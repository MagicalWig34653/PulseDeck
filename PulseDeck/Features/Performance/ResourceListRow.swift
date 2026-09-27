import PulseDeckCore
import SwiftUI

/// One row of the resource list: icon, name, compact live preview and a sparkline of the last
/// 60 seconds (SPEC §10).
struct ResourceListRow: View {
    @Environment(AppState.self) private var appState
    let category: ResourceCategory

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    MetricStateText(state: appState.latestSnapshot?.preview(for: category))
                        .font(.caption)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: category.systemImage)
            }
            Spacer(minLength: 4)
            if let sparkline {
                TimeSeriesChart(
                    history: sparkline.history,
                    series: sparkline.series,
                    yAxis: sparkline.yAxis,
                    format: sparkline.format,
                    accessibilityLabel: Text(category.title),
                    isCompact: true,
                    allowsHover: false
                )
                .frame(width: 56, height: 26)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
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
        case .gpu, .energy:
            return nil
        }
    }
}
