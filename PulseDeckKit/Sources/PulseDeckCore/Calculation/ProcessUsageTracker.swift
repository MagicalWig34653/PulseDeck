/// Converts Mach absolute-time units to nanoseconds (`mach_timebase_info`).
///
/// `proc_pid_rusage` reports CPU times in Mach absolute-time units. On Apple silicon one unit is
/// 125/3 ns (timebase 125/3); on Intel it is 1 ns (timebase 1/1). See IMPLEMENTATION_PLAN.md R3.
public struct MachTimebase: Hashable, Sendable {
    public var numerator: UInt32
    public var denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// `ticks × numerator / denominator` without intermediate overflow; saturates at `UInt64.max`.
    /// Returns `nil` for an invalid timebase (zero denominator).
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64? {
        guard denominator > 0 else { return nil }
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        let divisor = UInt64(denominator)
        // The quotient overflows exactly when the high word is not below the divisor.
        guard product.high < divisor else { return .max }
        return divisor.dividingFullWidth((high: product.high, low: product.low)).quotient
    }
}

/// One process as read from libproc, before rates are computed.
public struct ProcessReading: Hashable, Sendable {
    /// Cumulative resource usage (`proc_pid_rusage`).
    public struct Usage: Hashable, Sendable {
        /// User + system CPU time, in nanoseconds.
        public var cpuTimeNanoseconds: UInt64
        /// `ri_phys_footprint`: the memory figure Activity Monitor shows.
        public var physicalFootprintBytes: UInt64
        public var diskBytesRead: UInt64
        public var diskBytesWritten: UInt64

        public init(cpuTimeNanoseconds: UInt64, physicalFootprintBytes: UInt64, diskBytesRead: UInt64, diskBytesWritten: UInt64) {
            self.cpuTimeNanoseconds = cpuTimeNanoseconds
            self.physicalFootprintBytes = physicalFootprintBytes
            self.diskBytesRead = diskBytesRead
            self.diskBytesWritten = diskBytesWritten
        }
    }

    public var identity: ProcessIdentity
    public var name: String
    public var path: String?
    public var userID: UInt32?
    /// Why `usage` is missing, e.g. `.permissionDenied` for another user's process.
    public var usage: Result<Usage, UnavailableReasonError>
    public var threadCount: Result<Int, UnavailableReasonError>

    public init(identity: ProcessIdentity, name: String, path: String?, userID: UInt32?, usage: Result<Usage, UnavailableReasonError>, threadCount: Result<Int, UnavailableReasonError>) {
        self.identity = identity
        self.name = name
        self.path = path
        self.userID = userID
        self.usage = usage
        self.threadCount = threadCount
    }
}

/// An `UnavailableReason` usable as the failure of a `Result`.
public struct UnavailableReasonError: Error, Hashable, Sendable {
    public var reason: UnavailableReason

    public init(_ reason: UnavailableReason) {
        self.reason = reason
    }
}

/// Turns successive process readings into CPU and disk rates (SPEC §21, §28).
///
/// Baselines are keyed by `ProcessIdentity` (PID + start time), so a reused PID starts a fresh
/// baseline instead of producing a delta against an unrelated process. Processes that vanish
/// are dropped on the next update, keeping memory bounded by the live process count.
public struct ProcessUsageTracker: Sendable {
    private struct Baseline: Sendable {
        var cpu: CounterReading
        var read: CounterReading
        var written: CounterReading
    }

    public let maximumGap: Duration
    private var baselines: [ProcessIdentity: Baseline] = [:]

    public init(maximumGap: Duration = CounterRateTracker<String>.defaultMaximumGap) {
        self.maximumGap = maximumGap
    }

    public var trackedCount: Int { baselines.count }

    public mutating func update(_ readings: [ProcessReading], at instant: MonotonicInstant) -> [ProcessSnapshot] {
        var next: [ProcessIdentity: Baseline] = [:]
        next.reserveCapacity(readings.count)
        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(readings.count)
        let nanosecondsPerSecond = 1e9

        for reading in readings {
            let cpu: MetricState<Double>
            let memory: MetricState<UInt64>
            let readRate: MetricState<Double>
            let writeRate: MetricState<Double>
            switch reading.usage {
            case .success(let usage):
                let current = Baseline(
                    cpu: CounterReading(value: usage.cpuTimeNanoseconds, instant: instant),
                    read: CounterReading(value: usage.diskBytesRead, instant: instant),
                    written: CounterReading(value: usage.diskBytesWritten, instant: instant)
                )
                let previous = baselines[reading.identity]
                // CPU nanoseconds per second of wall time = fraction of one logical processor.
                cpu = RateCalculator.rate(previous: previous?.cpu, current: current.cpu, maximumGap: maximumGap)
                    .map { $0 / nanosecondsPerSecond }
                readRate = RateCalculator.rate(previous: previous?.read, current: current.read, maximumGap: maximumGap)
                writeRate = RateCalculator.rate(previous: previous?.written, current: current.written, maximumGap: maximumGap)
                memory = .available(usage.physicalFootprintBytes)
                next[reading.identity] = current
            case .failure(let error):
                cpu = .unavailable(error.reason)
                memory = .unavailable(error.reason)
                readRate = .unavailable(error.reason)
                writeRate = .unavailable(error.reason)
            }
            let threads: MetricState<Int> = switch reading.threadCount {
            case .success(let count): .available(count)
            case .failure(let error): .unavailable(error.reason)
            }
            snapshots.append(ProcessSnapshot(
                identity: reading.identity,
                name: reading.name,
                path: reading.path,
                userID: reading.userID,
                cpu: cpu,
                memoryBytes: memory,
                threadCount: threads,
                diskReadBytesPerSecond: readRate,
                diskWriteBytesPerSecond: writeRate
            ))
        }
        baselines = next
        return snapshots
    }

    /// Forgets every baseline (after wake, or when sampling resumes).
    public mutating func reset() {
        baselines.removeAll(keepingCapacity: true)
    }
}
