import Foundation

/// Pure logic for the Podman Machine adapter.
///
/// Sources (podman `main`): `pkg/machine/vmconfigs/config.go` (`MachineConfig`, `ResourceConfig`:
/// `CPUs`, `Memory` in MiB, `DiskSize` in GiB), `pkg/machine/env/dir.go` (configs live in
/// `$XDG_CONFIG_HOME|~/.config / containers/podman/machine/<provider>/<name>.json`, provider is
/// `applehv`, `libkrun`, `qemu`, …), `pkg/machine/apple/devices.go` (the VM's disk is passed to
/// vfkit/krunkit as `--device virtio-blk,path=<ImagePath>`), `pkg/machine/shim/host.go` (`Set`:
/// disk size must be strictly larger) and `pkg/machine/apple/apple.go` (`SetProviderAttrs`: "unable to
/// change settings unless vm is stopped"), `cmd/podman/machine/set.go` (`--cpus`, `--memory` MiB,
/// `--disk-size` GiB).
public enum PodmanVMParsing {
    /// A machine as stored in `<name>.json`.
    public struct Machine: Hashable, Sendable {
        public var name: String
        /// Hypervisor provider = name of the directory the file was found in ("applehv", "libkrun", "qemu").
        public var provider: String
        public var cpus: Int?
        public var memoryMiB: UInt64?
        public var diskGiB: UInt64?
        /// `true` between the start of `podman machine start` and the machine being ready.
        public var starting: Bool
        public var rootful: Bool?
        /// Paths of the machine's disk image (`ImagePath.Path` and its short symlink).
        public var imagePaths: [String]

        public init(name: String, provider: String, cpus: Int? = nil, memoryMiB: UInt64? = nil, diskGiB: UInt64? = nil, starting: Bool = false, rootful: Bool? = nil, imagePaths: [String] = []) {
            self.name = name
            self.provider = provider
            self.cpus = cpus
            self.memoryMiB = memoryMiB
            self.diskGiB = diskGiB
            self.starting = starting
            self.rootful = rootful
            self.imagePaths = imagePaths
        }
    }

    /// Directory below the home directory that holds one subdirectory per provider.
    public static let configDirectoryComponents = [".config", "containers", "podman", "machine"]

    // MARK: - Config file

    /// Parses one machine config. `fileName` (without directories) is the fallback name when the
    /// JSON has no `Name`. `nil` when the JSON is not an object.
    public static func parseMachine(_ data: Data, provider: String, fileName: String) -> Machine? {
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        let fallbackName = fileName.hasSuffix(".json") ? String(fileName.dropLast(5)) : fileName
        let name = (config.name?.isEmpty == false ? config.name : nil) ?? fallbackName
        guard !name.isEmpty else { return nil }
        var paths: [String] = []
        if let path = config.imagePath?.path, !path.isEmpty { paths.append(path) }
        if let link = config.imagePath?.symlink, !link.isEmpty, !paths.contains(link) { paths.append(link) }
        return Machine(
            name: name,
            provider: provider,
            cpus: config.resources?.cpus.flatMap { Int(exactly: $0) },
            memoryMiB: config.resources?.memory,
            diskGiB: config.resources?.diskSize,
            starting: config.starting ?? false,
            rootful: config.hostUser?.rootful,
            imagePaths: paths
        )
    }

    // MARK: - Host processes

    /// Process names of the hypervisors podman starts: vfkit (applehv), krunkit (libkrun) and QEMU.
    static func isHypervisorProcess(_ process: VMHostProcess) -> Bool {
        process.name == "vfkit" || process.name == "krunkit" || process.name.hasPrefix("qemu-system-")
    }

    /// A hypervisor process belongs to the machine when one of its arguments names the machine's
    /// disk image (vfkit/krunkit: `virtio-blk,path=<image>`; QEMU: `file=<image>`). The image path is
    /// unique per machine and the match requires the path to end at the argument end or a comma.
    public static func hostProcessIDs(machine: Machine, processes: [VMHostProcess]) -> [Int32] {
        guard !machine.imagePaths.isEmpty else { return [] }
        return processes.filter { process in
            isHypervisorProcess(process) && process.arguments.contains { argument in
                machine.imagePaths.contains { containsPath($0, in: argument) }
            }
        }.map(\.pid).sorted()
    }

    /// `true` when `path` occurs in `argument` followed by the end of the string or a comma.
    static func containsPath(_ path: String, in argument: String) -> Bool {
        var searchRange = argument.startIndex..<argument.endIndex
        while let found = argument.range(of: path, range: searchRange) {
            if found.upperBound == argument.endIndex || argument[found.upperBound] == "," { return true }
            searchRange = found.upperBound..<argument.endIndex
        }
        return false
    }

    // MARK: - Records

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: true,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    public static func records(machines: [Machine], processes: [VMHostProcess]) -> [VMRecord] {
        // vfkit/krunkit/QEMU processes whose arguments the kernel did not give us: their owner
        // cannot be ruled out, so a machine without a match is "unknown", not "stopped".
        let unreadableHypervisors = processes.contains { isHypervisorProcess($0) && $0.arguments.isEmpty }

        return machines.map { machine in
            let processIDs = hostProcessIDs(machine: machine, processes: processes)
            let state: VMState
            if !processIDs.isEmpty {
                state = machine.starting ? .starting : .running
            } else if unreadableHypervisors {
                state = .unknown
            } else {
                state = .stopped
            }

            var details = [VMDetail(label: "Hypervisor", value: hypervisorName(provider: machine.provider))]
            if let rootful = machine.rootful {
                details.append(VMDetail(label: "Mode", value: rootful ? "Rootful" : "Rootless"))
            }
            if state == .unknown {
                details.append(VMDetail(label: "State", value: "A hypervisor process whose arguments cannot be read is running, so it is unclear whether this machine is up."))
            }

            return VMRecord(
                nativeID: "\(machine.provider)/\(machine.name)",
                name: machine.name,
                state: state,
                guestOS: "Linux",
                architecture: nil,
                resources: VMResources(
                    cpus: machine.cpus,
                    memoryBytes: machine.memoryMiB.flatMap { multiplied($0, by: 1_048_576) },
                    diskBytes: machine.diskGiB.flatMap { multiplied($0, by: 1_073_741_824) }
                ),
                ipAddress: nil,
                startedAt: nil,
                hostProcessIDs: processIDs,
                details: details,
                capabilities: capabilities
            )
        }
    }

