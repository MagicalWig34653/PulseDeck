import Foundation

/// One point of a metric's history. `values` holds one entry per series; `nil` marks a sample
/// without a valid value (drawn as a gap, never as zero — SPEC §28).
public struct HistorySample: TimestampedSample, Sendable {
    public var timestamp: MonotonicInstant
    public var wallClock: Date
    public var values: [Double?]

    public init(timestamp: MonotonicInstant, wallClock: Date, values: [Double?]) {
        self.timestamp = timestamp
        self.wallClock = wallClock
        self.values = values
    }
}

/// Bounded history of one metric with a fixed number of series (SPEC §6, §29).
public struct MetricHistory: Sendable {
    public private(set) var samples: RingBuffer<HistorySample>
    public let seriesCount: Int

    public init(seriesCount: Int, capacity: Int = SystemHistory.capacity) {
        self.seriesCount = seriesCount
        samples = RingBuffer(capacity: capacity)
    }

    public mutating func append(_ timestamp: SampleTimestamp, values: [Double?]) {
        precondition(values.count == seriesCount, "series count mismatch")
        samples.append(HistorySample(timestamp: timestamp.monotonic, wallClock: timestamp.wallClock, values: values))
    }

    public var latest: HistorySample? { samples.newest }

    /// Largest non-nil value of `series` in the buffer, for chart scaling.
    public func maximum(series: Int) -> Double? {
        samples.compactMap { $0.values[series] }.max()
    }
}

/// History of all performance metrics shown in charts. Appended once per snapshot; hover
/// inspection only reads it (SPEC §12).
public struct SystemHistory: Sendable {
    /// Visible chart window (SPEC §6).
    public static let window: Duration = .seconds(60)
    /// 60 s at the fastest foreground interval (0.5 s) needs 121 samples to span the whole
    /// window. At 1 s the buffers hold the last two minutes; memory stays bounded either way.
    public static let capacity = 121

    /// Series: 0 = user, 1 = system (fractions of all logical processors).
    public private(set) var cpu = MetricHistory(seriesCount: 2)
    /// Series: one total-utilization fraction per logical processor.
    public private(set) var cpuCores = MetricHistory(seriesCount: 0)
    /// Series: 0 = efficiency-cluster frequency (Hz), 1 = performance-cluster frequency (Hz).
    /// Demand-driven (CPU page only), so ticks without a sample leave no point.
    public private(set) var cpuFrequency = MetricHistory(seriesCount: 2)
    /// Series: 0 = hottest CPU sensor (°C), 1 = hottest GPU sensor (°C). Demand-driven (Thermals
    /// page only).
    public private(set) var thermals = MetricHistory(seriesCount: 2)
    /// Series: 0 = used fraction, 1 = used bytes, 2 = compressed (bytes occupied by the
    /// compressor), 3 = original size of the compressed data.
    public private(set) var memory = MetricHistory(seriesCount: 4)
    /// Per interface (BSD name). Series: 0 = received B/s, 1 = sent B/s.
    public private(set) var network: [String: MetricHistory] = [:]
    /// Per disk (BSD name). Series: 0 = read B/s, 1 = written B/s.
    public private(set) var disks: [String: MetricHistory] = [:]
    /// Per GPU (Metal registry ID). Series: 0 = device utilization fraction.
    public private(set) var gpus: [UInt64: MetricHistory] = [:]
    /// Series: 0 = system power in (W), 1 = battery charging power (W), 2 = battery discharging
    /// power (W, positive). Charging and discharging are separate series so each is a gap while
    /// the other applies, and neither is ever drawn below zero.
    public private(set) var energy = MetricHistory(seriesCount: 3)

    public init() {}

