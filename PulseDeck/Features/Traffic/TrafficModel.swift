import PulseDeckCore
import PulseDeckTelemetry
import SwiftUI

// MARK: - Classifier

/// The offline classifier, created once from the bundled GeoIP database (`GeoIP.bin`). Without
/// the file only the built-in tables apply (private ranges, well-known ports …).
enum TrafficClassifier {
    private static let geoData: Data? = Bundle.main.url(forResource: "GeoIP", withExtension: "bin")
        .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }

    static let shared = DestinationClassifier(geoData: geoData)

    /// Whether the country / provider database is part of this build.
    static var hasGeoData: Bool { geoData != nil }
}

// MARK: - Presentation types

/// One row of the Traffic table: a group, or a destination (inside a group, or at top level when
/// grouping by destination). All numbers and strings are prepared off the main thread, so cells
/// only draw.
struct TrafficRow: Identifiable, Sendable, TrafficSortable {
    enum Kind: Sendable {
        case group
        case destination
    }

    /// "g|<group>" for group rows (and top-level destination rows), "d|<group>|<address>" for
    /// destinations inside an expanded group.
    let id: String
    let groupID: String
    let kind: Kind
    let depth: Int
    let title: String
    /// Secondary text after the title: the address behind a host name, or the member count.
    let detail: String?
    let flag: String?
    /// Country name, or the scope for local traffic ("Local network").
    let location: String
    let providerService: String
    let bytesReceived: UInt64
    let bytesSent: UInt64
    let receiveRate: Double?
    let sendRate: Double?
    let activeFlows: Int
    let totalFlows: Int
    let lastSeen: Date?
    /// `false` when the source carries no byte counters: bytes render as "—".
    let hasCounters: Bool
    /// Fraction of all shown traffic, 0…1.
    let share: Double
    let isExpandable: Bool
    let isExpanded: Bool
    /// Group rows leave room for the disclosure triangle; so do their members' siblings.
    let reservesDisclosureSpace: Bool
    let receivedText: String
    let sentText: String
    let totalText: String
    let receiveRateText: String
    let sendRateText: String
    let flowsText: String
    let lastSeenText: String
    /// The destination behind a destination row.
    let destination: DestinationTotals?
    /// Every destination of a group row.
    let members: [DestinationTotals]
    let info: DestinationInfo?
    let hostName: String?

    static func rowID(forGroup groupID: String) -> String { "g|" + groupID }

    // Sort keys. Missing values sort below every real value (−1).
    var nameSort: String { title }
    var receivedSort: Double { hasCounters ? Double(bytesReceived) : -1 }
    var sentSort: Double { hasCounters ? Double(bytesSent) : -1 }
    var totalSort: Double { hasCounters ? Double(bytesReceived) + Double(bytesSent) : -1 }
    var receiveRateSort: Double { receiveRate ?? -1 }
    var sendRateSort: Double { sendRate ?? -1 }
    var flowsSort: Int { activeFlows &* 1_000_000 &+ min(totalFlows, 999_999) }
    var lastSeenSort: Double { lastSeen?.timeIntervalSince1970 ?? -1 }

    var sortName: String { title }

    func sortValue(for key: TrafficSortKey) -> Double {
        switch key {
        case .name: 0
        case .received: receivedSort
        case .sent: sentSort
        case .total: totalSort
        case .receiveRate: receiveRateSort
        case .sendRate: sendRateSort
        case .flows: Double(flowsSort)
        case .lastSeen: lastSeenSort
        }
    }
}

extension TrafficSortOrder {
    /// Maps a column header click to a sort order; `nil` for columns that cannot be sorted.
    /// Key paths are compared like `ProcessSorting` does: the table's own sorting is never used.
    init?(_ comparator: KeyPathComparator<TrafficRow>) {
        let path = comparator.keyPath
        let key: TrafficSortKey
        if path == \TrafficRow.nameSort {
            key = .name
        } else if path == \TrafficRow.receivedSort {
            key = .received
        } else if path == \TrafficRow.sentSort {
            key = .sent
        } else if path == \TrafficRow.totalSort {
            key = .total
        } else if path == \TrafficRow.receiveRateSort {
            key = .receiveRate
        } else if path == \TrafficRow.sendRateSort {
            key = .sendRate
        } else if path == \TrafficRow.flowsSort {
            key = .flows
        } else if path == \TrafficRow.lastSeenSort {
            key = .lastSeen
        } else {
            return nil
        }
        self.init(key: key, ascending: comparator.order == .forward)
    }
}

