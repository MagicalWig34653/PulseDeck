#if os(macOS)
import Foundation
import PulseDeckCore

/// STUB — replaced by the VM backend agent.
public actor VMMonitor: TelemetryProvider {
    public init() {}
    public func capability() -> TelemetryCapability { .unsupported(.notImplemented) }
    public func sample(at instant: MonotonicInstant) -> MetricState<VirtualMachinesSnapshot> { .unavailable(.notImplemented) }
    public func invalidateBaselines() {}
}

public enum VMControlError: Error, Hashable, Sendable {
    /// The provider offers no way to do this.
    case unsupported
    /// The provider's command-line tool or app is gone.
    case providerUnavailable
    case failed(String)
}

/// STUB — replaced by the VM backend agent. Runs the provider's own tool once, on a user click.
public enum VMControl {
    public static func perform(_ action: VMAction, on machine: VirtualMachineSnapshot) async -> Result<Void, VMControlError> {
        .failure(.unsupported)
    }

    /// Applies new resources. For providers that need a stopped VM the UI stops it first and
    /// starts it again afterwards (`restartIfRunning`).
    public static func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool) async -> Result<Void, VMControlError> {
        .failure(.unsupported)
    }
}
#endif
