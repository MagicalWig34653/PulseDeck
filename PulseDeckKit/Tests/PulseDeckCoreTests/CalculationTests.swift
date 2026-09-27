import Foundation
import Testing
@testable import PulseDeckCore

private let testCPUInfo = CPUInfo(modelName: "Test", logicalProcessorCount: 2, physicalCoreCount: 2, performanceLevels: [])

@Suite("CPU calculation")
struct CPUUsageCalculatorTests {
    @Test func computesPerCoreAndAggregateFractions() throws {
        let previous = [
            CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 1_000, nice: 0),
        ]
        let current = [
            CPUTicks(user: 160, system: 70, idle: 870, nice: 0),   // +60 user, +20 system, +20 idle
            CPUTicks(user: 0, system: 0, idle: 1_100, nice: 0),    // +100 idle
        ]
        let snapshot = try #require(CPUUsageCalculator.snapshot(info: testCPUInfo, previous: previous, current: current).value)
        #expect(snapshot.cores.count == 2)
        #expect(abs(snapshot.cores[0].user - 0.6) < 1e-9)
        #expect(abs(snapshot.cores[0].system - 0.2) < 1e-9)
        #expect(abs(snapshot.cores[0].total - 0.8) < 1e-9)
        #expect(snapshot.cores[1].total == 0)
        #expect(abs(snapshot.user - 0.3) < 1e-9)
        #expect(abs(snapshot.system - 0.1) < 1e-9)
        #expect(abs(snapshot.idle - 0.6) < 1e-9)
        #expect(abs(snapshot.total - 0.4) < 1e-9)
    }

    @Test func niceCountsAsUser() throws {
        let snapshot = try #require(CPUUsageCalculator.snapshot(
            info: testCPUInfo,
            previous: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
            current: [CPUTicks(user: 10, system: 0, idle: 70, nice: 20)]
        ).value)
        #expect(abs(snapshot.user - 0.3) < 1e-9)
    }

    @Test func handlesTickCounterWrap() throws {
        let snapshot = try #require(CPUUsageCalculator.snapshot(
            info: testCPUInfo,
            previous: [CPUTicks(user: .max - 9, system: 0, idle: .max - 9, nice: 0)],
            current: [CPUTicks(user: 10, system: 0, idle: 10, nice: 0)]
        ).value)
        #expect(abs(snapshot.user - 0.5) < 1e-9)
    }

    @Test func processorCountChangeIsInvalid() {
        let state = CPUUsageCalculator.snapshot(
            info: testCPUInfo,
            previous: [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)],
            current: [CPUTicks(user: 1, system: 0, idle: 1, nice: 0), CPUTicks(user: 1, system: 0, idle: 1, nice: 0)]
        )
        #expect(state.unavailableReason == .invalidDelta)
    }

    @Test func noElapsedTicksIsInvalid() {
        let ticks = [CPUTicks(user: 5, system: 5, idle: 5, nice: 0)]
        #expect(CPUUsageCalculator.snapshot(info: testCPUInfo, previous: ticks, current: ticks).unavailableReason == .invalidDelta)
    }
}

@Suite("Memory calculation")
struct MemoryCalculatorTests {
    @Test func usedIsAppPlusWiredPlusCompressed() {
        let pageSize: UInt64 = 16_384
        let pages = VMPageCounts(free: 100, active: 400, inactive: 300, wired: 200, speculative: 20,
                                 purgeable: 50, compressor: 150, internalPages: 550, externalPages: 250)
        let snapshot = MemoryCalculator.snapshot(physicalTotal: 16 << 30, pageSize: pageSize, pages: pages,
                                                 swap: .available(SwapUsage(used: 1, total: 2)), pressure: .available(.normal))
        #expect(snapshot.appMemory == 500 * pageSize)
        #expect(snapshot.wired == 200 * pageSize)
        #expect(snapshot.compressed == 150 * pageSize)
        #expect(snapshot.used == 850 * pageSize)
        #expect(snapshot.cachedFiles == 300 * pageSize)
        #expect(snapshot.free == 100 * pageSize)
        #expect(snapshot.available == (16 << 30) - 850 * pageSize)
    }

