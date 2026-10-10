/// Cumulative usage of one host process that belongs to a VM, as read from libproc.
public struct VMProcessSample: Hashable, Sendable {
    /// PID plus start time: a reused PID is a different identity and gets a fresh baseline.
    public var identity: ProcessIdentity
    /// Cumulative CPU time, resident/footprint memory and disk bytes, or why they are unreadable
    /// (`.permissionDenied` for another user's process).
    public var usage: Result<ProcessReading.Usage, UnavailableReasonError>

    public init(identity: ProcessIdentity, usage: Result<ProcessReading.Usage, UnavailableReasonError>) {
        self.identity = identity
        self.usage = usage
    }
}

/// Turns per-process cumulative samples of a VM's host processes into `VMUsage`.
///
/// Mirrors `ProcessUsageTracker`: baselines are keyed by `ProcessIdentity` and rebuilt from every
/// update, so processes that vanished are forgotten and a reused PID starts over. Rates use
/// `RateCalculator` (actual elapsed monotonic time; a counter that went backwards or a gap longer
/// than `maximumGap`, e.g. after sleep, yields `.invalidDelta`).
///
/// A VM usually consists of several processes (hostagent, hypervisor, helpers). Its figures are
/// the sums over the processes that could be read. A process that has just appeared contributes
/// from its second sample on; while *no* process has a valid delta the VM reports why
/// (`.awaitingBaseline` before `.invalidDelta` before an access error).
public struct VMUsageTracker: Sendable {
    private struct Baseline: Sendable {
        var cpu: CounterReading
        var read: CounterReading
        var written: CounterReading
    }

    private struct Rates {
        var cpu: MetricState<Double>
        var read: MetricState<Double>
        var write: MetricState<Double>
    }

    public let maximumGap: Duration
    private var baselines: [ProcessIdentity: Baseline] = [:]

    public init(maximumGap: Duration = CounterRateTracker<String>.defaultMaximumGap) {
        self.maximumGap = maximumGap
    }

    public var trackedCount: Int { baselines.count }

    /// - Parameter machines: samples per VM (key: the VM's id). A VM without processes is stopped
    ///   and gets `VMUsage.none`.
    /// - Returns: usage per key of `machines`.
    public mutating func update(machines: [String: [VMProcessSample]], at instant: MonotonicInstant) -> [String: VMUsage] {
        // Each process is evaluated once even when two VMs claim it.
        var rates: [ProcessIdentity: Rates] = [:]
        var next: [ProcessIdentity: Baseline] = [:]
        for sample in machines.values.joined() where rates[sample.identity] == nil {
            switch sample.usage {
            case .success(let usage):
                let current = Baseline(
                    cpu: CounterReading(value: usage.cpuTimeNanoseconds, instant: instant),
                    read: CounterReading(value: usage.diskBytesRead, instant: instant),
                    written: CounterReading(value: usage.diskBytesWritten, instant: instant)
                )
                let previous = baselines[sample.identity]
                let nanosecondsPerSecond = 1e9
                rates[sample.identity] = Rates(
                    // CPU nanoseconds per second of wall time = fraction of one core.
                    cpu: RateCalculator.rate(previous: previous?.cpu, current: current.cpu, maximumGap: maximumGap)
                        .map { $0 / nanosecondsPerSecond },
                    read: RateCalculator.rate(previous: previous?.read, current: current.read, maximumGap: maximumGap),
                    write: RateCalculator.rate(previous: previous?.written, current: current.written, maximumGap: maximumGap)
                )
                next[sample.identity] = current
            case .failure(let error):
                let unavailable: MetricState<Double> = .unavailable(error.reason)
                rates[sample.identity] = Rates(cpu: unavailable, read: unavailable, write: unavailable)
            }
        }
        baselines = next

        var result: [String: VMUsage] = [:]
        result.reserveCapacity(machines.count)
        for (key, samples) in machines {
            guard !samples.isEmpty else {
                result[key] = VMUsage.none
                continue
            }
            // De-duplicate identities inside one VM (a pid file and the process table can both
            // name the same process).
            var seen = Set<ProcessIdentity>()
            let unique = samples.filter { seen.insert($0.identity).inserted }
            let perProcess = unique.compactMap { rates[$0.identity] }
            var memory: [MetricState<UInt64>] = []
            for sample in unique {
                switch sample.usage {
                case .success(let usage): memory.append(.available(usage.physicalFootprintBytes))
                case .failure(let error): memory.append(.unavailable(error.reason))
                }
            }
            result[key] = VMUsage(
                cpu: Self.sum(perProcess.map(\.cpu)),
                memoryBytes: Self.sum(memory),
                diskReadBytesPerSecond: Self.sum(perProcess.map(\.read)),
                diskWriteBytesPerSecond: Self.sum(perProcess.map(\.write)),
                processCount: unique.count
            )
        }
        return result
    }

    /// Forgets the baselines of every process not in `identities`.
    public mutating func retainOnly(_ identities: Set<ProcessIdentity>) {
        baselines = baselines.filter { identities.contains($0.key) }
    }

    /// Forgets every baseline (after wake, or when sampling resumes).
    public mutating func reset() {
        baselines.removeAll(keepingCapacity: true)
    }

    // MARK: - Aggregation

    /// Sum of the available values; if there is none, the most useful reason.
    static func sum<T: AdditiveArithmetic & Sendable>(_ states: [MetricState<T>]) -> MetricState<T> {
        var total: T = .zero
        var anyValue = false
        var reasons: [UnavailableReason] = []
        for state in states {
            switch state {
            case .available(let value):
                total += value
                anyValue = true
            case .unavailable(let reason): reasons.append(reason)
            case .notSampled: break
            }
        }
        if anyValue { return .available(total) }
        if reasons.contains(.awaitingBaseline) { return .unavailable(.awaitingBaseline) }
        if reasons.contains(.invalidDelta) { return .unavailable(.invalidDelta) }
        if let first = reasons.first { return .unavailable(first) }
        return .unavailable(.notApplicable)
    }
}
