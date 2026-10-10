import Foundation

/// VirtualBox — machine registry (`~/Library/VirtualBox/VirtualBox.xml`: `Global/MachineRegistry/
/// MachineEntry[@uuid,@src]`), machine files (`*.vbox`: `Machine[@uuid,@name,@OSType,@stateFile]`,
/// `Hardware/CPU[@count]`, `Hardware/Memory[@RAMSize]` in MB, `StorageControllers/…/AttachedDevice`,
/// `MediaRegistry/HardDisks/HardDisk[@uuid,@location]`), process matching and `VBoxManage` lines.
public enum VirtualBoxParsing {
    public static let providerID = VMProviderID.virtualBox.rawValue
    public static let bytesPerMiB: UInt64 = 1_048_576

    // MARK: Registry

    public struct RegistryEntry: Hashable, Sendable {
        public var uuid: String
        /// Absolute path of the `.vbox` file.
        public var path: String
    }

    /// `src` is absolute in current releases and relative to `~/Library/VirtualBox` in old ones;
    /// old releases also percent-encode it.
    public static func registryEntries(_ data: Data, virtualBoxHome: String) -> [RegistryEntry] {
        guard let root = VMProviderXMLElement.parse(data), root.name == "VirtualBox",
              let registry = root.descendant("Global/MachineRegistry") else { return [] }
        return registry.children(named: "MachineEntry").compactMap { entry in
            guard let uuid = entry.attributes["uuid"], var source = entry.attributes["src"], !source.isEmpty else { return nil }
            if source.contains("%"), let decoded = source.removingPercentEncoding { source = decoded }
            source = source.replacingOccurrences(of: "\\", with: "/")
            let path = source.hasPrefix("/") ? source : (virtualBoxHome as NSString).appendingPathComponent(source)
            return RegistryEntry(uuid: uuid, path: path)
        }
    }

    // MARK: .vbox

    public struct Config: Hashable, Sendable {
        public var uuid: String
        public var name: String
        public var osType: String?
        public var cpus: Int?
        public var memoryMiB: UInt64?
        /// A saved-state file is recorded: the VM is "Saved".
        public var hasSavedState: Bool
        /// Absolute paths of the hard disk images attached to the machine (differencing disks of
        /// snapshots included; their virtual size equals the base disk's).
        public var diskPaths: [String]
    }

    public static func parseMachine(_ data: Data, machineFolder: String) -> Config? {
        guard let root = VMProviderXMLElement.parse(data), root.name == "VirtualBox",
              let machine = root.child("Machine"),
              let uuid = machine.attributes["uuid"], let name = machine.attributes["name"] else { return nil }

        // Snapshots repeat Hardware/StorageControllers below Machine/Snapshot; only the
        // machine's own direct children describe its current configuration.
        let hardware = machine.child("Hardware")
        let cpus = hardware?.child("CPU")?.attributes["count"].flatMap { Int($0) }
        let memory = hardware?.child("Memory")?.attributes["RAMSize"].flatMap { UInt64($0) }

        var locations: [String: String] = [:]
        for disk in machine.child("MediaRegistry")?.child("HardDisks")?.allDescendants(named: "HardDisk") ?? [] {
            if let id = disk.attributes["uuid"], let location = disk.attributes["location"] { locations[id] = location }
        }
        var diskPaths: [String] = []
        for controller in machine.child("StorageControllers")?.children(named: "StorageController") ?? [] {
            for device in controller.children(named: "AttachedDevice") where device.attributes["type"] == "HardDisk" {
                guard let id = device.child("Image")?.attributes["uuid"], let location = locations[id] else { continue }
                diskPaths.append(location.hasPrefix("/") ? location : (machineFolder as NSString).appendingPathComponent(location))
            }
        }

        return Config(
            uuid: uuid,
            name: name,
            osType: machine.attributes["OSType"],
            cpus: cpus.flatMap { $0 > 0 ? $0 : nil },
            memoryMiB: memory.flatMap { $0 > 0 ? $0 : nil },
            hasSavedState: !(machine.attributes["stateFile"] ?? "").isEmpty,
            diskPaths: diskPaths
        )
    }

