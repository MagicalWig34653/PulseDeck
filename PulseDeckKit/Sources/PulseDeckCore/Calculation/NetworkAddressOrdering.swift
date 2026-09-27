/// Orders textual IP addresses for display: IPv4 first, then routable IPv6, then link-local
/// IPv6 (fe80::/10), which is rarely what a user is looking for.
public enum NetworkAddressOrdering {
    public static func isIPv4(_ address: String) -> Bool {
        !address.contains(":")
    }

    public static func isLinkLocal(_ address: String) -> Bool {
        let lowercased = address.lowercased()
        return lowercased.hasPrefix("fe8") || lowercased.hasPrefix("fe9")
            || lowercased.hasPrefix("fea") || lowercased.hasPrefix("feb")
            || lowercased.hasPrefix("169.254.")
    }

    /// Removes an IPv6 zone index ("fe80::1%en0" → "fe80::1"); the interface is shown anyway.
    public static func withoutZone(_ address: String) -> String {
        address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
    }

    public static func sorted(_ addresses: [String]) -> [String] {
        func rank(_ address: String) -> Int {
            if isIPv4(address) { return isLinkLocal(address) ? 2 : 0 }
            return isLinkLocal(address) ? 3 : 1
        }
        return addresses.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.element), rank(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
