import PulseDeckCore
import SwiftUI

/// CPU page (SPEC §13): overall utilization or per-logical-processor charts, plus statistics.
struct CPUPerformanceView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("cpuChartMode") private var mode: Mode = .overall

    enum Mode: String, CaseIterable, Identifiable {
        case overall
        case logicalProcessors

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .overall: "Overall Utilization"
            case .logicalProcessors: "Logical Processors"
            }
        }
    }

    private var state: MetricState<CPUSnapshot>? { appState.latestSnapshot?.cpu }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(title: String(localized: "CPU"), subtitle: state?.value?.info.modelName)

                Picker("Chart", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch mode {
                case .overall:
                    TimeSeriesChart(
                        history: appState.history.cpu,
                        series: Self.overallSeries,
                        yAxis: .fraction,
                        format: Format.precisePercent,
                        accessibilityLabel: Text("CPU utilization")
                    )
                    .frame(height: 260)
                case .logicalProcessors:
                    LogicalProcessorGrid(history: appState.history.cpuCores)
                }

                statistics
            }
            .padding(24)
        }
    }

    /// Total is drawn filled; system time is drawn as a line; user time appears on hover.
    static var overallSeries: [ChartSeries] {
        [
            ChartSeries(label: "Total", color: .blue, value: { sample in
                guard let user = sample.values[0], let system = sample.values[1] else { return nil }
                return user + system
            }),
            ChartSeries(label: "System", color: .orange, value: { $0.values[1] }, isFilled: false),
            ChartSeries(label: "User", color: .green, value: { $0.values[0] }, isDrawn: false),
        ]
    }

    private var statistics: some View {
        StatisticsGrid {
            StatisticView(label: "Utilization", value: state?.flatMap { .available(Format.percent($0.total)) })
            StatisticView(label: "User", value: state?.flatMap { .available(Format.percent($0.user)) })
            StatisticView(label: "System", value: state?.flatMap { .available(Format.percent($0.system)) })
            StatisticView(label: "Idle", value: state?.flatMap { .available(Format.percent($0.idle)) })
            StatisticView(label: "Logical processors", value: state?.flatMap { .available("\($0.info.logicalProcessorCount)") })
            StatisticView(label: "Physical cores", value: state?.flatMap { cpu in
                cpu.info.physicalCoreCount.map { MetricState.available("\($0)") } ?? .unavailable(.unsupportedHardware)
            })
            ForEach(state?.value?.info.performanceLevels ?? [], id: \.name) { level in
                StatisticView(label: "\(level.name) cores", value: .available("\(level.physicalCoreCount)"))
            }
        }
    }
}

/// One small chart per logical processor (SPEC §13 "Logical Processors" mode), each with hover.
private struct LogicalProcessorGrid: View {
    let history: MetricHistory

    var body: some View {
        if history.seriesCount == 0 {
            Text(verbatim: AppState.placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(0..<history.seriesCount, id: \.self) { core in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CPU \(core)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TimeSeriesChart(
                            history: history,
                            series: [ChartSeries(label: "CPU \(core)", color: .blue, value: { $0.values[core] })],
                            yAxis: .fraction,
                            format: Format.precisePercent,
                            accessibilityLabel: Text("CPU \(core) utilization"),
                            isCompact: true
                        )
                        .frame(height: 70)
                    }
                }
            }
        }
    }
}