    @Test func purgeableLargerThanInternalDoesNotUnderflow() {
        let pages = VMPageCounts(free: 0, active: 0, inactive: 0, wired: 1, speculative: 0,
                                 purgeable: 10, compressor: 0, internalPages: 5, externalPages: 0)
        let snapshot = MemoryCalculator.snapshot(physicalTotal: 1 << 20, pageSize: 4_096, pages: pages,
                                                 swap: .unavailable(.transientFailure("test")), pressure: .notSampled)
        #expect(snapshot.appMemory == 0)
        #expect(snapshot.used == 4_096)
    }

    @Test func pressureLevels() {
        #expect(MemoryPressure(dispatchLevel: 1) == .normal)
        #expect(MemoryPressure(dispatchLevel: 2) == .warning)
        #expect(MemoryPressure(dispatchLevel: 4) == .critical)
        #expect(MemoryPressure(dispatchLevel: 3) == nil)
    }
}

@Suite("Counter rate tracker")
struct CounterRateTrackerTests {
    private func at(_ seconds: Double) -> MonotonicInstant { MonotonicInstant(nanoseconds: UInt64(seconds * 1e9)) }

    @Test func firstSampleThenRates() {
        var tracker = CounterRateTracker<String>()
        let first = tracker.update(key: "en0", generation: 4, counters: [1_000, 500], at: at(10))
        #expect(first == [.unavailable(.awaitingBaseline), .unavailable(.awaitingBaseline)])
        let second = tracker.update(key: "en0", generation: 4, counters: [3_000, 1_500], at: at(12))
        #expect(second == [.available(1_000), .available(500)])
    }

    @Test func recreatedDeviceStartsNewBaseline() {
        var tracker = CounterRateTracker<String>()
        _ = tracker.update(key: "utun4", generation: 20, counters: [9_000], at: at(1))
        // Same name, new interface index: the VPN reconnected.
        let rates = tracker.update(key: "utun4", generation: 21, counters: [100], at: at(2))
        #expect(rates == [.unavailable(.awaitingBaseline)])
        #expect(tracker.update(key: "utun4", generation: 21, counters: [300], at: at(3)) == [.available(200)])
    }

    @Test func counterResetIsInvalidNotNegative() {
        var tracker = CounterRateTracker<String>()
        _ = tracker.update(key: "disk2", generation: 1, counters: [5_000], at: at(1))
        #expect(tracker.update(key: "disk2", generation: 1, counters: [10], at: at(2)) == [.unavailable(.invalidDelta)])
    }

    @Test func gapLongerThanMaximumIsInvalid() {
        var tracker = CounterRateTracker<String>(maximumGap: .seconds(15))
        _ = tracker.update(key: "en0", generation: 1, counters: [0], at: at(0))
        #expect(tracker.update(key: "en0", generation: 1, counters: [1_000_000], at: at(60)) == [.unavailable(.invalidDelta)])
    }

    @Test func retainOnlyDropsVanishedDevices() {
        var tracker = CounterRateTracker<String>()
        _ = tracker.update(key: "a", generation: 1, counters: [1], at: at(1))
        _ = tracker.update(key: "b", generation: 1, counters: [1], at: at(1))
        tracker.retainOnly(["b"])
        #expect(tracker.trackedKeys == ["b"])
        tracker.reset()
        #expect(tracker.trackedKeys.isEmpty)
    }
}

@Suite("Interface classification")
struct NetworkInterfaceClassifierTests {
    private typealias C = NetworkInterfaceClassifier

