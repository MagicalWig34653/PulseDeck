import Foundation

/// Pure logic for the minikube adapter.
///
/// Sources (minikube `master`): `pkg/minikube/config/types.go` (`ClusterConfig`: `Name`, `Memory` and
/// `DiskSize` in MB, `CPUs`, `Driver`, `KubernetesConfig`, `Nodes`), `pkg/minikube/config/profile.go`
/// (`MachineName`, `profiles/<name>/config.json`), `pkg/minikube/localpath/localpath.go`
/// (`$MINIKUBE_HOME/.minikube`, default `~/.minikube`, with `machines/<machine>/`),
/// `pkg/drivers/vfkit/vfkit.go` and `pkg/drivers/qemu/qemu.go` (pid files `vfkit.pid` / `qemu.pid` in
/// the machine directory; disk and socket paths below it) and `cmd/minikube/cmd/start_flags.go`
/// ("You cannot change the memory size / CPUs / disk size for an existing minikube cluster. Please
/// first delete the cluster.").
public enum MinikubeVMParsing {
    public enum DriverKind: Hashable, Sendable {
        /// vfkit, krunkit, qemu2, hyperkit: the hypervisor process and its files are known.
        case virtualMachine
        /// virtualbox, vmware, parallels, kvm2, hyperv: a VM, but state is not readable from files.
        case otherVirtualMachine
        /// docker, podman: the "node" is a container, there is no VM of its own.
        case container
        /// none, ssh: not a VM on this Mac.
        case notAVirtualMachine
    }

    public struct Profile: Hashable, Sendable {
        /// The name `minikube -p` takes (the profile directory name).
        public var name: String
        public var driver: String
        public var cpus: Int?
        public var memoryMiB: UInt64?
        public var diskMiB: UInt64?
        public var kubernetesVersion: String?
        public var containerRuntime: String?
        /// Machine names (directories below `machines/`) of all nodes.
        public var machineNames: [String]
        public var controlPlaneIP: String?

        public init(name: String, driver: String, cpus: Int? = nil, memoryMiB: UInt64? = nil, diskMiB: UInt64? = nil, kubernetesVersion: String? = nil, containerRuntime: String? = nil, machineNames: [String]? = nil, controlPlaneIP: String? = nil) {
            self.name = name
            self.driver = driver
            self.cpus = cpus
            self.memoryMiB = memoryMiB
            self.diskMiB = diskMiB
            self.kubernetesVersion = kubernetesVersion
            self.containerRuntime = containerRuntime
            self.machineNames = machineNames ?? [name]
            self.controlPlaneIP = controlPlaneIP
        }
    }

    public static func driverKind(_ driver: String) -> DriverKind {
        switch driver.lowercased() {
        case "vfkit", "krunkit", "qemu2", "qemu", "hyperkit": .virtualMachine
        case "virtualbox", "vmware", "vmwarefusion", "parallels", "kvm2", "hyperv": .otherVirtualMachine
        case "docker", "podman": .container
        default: .notAVirtualMachine
        }
    }

    // MARK: - Profile

    /// Parses `profiles/<directoryName>/config.json`. `nil` when it is not a cluster config.
    public static func parseProfile(_ data: Data, directoryName: String) -> Profile? {
        guard let config = try? JSONDecoder().decode(ClusterConfig.self, from: data), let driver = config.driver, !driver.isEmpty else { return nil }
        let clusterName = (config.name?.isEmpty == false ? config.name : nil) ?? directoryName
        let nodes = config.nodes ?? []
        // minikube's `MachineName`: the single node (or an unnamed one) keeps the profile name,
        // further nodes are "<profile>-<node name>" (e.g. "minikube-m02").
        let machineNames: [String] = nodes.isEmpty ? [clusterName] : nodes.map { node in
            let nodeName = node.name ?? ""
            return (nodes.count == 1 || nodeName.isEmpty) ? clusterName : "\(clusterName)-\(nodeName)"
        }
        let controlPlane = nodes.first(where: { $0.controlPlane == true }) ?? nodes.first
        return Profile(
            name: directoryName,
            driver: driver,
            cpus: config.cpus,
            memoryMiB: config.memory.flatMap { $0 > 0 ? UInt64($0) : nil },
            diskMiB: config.diskSize.flatMap { $0 > 0 ? UInt64($0) : nil },
            kubernetesVersion: nonEmpty(config.kubernetesConfig?.kubernetesVersion),
            containerRuntime: nonEmpty(config.kubernetesConfig?.containerRuntime),
            machineNames: machineNames,
            controlPlaneIP: nonEmpty(controlPlane?.ip)
        )
    }

