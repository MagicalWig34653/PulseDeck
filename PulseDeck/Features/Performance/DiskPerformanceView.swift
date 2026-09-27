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
                VStack(alignment: .leading, spacing: 18) {
                    let selected = selectedDisk
                    DetailHeader(
                        title: selected?.name ?? String(localized: "Disks"),
                        subtitle: selected.map { "\($0.connection.label) · \($0.id)" }
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
                    .frame(height: 220)

                    if let selected {
                        statistics(for: selected)
                    }

                    Text("Devices")
                        .font(.headline)
                    diskTable
                }
                .padding(24)
            }
        }
    }

    /// 100 KB/s: keeps idle-time metadata writes from filling the chart.
    private static let minimumChartScale = 100_000.0

    private func statistics(for disk: DiskSnapshot) -> some View {
        StatisticsGrid {
            StatisticView(label: "Read speed", value: disk.readBytesPerSecond.map(Format.rate))
            StatisticView(label: "Write speed", value: disk.writeBytesPerSecond.map(Format.rate))
            StatisticView(label: "Capacity", value: disk.capacityBytes.map(Format.storage))
            StatisticView(label: "Available", value: disk.availableBytes.map(Format.storage),
                          help: "Free space on the device's mounted volumes, as Finder reports it (includes purgeable space).")
            StatisticView(label: "Used", value: disk.capacityBytes.flatMap { capacity in
                disk.availableBytes.map { available in Format.storage(capacity > available ? capacity - available : 0) }
            }, help: "Capacity minus available space; includes partitions that are not mounted.")
            StatisticView(label: "Total read", value: disk.totalBytesRead.map(Format.storage),
                          help: "Bytes read since the device was attached.")
            StatisticView(label: "Total written", value: disk.totalBytesWritten.map(Format.storage),
                          help: "Bytes written since the device was attached.")
            StatisticView(label: "Active time", value: disk.activeTime.map(Format.percent),
                          help: "macOS exposes no busy-time counter for storage devices.")
            StatisticView(label: "Removable", value: .available(disk.isRemovable ? String(localized: "Yes") : String(localized: "No")))
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
            TableColumn("Write") { disk in
                MetricStateText(state: disk.writeBytesPerSecond.map(Format.rate))
            }
            TableColumn("Capacity") { disk in
                MetricStateText(state: disk.capacityBytes.map(Format.storage))
            }
            TableColumn("Available") { disk in
                MetricStateText(state: disk.availableBytes.map(Format.storage))
            }
        }
        .frame(height: NetworkPerformanceView.tableHeight(rows: rows.count))
    }
}
