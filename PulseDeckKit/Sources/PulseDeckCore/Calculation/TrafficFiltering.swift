import Foundation

/// Coarse placement of a destination, for the Traffic scope filters and the live rate chart.
public enum TrafficScopeClass: Int, CaseIterable, Hashable, Sendable {
    /// Loopback and unspecified addresses: traffic that never leaves this Mac.
    case thisMac
    /// Private, link-local and multicast addresses.
    case localNetwork
    /// Everything routed: the internet and Tailscale.
    case external
}

extension DestinationScope {
    public var trafficClass: TrafficScopeClass {
        switch self {
        case .loopback, .unspecified: .thisMac
        case .localNetwork, .linkLocal, .multicast: .localNetwork
        case .internet, .tailscale: .external
        }
    }
}

/// Filters of the Traffic section: scope toggles, "only active" and the search field.
public struct TrafficFilter: Hashable, Sendable {
    public var hidesLocalNetwork: Bool
    public var hidesThisMac: Bool
    public var onlyActive: Bool
    public var searchText: String

    public init(hidesLocalNetwork: Bool = false, hidesThisMac: Bool = true, onlyActive: Bool = false, searchText: String = "") {
        self.hidesLocalNetwork = hidesLocalNetwork
        self.hidesThisMac = hidesThisMac
        self.onlyActive = onlyActive
        self.searchText = searchText
    }

    /// Whether destinations of this placement are shown.
    public func includes(_ scopeClass: TrafficScopeClass) -> Bool {
        switch scopeClass {
        case .thisMac: !hidesThisMac
        case .localNetwork: !hidesLocalNetwork
        case .external: true
        }
    }

    /// Search terms; a destination must match every one of them.
    public var searchTokens: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether `destination` matches the search: address, host name, country (code or name),
    /// provider, service, process name, transport and port number.
    public func matchesSearch(_ destination: DestinationTotals, info: DestinationInfo, hostName: String?, locale: Locale = .current) -> Bool {
        let tokens = searchTokens
        guard !tokens.isEmpty else { return true }
        var fields = [destination.address]
        if let hostName { fields.append(hostName) }
        if let code = info.countryCode {
            fields.append(code)
            if let name = TrafficLabels.countryName(regionCode: code, locale: locale) { fields.append(name) }
        }
        if let provider = info.provider { fields.append(provider) }
        if let service = info.service { fields.append(service) }
        for process in destination.processes { fields.append(process.processName) }
        for port in destination.ports {
            fields.append(port.transport.name)
            fields.append(String(port.port))
        }
        // One haystack per destination: a single scan per term instead of one per field.
        let haystack = fields.joined(separator: "\n")
        return tokens.allSatisfy { token in
            haystack.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Splits `destinations` (with their `infos`, index for index) into those inside the scope
    /// toggles and those that also pass "only active" and the search. The first set feeds the
    /// header totals, the second the visualisation and the table.
    public func partition(_ destinations: [DestinationTotals], infos: [DestinationInfo], hostNames: [String: String] = [:], locale: Locale = .current) -> TrafficPartition {
        precondition(destinations.count == infos.count, "infos must match destinations")
        var inScope: [DestinationTotals] = []
        var visible: [DestinationTotals] = []
        for index in destinations.indices {
            let destination = destinations[index]
            let info = infos[index]
            guard includes(info.scope.trafficClass) else { continue }
            inScope.append(destination)
            if onlyActive && destination.activeFlowCount == 0 { continue }
            if matchesSearch(destination, info: info, hostName: hostNames[destination.address], locale: locale) {
                visible.append(destination)
            }
        }
        return TrafficPartition(inScope: inScope, visible: visible)
    }
}

public struct TrafficPartition: Sendable {
    public var inScope: [DestinationTotals]
    public var visible: [DestinationTotals]
}

/// Remembers the offline classification of each destination so a once-per-second refresh does not
/// classify thousands of addresses again. An entry is reused while the destination's main
/// remote port stays the same (the service depends on it).
public struct TrafficInfoCache: Sendable {
    private struct Entry: Sendable {
        var port: UInt16
        var transport: FlowTransport
        var info: DestinationInfo
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// Classification of each destination, index for index. Entries of destinations that are
    /// no longer present are dropped, so the cache cannot grow beyond the current ledger.
    public mutating func infos(for destinations: [DestinationTotals], classifier: any DestinationClassifying) -> [DestinationInfo] {
        var next: [String: Entry] = Dictionary(minimumCapacity: destinations.count)
        var result: [DestinationInfo] = []
        result.reserveCapacity(destinations.count)
        for destination in destinations {
            let port = destination.ports.first?.port ?? 0
            let transport = destination.ports.first?.transport ?? .tcp
            if let entry = entries[destination.address], entry.port == port, entry.transport == transport {
                next[destination.address] = entry
                result.append(entry.info)
            } else {
                let info = classifier.info(forAddress: destination.address, port: port, transport: transport)
                next[destination.address] = Entry(port: port, transport: transport, info: info)
                result.append(info)
            }
        }
        entries = next
        return result
    }
}

/// Which addresses are worth a reverse-DNS lookup.
public enum TrafficHostNameSelection {
    /// The `limit` busiest destinations that can have a meaningful public or LAN name: not
    /// loopback, unspecified or multicast addresses. Busiest first (bytes, then active flows,
    /// then most recently seen).
    public static func candidates(destinations: [DestinationTotals], infos: [DestinationInfo], limit: Int) -> [String] {
        precondition(destinations.count == infos.count, "infos must match destinations")
        let eligible = destinations.indices.filter { index in
            switch infos[index].scope {
            case .internet, .localNetwork, .linkLocal, .tailscale: true
            case .loopback, .multicast, .unspecified: false
            }
        }
        let ranked = eligible.sorted { lhs, rhs in
            let a = destinations[lhs]
            let b = destinations[rhs]
            if a.totalBytes != b.totalBytes { return a.totalBytes > b.totalBytes }
            if a.activeFlowCount != b.activeFlowCount { return a.activeFlowCount > b.activeFlowCount }
            if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
            return a.address < b.address
        }
        return ranked.prefix(max(limit, 0)).map { destinations[$0].address }
    }
}
