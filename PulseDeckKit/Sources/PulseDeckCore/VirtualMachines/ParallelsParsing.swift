import Foundation

/// Parallels Desktop. Listing uses `prlctl list -a -i --json` (the documented interface: no
/// readable registry of registered VMs was found, see `ParallelsVMAdapter`); `config.pvs` of a
/// `.pvm` bundle is the fallback when `prlctl` is missing. JSON keys follow the output consumed
/// by Parallels' own VS Code extension (`Hardware.cpu.cpus`, `Hardware.memory.size`,
/// `Hardware.hdd0.size`, `State`, `OS`, `Home`, `ID`), the XML paths are those of `config.pvs`.
public enum ParallelsParsing {
    public static let providerID = VMProviderID.parallels.rawValue
    public static let bytesPerMiB: UInt64 = 1_048_576

    public struct Machine: Hashable, Sendable {
        /// `{xxxxxxxx-xxxx-…}` as Parallels writes it.
        public var uuid: String
        public var name: String
        /// `nil` when the source (config.pvs) does not say.
        public var state: String?
        /// Parallels OS identifier from `prlctl` (`win-11`, `macos`, `ubuntu`), or a derived name.
        public var os: String?
        public var cpus: Int?
        public var memoryMiB: UInt64?
        /// Virtual size of the single enabled hard disk, if known (MiB).
        public var diskMiB: UInt64?
        /// `true` when the VM has exactly one enabled disk and it is `hdd0` (the one
        /// `prlctl set --device-set hdd0 --size` addresses).
        public var hasEditableDisk: Bool
        public var home: String?
        public var architecture: String?
    }

    // MARK: prlctl JSON