    /// VirtualBox OS type identifiers (`Ubuntu_64`, `Windows11_64`, `MacOS_arm64`, …).
    public static func guestInfo(osType: String?) -> (os: String?, architecture: String?) {
        guard let id = osType?.lowercased(), !id.isEmpty else { return (nil, nil) }
        let os: String?
        if id.hasPrefix("win") {
            os = "Windows"
        } else if id.hasPrefix("macos") || id.hasPrefix("darwin") || id.hasPrefix("mac") {
            os = "macOS"
        } else {
            let linux = ["linux", "ubuntu", "debian", "fedora", "redhat", "rhel", "oracle", "suse", "arch", "mandriva", "mandrake", "centos", "rocky", "alma", "xandros", "turbolinux", "linuxmint"]
            os = linux.contains(where: { id.contains($0) }) ? "Linux" : nil
        }
        let architecture: String?
        if id.hasSuffix("_64") { architecture = "x86_64" }
        else if id.hasSuffix("_arm64") { architecture = "arm64" }
        else { architecture = nil }
        return (os, architecture)
    }

    // MARK: Host processes

    private static let vmProcessPrefixes = ["VBoxHeadless", "VirtualBoxVM", "VBoxSDL"]

    /// VM processes are `VBoxHeadless --comment <name> --startvm <uuid> …` and
    /// `VirtualBoxVM --comment <name> --startvm <uuid> …`; the value is the UUID without braces
    /// (or the name when started by name).
    public static func hostProcesses(forUUID uuid: String, name: String, in processes: [VMHostProcess]) -> [VMHostProcess] {
        let wantedUUID = uuid.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased()
        return processes.filter { process in
            guard vmProcessPrefixes.contains(where: { process.name.hasPrefix($0) }) else { return false }
            guard let index = process.arguments.firstIndex(of: "--startvm"), index + 1 < process.arguments.count else { return false }
            let value = process.arguments[index + 1]
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased() == wantedUUID || value == name
        }
    }

    // MARK: Record

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: false,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    public static func makeRecord(config: Config, vboxPath: String, diskBytes: UInt64?, processes: [VMHostProcess]) -> VMRecord {
        let host = hostProcesses(forUUID: config.uuid, name: config.name, in: processes)
        let state: VMState = !host.isEmpty ? .running : (config.hasSavedState ? .suspended : .stopped)
        let guest = guestInfo(osType: config.osType)
        var details = [VMDetail(label: "Location", value: vboxPath)]
        if let osType = config.osType { details.append(VMDetail(label: "OS type", value: osType)) }
        return VMRecord(
            nativeID: config.uuid,
            name: config.name,
            state: state,
            guestOS: guest.os,
            architecture: guest.architecture,
            resources: VMResources(cpus: config.cpus, memoryBytes: config.memoryMiB.map { $0 * bytesPerMiB }, diskBytes: diskBytes),
            hostProcessIDs: host.map(\.pid),
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: VBoxManage

    /// `VBoxManage startvm <uuid> --type headless`.
    public static func startArguments(uuid: String) -> [String] { ["startvm", uuid, "--type", "headless"] }

    /// `controlvm acpipowerbutton` asks the guest to shut down.
    public static func stopArguments(uuid: String) -> [String] { ["controlvm", uuid, "acpipowerbutton"] }

    /// `controlvm reset` is a virtual hardware reset (no guest shutdown).
    public static func restartArguments(uuid: String) -> [String] { ["controlvm", uuid, "reset"] }

    /// `VBoxManage modifyvm <uuid> --cpus N --memory MB` for the values that differ; `nil` if none.
    public static func modifyArguments(uuid: String, new: VMResources, current: VMResources) -> [String]? {
        var arguments = ["modifyvm", uuid]
        if let cpus = new.cpus, cpus > 0, cpus != current.cpus {
            arguments += ["--cpus", String(cpus)]
        }
        if let memory = new.memoryBytes, memory >= bytesPerMiB, memory != current.memoryBytes {
            arguments += ["--memory", String(memory / bytesPerMiB)]
        }
        return arguments.count > 2 ? arguments : nil
    }
}
