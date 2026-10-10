import Foundation

/// UTM — configuration (`<name>.utm/config.plist`), state derivation from the host process table
/// and `utmctl` command lines. Keys verified against UTM's sources
/// (`UTMAppleConfiguration*`, `UTMQemuConfiguration*`, `utmctl/UTMCtl.swift`).
public enum UTMParsing {
    public static let providerID = VMProviderID.utm.rawValue

    public enum Backend: String, Hashable, Sendable {
        case apple = "Apple"
        case qemu = "QEMU"
    }

    public struct Drive: Hashable, Sendable {
        /// File name inside `<bundle>/Data/`; `nil` for removable drives without an image.
        public var imageName: String?
        /// QEMU only: `Disk`, `CD`, `BIOS`, …
        public var imageType: String?
        public var isReadOnly: Bool
    }

    public struct Config: Hashable, Sendable {
        public var name: String
        public var uuid: String
        public var backend: Backend
        public var architecture: String?
        /// `nil` when UTM chooses automatically (`CPUCount` 0).
        public var cpuCount: Int?
        public var memoryMiB: Int?
        /// Apple backend only (`System/Boot/OperatingSystem`).
        public var guestOS: String?
        public var drives: [Drive]
    }

    // MARK: config.plist

    /// Parses a property list (XML or binary). `nil` if it is not a UTM configuration.
    public static func parseConfig(_ data: Data) -> Config? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = object as? [String: Any],
              let information = root["Information"] as? [String: Any],
              let name = information["Name"] as? String,
              let uuid = information["UUID"] as? String else { return nil }

        // Old QEMU configurations have no "Backend" key; UTM treats a missing key as QEMU.
        let backendName = root["Backend"] as? String ?? Backend.qemu.rawValue
        guard let backend = Backend(rawValue: backendName) else { return nil }

