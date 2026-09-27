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
        case .notApplicable: "Not applicable to this device."
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

// MARK: - Formatting shortcuts

enum Format {
    static func percent(_ fraction: Double) -> String { MetricFormatting.percent(fraction) }
    static func precisePercent(_ fraction: Double) -> String { MetricFormatting.percent(fraction, fractionDigits: 1) }
    static func memory(_ bytes: UInt64) -> String { MetricFormatting.memoryBytes(bytes) }
    static func memory(_ bytes: Double) -> String { MetricFormatting.memoryBytes(UInt64(max(bytes, 0))) }
    static func storage(_ bytes: UInt64) -> String { MetricFormatting.storageBytes(bytes) }
    static func rate(_ bytesPerSecond: Double) -> String { MetricFormatting.byteRate(bytesPerSecond) }
}

// MARK: - Labels

extension NetworkInterfaceKind {
    var label: String {
        switch self {
        case .ethernet: String(localized: "Ethernet")
        case .wifi: String(localized: "Wi‑Fi")
        case .bridge: String(localized: "Bridge")
        case .thunderbolt: String(localized: "Thunderbolt")
        case .cellular: String(localized: "Cellular")
        case .vpnTunnel(let friendlyName): friendlyName ?? String(localized: "VPN / Tunnel")
        case .loopback: String(localized: "Loopback")
        case .other: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .ethernet: "cable.connector"
        case .wifi: "wifi"
        case .bridge: "point.3.connected.trianglepath.dotted"
        case .thunderbolt: "bolt.horizontal"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .vpnTunnel: "lock.shield"
        case .loopback: "arrow.triangle.2.circlepath"
        case .other: "network"
        }
    }
}

extension NetworkInterfaceSnapshot {
    /// "Wi‑Fi", "Thunderbolt Bridge", or the generic kind label (e.g. "VPN / Tunnel").
    var title: String { displayName ?? kind.label }

    /// Interfaces hidden unless "Show all interfaces" is on: loopback and interfaces that are
    /// down and have never carried traffic. Unclassified interfaces are never hidden for that
    /// reason alone (SPEC §17).
    var isNormallyHidden: Bool {
        kind == .loopback || (!isUp && totalBytesReceived == 0 && totalBytesSent == 0)
    }
}

extension DiskConnection {
    var label: String {
        switch self {
        case .internal: String(localized: "Internal")
        case .external: String(localized: "External")
        case .diskImage: String(localized: "Disk Image")
        case .unknown: String(localized: "Unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .internal: "internaldrive"
        case .external: "externaldrive"
        case .diskImage: "opticaldisc"
        case .unknown: "questionmark.circle"
        }
    }
}

extension MemoryPressure {
    var label: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }
}

// MARK: - Previews

extension SystemSnapshot {
    /// Compact live preview for the resource list and the menu bar overview (SPEC §10).
    func preview(for category: ResourceCategory) -> MetricState<String> {
        switch category {
        case .cpu:
            cpu.map { Format.percent($0.total) }
        case .memory:
            memory.map { "\(Format.memory($0.used)) (\(Format.percent($0.usedFraction)))" }
        case .disks:
            disks.flatMap { disks -> MetricState<String> in
                // Sum over devices; each byte is counted once because only whole devices
                // (not partitions or volumes) are sampled.
                let read = disks.compactMap(\.readBytesPerSecond.value)
                let written = disks.compactMap(\.writeBytesPerSecond.value)
                guard !read.isEmpty || !written.isEmpty else { return .unavailable(.awaitingBaseline) }
                return .available(String(localized: "R \(Format.rate(read.reduce(0, +))) · W \(Format.rate(written.reduce(0, +)))"))
            }
        case .network:
            network.flatMap { network -> MetricState<String> in
                // The primary interface only: summing interfaces would double-count VPN and
                // bridge traffic.
                guard let primary = network.primaryInterface else { return .unavailable(.notApplicable) }
                guard let received = primary.receivedBytesPerSecond.value, let sent = primary.sentBytesPerSecond.value else {
                    return .unavailable(.awaitingBaseline)
                }
                return .available("\(primary.id) ↓ \(Format.rate(received)) ↑ \(Format.rate(sent))")
            }
        case .gpu:
            gpu.flatMap { (snapshot: GPUSnapshot) -> MetricState<String> in
                guard let device = snapshot.devices.first else { return .unavailable(.unsupportedHardware) }
                return .available(device.utilization.value.map { Format.percent($0) } ?? device.name)
            }
        case .energy:
            // Only a battery value is shown; it is labelled as such (never system power).
            energy.flatMap { energy in
                energy.battery.map { battery in String(localized: "Battery \(Format.percent(battery.charge))") }
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
            snapshot.cpu.map { Format.percent($0.total) }
        case .memory:
            snapshot.memory.map { Format.percent($0.usedFraction) }
        case .gpu:
            snapshot.gpu.flatMap { (snapshot: GPUSnapshot) -> MetricState<String> in
                snapshot.devices.first.map { device in device.utilization.map { Format.percent($0) } }
                    ?? .unavailable(.unsupportedHardware)
            }
        case .networkDownload, .networkUpload:
            // The primary (default-route) interface; summing all interfaces would double-count
            // tunnel and bridge traffic.
            snapshot.network.flatMap { network -> MetricState<String> in
                guard let primary = network.primaryInterface else { return .unavailable(.notApplicable) }
                let rate = self == .networkDownload ? primary.receivedBytesPerSecond : primary.sentBytesPerSecond
                return rate.map { (self == .networkDownload ? "↓ " : "↑ ") + Format.rate($0) }
            }
        case .energy:
            snapshot.energy.flatMap { energy in
                energy.battery.flatMap { battery in
                    battery.batteryPowerWatts.map { MetricFormatting.watts($0.value) }
                }
            }
        }
    }
}

// MARK: - Views

/// Displays a metric value, a transient dash, or "Not Available" with an explanation.
/// Never displays `0` for a missing value (SPEC §3).
struct MetricStateText: View {
    let state: MetricState<String>?

    var body: some View {
        switch state {
        case .available(let text)?:
            Text(verbatim: text)
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

/// A labelled statistic in the detail pages' statistics grid.
struct StatisticView: View {
    let label: LocalizedStringResource
    let value: MetricState<String>?
    var help: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            MetricStateText(state: value)
                .font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityElement(children: .combine)
    }
}

/// Adaptive grid of statistics.
struct StatisticsGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 14) {
            content
        }
    }
}

/// Title row of a detail page: large title on the leading side, device/model on the trailing.
struct DetailHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title)
                .font(.largeTitle.weight(.semibold))
            Spacer()
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