/// One tile of the treemap.
struct TrafficTile: Identifiable, Sendable {
    /// The group ID, or `TrafficTreemap.otherID`.
    let id: String
    let title: String
    let flag: String?
    let weight: Double
    let share: Double
    /// "12.3 GB", or "4 connections" without byte counters.
    let valueText: String
    /// "↓ 11 GB  ↑ 1.3 GB"; empty without byte counters.
    let directionText: String
    /// Received fraction of the tile's bytes (the rest was sent); `nil` without counters.
    let receivedFraction: Double?
    let accessibilityLabel: String

    var isOther: Bool { id == TrafficTreemap.otherID }
}

/// What the Traffic page shows, built off the main thread once per second.
struct TrafficSnapshot: Sendable {
    var rows: [TrafficRow] = []
    var rowsByID: [String: TrafficRow] = [:]
    /// Rows left out by the row limit ("Show More").
    var hiddenRowCount = 0
    var tiles: [TrafficTile] = []
    var totals = TrafficTotals.empty
    /// Destinations in the ledger before any filter.
    var ledgerDestinationCount = 0
    var source: FlowSource?
    var recordingSince: Date?
    var hasByteCounters = true
    var hostNameCandidates: [String] = []
    var rateSums = TrafficRateSums.none

    static let empty = TrafficSnapshot()
}

/// The inputs that change what is shown. Any change restarts the refresh at once; otherwise the
/// page refreshes at most once per second.
struct TrafficControls: Hashable, Sendable {
    var grouping: FlowGrouping
    var filter: TrafficFilter
    var sort: TrafficSortOrder
    var expanded: Set<String>
    var rowLimit: Int
    var hostNamesVersion: Int
    var refreshToken: Int
}

struct TrafficBuildInput: Sendable {
    var destinations: [DestinationTotals]
    var hasByteCounters: Bool
    var source: FlowSource?
    var recordingSince: Date?
    var controls: TrafficControls
    var hostNames: [String: String]
    var infoCache: TrafficInfoCache
    var now: Date
}

struct TrafficBuildOutput: Sendable {
    var snapshot: TrafficSnapshot
    var infoCache: TrafficInfoCache
}

// MARK: - Text

extension FlowGrouping {
    var title: String {
        switch self {
        case .destination: String(localized: "Destination")
        case .country: String(localized: "Country")
        case .provider: String(localized: "Provider")
        case .service: String(localized: "Service")
        case .process: String(localized: "Process")
        case .transportProtocol: String(localized: "Protocol")
        case .port: String(localized: "Port")
        }
    }
}

enum TrafficFormat {
    static let dash = "—"

    static func bytes(_ value: UInt64, counters: Bool) -> String {
        counters ? Format.storage(value) : dash
    }

    static func rate(_ value: Double?, counters: Bool) -> String {
        guard counters, let value else { return dash }
        return Format.rate(value)
    }

    static func lastSeen(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    static func scopeName(_ scope: DestinationScope) -> String {
        switch scope {
        case .internet: String(localized: "Internet")
        case .localNetwork: String(localized: "Local network")
        case .loopback: String(localized: "This Mac (loopback)")
        case .linkLocal: String(localized: "Link-local")
        case .multicast: String(localized: "Multicast")
        case .tailscale: String(localized: "Tailscale")
        case .unspecified: String(localized: "Unspecified")
        }
    }

    /// Flag and name of where a destination is: its country, or its scope for local traffic.
    /// Traffic without a known country is "Unknown", never hidden.
    static func location(of info: DestinationInfo) -> (flag: String?, name: String) {
        if info.scope == .internet || info.countryCode != nil {
            guard let code = info.countryCode, !code.isEmpty else { return (nil, String(localized: "Unknown")) }
            return (TrafficLabels.flagEmoji(regionCode: code), TrafficLabels.countryName(regionCode: code) ?? code)
        }
        return (nil, scopeName(info.scope))
    }

    static func providerService(of info: DestinationInfo) -> String {
        let provider = info.provider ?? (info.scope == .internet ? String(localized: "Unknown") : nil)
        return [provider, info.service].compactMap { $0 }.joined(separator: " · ")
    }

    static func memberCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 destination") : String(localized: "\(count) destinations")
    }
}

