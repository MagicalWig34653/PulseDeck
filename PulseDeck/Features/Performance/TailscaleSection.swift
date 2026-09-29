import PulseDeckCore
import SwiftUI

/// Tailscale details on the page of the Tailscale interface: tailnet status, a flow diagram of
/// the current connections and a table of peers with their bandwidth. Read from the Tailscale
/// client's LocalAPI while the page is visible.
struct TailscaleSection: View {
    let state: MetricState<TailscaleSnapshot>?
    @AppStorage("tailscaleShowsOfflinePeers") private var showsOfflinePeers = false

    var body: some View {
        switch state {
        case .available(let snapshot)?:
            content(snapshot)
        case .unavailable(let reason)? where !reason.isTransient:
            DetailSection(title: "Tailscale") {
                StatisticView(label: "Connections", value: .unavailable(reason),
                              help: reason == .notApplicable
                                ? "The Tailscale client's local API was not found. Is Tailscale running?"
                                : reason.explanation)
            }
        default:
            DetailSection(title: "Tailscale") {
                StatisticView(label: "Connections", value: .unavailable(.awaitingBaseline))
            }
        }
    }

    private func content(_ snapshot: TailscaleSnapshot) -> some View {
        let online = snapshot.peers.filter(\.isOnline)
        let peers = showsOfflinePeers ? snapshot.peers : online
        return VStack(alignment: .leading, spacing: 20) {
            DetailSection(title: "Tailscale") {
                StatisticView(label: "Status", value: .available(snapshot.backendState))
                StatisticView(label: "Tailnet", value: snapshot.tailnetName.map { .available($0) } ?? .unavailable(.notApplicable))
                StatisticView(label: "This Device", value: .available(snapshot.selfHostName))
                StatisticView(label: "Peers Online", value: .available("\(online.count) / \(snapshot.peers.count)"))
            }

            GroupBox {
                TailscaleFlowDiagram(snapshot: snapshot)
                    .padding(8)
            } label: {
                Text("Connections")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Peers") {
                    Toggle("Show offline peers", isOn: $showsOfflinePeers)
                }
                Table(peers) {
                    TableColumn("Name") { peer in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(peer.isOnline ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                                .accessibilityLabel(peer.isOnline ? Text("Online") : Text("Offline"))
                            Text(verbatim: peer.hostName)
                                .lineLimit(1)
                            if peer.isExitNode {
                                Text("Exit Node")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 120, ideal: 170)
                    TableColumn("OS") { peer in
                        Text(verbatim: peer.os ?? AppState.placeholder)
                    }
                    .width(min: 50, ideal: 70)
                    TableColumn("Address") { peer in
                        Text(verbatim: peer.addresses.first ?? AppState.placeholder)
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Connection") { peer in
                        Text(verbatim: peer.connectionLabel)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Download") { peer in
                        MetricStateText(state: peer.receivedBytesPerSecond.map(Format.rate), isCompact: true)
                    }
                    .width(min: 70, ideal: 84)
                    TableColumn("Upload") { peer in
                        MetricStateText(state: peer.sentBytesPerSecond.map(Format.rate), isCompact: true)
                    }
                    .width(min: 70, ideal: 84)
                    TableColumn("Received") { peer in
                        Text(verbatim: Format.storage(peer.totalBytesReceived))
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 84)
                    TableColumn("Sent") { peer in
                        Text(verbatim: Format.storage(peer.totalBytesSent))
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 84)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: inlineTableHeight(rows: peers.count))
            }

            SourceNote(text: "Tailscale data is read from the Tailscale client's local API (the interface the tailscale command-line tool uses), which is not a documented, versioned API. Rates are derived from each peer's byte counters.")
        }
    }
}

extension TailscalePeer {
    var connectionLabel: String {
        switch connectionKind {
        case .direct: String(localized: "Direct")
        case .relayed(let region): String(localized: "Relay (\(region))")
        case .idle: isOnline ? String(localized: "Idle") : String(localized: "Offline")
        }
    }

    /// Combined current rate, 0 while unknown (only used for ordering and line width).
    var totalRate: Double {
        (receivedBytesPerSecond.value ?? 0) + (sentBytesPerSecond.value ?? 0)
    }
}

/// Flow diagram: this Mac on the left, peers with a current connection on the right, relayed
/// connections routed through their DERP relay in the middle. Line width follows bandwidth.
struct TailscaleFlowDiagram: View {
    let snapshot: TailscaleSnapshot

