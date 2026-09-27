/// Classifies network interfaces for display (SPEC §16, §17). Never hides an interface: anything
/// that cannot be classified is `.other`.
public enum NetworkInterfaceClassifier {
    /// `ifi_type` values from xnu `net/if_types.h`.
    public enum InterfaceType {
        public static let ethernet: UInt8 = 0x06   // IFT_ETHER (also used by Wi‑Fi on macOS)
        public static let ppp: UInt8 = 0x17        // IFT_PPP
        public static let loopback: UInt8 = 0x18   // IFT_LOOP
        public static let gif: UInt8 = 0x37        // IFT_GIF (generic tunnel)
        public static let stf: UInt8 = 0x39        // IFT_STF (6to4 tunnel)
        public static let bridge: UInt8 = 0xd1     // IFT_BRIDGE
        public static let cellular: UInt8 = 0xff   // IFT_CELLULAR
    }

    /// Interface type strings from SystemConfiguration (`kSCNetworkInterfaceType*`).
    public enum SystemConfigurationType {
        public static let ethernet = "Ethernet"
        public static let wifi = "IEEE80211"
        public static let bridge = "Bridge"
        public static let ppp = "PPP"
        public static let ipsec = "IPSec"
        public static let vpn = "VPN"
        public static let wwan = "WWAN"
    }

    /// BSD name prefixes of tunnel interfaces. `utun` is used by Network Extension VPNs and by
    /// system services (e.g. iCloud Private Relay), so it is labelled generically.
    public static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "gif", "stf"]

    public static func classify(
        bsdName: String,
        interfaceType: UInt8,
        isLoopback: Bool,
        systemConfigurationType: String?,
        displayName: String?
    ) -> NetworkInterfaceKind {
        if isLoopback || interfaceType == InterfaceType.loopback {
            return .loopback
        }
        let mentionsThunderbolt = displayName?.lowercased().contains("thunderbolt") ?? false
        switch systemConfigurationType {
        case SystemConfigurationType.wifi:
            return .wifi
        case SystemConfigurationType.ethernet:
            return mentionsThunderbolt ? .thunderbolt : .ethernet
        case SystemConfigurationType.bridge:
            return mentionsThunderbolt ? .thunderbolt : .bridge
        case SystemConfigurationType.wwan:
            return .cellular
        case SystemConfigurationType.ppp, SystemConfigurationType.ipsec, SystemConfigurationType.vpn:
            return .vpnTunnel(friendlyName: displayName)
        default:
            break
        }
        if tunnelPrefixes.contains(where: { bsdName.hasPrefix($0) })
            || interfaceType == InterfaceType.gif || interfaceType == InterfaceType.stf || interfaceType == InterfaceType.ppp {
            return .vpnTunnel(friendlyName: nil)
        }
        if interfaceType == InterfaceType.bridge || bsdName.hasPrefix("bridge") {
            return .bridge
        }
        if interfaceType == InterfaceType.cellular || bsdName.hasPrefix("pdp_ip") {
            return .cellular
        }
        // IFT_ETHER alone does not distinguish Ethernet from Wi‑Fi on macOS, so without
        // SystemConfiguration information the interface stays unclassified.
        return .other
    }
}

