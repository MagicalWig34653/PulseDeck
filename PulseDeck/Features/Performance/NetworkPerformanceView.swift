import PulseDeckCore
import SwiftUI

/// Network page (SPEC §16, §17) for one interface — Ethernet, Wi‑Fi, bridge, Thunderbolt,
/// VPN/tunnel — chosen in the Performance list, where every interface has its own entry.
struct NetworkPerformanceView: View {
    @Environment(AppState.self) private var appState
    /// The interface to show; `nil` shows the primary (default-route) interface.
    let interfaceID: String?

    private var state: MetricState<NetworkSnapshot>? { appState.latestSnapshot?.network }

    private var selectedInterface: NetworkInterfaceSnapshot? {
        guard let network = state?.value else { return nil }
        let id = interfaceID ?? network.primaryInterfaceID
        return network.interfaces.first { $0.id == id } ?? (interfaceID == nil ? network.interfaces.first : nil)
    }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            CategoryUnavailableView(category: .network, reason: reason)
        } else if let interfaceID, state?.value != nil, selectedInterface == nil {
            // The interface went away while its page was open (e.g. a VPN disconnected).
            ContentUnavailableView {
                Label(interfaceID, systemImage: ResourceCategory.network.systemImage)
            } description: {
                Text("This network interface is no longer present.")
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
                        DetailSection(title: "Link") {
                            StatisticView(label: selected.kind == .wifi ? "Link Rate" : "Link Speed",
                                          value: selected.linkSpeedBitsPerSecond.map { .available(Format.bitRate(Double($0))) } ?? .unavailable(.notApplicable),
                                          help: "Speed negotiated with the switch or access point, as reported by the network driver.")
                            if let wifi = selected.wifi {
                                StatisticView(label: "Wi‑Fi Standard", value: wifi.standard.map { .available($0.label) } ?? .unavailable(.transientFailure("unknown PHY mode")))
                                StatisticView(label: "Transmit Rate", value: wifi.transmitRateMbps.map { .available(Format.bitRate($0 * 1e6)) } ?? .unavailable(.transientFailure("no rate")))
                                StatisticView(label: "Channel", value: wifi.channel.map { .available($0) } ?? .unavailable(.transientFailure("no channel")))
                                StatisticView(label: "Signal", value: wifi.rssi.map { rssi in
                                    .available(wifi.noise.map { String(localized: "\(rssi) dBm (noise \($0) dBm)") } ?? String(localized: "\(rssi) dBm"))
                                })
                            }
                        }
                        if selected.isTailscale {
                            TailscaleSection(state: appState.latestSnapshot?.tailscale)
                        }
                    }
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
}
