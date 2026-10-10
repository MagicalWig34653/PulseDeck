import Foundation
import Testing
@testable import PulseDeckCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func destination(_ address: String, received: UInt64 = 0, sent: UInt64 = 0, active: Int = 0, flows: Int = 1,
                         down: Double? = nil, up: Double? = nil, ports: [PortTotals] = [], processes: [ProcessTotals] = [],
                         lastSeen: Date = epoch) -> DestinationTotals {
    DestinationTotals(address: address, family: address.contains(":") ? .v6 : .v4, bytesReceived: received, bytesSent: sent,
                      flowCount: flows, activeFlowCount: active, firstSeen: epoch, lastSeen: lastSeen,
                      receiveBytesPerSecond: down, sendBytesPerSecond: up, ports: ports, processes: processes)
}

/// Classifies by address prefix and counts how often it is asked.
private final class CountingClassifier: DestinationClassifying, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }

    func info(forAddress address: String, port: UInt16, transport: FlowTransport) -> DestinationInfo {
        lock.withLock { calls += 1 }
        if address.hasPrefix("127.") || address == "::1" { return DestinationInfo(scope: .loopback) }
        if address.hasPrefix("192.168.") { return DestinationInfo(scope: .localNetwork) }
        if address.hasPrefix("224.") { return DestinationInfo(scope: .multicast) }
        if address.hasPrefix("1.1.1.") { return DestinationInfo(scope: .internet, countryCode: "US", provider: "Cloudflare", service: port == 443 ? "HTTPS" : nil) }
        return DestinationInfo(scope: .internet, countryCode: "DE", provider: "Hetzner", service: nil)
    }
}

@Suite("Traffic treemap")
struct TrafficTreemapTests {
    private let bounds = TreemapRect(x: 10, y: 20, width: 400, height: 250)

    @Test func tilesFillTheBoundsWithProportionalAreas() {
        let weights = [60.0, 25, 10, 5, 3, 2, 1]
        let rects = TrafficTreemap.layout(weights: weights, in: bounds)
        let total = weights.reduce(0, +)
        #expect(abs(rects.reduce(0) { $0 + $1.area } - bounds.area) < 1e-6)
        for (weight, rect) in zip(weights, rects) {
            #expect(abs(rect.area - bounds.area * weight / total) < 1e-6)
        }
    }

