/// Decides how often, and which metrics, the engine samples (SPEC §6, §7, §26).
public struct SamplingPolicy: Hashable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// Main window visible: high-resolution sampling.
        case foreground
        /// Menu bar only (window closed or occluded): reduced sampling.
        case background
        /// System asleep: no sampling at all.
        case suspended
    }

    /// Allowed background interval range from SPEC §7 ("initially 2–5 seconds").
    public static let backgroundIntervalRange: ClosedRange<Duration> = .seconds(2) ... .seconds(5)
    /// SPEC §6 default foreground interval.
    public static let defaultForegroundInterval: Duration = .seconds(1)
    public static let defaultBackgroundInterval: Duration = .seconds(3)
    /// Fraction of the interval the timer may be deferred so the OS can coalesce wakeups.
    public static let timerToleranceFraction = 0.1

    public var mode: Mode
    public var foregroundInterval: Duration
    public var backgroundInterval: Duration {
        didSet { backgroundInterval = Self.clampBackground(backgroundInterval) }
    }
    /// Optional metrics someone is currently observing. `MetricKind.alwaysSampled` are
    /// sampled regardless.
    public var demand: Set<MetricKind>

    public init(
        mode: Mode = .foreground,
        foregroundInterval: Duration = SamplingPolicy.defaultForegroundInterval,
        backgroundInterval: Duration = SamplingPolicy.defaultBackgroundInterval,
        demand: Set<MetricKind> = []
    ) {
        self.mode = mode
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = Self.clampBackground(backgroundInterval)
        self.demand = demand
    }

    /// Time between samples, or `nil` when sampling is suspended.
    public var interval: Duration? {
        switch mode {
        case .foreground: foregroundInterval
        case .background: backgroundInterval
        case .suspended: nil
        }
    }

    /// Timer tolerance passed to `Task.sleep` to allow wakeup coalescing.
    public var tolerance: Duration? {
        interval.map { $0 * Self.timerToleranceFraction }
    }

    /// Largest elapsed time between two samples for which a counter delta is still trusted.
    /// Anything longer (sleep, stalled process) yields `.invalidDelta` instead of a rate
    /// averaged over an unknown period (SPEC §27, §28).
    public var maximumSampleGap: Duration {
        let minimumGap: Duration = .seconds(10)
        let gapMultiplier = 3
        guard let interval else { return minimumGap }
        return max(interval * gapMultiplier, minimumGap)
    }

    /// Whether `kind` should be collected on the next tick.
    public func shouldSample(_ kind: MetricKind) -> Bool {
        guard mode != .suspended else { return false }
        return MetricKind.alwaysSampled.contains(kind) || demand.contains(kind)
    }

    private static func clampBackground(_ interval: Duration) -> Duration {
        min(max(interval, backgroundIntervalRange.lowerBound), backgroundIntervalRange.upperBound)
    }
}
