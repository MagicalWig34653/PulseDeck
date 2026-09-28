import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Mach timebase")
struct MachTimebaseTests {
    @Test func appleSiliconTimebase() {
        // 125/3: 24 ticks = 1000 ns.
        let timebase = MachTimebase(numerator: 125, denominator: 3)
        #expect(timebase.nanoseconds(fromTicks: 24) == 1_000)
        #expect(timebase.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
    }

    @Test func identityTimebase() {
        #expect(MachTimebase(numerator: 1, denominator: 1).nanoseconds(fromTicks: 12_345) == 12_345)
    }

    @Test func noIntermediateOverflow() {
        // ticks × 125 overflows 64 bits, the quotient does not.
        let ticks = UInt64.max / 100
        let expected = UInt64((Double(ticks) * 125 / 3).rounded(.down))
        let result = MachTimebase(numerator: 125, denominator: 3).nanoseconds(fromTicks: ticks)
        #expect(result.map { abs(Double($0) - Double(expected)) / Double(expected) < 1e-12 } == true)
    }

    @Test func saturatesAndRejectsInvalidTimebase() {
        #expect(MachTimebase(numerator: 125, denominator: 3).nanoseconds(fromTicks: .max) == .max)
        #expect(MachTimebase(numerator: 1, denominator: 0).nanoseconds(fromTicks: 1) == nil)
    }
}

@Suite("Process usage")
struct ProcessUsageTrackerTests {
    private let second: UInt64 = 1_000_000_000

    private func instant(_ seconds: UInt64) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: seconds * second)
    }

    private func reading(pid: Int32, start: UInt64 = 1, cpu: UInt64, read: UInt64 = 0, written: UInt64 = 0, footprint: UInt64 = 4_096) -> ProcessReading {
        ProcessReading(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start),
            name: "proc\(pid)", path: nil, userID: 501,
            usage: .success(.init(cpuTimeNanoseconds: cpu, physicalFootprintBytes: footprint, diskBytesRead: read, diskBytesWritten: written)),
            threadCount: .success(3)
        )
    }

    @Test func firstSampleAwaitsBaselineButShowsMemory() throws {
        var tracker = ProcessUsageTracker()
        let snapshot = try #require(tracker.update([reading(pid: 1, cpu: 500)], at: instant(10)).first)
        #expect(snapshot.cpu == .unavailable(.awaitingBaseline))
        #expect(snapshot.memoryBytes == .available(4_096))
        #expect(snapshot.threadCount == .available(3))
        #expect(snapshot.userID == 501)
    }

    @Test func cpuIsFractionOfOneProcessor() throws {
        var tracker = ProcessUsageTracker()
        _ = tracker.update([reading(pid: 1, cpu: 0, read: 0, written: 0)], at: instant(10))
        // 1.5 s CPU over 2 s wall = 0.75 (can exceed 1 for multithreaded work).
        let snapshot = try #require(tracker.update([reading(pid: 1, cpu: 1_500_000_000, read: 4_000, written: 2_000)], at: instant(12)).first)
        #expect(snapshot.cpu == .available(0.75))
        #expect(snapshot.diskReadBytesPerSecond == .available(2_000))
        #expect(snapshot.diskWriteBytesPerSecond == .available(1_000))
    }

    @Test func pidReuseStartsNewBaseline() throws {
        var tracker = ProcessUsageTracker()
        _ = tracker.update([reading(pid: 42, start: 100, cpu: 9_000_000_000)], at: instant(10))
        // Same PID, different start time: a different process. Without the identity check this
        // would be a (negative → invalid, or bogus) delta against the old process.
        let snapshot = try #require(tracker.update([reading(pid: 42, start: 200, cpu: 10_000_000_000)], at: instant(11)).first)
        #expect(snapshot.cpu == .unavailable(.awaitingBaseline))
    }

    @Test func vanishedProcessesAreForgotten() {
        var tracker = ProcessUsageTracker()
        _ = tracker.update([reading(pid: 1, cpu: 0), reading(pid: 2, cpu: 0)], at: instant(10))
        #expect(tracker.trackedCount == 2)
        let snapshots = tracker.update([reading(pid: 2, cpu: 1_000)], at: instant(11))
        #expect(snapshots.map(\.pid) == [2])
        #expect(tracker.trackedCount == 1)
        // PID 1 returning later has no stale baseline.
        let returned = tracker.update([reading(pid: 1, cpu: 5_000_000_000)], at: instant(12))
        #expect(returned.first?.cpu == .unavailable(.awaitingBaseline))
    }

    @Test func counterDecreaseAndLongGapAreInvalid() {
        var tracker = ProcessUsageTracker(maximumGap: .seconds(10))
        _ = tracker.update([reading(pid: 1, cpu: 1_000)], at: instant(10))
        #expect(tracker.update([reading(pid: 1, cpu: 500)], at: instant(11)).first?.cpu == .unavailable(.invalidDelta))
        #expect(tracker.update([reading(pid: 1, cpu: 600)], at: instant(60)).first?.cpu == .unavailable(.invalidDelta))
    }

    @Test func permissionDeniedIsNotAvailableNeverZero() throws {
        var tracker = ProcessUsageTracker()
        let denied = ProcessReading(
            identity: ProcessIdentity(pid: 1, startTimeMicroseconds: 1), name: "launchd", path: "/sbin/launchd", userID: 0,
            usage: .failure(UnavailableReasonError(.permissionDenied)),
            threadCount: .failure(UnavailableReasonError(.permissionDenied))
        )
        _ = tracker.update([denied], at: instant(1))
        let snapshot = try #require(tracker.update([denied], at: instant(2)).first)
        #expect(snapshot.name == "launchd")
        #expect(snapshot.cpu == .unavailable(.permissionDenied))
        #expect(snapshot.memoryBytes == .unavailable(.permissionDenied))
        #expect(snapshot.threadCount == .unavailable(.permissionDenied))
        #expect(tracker.trackedCount == 0)
    }

    @Test func resetForgetsBaselines() {
        var tracker = ProcessUsageTracker()
        _ = tracker.update([reading(pid: 1, cpu: 0)], at: instant(1))
        tracker.reset()
        #expect(tracker.update([reading(pid: 1, cpu: 10)], at: instant(2)).first?.cpu == .unavailable(.awaitingBaseline))
    }
}

