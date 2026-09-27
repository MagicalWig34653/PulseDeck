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

    private var hiddenCount: Int {
        guard let network = state?.value, !showsAllInterfaces else { return 0 }
        return network.interfaces.count(where: \.isNormallyHidden)
    }

    private var toggleTitle: LocalizedStringResource {
        hiddenCount > 0 ? "Show \(hiddenCount) inactive" : "Show inactive"
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
                VStack(alignment: .leading, spacing: 20) {
                    let selected = selectedInterface
                    DetailHeader(
                        title: selected?.title ?? String(localized: "Network Interfaces"),
                        subtitle: selected.map(Self.subtitle),
                        value: selected.map(Self.throughput)
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
                    .frame(height: 200)

                    if let selected {
                        DetailSection(title: "Traffic") {
                            StatisticView(label: "Download", value: selected.receivedBytesPerSecond.map(Format.rate))
                            StatisticView(label: "Upload", value: selected.sentBytesPerSecond.map(Format.rate))
                            StatisticView(label: "Received", value: .available(Format.storage(selected.totalBytesReceived)),
                                          help: "Bytes received since the interface was created.")
                            StatisticView(label: "Sent", value: .available(Format.storage(selected.totalBytesSent)),
                                          help: "Bytes sent since the interface was created.")
                        }
                        DetailSection(title: "Addresses") {
                            StatisticView(label: "IPv4 Address", value: selected.ipv4Address.map { .available($0) } ?? .unavailable(.notApplicable))
                            StatisticView(label: "IPv6 Address", value: selected.ipv6Address.map { .available($0) } ?? .unavailable(.notApplicable))
                            StatisticView(label: "Interface", value: .available(selected.id))
                            StatisticView(label: "Status", value: .available(selected.isUp ? String(localized: "Connected") : String(localized: "Inactive")))
                        }
                    }

                    SectionHeader(title: "Interfaces") {
                        Toggle(isOn: $showsAllInterfaces) {
                            Text(toggleTitle)
                        }
                        .toggleStyle(.switch)
                        .help("Also show loopback and interfaces that have never received or sent data.")
                    }
                    interfaceTable
                }
                .padding(20)
            }
        }
    }

    /// Keeps the axis from amplifying background chatter on an idle link (10 kB/s).
    private static let minimumChartScale = 10_000.0

    private static func subtitle(_ interface: NetworkInterfaceSnapshot) -> String {
        [interface.kind.label, interface.id, interface.ipv4Address ?? interface.ipv6Address]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func throughput(_ interface: NetworkInterfaceSnapshot) -> MetricState<String> {
        interface.receivedBytesPerSecond.flatMap { received in
            interface.sentBytesPerSecond.map { sent in "↓ \(Format.rate(received))  ↑ \(Format.rate(sent))" }
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
                        .foregroundStyle(interface.isUp ? Color.accentColor : Color.secondary)
                }
            }
            .width(min: 140, ideal: 170)
            TableColumn("Name") { interface in
                Text(verbatim: interface.id).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("IP Address") { interface in
                Text(verbatim: interface.ipv4Address ?? interface.ipv6Address ?? AppState.placeholder)
                    .foregroundStyle(interface.addresses.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Download") { interface in
                MetricStateText(state: interface.receivedBytesPerSecond.map(Format.rate))
            }
            .width(min: 70, ideal: 80)
            TableColumn("Upload") { interface in
                MetricStateText(state: interface.sentBytesPerSecond.map(Format.rate))
            }
            .width(min: 70, ideal: 80)
            TableColumn("Received") { interface in
                Text(verbatim: Format.storage(interface.totalBytesReceived)).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: Self.tableHeight(rows: rows.count))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }

    static func tableHeight(rows: Int) -> CGFloat {
        let rowHeight: CGFloat = 26
        let headerHeight: CGFloat = 34
        let maximum: CGFloat = 360
        return min(CGFloat(max(rows, 1)) * rowHeight + headerHeight, maximum)
    }
}
