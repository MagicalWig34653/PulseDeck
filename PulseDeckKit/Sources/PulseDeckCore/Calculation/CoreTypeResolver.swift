import Foundation

/// One `IODeviceTree:/cpus/cpuN` node as read by the telemetry layer. Every field is optional:
/// the properties are undocumented and differ between chip generations.
public struct DeviceTreeCPU: Hashable, Sendable {
    /// `logical-cpu-id`.
    public var logicalID: Int?
    /// `cpu-id`.
    public var cpuID: Int?
    /// Node name, e.g. `cpu12`.
    public var name: String?
    /// `cluster-type`, e.g. `E` or `P`.
    public var clusterType: String?

    public init(logicalID: Int? = nil, cpuID: Int? = nil, name: String? = nil, clusterType: String? = nil) {
        self.logicalID = logicalID
        self.cpuID = cpuID
        self.name = name
        self.clusterType = clusterType
    }
}

/// Where the per-processor core types came from.
public enum CoreTypeSource: Hashable, Sendable {
    /// The device tree names each processor's cluster type.
    case deviceTree
    /// Inferred from the per-type core counts (`hw.perflevelN.logicalcpu`, documented) and the
    /// numbering macOS uses on Apple silicon: efficiency cores first, then performance cores.
    case performanceLevelOrder
}

/// Core type per logical processor index (for the P/E badges and the Core Types chart).
public enum CoreTypeResolver {
    /// Device tree first; if it is incomplete, the order of the performance levels. `nil` if
    /// neither yields a type for every processor (the UI then shows no core types).
    public static func resolve(
        deviceTree: [DeviceTreeCPU],
        levels: [CPUInfo.PerformanceLevel],
        logicalCount: Int
    ) -> (types: [CoreType], source: CoreTypeSource)? {
        guard logicalCount > 0 else { return nil }
        if let types = fromDeviceTree(deviceTree, logicalCount: logicalCount) {
            return (types, .deviceTree)
        }
        if let types = fromPerformanceLevels(levels, logicalCount: logicalCount) {
            return (types, .performanceLevelOrder)
        }
        return nil
    }

    static func fromDeviceTree(_ cpus: [DeviceTreeCPU], logicalCount: Int) -> [CoreType]? {
        var types: [Int: CoreType] = [:]
        for cpu in cpus {
            guard let id = cpu.logicalID ?? cpu.cpuID ?? cpu.name.flatMap(index(inNodeName:)),
                  let type = cpu.clusterType.flatMap(coreType(ofClusterType:)),
                  types.updateValue(type, forKey: id) == nil
            else { return nil }
        }
        guard types.count == logicalCount else { return nil }
        let ordered = (0..<logicalCount).compactMap { types[$0] }
        return ordered.count == logicalCount ? ordered : nil
    }

    /// Two levels only (Apple silicon with P- and E-cores): `hw.perflevel0` is the faster one,
    /// `hw.perflevel1` must be the efficiency level, and together they cover every processor.
    static func fromPerformanceLevels(_ levels: [CPUInfo.PerformanceLevel], logicalCount: Int) -> [CoreType]? {
        guard levels.count == 2,
              levels[1].name.caseInsensitiveCompare("Efficiency") == .orderedSame,
              levels[0].logicalProcessorCount > 0, levels[1].logicalProcessorCount > 0,
              levels[0].logicalProcessorCount + levels[1].logicalProcessorCount == logicalCount
        else { return nil }
        return Array(repeating: .efficiency, count: levels[1].logicalProcessorCount)
            + Array(repeating: .performance, count: levels[0].logicalProcessorCount)
    }

    /// `cpu12` → 12.
    static func index(inNodeName name: String) -> Int? {
        guard name.hasPrefix("cpu") else { return nil }
        return Int(name.dropFirst(3))
    }

    static func coreType(ofClusterType value: String) -> CoreType? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))).uppercased() {
        case "E": .efficiency
        case "P": .performance
        default: nil
        }
    }
}