    /// The pid file the driver writes into `machines/<machine>/`, where minikube's source documents one.
    public static func pidFileName(forDriver driver: String) -> String? {
        switch driver.lowercased() {
        case "vfkit": "vfkit.pid"
        case "qemu2", "qemu": "qemu.pid"
        default: nil
        }
    }

    /// A pid file holds the decimal process ID, possibly with a trailing newline.
    public static func parsePID(_ text: String) -> Int32? {
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    // MARK: - Host processes

    static func isHypervisorProcess(_ process: VMHostProcess, driver: String) -> Bool {
        switch driver.lowercased() {
        case "vfkit": process.name == "vfkit"
        case "krunkit": process.name == "krunkit"
        case "qemu2", "qemu": process.name.hasPrefix("qemu-system-")
        case "hyperkit": process.name == "hyperkit"
        default: false
        }
    }

    /// A hypervisor process of the profile's driver belongs to the profile when its pid is in the
    /// machine's pid file, or an argument points into `machines/<machine>/` (disk image, socket,
    /// pid file …). The process name check protects against a recycled pid.
    public static func hostProcessIDs(profile: Profile, pidFilePIDs: Set<Int32>, processes: [VMHostProcess]) -> [Int32] {
        let markers = profile.machineNames.map { "/machines/\($0)/" }
        return processes.filter { process in
            guard isHypervisorProcess(process, driver: profile.driver) else { return false }
            if pidFilePIDs.contains(process.pid) { return true }
            return process.arguments.contains { argument in markers.contains { argument.contains($0) } }
        }.map(\.pid).sorted()
    }

    // MARK: - Records

    /// Start / stop only for VM drivers whose state PulseDeck can read. Resources are fixed at
    /// creation, so nothing is editable (see the type's documentation).
    public static let virtualMachineCapabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true)

    public static let resourceEditingNote = "minikube cannot change CPUs, memory or disk of an existing cluster; delete it and run minikube start with new values."

