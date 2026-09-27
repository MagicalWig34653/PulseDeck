import Foundation

/// When a sample was taken: monotonic time for math, wall-clock time for display (SPEC §6).
public struct SampleTimestamp: Hashable, Sendable {
    public var monotonic: MonotonicInstant
    public var wallClock: Date

    public init(monotonic: MonotonicInstant, wallClock: Date) {
        self.monotonic = monotonic
        self.wallClock = wallClock
    }
}

/// One immutable batch of telemetry delivered to the UI per tick (SPEC §5).
public struct SystemSnapshot: Sendable {
    /// Strictly increasing per engine instance.
    public var sequence: UInt64
    public var timestamp: SampleTimestamp
    public var samplingMode: SamplingPolicy.Mode
    public var cpu: MetricState<CPUSnapshot>
    public var memory: MetricState<MemorySnapshot>
    public var disks: MetricState<[DiskSnapshot]>
    public var network: MetricState<NetworkSnapshot>
    public var gpu: MetricState<GPUSnapshot>
    public var energy: MetricState<EnergySnapshot>
    public var processes: MetricState<[ProcessSnapshot]>

    public init(sequence: UInt64, timestamp: SampleTimestamp, samplingMode: SamplingPolicy.Mode, cpu: MetricState<CPUSnapshot>, memory: MetricState<MemorySnapshot>, disks: MetricState<[DiskSnapshot]>, network: MetricState<NetworkSnapshot>, gpu: MetricState<GPUSnapshot>, energy: MetricState<EnergySnapshot>, processes: MetricState<[ProcessSnapshot]>) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.samplingMode = samplingMode
        self.cpu = cpu
        self.memory = memory
        self.disks = disks
        self.network = network
        self.gpu = gpu
        self.energy = energy
        self.processes = processes
    }
}
