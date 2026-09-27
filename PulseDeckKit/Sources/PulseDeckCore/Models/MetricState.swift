/// Why a metric has no value. Typed so the UI can explain *why* something is
/// `Not Available` instead of showing `0` (SPEC §3, §28, §34).
public enum UnavailableReason: Hashable, Sendable {
    /// The collector for this metric has not been implemented yet.
    case notImplemented
    /// macOS offers no public API for this metric (see TECHNICAL_LIMITATIONS.md).
    case noPublicAPI
    /// The hardware does not provide this metric (e.g. no battery).
    case unsupportedHardware
    /// The OS refused access (e.g. `EPERM` for another user's process).
    case permissionDenied
    /// The device, interface or process disappeared.
    case sourceRemoved
    /// First sample of a delta-based metric: there is no baseline yet.
    case awaitingBaseline
    /// A delta could not be computed safely (counter reset/overflow, sleep gap, clock anomaly).
    case invalidDelta
    /// A transient failure of the underlying API (e.g. an IOKit call failing).
    case transientFailure(String)
    /// The metric does not apply to this device (e.g. free space of a disk without mounted
    /// volumes).
    case notApplicable
}

/// The value of one metric in one snapshot.
public enum MetricState<Value: Sendable>: Sendable {
    /// A valid measurement.
    case available(Value)
    /// No valid value exists for this sample.
    case unavailable(UnavailableReason)
    /// The metric was intentionally not sampled because nothing is observing it
    /// (demand-driven sampling, SPEC §7, §26). Distinct from `unavailable`.
    case notSampled

    public var value: Value? {
        if case .available(let value) = self { value } else { nil }
    }

    public var unavailableReason: UnavailableReason? {
        if case .unavailable(let reason) = self { reason } else { nil }
    }

    public func map<T: Sendable>(_ transform: (Value) -> T) -> MetricState<T> {
        switch self {
        case .available(let value): .available(transform(value))
        case .unavailable(let reason): .unavailable(reason)
        case .notSampled: .notSampled
        }
    }

    /// Chains a transform that can itself be unavailable (e.g. battery inside energy).
    public func flatMap<T: Sendable>(_ transform: (Value) -> MetricState<T>) -> MetricState<T> {
        switch self {
        case .available(let value): transform(value)
        case .unavailable(let reason): .unavailable(reason)
        case .notSampled: .notSampled
        }
    }
}

extension MetricState: Equatable where Value: Equatable {}
extension MetricState: Hashable where Value: Hashable {}

/// How a value was obtained (SPEC §19: distinguish reported, derived and unavailable;
/// SPEC §3: estimates must be marked).
public enum ValueProvenance: Hashable, Sendable {
    /// Reported directly by the OS/hardware.
    case reported
    /// Computed exactly from reported values (e.g. power = voltage × current).
    case derived
    /// An approximation; the UI must label it as an estimate.
    case estimated
}

/// A value together with its provenance.
public struct AttributedValue<Value: Sendable>: Sendable {
    public var value: Value
    public var provenance: ValueProvenance

    public init(_ value: Value, provenance: ValueProvenance) {
        self.value = value
        self.provenance = provenance
    }
}

extension AttributedValue: Equatable where Value: Equatable {}
extension AttributedValue: Hashable where Value: Hashable {}

/// Result of a collector's capability detection (SPEC §18, §34).
public enum TelemetryCapability: Hashable, Sendable {
    /// Not yet probed.
    case undetermined
    /// The metric can be collected on this machine.
    case supported
    /// The metric cannot be collected on this machine.
    case unsupported(UnavailableReason)
}
