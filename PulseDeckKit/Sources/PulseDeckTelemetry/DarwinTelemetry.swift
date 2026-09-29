#if os(macOS)
import PulseDeckCore

/// Factory for the production collectors.
public enum DarwinTelemetry {
    /// All collectors. GPU, energy, processes, CPU frequency, Tailscale, containers and USB are
    /// demand-driven: the engine samples them only while something observes them
    /// (`SamplingPolicy.demand`).
    public static func makeProviders() -> TelemetryProviders {
        TelemetryProviders(
            cpu: CPUMonitor(),
            memory: MemoryMonitor(),
            disks: DiskMonitor(),
            network: NetworkMonitor(),
            gpu: GPUMonitor(),
            energy: EnergyMonitor(),
            processes: ProcessMonitor(),
            cpuFrequency: CPUFrequencyMonitor(),
            tailscale: TailscaleMonitor(),
            containers: ContainerMonitor(),
            usb: USBMonitor()
        )
    }
}
#endif