enum TrafficPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .mint, .brown, .cyan]

    /// A stable colour per group key; unclassified traffic and "Other" are grey.
    static func color(forGroup id: String) -> Color {
        if id == FlowGroup.unknownKey || id == TrafficTreemap.otherID { return .gray }
        return colors[TrafficLabels.paletteIndex(forKey: id, count: colors.count)]
    }
}

// MARK: - Builder

/// Turns the ledger into rows and tiles. Pure and nonisolated: it runs on a background task.
enum TrafficBuilder {
    static let hostNameCandidateLimit = 150
    static let maximumTiles = 24
    static let minimumTileShare = 0.01

    private struct Context {
        let grouping: FlowGrouping
        let hasByteCounters: Bool
        let hostNames: [String: String]
        let infoByAddress: [String: DestinationInfo]
        let now: Date
        let shareBase: UInt64
    }

    private struct SortItem: TrafficSortable {
        let index: Int
        let sortName: String
        let received: Double
        let sent: Double
        let receiveRate: Double
        let sendRate: Double
        let flows: Double
        let lastSeen: Double

        func sortValue(for key: TrafficSortKey) -> Double {
            switch key {
            case .name: 0
            case .received: received
            case .sent: sent
            case .total: received < 0 ? -1 : received + sent
            case .receiveRate: receiveRate
            case .sendRate: sendRate
            case .flows: flows
            case .lastSeen: lastSeen
            }
        }
    }

    static func build(_ input: TrafficBuildInput, classifier: any DestinationClassifying) -> TrafficBuildOutput {
        var cache = input.infoCache
        let destinations = input.destinations
        let infos = cache.infos(for: destinations, classifier: classifier)
        let rateSums = TrafficRateSums(destinations: destinations, classes: infos.map { $0.scope.trafficClass })
        let candidates = TrafficHostNameSelection.candidates(destinations: destinations, infos: infos, limit: hostNameCandidateLimit)

        let controls = input.controls
        let partition = controls.filter.partition(destinations, infos: infos, hostNames: input.hostNames)
        var totals = TrafficTotals(destinations: partition.inScope)
        totals.hasByteCounters = input.hasByteCounters

        let infoByAddress = Dictionary(zip(destinations.map(\.address), infos), uniquingKeysWith: { first, _ in first })
        let groups = FlowGrouper.group(partition.visible, by: controls.grouping, classifier: classifier, hostNames: input.hostNames)
        let shareBase = groups.reduce(0 as UInt64) { $0 &+ $1.totalBytes }
        let context = Context(grouping: controls.grouping, hasByteCounters: input.hasByteCounters, hostNames: input.hostNames,
                              infoByAddress: infoByAddress, now: input.now, shareBase: shareBase)

        // Without byte counters only connections can be ordered.
        var sort = controls.sort
        if !input.hasByteCounters {
            switch sort.key {
            case .name, .flows, .lastSeen: break
            default: sort = TrafficSortOrder(key: .flows, ascending: false)
            }
        }

        let (rows, available) = makeRows(for: groups, controls: controls, sort: sort, context: context)
        var snapshot = TrafficSnapshot()
        snapshot.rows = rows
        snapshot.rowsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot.hiddenRowCount = max(available - rows.count, 0)
        snapshot.tiles = tiles(for: groups, context: context)
        snapshot.totals = totals
        snapshot.ledgerDestinationCount = destinations.count
        snapshot.source = input.source
        snapshot.recordingSince = input.recordingSince
        snapshot.hasByteCounters = input.hasByteCounters
        snapshot.hostNameCandidates = candidates
        snapshot.rateSums = rateSums
        return TrafficBuildOutput(snapshot: snapshot, infoCache: cache)
    }

    // MARK: Rows