    /// - Parameter pidFilePIDs: pids read from the machines' pid files, keyed by machine name.
    public static func records(profiles: [Profile], pidFilePIDs: [String: Int32], processes: [VMHostProcess]) -> [VMRecord] {
        profiles.compactMap { profile in
            let kind = driverKind(profile.driver)
            guard kind != .notAVirtualMachine else { return nil }

            var details = [VMDetail(label: "Driver", value: profile.driver)]
            if let version = profile.kubernetesVersion { details.append(VMDetail(label: "Kubernetes", value: version)) }
            if let runtime = profile.containerRuntime { details.append(VMDetail(label: "Container runtime", value: runtime)) }
            if profile.machineNames.count > 1 {
                details.append(VMDetail(label: "Nodes", value: "\(profile.machineNames.count) (CPU and memory are per node)"))
            }

            var state = VMState.unknown
            var processIDs: [Int32] = []
            var capabilities = VMCapabilities.readOnly
            var disk = profile.diskMiB.flatMap { multiplied($0, by: 1_048_576) }
            var ip = profile.controlPlaneIP

            switch kind {
            case .virtualMachine:
                let pids = Set(profile.machineNames.compactMap { pidFilePIDs[$0] })
                processIDs = hostProcessIDs(profile: profile, pidFilePIDs: pids, processes: processes)
                if !processIDs.isEmpty {
                    state = .running
                } else if processes.contains(where: { isHypervisorProcess($0, driver: profile.driver) && $0.arguments.isEmpty }) {
                    // A hypervisor of this kind runs whose arguments we could not read: it may be ours.
                    state = .unknown
                    details.append(VMDetail(label: "State", value: "A \(profile.driver) process whose arguments cannot be read is running, so it is unclear whether this cluster is up."))
                } else {
                    state = .stopped
                }
                capabilities = virtualMachineCapabilities
                if state != .running { ip = nil }
            case .otherVirtualMachine:
                details.append(VMDetail(label: "State", value: "The \(profile.driver) driver keeps its state in the hypervisor; see that provider for the VM. Read-only here."))
                ip = nil
            case .container:
                details.append(VMDetail(label: "Runtime", value: "Container driver: the cluster runs as a container (\(profile.driver)), not as its own VM. Read-only."))
                // The disk size of a container node is not enforced by the driver.
                disk = nil
                ip = nil
            case .notAVirtualMachine:
                return nil
            }
            details.append(VMDetail(label: "Resources", value: resourceEditingNote))

            return VMRecord(
                nativeID: profile.name,
                name: profile.name,
                state: state,
                guestOS: "Linux",
                architecture: nil,
                resources: VMResources(cpus: profile.cpus, memoryBytes: profile.memoryMiB.flatMap { multiplied($0, by: 1_048_576) }, diskBytes: disk),
                ipAddress: ip,
                startedAt: nil,
                hostProcessIDs: processIDs,
                details: details,
                capabilities: capabilities
            )
        }
    }

    // MARK: - Actions

    /// The profile name of a snapshot id `"minikube:<profile>"`.
    public static func profileName(fromVMID id: String) -> String {
        let prefix = "minikube:"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// `minikube start|stop -p <profile>`; restart is stop followed by start.
    public static func actionCommands(_ action: VMAction, profile: String) -> [[String]] {
        switch action {
        case .start: [["start", "-p", profile]]
        case .stop: [["stop", "-p", profile]]
        case .restart: [["stop", "-p", profile], ["start", "-p", profile]]
        }
    }

    // MARK: - Decoding

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private static func multiplied(_ value: UInt64, by factor: UInt64) -> UInt64? {
        let (product, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? nil : product
    }

    private struct ClusterConfig: Decodable {
        var name: String?
        var memory: Int?
        var cpus: Int?
        var diskSize: Int?
        var driver: String?
        var kubernetesConfig: KubernetesConfig?
        var nodes: [Node]?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case memory = "Memory"
            case cpus = "CPUs"
            case diskSize = "DiskSize"
            case driver = "Driver"
            case kubernetesConfig = "KubernetesConfig"
            case nodes = "Nodes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            memory = try? container.decodeIfPresent(Int.self, forKey: .memory)
            cpus = try? container.decodeIfPresent(Int.self, forKey: .cpus)
            diskSize = try? container.decodeIfPresent(Int.self, forKey: .diskSize)
            driver = try? container.decodeIfPresent(String.self, forKey: .driver)
            kubernetesConfig = try? container.decodeIfPresent(KubernetesConfig.self, forKey: .kubernetesConfig)
            nodes = try? container.decodeIfPresent([Node].self, forKey: .nodes)
        }
    }

    private struct KubernetesConfig: Decodable {
        var kubernetesVersion: String?
        var containerRuntime: String?

        enum CodingKeys: String, CodingKey {
            case kubernetesVersion = "KubernetesVersion"
            case containerRuntime = "ContainerRuntime"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kubernetesVersion = try? container.decodeIfPresent(String.self, forKey: .kubernetesVersion)
            containerRuntime = try? container.decodeIfPresent(String.self, forKey: .containerRuntime)
        }
    }

    private struct Node: Decodable {
        var name: String?
        var ip: String?
        var controlPlane: Bool?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case ip = "IP"
            case controlPlane = "ControlPlane"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            ip = try? container.decodeIfPresent(String.self, forKey: .ip)
            controlPlane = try? container.decodeIfPresent(Bool.self, forKey: .controlPlane)
        }
    }
}
