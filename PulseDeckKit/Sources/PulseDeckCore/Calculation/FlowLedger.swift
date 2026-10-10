import Foundation

/// Accumulates bytes per destination (remote IP address) across flows — including flows that
/// ended between samples.
///
/// Crediting rules:
/// - Flow counters are cumulative since the flow began. Each ingest credits the *delta* since the
///   flow's previous reading, keyed by `NetworkFlow.id`.
/// - The first sight of a flow credits its full counters: the kernel counted them since the flow
///   began, and they were never credited before.
/// - `closed` flows credit their final delta and then stay as tombstones (so a late duplicate of
///   the same flow credits nothing twice).
/// - A counter that goes backwards means the ID now names another flow (or the counter was
///   reset): the baseline restarts at the new value and nothing is credited — never a negative
///   or invented amount. The same happens when a known ID shows up with a different remote
///   endpoint or transport.
/// - Flows without byte counters (`.unavailable`, the socket-table fallback) are counted as
///   flows, but their destinations keep `hasByteCounters == false` until a counted flow is seen,
///   so the UI shows "—" rather than "0 B".
///
/// Nothing is filtered: loopback, LAN and unspecified (listening / unconnected) remote addresses
/// are recorded too; the UI filters by `DestinationClassifier` scope.
///
/// Memory is bounded: at most `maximumDestinations` destinations (beyond that the least recently
/// seen, smallest ones are dropped; ledger-wide totals keep their bytes), `maximumPorts` port and
/// `maximumProcesses` process entries per destination (the smallest is dropped; destination
/// totals stay complete), and flow baselines expire after `baselineRetention` without a sighting.
public struct FlowLedger: Sendable {
    /// All destinations seen since the last `reset`, sorted by total bytes (descending), then
    /// address.
    public private(set) var destinations: [DestinationTotals] = []
    public private(set) var totalBytesReceived: UInt64 = 0
    public private(set) var totalBytesSent: UInt64 = 0
    /// When recording started (first ingest) — "since" label in the UI.
    public private(set) var recordingSince: Date?
    /// Where the data comes from (the latest ingest).
    public private(set) var source: FlowSource?

    public static let defaultMaximumDestinations = 4000
    public static let defaultMaximumPortsPerDestination = 24
    public static let defaultMaximumProcessesPerDestination = 24
    /// Baselines of flows not seen for this long are forgotten. Longer than any sampling gap
    /// that still matters, so a flow missing from one snapshot is not credited twice.
    public static let baselineRetention: TimeInterval = 600
    /// Hard bound on remembered flows (live + tombstones).
    public static let maximumBaselines = 100_000
    /// Rates are only reported for intervals up to this long. Three times the longest background
    /// interval (5 s), like `CounterRateTracker`: a longer gap is a stall, sleep, or the section
    /// having been closed, and an average over it is not a "current" rate.
    public static let maximumRateInterval: TimeInterval = 15

    let maximumDestinations: Int
    let maximumPorts: Int
    let maximumProcesses: Int

    private struct PortKey: Hashable {
        var transport: FlowTransport
        var port: UInt16
    }

    private struct Baseline {
        var transport: FlowTransport
        var remote: FlowEndpoint
        var received: UInt64?
        var sent: UInt64?
        var lastSeen: Date
    }

    private struct Accumulator {
        var totals: DestinationTotals
        var ports: [PortKey: PortTotals] = [:]
        var processes: [String: ProcessTotals] = [:]
    }

    /// Per-destination tallies of one ingest.
    private struct Tally {
        var activeFlows = 0
        var rateReceived: UInt64 = 0
        var rateSent: UInt64 = 0
    }

    private var baselines: [UInt64: Baseline] = [:]
    private var accumulators: [String: Accumulator] = [:]
    private var lastIngest: Date?
    private var lastPrune: Date?
    /// How often expired baselines are looked for (a full pass over every flow).
    static let pruneInterval: TimeInterval = 30

    public init() {
        self.init(maximumDestinations: Self.defaultMaximumDestinations)
    }

    init(maximumDestinations: Int, maximumPorts: Int = Self.defaultMaximumPortsPerDestination, maximumProcesses: Int = Self.defaultMaximumProcessesPerDestination) {
        self.maximumDestinations = max(1, maximumDestinations)
        self.maximumPorts = max(1, maximumPorts)
        self.maximumProcesses = max(1, maximumProcesses)
    }

