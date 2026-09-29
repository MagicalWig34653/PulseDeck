#if os(macOS)
import Darwin
import Foundation
import IOKit
import PulseDeckCore

/// CPU utilization from per-processor scheduler ticks (SPEC §13).
///
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` returns cumulative tick counts per logical
/// processor; utilization is the delta between two readings (`CPUUsageCalculator`).
public actor CPUMonitor: TelemetryProvider {
    /// Send right to the host port. Obtained once: every `mach_host_self()` call adds a user
    /// reference, so calling it per sample would leak references.
    private let host: host_t
    private let info: CPUInfo
    private var previous: [CPUTicks]?

    public init() {
        host = mach_host_self()
        info = Self.readInfo()
    }

    public func capability() -> TelemetryCapability {
        readTicks() == nil ? .unsupported(.transientFailure("host_processor_info failed")) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<CPUSnapshot> {
        guard let current = readTicks() else {
            previous = nil
            return .unavailable(.transientFailure("host_processor_info failed"))
        }
        let baseline = previous
        previous = current
        guard let baseline else { return .unavailable(.awaitingBaseline) }
        return CPUUsageCalculator.snapshot(info: info, previous: baseline, current: current)
    }

    public func invalidateBaselines() {
        previous = nil
    }

    private func readTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let infoArray else { return nil }
        // The kernel allocates the array in our address space; it must be released.
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: infoArray), size)
        }

        // Layout: processorCount × CPU_STATE_MAX integers (USER, SYSTEM, IDLE, NICE).
        let stateCount = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(processorCount) * stateCount else { return nil }
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for processor in 0..<Int(processorCount) {
            let base = processor * stateCount
            ticks.append(CPUTicks(
                user: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: infoArray[base + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }

    private static func readInfo() -> CPUInfo {
        let levelCount = Int(Sysctl.integer("hw.nperflevels", as: Int32.self) ?? 0)
        var levels: [CPUInfo.PerformanceLevel] = []
        // hw.perflevel0 is the highest-performance cluster (P-cores on Apple silicon).
        for level in 0..<levelCount {
            let prefix = "hw.perflevel\(level)"
            guard let name = Sysctl.string("\(prefix).name"),
                  let physical = Sysctl.integer("\(prefix).physicalcpu", as: Int32.self),
                  let logical = Sysctl.integer("\(prefix).logicalcpu", as: Int32.self)
            else { continue }
            levels.append(.init(name: name, physicalCoreCount: Int(physical), logicalProcessorCount: Int(logical)))
        }
        let logical = Sysctl.integer("hw.logicalcpu", as: Int32.self).map(Int.init)
            ?? ProcessInfo.processInfo.processorCount
        let coreTypes = CoreTypeResolver.resolve(deviceTree: readDeviceTreeCPUs(), levels: levels, logicalCount: logical)
        return CPUInfo(
            modelName: Sysctl.string("machdep.cpu.brand_string"),
            logicalProcessorCount: logical,
            physicalCoreCount: Sysctl.integer("hw.physicalcpu", as: Int32.self).map(Int.init),
            performanceLevels: levels,
            coreTypes: coreTypes?.types ?? [],
            coreTypeSource: coreTypes?.source,
            bootTime: readBootTime()
        )
    }

    /// `kern.boottime`: wall-clock time of boot (`struct timeval`).
    private static func readBootTime() -> Date? {
        guard let time = Sysctl.structure("kern.boottime", initial: timeval()), time.tv_sec > 0 else { return nil }
        let microsecondsPerSecond = 1e6
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / microsecondsPerSecond)
    }

    /// The processor nodes of the device tree (`IODeviceTree:/cpus/cpuN`) with their undocumented
    /// `logical-cpu-id`, `cpu-id` and `cluster-type` ("E"/"P") properties. Which of them exist
    /// varies by chip; `CoreTypeResolver` decides what is usable and falls back to the documented
    /// `hw.perflevel` counts.
    private static func readDeviceTreeCPUs() -> [DeviceTreeCPU] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var nodes: [DeviceTreeCPU] = []
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            let nodeName = IORegistryEntryGetName(cpu, &name) == KERN_SUCCESS
                ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            // Only processor nodes ("cpu<n>"): /cpus may also hold cluster or other children.
            if let nodeName, !(nodeName.hasPrefix("cpu") && Int(nodeName.dropFirst(3)) != nil) { continue }
            let clusterType = data(cpu, "cluster-type").map {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            nodes.append(DeviceTreeCPU(
                logicalID: littleEndianInteger(data(cpu, "logical-cpu-id")),
                cpuID: littleEndianInteger(data(cpu, "cpu-id")),
                name: nodeName,
                clusterType: clusterType
            ))
        }
        return nodes
    }

    private static func data(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
    }

    /// Device-tree integers are 32-bit little-endian cells.
    private static func littleEndianInteger(_ data: Data?) -> Int? {
        guard let data, data.count >= MemoryLayout<UInt32>.size else { return nil }
        return Int(data.prefix(MemoryLayout<UInt32>.size).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}
#endif
