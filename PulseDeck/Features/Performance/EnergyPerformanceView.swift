import PulseDeckCore
import SwiftUI

/// Energy page (SPEC §19). Keeps reported, derived and unavailable values visibly apart:
///
/// - *System Power In*: reported by the battery controller (undocumented `SystemPowerIn`,
///   approved, portables only); not applicable on battery power.
/// - *Battery Power*: derived from voltage × current; battery power only, never system power.
/// - CPU and GPU power: no public API (TECHNICAL_LIMITATIONS.md L‑2).
struct EnergyPerformanceView: View {
    @Environment(AppState.self) private var appState

    private var state: MetricState<EnergySnapshot>? { appState.latestSnapshot?.energy }

    /// 10 W: keeps small fluctuations of an idle Mac from filling the chart.
    private static let minimumChartScale = 10.0

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            ContentUnavailableView {
                Label("Energy", systemImage: ResourceCategory.energy.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let energy = state?.value
                    let battery = energy?.battery.value
                    DetailHeader(
                        title: battery != nil ? String(localized: "Internal Battery") : String(localized: "Energy"),
                        subtitle: battery.map(Self.subtitle),
                        value: energy.map { energy in energy.battery.map { Format.percent($0.charge) } }
                    )

                    if let energy, Self.hasPowerSource(energy) {
                        TimeSeriesChart(
                            history: appState.history.energy,
                            series: [
                                ChartSeries(label: "System Power In", color: .green, value: { $0.values[0] }),
                                ChartSeries(label: "Battery Charging", color: .blue, value: { $0.values[1] }, isFilled: false),
                                ChartSeries(label: "Battery Discharging", color: .orange, value: { $0.values[2] }, isFilled: false),
                            ],
                            yAxis: .automatic(minimum: Self.minimumChartScale),
                            format: Format.watts,
                            accessibilityLabel: Text("Power")
                        )
                        .frame(height: 200)
                        VStack(alignment: .leading, spacing: 4) {
                            SourceNote(text: "System Power In is read from an undocumented battery-controller value (PowerTelemetryData “SystemPowerIn”): the power drawn from the adapter, including power used to charge the battery.")
                            SourceNote(text: "Battery power is derived from battery voltage × current. It is the battery's charge or discharge power, not the Mac's total power consumption.")
                        }
                    }

                    DetailSection(title: "Power") {
                        StatisticView(label: "System Power In", value: energy?.systemPowerWatts.map { Format.attributed($0, Format.watts) },
                                      help: "Power the Mac draws from its power adapter (undocumented source). Not applicable while running on battery.")
                        StatisticView(label: "Battery Power", value: energy?.battery.flatMap { $0.batteryPowerText },
                                      help: "Derived from battery voltage × current.")
                        StatisticView(label: "CPU Power", value: energy?.cpuPowerWatts.map { Format.attributed($0, Format.watts) },
                                      help: "macOS provides no public API for CPU package power.")
                        StatisticView(label: "GPU Power", value: energy?.gpuPowerWatts.map { Format.attributed($0, Format.watts) },
                                      help: "macOS provides no public API for GPU power.")
                        StatisticView(label: "Power Adapter", value: energy?.adapterRatingWatts.map { String(localized: "\(Format.watts($0)) rated") },
                                      help: "The adapter's rated output, not the power the Mac draws.")
                    }

                    if let battery {
                        DetailSection(title: "Battery") {
                            StatisticView(label: "Charge", value: .available(Format.percent(battery.charge)))
                            StatisticView(label: "State", value: .available(battery.stateLabel))
                            StatisticView(label: "Power Source", value: .available(battery.powerSourceLabel))
                            StatisticView(label: battery.isCharging ? "Time to Full" : "Time Remaining",
                                          value: battery.timeRemaining.map(Format.duration),
                                          help: "Estimated by macOS.")
                            StatisticView(label: "Voltage", value: battery.voltageVolts.map { String(localized: "\($0.formatted(.number.precision(.fractionLength(2)))) V") })
                            StatisticView(label: "Current", value: battery.currentAmperes.map { String(localized: "\($0.formatted(.number.precision(.fractionLength(2)))) A") },
                                          help: "Positive while charging, negative while discharging.")
                        }
                    } else if energy?.battery.unavailableReason == .unsupportedHardware {
                        GroupBox {
                            Label("This Mac has no battery.", systemImage: "battery.0percent")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private static func subtitle(_ battery: BatterySnapshot) -> String {
        var parts = [battery.stateLabel]
        if let seconds = battery.timeRemaining.value {
            parts.append(battery.isCharging
                ? String(localized: "\(Format.duration(seconds)) until full")
                : String(localized: "\(Format.duration(seconds)) remaining"))
        }
        return parts.joined(separator: " · ")
    }

    /// Whether any power value can exist on this Mac, i.e. whether a chart makes sense. Desktops
    /// without a battery controller have none.
    private static func hasPowerSource(_ energy: EnergySnapshot) -> Bool {
        energy.battery.unavailableReason != .unsupportedHardware
            || energy.systemPowerWatts.unavailableReason != .unsupportedHardware
    }
}
