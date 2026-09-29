import PulseDeckCore
import SwiftUI

/// CPU page (SPEC §13): overall utilization, performance vs. efficiency cores, or
/// per-logical-processor charts; cluster frequencies (private IOReport, labelled); statistics.
struct CPUPerformanceView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("cpuChartMode") private var mode: Mode = .overall

    enum Mode: String, CaseIterable, Identifiable {
        case overall
        case coreTypes
        case logicalProcessors

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .overall: "Overall Utilization"
            case .coreTypes: "Core Types"
            case .logicalProcessors: "Logical Processors"
            }
        }
    }

    private var state: MetricState<CPUSnapshot>? { appState.latestSnapshot?.cpu }
    private var frequency: MetricState<CPUFrequencySnapshot>? { appState.latestSnapshot?.cpuFrequency }
    private var coreTypes: [CoreType] { state?.value?.info.coreTypes ?? [] }

    /// The Core Types chart needs both kinds (Apple silicon with P- and E-cores).
    private var availableModes: [Mode] {
        Set(coreTypes).count > 1 ? Mode.allCases : Mode.allCases.filter { $0 != .coreTypes }
    }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            CategoryUnavailableView(category: .cpu, reason: reason)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(
                    title: state?.value?.info.modelName ?? String(localized: "Processor"),
                    subtitle: state?.value.map { Self.topologyDescription($0.info) },
                    value: state?.flatMap { .available(Format.percent($0.total)) }
                )

                Picker("Chart", selection: $mode) {
                    ForEach(availableModes) { mode in
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
                    .frame(height: 240)
                case .coreTypes where Set(coreTypes).count > 1:
                    TimeSeriesChart(
                        history: appState.history.cpuCores,
                        series: Self.coreTypeSeries(coreTypes),
                        yAxis: .fraction,
                        format: Format.precisePercent,
                        accessibilityLabel: Text("Utilization of performance and efficiency cores")
                    )
                    .frame(height: 240)
                case .coreTypes, .logicalProcessors:
                    LogicalProcessorGrid(history: appState.history.cpuCores, coreTypes: coreTypes)
                }

                if mode != .overall, state?.value?.info.coreTypeSource == .performanceLevelOrder {
                    SourceNote(text: "Core types are derived from the number of performance and efficiency cores that macOS reports, assuming efficiency cores are numbered first.")
                }

                frequencySection

                DetailSection(title: "Utilization") {
                    StatisticView(label: "Total", value: state?.flatMap { .available(Format.percent($0.total)) })
                    StatisticView(label: "User", value: state?.flatMap { .available(Format.percent($0.user)) },
                                  help: "Time spent running apps and other user processes (including low-priority “nice” time).")
                    StatisticView(label: "System", value: state?.flatMap { .available(Format.percent($0.system)) },
                                  help: "Time spent in the macOS kernel.")
                    StatisticView(label: "Idle", value: state?.flatMap { .available(Format.percent($0.idle)) })
                }

                DetailSection(title: "Processor") {
                    StatisticView(label: "Logical processors", value: state?.flatMap { .available("\($0.info.logicalProcessorCount)") })
                    StatisticView(label: "Physical cores", value: state?.flatMap { cpu in
                        cpu.info.physicalCoreCount.map { MetricState.available("\($0)") } ?? .unavailable(.unsupportedHardware)
                    })
                    ForEach(state?.value?.info.performanceLevels ?? [], id: \.name) { level in
                        StatisticView(label: "\(level.name) cores", value: .available("\(level.physicalCoreCount)"))
                    }
                    StatisticView(label: "Uptime", value: state?.flatMap { cpu in
                        cpu.info.bootTime.map { .available(Format.uptime(since: $0)) } ?? .unavailable(.transientFailure("no boot time"))
                    }, help: "Time since macOS started (kern.boottime).")
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var frequencySection: some View {
        switch frequency {
        case .available(let snapshot)?:
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    TimeSeriesChart(
                        history: appState.history.cpuFrequency,
                        series: [
                            ChartSeries(label: "Performance cores", color: CoreType.performance.color, value: { $0.values[1] }, isFilled: false),
                            ChartSeries(label: "Efficiency cores", color: CoreType.efficiency.color, value: { $0.values[0] }, isFilled: false),
                        ],
                        yAxis: .automatic(minimum: Self.minimumFrequencyScale),
                        format: Format.frequency,
                        accessibilityLabel: Text("CPU cluster frequency")
                    )
                    .frame(height: 120)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                              alignment: .leading, spacing: 14) {
                        ForEach(snapshot.clusters) { cluster in
                            StatisticView(
                                label: Self.clusterLabel(cluster, in: snapshot),
                                value: .available(cluster.activeFrequencyHz.map(Format.frequency) ?? String(localized: "Idle")),
                                help: Self.clusterHelp(cluster)
                            )
                        }
                    }
                    SourceNote(text: "Frequencies are read from a private macOS library (IOReport CPU performance states) and the power manager's frequency tables. They are the average while each cluster was running during the last interval.")
                }
                .padding(8)
            } label: {
                Text("Frequency")
                    .font(.headline)
            }
        case .unavailable(let reason)? where !reason.isTransient:
            DetailSection(title: "Frequency") {
                StatisticView(label: "Current frequency", value: .unavailable(reason))
            }
        default:
            EmptyView()
        }
    }

    /// 1 GHz: the axis never zooms into idle-clock noise.
    private static let minimumFrequencyScale = 1e9

    /// "Performance cores", or "Performance cores 2" on chips with several P-clusters.
    private static func clusterLabel(_ cluster: ClusterFrequency, in snapshot: CPUFrequencySnapshot) -> LocalizedStringResource {
        let type = cluster.coreType ?? .performance
        let sameType = snapshot.clusters.filter { $0.coreType == cluster.coreType }
        guard sameType.count > 1, let index = sameType.firstIndex(of: cluster) else { return type.clusterTitle }
        return "\(String(localized: type.clusterTitle)) \(index + 1)"
    }

    private static func clusterHelp(_ cluster: ClusterFrequency) -> LocalizedStringResource {
        let maximum = cluster.maximumFrequencyHz.map(Format.frequency) ?? AppState.placeholder
        return "Running \(Format.percent(cluster.activeFraction)) of the interval · maximum \(maximum)"
    }

    /// Mean utilization of the logical processors of each core type.
    private static func coreTypeSeries(_ types: [CoreType]) -> [ChartSeries] {
        [CoreType.performance, .efficiency].map { type in
            let indices = types.indices.filter { types[$0] == type }
            return ChartSeries(label: type.clusterTitle, color: type.color, value: { sample in
                let values = indices.compactMap { sample.values.indices.contains($0) ? sample.values[$0] : nil }
                guard !values.isEmpty, values.count == indices.count else { return nil }
                return values.reduce(0, +) / Double(values.count)
            }, isFilled: type == .performance)
        }
    }

    /// "10 cores (4 Performance + 6 Efficiency) · 10 logical processors".
    private static func topologyDescription(_ info: CPUInfo) -> String {
        var parts: [String] = []
        if let physical = info.physicalCoreCount {
            var cores = String(localized: "\(physical) cores")
            if info.performanceLevels.count > 1 {
                let clusters = info.performanceLevels.map { "\($0.physicalCoreCount) \($0.name)" }.joined(separator: " + ")
                cores += " (\(clusters))"
            }
            parts.append(cores)
        }
        parts.append(String(localized: "\(info.logicalProcessorCount) logical processors"))
        return parts.joined(separator: " · ")
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
}

