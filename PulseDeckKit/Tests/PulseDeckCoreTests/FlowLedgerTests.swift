import Foundation
import Testing
@testable import PulseDeckCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
}

private func flow(_ id: UInt64, to address: String = "93.184.216.34", port: UInt16 = 443, transport: FlowTransport = .tcp, received: UInt64?, sent: UInt64?, process: String? = "Safari", pid: Int32? = 100, startedAt: Date? = nil) -> NetworkFlow {
    NetworkFlow(
        id: id,
        family: address.contains(":") ? .v6 : .v4,
        transport: transport,
        local: FlowEndpoint(address: "192.168.1.2", port: 50_000),
        remote: FlowEndpoint(address: address, port: port),
        processName: process,
        processID: pid,
        bytesReceived: received.map { .available($0) } ?? .unavailable(.noPublicAPI),
        bytesSent: sent.map { .available($0) } ?? .unavailable(.noPublicAPI),
        startedAt: startedAt
    )
}

private func snapshot(_ flows: [NetworkFlow], closed: [NetworkFlow] = [], source: FlowSource = .networkStatistics) -> NetworkFlowsSnapshot {
    NetworkFlowsSnapshot(source: source, flows: flows, closed: closed)
}

@Suite("Flow ledger")
struct FlowLedgerTests {
    @Test func firstSightCreditsFullCountersThenDeltas() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 1000, sent: 100)]), at: at(0))
        #expect(ledger.recordingSince == at(0))
        #expect(ledger.source == .networkStatistics)
        var destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 1000)
        #expect(destination.bytesSent == 100)
        #expect(destination.flowCount == 1)
        #expect(destination.activeFlowCount == 1)
        #expect(destination.hasByteCounters)
        // First sight: no rate.
        #expect(destination.receiveBytesPerSecond == nil)

        ledger.ingest(snapshot([flow(1, received: 1500, sent: 300)]), at: at(2))
        destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 1500)
        #expect(destination.bytesSent == 300)
        #expect(destination.flowCount == 1)
        #expect(destination.receiveBytesPerSecond == 250)
        #expect(destination.sendBytesPerSecond == 100)
        #expect(destination.firstSeen == at(0))
        #expect(destination.lastSeen == at(2))
        #expect(ledger.totalBytesReceived == 1500)
        #expect(ledger.totalBytesSent == 300)
        #expect(ledger.recordingSince == at(0))
    }

    @Test func closedFlowsCreditFinalDeltaOnce() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 100, sent: 10)]), at: at(0))
        ledger.ingest(snapshot([], closed: [flow(1, received: 400, sent: 40)]), at: at(1))
        var destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 400)
        #expect(destination.bytesSent == 40)
        #expect(destination.activeFlowCount == 0)
        #expect(destination.flowCount == 1)
        #expect(destination.receiveBytesPerSecond == 300)

        // A late duplicate of the closed flow credits nothing.
        ledger.ingest(snapshot([], closed: [flow(1, received: 400, sent: 40)]), at: at(2))
        destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 400)
        #expect(destination.receiveBytesPerSecond == 0)
    }

    @Test func flowThatOpenedAndClosedBetweenSamplesIsCredited() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([]), at: at(0))
        ledger.ingest(snapshot([], closed: [flow(9, to: "1.1.1.1", port: 53, transport: .udp, received: 120, sent: 60, startedAt: at(0.5))]), at: at(1))
        let destination = try #require(ledger.destinations.first)
        #expect(destination.address == "1.1.1.1")
        #expect(destination.bytesReceived == 120)
        #expect(destination.ports == [PortTotals(transport: .udp, port: 53, bytesReceived: 120, bytesSent: 60, flowCount: 1)])
        #expect(destination.activeFlowCount == 0)
    }

    @Test func backwardsCountersResetBaselineWithoutNegativeCredit() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 1000, sent: 1000)]), at: at(0))
        ledger.ingest(snapshot([flow(1, received: 200, sent: 1500)]), at: at(1))
        var destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 1000)
        #expect(destination.bytesSent == 1500)
        // The new baseline is 200.
        ledger.ingest(snapshot([flow(1, received: 300, sent: 1500)]), at: at(2))
        destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 1100)
    }

    @Test func reusedIDWithAnotherEndpointIsANewFlow() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, to: "10.0.0.1", received: 1000, sent: 0)]), at: at(0))
        ledger.ingest(snapshot([flow(1, to: "10.0.0.2", received: 1200, sent: 0)]), at: at(1))
        #expect(ledger.destinations.map(\.address) == ["10.0.0.2", "10.0.0.1"])
        #expect(ledger.destinations.map(\.bytesReceived) == [1200, 1000])
        #expect(ledger.destinations.first?.flowCount == 1)
    }

    @Test func resetForgetsTotalsButNotBaselines() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 1000, sent: 0)]), at: at(0))
        ledger.reset()
        #expect(ledger.destinations.isEmpty)
        #expect(ledger.totalBytesReceived == 0)
        #expect(ledger.recordingSince == nil)
        #expect(ledger.source == nil)

        ledger.ingest(snapshot([flow(1, received: 1300, sent: 0), flow(2, to: "8.8.8.8", received: 50, sent: 0)]), at: at(5))
        #expect(ledger.recordingSince == at(5))
        // The still-open flow is credited only with what came after the reset; a flow never
        // seen before is credited fully.
        let byAddress = Dictionary(uniqueKeysWithValues: ledger.destinations.map { ($0.address, $0.bytesReceived) })
        #expect(byAddress == ["93.184.216.34": 300, "8.8.8.8": 50])
        #expect(ledger.totalBytesReceived == 350)
    }

    @Test func socketTableFlowsAreCountedWithoutBytes() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: nil, sent: nil)], source: .socketTable), at: at(0))
        ledger.ingest(snapshot([flow(1, received: nil, sent: nil), flow(2, port: 80, received: nil, sent: nil)], source: .socketTable), at: at(1))
        let destination = try #require(ledger.destinations.first)
        #expect(!destination.hasByteCounters)
        #expect(destination.bytesReceived == 0)
        #expect(destination.flowCount == 2)
        #expect(destination.activeFlowCount == 2)
        #expect(destination.receiveBytesPerSecond == nil)
        #expect(destination.ports.count == 2)
        #expect(ledger.source == .socketTable)
    }

    @Test func aggregatesPortsAndProcesses() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([
            flow(1, port: 443, received: 100, sent: 0, process: "Safari"),
            flow(2, port: 443, received: 300, sent: 0, process: "curl", pid: 200),
            flow(3, port: 80, received: 50, sent: 0, process: nil, pid: 300),
            flow(4, port: 443, transport: .udp, received: 1000, sent: 0, process: nil, pid: nil),
        ]), at: at(0))
        let destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 1450)
        #expect(destination.flowCount == 4)
        #expect(destination.ports == [
            PortTotals(transport: .udp, port: 443, bytesReceived: 1000, flowCount: 1),
            PortTotals(transport: .tcp, port: 443, bytesReceived: 400, flowCount: 2),
            PortTotals(transport: .tcp, port: 80, bytesReceived: 50, flowCount: 1),
        ])
        // The unattributed flow is only in the destination totals.
        #expect(destination.processes == [
            ProcessTotals(processName: "curl", bytesReceived: 300),
            ProcessTotals(processName: "Safari", bytesReceived: 100),
            ProcessTotals(processName: "PID 300", bytesReceived: 50),
        ])
    }

    @Test func capsPortsAndProcessesKeepingDestinationTotals() throws {
        var ledger = FlowLedger(maximumDestinations: 10, maximumPorts: 2, maximumProcesses: 2)
        ledger.ingest(snapshot([
            flow(1, port: 1, received: 10, sent: 0, process: "a"),
            flow(2, port: 2, received: 30, sent: 0, process: "b"),
            flow(3, port: 3, received: 20, sent: 0, process: "c"),
        ]), at: at(0))
        let destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 60)
        #expect(destination.ports.map(\.port) == [2, 3])
        #expect(destination.processes.map(\.processName) == ["b", "c"])
    }

    @Test func capsDestinationsEvictingStaleSmallOnes() {
        var ledger = FlowLedger(maximumDestinations: 2)
        ledger.ingest(snapshot([flow(1, to: "10.0.0.1", received: 500, sent: 0)]), at: at(0))
        ledger.ingest(snapshot([flow(2, to: "10.0.0.2", received: 100, sent: 0)], closed: [flow(1, to: "10.0.0.1", received: 500, sent: 0)]), at: at(1))
        ledger.ingest(snapshot([flow(3, to: "10.0.0.3", received: 50, sent: 0)], closed: [flow(2, to: "10.0.0.2", received: 100, sent: 0)]), at: at(2))
        // 10.0.0.1 was seen least recently.
        #expect(ledger.destinations.map(\.address) == ["10.0.0.2", "10.0.0.3"])
        // Ledger totals keep the evicted bytes.
        #expect(ledger.totalBytesReceived == 650)
    }

    @Test func ordersByTotalThenAddress() {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([
            flow(1, to: "10.0.0.9", received: 10, sent: 0),
            flow(2, to: "10.0.0.1", received: 10, sent: 0),
            flow(3, to: "2001:db8::1", received: 5, sent: 50),
        ]), at: at(0))
        #expect(ledger.destinations.map(\.address) == ["2001:db8::1", "10.0.0.1", "10.0.0.9"])
        #expect(ledger.destinations.first?.family == .v6)
    }

    @Test func ratesIncludeNewFlowsStartedWithinTheInterval() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 1000, sent: 0)]), at: at(0))
        ledger.ingest(snapshot([
            flow(1, received: 1000, sent: 0),
            // Started during the interval: its bytes are current traffic.
            flow(2, received: 400, sent: 0, startedAt: at(0.5)),
            // Long-lived flow seen for the first time: history, not rate.
            flow(3, received: 9000, sent: 0, startedAt: at(-3600)),
        ]), at: at(2))
        let destination = try #require(ledger.destinations.first)
        #expect(destination.bytesReceived == 10_400)
        #expect(destination.receiveBytesPerSecond == 200)
        #expect(destination.activeFlowCount == 3)
    }

    @Test func noRateAcrossLongGapsOrForIdleDestinationsWithoutCounters() throws {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([flow(1, received: 0, sent: 0)]), at: at(0))
        ledger.ingest(snapshot([flow(1, received: 100, sent: 0)]), at: at(600))
        #expect(ledger.destinations.first?.receiveBytesPerSecond == nil)
        ledger.ingest(snapshot([]), at: at(601))
        // Measured, nothing transferred: 0, not unknown.
        #expect(ledger.destinations.first?.receiveBytesPerSecond == 0)
        #expect(ledger.destinations.first?.activeFlowCount == 0)
    }

    @Test func recordsLoopbackAndUnspecifiedDestinations() {
        var ledger = FlowLedger()
        ledger.ingest(snapshot([
            flow(1, to: "127.0.0.1", port: 8080, received: 5, sent: 5),
            flow(2, to: "0.0.0.0", port: 0, transport: .udp, received: 1, sent: 1),
        ]), at: at(0))
        #expect(Set(ledger.destinations.map(\.address)) == ["127.0.0.1", "0.0.0.0"])
    }
}
