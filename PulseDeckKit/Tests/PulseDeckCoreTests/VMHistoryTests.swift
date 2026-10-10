import Foundation
import Testing
@testable import PulseDeckCore

@Suite struct VMHistoryTests {
    private func time(_ second: UInt64) -> SampleTimestamp {
        SampleTimestamp(monotonic: MonotonicInstant(nanoseconds: second * 1_000_000_000), wallClock: Date(timeIntervalSince1970: Double(second)))
    }

    private func machine(_ name: String, state: VMState = .running, cpu: MetricState<Double> = .available(0.5),
                         memory: MetricState<UInt64> = .available(1_000), read: MetricState<Double> = .available(10),
                         write: MetricState<Double> = .available(20)) -> VirtualMachineSnapshot {
        VirtualMachineSnapshot(
            id: "colima:\(name)", providerID: "colima", providerName: "Colima", name: name, state: state,
            usage: VMUsage(cpu: cpu, memoryBytes: memory, diskReadBytesPerSecond: read, diskWriteBytesPerSecond: write, processCount: 1)
        )
    }

    private func snapshot(_ machines: [VirtualMachineSnapshot]) -> VirtualMachinesSnapshot {
        VirtualMachinesSnapshot(providers: [], machines: machines)
    }

    @Test func recordsPerMachineSeries() {
        var history = VMHistory()
        history.ingest(snapshot([machine("a"), machine("b", cpu: .available(1.5))]), at: time(1))
        #expect(history.history(for: "colima:a")?.latest?.values == [0.5, 1_000.0, 10.0, 20.0])
        #expect(history.history(for: "colima:b")?.latest?.values[VMHistory.Series.cpu] == 1.5)
        #expect(history.history(for: "colima:missing") == nil)
    }

    @Test func unavailableValuesAreGapsNotZero() {
        var history = VMHistory()
        let unreadable = machine("a", cpu: .unavailable(.awaitingBaseline), memory: .unavailable(.permissionDenied),
                                 read: .unavailable(.notApplicable), write: .available(5))
        history.ingest(snapshot([unreadable]), at: time(1))
        #expect(history.history(for: "colima:a")?.latest?.values == [nil, nil, nil, 5.0])
        #expect(history.aggregate.latest?.values == [nil, nil])
    }

    @Test func stoppedMachineIsAGap() {
        var history = VMHistory()
        history.ingest(snapshot([machine("a", state: .stopped)]), at: time(1))
        #expect(history.history(for: "colima:a")?.latest?.values == [nil, nil, nil, nil])
    }

    @Test func aggregateSumsActiveMachines() {
        var history = VMHistory()
        history.ingest(snapshot([
            machine("a", cpu: .available(0.25), memory: .available(100)),
            machine("b", cpu: .available(0.5), memory: .available(300)),
            machine("c", state: .stopped, cpu: .available(9), memory: .available(9_999)),
            machine("d", cpu: .unavailable(.awaitingBaseline), memory: .available(50)),
        ]), at: time(1))
        #expect(history.aggregate.latest?.values == [0.75, 450.0])
    }

    @Test func totalsAreNilWhenNothingIsReadable() {
        #expect(VMHistory.totals(of: []) == VMHistory.Totals(cpu: nil, memoryBytes: nil))
        let stopped = machine("a", state: .stopped)
        let unreadable = machine("b", cpu: .unavailable(.awaitingBaseline), memory: .unavailable(.awaitingBaseline))
        #expect(VMHistory.totals(of: [stopped, unreadable]) == VMHistory.Totals(cpu: nil, memoryBytes: nil))
        let readable = machine("c", cpu: .available(1), memory: .available(2_048))
        #expect(VMHistory.totals(of: [stopped, unreadable, readable]) == VMHistory.Totals(cpu: 1, memoryBytes: 2_048))
    }

    @Test func noMachinesAppendsAGap() {
        var history = VMHistory()
        history.ingest(snapshot([]), at: time(1))
        #expect(history.aggregate.samples.count == 1)
        #expect(history.aggregate.latest?.values == [nil, nil])
        #expect(history.machines.isEmpty)
    }

    @Test func staysBounded() {
        var history = VMHistory()
        for second in 1...1_000 as ClosedRange<UInt64> {
            history.ingest(snapshot([machine("a")]), at: time(second))
        }
        #expect(history.history(for: "colima:a")?.samples.count == SystemHistory.capacity)
        #expect(history.aggregate.samples.count == SystemHistory.capacity)
    }

    @Test func vanishedMachinesArePrunedAfterWindow() {
        var history = VMHistory()
        history.ingest(snapshot([machine("a"), machine("b")]), at: time(1))
        history.ingest(snapshot([machine("a")]), at: time(30))
        #expect(history.machines.keys.sorted() == ["colima:a", "colima:b"])
        history.ingest(snapshot([machine("a")]), at: time(62))
        #expect(history.machines.keys.sorted() == ["colima:a"])
    }
}