    @Test func systemConfigurationTypesWin() {
        #expect(C.classify(bsdName: "en0", interfaceType: C.InterfaceType.ethernet, isLoopback: false, systemConfigurationType: "IEEE80211", displayName: "Wi-Fi") == .wifi)
        #expect(C.classify(bsdName: "en5", interfaceType: C.InterfaceType.ethernet, isLoopback: false, systemConfigurationType: "Ethernet", displayName: "USB 10/100/1G/2.5G LAN") == .ethernet)
        #expect(C.classify(bsdName: "en2", interfaceType: C.InterfaceType.ethernet, isLoopback: false, systemConfigurationType: "Ethernet", displayName: "Thunderbolt 2") == .thunderbolt)
        #expect(C.classify(bsdName: "bridge0", interfaceType: C.InterfaceType.bridge, isLoopback: false, systemConfigurationType: "Bridge", displayName: "Thunderbolt Bridge") == .thunderbolt)
    }

    @Test func tunnelsAreVisibleAsGenericVPN() {
        for name in ["utun0", "utun7", "ipsec0", "ppp0", "wg0", "tun1", "tap0"] {
            #expect(C.classify(bsdName: name, interfaceType: 0, isLoopback: false, systemConfigurationType: nil, displayName: nil) == .vpnTunnel(friendlyName: nil))
        }
    }

    @Test func loopbackBridgeCellularAndUnknown() {
        #expect(C.classify(bsdName: "lo0", interfaceType: C.InterfaceType.loopback, isLoopback: true, systemConfigurationType: nil, displayName: nil) == .loopback)
        #expect(C.classify(bsdName: "bridge100", interfaceType: C.InterfaceType.bridge, isLoopback: false, systemConfigurationType: nil, displayName: nil) == .bridge)
        #expect(C.classify(bsdName: "pdp_ip0", interfaceType: C.InterfaceType.cellular, isLoopback: false, systemConfigurationType: nil, displayName: nil) == .cellular)
        // IFT_ETHER without SystemConfiguration info could be Wi-Fi: never guess "Ethernet".
        #expect(C.classify(bsdName: "en9", interfaceType: C.InterfaceType.ethernet, isLoopback: false, systemConfigurationType: nil, displayName: nil) == .other)
        #expect(C.classify(bsdName: "awdl0", interfaceType: C.InterfaceType.ethernet, isLoopback: false, systemConfigurationType: nil, displayName: nil) == .other)
    }
}

@Suite("System history")
struct SystemHistoryTests {
    private func snapshot(_ second: UInt64, cpu: MetricState<CPUSnapshot>, interfaces: [String] = []) -> SystemSnapshot {
        let ifaces = interfaces.map {
            NetworkInterfaceSnapshot(id: $0, displayName: nil, kind: .other, isUp: true,
                                     receivedBytesPerSecond: .available(10), sentBytesPerSecond: .unavailable(.awaitingBaseline),
                                     totalBytesReceived: 0, totalBytesSent: 0)
        }
        return SystemSnapshot(
            sequence: second,
            timestamp: SampleTimestamp(monotonic: MonotonicInstant(nanoseconds: second * 1_000_000_000), wallClock: Date(timeIntervalSince1970: TimeInterval(second))),
            samplingMode: .foreground,
            cpu: cpu, memory: .unavailable(.notImplemented), disks: .unavailable(.notImplemented),
            network: .available(NetworkSnapshot(interfaces: ifaces, primaryInterfaceID: nil)),
            gpu: .notSampled, energy: .notSampled, processes: .notSampled
        )
    }

    private let cpu = CPUSnapshot(info: testCPUInfo, user: 0.25, system: 0.5, idle: 0.25,
                                  cores: [CPUCoreSnapshot(id: 0, user: 0.5, system: 0.5, idle: 0),
                                          CPUCoreSnapshot(id: 1, user: 0, system: 0.5, idle: 0.5)])

