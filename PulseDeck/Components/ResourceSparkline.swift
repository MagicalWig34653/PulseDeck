import PulseDeckCore
import SwiftUI

/// The last 60 seconds of a resource as a small unframed chart, shared by the resource list and
/// the menu bar panel. Draws nothing where no history exists (e.g. GPU utilization Not
/// Available, desktops for energy) rather than an empty or zero line.
struct ResourceSparkline: View {
    @Environment(AppState.self) private var appState
    let category: ResourceCategory

    var body: some View {
        if let sparkline {
            TimeSeriesChart(
                history: sparkline.history,
                series: sparkline.series,
                yAxis: sparkline.yAxis,
                format: sparkline.format,
                accessibilityLabel: Text(category.title),
                isCompact: true,
                allowsHover: false,
                isDecorative: true
            )
        }
    }

    private struct Sparkline {
        let history: MetricHistory
        let series: [ChartSeries]
        let yAxis: ChartYAxis
        let format: (Double) -> String
    }

    private var sparkline: Sparkline? {
        let history = appState.history
        switch category {
        case .cpu:
            return Sparkline(history: history.cpu, series: [ChartSeries(label: "Total", color: .blue, value: { sample in
                guard let user = sample.values[0], let system = sample.values[1] else { return nil }
                return user + system
            })], yAxis: .fraction, format: Format.percent)
        case .memory:
            return Sparkline(history: history.memory, series: [ChartSeries(label: "Used", color: .purple, value: { $0.values[0] })],
                             yAxis: .fraction, format: Format.percent)
        case .network:
            guard let primary = appState.latestSnapshot?.network.value?.primaryInterfaceID,
                  let interfaceHistory = history.network[primary] else { return nil }
            return Sparkline(history: interfaceHistory, series: [
                ChartSeries(label: "Download", color: .blue, value: { $0.values[0] }),
                ChartSeries(label: "Upload", color: .orange, value: { $0.values[1] }, isFilled: false),
            ], yAxis: .automatic(minimum: 10_000), format: Format.rate)
        case .disks:
            guard let first = appState.latestSnapshot?.disks.value?.first,
                  let diskHistory = history.disks[first.id] else { return nil }
            return Sparkline(history: diskHistory, series: [
                ChartSeries(label: "Read", color: .teal, value: { $0.values[0] }),
                ChartSeries(label: "Write", color: .orange, value: { $0.values[1] }, isFilled: false),
            ], yAxis: .automatic(minimum: 100_000), format: Format.rate)
        case .gpu:
            guard let first = appState.latestSnapshot?.gpu.value?.devices.first,
                  first.utilization.unavailableReason != .noPublicAPI,
                  let gpuHistory = history.gpus[first.id] else { return nil }
            return Sparkline(history: gpuHistory, series: [ChartSeries(label: "Utilization", color: .green, value: { $0.values[0] })],
                             yAxis: .fraction, format: Format.percent)
        case .energy:
            // Only where a power value can exist (portables); desktops show no sparkline.
            guard let energy = appState.latestSnapshot?.energy.value,
                  energy.battery.value != nil || energy.systemPowerWatts.value != nil else { return nil }
            return Sparkline(history: history.energy, series: [
                ChartSeries(label: "System Power In", color: .green, value: { $0.values[0] }),
                ChartSeries(label: "Battery Discharging", color: .orange, value: { $0.values[2] }, isFilled: false),
            ], yAxis: .automatic(minimum: 10), format: Format.watts)
        }
    }
}
