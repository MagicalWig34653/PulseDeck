/// Cumulative scheduler ticks of one logical processor, as reported by
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` (`cpu_ticks[CPU_STATE_MAX]`, each a 32-bit
/// `natural_t` that wraps modulo 2³²).
public struct CPUTicks: Hashable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Computes CPU utilization from two tick readings (SPEC §13: deltas between cumulative
/// counters).
public enum CPUUsageCalculator {
    /// - Returns: `.unavailable(.invalidDelta)` if the processor count changed or no ticks
    ///   elapsed; otherwise per-core and aggregate fractions. `nice` time counts as user time.
    public static func snapshot(info: CPUInfo, previous: [CPUTicks], current: [CPUTicks]) -> MetricState<CPUSnapshot> {
        guard !current.isEmpty, previous.count == current.count else {
            return .unavailable(.invalidDelta)
        }

        var cores: [CPUCoreSnapshot] = []
        cores.reserveCapacity(current.count)
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0

        for index in current.indices {
            let before = previous[index]
            let after = current[index]
            // Wrapping subtraction handles the 32-bit rollover of each tick counter.
            let user = UInt64(CounterDelta.wrapping32(previous: before.user, current: after.user) ?? 0)
                + UInt64(CounterDelta.wrapping32(previous: before.nice, current: after.nice) ?? 0)
            let system = UInt64(CounterDelta.wrapping32(previous: before.system, current: after.system) ?? 0)
            let idle = UInt64(CounterDelta.wrapping32(previous: before.idle, current: after.idle) ?? 0)
            let total = user + system + idle
            guard total > 0 else {
                return .unavailable(.invalidDelta)
            }
            cores.append(CPUCoreSnapshot(
                id: index,
                user: Double(user) / Double(total),
                system: Double(system) / Double(total),
                idle: Double(idle) / Double(total)
            ))
            totalUser += user
            totalSystem += system
            totalIdle += idle
        }

        let total = Double(totalUser + totalSystem + totalIdle)
        return .available(CPUSnapshot(
            info: info,
            user: Double(totalUser) / total,
            system: Double(totalSystem) / total,
            idle: Double(totalIdle) / total,
            cores: cores
        ))
    }
}
