import Foundation

/// Offline country / provider / service lookup. Three layers, all optional-data-safe:
///  1. address ranges (loopback, private, link-local, multicast, Tailscale …) → `DestinationScope`;
///  2. the compact binary database `GeoIP.bin` (`PulseDeck/Resources`, produced by
///     `scripts/build-geoip.py`) → country and provider, internet addresses only;
///  3. the (transport, port) table → service, refined by the provider where unambiguous.
///
/// Unknown stays unknown: without data (or with a corrupt file) country and provider are `nil`, never
/// guessed. Pure Swift, no networking, no platform APIs.
public struct DestinationClassifier: DestinationClassifying {
    private let database: GeoIPDatabase?

    /// - Parameter geoData: contents of `GeoIP.bin`; `nil` → only built-in tables. Data that fails
    ///   validation (corrupt, truncated, unknown version) is treated like `nil`.
    public init(geoData: Data? = nil) {
        self.database = geoData.flatMap { try? GeoIPDatabase(data: $0) }
    }

    /// `true` when a valid `GeoIP.bin` was loaded.
    public var hasGeoData: Bool { database != nil }

    /// Version, date and size of the loaded database (for an About / Settings line).
    public var geoMetadata: GeoIPDatabase.Metadata? { database?.metadata }

    public func info(forAddress address: String, port: UInt16, transport: FlowTransport) -> DestinationInfo {
        guard let parsed = IPAddress(address) else {
            // Not a numeric address: nothing can be said about it.
            return DestinationInfo(scope: .unspecified)
        }
        let scope = AddressScopeClassifier.scope(of: parsed)
        var record = GeoIPDatabase.Record()
        if scope == .internet, let database {
            record = database.lookup(parsed)
        }
        return DestinationInfo(
            scope: scope,
            countryCode: record.countryCode,
            provider: record.provider,
            service: PortServices.name(transport: transport, port: port, provider: record.provider)
        )
    }
}

