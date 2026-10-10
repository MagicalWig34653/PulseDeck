/// Well-known port → service names. The IANA Service Name and Transport Protocol Port Number Registry
/// is the base; entries marked "de facto" are not registered with IANA for that purpose but are what a
/// Mac user meets in practice. A transport is listed only where the service really uses it (for example
/// 514/udp is syslog but 514/tcp is the legacy `rsh`, so only UDP is listed).
public enum PortServices {
    /// Names that only say "web traffic"; a more specific host-name brand ("YouTube") may replace them.
    public static let genericWebServices: Set<String> = [http, https, quic, httpAlternate, httpsAlternate]

    public static let http = "HTTP"
    public static let https = "HTTPS"
    public static let quic = "QUIC (HTTP/3)"
    public static let httpAlternate = "HTTP (alt)"
    public static let httpsAlternate = "HTTPS (alt)"
    public static let applePush = "Apple Push Notification Service"

    /// The service for a flow to `port`, or `nil` when the port is not in the table (or is 0).
    public static func name(transport: FlowTransport, port: UInt16) -> String? {
        switch transport {
        case .tcp: return tcp[port]
        case .udp: return udp[port]
        case .other(1): return "ICMP"
        case .other(58): return "ICMPv6"
        case .other: return nil
        }
    }

    /// Like `name(transport:port:)`, refined by the provider where that is unambiguous.
    ///
    /// Only one refinement is made: TCP 5223 to an Apple network is the Apple Push Notification Service
    /// (Apple's "Use Apple products on enterprise networks" documentation lists TCP 5223 to 17.0.0.0/8 for
    /// APNs). The same port elsewhere is XMPP over TLS. Port 443 to Apple is deliberately NOT refined:
    /// it carries APNs fallback traffic, but also everything else Apple serves over HTTPS.
    public static func name(transport: FlowTransport, port: UInt16, provider: String?) -> String? {
        if transport == .tcp, port == 5223, provider == "Apple" { return applePush }
        return name(transport: transport, port: port)
    }

    private struct Entry {
        var port: UInt16
        var tcp: String?
        var udp: String?
    }

    private static let entries: [Entry] = [
        Entry(port: 20, tcp: "FTP (data)"),
        Entry(port: 21, tcp: "FTP"),
        Entry(port: 22, tcp: "SSH"),
        Entry(port: 23, tcp: "Telnet"),
        Entry(port: 25, tcp: "SMTP"),
        Entry(port: 53, tcp: "DNS", udp: "DNS"),
        Entry(port: 67, udp: "DHCP"),
        Entry(port: 68, udp: "DHCP"),
        Entry(port: 69, udp: "TFTP"),
        Entry(port: 80, tcp: http),
        Entry(port: 88, tcp: "Kerberos", udp: "Kerberos"),
        Entry(port: 110, tcp: "POP3"),
        Entry(port: 119, tcp: "NNTP"),
        Entry(port: 123, udp: "NTP"),
        Entry(port: 135, tcp: "MS RPC"),
        Entry(port: 137, udp: "NetBIOS"),
        Entry(port: 138, udp: "NetBIOS"),
        Entry(port: 139, tcp: "NetBIOS"),
        Entry(port: 143, tcp: "IMAP"),
        Entry(port: 161, udp: "SNMP"),
        Entry(port: 162, udp: "SNMP"),
        Entry(port: 179, tcp: "BGP"),
        Entry(port: 389, tcp: "LDAP", udp: "LDAP"),
        Entry(port: 443, tcp: https, udp: quic),
        Entry(port: 445, tcp: "SMB"),
        Entry(port: 465, tcp: "SMTPS"),
        Entry(port: 500, udp: "IPsec (IKE)"),
        Entry(port: 514, udp: "Syslog"),
        Entry(port: 515, tcp: "LPD printing"),
        Entry(port: 546, udp: "DHCPv6"),
        Entry(port: 547, udp: "DHCPv6"),
        Entry(port: 548, tcp: "AFP"),
        Entry(port: 554, tcp: "RTSP", udp: "RTSP"),
        Entry(port: 587, tcp: "SMTP (submission)"),
        Entry(port: 631, tcp: "IPP printing", udp: "IPP printing"),
        Entry(port: 636, tcp: "LDAPS"),
        Entry(port: 853, tcp: "DNS over TLS", udp: "DNS over QUIC"),
        Entry(port: 873, tcp: "rsync"),
        Entry(port: 990, tcp: "FTPS"),
        Entry(port: 993, tcp: "IMAPS"),
        Entry(port: 995, tcp: "POP3S"),
        Entry(port: 1194, tcp: "OpenVPN", udp: "OpenVPN"),
        Entry(port: 1433, tcp: "SQL Server"),
        Entry(port: 1701, udp: "L2TP"),
        Entry(port: 1723, tcp: "PPTP"),
        Entry(port: 1883, tcp: "MQTT"),
        Entry(port: 1900, udp: "SSDP"),
        Entry(port: 1935, tcp: "RTMP"),
        Entry(port: 2049, tcp: "NFS", udp: "NFS"),
        Entry(port: 3283, tcp: "Apple Remote Desktop", udp: "Apple Remote Desktop"),
        Entry(port: 3306, tcp: "MySQL"),
        Entry(port: 3389, tcp: "RDP", udp: "RDP"),
        Entry(port: 3478, tcp: "STUN/TURN", udp: "STUN/TURN"),
        Entry(port: 3689, tcp: "iTunes sharing (DAAP)"),
        Entry(port: 4500, udp: "IPsec (NAT-T)"),
        Entry(port: 5060, tcp: "SIP", udp: "SIP"),
        Entry(port: 5061, tcp: "SIP (TLS)"),
        Entry(port: 5222, tcp: "XMPP"),
        Entry(port: 5223, tcp: "XMPP (TLS)"),
        Entry(port: 5353, udp: "mDNS (Bonjour)"),
        Entry(port: 5355, udp: "LLMNR"),
        Entry(port: 5432, tcp: "PostgreSQL"),
        Entry(port: 5671, tcp: "AMQPS"),
        Entry(port: 5672, tcp: "AMQP"),
        Entry(port: 5900, tcp: "VNC"),
        Entry(port: 6379, tcp: "Redis"),                              // de facto
        Entry(port: 6667, tcp: "IRC"),
        Entry(port: 6881, tcp: "BitTorrent", udp: "BitTorrent"),      // de facto
        Entry(port: 7000, tcp: "AirPlay"),                            // de facto (Apple)
        Entry(port: 8080, tcp: httpAlternate),
        Entry(port: 8443, tcp: httpsAlternate),
        Entry(port: 8883, tcp: "MQTT (TLS)"),
        Entry(port: 9100, tcp: "Raw printing"),
        Entry(port: 9418, tcp: "Git"),
        Entry(port: 19302, udp: "STUN/TURN"),                         // de facto (Google STUN)
        Entry(port: 27017, tcp: "MongoDB"),                           // de facto
        Entry(port: 41641, udp: "Tailscale"),                         // de facto
        Entry(port: 51820, udp: "WireGuard"),                         // de facto
        Entry(port: 62078, tcp: "iPhone sync"),                       // de facto (lockdownd)
    ]

    private static let tcp: [UInt16: String] = Dictionary(
        entries.compactMap { entry in entry.tcp.map { (entry.port, $0) } }, uniquingKeysWith: { first, _ in first })
    private static let udp: [UInt16: String] = Dictionary(
        entries.compactMap { entry in entry.udp.map { (entry.port, $0) } }, uniquingKeysWith: { first, _ in first })
}
