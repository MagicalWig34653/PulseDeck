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

/// Wi‑Fi generation from the active PHY mode (CoreWLAN `CWPHYMode`).
public enum WiFiStandard: Hashable, Sendable {
    case legacy(String)      // 802.11a/b/g
    case wifi4               // 802.11n
    case wifi5               // 802.11ac
    case wifi6               // 802.11ax
    case wifi7               // 802.11be

    /// Maps CoreWLAN's `CWPHYMode` raw values (a = 1, b = 2, g = 3, n = 4, ac = 5, ax = 6,
    /// be = 7). Unknown values stay `nil` rather than being guessed.
    public init?(phyModeRawValue: Int) {
        switch phyModeRawValue {
        case 1: self = .legacy("802.11a")
        case 2: self = .legacy("802.11b")
        case 3: self = .legacy("802.11g")
        case 4: self = .wifi4
        case 5: self = .wifi5
        case 6: self = .wifi6
        case 7: self = .wifi7
        default: return nil
        }
    }
}

/// Wi‑Fi link details (CoreWLAN).
public struct WiFiLink: Hashable, Sendable {
    public var standard: WiFiStandard?
    /// Current transmit rate in Mbit/s as negotiated with the access point.
    public var transmitRateMbps: Double?
    public var rssi: Int?
    public var noise: Int?
    /// e.g. "36 (5 GHz, 80 MHz)".
    public var channel: String?

    public init(standard: WiFiStandard?, transmitRateMbps: Double?, rssi: Int?, noise: Int?, channel: String?) {
        self.standard = standard
        self.transmitRateMbps = transmitRateMbps
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
    }
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
    /// Local IPv4/IPv6 addresses, ordered by `NetworkAddressOrdering` (IPv4 first, link-local
    /// last).
    public var addresses: [String]
    /// Link speed reported by the driver (`ifi_baudrate`): the negotiated Ethernet speed, or the
    /// Wi‑Fi link rate. `nil` when the driver reports none (tunnels, loopback).
    public var linkSpeedBitsPerSecond: UInt64?
    /// Wi‑Fi details, for Wi‑Fi interfaces.
    public var wifi: WiFiLink?

    public var bsdName: String { id }

    /// First IPv4 address, if any.
    public var ipv4Address: String? { addresses.first(where: NetworkAddressOrdering.isIPv4) }

    /// First routable (non-link-local) IPv6 address, if any.
    public var ipv6Address: String? {
        addresses.first { !NetworkAddressOrdering.isIPv4($0) && !NetworkAddressOrdering.isLinkLocal($0) }
    }

    public init(id: String, displayName: String?, kind: NetworkInterfaceKind, isUp: Bool, receivedBytesPerSecond: MetricState<Double>, sentBytesPerSecond: MetricState<Double>, totalBytesReceived: UInt64, totalBytesSent: UInt64, addresses: [String] = [], linkSpeedBitsPerSecond: UInt64? = nil, wifi: WiFiLink? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.receivedBytesPerSecond = receivedBytesPerSecond
        self.sentBytesPerSecond = sentBytesPerSecond
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesSent = totalBytesSent
        self.addresses = addresses
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
        self.wifi = wifi
    }

    /// Whether this is a Tailscale interface (see `NetworkInterfaceClassifier.isTailscale`).
    public var isTailscale: Bool {
        if case .vpnTunnel(let name) = kind, name == NetworkInterfaceClassifier.tailscaleName { return true }
        return false
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
