import PulseDeckCore
import SwiftUI

extension UnavailableReason {
    /// User-facing explanation shown as help text next to "Not Available".
    var explanation: LocalizedStringResource {
        switch self {
        case .notImplemented: "This metric is not collected yet."
        case .noPublicAPI: "macOS provides no public API for this metric."
        case .unsupportedHardware: "This Mac does not provide this metric."
        case .permissionDenied: "macOS denied access to this information."
        case .sourceRemoved: "The device or process is no longer present."
        case .awaitingBaseline: "Collecting the first sample."
        case .invalidDelta: "No valid measurement for this interval."
        case .transientFailure: "The system did not return a value."
        }
    }

    /// Whether the missing value is only temporary (the UI shows a dash rather than
    /// "Not Available").
    var isTransient: Bool {
        switch self {
        case .awaitingBaseline, .invalidDelta, .transientFailure: true
        default: false
        }
    }
}

extension SystemSnapshot {
    /// Compact live preview for the resource list and the menu bar overview (SPEC §10).
    func preview(for category: ResourceCategory) -> MetricState<String> {
        switch category {
        case .cpu:
            cpu.map { MetricFormatting.percent($0.total) }
        case .memory:
            memory.map { MetricFormatting.percent($0.usedFraction) }
        case .disks:
            disks.map { String(localized: "\($0.count) devices") }
        case .network:
            network.map { String(localized: "\($0.interfaces.count) interfaces") }
        case .gpu:
            gpu.flatMap { (snapshot: GPUSnapshot) -> MetricState<String> in
                guard let device = snapshot.devices.first else { return .unavailable(.unsupportedHardware) }
                return .available(device.utilization.value.map { MetricFormatting.percent($0) } ?? device.name)
            }
        case .energy:
            // Only a battery value is shown; it is labelled as such (never system power).
            energy.flatMap { energy in
                energy.battery.map { battery in String(localized: "Battery \(MetricFormatting.percent(battery.charge))") }
            }
        }
    }
}

extension MenuBarMetric {
    /// Value for the menu bar label. Missing values stay missing — never zero.
    func value(in snapshot: SystemSnapshot) -> MetricState<String> {
        switch self {
        case .none:
            .notSampled
        case .cpu:
            snapshot.cpu.map { MetricFormatting.percent($0.total) }
        case .memory:
            snapshot.memory.map { MetricFormatting.percent($0.usedFraction) }
        case .gpu:
            snapshot.gpu.flatMap { (snapshot: GPUSnapshot) -> MetricState<String> in
                snapshot.devices.first.map { device in device.utilization.map { MetricFormatting.percent($0) } }
                    ?? .unavailable(.unsupportedHardware)
            }
        case .networkDownload, .networkUpload:
            // Summing interfaces naively double-counts tunnel and bridge traffic. The
            // aggregation rule is defined with the network collector (Milestone 4/9);
            // until then this stays unavailable rather than showing a wrong total.
            snapshot.network.flatMap { _ in .unavailable(.notImplemented) }
        case .energy:
            snapshot.energy.flatMap { energy in
                energy.battery.flatMap { battery in
                    battery.batteryPowerWatts.map { MetricFormatting.watts($0.value) }
                }
            }
        }
    }
}

/// Displays a metric value, a transient dash, or "Not Available" with an explanation.
/// Never displays `0` for a missing value (SPEC §3).
struct MetricStateText: View {
    let state: MetricState<String>?

    var body: some View {
        switch state {
        case .available(let text)?:
            Text(text)
                .monospacedDigit()
        case .unavailable(let reason)? where !reason.isTransient:
            Text("Not Available")
                .foregroundStyle(.secondary)
                .help(Text(reason.explanation))
        case .unavailable(let reason)?:
            Text(verbatim: AppState.placeholder)
                .foregroundStyle(.secondary)
                .help(Text(reason.explanation))
                .accessibilityLabel(Text("Not Available"))
        case .notSampled?, nil:
            Text(verbatim: AppState.placeholder)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Not Available"))
        }
    }
}
