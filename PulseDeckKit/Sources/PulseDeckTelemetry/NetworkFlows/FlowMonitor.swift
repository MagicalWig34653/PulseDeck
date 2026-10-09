#if os(macOS)
import Foundation
import PulseDeckCore

/// STUB — replaced by the flows backend agent.
public actor FlowMonitor: TelemetryProvider {
    public init() {}
    public func capability() -> TelemetryCapability { .unsupported(.notImplemented) }
    public func sample(at instant: MonotonicInstant) -> MetricState<NetworkFlowsSnapshot> { .unavailable(.notImplemented) }
    public func invalidateBaselines() {}
}
#endif