    public mutating func ingest(_ snapshot: NetworkFlowsSnapshot, at date: Date) {
        if recordingSince == nil { recordingSince = date }
        source = snapshot.source

        let interval = lastIngest.map { date.timeIntervalSince($0) }
        let previousIngest = lastIngest
        var tallies: [String: Tally] = [:]
        var created: Set<String> = []

        for flow in snapshot.flows {
            credit(flow, isClosed: false, at: date, previousIngest: previousIngest, tallies: &tallies, created: &created)
        }
        for flow in snapshot.closed {
            credit(flow, isClosed: true, at: date, previousIngest: previousIngest, tallies: &tallies, created: &created)
        }

        let rateInterval: TimeInterval? = if let interval, interval > 0, interval <= Self.maximumRateInterval,
                                             snapshot.source != .socketTable { interval } else { nil }
        for address in Array(accumulators.keys) {
            let tally = tallies[address]
            accumulators[address]?.totals.activeFlowCount = tally?.activeFlows ?? 0
            guard let rateInterval,
                  !created.contains(address),
                  accumulators[address]?.totals.hasByteCounters == true
            else {
                accumulators[address]?.totals.receiveBytesPerSecond = nil
                accumulators[address]?.totals.sendBytesPerSecond = nil
                continue
            }
            accumulators[address]?.totals.receiveBytesPerSecond = Double(tally?.rateReceived ?? 0) / rateInterval
            accumulators[address]?.totals.sendBytesPerSecond = Double(tally?.rateSent ?? 0) / rateInterval
        }

        pruneBaselines(at: date)
        evictDestinations(keeping: Set(tallies.keys))
        rebuildDestinations(touched: tallies.keys)
        lastIngest = date
    }

    /// Forgets all destination totals ("Reset Totals"). Flow baselines are kept, so flows that
    /// are still open are credited only with what they transfer after the reset — not again with
    /// everything since they began. Recording restarts at the next ingest.
    public mutating func reset() {
        destinations = []
        totalBytesReceived = 0
        totalBytesSent = 0
        recordingSince = nil
        source = nil
        accumulators = [:]
    }

    // MARK: - Crediting

    private mutating func credit(_ flow: NetworkFlow, isClosed: Bool, at date: Date, previousIngest: Date?, tallies: inout [String: Tally], created: inout Set<String>) {
        let address = flow.remote.address
        let known = baselines[flow.id].flatMap { baseline in
            baseline.transport == flow.transport && baseline.remote == flow.remote ? baseline : nil
        }
        let isNewFlow = known == nil

        func delta(_ state: MetricState<UInt64>, previous: UInt64?) -> (credit: UInt64, value: UInt64?) {
            guard let value = state.value else { return (0, nil) }
            guard !isNewFlow else { return (value, value) }
            guard let previous else { return (value, value) }
            // Backwards: another flow under this ID, or a counter reset. Restart, credit nothing.
            return (value >= previous ? value - previous : 0, value)
        }
        let received = delta(flow.bytesReceived, previous: known?.received)
        let sent = delta(flow.bytesSent, previous: known?.sent)
        let hasCounters = received.value != nil || sent.value != nil

        baselines[flow.id] = Baseline(transport: flow.transport, remote: flow.remote,
                                      received: received.value ?? known?.received,
                                      sent: sent.value ?? known?.sent,
                                      lastSeen: date)

        if accumulators[address] == nil {
            accumulators[address] = Accumulator(totals: DestinationTotals(
                address: address, family: flow.family, firstSeen: date, lastSeen: date, hasByteCounters: false))
            created.insert(address)
        }
        // Taken out of the dictionary while mutated so its port/process tables are not copied.
        guard var accumulator = accumulators.removeValue(forKey: address) else { return }

        accumulator.totals.lastSeen = date
        accumulator.totals.bytesReceived &+= received.credit
        accumulator.totals.bytesSent &+= sent.credit
        if hasCounters { accumulator.totals.hasByteCounters = true }
        if isNewFlow { accumulator.totals.flowCount += 1 }
        totalBytesReceived &+= received.credit
        totalBytesSent &+= sent.credit

        let portKey = PortKey(transport: flow.transport, port: flow.remote.port)
        var port = accumulator.ports[portKey] ?? PortTotals(transport: flow.transport, port: flow.remote.port)
        port.bytesReceived &+= received.credit
        port.bytesSent &+= sent.credit
        if isNewFlow { port.flowCount += 1 }
        accumulator.ports[portKey] = port
        if accumulator.ports.count > maximumPorts {
            Self.dropSmallest(from: &accumulator.ports) { ($0.bytesReceived &+ $0.bytesSent, UInt64($0.flowCount)) }
        }

        if let processName = Self.processKey(of: flow) {
            var process = accumulator.processes[processName] ?? ProcessTotals(processName: processName)
            process.bytesReceived &+= received.credit
            process.bytesSent &+= sent.credit
            accumulator.processes[processName] = process
            if accumulator.processes.count > maximumProcesses {
                Self.dropSmallest(from: &accumulator.processes) { ($0.bytesReceived &+ $0.bytesSent, 0) }
            }
        }
        accumulators[address] = accumulator

        var tally = tallies[address] ?? Tally()
        if !isClosed { tally.activeFlows += 1 }
        // Bytes of a flow seen for the first time belong to the last interval only if the flow
        // started within it; otherwise they are history and would inflate the rate.
        let countsTowardsRate: Bool
        if !isNewFlow {
            countsTowardsRate = true
        } else if let previousIngest, let startedAt = flow.startedAt {
            countsTowardsRate = startedAt >= previousIngest
        } else {
            countsTowardsRate = false
        }
        if countsTowardsRate {
            tally.rateReceived &+= received.credit
            tally.rateSent &+= sent.credit
        }
        tallies[address] = tally
    }

