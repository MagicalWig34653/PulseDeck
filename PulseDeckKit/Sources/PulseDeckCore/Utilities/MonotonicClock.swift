/// A point on the monitor's monotonic timeline, in nanoseconds since the clock's
/// reference point.
///
/// Monotonic time is used for every delta/rate calculation (SPEC §6) because wall-clock
/// time can jump (NTP, manual changes, time zones). Wall-clock `Date`s are stored next to
/// samples for display only.
public struct MonotonicInstant: Hashable, Comparable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Signed elapsed time from `earlier` to `self`, in nanoseconds.
    public func nanoseconds(since earlier: MonotonicInstant) -> Int64 {
        if nanoseconds >= earlier.nanoseconds {
            return Int64(clamping: nanoseconds - earlier.nanoseconds)
        } else {
            return -Int64(clamping: earlier.nanoseconds - nanoseconds)
        }
    }

    public func advanced(by duration: Duration) -> MonotonicInstant {
        let delta = duration.nanosecondsClamped
        if delta >= 0 {
            return MonotonicInstant(nanoseconds: nanoseconds &+ UInt64(delta))
        } else {
            let magnitude = UInt64(delta.magnitude)
            return MonotonicInstant(nanoseconds: nanoseconds >= magnitude ? nanoseconds - magnitude : 0)
        }
    }
}

/// Source of monotonic instants. Injected so tests can control time (SPEC §38).
public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
}

/// Production clock backed by `ContinuousClock`.
///
/// On Darwin `ContinuousClock` is `mach_continuous_time`, which keeps advancing while the
/// machine sleeps. That is deliberate: after a sleep the elapsed time between two samples is
/// large, so a rate computed across the sleep would be too *small*, never a spike — and the
/// engine additionally rejects deltas whose elapsed time exceeds the policy's maximum gap
/// (SPEC §27).
public struct SystemMonotonicClock: MonotonicClock {
    private let reference: ContinuousClock.Instant

    public init() {
        reference = ContinuousClock.now
    }

    public func now() -> MonotonicInstant {
        let elapsed = reference.duration(to: ContinuousClock.now).nanosecondsClamped
        return MonotonicInstant(nanoseconds: UInt64(max(elapsed, 0)))
    }
}

extension Duration {
    /// Whole nanoseconds, saturating at `Int64` bounds (~292 years).
    public var nanosecondsClamped: Int64 {
        let (seconds, attoseconds) = components
        let nanosPerSecond: Int64 = 1_000_000_000
        let attosPerNano: Int64 = 1_000_000_000
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: nanosPerSecond)
        if overflow {
            return seconds < 0 ? .min : .max
        }
        let (sum, sumOverflow) = scaled.addingReportingOverflow(attoseconds / attosPerNano)
        if sumOverflow {
            return scaled < 0 ? .min : .max
        }
        return sum
    }

    /// The duration expressed in (fractional) seconds.
    public var secondsDouble: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