    /// The visible rows (at most `rowLimit`) and how many rows there would be without the limit.
    private static func makeRows(for groups: [FlowGroup], controls: TrafficControls, sort: TrafficSortOrder, context: Context) -> ([TrafficRow], Int) {
        var rows: [TrafficRow] = []
        var budget = controls.rowLimit

        if context.grouping == .destination {
            // One destination per group: show the destinations themselves.
            let pairs = groups.compactMap { group in group.destinations.first.map { (group: group, destination: $0) } }
            let items = pairs.indices.map { index in
                sortItem(for: pairs[index].destination, index: index, context: context)
            }
            for item in TrafficSorting.sorted(items, by: sort).prefix(max(budget, 0)) {
                let pair = pairs[item.index]
                rows.append(destinationRow(pair.destination, id: TrafficRow.rowID(forGroup: pair.group.id), groupID: pair.group.id,
                                           depth: 0, reservesDisclosureSpace: false, context: context))
            }
            return (rows, pairs.count)
        }

        var available = 0
        let groupItems = groups.indices.map { index in sortItem(for: groups[index], index: index, context: context) }
        for item in TrafficSorting.sorted(groupItems, by: sort) {
            let group = groups[item.index]
            let isExpanded = controls.expanded.contains(group.id)
            available += 1 + (isExpanded ? group.destinations.count : 0)
            guard budget > 0 else { continue }
            rows.append(groupRow(group, isExpanded: isExpanded, context: context))
            budget -= 1
            guard isExpanded, budget > 0 else { continue }
            let memberItems = group.destinations.indices.map { index in
                sortItem(for: group.destinations[index], index: index, context: context)
            }
            for member in TrafficSorting.sorted(memberItems, by: sort).prefix(budget) {
                rows.append(destinationRow(group.destinations[member.index], id: "d|\(group.id)|\(group.destinations[member.index].address)",
                                           groupID: group.id, depth: 1, reservesDisclosureSpace: false, context: context))
                budget -= 1
            }
        }
        return (rows, available)
    }

    private static func sortItem(for destination: DestinationTotals, index: Int, context: Context) -> SortItem {
        let counters = context.hasByteCounters && destination.hasByteCounters
        return SortItem(
            index: index,
            sortName: context.hostNames[destination.address] ?? destination.address,
            received: counters ? Double(destination.bytesReceived) : -1,
            sent: counters ? Double(destination.bytesSent) : -1,
            receiveRate: destination.receiveBytesPerSecond ?? -1,
            sendRate: destination.sendBytesPerSecond ?? -1,
            flows: Double(destination.activeFlowCount) * 1_000_000 + Double(min(destination.flowCount, 999_999)),
            lastSeen: destination.lastSeen.timeIntervalSince1970
        )
    }

    private static func sortItem(for group: FlowGroup, index: Int, context: Context) -> SortItem {
        SortItem(
            index: index,
            sortName: groupIdentity(group, grouping: context.grouping).title,
            received: context.hasByteCounters ? Double(group.bytesReceived) : -1,
            sent: context.hasByteCounters ? Double(group.bytesSent) : -1,
            receiveRate: group.receiveBytesPerSecond,
            sendRate: group.sendBytesPerSecond,
            flows: Double(group.activeFlowCount) * 1_000_000 + Double(min(group.destinations.reduce(0) { $0 + $1.flowCount }, 999_999)),
            lastSeen: group.destinations.map(\.lastSeen).max()?.timeIntervalSince1970 ?? -1
        )
    }

    /// Title and flag of a group. A country group's key is its region code; the name comes from
    /// the system so it follows the user's language.
    static func groupIdentity(_ group: FlowGroup, grouping: FlowGrouping) -> (title: String, flag: String?) {
        if group.id == FlowGroup.unknownKey { return (String(localized: "Unknown"), nil) }
        let fallback = group.title.isEmpty ? group.id : group.title
        if grouping == .country, let flag = TrafficLabels.flagEmoji(regionCode: group.id) {
            return (TrafficLabels.countryName(regionCode: group.id) ?? fallback, flag)
        }
        return (fallback, nil)
    }

