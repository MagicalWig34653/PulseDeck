/// Safe deltas between readings of cumulative counters (SPEC §28).
public enum CounterDelta {
    /// Delta of a 64-bit counter that is not expected to wrap in practice (e.g. `if_data64`
    /// byte counts, IOKit disk byte counts). A decrease means the counter was reset (interface
    /// re-created, driver re-instantiated), so there is no valid delta: returns `nil`.
    public static func monotonic(previous: UInt64, current: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }

    /// Delta of a 32-bit counter that wraps modulo 2³² (e.g. Mach CPU tick counters, which are
    /// `natural_t`). Wrapping subtraction is correct as long as fewer than 2³² increments
    /// happened between readings; `maximumPlausible` rejects deltas that exceed what could
    /// have happened in the elapsed time (e.g. a reset misread as a wrap).
    public static func wrapping32(previous: UInt32, current: UInt32, maximumPlausible: UInt32 = .max) -> UInt32? {
        let delta = current &- previous
        return delta <= maximumPlausible ? delta : nil
    }
}

/// One reading of a cumulative counter at a monotonic instant.
public struct CounterReading: Hashable, Sendable {
    public var value: UInt64
    public var instant: MonotonicInstant

    public init(value: UInt64, instant: MonotonicInstant) {
        self.value = value
        self.instant = instant
    }
}

/// Per-second rates from counter readings, using actual elapsed monotonic time (SPEC §16).
public enum RateCalculator {
    /// Rate in units per second between two readings of a 64-bit cumulative counter.
    ///
    /// - Returns: `.unavailable(.awaitingBaseline)` without a previous reading,
    ///   `.unavailable(.invalidDelta)` for non-positive elapsed time, an elapsed time above
    ///   `maximumGap` (sleep/stall) or a counter reset; otherwise the rate.
    public static func rate(
        previous: CounterReading?,
        current: CounterReading,
        maximumGap: Duration
    ) -> MetricState<Double> {
        guard let previous else { return .unavailable(.awaitingBaseline) }
        let elapsed = current.instant.nanoseconds(since: previous.instant)
        guard elapsed > 0, elapsed <= maximumGap.nanosecondsClamped else {
            return .unavailable(.invalidDelta)
        }
        guard let delta = CounterDelta.monotonic(previous: previous.value, current: current.value) else {
            return .unavailable(.invalidDelta)
        }
        let nanosecondsPerSecond = 1e9
        return .available(Double(delta) * nanosecondsPerSecond / Double(elapsed))
    }
}