    /// The name per-process totals are kept under: the process name, else its PID; flows without
    /// either are not attributed (the destination totals still include them).
    private static func processKey(of flow: NetworkFlow) -> String? {
        if let name = flow.processName, !name.isEmpty { return name }
        return flow.processID.map { "PID \($0)" }
    }

    /// Removes the entry with the smallest (bytes, secondary) value; ties go to the larger key
    /// description so the choice is deterministic.
    private static func dropSmallest<Key: Hashable, Value>(from dictionary: inout [Key: Value], by measure: (Value) -> (UInt64, UInt64)) {
        guard let smallest = dictionary.min(by: { lhs, rhs in
            let (left, right) = (measure(lhs.value), measure(rhs.value))
            if left != right { return left < right }
            return String(describing: lhs.key) > String(describing: rhs.key)
        }) else { return }
        dictionary.removeValue(forKey: smallest.key)
    }

    // MARK: - Bounds

    private mutating func pruneBaselines(at date: Date) {
        if let lastPrune, date.timeIntervalSince(lastPrune) < Self.pruneInterval, date >= lastPrune,
           baselines.count <= Self.maximumBaselines {
            return
        }
        lastPrune = date
        let cutoff = date.addingTimeInterval(-Self.baselineRetention)
        baselines = baselines.filter { $0.value.lastSeen >= cutoff }
        if baselines.count > Self.maximumBaselines {
            let excess = baselines.count - Self.maximumBaselines
            let oldest = baselines.sorted { lhs, rhs in
                lhs.value.lastSeen != rhs.value.lastSeen ? lhs.value.lastSeen < rhs.value.lastSeen : lhs.key < rhs.key
            }.prefix(excess)
            for (id, _) in oldest { baselines.removeValue(forKey: id) }
        }
    }

    /// Drops destinations beyond the cap: those not seen in this ingest first, least recently
    /// seen first, smallest totals first.
    private mutating func evictDestinations(keeping current: Set<String>) {
        guard accumulators.count > maximumDestinations else { return }
        let excess = accumulators.count - maximumDestinations
        let order = accumulators.values.map(\.totals).sorted { lhs, rhs in
            let (leftCurrent, rightCurrent) = (current.contains(lhs.address), current.contains(rhs.address))
            if leftCurrent != rightCurrent { return !leftCurrent }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen < rhs.lastSeen }
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes < rhs.totalBytes }
            return lhs.address < rhs.address
        }
        for totals in order.prefix(excess) {
            accumulators.removeValue(forKey: totals.address)
        }
    }

    /// Re-sorts the port and process breakdowns of the destinations credited in this ingest
    /// (the others did not change), then orders all destinations.
    private mutating func rebuildDestinations(touched: Dictionary<String, Tally>.Keys) {
        for address in touched {
            guard var accumulator = accumulators.removeValue(forKey: address) else { continue }
            accumulator.totals.ports = accumulator.ports.values.sorted { lhs, rhs in
                let (left, right) = (lhs.bytesReceived &+ lhs.bytesSent, rhs.bytesReceived &+ rhs.bytesSent)
                if left != right { return left > right }
                if lhs.flowCount != rhs.flowCount { return lhs.flowCount > rhs.flowCount }
                if lhs.transport.protocolNumber != rhs.transport.protocolNumber {
                    return lhs.transport.protocolNumber < rhs.transport.protocolNumber
                }
                return lhs.port < rhs.port
            }
            accumulator.totals.processes = accumulator.processes.values.sorted { lhs, rhs in
                let (left, right) = (lhs.bytesReceived &+ lhs.bytesSent, rhs.bytesReceived &+ rhs.bytesSent)
                return left != right ? left > right : lhs.processName < rhs.processName
            }
            accumulators[address] = accumulator
        }
        destinations = accumulators.values.map(\.totals)
        destinations.sort { lhs, rhs in
            lhs.totalBytes != rhs.totalBytes ? lhs.totalBytes > rhs.totalBytes : lhs.address < rhs.address
        }
    }
}