    private static func groupRow(_ group: FlowGroup, isExpanded: Bool, context: Context) -> TrafficRow {
        let identity = groupIdentity(group, grouping: context.grouping)
        let counters = context.hasByteCounters
        let totalFlows = group.destinations.reduce(0) { $0 + $1.flowCount }
        let lastSeen = group.destinations.map(\.lastSeen).max()
        return TrafficRow(
            id: TrafficRow.rowID(forGroup: group.id), groupID: group.id, kind: .group, depth: 0,
            title: identity.title, detail: TrafficFormat.memberCount(group.destinationCount), flag: identity.flag,
            location: "", providerService: "",
            bytesReceived: group.bytesReceived, bytesSent: group.bytesSent,
            receiveRate: group.receiveBytesPerSecond, sendRate: group.sendBytesPerSecond,
            activeFlows: group.activeFlowCount, totalFlows: totalFlows, lastSeen: lastSeen,
            hasCounters: counters,
            share: counters ? TrafficLabels.share(group.totalBytes, of: context.shareBase) : 0,
            isExpandable: true, isExpanded: isExpanded, reservesDisclosureSpace: true,
            receivedText: TrafficFormat.bytes(group.bytesReceived, counters: counters),
            sentText: TrafficFormat.bytes(group.bytesSent, counters: counters),
            totalText: TrafficFormat.bytes(group.totalBytes, counters: counters),
            receiveRateText: TrafficFormat.rate(group.receiveBytesPerSecond, counters: counters),
            sendRateText: TrafficFormat.rate(group.sendBytesPerSecond, counters: counters),
            flowsText: "\(group.activeFlowCount) / \(totalFlows)",
            lastSeenText: lastSeen.map { TrafficFormat.lastSeen($0, now: context.now) } ?? TrafficFormat.dash,
            destination: nil, members: group.destinations, info: nil, hostName: nil
        )
    }

    private static func destinationRow(_ destination: DestinationTotals, id: String, groupID: String, depth: Int, reservesDisclosureSpace: Bool, context: Context) -> TrafficRow {
        let info = context.infoByAddress[destination.address] ?? DestinationInfo(scope: .unspecified)
        let hostName = context.hostNames[destination.address]
        let counters = context.hasByteCounters && destination.hasByteCounters
        let location = TrafficFormat.location(of: info)
        return TrafficRow(
            id: id, groupID: groupID, kind: .destination, depth: depth,
            title: hostName ?? destination.address, detail: hostName == nil ? nil : destination.address, flag: location.flag,
            location: location.name, providerService: TrafficFormat.providerService(of: info),
            bytesReceived: destination.bytesReceived, bytesSent: destination.bytesSent,
            receiveRate: destination.receiveBytesPerSecond, sendRate: destination.sendBytesPerSecond,
            activeFlows: destination.activeFlowCount, totalFlows: destination.flowCount, lastSeen: destination.lastSeen,
            hasCounters: counters,
            share: counters ? TrafficLabels.share(destination.totalBytes, of: context.shareBase) : 0,
            isExpandable: false, isExpanded: false, reservesDisclosureSpace: reservesDisclosureSpace,
            receivedText: TrafficFormat.bytes(destination.bytesReceived, counters: counters),
            sentText: TrafficFormat.bytes(destination.bytesSent, counters: counters),
            totalText: TrafficFormat.bytes(destination.totalBytes, counters: counters),
            receiveRateText: TrafficFormat.rate(destination.receiveBytesPerSecond, counters: counters),
            sendRateText: TrafficFormat.rate(destination.sendBytesPerSecond, counters: counters),
            flowsText: "\(destination.activeFlowCount) / \(destination.flowCount)",
            lastSeenText: TrafficFormat.lastSeen(destination.lastSeen, now: context.now),
            destination: destination, members: [], info: info, hostName: hostName
        )
    }

    // MARK: Tiles

    private static func tiles(for groups: [FlowGroup], context: Context) -> [TrafficTile] {
        let counters = context.hasByteCounters
        let weights = groups.map { counters ? Double($0.totalBytes) : Double($0.activeFlowCount) }
        let entries = TrafficTreemap.entries(ids: groups.map(\.id), weights: weights, maximumTiles: maximumTiles, minimumShare: minimumTileShare)
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keptIDs = Set(entries.filter { !$0.isOther }.map(\.id))

        return entries.compactMap { entry -> TrafficTile? in
            let title: String
            var flag: String?
            let received: UInt64
            let sent: UInt64
            let flows: Int
            if entry.isOther {
                let rest = groups.filter { !keptIDs.contains($0.id) }
                title = String(localized: "Other (\(entry.memberCount))")
                received = rest.reduce(0) { $0 &+ $1.bytesReceived }
                sent = rest.reduce(0) { $0 &+ $1.bytesSent }
                flows = rest.reduce(0) { $0 + $1.activeFlowCount }
            } else if let group = byID[entry.id] {
                if context.grouping == .destination, let destination = group.destinations.first {
                    title = context.hostNames[destination.address] ?? destination.address
                    flag = context.infoByAddress[destination.address].flatMap { TrafficFormat.location(of: $0).flag }
                } else {
                    let identity = groupIdentity(group, grouping: context.grouping)
                    title = identity.title
                    flag = identity.flag
                }
                received = group.bytesReceived
                sent = group.bytesSent
                flows = group.activeFlowCount
            } else {
                return nil
            }
            let total = received &+ sent
            let percent = Format.percent(entry.share)
            let valueText = counters ? Format.storage(total) : String(localized: "\(flows) connections")
            let directionText = counters ? "↓ \(Format.storage(received))  ↑ \(Format.storage(sent))" : ""
            let spoken = counters
                ? String(localized: "\(title), \(valueText), \(percent) of traffic, \(Format.storage(received)) received, \(Format.storage(sent)) sent")
                : String(localized: "\(title), \(valueText), \(percent) of connections")
            return TrafficTile(
                id: entry.id, title: title, flag: flag, weight: entry.weight, share: entry.share,
                valueText: valueText, directionText: directionText,
                receivedFraction: counters && total > 0 ? TrafficLabels.share(received, of: total) : nil,
                accessibilityLabel: spoken
            )
        }
    }
}

