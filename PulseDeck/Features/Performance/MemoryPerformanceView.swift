import Charts
import PulseDeckCore
import SwiftUI

/// Memory page (SPEC §14): used-memory chart, composition bar, optional pie chart of memory by
/// process, compression chart and statistics.
struct MemoryPerformanceView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PreferenceKey.memoryProcessPie) private var showsProcessPie = false

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
                            MemoryCompositionBar(memory: memory)
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
                    Text("Composition")
                        .font(.headline)
                }

                GroupBox {
                    if showsProcessPie {
                        ProcessMemoryPie(processes: appState.latestSnapshot?.processes)
                            .padding(8)
                    } else {
                        Text("Shows which apps and processes use the most memory. Turning it on samples all processes while this page is open.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                } label: {
                    HStack {
                        Text("Memory by Process")
                            .font(.headline)
                        Spacer()
                        Toggle("Show pie chart", isOn: $showsProcessPie)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
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

/// Pie chart of memory by process: the five largest consumers (grouped by name) and the rest,
/// by physical footprint — the value Activity Monitor's Memory column shows. At most six slices.
private struct ProcessMemoryPie: View {
    let processes: MetricState<[ProcessSnapshot]>?

    private static let colors: [Color] = [.purple, .blue, .teal, .green, .orange]
    private static let otherColor = Color.gray.opacity(0.45)

    var body: some View {
        switch processes {
        case .available(let processes)?:
            chart(ProcessMemoryBreakdown(processes: processes))
        case .unavailable(let reason)? where !reason.isTransient:
            StatisticView(label: "Memory by Process", value: .unavailable(reason))
        default:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    private func color(of slice: ProcessMemoryBreakdown.Slice, at index: Int) -> Color {
        slice.isOther ? Self.otherColor : Self.colors[index % Self.colors.count]
    }

    private func label(of slice: ProcessMemoryBreakdown.Slice) -> String {
        guard let name = slice.name else {
            return String(localized: "Other processes (\(slice.processCount))")
        }
        return slice.processCount > 1 ? "\(name) (\(slice.processCount))" : name
    }

    private func chart(_ breakdown: ProcessMemoryBreakdown) -> some View {
        let slices = Array(breakdown.slices.enumerated())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 24) {
                Chart(slices, id: \.element.id) { index, slice in
                    SectorMark(angle: .value("Bytes", Double(slice.bytes)), innerRadius: .ratio(0.55), angularInset: 1)
                        .foregroundStyle(color(of: slice, at: index))
                }
                .chartLegend(.hidden)
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slices, id: \.element.id) { index, slice in
                        HStack(spacing: 6) {
                            Circle().fill(color(of: slice, at: index)).frame(width: 8, height: 8)
                            Text(verbatim: label(of: slice))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(verbatim: Format.memory(slice.bytes))
                                .monospacedDigit()
                            Text(verbatim: Format.percent(Double(slice.bytes) / Double(max(breakdown.totalBytes, 1))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: 360)
            }
            if breakdown.excludedProcessCount > 0 {
                Text("\(breakdown.excludedProcessCount) processes of other users are not included: macOS does not report their memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Memory by process"))
        .accessibilityValue(Text(verbatim: breakdown.slices.map { "\(label(of: $0)) \(Format.memory($0.bytes))" }.joined(separator: ", ")))
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
