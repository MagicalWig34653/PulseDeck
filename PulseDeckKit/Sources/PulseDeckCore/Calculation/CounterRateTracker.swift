/// Tracks cumulative counters for a dynamic set of devices (network interfaces, disks) and
/// turns them into per-second rates (SPEC §16, §28).
///
/// Each device is identified by a `Key` (e.g. BSD name) plus a `generation` (interface index,
/// IORegistry entry ID). If the generation changes, the device was re-created and its old
/// baseline is discarded instead of producing a bogus delta.
public struct CounterRateTracker<Key: Hashable & Sendable>: Sendable {
    private struct Baseline: Sendable {
        var generation: UInt64
        var readings: [CounterReading]
    }

    /// Longest interval over which a rate is trusted. Three times the longest background
    /// interval (5 s): anything longer is a stall or an unreported sleep.
    public static var defaultMaximumGap: Duration { .seconds(15) }

    public let maximumGap: Duration
    private var baselines: [Key: Baseline] = [:]

    public init(maximumGap: Duration = Self.defaultMaximumGap) {
        self.maximumGap = maximumGap
    }

    /// Records new counter values for `key` and returns one rate per counter.
    public mutating func update(key: Key, generation: UInt64, counters: [UInt64], at instant: MonotonicInstant) -> [MetricState<Double>] {
        let readings = counters.map { CounterReading(value: $0, instant: instant) }
        defer { baselines[key] = Baseline(generation: generation, readings: readings) }

        guard let baseline = baselines[key],
              baseline.generation == generation,
              baseline.readings.count == readings.count
        else {
            return Array(repeating: .unavailable(.awaitingBaseline), count: counters.count)
        }
        return zip(baseline.readings, readings).map { previous, current in
            RateCalculator.rate(previous: previous, current: current, maximumGap: maximumGap)
        }
    }

    /// Forgets devices that are no longer present.
    public mutating func retainOnly(_ keys: Set<Key>) {
        baselines = baselines.filter { keys.contains($0.key) }
    }

    /// Forgets every baseline (e.g. after wake).
    public mutating func reset() {
        baselines.removeAll(keepingCapacity: true)
    }

    public var trackedKeys: Set<Key> { Set(baselines.keys) }
}
