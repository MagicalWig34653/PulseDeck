import PulseDeckCore
import SwiftUI

/// Thermals page: a schematic top view of the logic board with each component coloured by its
/// temperature, the fans at the sides and the battery below; then the CPU/GPU temperature chart,
/// per-zone readings, fans and battery health. Temperatures and fans come from undocumented SMC
/// keys (TECHNICAL_LIMITATIONS.md L‑13), read only while this page is visible.
struct ThermalsPerformanceView: View {
    @Environment(AppState.self) private var appState

    private var state: MetricState<ThermalSnapshot>? { appState.latestSnapshot?.thermals }
    /// Live reading, or the last one while the first sample of this visit is pending.
    private var thermals: ThermalSnapshot? { state?.value ?? appState.latestThermals }
    private var battery: BatterySnapshot? { appState.latestSnapshot?.energy.value?.battery.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(
                    title: String(localized: "Temperatures & Fans"),
                    subtitle: thermals.map(Self.subtitle),
                    value: headerValue
                )

                LogicBoardView(thermals: thermals, battery: battery, unavailableReason: state?.unavailableReason)

                if thermals != nil {
                    TimeSeriesChart(
                        history: appState.history.thermals,
                        series: [
                            ChartSeries(label: "CPU", color: .red, value: { $0.values[0] }, isFilled: false),
                            ChartSeries(label: "GPU", color: .purple, value: { $0.values[1] }, isFilled: false),
                        ],
                        yAxis: .automatic(minimum: Self.minimumChartScale),
                        format: Format.temperature,
                        accessibilityLabel: Text("CPU and GPU temperature")
                    )
                    .frame(height: 160)
                }

                if let thermals {
                    DetailSection(title: "Components") {
                        ForEach(thermals.zones) { zone in
                            StatisticView(
                                label: zone.zone.title,
                                value: .available(Format.temperature(zone.maximumCelsius)),
                                help: "Hottest of \(zone.sensorCount) sensors · average \(Format.temperature(zone.averageCelsius))"
                            )
                        }
                    }
                    FanSection(fans: thermals.fans)
                } else if let reason = state?.unavailableReason, !reason.isTransient {
                    DetailSection(title: "Components") {
                        StatisticView(label: "Temperatures", value: .unavailable(reason),
                                      help: "This Mac's System Management Controller did not provide temperature sensors.")
                    }
                }

                if let battery {
                    BatteryHealthSection(health: battery.health)
                }

                SourceNote(text: "Temperatures and fan speeds are read from the System Management Controller through undocumented keys; sensors are grouped by what their key names indicate. The board is a schematic, not the layout of this Mac.")
            }
            .padding(20)
        }
    }

    /// 60 °C: idle temperatures do not fill the chart.
    private static let minimumChartScale = 60.0

    private var headerValue: MetricState<String>? {
        if let cpu = thermals?.cpuMaximumCelsius { return .available(Format.temperature(cpu)) }
        return state?.unavailableReason.map { .unavailable($0) }
    }

    private static func subtitle(_ thermals: ThermalSnapshot) -> String {
        var parts = [String(localized: "\(thermals.sensors.count) sensors")]
        switch thermals.fans {
        case .available(let fans): parts.append(fans.count == 1 ? String(localized: "1 fan") : String(localized: "\(fans.count) fans"))
        case .unavailable(.notApplicable): parts.append(String(localized: "Fanless"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Board view

/// Schematic top view: the SoC package (performance cores, efficiency cores, GPU) with memory
/// beside it, storage, wireless and power delivery on the board, fans at the edges, the battery
/// below and the palm rest in front. Components without a sensor stay grey.
private struct LogicBoardView: View {
    let thermals: ThermalSnapshot?
    let battery: BatterySnapshot?
    let unavailableReason: UnavailableReason?

    /// Board proportions (width : height) of the drawing.
    private static let aspectRatio: CGFloat = 2.1

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                // Board outline.
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.green.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.green.opacity(0.35), lineWidth: 1.5))
                    .frame(width: size.width * 0.78, height: size.height * 0.66)
                    .position(x: size.width * 0.5, y: size.height * 0.36)

                // SoC package.
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .frame(width: size.width * 0.3, height: size.height * 0.5)
                    .position(x: size.width * 0.42, y: size.height * 0.36)
                Text("SoC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .position(x: size.width * 0.42, y: size.height * 0.14)

                ForEach(Self.blocks(hasCoreTypes: hasCoreTypes)) { block in
                    ComponentTile(title: block.zone.title, reading: thermals?.zone(block.zone), isCompact: block.isCompact)
                        .frame(width: size.width * block.frame.width, height: size.height * block.frame.height)
                        .position(x: size.width * block.frame.midX, y: size.height * block.frame.midY)
                }

                ForEach(Array(fanSlots.enumerated()), id: \.offset) { index, fan in
                    FanTile(fan: fan, isAbsent: fansAbsent)
                        .frame(width: size.width * 0.1, height: size.width * 0.1)
                        .position(x: size.width * (index == 0 ? 0.055 : 0.945), y: size.height * 0.36)
                }

                BatteryTile(battery: battery, reading: thermals?.zone(.battery))
                    .frame(width: size.width * 0.6, height: size.height * 0.2)
                    .position(x: size.width * 0.5, y: size.height * 0.86)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Logic board temperatures"))
    }

    private var hasCoreTypes: Bool {
        thermals?.zone(.cpuPerformance) != nil || thermals?.zone(.cpuEfficiency) != nil
    }

    /// Two fan positions (left, right). A Mac with one fan shows it on the left; fanless Macs
    /// show no fans.
    private var fanSlots: [FanReading?] {
        switch thermals?.fans {
        case .available(let fans): Array(fans.prefix(2)).map(Optional.some)
        case .unavailable(.notApplicable): []
        default: [nil, nil]
        }
    }

    private var fansAbsent: Bool { thermals == nil }

    private struct Block: Identifiable {
        let zone: ThermalZone
        /// Unit rectangle within the drawing.
        let frame: CGRect
        var isCompact = false
        var id: ThermalZone { zone }
    }

    private static func blocks(hasCoreTypes: Bool) -> [Block] {
        var blocks: [Block] = []
        if hasCoreTypes {
            blocks.append(Block(zone: .cpuPerformance, frame: CGRect(x: 0.29, y: 0.18, width: 0.125, height: 0.2)))
            blocks.append(Block(zone: .cpuEfficiency, frame: CGRect(x: 0.425, y: 0.18, width: 0.125, height: 0.2)))
        } else {
            blocks.append(Block(zone: .cpu, frame: CGRect(x: 0.29, y: 0.18, width: 0.26, height: 0.2)))
        }
        blocks += [
            Block(zone: .gpu, frame: CGRect(x: 0.29, y: 0.4, width: 0.26, height: 0.18)),
            Block(zone: .memory, frame: CGRect(x: 0.15, y: 0.14, width: 0.11, height: 0.36)),
            Block(zone: .storage, frame: CGRect(x: 0.6, y: 0.1, width: 0.17, height: 0.2)),
            Block(zone: .wireless, frame: CGRect(x: 0.6, y: 0.33, width: 0.17, height: 0.14), isCompact: true),
            Block(zone: .power, frame: CGRect(x: 0.6, y: 0.5, width: 0.17, height: 0.14), isCompact: true),
            Block(zone: .ambient, frame: CGRect(x: 0.15, y: 0.52, width: 0.11, height: 0.1), isCompact: true),
            Block(zone: .enclosure, frame: CGRect(x: 0.8, y: 0.72, width: 0.16, height: 0.12), isCompact: true),
        ]
        return blocks
    }
}

/// One component on the board, filled with its temperature colour.
private struct ComponentTile: View {
    let title: LocalizedStringResource
    let reading: ThermalZoneReading?
    var isCompact = false

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(isCompact ? .caption2 : .caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: reading.map { Format.temperature($0.maximumCelsius) } ?? AppState.placeholder)
                .font((isCompact ? Font.callout : Font.title3).weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(reading == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary))
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(reading.map { TemperatureScale.color(for: $0.maximumCelsius) } ?? .secondary.opacity(0.3), lineWidth: 1))
        .help(Text(reading.map { "\(String(localized: title)): hottest \(Format.temperature($0.maximumCelsius)), average \(Format.temperature($0.averageCelsius)), \($0.sensorCount) sensors" }
                   ?? String(localized: "\(String(localized: title)): no sensor on this Mac")))
        .accessibilityElement(children: .combine)
    }

    private var fill: Color {
        reading.map { TemperatureScale.color(for: $0.maximumCelsius).opacity(0.28) } ?? Color.secondary.opacity(0.08)
    }
}

