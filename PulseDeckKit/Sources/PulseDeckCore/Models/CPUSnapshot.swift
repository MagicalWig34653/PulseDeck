import Foundation

/// Core type of a logical processor on Apple silicon.
public enum CoreType: Hashable, Sendable {
    case performance
    case efficiency
}

/// Static CPU description, read once at launch.
public struct CPUInfo: Hashable, Sendable {
    /// Marketing/model name, e.g. from `machdep.cpu.brand_string`. `nil` if unavailable.
    public var modelName: String?
    public var logicalProcessorCount: Int
    /// Physical core count, `nil` if not reliably available.
    public var physicalCoreCount: Int?
    /// Performance levels (P/E clusters) where the OS reports them.
    public var performanceLevels: [PerformanceLevel]
    /// Core type per logical processor index (`CoreTypeResolver`); empty when unknown, in which
    /// case the UI does not color cores by type.
    public var coreTypes: [CoreType]
    /// How `coreTypes` was determined; `nil` when it is empty.
    public var coreTypeSource: CoreTypeSource?
    /// Wall-clock boot time (`kern.boottime`), for uptime.
    public var bootTime: Date?

    public struct PerformanceLevel: Hashable, Sendable {
        public var name: String
        public var physicalCoreCount: Int
        public var logicalProcessorCount: Int

        public init(name: String, physicalCoreCount: Int, logicalProcessorCount: Int) {
            self.name = name
            self.physicalCoreCount = physicalCoreCount
            self.logicalProcessorCount = logicalProcessorCount
        }
    }

    public init(modelName: String?, logicalProcessorCount: Int, physicalCoreCount: Int?, performanceLevels: [PerformanceLevel], coreTypes: [CoreType] = [], coreTypeSource: CoreTypeSource? = nil, bootTime: Date? = nil) {
        self.modelName = modelName
        self.logicalProcessorCount = logicalProcessorCount
        self.physicalCoreCount = physicalCoreCount
        self.performanceLevels = performanceLevels
        self.coreTypes = coreTypes
        self.coreTypeSource = coreTypes.isEmpty ? nil : coreTypeSource
        self.bootTime = bootTime
    }

    /// Core type of logical processor `index`, `nil` if unknown.
    public func coreType(ofProcessor index: Int) -> CoreType? {
        coreTypes.indices.contains(index) ? coreTypes[index] : nil
    }
}

/// CPU utilization over the last sampling interval. Fractions are in `0...1`.
public struct CPUSnapshot: Hashable, Sendable {
    public var info: CPUInfo
    public var user: Double
    public var system: Double
    public var idle: Double
    public var cores: [CPUCoreSnapshot]

    public var total: Double { user + system }

    public init(info: CPUInfo, user: Double, system: Double, idle: Double, cores: [CPUCoreSnapshot]) {
        self.info = info
        self.user = user
        self.system = system
        self.idle = idle
        self.cores = cores
    }
}
