/// Frequency of one CPU cluster over the last sampling interval.
///
/// Source: residency in each performance state from the private IOReport library ("CPU Stats" →
/// "CPU Complex Performance States"), weighted by the state frequencies from the IORegistry
/// (`pmgr` voltage-state tables). Approved by the product owner as a labelled private source with
/// fallback (TECHNICAL_LIMITATIONS.md L‑11).
public struct ClusterFrequency: Hashable, Sendable, Identifiable {
    /// IOReport channel name, e.g. "ECPU", "PCPU", "PCPU1".
    public var id: String
    public var coreType: CoreType?
    /// Average frequency while the cluster was running, in Hz; `nil` if it was idle the whole
    /// interval (never reported as 0 Hz).
    public var activeFrequencyHz: Double?
    /// Share of the interval the cluster was running (not idle/off), `0...1`.
    public var activeFraction: Double
    /// Highest frequency in the cluster's state table, in Hz.
    public var maximumFrequencyHz: Double?

    public init(id: String, coreType: CoreType?, activeFrequencyHz: Double?, activeFraction: Double, maximumFrequencyHz: Double?) {
        self.id = id
        self.coreType = coreType
        self.activeFrequencyHz = activeFrequencyHz
        self.activeFraction = activeFraction
        self.maximumFrequencyHz = maximumFrequencyHz
    }
}

public struct CPUFrequencySnapshot: Hashable, Sendable {
    public var clusters: [ClusterFrequency]

    public init(clusters: [ClusterFrequency]) {
        self.clusters = clusters
    }
}
