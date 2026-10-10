import Foundation

/// The VM providers PulseDeck knows. Raw values are stable (used in `VirtualMachineSnapshot.id`).
public enum VMProviderID: String, CaseIterable, Hashable, Sendable {
    case colima
    case lima
    case finch
    case rancherDesktop
    case orbstack
    case dockerDesktop
    case tart
    case utm
    case parallels
    case vmwareFusion
    case virtualBox
    case anka
    case multipass
    case podman
    case minikube
    case vagrant
    case qemu

    public var displayName: String {
        switch self {
        case .colima: "Colima"
        case .lima: "Lima"
        case .finch: "Finch"
        case .rancherDesktop: "Rancher Desktop"
        case .orbstack: "OrbStack"
        case .dockerDesktop: "Docker Desktop"
        case .tart: "Tart"
        case .utm: "UTM"
        case .parallels: "Parallels Desktop"
        case .vmwareFusion: "VMware Fusion"
        case .virtualBox: "VirtualBox"
        case .anka: "Anka"
        case .multipass: "Multipass"
        case .podman: "Podman Machine"
        case .minikube: "minikube"
        case .vagrant: "Vagrant"
        case .qemu: "QEMU"
        }
    }
}

/// One process of the host, as far as attributing it to a VM needs it. Built from libproc and
/// `sysctl(KERN_PROCARGS2)` by the telemetry module; providers match VMs against it by name,
/// executable path and arguments (e.g. `qemu-system-aarch64 -name colima -m 2048 -smp 2`).
public struct VMHostProcess: Hashable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// Executable file name without directories.
    public var name: String
    public var executablePath: String?
    /// argv without the executable (arguments the process was started with), possibly empty
    /// when the kernel refused to return them.
    public var arguments: [String]

    public init(pid: Int32, parentPID: Int32, name: String, executablePath: String? = nil, arguments: [String] = []) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// A VM as a provider describes it, before host resource usage is attached (`VMUsageTracker`).
public struct VMRecord: Hashable, Sendable {
    /// Provider-specific stable identifier (name, UUID, path …).
    public var nativeID: String
    public var name: String
    public var state: VMState
    public var guestOS: String?
    public var architecture: String?
    public var resources: VMResources
    public var ipAddress: String?
    public var startedAt: Date?
    /// Host processes that run this VM, matched by the provider.
    public var hostProcessIDs: [Int32]
    public var details: [VMDetail]
    public var capabilities: VMCapabilities

    public init(nativeID: String, name: String, state: VMState, guestOS: String? = nil, architecture: String? = nil, resources: VMResources = VMResources(), ipAddress: String? = nil, startedAt: Date? = nil, hostProcessIDs: [Int32] = [], details: [VMDetail] = [], capabilities: VMCapabilities = .readOnly) {
        self.nativeID = nativeID
        self.name = name
        self.state = state
        self.guestOS = guestOS
        self.architecture = architecture
        self.resources = resources
        self.ipAddress = ipAddress
        self.startedAt = startedAt
        self.hostProcessIDs = hostProcessIDs
        self.details = details
        self.capabilities = capabilities
    }
}
