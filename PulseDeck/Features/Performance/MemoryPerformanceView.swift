import PulseDeckCore
import SwiftUI

/// Memory page (SPEC §14): used-memory chart, composition bar and statistics.
struct MemoryPerformanceView: View {
    @Environment(AppState.self) private var appState

    private var state: MetricState<MemorySnapshot>? { appState.latestSnapshot?.memory }

    var body: some View {
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
                        memory.swap.map { "\(Format.memory($0.used)) / \(Format.memory($0.total))" }
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
            }
            .padding(20)
        }
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
