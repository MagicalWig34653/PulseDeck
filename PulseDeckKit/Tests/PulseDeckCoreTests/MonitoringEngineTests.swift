import Synchronization
import Testing
@testable import PulseDeckCore

// MARK: - Test doubles (test target only; never used in production)

/// Deterministic clock advanced manually by tests.
private final class ManualClock: MonotonicClock {
    private let current = Mutex<UInt64>(0)

    func now() -> MonotonicInstant {
        current.withLock { MonotonicInstant(nanoseconds: $0) }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 += UInt64(duration.nanosecondsClamped) }
    }
}

/// Stub collector returning a fixed reading and recording calls.
private actor StubProvider<Reading: Sendable>: TelemetryProvider {
    private let reading: MetricState<Reading>
    private(set) var sampleCount = 0
    private(set) var invalidationCount = 0
    private(set) var sampledInstants: [MonotonicInstant] = []

    init(_ reading: MetricState<Reading>) {
        self.reading = reading
    }

    func capability() async -> TelemetryCapability { .supported }

    func sample(at instant: MonotonicInstant) async -> MetricState<Reading> {
        sampleCount += 1
        sampledInstants.append(instant)
        return reading
    }

    func invalidateBaselines() async {
        invalidationCount += 1
    }
}

private let stubCPU = CPUSnapshot(
    info: CPUInfo(modelName: "Stub CPU", logicalProcessorCount: 2, physicalCoreCount: 2, performanceLevels: []),
    user: 0.25,
    system: 0.25,
    idle: 0.5,
    cores: [
        CPUCoreSnapshot(id: 0, user: 0.5, system: 0.5, idle: 0),
        CPUCoreSnapshot(id: 1, user: 0, system: 0, idle: 1),
    ]
)

// MARK: - Tests

@Suite("MonitoringEngine")
struct MonitoringEngineTests {
    @Test func missingCollectorsAreNotImplementedNeverZero() async {
        let engine = MonitoringEngine(providers: .none, clock: ManualClock())
        let snapshot = await engine.sampleOnce()
        #expect(snapshot.cpu == .unavailable(.notImplemented))
        #expect(snapshot.memory == .unavailable(.notImplemented))
        #expect(snapshot.disks == .unavailable(.notImplemented))
        #expect(snapshot.network == .unavailable(.notImplemented))
        // Demand-driven domains are not sampled without demand.
        #expect(snapshot.gpu == .notSampled)
        #expect(snapshot.energy == .notSampled)
        #expect(snapshot.processes == .notSampled)
    }

    @Test func collectsFromProvidersAtTheSampleInstant() async {
        let clock = ManualClock()
        clock.advance(by: .seconds(5))
        let cpu = StubProvider<CPUSnapshot>(.available(stubCPU))
        let engine = MonitoringEngine(providers: TelemetryProviders(cpu: cpu), clock: clock)
        let snapshot = await engine.sampleOnce()
        #expect(snapshot.cpu == .available(stubCPU))
        #expect(snapshot.timestamp.monotonic == MonotonicInstant(nanoseconds: 5_000_000_000))
        #expect(await cpu.sampledInstants == [snapshot.timestamp.monotonic])
    }

    @Test func sequenceNumbersIncrease() async {
        let engine = MonitoringEngine(providers: .none, clock: ManualClock())
        let first = await engine.sampleOnce()
        let second = await engine.sampleOnce()
        #expect(second.sequence == first.sequence + 1)
    }

    @Test func processSamplingFollowsDemand() async {
        let processes = StubProvider<[ProcessSnapshot]>(.available([]))
        let engine = MonitoringEngine(providers: TelemetryProviders(processes: processes), clock: ManualClock())

        let withoutDemand = await engine.sampleOnce()
        #expect(withoutDemand.processes == .notSampled)
        #expect(await processes.sampleCount == 0)

        await engine.updatePolicy(SamplingPolicy(demand: [.processes]))
        let withDemand = await engine.sampleOnce()
        #expect(withDemand.processes == .available([]))
        #expect(await processes.sampleCount == 1)
    }

    @Test func sleepSuspendsAndWakeInvalidatesBaselines() async {
        let cpu = StubProvider<CPUSnapshot>(.available(stubCPU))
        let engine = MonitoringEngine(providers: TelemetryProviders(cpu: cpu), clock: ManualClock())

        await engine.systemWillSleep()
        #expect(await engine.effectivePolicy.mode == .suspended)
        let asleep = await engine.sampleOnce()
        #expect(asleep.cpu == .notSampled)
        #expect(asleep.samplingMode == .suspended)

        await engine.systemDidWake()
        #expect(await engine.effectivePolicy.mode == .foreground)
        #expect(await cpu.invalidationCount == 1)

        // A second wake without sleep is ignored.
        await engine.systemDidWake()
        #expect(await cpu.invalidationCount == 1)
    }

    @Test func policyChangeDuringSleepAppliesAfterWake() async {
        let engine = MonitoringEngine(providers: .none, clock: ManualClock())
        await engine.systemWillSleep()
        await engine.updatePolicy(SamplingPolicy(mode: .background))
        #expect(await engine.effectivePolicy.mode == .suspended)
        await engine.systemDidWake()
        #expect(await engine.effectivePolicy.mode == .background)
    }

    @Test(.timeLimit(.minutes(1)))
    func runningEnginePublishesOrderedSnapshots() async {
        let cpu = StubProvider<CPUSnapshot>(.available(stubCPU))
        let engine = MonitoringEngine(
            providers: TelemetryProviders(cpu: cpu),
            policy: SamplingPolicy(foregroundInterval: .milliseconds(10))
        )
        await engine.start()
        await engine.start() // idempotent

        var received: [SystemSnapshot] = []
        for await snapshot in engine.snapshots {
            received.append(snapshot)
            if received.count == 3 { break }
        }
        await engine.stop()
        #expect(await engine.running == false)

        #expect(received.count == 3)
        let sequences = received.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == 3)
        let instants = received.map(\.timestamp.monotonic)
        #expect(instants == instants.sorted())
        #expect(received.allSatisfy { $0.cpu == .available(stubCPU) })
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownFinishesStream() async {
        let engine = MonitoringEngine(
            providers: .none,
            policy: SamplingPolicy(foregroundInterval: .milliseconds(10))
        )
        await engine.start()
        await engine.shutdown()
        var count = 0
        for await _ in engine.snapshots { count += 1 }
        // The stream terminates; at most the buffered snapshots are delivered.
        #expect(count <= MonitoringEngine.defaultSnapshotBufferSize)
    }

    @Test func capabilitiesReportMissingCollectors() async {
        let cpu = StubProvider<CPUSnapshot>(.available(stubCPU))
        let engine = MonitoringEngine(providers: TelemetryProviders(cpu: cpu), clock: ManualClock())
        let capabilities = await engine.capabilities()
        #expect(capabilities[.cpu] == .supported)
        #expect(capabilities[.gpu] == .unsupported(.notImplemented))
        #expect(capabilities.count == MetricKind.allCases.count)
    }
}
