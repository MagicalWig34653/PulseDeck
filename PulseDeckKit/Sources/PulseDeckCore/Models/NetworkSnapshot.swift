/// Classification of a network interface (SPEC §16, §17).
public enum NetworkInterfaceKind: Hashable, Sendable {
    case ethernet
    case wifi
    case bridge
    case thunderbolt
    case cellular
    /// VPN or tunnel (utun, ipsec, ppp, …). `friendlyName` only when reliably known.
    case vpnTunnel(friendlyName: String?)
    case loopback
    /// Anything else. Such interfaces are still displayed (SPEC §17).
    case other
}

/// One network interface. Byte counters are 64-bit (`if_data64`).
public struct NetworkInterfaceSnapshot: Hashable, Sendable, Identifiable {
    /// BSD interface name, e.g. `en0`, `utun3`.
    public var id: String
    /// Localized name from SystemConfiguration (e.g. "Wi‑Fi"), when the system provides one.
    public var displayName: String?
    public var kind: NetworkInterfaceKind
    public var isUp: Bool
    public var receivedBytesPerSecond: MetricState<Double>
    public var sentBytesPerSecond: MetricState<Double>
    public var totalBytesReceived: UInt64
    public var totalBytesSent: UInt64

    public var bsdName: String { id }

    public init(id: String, displayName: String?, kind: NetworkInterfaceKind, isUp: Bool, receivedBytesPerSecond: MetricState<Double>, sentBytesPerSecond: MetricState<Double>, totalBytesReceived: UInt64, totalBytesSent: UInt64) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesSent = totalBytesSent
    }
}

/// All interfaces, listed individually rather than aggregated (SPEC §16).
public struct NetworkSnapshot: Hashable, Sendable {
    public var interfaces: [NetworkInterfaceSnapshot]
    /// BSD name of the interface carrying the default IPv4 route, if any.
    public var primaryInterfaceID: String?

    public init(interfaces: [NetworkInterfaceSnapshot], primaryInterfaceID: String?) {
        self.interfaces = interfaces
        self.primaryInterfaceID = primaryInterfaceID
    }

    public var primaryInterface: NetworkInterfaceSnapshot? {
        primaryInterfaceID.flatMap { id in interfaces.first { $0.id == id } }
    }
}
