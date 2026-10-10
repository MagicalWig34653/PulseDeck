import Foundation

/// The sortable columns of the Traffic table.
public enum TrafficSortKey: String, CaseIterable, Hashable, Sendable {
    case name
    case received
    case sent
    case total
    case receiveRate
    case sendRate
    case flows
    case lastSeen
}

public struct TrafficSortOrder: Hashable, Sendable {
    public var key: TrafficSortKey
    public var ascending: Bool

    public init(key: TrafficSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// Biggest total first.
    public static let `default` = TrafficSortOrder(key: .total, ascending: false)
}

/// A row that can be sorted by any Traffic column.
public protocol TrafficSortable {
    var sortName: String { get }
    /// Numeric key of a column. Missing values must return a value below every real one (−1),
    /// so they sort last in the default descending order.
    func sortValue(for key: TrafficSortKey) -> Double
}

/// Sorting of the Traffic table. Like `ProcessSorting`, each row's key is read once and indices are
/// sorted, instead of `KeyPathComparator` reading keys through key paths on every comparison.
/// Ties fall back to the name and then the original position, so equal rows keep a stable order
/// from one refresh to the next.
public enum TrafficSorting {
    public static func sorted<Row: TrafficSortable>(_ rows: [Row], by order: TrafficSortOrder) -> [Row] {
        if order.key == .name {
            let names = rows.map(\.sortName)
            let indices = rows.indices.sorted { lhs, rhs in
                let comparison = names[lhs].localizedStandardCompare(names[rhs])
                if comparison == .orderedSame { return lhs < rhs }
                return order.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            return indices.map { rows[$0] }
        }
        let keys = rows.map { $0.sortValue(for: order.key) }
        let names = rows.map(\.sortName)
        let indices = rows.indices.sorted { lhs, rhs in
            if keys[lhs] != keys[rhs] {
                return order.ascending ? keys[lhs] < keys[rhs] : keys[lhs] > keys[rhs]
            }
            let comparison = names[lhs].localizedStandardCompare(names[rhs])
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs < rhs
        }
        return indices.map { rows[$0] }
    }
}

/// Totals shown in the Traffic header.
public struct TrafficTotals: Hashable, Sendable {
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var activeFlows: Int
    public var destinationCount: Int
    /// Sum of the known rates; `nil` when no destination has a rate yet.
    public var receiveBytesPerSecond: Double?
    public var sendBytesPerSecond: Double?
    /// `false` when the flows come from a source without byte counters.
    public var hasByteCounters: Bool

    public static let empty = TrafficTotals(bytesReceived: 0, bytesSent: 0, activeFlows: 0, destinationCount: 0,
                                            receiveBytesPerSecond: nil, sendBytesPerSecond: nil, hasByteCounters: true)

    public init(bytesReceived: UInt64, bytesSent: UInt64, activeFlows: Int, destinationCount: Int, receiveBytesPerSecond: Double?, sendBytesPerSecond: Double?, hasByteCounters: Bool) {
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.activeFlows = activeFlows
        self.destinationCount = destinationCount
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.sendBytesPerSecond = sendBytesPerSecond
        self.hasByteCounters = hasByteCounters
    }

    public init(destinations: [DestinationTotals]) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var flows = 0
        var down: Double?
        var up: Double?
        var counters = true
        for destination in destinations {
            received &+= destination.bytesReceived
            sent &+= destination.bytesSent
            flows += destination.activeFlowCount
            if let rate = destination.receiveBytesPerSecond { down = (down ?? 0) + rate }
            if let rate = destination.sendBytesPerSecond { up = (up ?? 0) + rate }
            if !destination.hasByteCounters { counters = false }
        }
        self.init(bytesReceived: received, bytesSent: sent, activeFlows: flows, destinationCount: destinations.count,
                  receiveBytesPerSecond: down, sendBytesPerSecond: up, hasByteCounters: counters)
    }

    public var totalBytes: UInt64 { bytesReceived &+ bytesSent }
}

/// Layer 4 and process breakdowns summed over several destinations (the inspector of a group).
public enum TrafficAggregation {
    private struct PortKey: Hashable {
        var transport: FlowTransport
        var port: UInt16
    }

    /// Per (transport, port), largest first.
    public static func ports(of destinations: [DestinationTotals]) -> [PortTotals] {
        var merged: [PortKey: PortTotals] = [:]
        for destination in destinations {
            for entry in destination.ports {
                let key = PortKey(transport: entry.transport, port: entry.port)
                var total = merged[key] ?? PortTotals(transport: entry.transport, port: entry.port)
                total.bytesReceived &+= entry.bytesReceived
                total.bytesSent &+= entry.bytesSent
                total.flowCount += entry.flowCount
                merged[key] = total
            }
        }
        return merged.values.sorted { lhs, rhs in
            let a = lhs.bytesReceived &+ lhs.bytesSent
            let b = rhs.bytesReceived &+ rhs.bytesSent
            if a != b { return a > b }
            if lhs.flowCount != rhs.flowCount { return lhs.flowCount > rhs.flowCount }
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.transport.protocolNumber < rhs.transport.protocolNumber
        }
    }

    /// Per process name, largest first.
    public static func processes(of destinations: [DestinationTotals]) -> [ProcessTotals] {
        var merged: [String: ProcessTotals] = [:]
        for destination in destinations {
            for entry in destination.processes {
                var total = merged[entry.processName] ?? ProcessTotals(processName: entry.processName)
                total.bytesReceived &+= entry.bytesReceived
                total.bytesSent &+= entry.bytesSent
                merged[entry.processName] = total
            }
        }
        return merged.values.sorted { lhs, rhs in
            let a = lhs.bytesReceived &+ lhs.bytesSent
            let b = rhs.bytesReceived &+ rhs.bytesSent
            if a != b { return a > b }
            return lhs.processName < rhs.processName
        }
    }
}