    static func hypervisorName(provider: String) -> String {
        switch provider {
        case "applehv": "Apple Virtualization (vfkit)"
        case "libkrun": "libkrun (krunkit)"
        case "qemu": "QEMU"
        default: provider
        }
    }

    // MARK: - Actions and editing

    /// Commands for `action`; restart is stop followed by start (podman has no restart verb for machines).
    public static func actionCommands(_ action: VMAction, machine: String) -> [[String]] {
        switch action {
        case .start: [["machine", "start", machine]]
        case .stop: [["machine", "stop", machine]]
        case .restart: [["machine", "stop", machine], ["machine", "start", machine]]
        }
    }

    public enum EditError: Error, Hashable, Sendable {
        case invalidCPUCount
        case invalidMemory
        case diskMustGrow
    }

    /// `podman machine set --cpus N --memory MiB --disk-size GiB <name>` with only the changed values,
    /// or an empty list when nothing differs. Podman rejects a disk size that is not strictly larger
    /// than the current one (whole GiB), so the request is rounded up to GiB and checked first.
    public static func setCommands(machine: String, current: VMResources, requested: VMResources) -> Result<[[String]], EditError> {
        var flags: [String] = []
        if let cpus = requested.cpus, cpus != current.cpus {
            guard cpus >= 1 else { return .failure(.invalidCPUCount) }
            flags += ["--cpus", String(cpus)]
        }
        if let memory = requested.memoryBytes, memory != current.memoryBytes {
            let mebibytes = roundedUp(memory, toUnit: 1_048_576)
            guard mebibytes >= 1 else { return .failure(.invalidMemory) }
            flags += ["--memory", String(mebibytes)]
        }
        if let disk = requested.diskBytes, disk != current.diskBytes {
            let gibibytes = roundedUp(disk, toUnit: 1_073_741_824)
            // Compare in the unit podman stores (GiB), not in bytes.
            let existingGiB = current.diskBytes.map { $0 / 1_073_741_824 }
            if let existingGiB {
                if gibibytes < existingGiB { return .failure(.diskMustGrow) }
                // Same size in whole GiB: nothing to change (podman would reject a non-larger size).
                if gibibytes > existingGiB { flags += ["--disk-size", String(gibibytes)] }
            } else {
                flags += ["--disk-size", String(gibibytes)]
            }
        }
        return .success(flags.isEmpty ? [] : [["machine", "set"] + flags + [machine]])
    }

    private static func roundedUp(_ value: UInt64, toUnit unit: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(unit - 1)
        return (overflow ? UInt64.max : sum) / unit
    }

    /// The highest version among Homebrew Cellar directory names such as `5.4.2` or `10.1.0_1`
    /// (compared numerically, so `10.0` beats `9.2`); `nil` for an empty list.
    public static func highestVersion(of names: [String]) -> String? {
        names.filter { $0.first?.isNumber == true }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static func multiplied(_ value: UInt64, by factor: UInt64) -> UInt64? {
        let (product, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? nil : product
    }

    // MARK: - Decoding

    private struct Config: Decodable {
        var name: String?
        var resources: Resources?
        var starting: Bool?
        var hostUser: HostUser?
        var imagePath: ImagePath?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case resources = "Resources"
            case starting = "Starting"
            case hostUser = "HostUser"
            case imagePath = "ImagePath"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            resources = try? container.decodeIfPresent(Resources.self, forKey: .resources)
            starting = try? container.decodeIfPresent(Bool.self, forKey: .starting)
            hostUser = try? container.decodeIfPresent(HostUser.self, forKey: .hostUser)
            imagePath = try? container.decodeIfPresent(ImagePath.self, forKey: .imagePath)
        }
    }

    private struct Resources: Decodable {
        var cpus: UInt64?
        var memory: UInt64?
        var diskSize: UInt64?

        enum CodingKeys: String, CodingKey {
            case cpus = "CPUs"
            case memory = "Memory"
            case diskSize = "DiskSize"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cpus = try? container.decodeIfPresent(UInt64.self, forKey: .cpus)
            memory = try? container.decodeIfPresent(UInt64.self, forKey: .memory)
            diskSize = try? container.decodeIfPresent(UInt64.self, forKey: .diskSize)
        }
    }

    private struct HostUser: Decodable {
        var rootful: Bool?

        enum CodingKeys: String, CodingKey { case rootful = "Rootful" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rootful = try? container.decodeIfPresent(Bool.self, forKey: .rootful)
        }
    }

    private struct ImagePath: Decodable {
        var path: String?
        var symlink: String?

        enum CodingKeys: String, CodingKey {
            case path = "Path"
            case symlink
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try? container.decodeIfPresent(String.self, forKey: .path)
            symlink = try? container.decodeIfPresent(String.self, forKey: .symlink)
        }
    }
}
