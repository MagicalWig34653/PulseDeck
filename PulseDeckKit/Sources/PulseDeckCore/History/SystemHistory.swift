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
    /// 60 one-second intervals need 61 samples to span the whole window.
    public static let capacity = 61

    /// Series: 0 = user, 1 = system (fractions of all logical processors).
    public private(set) var cpu = MetricHistory(seriesCount: 2)
    /// Series: one total-utilization fraction per logical processor.
    public private(set) var cpuCores = MetricHistory(seriesCount: 0)
    /// Series: 0 = used fraction, 1 = used bytes.
    public private(set) var memory = MetricHistory(seriesCount: 2)
    /// Per interface (BSD name). Series: 0 = received B/s, 1 = sent B/s.
    public private(set) var network: [String: MetricHistory] = [:]
    /// Per disk (BSD name). Series: 0 = read B/s, 1 = written B/s.
    public private(set) var disks: [String: MetricHistory] = [:]

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

        switch snapshot.memory {
        case .available(let memory):
            self.memory.append(time, values: [memory.usedFraction, Double(memory.used)])
        case .unavailable:
            self.memory.append(time, values: [nil, nil])
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
        prune(before: time.monotonic.advanced(by: .zero - Self.window))
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
    }

    private static func append(to histories: inout [String: MetricHistory], key: String, time: SampleTimestamp, values: [Double?]) {
        histories[key, default: MetricHistory(seriesCount: values.count)].append(time, values: values)
    }
}
