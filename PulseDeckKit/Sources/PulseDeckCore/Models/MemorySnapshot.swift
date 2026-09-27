/// System memory pressure as reported by the OS.
public enum MemoryPressure: Hashable, Sendable {
    case normal
    case warning
    case critical
}

/// System memory state. All sizes in bytes.
///
/// The exact formula for `used` is documented in IMPLEMENTATION_PLAN.md §10 (SPEC §14):
/// `used = appMemory + wired + compressed`, where
/// `appMemory = (internal_page_count − purgeable_count) × pageSize`.
public struct MemorySnapshot: Hashable, Sendable {
    public var physicalTotal: UInt64
    public var used: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed and purgeable memory the system can reclaim.
    public var cachedFiles: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MetricState<MemoryPressure>

    /// `physicalTotal − used`.
    public var available: UInt64 { physicalTotal >= used ? physicalTotal - used : 0 }

    /// Used fraction of physical memory in `0...1`.
    public var usedFraction: Double {
        physicalTotal > 0 ? Double(used) / Double(physicalTotal) : 0
    }

    public init(physicalTotal: UInt64, used: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64, cachedFiles: UInt64, free: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MetricState<MemoryPressure>) {
        self.physicalTotal = physicalTotal
        self.used = used
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}
