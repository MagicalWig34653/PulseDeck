import Foundation

/// Chart history of virtual machines, fed once per VM snapshot (only while the Virtual Machines
/// section is visible). Values are host-side: what the VM's processes use on the Mac.
public struct VMHistory: Sendable {
    /// Series of a machine's history. A missing value is `nil` (a gap), never 0.
    public enum Series {
        /// Host CPU time as a fraction of one core (can exceed 1).
        public static let cpu = 0
        /// Resident memory of the VM's host processes (bytes).
        public static let memory = 1
        /// Disk read throughput (B/s).
        public static let diskRead = 2
        /// Disk write throughput (B/s).
        public static let diskWrite = 3
        public static let count = 4
    }

    /// Series of `aggregate`.
    public enum AggregateSeries {
        /// Sum of the host CPU of all VMs that are not stopped (fraction of one core).
        public static let cpu = 0
        /// Sum of their resident memory (bytes).
        public static let memory = 1
        public static let count = 2
    }

    /// Per VM (`VirtualMachineSnapshot.id`). Series: see `Series`.
    public private(set) var machines: [String: MetricHistory] = [:]
    /// All VMs together. Series: see `AggregateSeries`.
    public private(set) var aggregate = MetricHistory(seriesCount: AggregateSeries.count)

    public init() {}

    public func history(for id: String) -> MetricHistory? {
        machines[id]
    }

    /// Host CPU and resident memory of all VMs together.
    public struct Totals: Equatable, Sendable {
        /// Fraction of one core; `nil` if no machine reports it (never 0).
        public var cpu: Double?
        public var memoryBytes: Double?
    }

    /// Sums the readable usage of all VMs that are not stopped. Values a provider could not read
    /// contribute nothing; if none could be read, the total is `nil`.
    public static func totals(of machines: [VirtualMachineSnapshot]) -> Totals {
        var totals = Totals()
        for machine in machines where machine.state != .stopped {
            if let cpu = machine.usage.cpu.value { totals.cpu = (totals.cpu ?? 0) + cpu }
            if let memory = machine.usage.memoryBytes.value { totals.memoryBytes = (totals.memoryBytes ?? 0) + Double(memory) }
        }
        return totals
    }

    public mutating func ingest(_ snapshot: VirtualMachinesSnapshot, at timestamp: SampleTimestamp) {
        for machine in snapshot.machines {
            // A stopped VM has no processes: its line is a gap even if a provider left a value.
            let usage: VMUsage? = machine.state == .stopped ? nil : machine.usage
            machines[machine.id, default: MetricHistory(seriesCount: Series.count)].append(timestamp, values: [
                usage?.cpu.value,
                usage?.memoryBytes.value.map { Double($0) },
                usage?.diskReadBytesPerSecond.value,
                usage?.diskWriteBytesPerSecond.value,
            ])
        }
        let totals = Self.totals(of: snapshot.machines)
        aggregate.append(timestamp, values: [totals.cpu, totals.memoryBytes])
        prune(before: timestamp.monotonic.advanced(by: .zero - SystemHistory.window))
    }

    /// Drops histories of VMs that have not been listed for more than one window (deleted VMs),
    /// keeping memory bounded.
    private mutating func prune(before cutoff: MonotonicInstant) {
        let isStale: (MetricHistory) -> Bool = { ($0.latest?.timestamp ?? cutoff) < cutoff }
        if machines.values.contains(where: isStale) {
            machines = machines.filter { !isStale($0.value) }
        }
    }
}
