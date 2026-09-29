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
        case .notApplicable: "Does not apply to this device or its current state."
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
    static func watts(_ watts: Double) -> String { MetricFormatting.watts(watts) }
    /// Process CPU as a percentage of one logical processor, like Activity Monitor ("123.4%").
    static func processCPU(_ fraction: Double) -> String { MetricFormatting.percent(fraction, fractionDigits: 1) }
    /// "3 hr, 20 min".
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    /// "3.21 GHz", "912 MHz".
    static func frequency(_ hertz: Double) -> String {
        hertz >= 1e9
            ? String(localized: "\((hertz / 1e9).formatted(.number.precision(.fractionLength(2)))) GHz")
            : String(localized: "\((hertz / 1e6).formatted(.number.precision(.fractionLength(0)))) MHz")
    }
    /// "3 days, 4 hr, 12 min" since `bootTime`.
    static func uptime(since bootTime: Date, now: Date = .now) -> String {
        Duration.seconds(max(now.timeIntervalSince(bootTime), 0))
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 3))
    }
    /// "10 Gbit/s", "866.7 Mbit/s".
    static func bitRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1e9 {
            return String(localized: "\((bitsPerSecond / 1e9).formatted(.number.precision(.significantDigits(1...3)))) Gbit/s")
        }
        return String(localized: "\((bitsPerSecond / 1e6).formatted(.number.precision(.significantDigits(1...4)))) Mbit/s")
    }
    /// Appends the provenance marker SPEC §19 requires for values that were not reported directly.
    static func attributed(_ value: AttributedValue<Double>, _ format: (Double) -> String) -> String {
        switch value.provenance {
        case .reported: format(value.value)
        case .derived: String(localized: "\(format(value.value)) (derived)")
        case .estimated: String(localized: "\(format(value.value)) (est.)")
        }
    }
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

extension WiFiStandard {
    /// "Wi‑Fi 6 (802.11ax)", "802.11g".
    var label: String {
        switch self {
        case .legacy(let name): name
        case .wifi4: String(localized: "Wi‑Fi 4 (802.11n)")
        case .wifi5: String(localized: "Wi‑Fi 5 (802.11ac)")
        case .wifi6: String(localized: "Wi‑Fi 6 (802.11ax)")
        case .wifi7: String(localized: "Wi‑Fi 7 (802.11be)")
        }
    }
}