    @Test func tilesStayInsideTheBoundsAndDoNotOverlap() {
        let rects = TrafficTreemap.layout(weights: [40, 30, 12, 9, 5, 3, 1], in: bounds)
        for rect in rects {
            #expect(rect.x >= bounds.x - 1e-9 && rect.y >= bounds.y - 1e-9)
            #expect(rect.maxX <= bounds.maxX + 1e-9 && rect.maxY <= bounds.maxY + 1e-9)
        }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlapWidth = min(a.maxX, b.maxX) - max(a.x, b.x)
                let overlapHeight = min(a.maxY, b.maxY) - max(a.y, b.y)
                #expect(overlapWidth <= 1e-6 || overlapHeight <= 1e-6)
            }
        }
    }

    @Test func resultFollowsInputOrderAndSquarifies() {
        // Unsorted input: the rectangle at index 2 belongs to the biggest weight.
        let rects = TrafficTreemap.layout(weights: [1, 2, 10, 2], in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        #expect(rects[2].area > rects[1].area)
        #expect(rects[2].area > rects[0].area)
        // Equal weights in a square give square-ish tiles.
        let equal = TrafficTreemap.layout(weights: [1, 1, 1, 1], in: TreemapRect(x: 0, y: 0, width: 100, height: 100))
        for rect in equal {
            #expect(abs(rect.width - 50) < 1e-9 && abs(rect.height - 50) < 1e-9)
        }
    }

    @Test func aspectRatiosStayReasonable() {
        let rects = TrafficTreemap.layout(weights: [30, 20, 15, 10, 8, 6, 5, 3, 2, 1], in: TreemapRect(x: 0, y: 0, width: 600, height: 300))
        for rect in rects {
            let ratio = max(rect.width / rect.height, rect.height / rect.width)
            #expect(ratio < 6)
        }
    }

    @Test func emptyDegenerateAndNonPositiveInput() {
        #expect(TrafficTreemap.layout(weights: [], in: bounds).isEmpty)
        #expect(TrafficTreemap.layout(weights: [5], in: TreemapRect(x: 0, y: 0, width: 0, height: 10)) == [.zero])
        let rects = TrafficTreemap.layout(weights: [0, 5, -1, .nan], in: bounds)
        #expect(rects[1].area > 0)
        #expect(rects[0] == .zero && rects[2] == .zero && rects[3] == .zero)
        #expect(abs(rects[1].area - bounds.area) < 1e-6)
    }

    @Test func entriesMergeTheTailIntoOther() {
        let ids = (0..<30).map { "g\($0)" }
        let weights = (0..<30).map { Double(1000 - $0 * 10) }
        let entries = TrafficTreemap.entries(ids: ids, weights: weights, maximumTiles: 10, minimumShare: 0)
        #expect(entries.count == 10)
        #expect(entries.last?.isOther == true)
        #expect(entries.last?.memberCount == 21)
        #expect(abs(entries.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(entries.first?.id == "g0")
    }

    @Test func entriesRespectTheMinimumShareAndDropEmptyGroups() {
        let entries = TrafficTreemap.entries(ids: ["a", "b", "c", "d", "e"], weights: [900, 80, 10, 5, 0], maximumTiles: 24, minimumShare: 0.02)
        #expect(entries.map(\.id) == ["a", "b", TrafficTreemap.otherID])
        #expect(entries.last?.memberCount == 2)
        #expect(TrafficTreemap.entries(ids: ["a"], weights: [0], maximumTiles: 5, minimumShare: 0).isEmpty)
    }

    @Test func aLoneLeftoverKeepsItsName() {
        let entries = TrafficTreemap.entries(ids: ["a", "b", "c"], weights: [90, 9, 1], maximumTiles: 24, minimumShare: 0.05)
        #expect(entries.map(\.id) == ["a", "b", "c"])
        let atCapacity = TrafficTreemap.entries(ids: ["a", "b", "c"], weights: [90, 9, 1], maximumTiles: 3, minimumShare: 0)
        #expect(atCapacity.map(\.id) == ["a", "b", "c"])
    }
}

@Suite("Traffic filtering")
struct TrafficFilteringTests {
    @Test func scopeClasses() {
        #expect(DestinationScope.loopback.trafficClass == .thisMac)
        #expect(DestinationScope.unspecified.trafficClass == .thisMac)
        #expect(DestinationScope.localNetwork.trafficClass == .localNetwork)
        #expect(DestinationScope.multicast.trafficClass == .localNetwork)
        #expect(DestinationScope.internet.trafficClass == .external)
        #expect(DestinationScope.tailscale.trafficClass == .external)
    }

    @Test func defaultFilterHidesOnlyThisMac() {
        let filter = TrafficFilter()
        #expect(!filter.includes(.thisMac))
        #expect(filter.includes(.localNetwork))
        #expect(filter.includes(.external))
        #expect(!TrafficFilter(hidesLocalNetwork: true).includes(.localNetwork))
    }