// MARK: - Model

/// Hover shared between the treemap and the table. A separate object, so hovering only redraws
/// the views that read it.
@MainActor
@Observable
final class TrafficHover {
    var groupID: String?
}

/// State of the Traffic page: the last built snapshot, the rolling rate history, resolved host
/// names and the table's expansion. Rebuilds run off the main actor, at most once per second.
@MainActor
@Observable
final class TrafficModel {
    static let pageSize = 400

    private(set) var snapshot = TrafficSnapshot.empty
    private(set) var hasBuilt = false
    private(set) var rateHistory = TrafficRateHistory()
    private(set) var hostNames: [String: String] = [:]
    private(set) var hostNamesVersion = 0
    private(set) var refreshToken = 0
    var expanded = Set<String>()
    var rowLimit = TrafficModel.pageSize

    @ObservationIgnored private var infoCache = TrafficInfoCache()

    /// Refreshes the page when the ledger changed (checked once per second) or `controls`
    /// changed (the caller restarts this loop for those, so the first pass is immediate).
    func refreshLoop(appState: AppState, controls: TrafficControls) async {
        var lastRevision: UInt64?
        while !Task.isCancelled {
            let revision = appState.flowLedgerRevision
            if revision != lastRevision {
                lastRevision = revision
                await rebuild(appState: appState, controls: controls)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func rebuild(appState: AppState, controls: TrafficControls) async {
        let ledger = appState.flowLedger
        let timestamp = appState.latestSnapshot?.timestamp
        let input = TrafficBuildInput(
            destinations: ledger.destinations,
            hasByteCounters: ledger.source != .socketTable,
            source: ledger.source,
            recordingSince: ledger.recordingSince,
            controls: controls,
            hostNames: hostNames,
            infoCache: infoCache,
            now: Date()
        )
        let output = await Task.detached(priority: .userInitiated) {
            TrafficBuilder.build(input, classifier: TrafficClassifier.shared)
        }.value
        guard !Task.isCancelled else { return }
        infoCache = output.infoCache
        snapshot = output.snapshot
        hasBuilt = true
        if let timestamp {
            rateHistory.append(output.snapshot.rateSums, at: timestamp)
        }
    }

    /// Looks up host names of the busiest destinations every few seconds.
    func resolveHostNamesLoop() async {
        while !Task.isCancelled {
            let candidates = snapshot.hostNameCandidates
            if !candidates.isEmpty {
                let names = await HostNameResolver.shared.resolve(candidates)
                if Task.isCancelled { return }
                if names != hostNames {
                    hostNames = names
                    hostNamesVersion &+= 1
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func clearHostNames() {
        guard !hostNames.isEmpty else { return }
        hostNames = [:]
        hostNamesVersion &+= 1
    }

    func toggleExpansion(of groupID: String) {
        if expanded.contains(groupID) {
            expanded.remove(groupID)
        } else {
            expanded.insert(groupID)
        }
    }

    func showMoreRows() {
        rowLimit += Self.pageSize
    }

    /// After the ledger was reset: forget the chart and rebuild at once.
    func didResetLedger() {
        rateHistory.removeAll()
        rowLimit = Self.pageSize
        refreshToken &+= 1
    }
}