/// Groups destinations for the Traffic section.
///
/// How destinations are split between groups:
/// - `destination`, `country`, `provider`, `service`: each destination belongs to exactly one group, so
///   the group totals add up to the totals of all destinations. Country, provider and service are
///   taken from the destination's dominant (transport, port) pair, the one with the most bytes.
/// - `process`, `port`, `transportProtocol`: a destination participates in every group it has traffic
///   with. Its bytes are attributed from `ProcessTotals` / `PortTotals`, and the group member is a copy of
///   the destination carrying only that share, so **summed over all groups the bytes still equal the
///   destinations' totals**; `destinationCount` counts the destination once per group, so those counts
///   add up to more than the number of destinations. Bytes that the breakdown does not explain (or
///   destinations without any breakdown) go to the `FlowGroup.unknownKey` group.
///   Rates are split in proportion to the bytes received / sent. Active flows cannot be attributed, so
///   they are counted in the group holding the destination's largest share (ties: first seen in the
///   destination's own breakdown order), never twice.
public enum FlowGrouper {
    /// Groups destinations. Classification comes from `classifier` (offline); `hostNames` maps
    /// addresses to reverse-DNS names (used for the `destination` titles and as a service hint).
    /// Sorted by total bytes, descending (ties: title, then id); unknown classification forms the
    /// `FlowGroup.unknownKey` group. Deterministic; O(n) in destinations plus their breakdown rows.
    public static func group(_ destinations: [DestinationTotals], by grouping: FlowGrouping, classifier: any DestinationClassifying, hostNames: [String: String] = [:]) -> [FlowGroup] {
        var builder = Builder()
        switch grouping {
        case .destination:
            for destination in destinations {
                let name = hostNames[destination.address].flatMap { $0.isEmpty ? nil : $0 }
                builder.add(destination, key: destination.address, title: name ?? destination.address)
            }
        case .country:
            let locale = Locale(identifier: "en_US")
            for destination in destinations {
                let info = classify(destination, with: classifier)
                if let pseudo = pseudoGroup(for: info.scope) {
                    builder.add(destination, key: pseudo.key, title: pseudo.title)
                } else if let code = info.countryCode, !code.isEmpty {
                    builder.add(destination, key: code, title: locale.localizedString(forRegionCode: code) ?? code)
                } else {
                    builder.add(destination, key: FlowGroup.unknownKey, title: unknownTitle)
                }
            }
        case .provider:
            for destination in destinations {
                let info = classify(destination, with: classifier)
                if let pseudo = pseudoGroup(for: info.scope) {
                    builder.add(destination, key: pseudo.key, title: pseudo.title)
                } else if let provider = info.provider, !provider.isEmpty {
                    builder.add(destination, key: provider, title: provider)
                } else {
                    builder.add(destination, key: FlowGroup.unknownKey, title: unknownTitle)
                }
            }
        case .service:
            for destination in destinations {
                if let service = service(of: destination, classifier: classifier, hostName: hostNames[destination.address]) {
                    builder.add(destination, key: service, title: service)
                } else {
                    builder.add(destination, key: FlowGroup.unknownKey, title: unknownTitle)
                }
            }
        case .process:
            for destination in destinations { addByProcess(destination, to: &builder) }
        case .transportProtocol:
            for destination in destinations { addByTransport(destination, to: &builder) }
        case .port:
            // A port group's title depends on all its members (UDP 443 is QUIC, TCP 443 is HTTPS), so the
            // transport mix per port is established first; otherwise the title would depend on input order.
            var tcpBytes: [UInt16: UInt64] = [:]
            var udpBytes: [UInt16: UInt64] = [:]
            for destination in destinations {
                for port in destination.ports {
                    let bytes = port.bytesReceived &+ port.bytesSent
                    switch port.transport {
                    case .tcp: tcpBytes[port.port, default: 0] &+= bytes
                    case .udp: udpBytes[port.port, default: 0] &+= bytes
                    case .other: break
                    }
                }
            }
            let titles = Dictionary(uniqueKeysWithValues: Set(tcpBytes.keys).union(udpBytes.keys).map { port -> (UInt16, String) in
                let preferred: [FlowTransport] = (udpBytes[port] ?? 0) > (tcpBytes[port] ?? 0) ? [.udp, .tcp] : [.tcp, .udp]
                return (port, portTitle(port, preferring: preferred))
            })
            for destination in destinations { addByPort(destination, titles: titles, to: &builder) }
        }
        return builder.finish()
    }

    // MARK: Classification

    static let unknownTitle = "Unknown"

    /// The (transport, port) with the most bytes; ties go to the lower port, then the lower IP protocol
    /// number, so the choice never depends on array order.
    static func dominantPort(of destination: DestinationTotals) -> PortTotals? {
        destination.ports.max { lhs, rhs in
            let (left, right) = (lhs.bytesReceived &+ lhs.bytesSent, rhs.bytesReceived &+ rhs.bytesSent)
            if left != right { return left < right }
            if lhs.port != rhs.port { return lhs.port > rhs.port }
            return lhs.transport.protocolNumber > rhs.transport.protocolNumber
        }
    }

    private static func classify(_ destination: DestinationTotals, with classifier: any DestinationClassifying) -> DestinationInfo {
        let dominant = dominantPort(of: destination)
        return classifier.info(forAddress: destination.address, port: dominant?.port ?? 0, transport: dominant?.transport ?? .other(0))
    }

    /// The service of a destination: the dominant port's service, except that a host-name brand
    /// ("YouTube") replaces a generic web service ("HTTPS"), and fills in when the port says nothing.
    private static func service(of destination: DestinationTotals, classifier: any DestinationClassifying, hostName: String?) -> String? {
        let portService = classify(destination, with: classifier).service
        let hostService = hostName.flatMap { HostNameServices.service(forHostName: $0) }
        guard let portService else { return hostService }
        if PortServices.genericWebServices.contains(portService), let hostService { return hostService }
        return portService
    }

