/// The telemetry domains the engine can sample. Used for demand-driven sampling and
/// capability reporting.
public enum MetricKind: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case energy
    case processes
    /// Live CPU cluster frequencies (IOReport; CPU page only).
    case cpuFrequency
    /// Tailscale peers and connections (LocalAPI; Tailscale interface page only).
    case tailscale
    /// Docker containers (Containers section only).
    case containers
    /// USB tree (USB page only).
    case usb

    /// Domains that are cheap enough (a single syscall/IOKit read per tick) to sample
    /// continuously so their history stays complete while the window is closed.
    public static let alwaysSampled: Set<MetricKind> = [.cpu, .memory, .disk, .network]
}