    @Test func partitionAppliesScopeActivityAndSearch() {
        let classifier = CountingClassifier()
        let destinations = [
            destination("127.0.0.1", received: 5, active: 1),
            destination("192.168.1.1", received: 10, active: 0),
            destination("1.1.1.1", received: 100, active: 2, ports: [PortTotals(transport: .tcp, port: 443)], processes: [ProcessTotals(processName: "Safari")]),
            destination("5.9.0.1", received: 50, active: 0),
        ]
        var cache = TrafficInfoCache()
        let infos = cache.infos(for: destinations, classifier: classifier)

        let all = TrafficFilter().partition(destinations, infos: infos)
        #expect(all.inScope.map(\.address) == ["192.168.1.1", "1.1.1.1", "5.9.0.1"])
        #expect(all.visible.count == 3)

        let hidingLAN = TrafficFilter(hidesLocalNetwork: true, hidesThisMac: false).partition(destinations, infos: infos)
        #expect(hidingLAN.inScope.map(\.address) == ["127.0.0.1", "1.1.1.1", "5.9.0.1"])

        let active = TrafficFilter(onlyActive: true).partition(destinations, infos: infos)
        #expect(active.inScope.count == 3)
        #expect(active.visible.map(\.address) == ["1.1.1.1"])

        #expect(TrafficFilter(searchText: "safari").partition(destinations, infos: infos).visible.map(\.address) == ["1.1.1.1"])
        #expect(TrafficFilter(searchText: "hetzner").partition(destinations, infos: infos).visible.map(\.address) == ["5.9.0.1"])
        #expect(TrafficFilter(searchText: "cloudflare https").partition(destinations, infos: infos).visible.map(\.address) == ["1.1.1.1"])
        #expect(TrafficFilter(searchText: "cloudflare hetzner").partition(destinations, infos: infos).visible.isEmpty)
        #expect(TrafficFilter(searchText: "443").partition(destinations, infos: infos).visible.map(\.address) == ["1.1.1.1"])
        // Search never changes what counts for the totals.
        #expect(TrafficFilter(searchText: "hetzner").partition(destinations, infos: infos).inScope.count == 3)
    }

    @Test func searchFindsHostNames() {
        let target = destination("5.9.0.1")
        let info = DestinationInfo(scope: .internet)
        let filter = TrafficFilter(searchText: "Example")
        #expect(filter.matchesSearch(target, info: info, hostName: "www.example.org"))
        #expect(!filter.matchesSearch(target, info: info, hostName: nil))
        #expect(TrafficFilter().matchesSearch(target, info: info, hostName: nil))
    }

    @Test func infoCacheReusesEntriesUntilThePortChanges() {
        let classifier = CountingClassifier()
        var cache = TrafficInfoCache()
        let web = destination("1.1.1.1", ports: [PortTotals(transport: .tcp, port: 443)])
        _ = cache.infos(for: [web], classifier: classifier)
        _ = cache.infos(for: [web], classifier: classifier)
        #expect(classifier.callCount == 1)
        let other = destination("1.1.1.1", ports: [PortTotals(transport: .udp, port: 53)])
        let infos = cache.infos(for: [other], classifier: classifier)
        #expect(classifier.callCount == 2)
        #expect(infos.first?.service == nil)
        // Destinations that disappear leave the cache.
        _ = cache.infos(for: [], classifier: classifier)
        #expect(cache.count == 0)
    }

    @Test func hostNameCandidatesAreTheBusiestResolvableAddresses() {
        let classifier = CountingClassifier()
        let destinations = [
            destination("127.0.0.1", received: 9_999),
            destination("224.0.0.251", received: 8_000),
            destination("1.1.1.1", received: 100),
            destination("5.9.0.1", received: 500),
            destination("192.168.1.1", received: 300),
        ]
        var cache = TrafficInfoCache()
        let infos = cache.infos(for: destinations, classifier: classifier)
        #expect(TrafficHostNameSelection.candidates(destinations: destinations, infos: infos, limit: 2) == ["5.9.0.1", "192.168.1.1"])
        #expect(TrafficHostNameSelection.candidates(destinations: destinations, infos: infos, limit: 0).isEmpty)
    }
}

@Suite("Traffic sorting and totals")
struct TrafficSortingTests {
    private struct Row: TrafficSortable, Equatable {
        var name: String
        var received: Double
        var rate: Double

        var sortName: String { name }
        func sortValue(for key: TrafficSortKey) -> Double {
            switch key {
            case .received, .total: received
            case .receiveRate: rate
            default: 0
            }
        }
    }

    private let rows = [
        Row(name: "b", received: 10, rate: -1),
        Row(name: "a", received: 30, rate: 5),
        Row(name: "c", received: 30, rate: 7),
        Row(name: "file 10", received: 1, rate: 0),
        Row(name: "file 2", received: 1, rate: 0),
    ]

