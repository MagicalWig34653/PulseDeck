#if os(macOS)
import Darwin
import Foundation
import IOKit
import PulseDeckCore

/// Per-device disk throughput and capacity (SPEC §15).
///
/// Devices are discovered on every sample by matching `IOBlockStorageDriver` services, so
/// hot-plugged and ejected drives appear/disappear on the next tick. Byte counters come from the
/// driver's `Statistics` dictionary (keys documented in IOStorageFamily `IOBlockStorageDriver.h`).
/// Active time is not available: see TECHNICAL_LIMITATIONS.md L‑3.
public actor DiskMonitor: TelemetryProvider {
    private struct RawDisk {
        var bsdName: String
        var registryID: UInt64
        var name: String
        var connection: DiskConnection
        var isRemovable: Bool
        var size: UInt64?
        var bytesRead: UInt64?
        var bytesWritten: UInt64?
        var bus: String?
    }

    /// Volume details refreshed with free space.
    private struct VolumeDetails: Sendable {
        var mountPoints: [String]
        var snapshotCount: MetricState<Int>
    }

    /// Free space changes slowly and querying it touches the file system, so it is refreshed
    /// on this interval (or when the device set changes) instead of every tick.
    private static let capacityRefreshInterval: Duration = .seconds(30)

    // `IOBlockStorageDriver.h` statistics keys.
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    /// Static part of a disk, keyed by its IOMedia registry entry ID.
    private struct DiskDescription: Sendable {
        var bsdName: String
        var name: String
        var connection: DiskConnection
        var isRemovable: Bool
        var size: UInt64?
        var bus: String?
    }

    private var tracker = CounterRateTracker<String>()
    private var descriptions: [UInt64: DiskDescription] = [:]
    private var availableSpace: [String: MetricState<UInt64>] = [:]
    private var volumeDetails: [String: VolumeDetails] = [:]
    private var availableSpaceDevices: Set<String> = []
    private var availableSpaceReadAt: MonotonicInstant?

    public init() {}

    public func capability() -> TelemetryCapability {
        readDisks() == nil ? .unsupported(.transientFailure("IOServiceGetMatchingServices failed")) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<[DiskSnapshot]> {
        guard let disks = readDisks() else {
            return .unavailable(.transientFailure("IOServiceGetMatchingServices failed"))
        }
        let names = Set(disks.map(\.bsdName))
        refreshAvailableSpace(for: names, at: instant)

        var snapshots: [DiskSnapshot] = []
        snapshots.reserveCapacity(disks.count)
        for disk in disks {
            let rates: [MetricState<Double>]
            if let read = disk.bytesRead, let written = disk.bytesWritten {
                rates = tracker.update(key: disk.bsdName, generation: disk.registryID, counters: [read, written], at: instant)
            } else {
                rates = Array(repeating: .unavailable(.transientFailure("no driver statistics")), count: 2)
            }
            snapshots.append(DiskSnapshot(
                id: disk.bsdName,
                name: disk.name,
                connection: disk.connection,
                isRemovable: disk.isRemovable,
                capacityBytes: disk.size.map { .available($0) } ?? .unavailable(.transientFailure("no media size")),
                availableBytes: availableSpace[disk.bsdName] ?? .unavailable(.awaitingBaseline),
                readBytesPerSecond: rates[0],
                writeBytesPerSecond: rates[1],
                totalBytesRead: disk.bytesRead.map { .available($0) } ?? .unavailable(.transientFailure("no driver statistics")),
                totalBytesWritten: disk.bytesWritten.map { .available($0) } ?? .unavailable(.transientFailure("no driver statistics")),
                activeTime: .unavailable(.noPublicAPI),
                bus: disk.bus,
                mountPoints: volumeDetails[disk.bsdName]?.mountPoints ?? [],
                snapshotCount: volumeDetails[disk.bsdName]?.snapshotCount ?? .unavailable(.awaitingBaseline),
                snapshotBytes: .unavailable(.noPublicAPI)
            ))
        }
        tracker.retainOnly(names)
        snapshots.sort(by: Self.displayOrder)
        return .available(snapshots)
    }

    public func invalidateBaselines() {
        tracker.reset()
        availableSpaceReadAt = nil
    }

    /// Internal devices first, then external, then disk images; by BSD unit number within.
    private static func displayOrder(_ lhs: DiskSnapshot, _ rhs: DiskSnapshot) -> Bool {
        func rank(_ connection: DiskConnection) -> Int {
            switch connection {
            case .internal: 0
            case .external: 1
            case .unknown: 2
            case .diskImage: 3
            }
        }
        if rank(lhs.connection) != rank(rhs.connection) {
            return rank(lhs.connection) < rank(rhs.connection)
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    // MARK: - IOKit

    private func readDisks() -> [RawDisk]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var disks: [RawDisk] = []
        var seen: [UInt64: DiskDescription] = [:]
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            if let disk = readDisk(driver: driver, seen: &seen) {
                disks.append(disk)
            }
        }
        descriptions = seen
        return disks
    }

    /// Registry layout: IOBlockStorageDevice (parent) → IOBlockStorageDriver → IOMedia (whole
    /// disk, carries the BSD name).
    ///
    /// The static description is cached per IOMedia registry entry, so a known disk costs four
    /// registry calls per tick (driver ID, media, media ID, statistics) instead of about ten
    /// (M10). New media — including a card swapped in the same reader — has a new entry ID and
    /// is described afresh.
    private func readDisk(driver: io_registry_entry_t, seen: inout [UInt64: DiskDescription]) -> RawDisk? {
        var media: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(media) }
        var mediaID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &mediaID) == KERN_SUCCESS else { return nil }
        guard let description = descriptions[mediaID] ?? Self.describe(driver: driver, media: media) else { return nil }
        seen[mediaID] = description

        var registryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(driver, &registryID)
        let statistics = Self.property(driver, Self.statisticsKey) as? [String: Any]
        return RawDisk(
            bsdName: description.bsdName,
            registryID: registryID,
            name: description.name,
            connection: description.connection,
            isRemovable: description.isRemovable,
            size: description.size,
            bytesRead: (statistics?[Self.bytesReadKey] as? NSNumber)?.uint64Value,
            bytesWritten: (statistics?[Self.bytesWrittenKey] as? NSNumber)?.uint64Value,
            bus: description.bus
        )
    }

    /// Everything about a disk that does not change while its media is present.
    private static func describe(driver: io_registry_entry_t, media: io_registry_entry_t) -> DiskDescription? {
        guard let bsdName = property(media, kIOBSDNameKey) as? String else { return nil }
        var device: io_registry_entry_t = 0
        var protocolCharacteristics: [String: Any]?
        var deviceCharacteristics: [String: Any]?
        if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS {
            protocolCharacteristics = property(device, "Protocol Characteristics") as? [String: Any]
            deviceCharacteristics = property(device, "Device Characteristics") as? [String: Any]
            IOObjectRelease(device)
        }
        let productName = (deviceCharacteristics?["Product Name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DiskDescription(
            bsdName: bsdName,
            name: productName.flatMap { $0.isEmpty ? nil : $0 } ?? registryName(media) ?? bsdName,
            connection: connection(from: protocolCharacteristics),
            isRemovable: (property(media, "Removable") as? Bool) ?? false,
            size: (property(media, "Size") as? NSNumber)?.uint64Value,
            // e.g. "PCI-Express", "USB", "Thunderbolt", "SATA", "Apple Fabric", "Virtual Interface".
            bus: (protocolCharacteristics?["Physical Interconnect"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func connection(from characteristics: [String: Any]?) -> DiskConnection {
        let location = characteristics?["Physical Interconnect Location"] as? String
        let interconnect = characteristics?["Physical Interconnect"] as? String
        if location == "File" || interconnect == "Virtual Interface" {
            return .diskImage
        }
        switch location {
        case "Internal": return .internal
        case "External": return .external
        default: return .unknown
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// BSD names of all media below a whole disk: its partitions and, for APFS, the synthesized
    /// container disk and its volumes (disk0 → disk0s2 → disk3 → disk3s1 …).
    private static func descendantMediaNames(ofDisk bsdName: String) -> Set<String> {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return [] }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return [] }
        defer { IOObjectRelease(media) }
        var names: Set<String> = [bsdName]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(media, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return names
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMedia") != 0, let name = property(entry, kIOBSDNameKey) as? String {
                names.insert(name)
            }
        }
        return names
    }

    // MARK: - Free space

    private func refreshAvailableSpace(for devices: Set<String>, at instant: MonotonicInstant) {
        if devices == availableSpaceDevices,
           let readAt = availableSpaceReadAt,
           instant.nanoseconds(since: readAt) < Self.capacityRefreshInterval.nanosecondsClamped {
            return
        }
        availableSpaceDevices = devices
        availableSpaceReadAt = instant

        let volumes = Self.mountedVolumes()
        var result: [String: MetricState<UInt64>] = [:]
        var details: [String: VolumeDetails] = [:]
        for device in devices {
            let media = Self.descendantMediaNames(ofDisk: device)
            let deviceVolumes = volumes.filter { media.contains($0.device) }
            details[device] = VolumeDetails(
                mountPoints: Self.orderedMountPoints(deviceVolumes.map(\.mountPoint)),
                snapshotCount: Self.snapshotCount(of: deviceVolumes)
            )
            // APFS volumes in one container share its free space: count each container once.
            var perContainer: [String: UInt64] = [:]
            for volume in volumes where media.contains(volume.device) {
                guard let available = Self.availableCapacity(atMountPoint: volume.mountPoint) else { continue }
                let container = Self.wholeDiskName(volume.device)
                perContainer[container] = max(perContainer[container] ?? 0, available)
            }
            result[device] = perContainer.isEmpty ? .unavailable(.notApplicable) : .available(perContainer.values.reduce(0, +))
        }
        availableSpace = result
        volumeDetails = details
    }

    /// "/" first, then alphabetically.
    private static func orderedMountPoints(_ mountPoints: [String]) -> [String] {
        Array(Set(mountPoints)).sorted { lhs, rhs in
            if lhs == "/" || rhs == "/" { return lhs == "/" }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    // MARK: - APFS snapshots

    private typealias SnapshotList = @convention(c) (Int32, UnsafeMutablePointer<attrlist>?, UnsafeMutableRawPointer?, Int, UInt32) -> Int32

    /// Snapshots of the disk's mounted APFS volumes, each volume counted once (the boot volume
    /// is mounted from a snapshot of itself, `disk3s1s1` → volume `disk3s1`).
    private static func snapshotCount(of volumes: [(device: String, mountPoint: String, fileSystem: String)]) -> MetricState<Int> {
        let apfs = volumes.filter { $0.fileSystem == "apfs" }
        guard !apfs.isEmpty else { return .unavailable(.notApplicable) }
        var seen = Set<String>()
        var total = 0
        var failure: UnavailableReason?
        for volume in apfs where seen.insert(volumeName(volume.device)).inserted {
            switch countSnapshots(atMountPoint: volume.mountPoint) {
            case .available(let count): total += count
            case .unavailable(let reason): failure = failure ?? reason
            case .notSampled: break
            }
        }
        if total == 0, let failure { return .unavailable(failure) }
        return .available(total)
    }

    /// Counts snapshots with `fs_snapshot_list(2)` (public, `<sys/snapshot.h>`), requesting only
    /// names. The call returns the number of entries per batch and 0 when done. Looked up at run
    /// time so the build does not depend on the header being part of Swift's Darwin module.
    private static func countSnapshots(atMountPoint path: String) -> MetricState<Int> {
        // RTLD_DEFAULT is ((void *)-2) on Darwin.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fs_snapshot_list") else {
            return .unavailable(.noPublicAPI)
        }
        let list = unsafeBitCast(symbol, to: SnapshotList.self)
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return .unavailable(reason(for: errno)) }
        defer { close(descriptor) }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_NAME)
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var total = 0
        // Bounded in case a file system never reports the end of the list.
        let maximumBatches = 1_000
        for _ in 0..<maximumBatches {
            let count = buffer.withUnsafeMutableBytes { bytes in
                list(descriptor, &attributes, bytes.baseAddress, bytes.count, 0)
            }
            if count == 0 { return .available(total) }
            guard count > 0 else { return total > 0 ? .available(total) : .unavailable(reason(for: errno)) }
            total += Int(count)
        }
        return .available(total)
    }

    private static func reason(for error: Int32) -> UnavailableReason {
        error == EPERM || error == EACCES ? .permissionDenied : .transientFailure("errno \(error)")
    }

    /// `disk3s1s1` → `disk3s1`; `disk3s5` stays.
    private static func volumeName(_ bsdName: String) -> String {
        let parts = bsdName.split(separator: "s", omittingEmptySubsequences: false)
        // "disk3s1s1" splits into ["di", "k3", "1", "1"].
        guard parts.count > 3 else { return bsdName }
        return parts.dropLast().joined(separator: "s")
    }

    /// Mounted file systems backed by a `/dev/diskN…` node.
    private static func mountedVolumes() -> [(device: String, mountPoint: String, fileSystem: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // `statfs` is a plain C struct, so the kernel can fill uninitialized storage directly.
        let entries = Array<statfs>(unsafeUninitializedCapacity: Int(count)) { buffer, initializedCount in
            let filled = getfsstat(buffer.baseAddress, Int32(MemoryLayout<statfs>.stride * buffer.count), MNT_NOWAIT)
            initializedCount = min(max(Int(filled), 0), buffer.count)
        }
        let devicePrefix = "/dev/"
        return entries.compactMap { entry in
            let from = withUnsafeBytes(of: entry.f_mntfromname) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: entry.f_mntonname) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: entry.f_fstypename) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            guard from.hasPrefix(devicePrefix) else { return nil }
            return (String(from.dropFirst(devicePrefix.count)), on, type)
        }
    }

    /// Available space as Finder reports it (includes purgeable space on APFS).
    private static func availableCapacity(atMountPoint path: String) -> UInt64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        return values.volumeAvailableCapacity.map { UInt64(max($0, 0)) }
    }

    /// `disk3s1s1` → `disk3`.
    private static func wholeDiskName(_ bsdName: String) -> String {
        let prefix = "disk"
        guard bsdName.hasPrefix(prefix) else { return bsdName }
        let digits = bsdName.dropFirst(prefix.count).prefix { $0.isNumber }
        return prefix + digits
    }
}
#endif
