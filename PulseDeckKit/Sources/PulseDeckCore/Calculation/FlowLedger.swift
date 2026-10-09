import Foundation

/// STUB API (flows backend agent implements; keep these signatures). Accumulates bytes per
/// destination across flows — including flows that ended between samples.
public struct FlowLedger: Sendable {
    /// All destinations seen since the last `reset`, in no particular order.
    public private(set) var destinations: [DestinationTotals] = []
    public private(set) var totalBytesReceived: UInt64 = 0
    public private(set) var totalBytesSent: UInt64 = 0
    /// When recording started (first ingest) — "since" label in the UI.
    public private(set) var recordingSince: Date?
    /// Where the data comes from (the latest ingest).
    public private(set) var source: FlowSource?

    public init() {}
    public mutating func ingest(_ snapshot: NetworkFlowsSnapshot, at date: Date) {}
    public mutating func reset() {
        self = FlowLedger()
    }
}