    public mutating func append(_ snapshot: SystemSnapshot) {
        let time = snapshot.timestamp

        switch snapshot.cpu {
        case .available(let cpu):
            self.cpu.append(time, values: [cpu.user, cpu.system])
            if cpuCores.seriesCount != cpu.cores.count {
                cpuCores = MetricHistory(seriesCount: cpu.cores.count)
            }
            cpuCores.append(time, values: cpu.cores.map { Optional($0.total) })
        case .unavailable:
            self.cpu.append(time, values: [nil, nil])
            cpuCores.append(time, values: Array(repeating: nil, count: cpuCores.seriesCount))
        case .notSampled:
            break
        }

        switch snapshot.cpuFrequency {
        case .available(let frequency):
            cpuFrequency.append(time, values: [
                Self.meanFrequency(of: frequency.clusters, type: .efficiency),
                Self.meanFrequency(of: frequency.clusters, type: .performance),
            ])
        case .unavailable:
            cpuFrequency.append(time, values: [nil, nil])
        case .notSampled:
            break
        }

        switch snapshot.thermals {
        case .available(let thermals):
            self.thermals.append(time, values: [thermals.cpuMaximumCelsius, thermals.zone(.gpu)?.maximumCelsius])
        case .unavailable:
            self.thermals.append(time, values: [nil, nil])
        case .notSampled:
            break
        }

        switch snapshot.memory {
        case .available(let memory):
            self.memory.append(time, values: [memory.usedFraction, Double(memory.used), Double(memory.compressed),
                                              memory.compressedOriginal > 0 ? Double(memory.compressedOriginal) : nil])
        case .unavailable:
            self.memory.append(time, values: [nil, nil, nil, nil])
        case .notSampled:
            break
        }

        if let network = snapshot.network.value {
            for interface in network.interfaces {
                Self.append(to: &self.network, key: interface.id, time: time,
                            values: [interface.receivedBytesPerSecond.value, interface.sentBytesPerSecond.value])
            }
        }
        if let disks = snapshot.disks.value {
            for disk in disks {
                Self.append(to: &self.disks, key: disk.id, time: time,
                            values: [disk.readBytesPerSecond.value, disk.writeBytesPerSecond.value])
            }
        }
        // GPU and energy are demand-driven: `.notSampled` ticks leave no point (the chart shows
        // only real samples), and pruning drops a GPU's history once it is a window old.
        if let gpu = snapshot.gpu.value {
            for device in gpu.devices {
                Self.append(to: &gpus, key: device.id, time: time, values: [device.utilization.value])
            }
        }
        switch snapshot.energy {
        case .available(let energy):
            self.energy.append(time, values: Self.energyValues(energy))
        case .unavailable:
            self.energy.append(time, values: [nil, nil, nil])
        case .notSampled:
            break
        }
        prune(before: time.monotonic.advanced(by: .zero - Self.window))
    }

    /// Mean active frequency of the clusters of one core type, weighted by how long each
    /// cluster was running. `nil` if every such cluster was idle (never 0 Hz).
    public static func meanFrequency(of clusters: [ClusterFrequency], type: CoreType) -> Double? {
        let running = clusters.filter { $0.coreType == type && $0.activeFrequencyHz != nil && $0.activeFraction > 0 }
        let weight = running.reduce(0) { $0 + $1.activeFraction }
        guard weight > 0 else { return nil }
        return running.reduce(0) { $0 + ($1.activeFrequencyHz ?? 0) * $1.activeFraction } / weight
    }

    static func energyValues(_ energy: EnergySnapshot) -> [Double?] {
        let batteryWatts = energy.battery.value?.batteryPowerWatts.value?.value
        return [
            energy.systemPowerWatts.value?.value,
            batteryWatts.flatMap { $0 >= 0 ? $0 : nil },
            batteryWatts.flatMap { $0 < 0 ? -$0 : nil },
        ]
    }

    /// Drops histories of devices that disappeared more than one window ago, keeping memory
    /// bounded while devices are hot-plugged (SPEC §29).
    private mutating func prune(before cutoff: MonotonicInstant) {
        let isStale: (MetricHistory) -> Bool = { ($0.latest?.timestamp ?? cutoff) < cutoff }
        // Only rebuild the dictionaries when something actually went stale.
        if network.values.contains(where: isStale) {
            network = network.filter { !isStale($0.value) }
        }
        if disks.values.contains(where: isStale) {
            disks = disks.filter { !isStale($0.value) }
        }
        if gpus.values.contains(where: isStale) {
            gpus = gpus.filter { !isStale($0.value) }
        }
    }

    private static func append<Key: Hashable>(to histories: inout [Key: MetricHistory], key: Key, time: SampleTimestamp, values: [Double?]) {
        histories[key, default: MetricHistory(seriesCount: values.count)].append(time, values: values)
    }
}
