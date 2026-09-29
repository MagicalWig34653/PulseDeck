import Foundation

/// Decodes Tailscale's LocalAPI `GET /localapi/v0/status` (Go `ipnstate.Status`, JSON field names
/// as in tailscale.com/ipn/ipnstate) and turns peer byte counters into rates.
public struct TailscaleStatusTracker: Sendable {
    struct StatusDocument: Decodable {
        var backendState: String?
        var tailscaleIPs: [String]?
        var selfNode: PeerStatus?
        var peers: [String: PeerStatus]?
        var currentTailnet: TailnetInfo?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case tailscaleIPs = "TailscaleIPs"
            case selfNode = "Self"
            case peers = "Peer"
            case currentTailnet = "CurrentTailnet"
        }
    }

    struct TailnetInfo: Decodable {
        var name: String?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
        }
    }

    struct PeerStatus: Decodable {
        var id: String?
        var publicKey: String?
        var hostName: String?
        var dnsName: String?
        var os: String?
        var tailscaleIPs: [String]?
        var relay: String?
        var currentAddress: String?
        var rxBytes: UInt64?
        var txBytes: UInt64?
        var online: Bool?
        var active: Bool?
        var exitNode: Bool?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case publicKey = "PublicKey"
            case hostName = "HostName"
            case dnsName = "DNSName"
            case os = "OS"
            case tailscaleIPs = "TailscaleIPs"
            case relay = "Relay"
            case currentAddress = "CurAddr"
            case rxBytes = "RxBytes"
            case txBytes = "TxBytes"
            case online = "Online"
            case active = "Active"
            case exitNode = "ExitNode"
        }
    }

    private var rates = CounterRateTracker<String>()

    public init() {}

    /// - Returns: `nil` if `json` is not a status document.
    public mutating func snapshot(fromStatusJSON json: [UInt8], at instant: MonotonicInstant) -> TailscaleSnapshot? {
        guard let status = try? JSONDecoder().decode(StatusDocument.self, from: Data(json)) else { return nil }
        var peers: [TailscalePeer] = []
        for (key, peer) in status.peers ?? [:] {
            let id = peer.id ?? peer.publicKey ?? key
            let received = peer.rxBytes ?? 0
            let sent = peer.txBytes ?? 0
            let peerRates = rates.update(key: id, generation: 0, counters: [received, sent], at: instant)
            peers.append(TailscalePeer(
                id: id,
                hostName: peer.hostName ?? id,
                dnsName: peer.dnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 },
                os: peer.os.flatMap { $0.isEmpty ? nil : $0 },
                addresses: peer.tailscaleIPs ?? [],
                isOnline: peer.online ?? false,
                isActive: peer.active ?? false,
                directEndpoint: peer.currentAddress.flatMap { $0.isEmpty ? nil : $0 },
                relay: peer.relay.flatMap { $0.isEmpty ? nil : $0 },
                isExitNode: peer.exitNode ?? false,
                receivedBytesPerSecond: peerRates[0],
                sentBytesPerSecond: peerRates[1],
                totalBytesReceived: received,
                totalBytesSent: sent
            ))
        }
        rates.retainOnly(Set(peers.map(\.id)))
        // Active connections first, then online peers, then by name.
        peers.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            return lhs.hostName.localizedStandardCompare(rhs.hostName) == .orderedAscending
        }
        return TailscaleSnapshot(
            backendState: status.backendState ?? "Unknown",
            tailnetName: status.currentTailnet?.name,
            selfHostName: status.selfNode?.hostName ?? "This Mac",
            selfAddresses: status.tailscaleIPs ?? status.selfNode?.tailscaleIPs ?? [],
            peers: peers
        )
    }

    public mutating func reset() {
        rates.reset()
    }
}
