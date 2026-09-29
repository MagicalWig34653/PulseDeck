/// One Tailscale peer, from the Tailscale client's LocalAPI `/localapi/v0/status` (read-only;
/// approved by the product owner). Rates are computed from the peer's cumulative byte counters.
public struct TailscalePeer: Hashable, Sendable, Identifiable {
    /// Stable node ID.
    public var id: String
    public var hostName: String
    /// MagicDNS name without the trailing dot, e.g. "nas.tailnet.ts.net".
    public var dnsName: String?
    public var os: String?
    public var addresses: [String]
    public var isOnline: Bool
    /// Traffic was exchanged recently (Tailscale's "Active").
    public var isActive: Bool
    /// Direct UDP endpoint in use, e.g. "203.0.113.5:41641"; `nil` when relayed or idle.
    public var directEndpoint: String?
    /// DERP relay region code, e.g. "fra".
    public var relay: String?
    public var isExitNode: Bool
    public var receivedBytesPerSecond: MetricState<Double>
    public var sentBytesPerSecond: MetricState<Double>
    public var totalBytesReceived: UInt64
    public var totalBytesSent: UInt64

    public init(id: String, hostName: String, dnsName: String?, os: String?, addresses: [String], isOnline: Bool, isActive: Bool, directEndpoint: String?, relay: String?, isExitNode: Bool, receivedBytesPerSecond: MetricState<Double>, sentBytesPerSecond: MetricState<Double>, totalBytesReceived: UInt64, totalBytesSent: UInt64) {
        self.id = id
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.addresses = addresses
        self.isOnline = isOnline
        self.isActive = isActive
        self.directEndpoint = directEndpoint
        self.relay = relay
        self.isExitNode = isExitNode
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesSent = totalBytesSent
    }

    /// "Direct" or "Relay (fra)" for an active connection.
    public var connectionKind: ConnectionKind {
        if directEndpoint != nil { return .direct }
        if isActive, let relay, !relay.isEmpty { return .relayed(relay) }
        return .idle
    }

    public enum ConnectionKind: Hashable, Sendable {
        case direct
        case relayed(String)
        case idle
    }
}

public struct TailscaleSnapshot: Hashable, Sendable {
    /// "Running", "Stopped", "NeedsLogin", ….
    public var backendState: String
    public var tailnetName: String?
    public var selfHostName: String
    public var selfAddresses: [String]
    public var peers: [TailscalePeer]

    public init(backendState: String, tailnetName: String?, selfHostName: String, selfAddresses: [String], peers: [TailscalePeer]) {
        self.backendState = backendState
        self.tailnetName = tailnetName
        self.selfHostName = selfHostName
        self.selfAddresses = selfAddresses
        self.peers = peers
    }
}
