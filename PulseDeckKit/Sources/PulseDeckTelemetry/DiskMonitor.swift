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
    }

    /// Free space changes slowly and querying it touches the file system, so it is refreshed
    /// on this interval (or when the device set changes) instead of every tick.
    private static let capacityRefreshInterval: Duration = .seconds(30)

    // `IOBlockStorageDriver.h` statistics keys.
    private static let statisticsKey = "Statistics"
    private static let bytesReadKey = "Bytes (Read)"
    private static let bytesWrittenKey = "Bytes (Write)"

    private var tracker = CounterRateTracker<String>()
    private var availableSpace: [String: MetricState<UInt64>] = [:]
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
                activeTime: .unavailable(.noPublicAPI)
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
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            if let disk = Self.readDisk(driver: driver) {
                disks.append(disk)
            }
        }
        return disks
    }

    /// Registry layout: IOBlockStorageDevice (parent) → IOBlockStorageDriver → IOMedia (whole
    /// disk, carries the BSD name).
    private static func readDisk(driver: io_registry_entry_t) -> RawDisk? {
        var media: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(driver, kIOServicePlane, &media) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(media) }
        guard let bsdName = property(media, kIOBSDNameKey) as? String else { return nil }

        var registryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(driver, &registryID)

        let statistics = property(driver, statisticsKey) as? [String: Any]

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
        return RawDisk(
            bsdName: bsdName,
            registryID: registryID,
            name: productName.flatMap { $0.isEmpty ? nil : $0 } ?? registryName(media) ?? bsdName,
            connection: connection(from: protocolCharacteristics),
            isRemovable: (property(media, "Removable") as? Bool) ?? false,
            size: (property(media, "Size") as? NSNumber)?.uint64Value,
            bytesRead: (statistics?[bytesReadKey] as? NSNumber)?.uint64Value,
            bytesWritten: (statistics?[bytesWrittenKey] as? NSNumber)?.uint64Value
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
        for device in devices {
            let media = Self.descendantMediaNames(ofDisk: device)
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
    }

    /// Mounted file systems backed by a `/dev/diskN…` node.
    private static func mountedVolumes() -> [(device: String, mountPoint: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var entries = [statfs](repeating: statfs(), count: Int(count))
        let filled = getfsstat(&entries, Int32(MemoryLayout<statfs>.stride * entries.count), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        let devicePrefix = "/dev/"
        return entries.prefix(Int(filled)).compactMap { entry in
            let from = withUnsafeBytes(of: entry.f_mntfromname) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: entry.f_mntonname) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
            guard from.hasPrefix(devicePrefix) else { return nil }
            return (String(from.dropFirst(devicePrefix.count)), on)
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
