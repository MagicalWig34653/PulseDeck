import Charts
import PulseDeckCore
import SwiftUI

/// Memory page (SPEC §14): used-memory chart, compression chart, composition as bar or pie
/// chart, and statistics.
struct MemoryPerformanceView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("memoryCompositionStyle") private var compositionStyle: CompositionStyle = .bar

    enum CompositionStyle: String, CaseIterable, Identifiable {
        case bar
        case pie

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .bar: "Bar"
            case .pie: "Pie Chart"
            }
        }

        var systemImage: String {
            switch self {
            case .bar: "rectangle.split.3x1"
            case .pie: "chart.pie"
            }
        }
    }

    private var state: MetricState<MemorySnapshot>? { appState.latestSnapshot?.memory }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            CategoryUnavailableView(category: .memory, reason: reason)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeader(
                    title: state?.value.map { String(localized: "\(Format.memory($0.physicalTotal)) Memory") } ?? String(localized: "Memory"),
                    subtitle: state?.value?.pressure.value.map { String(localized: "Memory pressure: \($0.label)") },
                    value: state?.flatMap { .available(Format.memory($0.used)) }
                )

                TimeSeriesChart(
                    history: appState.history.memory,
                    series: [
                        ChartSeries(label: "Used", color: .purple, value: { $0.values[0] }),
                        ChartSeries(label: "Used memory", color: .purple, value: { $0.values[1] }, isDrawn: false, format: Format.memory),
                    ],
                    yAxis: .fraction,
                    format: Format.precisePercent,
                    accessibilityLabel: Text("Memory used")
                )
                .frame(height: 200)

                DetailSection(title: "Usage") {
                    StatisticView(label: "Used", value: state?.flatMap { .available("\(Format.memory($0.used)) (\(Format.percent($0.usedFraction)))") },
                                  help: "App Memory + Wired + Compressed.")
                    StatisticView(label: "Available", value: state?.flatMap { .available(Format.memory($0.available)) })
                    StatisticView(label: "Free", value: state?.flatMap { .available(Format.memory($0.free)) })
                    StatisticView(label: "Swap Used", value: state?.flatMap { memory in
                        memory.swap.map { swap in
                            swap.total == 0 ? String(localized: "Not in use") : "\(Format.memory(swap.used)) / \(Format.memory(swap.total))"
                        }
                    })
                    StatisticView(
                        label: "Memory Pressure",
                        value: state?.flatMap { memory in memory.pressure.map(\.label) },
                        help: "Read from the kernel's memory pressure level (undocumented sysctl kern.memorystatus_vm_pressure_level)."
                    )
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        if let memory = state?.value {
                            switch compositionStyle {
                            case .bar: MemoryCompositionBar(memory: memory)
                            case .pie: MemoryCompositionPie(memory: memory)
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                                  alignment: .leading, spacing: 14) {
                            StatisticView(label: "App Memory", value: state?.flatMap { .available(Format.memory($0.appMemory)) })
                            StatisticView(label: "Wired", value: state?.flatMap { .available(Format.memory($0.wired)) },
                                          help: "Memory the kernel keeps resident; it cannot be compressed or paged out.")
                            StatisticView(label: "Compressed", value: state?.flatMap { .available(Format.memory($0.compressed)) })
                            StatisticView(label: "Cached Files", value: state?.flatMap { .available(Format.memory($0.cachedFiles)) },
                                          help: "File data kept in memory; reclaimed by the system when needed.")
                        }
                    }
                    .padding(8)
                } label: {
                    HStack {
                        Text("Composition")
                            .font(.headline)
                        Spacer()
                        Picker("Style", selection: $compositionStyle) {
                            ForEach(CompositionStyle.allCases) { style in
                                Label {
                                    Text(style.title)
                                } icon: {
                                    Image(systemName: style.systemImage)
                                }
                                .tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        TimeSeriesChart(
                            history: appState.history.memory,
                            series: [
                                ChartSeries(label: "Original size", color: .pink.opacity(0.55), value: { $0.values[3] }, isFilled: false),
                                ChartSeries(label: "Compressed", color: .pink, value: { $0.values[2] }),
                            ],
                            yAxis: .automatic(minimum: Self.minimumCompressionScale),
                            format: Format.memory,
                            accessibilityLabel: Text("Memory compression")
                        )
                        .frame(height: 140)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                                  alignment: .leading, spacing: 14) {
                            StatisticView(label: "Compressed", value: state?.flatMap { .available(Format.memory($0.compressed)) },
                                          help: "Physical memory the compressor occupies.")
                            StatisticView(label: "Original Size", value: state?.flatMap { memory in
                                memory.compressedOriginal > 0 ? .available(Format.memory(memory.compressedOriginal)) : .unavailable(.notApplicable)
                            }, help: "Size of the compressed data before compression.")
                            StatisticView(label: "Saved", value: state?.flatMap { memory in
                                memory.compressedOriginal > memory.compressed
                                    ? .available(Format.memory(memory.compressedOriginal - memory.compressed)) : .unavailable(.notApplicable)
                            }, help: "Memory freed by compression.")
                            StatisticView(label: "Ratio", value: state?.flatMap { memory in
                                memory.compressionRatio.map { .available(String(localized: "\($0.formatted(.number.precision(.fractionLength(1)))) : 1")) }
                                    ?? .unavailable(.notApplicable)
                            })
                        }
                    }
                    .padding(8)
                } label: {
                    Text("Compression")
                        .font(.headline)
                }
            }
            .padding(20)
        }
    }
}