private struct FanTile: View {
    let fan: FanReading?
    let isAbsent: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "fan")
                .font(.title2)
                .foregroundStyle(fan == nil ? .secondary : Color.cyan)
            Text(verbatim: fan.map { Format.rpm($0.actualRPM) } ?? AppState.placeholder)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cyan.opacity(fan == nil ? 0.04 : 0.12), in: .circle)
        .overlay(Circle().strokeBorder(Color.cyan.opacity(fan == nil ? 0.2 : 0.5)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(fan.map { "Fan \($0.index + 1)" } ?? "Fan"))
    }
}

private struct BatteryTile: View {
    let battery: BatterySnapshot?
    let reading: ThermalZoneReading?

    var body: some View {
        let health = battery?.health.value
        let temperature = reading?.maximumCelsius ?? health?.temperatureCelsius
        HStack(spacing: 14) {
            Image(systemName: battery == nil ? "battery.0percent" : "battery.75percent")
                .font(.title2)
                .foregroundStyle(battery == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
            VStack(alignment: .leading, spacing: 2) {
                Text("Battery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: battery == nil ? String(localized: "No battery") : healthText(health))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            Text(verbatim: temperature.map(Format.temperature) ?? AppState.placeholder)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(temperature.map { TemperatureScale.color(for: $0).opacity(0.2) } ?? Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
    }

    /// "Health 91 % · 312 cycles".
    private func healthText(_ health: BatteryHealth?) -> String {
        var parts: [String] = []
        if let fraction = health?.maximumCapacityFraction { parts.append(String(localized: "Health \(Format.percent(fraction))")) }
        if let cycles = health?.cycleCount { parts.append(String(localized: "\(cycles) cycles")) }
        return parts.isEmpty ? AppState.placeholder : parts.joined(separator: " · ")
    }
}

/// Colour ramp for temperatures: blue when cool, through green and yellow to red when hot.
enum TemperatureScale {
    static func color(for celsius: Double) -> Color {
        switch celsius {
        case ..<40: .blue
        case ..<55: .green
        case ..<70: .yellow
        case ..<85: .orange
        default: .red
        }
    }
}

/// Fans with their speed within the min–max range.
private struct FanSection: View {
    let fans: MetricState<[FanReading]>

    var body: some View {
        DetailSection(title: "Fans") {
            switch fans {
            case .available(let fans):
                ForEach(fans) { fan in
                    VStack(alignment: .leading, spacing: 4) {
                        StatisticView(label: "Fan \(fan.index + 1)", value: .available(Format.rpm(fan.actualRPM)),
                                      help: rangeHelp(fan))
                        if let fraction = fan.fractionOfRange {
                            ProgressView(value: fraction)
                                .tint(.cyan)
                                .accessibilityLabel(Text("Share of the fan's speed range"))
                        }
                    }
                }
            case .unavailable(.notApplicable):
                StatisticView(label: "Fans", value: .available(String(localized: "Fanless")),
                              help: "This Mac has no fans.")
            case .unavailable(let reason):
                StatisticView(label: "Fans", value: .unavailable(reason))
            case .notSampled:
                StatisticView(label: "Fans", value: .notSampled)
            }
        }
    }

    private func rangeHelp(_ fan: FanReading) -> LocalizedStringResource {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM else { return "Current speed." }
        return "Range \(Format.rpm(minimum)) – \(Format.rpm(maximum))"
    }
}

extension ThermalZone {
    var title: LocalizedStringResource {
        switch self {
        case .cpuPerformance: "P-Cores"
        case .cpuEfficiency: "E-Cores"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "SSD"
        case .wireless: "Wi‑Fi"
        case .battery: "Battery"
        case .power: "Power"
        case .ambient: "Ambient"
        case .enclosure: "Palm Rest"
        }
    }
}
