import Foundation

/// Where an address lives, independent of any database.
public enum DestinationScope: String, Hashable, Sendable {
    case internet
    case localNetwork
    case loopback
    case linkLocal
    case multicast
    /// Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48).
    case tailscale
    case unspecified
}

/// What is known about the far end of a flow, from offline data (no network lookups).
public struct DestinationInfo: Hashable, Sendable {
    public var scope: DestinationScope
    /// ISO 3166-1 alpha-2, e.g. "DE". `nil` for non-internet scopes or unknown.
    public var countryCode: String?
    /// Network operator / hosting provider, e.g. "Cloudflare", "Apple", "Amazon AWS".
    public var provider: String?
    /// Service, from the well-known port and/or the provider ("HTTPS", "DNS", "iCloud", "YouTube").
    public var service: String?

    public init(scope: DestinationScope, countryCode: String? = nil, provider: String? = nil, service: String? = nil) {
        self.scope = scope
        self.countryCode = countryCode
        self.provider = provider
        self.service = service
    }
}

/// Classifies destinations offline. The production implementation is `DestinationClassifier`.
public protocol DestinationClassifying: Sendable {
    func info(forAddress address: String, port: UInt16, transport: FlowTransport) -> DestinationInfo
}

/// Bytes seen for one (transport, remote port) pair of a destination — the layer 4 breakdown.
public struct PortTotals: Hashable, Sendable {
    public var transport: FlowTransport
    public var port: UInt16
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var flowCount: Int

    public init(transport: FlowTransport, port: UInt16, bytesReceived: UInt64 = 0, bytesSent: UInt64 = 0, flowCount: Int = 0) {
        self.transport = transport
        self.port = port
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.flowCount = flowCount
    }
}

/// Bytes exchanged with a destination by one process.
public struct ProcessTotals: Hashable, Sendable {
    public var processName: String
    public var bytesReceived: UInt64
    public var bytesSent: UInt64

    public init(processName: String, bytesReceived: UInt64 = 0, bytesSent: UInt64 = 0) {
        self.processName = processName
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
    }
}

/// Everything accumulated for one remote IP address since PulseDeck started recording.
public struct DestinationTotals: Hashable, Sendable, Identifiable {
    /// The remote address (also the identity).
    public var id: String { address }
    public var address: String
    public var family: IPFamily
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    /// Flows ever seen / currently open.
    public var flowCount: Int
    public var activeFlowCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// Current rates over the last sample interval; `nil` when unknown (first sample, no counters).
    public var receiveBytesPerSecond: Double?
    public var sendBytesPerSecond: Double?
    /// `false` when the flows come from the socket table, which carries no byte counters — the
    /// UI shows "—" instead of 0 B.
    public var hasByteCounters: Bool
    /// Layer 4 breakdown, largest first.
    public var ports: [PortTotals]
    /// By process, largest first.
    public var processes: [ProcessTotals]

    public init(address: String, family: IPFamily, bytesReceived: UInt64 = 0, bytesSent: UInt64 = 0, flowCount: Int = 0, activeFlowCount: Int = 0, firstSeen: Date, lastSeen: Date, receiveBytesPerSecond: Double? = nil, sendBytesPerSecond: Double? = nil, hasByteCounters: Bool = true, ports: [PortTotals] = [], processes: [ProcessTotals] = []) {
        self.address = address
        self.family = family
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.flowCount = flowCount
        self.activeFlowCount = activeFlowCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.sendBytesPerSecond = sendBytesPerSecond
        self.hasByteCounters = hasByteCounters
        self.ports = ports
        self.processes = processes
    }

    public var totalBytes: UInt64 { bytesReceived &+ bytesSent }
}

/// How destinations can be grouped in the Traffic section.
public enum FlowGrouping: String, CaseIterable, Hashable, Sendable {
    case destination
    case country
    case provider
    case service
    case process
    case transportProtocol
    case port
}

/// One row of a grouped view.
public struct FlowGroup: Hashable, Sendable, Identifiable {
    /// Group key: "DE", "Cloudflare", "HTTPS", "Safari", "TCP", "443" … or "Unknown" (never
    /// dropped: traffic without classification is grouped as `unknownKey`).
    public var id: String
    public var title: String
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var destinationCount: Int
    public var activeFlowCount: Int
    public var receiveBytesPerSecond: Double
    public var sendBytesPerSecond: Double
    /// The members, largest first (for expansion / drill-down).
    public var destinations: [DestinationTotals]

    public static let unknownKey = "unknown"
    public var totalBytes: UInt64 { bytesReceived &+ bytesSent }

    public init(id: String, title: String, bytesReceived: UInt64, bytesSent: UInt64, destinationCount: Int, activeFlowCount: Int, receiveBytesPerSecond: Double, sendBytesPerSecond: Double, destinations: [DestinationTotals]) {
        self.id = id
        self.title = title
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.destinationCount = destinationCount
        self.activeFlowCount = activeFlowCount
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.sendBytesPerSecond = sendBytesPerSecond
        self.destinations = destinations
    }
}