    /// Scopes that are not "the internet" get their own pseudo groups instead of an unknown country or provider.
    private static func pseudoGroup(for scope: DestinationScope) -> (key: String, title: String)? {
        switch scope {
        case .internet: nil
        case .localNetwork: ("local-network", "Local network")
        case .loopback: ("loopback", "This Mac (loopback)")
        case .linkLocal: ("link-local", "Link-local")
        case .multicast: ("multicast", "Multicast")
        case .tailscale: ("tailscale", "Tailscale")
        case .unspecified: ("unspecified", "Unspecified address")
        }
    }

    // MARK: Split groupings

    /// One share of a destination for a split grouping.
    private struct Share {
        var key: String
        var title: String
        var received: UInt64
        var sent: UInt64
        var flowCount: Int?
        var ports: [PortTotals]?
        var processes: [ProcessTotals]?
    }

    private static func addByProcess(_ destination: DestinationTotals, to builder: inout Builder) {
        var byName: [String: ProcessTotals] = [:]
        var order: [String] = []
        for process in destination.processes {
            if var existing = byName[process.processName] {
                existing.bytesReceived = existing.bytesReceived &+ process.bytesReceived
                existing.bytesSent = existing.bytesSent &+ process.bytesSent
                byName[process.processName] = existing
            } else {
                byName[process.processName] = process
                order.append(process.processName)
            }
        }
        let shares = order.map { name -> Share in
            let process = byName[name] ?? ProcessTotals(processName: name)
            return Share(key: name, title: name, received: process.bytesReceived, sent: process.bytesSent, flowCount: nil, ports: nil, processes: [process])
        }
        builder.addSplit(destination, shares: shares, unknownTitle: unknownTitle)
    }

    private static func addByTransport(_ destination: DestinationTotals, to builder: inout Builder) {
        var received: [String: UInt64] = [:]
        var sent: [String: UInt64] = [:]
        var flows: [String: Int] = [:]
        var ports: [String: [PortTotals]] = [:]
        var order: [String] = []
        for port in destination.ports {
            let name = port.transport.name
            if ports[name] == nil { order.append(name) }
            received[name, default: 0] &+= port.bytesReceived
            sent[name, default: 0] &+= port.bytesSent
            flows[name, default: 0] += port.flowCount
            ports[name, default: []].append(port)
        }
        let shares = order.map { name in
            Share(key: name, title: name, received: received[name] ?? 0, sent: sent[name] ?? 0, flowCount: flows[name], ports: ports[name], processes: nil)
        }
        builder.addSplit(destination, shares: shares, unknownTitle: unknownTitle)
    }

    private static func addByPort(_ destination: DestinationTotals, titles: [UInt16: String], to builder: inout Builder) {
        var received: [UInt16: UInt64] = [:]
        var sent: [UInt16: UInt64] = [:]
        var flows: [UInt16: Int] = [:]
        var ports: [UInt16: [PortTotals]] = [:]
        var order: [UInt16] = []
        for port in destination.ports {
            if ports[port.port] == nil { order.append(port.port) }
            received[port.port, default: 0] &+= port.bytesReceived
            sent[port.port, default: 0] &+= port.bytesSent
            flows[port.port, default: 0] += port.flowCount
            ports[port.port, default: []].append(port)
        }
        let shares = order.map { number in
            Share(key: String(number), title: titles[number] ?? portTitle(number), received: received[number] ?? 0,
                  sent: sent[number] ?? 0, flowCount: flows[number], ports: ports[number], processes: nil)
        }
        builder.addSplit(destination, shares: shares, unknownTitle: unknownTitle)
    }

    /// "443 · HTTPS", or just "8123" when the port has no well-known name, or "No port" for port 0.
    static func portTitle(_ port: UInt16, preferring transports: [FlowTransport] = [.tcp, .udp]) -> String {
        if port == 0 { return "No port" }
        for transport in transports {
            if let name = PortServices.name(transport: transport, port: port) { return "\(port) · \(name)" }
        }
        return String(port)
    }

    // MARK: Accumulation

    private struct Accumulator {
        var title: String
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var activeFlows = 0
        var receiveRate = 0.0
        var sendRate = 0.0
        var members: [DestinationTotals] = []
    }