    @Test func recordsValuesAndGaps() {
        var history = SystemHistory()
        history.append(snapshot(1, cpu: .unavailable(.awaitingBaseline)))
        history.append(snapshot(2, cpu: .available(cpu)))
        #expect(history.cpu.samples.count == 2)
        #expect(history.cpu.samples[0].values == [nil, nil])
        #expect(history.cpu.samples[1].values == [0.25, 0.5])
        #expect(history.cpuCores.seriesCount == 2)
        #expect(history.cpuCores.latest?.values == [1.0, 0.5])
        #expect(history.memory.samples[1].values == [nil, nil])
    }

    @Test func notSampledAddsNothing() {
        var history = SystemHistory()
        history.append(snapshot(1, cpu: .notSampled))
        #expect(history.cpu.samples.isEmpty)
    }

    @Test func staysBounded() {
        var history = SystemHistory()
        for second in 1...1_000 as ClosedRange<UInt64> {
            history.append(snapshot(second, cpu: .available(cpu), interfaces: ["en0"]))
        }
        #expect(history.cpu.samples.count == SystemHistory.capacity)
        #expect(history.network["en0"]?.samples.count == SystemHistory.capacity)
    }

    @Test func vanishedDevicesArePrunedAfterWindow() {
        var history = SystemHistory()
        history.append(snapshot(1, cpu: .available(cpu), interfaces: ["en0", "utun3"]))
        history.append(snapshot(30, cpu: .available(cpu), interfaces: ["en0"]))
        #expect(history.network.keys.sorted() == ["en0", "utun3"])
        history.append(snapshot(62, cpu: .available(cpu), interfaces: ["en0"]))
        #expect(history.network.keys.sorted() == ["en0"])
        #expect(history.network["en0"]?.latest?.values == [10, nil])
    }
}

@Suite("Chart scale")
struct ChartScaleTests {
    @Test func roundsUpToNiceSteps() {
        #expect(ChartScale.niceUpperBound(for: 0.7, minimum: 0) == 1)
        #expect(ChartScale.niceUpperBound(for: 1.3, minimum: 0) == 2)
        #expect(ChartScale.niceUpperBound(for: 3_100, minimum: 0) == 5_000)
        #expect(ChartScale.niceUpperBound(for: 5_000, minimum: 0) == 5_000)
        #expect(ChartScale.niceUpperBound(for: 7_200_000, minimum: 0) == 10_000_000)
    }

    @Test func respectsMinimumAndBadInput() {
        #expect(ChartScale.niceUpperBound(for: 10, minimum: 100_000) == 100_000)
        #expect(ChartScale.niceUpperBound(for: 0, minimum: 0) == 1)
        #expect(ChartScale.niceUpperBound(for: .nan, minimum: 1_000) == 1_000)
    }
}

@Suite("Network addresses")
struct NetworkAddressOrderingTests {
    @Test func ordersIPv4ThenRoutableIPv6ThenLinkLocal() {
        let sorted = NetworkAddressOrdering.sorted(["fe80::1", "2001:db8::5", "192.168.1.20", "169.254.3.4"])
        #expect(sorted == ["192.168.1.20", "2001:db8::5", "169.254.3.4", "fe80::1"])
    }

    @Test func stripsZoneIndex() {
        #expect(NetworkAddressOrdering.withoutZone("fe80::1%en0") == "fe80::1")
        #expect(NetworkAddressOrdering.withoutZone("10.0.0.1") == "10.0.0.1")
    }

    @Test func snapshotAccessors() {
        let interface = NetworkInterfaceSnapshot(
            id: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true,
            receivedBytesPerSecond: .available(0), sentBytesPerSecond: .available(0),
            totalBytesReceived: 1, totalBytesSent: 1,
            addresses: NetworkAddressOrdering.sorted(["fe80::1", "fd00::2", "10.0.0.7"])
        )
        #expect(interface.ipv4Address == "10.0.0.7")
        #expect(interface.ipv6Address == "fd00::2")
    }
}
