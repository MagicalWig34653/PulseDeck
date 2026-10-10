#if os(macOS)
import Foundation
import PulseDeckCore

/// Result of running a vendor command-line tool.
public struct VMCommandResult: Sendable {
    public var exitStatus: Int32
    public var standardOutput: String
    public var standardError: String
    public var succeeded: Bool { exitStatus == 0 }
}

/// Runs a vendor tool once. Tools are looked up by name in Homebrew, /usr/local, /Applications
/// bundles … (never through a shell or `PATH` of the app). Used for user-initiated actions and,
/// only where a provider offers no readable files, for listing (throttled by the monitor).
public protocol VMCommandRunning: Sendable {
    /// `tool`: candidate executable names or absolute paths, tried in order, e.g.
    /// `["limactl", "/opt/homebrew/bin/limactl"]`. Returns `nil` when none exists.
    func run(tool candidates: [String], arguments: [String], timeout: Duration) async -> VMCommandResult?
}

/// What an adapter is told about the machine it runs on.
public struct VMEnvironment: Sendable {
    public var homeDirectory: String
    public var runner: any VMCommandRunning
    public init(homeDirectory: String, runner: any VMCommandRunning) {
        self.homeDirectory = homeDirectory
        self.runner = runner
    }
}

/// One VM provider. Implementations are thin: they find files / run a tool and hand text to
/// pure parsers in `PulseDeckCore` (which carry the unit tests). Listing reads files and the
/// process table; a vendor CLI is used for listing only if the provider has no readable files.
public protocol VMProviderAdapter: Sendable {
    var id: VMProviderID { get }

    /// How long `VMMonitor` reuses the previous `list` result before calling `list` again. Only
    /// adapters whose listing runs a vendor command (no readable files) return a value above
    /// `.zero`; the monitor still refreshes process-derived state and usage on every tick.
    var minimumListInterval: Duration { get }

    /// Cheap check (file-system / bundle lookups only, no process spawn): is the provider
    /// installed or in use? Returns its version if readable without running anything.
    func detect(in environment: VMEnvironment) -> VMProviderInstall?

    /// All VMs the provider manages. `processes` is the current host process table.
    func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord]

    func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError>

    /// Changes CPU / memory / disk. Only called when the VM's capabilities allow it. The UI has
    /// already stopped a VM whose provider `editRequiresStopped`; when `restartIfRunning` the
    /// adapter must start it again afterwards.
    func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError>
}

extension VMProviderAdapter {
    /// File-based listings are cheap: no throttling.
    public var minimumListInterval: Duration { .zero }
}

public struct VMProviderInstall: Sendable {
    public var version: String?
    /// Short remark shown with the provider, e.g. "read-only".
    public var note: String?
    public init(version: String? = nil, note: String? = nil) {
        self.version = version
        self.note = note
    }
}
#endif
