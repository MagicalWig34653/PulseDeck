import PulseDeckCore
import SwiftUI

/// Network page (SPEC §16, §17): every interface individually — Ethernet, Wi‑Fi, bridges,
/// Thunderbolt, VPN/tunnels — with a chart for the selected one.
struct NetworkPerformanceView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: NetworkInterfaceSnapshot.ID?
    @AppStorage("showAllNetworkInterfaces") private var showsAllInterfaces = false

    private var state: MetricState<NetworkSnapshot>? { appState.latestSnapshot?.network }

    private var interfaces: [NetworkInterfaceSnapshot] {
        guard let network = state?.value else { return [] }
        let visible = showsAllInterfaces ? network.interfaces : network.interfaces.filter { !$0.isNormallyHidden }
        // Primary interface first, then interfaces that are up, then by name.
        return visible.sorted { lhs, rhs in
            let lhsPrimary = lhs.id == network.primaryInterfaceID
            let rhsPrimary = rhs.id == network.primaryInterfaceID
            if lhsPrimary != rhsPrimary { return lhsPrimary }
            if lhs.isUp != rhs.isUp { return lhs.isUp }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private var selectedInterface: NetworkInterfaceSnapshot? {
        let list = interfaces
        return list.first { $0.id == selection } ?? list.first
    }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            ContentUnavailableView {
                Label("Network Interfaces", systemImage: ResourceCategory.network.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let selected = selectedInterface
                    DetailHeader(
                        title: selected?.title ?? String(localized: "Network Interfaces"),
                        subtitle: selected.map { "\($0.kind.label) · \($0.id)" }
                    )

                    TimeSeriesChart(
                        history: selected.flatMap { appState.history.network[$0.id] } ?? MetricHistory(seriesCount: 2),
                        series: [
                            ChartSeries(label: "Download", color: .blue, value: { $0.values[0] }),
                            ChartSeries(label: "Upload", color: .orange, value: { $0.values[1] }),
                        ],
                        yAxis: .automatic(minimum: Self.minimumChartScale),
                        format: Format.rate,
                        accessibilityLabel: Text("Network throughput of \(selected?.id ?? "")")
                    )
                    .frame(height: 220)

                    if let selected {
                        statistics(for: selected)
                    }

                    HStack {
                        Text("Interfaces")
                            .font(.headline)
                        Spacer()
                        Toggle("Show all interfaces", isOn: $showsAllInterfaces)
                            .toggleStyle(.checkbox)
                            .help("Also show loopback and interfaces that are down and have never carried traffic.")
                    }

                    interfaceTable
                }
                .padding(24)
            }
        }
    }

    /// Keeps the axis from amplifying background chatter on an idle link (10 KB/s).
    private static let minimumChartScale = 10_000.0

    private func statistics(for interface: NetworkInterfaceSnapshot) -> some View {
        StatisticsGrid {
            StatisticView(label: "Download", value: interface.receivedBytesPerSecond.map(Format.rate))
            StatisticView(label: "Upload", value: interface.sentBytesPerSecond.map(Format.rate))
            StatisticView(label: "Received", value: .available(Format.storage(interface.totalBytesReceived)),
                          help: "Bytes received since the interface was created.")
            StatisticView(label: "Sent", value: .available(Format.storage(interface.totalBytesSent)),
                          help: "Bytes sent since the interface was created.")
            StatisticView(label: "Status", value: .available(interface.isUp ? String(localized: "Up") : String(localized: "Down")))
            StatisticView(label: "Type", value: .available(interface.kind.label))
            StatisticView(label: "Interface", value: .available(interface.id))
        }
    }

    private var interfaceTable: some View {
        let rows = interfaces
        return Table(rows, selection: $selection) {
            TableColumn("Interface") { interface in
                Label {
                    Text(verbatim: interface.title)
                } icon: {
                    Image(systemName: interface.kind.systemImage)
                }
            }
            .width(min: 140, ideal: 180)
            TableColumn("Name") { interface in
                Text(verbatim: interface.id).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Download") { interface in
                MetricStateText(state: interface.receivedBytesPerSecond.map(Format.rate))
            }
            TableColumn("Upload") { interface in
                MetricStateText(state: interface.sentBytesPerSecond.map(Format.rate))
            }
            TableColumn("Received") { interface in
                Text(verbatim: Format.storage(interface.totalBytesReceived)).monospacedDigit()
            }
            TableColumn("Sent") { interface in
                Text(verbatim: Format.storage(interface.totalBytesSent)).monospacedDigit()
            }
        }
        .frame(height: Self.tableHeight(rows: rows.count))
    }

    static func tableHeight(rows: Int) -> CGFloat {
        let rowHeight: CGFloat = 24
        let headerHeight: CGFloat = 32
        let maximum: CGFloat = 360
        return min(CGFloat(max(rows, 1)) * rowHeight + headerHeight, maximum)
    }
}
