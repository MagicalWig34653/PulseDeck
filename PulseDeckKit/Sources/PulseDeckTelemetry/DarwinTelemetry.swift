#if os(macOS)
import PulseDeckCore

/// Factory for the production collectors.
public enum DarwinTelemetry {
    /// All collectors. GPU, energy and processes are demand-driven: the engine samples them only
    /// while something observes them (`SamplingPolicy.demand`).
    public static func makeProviders() -> TelemetryProviders {
        TelemetryProviders(
            cpu: CPUMonitor(),
            memory: MemoryMonitor(),
            disks: DiskMonitor(),
            network: NetworkMonitor(),
            gpu: GPUMonitor(),
            energy: EnergyMonitor(),
            processes: ProcessMonitor()
        )
    }
}
#endif
