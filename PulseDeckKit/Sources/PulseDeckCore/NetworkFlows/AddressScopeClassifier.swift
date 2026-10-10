/// Classifies an address by its reserved range, with no database. All ranges are from the IANA
/// special-purpose address registries (RFC 6890 and updates) except where noted.
public enum AddressScopeClassifier {
    public static func scope(of address: IPAddress) -> DestinationScope {
        // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) addresses are IPv4 destinations.
        if let embedded = address.embeddedIPv4 {
            return scope(ofIPv4: embedded)
        }
        guard case .v6(let high, let low) = address else { return .internet }
        return scope(ofIPv6High: high, low: low)
    }

    /// Scope of a textual address; `nil` when the text is not a numeric IP address.
    public static func scope(of text: String) -> DestinationScope? {
        IPAddress(text).map(scope(of:))
    }

    static func scope(ofIPv4 value: UInt32) -> DestinationScope {
        let first = value >> 24
        let second = (value >> 16) & 0xFF
        switch first {
        case 0: return .unspecified                       // 0.0.0.0/8 "this network"
        case 127: return .loopback                        // 127.0.0.0/8
        case 10: return .localNetwork                     // 10.0.0.0/8
        case 169 where second == 254: return .linkLocal   // 169.254.0.0/16
        case 172 where (16...31).contains(second): return .localNetwork   // 172.16.0.0/12
        case 192 where second == 168: return .localNetwork                // 192.168.0.0/16
        // 100.64.0.0/10 (RFC 6598 shared address space) is what Tailscale assigns; the contract treats it
        // as Tailscale even though carriers use it on other links.
        case 100 where (64...127).contains(second): return .tailscale
        // 198.18.0.0/15 is reserved for benchmarking, but proxy tools on the Mac (fake-IP modes) hand
        // it out locally, so traffic to it never leaves the Mac for the internet.
        case 198 where second == 18 || second == 19: return .localNetwork
        case 224...239: return .multicast                 // 224.0.0.0/4
        case 255 where value == 0xFFFF_FFFF: return .localNetwork   // limited broadcast
        default: return .internet                         // incl. 240.0.0.0/4 (reserved; no data)
        }
    }

    static func scope(ofIPv6High high: UInt64, low: UInt64) -> DestinationScope {
        if high == 0, low == 0 { return .unspecified }    // ::
        if high == 0, low == 1 { return .loopback }       // ::1
        let firstGroup = high >> 48
        if firstGroup >> 8 == 0xFF { return .multicast }  // ff00::/8
        if firstGroup >> 6 == 0b11_1111_1010 { return .linkLocal }   // fe80::/10
        // Tailscale: fd7a:115c:a1e0::/48 — checked before the unique-local range that contains it.
        if high >> 16 == 0xFD7A_115C_A1E0 { return .tailscale }
        if firstGroup >> 9 == 0b111_1110 { return .localNetwork }    // fc00::/7 unique local
        if firstGroup >> 6 == 0b11_1111_1011 { return .localNetwork } // fec0::/10 site-local (deprecated)
        return .internet
    }
}
