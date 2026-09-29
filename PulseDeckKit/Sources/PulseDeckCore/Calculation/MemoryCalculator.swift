/// Page counts from `host_statistics64(HOST_VM_INFO64)` (`vm_statistics64`).
public struct VMPageCounts: Hashable, Sendable {
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var wired: UInt64
    public var speculative: UInt64
    public var purgeable: UInt64
    /// Pages occupied by the compressor (`compressor_page_count`).
    public var compressor: UInt64
    /// Anonymous pages (`internal_page_count`).
    public var internalPages: UInt64
    /// File-backed pages (`external_page_count`).
    public var externalPages: UInt64
    /// Pages of data held by the compressor, before compression
    /// (`total_uncompressed_pages_in_compressor`).
    public var uncompressedInCompressor: UInt64

    public init(free: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, speculative: UInt64, purgeable: UInt64, compressor: UInt64, internalPages: UInt64, externalPages: UInt64, uncompressedInCompressor: UInt64 = 0) {
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.speculative = speculative
        self.purgeable = purgeable
        self.compressor = compressor
        self.internalPages = internalPages
        self.externalPages = externalPages
        self.uncompressedInCompressor = uncompressedInCompressor
    }
}

/// Derives the memory breakdown (SPEC §14). The formula is documented in
/// IMPLEMENTATION_PLAN.md §10 and matches Activity Monitor's definitions:
///
/// - App Memory  = (internal − purgeable) pages
/// - Used        = App Memory + Wired + Compressed
/// - Cached      = (external + purgeable) pages
/// - Free        = free pages (includes speculative pages)
public enum MemoryCalculator {
    public static func snapshot(
        physicalTotal: UInt64,
        pageSize: UInt64,
        pages: VMPageCounts,
        swap: MetricState<SwapUsage>,
        pressure: MetricState<MemoryPressure>
    ) -> MemorySnapshot {
        let appPages = pages.internalPages >= pages.purgeable ? pages.internalPages - pages.purgeable : 0
        let appMemory = appPages * pageSize
        let wired = pages.wired * pageSize
        let compressed = pages.compressor * pageSize
        let used = min(appMemory + wired + compressed, physicalTotal)
        return MemorySnapshot(
            physicalTotal: physicalTotal,
            used: used,
            appMemory: appMemory,
            wired: wired,
            compressed: compressed,
            compressedOriginal: pages.uncompressedInCompressor * pageSize,
            cachedFiles: (pages.externalPages + pages.purgeable) * pageSize,
            free: pages.free * pageSize,
            swap: swap,
            pressure: pressure
        )
    }
}
