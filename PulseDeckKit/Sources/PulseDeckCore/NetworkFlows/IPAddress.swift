/// A parsed IP address. Parsing is written by hand (no `inet_pton`) so that Linux and macOS behave
/// identically and the rules are testable: see `init?(_:)`.
public enum IPAddress: Hashable, Sendable {
    case v4(UInt32)
    /// The 128 bits as two big-endian halves: `high` holds the first 64 bits of the textual address.
    case v6(high: UInt64, low: UInt64)

    /// Parses numeric IPv4 ("192.168.1.1") and IPv6 ("2001:db8::1", "::ffff:1.2.3.4", upper or lower
    /// case) text. An IPv6 zone ("%en0") is ignored. Returns `nil` for anything else: host names,
    /// empty strings, out-of-range octets, leading zeros in octets ("01.2.3.4", which `inet_aton`
    /// would read as octal), non-canonical shortenings such as ":::" or two "::".
    public init?(_ text: String) {
        var bytes = Array(text.utf8)
        if let zone = bytes.firstIndex(of: Self.percent) {
            guard zone + 1 < bytes.count else { return nil }   // "fe80::1%" names no zone
            bytes.removeSubrange(zone...)
        }
        guard !bytes.isEmpty else { return nil }
        if bytes.contains(Self.colon) {
            guard let groups = Self.parseIPv6Groups(bytes[...]) else { return nil }
            var high: UInt64 = 0
            var low: UInt64 = 0
            for index in 0..<4 { high = high << 16 | UInt64(groups[index]) }
            for index in 4..<8 { low = low << 16 | UInt64(groups[index]) }
            self = .v6(high: high, low: low)
        } else {
            guard let value = Self.parseIPv4(bytes[...]) else { return nil }
            self = .v4(value)
        }
    }

    /// The IPv4 address carried inside an IPv4-mapped (`::ffff:a.b.c.d`) or NAT64 well-known-prefix
    /// (`64:ff9b::a.b.c.d`, RFC 6052) IPv6 address; for a plain IPv4 address, the address itself.
    /// `nil` for every other IPv6 address.
    public var embeddedIPv4: UInt32? {
        switch self {
        case .v4(let value):
            return value
        case .v6(let high, let low):
            // ::ffff:a.b.c.d → groups 0,0,0,0,0,ffff,x,y: `high` is 0 and `low` starts with 0000:ffff.
            if high == 0, low >> 32 == 0xFFFF {
                return UInt32(truncatingIfNeeded: low)
            }
            // 64:ff9b::/96 → `high` is 0064:ff9b:0000:0000 and the top 32 bits of `low` are zero.
            if high == 0x0064_FF9B_0000_0000, low >> 32 == 0 {
                return UInt32(truncatingIfNeeded: low)
            }
            return nil
        }
    }

    /// The top 48 bits of an IPv6 address (the longest prefix routed on the public internet; the
    /// GeoIP database is keyed by it). `nil` for IPv4.
    public var ipv6Prefix48: UInt64? {
        guard case .v6(let high, _) = self else { return nil }
        return high >> 16
    }

    // MARK: Parsing

    private static let colon = UInt8(ascii: ":")
    private static let dot = UInt8(ascii: ".")
    private static let percent = UInt8(ascii: "%")

    /// Dotted-quad parsing: exactly four decimal parts of 1–3 digits, each 0…255, no leading zeros.
    static func parseIPv4(_ text: ArraySlice<UInt8>) -> UInt32? {
        var value: UInt32 = 0
        var parts = 0
        var digits = 0
        var octet = 0
        var firstDigit: UInt8 = 0
        for byte in text {
            if byte == dot {
                guard digits > 0 else { return nil }
                value = value << 8 | UInt32(octet)
                parts += 1
                digits = 0
                octet = 0
            } else if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                if digits == 0 { firstDigit = byte }
                digits += 1
                // A leading zero followed by more digits is rejected (octal ambiguity).
                guard digits <= 3, !(digits > 1 && firstDigit == UInt8(ascii: "0")) else { return nil }
                octet = octet * 10 + Int(byte - UInt8(ascii: "0"))
                guard octet <= 255 else { return nil }
            } else {
                return nil
            }
        }
        guard digits > 0 else { return nil }
        value = value << 8 | UInt32(octet)
        parts += 1
        return parts == 4 ? value : nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt16? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt16(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt16(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt16(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    /// Parses a colon-separated list of groups. An empty slice is an empty list (it is only valid next
    /// to "::", which the caller guarantees). A trailing dotted quad counts as two groups.
    private static func parseGroups(_ text: ArraySlice<UInt8>, allowTrailingIPv4: Bool) -> [UInt16]? {
        guard !text.isEmpty else { return [] }
        var groups: [UInt16] = []
        let parts = text.split(separator: colon, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            if allowTrailingIPv4, index == parts.count - 1, part.contains(dot) {
                guard let v4 = parseIPv4(part) else { return nil }
                groups.append(UInt16(truncatingIfNeeded: v4 >> 16))
                groups.append(UInt16(truncatingIfNeeded: v4))
                continue
            }
            guard (1...4).contains(part.count) else { return nil }
            var group: UInt16 = 0
            for byte in part {
                guard let digit = hexValue(byte) else { return nil }
                group = group << 4 | digit
            }
            groups.append(group)
        }
        return groups
    }

    /// Returns exactly eight 16-bit groups.
    private static func parseIPv6Groups(_ text: ArraySlice<UInt8>) -> [UInt16]? {
        // Locate "::" (at most one).
        var gap: Int?
        var index = text.startIndex
        while index + 1 < text.endIndex {
            if text[index] == colon, text[index + 1] == colon {
                if gap != nil { return nil }
                gap = index
                index += 2
                // ":::" would leave a stray colon at the start of the tail → rejected by parseGroups
                // (empty group).
            } else {
                index += 1
            }
        }
        guard let gap else {
            guard let groups = parseGroups(text, allowTrailingIPv4: true), groups.count == 8 else { return nil }
            return groups
        }
        let tail = text[(gap + 2)...]
        guard let head = parseGroups(text[..<gap], allowTrailingIPv4: false),
              let rest = parseGroups(tail, allowTrailingIPv4: true),
              head.count + rest.count <= 7   // "::" must stand for at least one group
        else { return nil }
        return head + [UInt16](repeating: 0, count: 8 - head.count - rest.count) + rest
    }
}