        let system = root["System"] as? [String: Any] ?? [:]
        let cpuCount = integer(system["CPUCount"])
        let memory = integer(system["MemorySize"])
        let boot = system["Boot"] as? [String: Any]
        let drives = (root["Drive"] as? [[String: Any]] ?? []).map { entry in
            Drive(
                imageName: entry["ImageName"] as? String,
                imageType: entry["ImageType"] as? String,
                isReadOnly: entry["ReadOnly"] as? Bool ?? false
            )
        }
        return Config(
            name: name,
            uuid: uuid,
            backend: backend,
            architecture: (system["Architecture"] as? String).map(architecture),
            cpuCount: (cpuCount ?? 0) > 0 ? cpuCount : nil,
            memoryMiB: (memory ?? 0) > 0 ? memory : nil,
            guestOS: backend == .apple ? appleGuestOS(boot?["OperatingSystem"] as? String) : nil,
            drives: drives
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func appleGuestOS(_ value: String?) -> String? {
        switch value {
        case "macOS": "macOS"
        case "Linux": "Linux"
        default: nil
        }
    }

    public static func architecture(_ value: String) -> String {
        switch value {
        case "aarch64": "arm64"
        default: value
        }
    }

    /// Names of the image files that make up the VM's own disks (inside `<bundle>/Data/`):
    /// QEMU `ImageType == Disk`; Apple drives with an image that are not read-only
    /// (read-only ones are installer media).
    public static func diskImageNames(_ config: Config) -> [String] {
        config.drives.compactMap { drive in
            guard let image = drive.imageName, !image.isEmpty else { return nil }
            switch config.backend {
            case .qemu: return drive.imageType == "Disk" ? image : nil
            case .apple: return drive.isReadOnly ? nil : image
            }
        }
    }

    // MARK: Host processes

    /// The value following `option` in an argument list (QEMU style `-uuid <value>`).
    public static func argument(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// UTM starts QEMU through its `QEMULauncher` helper with the generated QEMU arguments, which
    /// contain `-uuid <VM UUID>` (`UTMQemuConfiguration+Arguments.swift`). Only a process with
    /// exactly this UUID counts.
    public static func qemuProcesses(forUUID uuid: String, in processes: [VMHostProcess]) -> [VMHostProcess] {
        processes.filter { process in
            guard process.name.hasPrefix("QEMULauncher") || process.name.hasPrefix("qemu-") else { return false }
            guard let value = argument(after: "-uuid", in: process.arguments) else { return false }
            return value.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }

    public static func isUTMRunning(_ processes: [VMHostProcess]) -> Bool {
        processes.contains { process in
            process.name == "UTM" && (process.executablePath?.contains("/UTM.app/") ?? true)
        }
    }

    /// Virtualization.framework runs every Apple-backend VM (UTM's, Tart's, …) in a
    /// `com.apple.Virtualization.VirtualMachine` XPC service; nothing in its command line names
    /// the VM, so these processes cannot be attributed.
    public static func hasVirtualizationServiceProcess(_ processes: [VMHostProcess]) -> Bool {
        processes.contains { process in
            process.name.hasPrefix("com.apple.Virtualization") || (process.executablePath?.contains("com.apple.Virtualization.VirtualMachine") ?? false)
        }
    }

    public static let appleAttributionNote = "UTM runs Apple-virtualization VMs in system services shared with other VMs, so their CPU and memory use cannot be attributed to one VM."

    // MARK: Record

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: false, canEditMemory: false, canEditDisk: false
    )

    public static func makeRecord(config: Config, diskBytes: UInt64?, bundlePath: String, processes: [VMHostProcess]) -> VMRecord {
        var state: VMState
        var hostPIDs: [Int32] = []
        var details = [VMDetail(label: "Location", value: bundlePath)]

        switch config.backend {
        case .qemu:
            let host = qemuProcesses(forUUID: config.uuid, in: processes)
            hostPIDs = host.map(\.pid)
            state = host.isEmpty ? .stopped : .running
            details.append(VMDetail(label: "Backend", value: "QEMU"))
        case .apple:
            // UTM not running → no VM of it can run. UTM running and no Virtualization service
            // process at all → also none. Otherwise some VM runs but not which one.
            if !isUTMRunning(processes) || !hasVirtualizationServiceProcess(processes) {
                state = .stopped
            } else {
                state = .unknown
            }
            details.append(VMDetail(label: "Backend", value: "Apple Virtualization"))
            details.append(VMDetail(label: "Host usage", value: appleAttributionNote))
        }
        if config.cpuCount == nil {
            details.append(VMDetail(label: "CPU cores", value: "Automatic (set by UTM when the VM starts)"))
        }

        return VMRecord(
            nativeID: config.uuid,
            name: config.name,
            state: state,
            guestOS: config.guestOS,
            architecture: config.architecture,
            resources: VMResources(
                cpus: config.cpuCount,
                memoryBytes: config.memoryMiB.map { UInt64($0) * 1_048_576 },
                diskBytes: diskBytes
            ),
            hostProcessIDs: hostPIDs,
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: utmctl

    /// `utmctl start <uuid>`: the identifier is "either the UUID or the complete name".
    public static func startArguments(uuid: String) -> [String] { ["start", uuid] }

    /// `--request` asks the guest OS to power down (a "Stop" that behaves like pressing the power
    /// button); `utmctl stop` without it force-stops the VM.
    public static func stopArguments(uuid: String) -> [String] { ["stop", "--request", uuid] }

    public static func statusArguments(uuid: String) -> [String] { ["status", uuid] }

    /// `utmctl status` prints one of `stopped starting started pausing paused resuming stopping`.
    public static func parseStatus(_ output: String) -> VMState {
        let word = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
        switch word {
        case "stopped": return .stopped
        case "starting", "resuming": return .starting
        case "started": return .running
        case "pausing", "paused": return .paused
        case "stopping": return .stopping
        default: return .unknown
        }
    }
}
