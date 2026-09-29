/// System memory pressure as reported by the OS.
public enum MemoryPressure: Hashable, Sendable {
    case normal
    case warning
    case critical

    /// Parses the dispatch-level value reported by the kernel (`NOTE_MEMORYSTATUS_PRESSURE_*`
    /// in xnu `sys/event_private.h`: normal = 0x1, warn = 0x2, critical = 0x4).
    public init?(dispatchLevel: UInt32) {
        switch dispatchLevel {
        case 0x1: self = .normal
        case 0x2: self = .warning
        case 0x4: self = .critical
        default: return nil
        }
    }
}

/// Swap file usage in bytes.
public struct SwapUsage: Hashable, Sendable {
    public var used: UInt64
    public var total: UInt64

    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
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
    /// Size of the data held by the compressor before compression
    /// (`total_uncompressed_pages_in_compressor` × page size). `compressed` is what it occupies.
    public var compressedOriginal: UInt64
    /// File-backed and purgeable memory the system can reclaim.
    public var cachedFiles: UInt64
    public var free: UInt64
    public var swap: MetricState<SwapUsage>
    /// Current pressure level. Source: undocumented sysctl `kern.memorystatus_vm_pressure_level`
    /// (approved; see TECHNICAL_LIMITATIONS.md L‑8).
    public var pressure: MetricState<MemoryPressure>

    /// `physicalTotal − used`.
    public var available: UInt64 { physicalTotal >= used ? physicalTotal - used : 0 }

    /// Original size ÷ compressed size, e.g. 3.2 means data shrank to under a third. `nil` when
    /// nothing is compressed.
    public var compressionRatio: Double? {
        compressed > 0 && compressedOriginal > 0 ? Double(compressedOriginal) / Double(compressed) : nil
    }

    /// Used fraction of physical memory in `0...1`.
    public var usedFraction: Double {
        physicalTotal > 0 ? Double(used) / Double(physicalTotal) : 0
    }

    public init(physicalTotal: UInt64, used: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64, compressedOriginal: UInt64 = 0, cachedFiles: UInt64, free: UInt64, swap: MetricState<SwapUsage>, pressure: MetricState<MemoryPressure>) {
        self.physicalTotal = physicalTotal
        self.used = used
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.compressedOriginal = compressedOriginal
        self.cachedFiles = cachedFiles
        self.free = free
        self.swap = swap
        self.pressure = pressure
    }
}