/// Smallest compression-chart scale (64 MB), so a nearly idle compressor is not magnified.
extension MemoryPerformanceView {
    static let minimumCompressionScale = 64.0 * 1_048_576
}

/// Pie chart of physical memory, at most six slices: the four composition parts, free memory,
/// and whatever the counters leave unassigned ("Other").
private struct MemoryCompositionPie: View {
    let memory: MemorySnapshot

    private struct Slice: Identifiable {
        let id: Int
        let label: LocalizedStringResource
        let bytes: UInt64
        let color: Color
    }

    private var slices: [Slice] {
        var slices = [
            Slice(id: 0, label: "App Memory", bytes: memory.appMemory, color: .purple),
            Slice(id: 1, label: "Wired", bytes: memory.wired, color: .orange),
            Slice(id: 2, label: "Compressed", bytes: memory.compressed, color: .pink),
            Slice(id: 3, label: "Cached Files", bytes: memory.cachedFiles, color: .teal),
            Slice(id: 4, label: "Free", bytes: memory.free, color: .gray.opacity(0.35)),
        ]
        let assigned = slices.reduce(UInt64(0)) { $0 &+ $1.bytes }
        if memory.physicalTotal > assigned {
            slices.append(Slice(id: 5, label: "Other", bytes: memory.physicalTotal - assigned, color: .secondary.opacity(0.25)))
        }
        return slices.filter { $0.bytes > 0 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Chart(slices) { slice in
                SectorMark(angle: .value("Bytes", Double(slice.bytes)), innerRadius: .ratio(0.55), angularInset: 1)
                    .foregroundStyle(slice.color)
            }
            .chartLegend(.hidden)
            .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.color).frame(width: 8, height: 8)
                        Text(slice.label)
                        Spacer(minLength: 12)
                        Text(verbatim: Format.memory(slice.bytes))
                            .monospacedDigit()
                        Text(verbatim: Format.percent(Double(slice.bytes) / Double(max(memory.physicalTotal, 1))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: 320)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Memory composition"))
        .accessibilityValue(Text(verbatim: slices.map { "\(String(localized: $0.label)) \(Format.memory($0.bytes))" }.joined(separator: ", ")))
    }
}

/// Horizontal bar showing how physical memory is used, like Activity Monitor's memory graph.
private struct MemoryCompositionBar: View {
    let memory: MemorySnapshot

    private var segments: [(label: LocalizedStringResource, bytes: UInt64, color: Color)] {
        [
            ("App Memory", memory.appMemory, .purple),
            ("Wired", memory.wired, .orange),
            ("Compressed", memory.compressed, .pink),
            ("Cached Files", memory.cachedFiles, .teal),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color.gradient)
                            .frame(width: width(of: segment.bytes, in: geometry.size.width))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(.quaternary, in: .capsule)
            .clipShape(.capsule)

            HStack(spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(spacing: 4) {
                        Circle().fill(segment.color).frame(width: 7, height: 7)
                        Text(segment.label)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Memory composition"))
        .accessibilityValue(Text(verbatim: segments.map { "\(String(localized: $0.label)) \(Format.memory($0.bytes))" }.joined(separator: ", ")))
    }

    private func width(of bytes: UInt64, in total: CGFloat) -> CGFloat {
        guard memory.physicalTotal > 0 else { return 0 }
        return total * CGFloat(Double(bytes) / Double(memory.physicalTotal))
    }
}
