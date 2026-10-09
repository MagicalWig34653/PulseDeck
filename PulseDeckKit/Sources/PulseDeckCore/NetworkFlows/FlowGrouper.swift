import Foundation

/// STUB API (geo/classification agent implements; keep these signatures).
public enum FlowGrouper {
    /// Groups destinations. Classification comes from `classifier` (offline); `hostNames` maps
    /// addresses to reverse-DNS names (only used for the `destination` grouping's titles).
    /// Sorted by total bytes, descending; unknown classification forms the `FlowGroup.unknownKey` group.
    public static func group(_ destinations: [DestinationTotals], by grouping: FlowGrouping, classifier: any DestinationClassifying, hostNames: [String: String] = [:]) -> [FlowGroup] {
        []
    }
}

/// STUB (geo/classification agent implements; keep the public API). Offline country / provider /
/// service lookup from a compact binary database produced by `scripts/build-geoip.py`
/// (`PulseDeck/Resources/GeoIP.bin`), plus built-in tables (private ranges, well-known
/// providers, port → service).
public struct DestinationClassifier: DestinationClassifying {
    /// - Parameter geoData: contents of `GeoIP.bin`; `nil` → only built-in tables.
    public init(geoData: Data? = nil) {}

    public func info(forAddress address: String, port: UInt16, transport: FlowTransport) -> DestinationInfo {
        DestinationInfo(scope: .unspecified)
    }
}
