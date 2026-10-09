import Foundation

/// STUB — replaced by the VM UI agent. Per-VM chart history, fed once per VM snapshot.
public struct VMHistory: Sendable {
    public init() {}
    public mutating func ingest(_ snapshot: VirtualMachinesSnapshot, at timestamp: SampleTimestamp) {}
}
