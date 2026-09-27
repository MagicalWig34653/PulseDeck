import PulseDeckCore
import SwiftUI

/// Disks page (SPEC §15): each storage device with read/write throughput, capacity and
/// cumulative transfer. Active time has no public API (TECHNICAL_LIMITATIONS.md L‑3).
struct DiskPerformanceView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: DiskSnapshot.ID?

    private var state: MetricState<[DiskSnapshot]>? { appState.latestSnapshot?.disks }
    private var disks: [DiskSnapshot] { state?.value ?? [] }

    private var selectedDisk: DiskSnapshot? {
        disks.first { $0.id == selection } ?? disks.first
    }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            ContentUnavailableView {
                Label("Disks", systemImage: ResourceCategory.disks.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let selected = selectedDisk
                    DetailHeader(
                        title: selected?.name ?? String(localized: "Disks"),
                        subtitle: selected.map(Self.subtitle),
                        value: selected.map(Self.throughput)
                    )

                    TimeSeriesChart(
                        history: selected.flatMap { appState.history.disks[$0.id] } ?? MetricHistory(seriesCount: 2),
                        series: [
                            ChartSeries(label: "Read", color: .teal, value: { $0.values[0] }),
                            ChartSeries(label: "Write", color: .orange, value: { $0.values[1] }),
                        ],
                        yAxis: .automatic(minimum: Self.minimumChartScale),
                        format: Format.rate,
                        accessibilityLabel: Text("Disk throughput of \(selected?.name ?? "")")
                    )
                    .frame(height: 200)

                    if let selected {
                        DetailSection(title: "Throughput") {
                            StatisticView(label: "Read", value: selected.readBytesPerSecond.map(Format.rate))
                            StatisticView(label: "Write", value: selected.writeBytesPerSecond.map(Format.rate))
                            StatisticView(label: "Total Read", value: selected.totalBytesRead.map(Format.storage),
                                          help: "Bytes read since the device was attached.")
                            StatisticView(label: "Total Written", value: selected.totalBytesWritten.map(Format.storage),
                                          help: "Bytes written since the device was attached.")
                            StatisticView(label: "Active Time", value: selected.activeTime.map(Format.percent),
                                          help: "macOS exposes no busy-time counter for storage devices.")
                        }
                        DetailSection(title: "Capacity") {
                            StatisticView(label: "Capacity", value: selected.capacityBytes.map(Format.storage))
                            StatisticView(label: "Available", value: selected.availableBytes.map(Format.storage),
                                          help: "Free space on the device's mounted volumes, as Finder reports it (includes purgeable space).")
                            StatisticView(label: "Used", value: Self.used(selected),
                                          help: "Capacity minus available space; includes partitions that are not mounted.")
                            StatisticView(label: "Removable", value: .available(selected.isRemovable ? String(localized: "Yes") : String(localized: "No")))
                        }
                    }

                    SectionHeader(title: "Devices")
                    diskTable
                }
                .padding(20)
            }
        }
    }

    /// 100 kB/s: keeps idle-time metadata writes from filling the chart.
    private static let minimumChartScale = 100_000.0

    private static func subtitle(_ disk: DiskSnapshot) -> String {
        [disk.connection.label, disk.id, disk.capacityBytes.value.map(Format.storage)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func throughput(_ disk: DiskSnapshot) -> MetricState<String> {
        disk.readBytesPerSecond.flatMap { read in
            disk.writeBytesPerSecond.map { written in "R \(Format.rate(read))  W \(Format.rate(written))" }
        }
    }

    private static func used(_ disk: DiskSnapshot) -> MetricState<String> {
        disk.capacityBytes.flatMap { capacity in
            disk.availableBytes.map { available in Format.storage(capacity > available ? capacity - available : 0) }
        }
    }

    private var diskTable: some View {
        let rows = disks
        return Table(rows, selection: $selection) {
            TableColumn("Device") { disk in
                Label {
                    Text(verbatim: disk.name)
                } icon: {
                    Image(systemName: disk.connection.systemImage)
                        .foregroundStyle(.tint)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("Name") { disk in
                Text(verbatim: disk.id).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Read") { disk in
                MetricStateText(state: disk.readBytesPerSecond.map(Format.rate))
            }
            .width(min: 70, ideal: 80)
            TableColumn("Write") { disk in
                MetricStateText(state: disk.writeBytesPerSecond.map(Format.rate))
            }
            .width(min: 70, ideal: 80)
            TableColumn("Capacity") { disk in
                MetricStateText(state: disk.capacityBytes.map(Format.storage))
            }
            .width(min: 70, ideal: 90)
            TableColumn("Available") { disk in
                MetricStateText(state: disk.availableBytes.map(Format.storage))
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: NetworkPerformanceView.tableHeight(rows: rows.count))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}
