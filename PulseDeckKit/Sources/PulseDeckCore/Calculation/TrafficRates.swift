import Foundation

public enum TrafficDirection: Sendable {
    case received
    case sent
}

/// Current transfer rates summed per placement class. A class without any known rate is `nil`
/// (a gap in the chart), never zero.
public struct TrafficRateSums: Hashable, Sendable {
    /// Indexed by `TrafficScopeClass.rawValue`.
    public var received: [Double?]
    public var sent: [Double?]

    public static let none = TrafficRateSums(received: [Double?](repeating: nil, count: TrafficScopeClass.allCases.count),
                                             sent: [Double?](repeating: nil, count: TrafficScopeClass.allCases.count))

    public init(received: [Double?], sent: [Double?]) {
        self.received = received
        self.sent = sent
    }

    /// `classes` gives the placement of each destination, index for index.
    public init(destinations: [DestinationTotals], classes: [TrafficScopeClass]) {
        precondition(destinations.count == classes.count, "classes must match destinations")
        var received = [Double?](repeating: nil, count: TrafficScopeClass.allCases.count)
        var sent = [Double?](repeating: nil, count: TrafficScopeClass.allCases.count)
        for index in destinations.indices {
            let slot = classes[index].rawValue
            if let rate = destinations[index].receiveBytesPerSecond { received[slot] = (received[slot] ?? 0) + rate }
            if let rate = destinations[index].sendBytesPerSecond { sent[slot] = (sent[slot] ?? 0) + rate }
        }
        self.init(received: received, sent: sent)
    }
}

/// The rolling 60-second history of the live rate chart. It is a regular `MetricHistory` so the
/// app's `TimeSeriesChart` (hover, Audio Graphs) can draw it. Series 0…2 hold the received rate
/// per `TrafficScopeClass`, series 3…5 the sent rate; the chart sums the classes the scope
/// toggles let through, so toggling a filter also changes the past of the chart.
public struct TrafficRateHistory: Sendable {
    public private(set) var history = MetricHistory(seriesCount: TrafficScopeClass.allCases.count * 2)

    public init() {}

    /// Appends one point. A timestamp that is not newer than the last one is ignored (a rebuild
    /// triggered by a control change sees the same snapshot again).
    public mutating func append(_ sums: TrafficRateSums, at timestamp: SampleTimestamp) {
        if let latest = history.latest, timestamp.monotonic <= latest.timestamp { return }
        history.append(timestamp, values: sums.received + sums.sent)
    }

    public mutating func removeAll() {
        self = TrafficRateHistory()
    }

    /// The rate of `direction` in `sample`, summed over `classes`; `nil` when none of them has a value.
    public static func value(in sample: HistorySample, direction: TrafficDirection, including classes: Set<TrafficScopeClass>) -> Double? {
        let offset = direction == .received ? 0 : TrafficScopeClass.allCases.count
        var sum: Double?
        for scopeClass in classes {
            if let value = sample.values[offset + scopeClass.rawValue] {
                sum = (sum ?? 0) + value
            }
        }
        return sum
    }
}
