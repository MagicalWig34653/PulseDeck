/// Utilization of one logical processor over the last sampling interval.
/// All fractions are in `0...1`.
public struct CPUCoreSnapshot: Hashable, Sendable, Identifiable {
    /// Logical processor index as reported by the kernel.
    public var id: Int
    /// User time fraction (includes `nice` time).
    public var user: Double
    public var system: Double
    public var idle: Double

    public var total: Double { user + system }

    public init(id: Int, user: Double, system: Double, idle: Double) {
        self.id = id
        self.user = user
        self.system = system
        self.idle = idle
    }
}