extension NetworkInterfaceSnapshot {
    /// "Wi‑Fi", "Thunderbolt Bridge", or the generic kind label (e.g. "VPN / Tunnel").
    var title: String { displayName ?? kind.label }
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

extension GPULocation {
    var label: String {
        switch self {
        case .builtIn: String(localized: "Built-in")
        case .slot: String(localized: "Expansion Slot")
        case .external: String(localized: "External")
        case .unspecified: String(localized: "Unspecified")
        }
    }
}

extension GPUDeviceSnapshot {
    /// "Integrated · Unified memory" / "Discrete · External".
    var kindLabel: String {
        let kind = hasUnifiedMemory || isLowPower ? String(localized: "Integrated") : String(localized: "Discrete")
        let memory = hasUnifiedMemory ? String(localized: "Unified memory") : String(localized: "Dedicated memory")
        return [kind, memory, isRemovable ? location.label : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

extension BatterySnapshot {
    var stateLabel: String {
        if isCharging { return String(localized: "Charging") }
        switch powerSource {
        case .battery: return String(localized: "On Battery")
        case .ac: return isCharged ? String(localized: "Charged") : String(localized: "Not Charging")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var powerSourceLabel: String {
        switch powerSource {
        case .battery: String(localized: "Battery")
        case .ac: String(localized: "Power Adapter")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Battery power with its direction spelled out and the "derived" marker, e.g.
    /// "Discharging 6.2 W (derived)". Never labelled as system power (SPEC §19).
    var batteryPowerText: MetricState<String> {
        batteryPowerWatts.map { power in
            let magnitude = AttributedValue(abs(power.value), provenance: power.provenance)
            let text = Format.attributed(magnitude, Format.watts)
            return if power.value > 0 {
                String(localized: "Charging \(text)")
            } else if power.value < 0 {
                String(localized: "Discharging \(text)")
            } else {
                text
            }
        }
    }
}

extension USBSnapshot {
    var deviceCount: Int { controllers.reduce(0) { $0 + $1.deviceCount } }

    /// "3 devices" / "No devices".
    var devicesDescription: String { Self.devicesDescription(count: deviceCount) }

    static func devicesDescription(count: Int) -> String {
        switch count {
        case 0: String(localized: "No devices")
        case 1: String(localized: "1 device")
        default: String(localized: "\(count) devices")
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
            // Only battery state is shown; no wattage that could be read as system power.
            energy.flatMap { energy in
                energy.battery.map { battery in String(localized: "Battery \(Format.percent(battery.charge)) · \(battery.stateLabel)") }
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
            // Battery power only — never labelled or computed as system power (SPEC §19). The
            // sign shows the direction: "+12 W" charging, "−6.2 W" discharging.
            snapshot.energy.flatMap { energy in
                energy.battery.flatMap { battery in
                    battery.batteryPowerWatts.map { power in
                        power.value.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false))) + " W"
                    }
                }
            }
        case .batteryCharge:
            snapshot.energy.flatMap { energy in
                energy.battery.map { battery in
                    (battery.isCharging ? "⚡︎" : "") + Format.percent(battery.charge)
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
    /// Table cells: show a dash (with the explanation as tooltip and "Not Available" for
    /// VoiceOver) instead of the full "Not Available" text.
    var isCompact = false

    var body: some View {
        switch state {
        case .available(let text)?:
            Text(verbatim: text)
                .monospacedDigit()
        case .unavailable(let reason)? where !reason.isTransient && !isCompact:
            Text("Not Available")
                .foregroundStyle(.secondary)
                .help(Text(reason.explanation))
        case .unavailable?  where isCompact:
            // No per-cell tooltip: in a table of hundreds of rows each `.help` re-registers a
            // tooltip on every refresh (M10). VoiceOver still hears "Not Available".
            Text(verbatim: AppState.placeholder)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Not Available"))
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

/// A labelled statistic inside a `DetailSection`.
struct StatisticView: View {
    let label: LocalizedStringResource
    let value: MetricState<String>?
    var help: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            MetricStateText(state: value)
                .font(.title3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityElement(children: .combine)
    }
}

/// A titled group of statistics in the native macOS group box style.
struct DetailSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                content
            }
            .padding(8)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

/// Header of a detail page. The toolbar already names the category, so the header shows the
/// concrete device, a secondary detail line and the current value (HIG: avoid repeating the
/// window title; lead with the most important information).
struct DetailHeader: View {
    let title: String
    var subtitle: String?
    var value: MetricState<String>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if let value {
                MetricStateText(state: value)
                    .font(.system(.title, design: .rounded).weight(.medium))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Title row above a table, with optional trailing controls.
struct SectionHeader<Accessory: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            accessory
                .controlSize(.small)
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: LocalizedStringResource) {
        self.title = title
        accessory = EmptyView()
    }
}

/// Full-page error state for a category whose collector cannot deliver at all (SPEC §34): the
/// category, "Not Available" and why. Transient failures keep the page and show dashes instead.
struct CategoryUnavailableView: View {
    let category: ResourceCategory
    let reason: UnavailableReason

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(category.title)
            } icon: {
                Image(systemName: category.systemImage)
            }
        } description: {
            Text("Not Available")
            Text(reason.explanation)
        }
    }
}

/// Height of an inline table showing all `rows` without scrolling, up to a maximum.
func inlineTableHeight(rows: Int) -> CGFloat {
    let rowHeight: CGFloat = 26
    let headerHeight: CGFloat = 34
    let maximum: CGFloat = 360
    return min(CGFloat(max(rows, 1)) * rowHeight + headerHeight, maximum)
}