    private struct Builder {
        private var groups: [String: Accumulator] = [:]

        /// The whole destination goes to one group.
        mutating func add(_ destination: DestinationTotals, key: String, title: String) {
            append(destination, key: key, title: title)
        }

        /// The destination is split into `shares`; whatever the shares do not explain goes to the unknown group.
        mutating func addSplit(_ destination: DestinationTotals, shares: [Share], unknownTitle: String) {
            let explainedReceived = shares.reduce(0 as UInt64) { $0 &+ $1.received }
            let explainedSent = shares.reduce(0 as UInt64) { $0 &+ $1.sent }
            var all = shares
            let residualReceived = destination.bytesReceived > explainedReceived ? destination.bytesReceived - explainedReceived : 0
            let residualSent = destination.bytesSent > explainedSent ? destination.bytesSent - explainedSent : 0
            // A destination with no breakdown at all also lands here, even with zero bytes: it must
            // not disappear from the view.
            if shares.isEmpty || residualReceived > 0 || residualSent > 0 {
                all.append(Share(key: FlowGroup.unknownKey, title: unknownTitle, received: residualReceived, sent: residualSent,
                                 flowCount: nil, ports: nil, processes: nil))
            }
            // Active flows go to the largest share (first one wins ties).
            var primary = 0
            for index in all.indices where all[index].received &+ all[index].sent > all[primary].received &+ all[primary].sent {
                primary = index
            }
            for (index, share) in all.enumerated() {
                var member = destination
                member.bytesReceived = share.received
                member.bytesSent = share.sent
                member.activeFlowCount = index == primary ? destination.activeFlowCount : 0
                if let flowCount = share.flowCount { member.flowCount = flowCount }
                if let ports = share.ports { member.ports = ports }
                if let processes = share.processes { member.processes = processes }
                member.receiveBytesPerSecond = Self.scaled(destination.receiveBytesPerSecond, share: share.received,
                                                           total: destination.bytesReceived, isPrimary: index == primary)
                member.sendBytesPerSecond = Self.scaled(destination.sendBytesPerSecond, share: share.sent,
                                                        total: destination.bytesSent, isPrimary: index == primary)
                append(member, key: share.key, title: share.title)
            }
        }

        /// A destination's rate split by byte share. With no bytes to split by, the primary group gets it all.
        private static func scaled(_ rate: Double?, share: UInt64, total: UInt64, isPrimary: Bool) -> Double? {
            guard let rate else { return nil }
            guard total > 0 else { return isPrimary ? rate : 0 }
            return rate * Double(share) / Double(total)
        }

        private mutating func append(_ member: DestinationTotals, key: String, title: String) {
            var accumulator = groups[key] ?? Accumulator(title: title)
            accumulator.received = accumulator.received &+ member.bytesReceived
            accumulator.sent = accumulator.sent &+ member.bytesSent
            accumulator.activeFlows += member.activeFlowCount
            accumulator.receiveRate += member.receiveBytesPerSecond ?? 0
            accumulator.sendRate += member.sendBytesPerSecond ?? 0
            accumulator.members.append(member)
            groups[key] = accumulator
        }

        func finish() -> [FlowGroup] {
            let result = groups.map { key, accumulator in
                FlowGroup(
                    id: key,
                    title: accumulator.title,
                    bytesReceived: accumulator.received,
                    bytesSent: accumulator.sent,
                    destinationCount: accumulator.members.count,
                    activeFlowCount: accumulator.activeFlows,
                    receiveBytesPerSecond: accumulator.receiveRate,
                    sendBytesPerSecond: accumulator.sendRate,
                    destinations: accumulator.members.sorted(by: FlowGrouper.memberOrder)
                )
            }
            return result.sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id < rhs.id
            }
        }
    }

    /// Largest first, then by address, so the order never depends on the input order.
    private static func memberOrder(_ lhs: DestinationTotals, _ rhs: DestinationTotals) -> Bool {
        if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
        return lhs.address < rhs.address
    }
}