    @Test func sortsByNumbersWithNameTieBreak() {
        let descending = TrafficSorting.sorted(rows, by: TrafficSortOrder(key: .received, ascending: false))
        #expect(descending.map(\.name) == ["a", "c", "b", "file 2", "file 10"])
        let ascending = TrafficSorting.sorted(rows, by: TrafficSortOrder(key: .received, ascending: true))
        #expect(ascending.map(\.name) == ["file 2", "file 10", "b", "a", "c"])
    }

    @Test func missingValuesSortBelowRealOnes() {
        let sorted = TrafficSorting.sorted(rows, by: TrafficSortOrder(key: .receiveRate, ascending: false))
        #expect(sorted.map(\.name) == ["c", "a", "file 2", "file 10", "b"])
    }

    @Test func sortsNamesNaturally() {
        let sorted = TrafficSorting.sorted(rows, by: TrafficSortOrder(key: .name, ascending: true))
        #expect(sorted.map(\.name) == ["a", "b", "c", "file 2", "file 10"])
        let reversed = TrafficSorting.sorted(rows, by: TrafficSortOrder(key: .name, ascending: false))
        #expect(reversed.map(\.name) == ["file 10", "file 2", "c", "b", "a"])
    }

    @Test func totalsSumTheDestinations() {
        let totals = TrafficTotals(destinations: [
            destination("1.1.1.1", received: 100, sent: 10, active: 2, down: 5, up: nil),
            destination("5.9.0.1", received: 50, sent: 20, active: 1, down: 7, up: 3),
        ])
        #expect(totals.bytesReceived == 150 && totals.bytesSent == 30 && totals.totalBytes == 180)
        #expect(totals.activeFlows == 3 && totals.destinationCount == 2)
        #expect(totals.receiveBytesPerSecond == 12)
        #expect(totals.sendBytesPerSecond == 3)
        #expect(totals.hasByteCounters)
        let none = TrafficTotals(destinations: [destination("1.1.1.1")])
        #expect(none.receiveBytesPerSecond == nil && none.sendBytesPerSecond == nil)
        var noCounters = destination("1.1.1.1")
        noCounters.hasByteCounters = false
        #expect(!TrafficTotals(destinations: [noCounters]).hasByteCounters)
    }

    @Test func aggregationMergesPortsAndProcesses() {
        let first = destination("1.1.1.1", ports: [
            PortTotals(transport: .tcp, port: 443, bytesReceived: 100, bytesSent: 10, flowCount: 2),
            PortTotals(transport: .udp, port: 443, bytesReceived: 5, bytesSent: 5, flowCount: 1),
        ], processes: [ProcessTotals(processName: "Safari", bytesReceived: 100, bytesSent: 10)])
        let second = destination("1.0.0.1", ports: [
            PortTotals(transport: .tcp, port: 443, bytesReceived: 50, bytesSent: 1, flowCount: 1),
            PortTotals(transport: .tcp, port: 80, bytesReceived: 1, bytesSent: 1, flowCount: 1),
        ], processes: [
            ProcessTotals(processName: "Safari", bytesReceived: 50, bytesSent: 1),
            ProcessTotals(processName: "curl", bytesReceived: 1, bytesSent: 1),
        ])
        let ports = TrafficAggregation.ports(of: [first, second])
        #expect(ports.count == 3)
        #expect(ports[0].transport == .tcp && ports[0].port == 443)
        #expect(ports[0].bytesReceived == 150 && ports[0].bytesSent == 11 && ports[0].flowCount == 3)
        #expect(ports[1].transport == .udp)
        let processes = TrafficAggregation.processes(of: [first, second])
        #expect(processes.map(\.processName) == ["Safari", "curl"])
        #expect(processes[0].bytesReceived == 150)
    }
}

@Suite("Traffic rates")
struct TrafficRatesTests {
    private func timestamp(_ seconds: UInt64) -> SampleTimestamp {
        SampleTimestamp(monotonic: MonotonicInstant(nanoseconds: seconds * 1_000_000_000), wallClock: epoch.addingTimeInterval(Double(seconds)))
    }