@Suite("Process sorting")
struct ProcessSortingTests {
    private func process(_ pid: Int32, _ name: String, cpu: MetricState<Double>, memory: UInt64 = 0) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: 1), name: name, path: "/usr/bin/\(name)",
            cpu: cpu, memoryBytes: .available(memory), threadCount: .available(1),
            diskReadBytesPerSecond: .available(0), diskWriteBytesPerSecond: .available(0)
        )
    }

    private var sample: [ProcessSnapshot] {
        [
            process(30, "zsh", cpu: .available(0.0), memory: 10),
            process(10, "Safari", cpu: .available(0.5), memory: 300),
            process(20, "kernel_task", cpu: .unavailable(.permissionDenied), memory: 50),
            process(5, "safari2", cpu: .available(0.0), memory: 20),
            process(40, "Xcode", cpu: .available(1.25), memory: 900),
        ]
    }

    @Test func cpuDescendingPutsUnavailableLastAndBreaksTiesByPID() {
        let sorted = ProcessSorting.sorted(sample, by: KeyPathComparator(\ProcessSnapshot.cpuSortValue, order: .reverse))
        #expect(sorted.map(\.pid) == [40, 10, 5, 30, 20])
    }

    @Test func matchesFoundationSortForNumericKeys() {
        for comparator in [
            KeyPathComparator(\ProcessSnapshot.memorySortValue),
            KeyPathComparator(\ProcessSnapshot.memorySortValue, order: .reverse),
            KeyPathComparator(\ProcessSnapshot.pid),
            KeyPathComparator(\ProcessSnapshot.pid, order: .reverse),
        ] {
            #expect(ProcessSorting.sorted(sample, by: comparator).map(\.pid) == sample.sorted(using: comparator).map(\.pid))
        }
    }

    @Test func namesSortLikeFinder() {
        let sorted = ProcessSorting.sorted(sample, by: KeyPathComparator(\ProcessSnapshot.name))
        #expect(sorted.map(\.name) == ["kernel_task", "Safari", "safari2", "Xcode", "zsh"])
        let reversed = ProcessSorting.sorted(sample, by: KeyPathComparator(\ProcessSnapshot.name, order: .reverse))
        #expect(reversed.map(\.name) == ["zsh", "Xcode", "safari2", "Safari", "kernel_task"])
    }

    @Test func noComparatorKeepsOrder() {
        #expect(ProcessSorting.sorted(sample, by: nil).map(\.pid) == sample.map(\.pid))
    }

    @Test func searchMatchesNamePathAndPID() {
        let safari = sample[1]
        #expect(safari.matches("saf"))
        #expect(safari.matches("usr/bin"))
        #expect(safari.matches("10"))
        #expect(!safari.matches("1"))
    }
}
