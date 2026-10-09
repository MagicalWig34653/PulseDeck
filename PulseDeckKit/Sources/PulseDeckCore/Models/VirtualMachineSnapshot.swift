import Foundation

/// Lifecycle state of a virtual machine as reported by its provider.
public enum VMState: String, Hashable, Sendable {
    case running
    case stopped
    case paused
    case suspended
    case starting
    case stopping
    case unknown

    public var isRunning: Bool { self == .running }
}

/// Start / stop / restart requests (`VMControl` in the telemetry module performs them).
public enum VMAction: String, CaseIterable, Hashable, Sendable {
    case start
    case stop
    case restart
}

/// Configured resources of a VM. `nil` means the provider does not expose that value.
public struct VMResources: Hashable, Sendable {
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var diskBytes: UInt64?

    public init(cpus: Int? = nil, memoryBytes: UInt64? = nil, diskBytes: UInt64? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

/// What the user may do with a VM through PulseDeck (decided per provider, never guessed).
public struct VMCapabilities: Hashable, Sendable {
    public var canStart: Bool
    public var canStop: Bool
    public var canRestart: Bool
    public var canEditCPUs: Bool
    public var canEditMemory: Bool
    public var canEditDisk: Bool
    /// The provider only applies resource changes to a stopped VM (the UI says so and offers
    /// to stop it first).
    public var editRequiresStopped: Bool
    /// Virtual disks can be enlarged but never shrunk.
    public var diskCanOnlyGrow: Bool

    public init(canStart: Bool = false, canStop: Bool = false, canRestart: Bool = false, canEditCPUs: Bool = false, canEditMemory: Bool = false, canEditDisk: Bool = false, editRequiresStopped: Bool = true, diskCanOnlyGrow: Bool = true) {
        self.canStart = canStart
        self.canStop = canStop
        self.canRestart = canRestart
        self.canEditCPUs = canEditCPUs
        self.canEditMemory = canEditMemory
        self.canEditDisk = canEditDisk
        self.editRequiresStopped = editRequiresStopped
        self.diskCanOnlyGrow = diskCanOnlyGrow
    }

    public var canEditAnything: Bool { canEditCPUs || canEditMemory || canEditDisk }

    /// Nothing can be done; the VM is only listed and monitored.
    public static let readOnly = VMCapabilities()
}

/// Host-side resource use of a running VM: what the processes that run it consume on the Mac.
/// (Guest-internal use is not readable without an agent in the guest.)
public struct VMUsage: Hashable, Sendable {
    /// CPU time of all host processes of the VM as a fraction of one host core (can exceed 1).
    public var cpu: MetricState<Double>
    /// Resident memory of those processes.
    public var memoryBytes: MetricState<UInt64>
    public var diskReadBytesPerSecond: MetricState<Double>
    public var diskWriteBytesPerSecond: MetricState<Double>
    public var processCount: Int

    public init(cpu: MetricState<Double> = .unavailable(.notApplicable), memoryBytes: MetricState<UInt64> = .unavailable(.notApplicable), diskReadBytesPerSecond: MetricState<Double> = .unavailable(.notApplicable), diskWriteBytesPerSecond: MetricState<Double> = .unavailable(.notApplicable), processCount: Int = 0) {
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.processCount = processCount
    }

    public static let none = VMUsage()
}

/// One labelled fact shown in a VM's detail pane (runtime, VM type, mounts, location …).
public struct VMDetail: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct VirtualMachineSnapshot: Hashable, Sendable, Identifiable {
    /// `"<providerID>:<native identifier>"`, stable across samples.
    public var id: String
    /// `VMProviderID` raw value, e.g. `colima`.
    public var providerID: String
    /// Display name of the provider, e.g. "Colima".
    public var providerName: String
    public var name: String
    public var state: VMState
    /// "Linux", "macOS", "Windows" …
    public var guestOS: String?
    /// "arm64", "x86_64".
    public var architecture: String?
    /// Configured resources (what the user can edit).
    public var resources: VMResources
    public var usage: VMUsage
    public var ipAddress: String?
    public var startedAt: Date?
    public var hostProcessIDs: [Int32]
    public var details: [VMDetail]
    public var capabilities: VMCapabilities

    public init(id: String, providerID: String, providerName: String, name: String, state: VMState, guestOS: String? = nil, architecture: String? = nil, resources: VMResources = VMResources(), usage: VMUsage = .none, ipAddress: String? = nil, startedAt: Date? = nil, hostProcessIDs: [Int32] = [], details: [VMDetail] = [], capabilities: VMCapabilities = .readOnly) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.name = name
        self.state = state
        self.guestOS = guestOS
        self.architecture = architecture
        self.resources = resources
        self.usage = usage
        self.ipAddress = ipAddress
        self.startedAt = startedAt
        self.hostProcessIDs = hostProcessIDs
        self.details = details
        self.capabilities = capabilities
    }
}

/// A VM provider that was found on this Mac, with the number of VMs it manages.
public struct VMProviderStatus: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String?
    public var machineCount: Int
    /// Short remark, e.g. "read-only: UTM has no scripting API for configuration".
    public var note: String?

    public init(id: String, name: String, version: String? = nil, machineCount: Int, note: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.machineCount = machineCount
        self.note = note
    }
}

public struct VirtualMachinesSnapshot: Hashable, Sendable {
    /// Providers that are installed (even with zero VMs).
    public var providers: [VMProviderStatus]
    public var machines: [VirtualMachineSnapshot]

    public init(providers: [VMProviderStatus], machines: [VirtualMachineSnapshot]) {
        self.providers = providers
        self.machines = machines
    }
}