    @Test func sumsPerClassAndKeepsMissingAsNil() {
        let sums = TrafficRateSums(
            destinations: [destination("1.1.1.1", down: 10, up: 1), destination("5.9.0.1", down: 5, up: nil), destination("127.0.0.1", down: nil, up: nil)],
            classes: [.external, .external, .thisMac]
        )
        #expect(sums.received[TrafficScopeClass.external.rawValue] == 15)
        #expect(sums.sent[TrafficScopeClass.external.rawValue] == 1)
        #expect(sums.received[TrafficScopeClass.thisMac.rawValue] == nil)
        #expect(sums.received[TrafficScopeClass.localNetwork.rawValue] == nil)
    }

    @Test func historyChartsTheSelectedClasses() throws {
        var history = TrafficRateHistory()
        let sums = TrafficRateSums(
            destinations: [destination("1.1.1.1", down: 10, up: 2), destination("127.0.0.1", down: 1000, up: 500)],
            classes: [.external, .thisMac]
        )
        history.append(sums, at: timestamp(1))
        let sample = try #require(history.history.latest)
        #expect(TrafficRateHistory.value(in: sample, direction: .received, including: [.external]) == 10)
        #expect(TrafficRateHistory.value(in: sample, direction: .received, including: [.external, .thisMac]) == 1010)
        #expect(TrafficRateHistory.value(in: sample, direction: .sent, including: [.external, .thisMac]) == 502)
        #expect(TrafficRateHistory.value(in: sample, direction: .received, including: [.localNetwork]) == nil)
        #expect(TrafficRateHistory.value(in: sample, direction: .sent, including: []) == nil)
    }

    @Test func historyIgnoresRepeatedTimestampsAndStaysBounded() {
        var history = TrafficRateHistory()
        history.append(.none, at: timestamp(5))
        history.append(.none, at: timestamp(5))
        history.append(.none, at: timestamp(4))
        #expect(history.history.samples.count == 1)
        for second in 6..<(6 + UInt64(SystemHistory.capacity) + 20) {
            history.append(.none, at: timestamp(second))
        }
        #expect(history.history.samples.count == SystemHistory.capacity)
        history.removeAll()
        #expect(history.history.latest == nil)
    }
}

@Suite("Traffic labels")
struct TrafficLabelsTests {
    @Test func flagEmoji() {
        #expect(TrafficLabels.flagEmoji(regionCode: "DE") == "🇩🇪")
        #expect(TrafficLabels.flagEmoji(regionCode: "us") == "🇺🇸")
        #expect(TrafficLabels.flagEmoji(regionCode: "D") == nil)
        #expect(TrafficLabels.flagEmoji(regionCode: "DEU") == nil)
        #expect(TrafficLabels.flagEmoji(regionCode: "1A") == nil)
        #expect(TrafficLabels.flagEmoji(regionCode: "") == nil)
    }

    @Test func countryNameOfEmptyCodeIsNil() {
        #expect(TrafficLabels.countryName(regionCode: "") == nil)
    }

    @Test func paletteIndexIsStableAndInRange() {
        for key in ["DE", "Cloudflare", "HTTPS", "unknown", ""] {
            let index = TrafficLabels.paletteIndex(forKey: key, count: 12)
            #expect((0..<12).contains(index))
            #expect(index == TrafficLabels.paletteIndex(forKey: key, count: 12))
        }
        // FNV-1a reference value: the 64-bit hash of "a" is 0xaf63dc4c8601ec8c.
        let reference: UInt64 = 0xaf63_dc4c_8601_ec8c
        #expect(TrafficLabels.paletteIndex(forKey: "a", count: 1_000_000) == Int(reference % 1_000_000))
        #expect(TrafficLabels.paletteIndex(forKey: "x", count: 0) == 0)
    }

    @Test func shareIsClamped() {
        #expect(TrafficLabels.share(25, of: 100) == 0.25)
        #expect(TrafficLabels.share(5, of: 0) == 0)
        #expect(TrafficLabels.share(200, of: 100) == 1)
    }
}
