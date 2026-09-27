#if os(macOS)
import PulseDeckCore

/// Factory for the production collectors.
public enum DarwinTelemetry {
    /// Collectors implemented so far. GPU, energy and processes follow in Milestones 6–8 and are
    /// reported as not implemented until then.
    public static func makeProviders() -> TelemetryProviders {
        TelemetryProviders(
            cpu: CPUMonitor(),
            memory: MemoryMonitor(),
            disks: DiskMonitor(),
            network: NetworkMonitor()
        )
    }
}
#endif