    /// Parses `prlctl list -a -i --json`. Tolerates text before the JSON and a single object
    /// instead of an array.
    public static func parseList(_ output: String) -> [Machine] {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return [] }
        let data = Data(output[start...].utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let entries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            entries = array
        } else if let single = object as? [String: Any] {
            entries = [single]
        } else {
            return []
        }
        return entries.compactMap(machine(from:))
    }

    private static func machine(from entry: [String: Any]) -> Machine? {
        guard let uuid = entry["ID"] as? String, let name = entry["Name"] as? String else { return nil }
        // Templates and containers are not VMs a user runs here.
        if let type = entry["Type"] as? String, type.uppercased() != "VM" { return nil }

        let hardware = entry["Hardware"] as? [String: Any] ?? [:]
        let cpu = hardware["cpu"] as? [String: Any]
        let memory = hardware["memory"] as? [String: Any]

        // hdd0, hdd1, … with `enabled`; CD-ROMs are `cdromN` and never match the prefix.
        let disks = hardware.compactMap { key, value -> (key: String, size: UInt64?)? in
            guard key.hasPrefix("hdd"), let disk = value as? [String: Any] else { return nil }
            if let enabled = disk["enabled"] as? Bool, !enabled { return nil }
            return (key, mebibytes(from: disk["size"]))
        }
        let single = disks.count == 1 ? disks.first : nil

        return Machine(
            uuid: uuid,
            name: name,
            state: entry["State"] as? String,
            os: entry["OS"] as? String,
            cpus: integer(cpu?["cpus"]),
            memoryMiB: mebibytes(from: memory?["size"]),
            diskMiB: single?.size,
            hasEditableDisk: single?.key == "hdd0" && single?.size != nil,
            home: (entry["Home"] as? String) ?? (entry["Home path"] as? String),
            architecture: architecture(fromCPUType: cpu?["type"] as? String)
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Sizes appear as `"4096Mb"`, `"262144Mb"`, possibly `"64Gb"` or a bare number (MiB).
    public static func mebibytes(from value: Any?) -> UInt64? {
        if let number = value as? Int { return number >= 0 ? UInt64(number) : nil }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let number = Double(digits), number >= 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let factor: Double
        switch unit {
        case "", "m", "mb", "mib": factor = 1
        case "g", "gb", "gib": factor = 1024
        case "t", "tb", "tib": factor = 1024 * 1024
        case "k", "kb", "kib": factor = 1.0 / 1024
        default: return nil
        }
        return UInt64((number * factor).rounded())
    }

    /// `Hardware.cpu.type` is `ARM` on Apple silicon hosts; Intel VMs report `x86`-style values.
    private static func architecture(fromCPUType type: String?) -> String? {
        guard let type = type?.lowercased() else { return nil }
        if type.contains("arm") { return "arm64" }
        if type.contains("x86") || type.contains("intel") || type.contains("amd64") { return "x86_64" }
        return nil
    }

    public static func state(_ value: String?) -> VMState {
        switch value?.lowercased() {
        case "running": .running
        case "stopped": .stopped
        case "paused": .paused
        case "suspended": .suspended
        case "starting", "resuming", "restoring": .starting
        case "stopping", "suspending", "pausing", "snapshotting": .stopping
        default: .unknown
        }
    }

    /// Guest OS family from Parallels' OS identifiers (`win-11`, `macos`, `ubuntu`, `debian`, …).
    public static func guestOS(_ os: String?) -> String? {
        guard let os = os?.lowercased(), !os.isEmpty else { return nil }
        if os.hasPrefix("win") { return "Windows" }
        if os.hasPrefix("mac") || os.hasPrefix("darwin") { return "macOS" }
        if os == "other" || os == "undefined" || os == "custom" { return nil }
        let linuxFamily = ["linux", "ubuntu", "debian", "fedora", "centos", "redhat", "rhel", "suse", "kali", "mint", "manjaro", "arch", "alma", "rocky", "oracle", "gentoo", "mageia"]
        return linuxFamily.contains(where: { os.contains($0) }) ? "Linux" : nil
    }

    // MARK: config.pvs

    /// Reads a `.pvm` bundle's `config.pvs`.
    public static func parsePVS(_ data: Data, bundlePath: String) -> Machine? {
        guard let root = VMProviderXMLElement.parse(data), root.name == "ParallelsVirtualMachine",
              let uuid = root.text(at: "Identification/VmUuid"), let name = root.text(at: "Identification/VmName") else { return nil }

        let disks = (root.descendant("Hardware")?.children(named: "Hdd") ?? []).filter { $0.text(at: "Enabled") != "0" }
        let size = disks.count == 1 ? disks.first?.text(at: "Size").flatMap { UInt64($0) } : nil
        return Machine(
            uuid: uuid,
            name: name,
            state: nil,
            os: root.text(at: "Settings/General/OsType").flatMap { Int($0) }.flatMap(osIdentifier(pvsOSType:)),
            cpus: root.text(at: "Hardware/Cpu/Number").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            memoryMiB: root.text(at: "Hardware/Memory/RAM").flatMap { UInt64($0) },
            diskMiB: size,
            hasEditableDisk: false,
            home: bundlePath,
            architecture: nil
        )
    }

    /// Maps `Settings/General/OsType` (`PVS_GUEST_TYPE_*` from the SDK header `PrlOses.h`) to
    /// the coarse identifiers `guestOS(_:)` understands.
    private static func osIdentifier(pvsOSType: Int) -> String? {
        switch pvsOSType {
        case 7: "macos"
        case 8: "win"
        case 9: "linux"
        default: nil
        }
    }

    // MARK: Host processes

    /// Each running VM has its own `prl_vm_app --vm-name <name> --uuid {uuid} --dir-uuid {…}
    /// --log-dir <bundle>` process (seen in Parallels problem reports).
    public static func hostProcesses(forUUID uuid: String, in processes: [VMHostProcess]) -> [VMHostProcess] {
        let wanted = normalize(uuid)
        return processes.filter { process in
            guard process.name == "prl_vm_app" || process.executablePath?.hasSuffix("/prl_vm_app") == true else { return false }
            guard let index = process.arguments.firstIndex(of: "--uuid"), index + 1 < process.arguments.count else { return false }
            return normalize(process.arguments[index + 1]) == wanted
        }
    }

    private static func normalize(_ uuid: String) -> String {
        uuid.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased()
    }

    // MARK: Record

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: true,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    /// A machine read from config.pvs has no state: it counts as running if its `prl_vm_app`
    /// process exists and as stopped otherwise (suspended / paused cannot be told apart then).
    public static func makeRecord(_ machine: Machine, processes: [VMHostProcess]) -> VMRecord {
        let host = hostProcesses(forUUID: machine.uuid, in: processes)
        let resolvedState: VMState = machine.state == nil ? (host.isEmpty ? .stopped : .running) : Self.state(machine.state)

        var capabilities = Self.capabilities
        capabilities.canEditDisk = machine.hasEditableDisk
        capabilities.canEditCPUs = machine.cpus != nil
        capabilities.canEditMemory = machine.memoryMiB != nil

        var details: [VMDetail] = []
        if let home = machine.home { details.append(VMDetail(label: "Location", value: home)) }
        if machine.state != nil, let os = machine.os { details.append(VMDetail(label: "Parallels OS", value: os)) }

        return VMRecord(
            nativeID: machine.uuid,
            name: machine.name,
            state: resolvedState,
            guestOS: guestOS(machine.os),
            architecture: machine.architecture,
            resources: VMResources(
                cpus: machine.cpus,
                memoryBytes: machine.memoryMiB.map { $0 * bytesPerMiB },
                diskBytes: machine.diskMiB.map { $0 * bytesPerMiB }
            ),
            hostProcessIDs: host.map(\.pid),
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: Commands

    public static let listArguments = ["list", "-a", "-i", "--json"]

    /// `prlctl start|stop|restart <uuid>` (`stop` without `--kill` is a graceful shutdown).
    public static func arguments(for action: VMAction, uuid: String) -> [String] {
        [action.rawValue, uuid]
    }

    /// One `prlctl set` call per setting (`--cpus N`, `--memsize MB`, `--device-set hdd0 --size MB`);
    /// only values that differ, and a disk only when it grows.
    public static func setCommands(uuid: String, new: VMResources, current: VMResources) -> [[String]] {
        var commands: [[String]] = []
        if let cpus = new.cpus, cpus > 0, cpus != current.cpus {
            commands.append(["set", uuid, "--cpus", String(cpus)])
        }
        if let memory = new.memoryBytes, memory >= bytesPerMiB, memory != current.memoryBytes {
            commands.append(["set", uuid, "--memsize", String(memory / bytesPerMiB)])
        }
        if let disk = new.diskBytes, disk > (current.diskBytes ?? 0) {
            let mebibytes = (disk + bytesPerMiB - 1) / bytesPerMiB
            commands.append(["set", uuid, "--device-set", "hdd0", "--size", String(mebibytes)])
        }
        return commands
    }
}