/// One small chart per logical processor (SPEC §13 "Logical Processors" mode), each with hover.
/// On Apple silicon each chart is labelled and colored as a performance or efficiency core.
private struct LogicalProcessorGrid: View {
    let history: MetricHistory
    /// Per logical processor; empty on Macs without core types. Colors P- and E-cores apart.
    let coreTypes: [CoreType]

    var body: some View {
        if history.seriesCount == 0 {
            Text(verbatim: AppState.placeholder)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if Set(coreTypes).count > 1 {
                    legend
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(0..<history.seriesCount, id: \.self) { core in
                        cell(core: core, type: coreTypes.indices.contains(core) ? coreTypes[core] : nil)
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([CoreType.performance, .efficiency], id: \.self) { type in
                HStack(spacing: 5) {
                    CoreTypeBadge(type: type)
                    Text(type.clusterTitle)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func cell(core: Int, type: CoreType?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("CPU \(core)")
                if let type {
                    CoreTypeBadge(type: type)
                }
                Spacer()
                Text(verbatim: history.latest.flatMap { $0.values[core] }.map(Format.percent) ?? AppState.placeholder)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TimeSeriesChart(
                history: history,
                series: [ChartSeries(label: "CPU \(core)", color: type?.color ?? .blue, value: { $0.values[core] })],
                yAxis: .fraction,
                format: Format.precisePercent,
                accessibilityLabel: type.map { Text("CPU \(core), \(Text($0.coreTitle)), utilization") }
                    ?? Text("CPU \(core) utilization"),
                isCompact: true,
                isFramed: true,
                scrollsSmoothly: true
            )
            .frame(height: 72)
        }
    }
}

/// "P" / "E" in a small capsule of the core type's color.
private struct CoreTypeBadge: View {
    let type: CoreType

    var body: some View {
        Text(verbatim: type.shortLabel)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 14)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(type.color.gradient, in: .capsule)
            .help(Text(type.coreTitle))
            .accessibilityLabel(Text(type.coreTitle))
    }
}

extension CoreType {
    var color: Color {
        switch self {
        case .performance: .blue
        case .efficiency: .mint
        }
    }

    var clusterTitle: LocalizedStringResource {
        switch self {
        case .performance: "Performance cores"
        case .efficiency: "Efficiency cores"
        }
    }

    /// Singular, for one logical processor.
    var coreTitle: LocalizedStringResource {
        switch self {
        case .performance: "Performance core"
        case .efficiency: "Efficiency core"
        }
    }

    /// "P" / "E" badge in the per-core grid.
    var shortLabel: String {
        switch self {
        case .performance: String(localized: "P", comment: "Performance core badge")
        case .efficiency: String(localized: "E", comment: "Efficiency core badge")
        }
    }
}