    /// More peers would make the diagram unreadable; the table lists all of them.
    private static let maximumPeers = 8
    private static let rowHeight: CGFloat = 44

    private var peers: [TailscalePeer] {
        snapshot.peers
            .filter { $0.connectionKind != .idle || $0.totalRate > 0 }
            .sorted { $0.totalRate > $1.totalRate }
            .prefix(Self.maximumPeers)
            .map { $0 }
    }

    private var relays: [String] {
        var seen: [String] = []
        for peer in peers {
            if case .relayed(let region) = peer.connectionKind, !seen.contains(region) {
                seen.append(region)
            }
        }
        return seen
    }

    var body: some View {
        if peers.isEmpty {
            Text("No active connections")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            let height = CGFloat(peers.count) * Self.rowHeight
            GeometryReader { geometry in
                let layout = NodeLayout(size: geometry.size, peers: peers, relays: relays)
                ZStack {
                    Canvas { context, _ in
                        for peer in peers {
                            let width = Self.lineWidth(for: peer.totalRate)
                            let color: Color = peer.connectionKind == .direct ? .green : .orange
                            let end = layout.peerPoint(peer.id)
                            var path = Path()
                            path.move(to: layout.selfPoint)
                            if case .relayed(let region) = peer.connectionKind {
                                let relay = layout.relayPoint(region)
                                Self.addCurve(to: &path, from: layout.selfPoint, to: relay)
                                Self.addCurve(to: &path, from: relay, to: end)
                            } else {
                                Self.addCurve(to: &path, from: layout.selfPoint, to: end)
                            }
                            context.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: width, lineCap: .round))
                        }
                    }
                    node(title: snapshot.selfHostName, subtitle: snapshot.selfAddresses.first, systemImage: "laptopcomputer")
                        .position(layout.selfPoint)
                    ForEach(relays, id: \.self) { region in
                        node(title: String(localized: "Relay"), subtitle: region, systemImage: "arrow.triangle.branch")
                            .position(layout.relayPoint(region))
                    }
                    ForEach(peers) { peer in
                        peerNode(peer)
                            .position(layout.peerPoint(peer.id))
                    }
                }
            }
            .frame(height: max(height, 90))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Tailscale connections"))
            .accessibilityValue(Text(verbatim: peers.map { "\($0.hostName): \($0.connectionLabel)" }.joined(separator: ", ")))
        }
    }

    private func node(title: String, subtitle: String?, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .fixedSize()
    }

    private func peerNode(_ peer: TailscalePeer) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: peer.hostName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(verbatim: "↓ \(peer.receivedBytesPerSecond.value.map(Format.rate) ?? AppState.placeholder)  ↑ \(peer.sentBytesPerSecond.value.map(Format.rate) ?? AppState.placeholder)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(peer.connectionKind == .direct ? Color.green.opacity(0.6) : Color.orange.opacity(0.6)))
        .fixedSize()
    }

    /// 1.5 pt when idle up to 7 pt at 100 MB/s, on a logarithmic scale.
    private static func lineWidth(for rate: Double) -> CGFloat {
        let minimum = 1.5, maximum = 7.0, fullScale = 100_000_000.0
        guard rate > 1 else { return minimum }
        let fraction = min(log10(rate) / log10(fullScale), 1)
        return minimum + (maximum - minimum) * fraction
    }

    private static func addCurve(to path: inout Path, from start: CGPoint, to end: CGPoint) {
        let middle = (start.x + end.x) / 2
        path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
    }

    /// Node positions: self at the left, relays in the middle, peers at the right.
    private struct NodeLayout {
        let size: CGSize
        let peers: [TailscalePeer]
        let relays: [String]

        var selfPoint: CGPoint { CGPoint(x: min(90, size.width * 0.15), y: size.height / 2) }

        func relayPoint(_ region: String) -> CGPoint {
            let index = relays.firstIndex(of: region) ?? 0
            return CGPoint(x: size.width * 0.45, y: size.height * (CGFloat(index) + 0.5) / CGFloat(max(relays.count, 1)))
        }

        func peerPoint(_ id: TailscalePeer.ID) -> CGPoint {
            let index = peers.firstIndex { $0.id == id } ?? 0
            return CGPoint(x: size.width - min(110, size.width * 0.18), y: size.height * (CGFloat(index) + 0.5) / CGFloat(max(peers.count, 1)))
        }
    }
}
