import PulseDeckCore
import SwiftUI

/// Details of the selected row: layer 3 facts of a destination, its layer 4 breakdown (transport
/// and port) and the processes talking to it. For a group, the same breakdowns summed over its
/// members, plus the busiest members.
struct TrafficInspector: View {
    let rows: [TrafficRow]
    let hostNames: [String: String]

    private static let listLimit = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch rows.count {
                case 0:
                    ContentUnavailableView {
                        Label("No Selection", systemImage: "network")
                    } description: {
                        Text("Select a destination or group to see its layer 3 and layer 4 details.")
                    }
                case 1:
                    if let row = rows.first {
                        detail(of: row)
                    }
                default:
                    multipleSelection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: One row

    @ViewBuilder
    private func detail(of row: TrafficRow) -> some View {
        let members = row.destination.map { [$0] } ?? row.members
        let address = members.first?.address ?? ""

        header(of: row, members: members)

        GroupBox {
            VStack(spacing: 8) {
                if let destination = row.destination {
                    fact("Address", destination.address)
                    fact("Family", destination.family == .v4 ? "IPv4" : "IPv6")
                    fact("Host name", row.hostName ?? TrafficFormat.dash)
                    if let info = row.info {
                        fact("Scope", TrafficFormat.scopeName(info.scope))
                        fact("Country", [row.flag, row.location].compactMap { $0 }.joined(separator: " "))
                        fact("Provider", info.provider ?? (info.scope == .internet ? String(localized: "Unknown") : TrafficFormat.dash))
                        fact("Service", info.service ?? TrafficFormat.dash)
                    }
                    fact("First seen", destination.firstSeen.formatted(date: .abbreviated, time: .standard))
                    fact("Last seen", destination.lastSeen.formatted(date: .abbreviated, time: .standard))
                } else {
                    fact("Destinations", row.members.count.formatted())
                    if let last = row.lastSeen {
                        fact("Last seen", last.formatted(date: .abbreviated, time: .standard))
                    }
                }
                fact("Flows (active / total)", row.flowsText)
            }
            .padding(6)
        } label: {
            Text("Layer 3")
                .font(.headline)
        }

        GroupBox {
            VStack(spacing: 8) {
                fact("Received", row.receivedText)
                fact("Sent", row.sentText)
                fact("Total", row.totalText)
                fact("↓ Rate", row.receiveRateText)
                fact("↑ Rate", row.sendRateText)
            }
            .padding(6)
        } label: {
            Text("Traffic")
                .font(.headline)
        }

        portsSection(TrafficAggregation.ports(of: members), address: address, counters: row.hasCounters)
        processesSection(TrafficAggregation.processes(of: members), counters: row.hasCounters)

        if row.destination == nil {
            membersSection(row)
        }
    }

    private func header(of row: TrafficRow, members: [DestinationTotals]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let flag = row.flag {
                        Text(verbatim: flag)
                    }
                    Text(verbatim: row.title)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                ProcessActions.copy(members.map(\.address).joined(separator: "\n"))
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .help(Text("Copy the address"))
            .disabled(members.isEmpty)
        }
    }

    /// One line of the facts list: label on the left, value on the right.
    private func fact(_ label: LocalizedStringResource, _ value: String) -> some View {
        factRow(Text(label), value)
    }

    private func factRow(_ label: Text, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value.isEmpty ? TrafficFormat.dash : value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: Layer 4

    @ViewBuilder
    private func portsSection(_ ports: [PortTotals], address: String, counters: Bool) -> some View {
        GroupBox {
            if ports.isEmpty {
                Text("No ports recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Port").gridColumnAlignment(.leading)
                        Text("↓")
                        Text("↑")
                        Text("Flows")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(ports.prefix(Self.listLimit).enumerated()), id: \.offset) { _, port in
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: Self.portTitle(port))
                                if let service = Self.serviceName(for: port, address: address) {
                                    Text(verbatim: service)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .gridColumnAlignment(.leading)
                            Text(verbatim: TrafficFormat.bytes(port.bytesReceived, counters: counters))
                            Text(verbatim: TrafficFormat.bytes(port.bytesSent, counters: counters))
                            Text(verbatim: String(port.flowCount))
                        }
                        .monospacedDigit()
                        .font(.callout)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                if ports.count > Self.listLimit {
                    Text("\(ports.count - Self.listLimit) more not shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
        } label: {
            Text("Layer 4 · Transport and port")
                .font(.headline)
        }
    }

    private static func portTitle(_ port: PortTotals) -> String {
        port.port == 0 ? port.transport.name : "\(port.transport.name) \(port.port)"
    }

    /// The service the classifier derives for this transport and port ("HTTPS", "DNS" …).
    private static func serviceName(for port: PortTotals, address: String) -> String? {
        guard port.port != 0 else { return nil }
        return TrafficClassifier.shared.info(forAddress: address, port: port.port, transport: port.transport).service
    }

    // MARK: Processes

    @ViewBuilder
    private func processesSection(_ processes: [ProcessTotals], counters: Bool) -> some View {
        GroupBox {
            if processes.isEmpty {
                Text("No processes recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Process").gridColumnAlignment(.leading)
                        Text("↓")
                        Text("↑")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(processes.prefix(Self.listLimit).enumerated()), id: \.offset) { _, process in
                        GridRow {
                            Text(verbatim: process.processName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .gridColumnAlignment(.leading)
                            Text(verbatim: TrafficFormat.bytes(process.bytesReceived, counters: counters))
                            Text(verbatim: TrafficFormat.bytes(process.bytesSent, counters: counters))
                        }
                        .monospacedDigit()
                        .font(.callout)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Text("Processes")
                .font(.headline)
        }
    }

    // MARK: Group members

    @ViewBuilder
    private func membersSection(_ row: TrafficRow) -> some View {
        let members = Array(row.members.prefix(10))
        GroupBox {
            VStack(spacing: 6) {
                ForEach(members) { member in
                    factRow(Text(verbatim: hostNames[member.address] ?? member.address),
                            TrafficFormat.bytes(member.totalBytes, counters: row.hasCounters && member.hasByteCounters))
                }
                if row.members.count > members.count {
                    Text("\(row.members.count - members.count) more in the table")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        } label: {
            Text("Busiest destinations")
                .font(.headline)
        }
    }

    // MARK: Several rows

    private var multipleSelection: some View {
        let addresses = rows.flatMap { row in
            row.destination.map { [$0.address] } ?? row.members.map(\.address)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(rows.count) items selected")
                .font(.title3.weight(.semibold))
            Button {
                ProcessActions.copy(addresses.joined(separator: "\n"))
            } label: {
                Label("Copy Addresses", systemImage: "doc.on.doc")
            }
            .disabled(addresses.isEmpty)
            Text("Select a single row to see its layer 3 and layer 4 details.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
