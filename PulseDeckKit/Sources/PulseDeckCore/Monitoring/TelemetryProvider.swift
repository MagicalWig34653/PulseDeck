/// A collector for one telemetry domain (SPEC §38: protocols around telemetry providers).
///
/// Conformers are actors: each owns its previous-sample baselines, so no telemetry state is
/// shared, and all Darwin calls run off the MainActor (SPEC §5).
public protocol TelemetryProvider<Reading>: Actor {
    associatedtype Reading: Sendable

    /// Probe whether this metric can be collected on this machine.
    func capability() async -> TelemetryCapability

    /// Take one sample. Delta-based collectors return `.unavailable(.awaitingBaseline)` for
    /// their first sample and `.unavailable(.invalidDelta)` when a delta cannot be trusted.
    /// Must not throw or crash on expected failures (SPEC §34).
    func sample(at instant: MonotonicInstant) async -> MetricState<Reading>

    /// Discard all baselines, e.g. after wake from sleep (SPEC §27).
    func invalidateBaselines() async
}

/// The set of collectors the engine uses. `nil` means no collector exists for that domain,
/// which the engine reports as `.unavailable(.notImplemented)` — never as zero.
public struct TelemetryProviders: Sendable {
    public var cpu: (any TelemetryProvider<CPUSnapshot>)?
    public var memory: (any TelemetryProvider<MemorySnapshot>)?
    public var disks: (any TelemetryProvider<[DiskSnapshot]>)?
    public var network: (any TelemetryProvider<NetworkSnapshot>)?
    public var gpu: (any TelemetryProvider<GPUSnapshot>)?
    public var energy: (any TelemetryProvider<EnergySnapshot>)?
    public var processes: (any TelemetryProvider<[ProcessSnapshot]>)?
    public var cpuFrequency: (any TelemetryProvider<CPUFrequencySnapshot>)?
    public var tailscale: (any TelemetryProvider<TailscaleSnapshot>)?
    public var containers: (any TelemetryProvider<ContainersSnapshot>)?
    public var usb: (any TelemetryProvider<USBSnapshot>)?

    public init(
        cpu: (any TelemetryProvider<CPUSnapshot>)? = nil,
        memory: (any TelemetryProvider<MemorySnapshot>)? = nil,
        disks: (any TelemetryProvider<[DiskSnapshot]>)? = nil,
        network: (any TelemetryProvider<NetworkSnapshot>)? = nil,
        gpu: (any TelemetryProvider<GPUSnapshot>)? = nil,
        energy: (any TelemetryProvider<EnergySnapshot>)? = nil,
        processes: (any TelemetryProvider<[ProcessSnapshot]>)? = nil,
        cpuFrequency: (any TelemetryProvider<CPUFrequencySnapshot>)? = nil,
        tailscale: (any TelemetryProvider<TailscaleSnapshot>)? = nil,
        containers: (any TelemetryProvider<ContainersSnapshot>)? = nil,
        usb: (any TelemetryProvider<USBSnapshot>)? = nil
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disks = disks
        self.network = network
        self.gpu = gpu
        self.energy = energy
        self.processes = processes
        self.cpuFrequency = cpuFrequency
        self.tailscale = tailscale
        self.containers = containers
        self.usb = usb
    }

    /// No collectors at all. Every metric is reported as not implemented.
    public static let none = TelemetryProviders()
}
