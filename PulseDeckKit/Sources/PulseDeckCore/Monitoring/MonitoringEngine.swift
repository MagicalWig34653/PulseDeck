import Foundation

/// Drives all telemetry collection and publishes immutable `SystemSnapshot`s (SPEC §5).
///
/// The engine is an actor, so its sampling loop never runs on the MainActor. Collectors are
/// sampled concurrently; their results are batched into one snapshot per tick so the UI has a
/// single update per interval instead of many independently observed values.
public actor MonitoringEngine {
    /// Snapshots in sampling order. Buffers only the newest few: if the consumer stalls, older
    /// snapshots are dropped and show up as a gap in history rather than being fabricated.
    public nonisolated let snapshots: AsyncStream<SystemSnapshot>

    private let continuation: AsyncStream<SystemSnapshot>.Continuation
    private let providers: TelemetryProviders
    private let clock: any MonotonicClock
    private let wallClock: @Sendable () -> Date

    /// Policy requested by the app (window visibility, demand).
    private var requestedPolicy: SamplingPolicy
    /// Set between the system's will-sleep and did-wake notifications.
    private var isSystemAsleep = false
    private var isRunning = false
    private var loopTask: Task<Void, Never>?
    private var nextSequence: UInt64 = 0

    /// Number of snapshots the stream keeps when the consumer is slower than the producer.
    public static let defaultSnapshotBufferSize = 4

    public init(
        providers: TelemetryProviders,
        policy: SamplingPolicy = SamplingPolicy(),
        clock: any MonotonicClock = SystemMonotonicClock(),
        wallClock: @escaping @Sendable () -> Date = { Date() },
        snapshotBufferSize: Int = MonitoringEngine.defaultSnapshotBufferSize
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SystemSnapshot.self,
            bufferingPolicy: .bufferingNewest(snapshotBufferSize)
        )
        self.snapshots = stream
        self.continuation = continuation
        self.providers = providers
        self.requestedPolicy = policy
        self.clock = clock
        self.wallClock = wallClock
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    // MARK: - Lifecycle

    /// The policy currently in effect (suspended while the system sleeps).
    public var effectivePolicy: SamplingPolicy {
        var policy = requestedPolicy
        if isSystemAsleep {
            policy.mode = .suspended
        }
        return policy
    }

    public var running: Bool { isRunning }

    /// Start periodic sampling. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        restartLoop()
    }

    /// Stop periodic sampling. Idempotent. The stream stays open so the engine can be restarted.
    public func stop() {
        isRunning = false
        restartLoop()
    }

    /// Stop sampling and finish the snapshot stream (explicit quit, SPEC §25).
    public func shutdown() {
        stop()
        continuation.finish()
    }

    /// Apply a new policy. A change of interval restarts the loop so, e.g., reopening the main
    /// window switches to 1 Hz immediately instead of after the pending background interval.
    public func updatePolicy(_ policy: SamplingPolicy) {
        guard policy != requestedPolicy else { return }
        let previousInterval = effectivePolicy.interval
        requestedPolicy = policy
        if effectivePolicy.interval != previousInterval {
            restartLoop()
        }
    }

    /// Called when the system is about to sleep: stop sampling entirely.
    public func systemWillSleep() {
        guard !isSystemAsleep else { return }
        isSystemAsleep = true
        restartLoop()
    }

    /// Called after wake: discard every baseline so no delta spans the sleep, then resume
    /// (SPEC §27).
    public func systemDidWake() async {
        guard isSystemAsleep else { return }
        await invalidateAllBaselines()
        isSystemAsleep = false
        restartLoop()
    }

    /// Discard all collector baselines. The next sample of every delta metric is
    /// `.awaitingBaseline`.
    public func invalidateAllBaselines() async {
        await providers.cpu?.invalidateBaselines()
        await providers.memory?.invalidateBaselines()
        await providers.disks?.invalidateBaselines()
        await providers.network?.invalidateBaselines()
        await providers.gpu?.invalidateBaselines()
        await providers.energy?.invalidateBaselines()
        await providers.processes?.invalidateBaselines()
        await providers.cpuFrequency?.invalidateBaselines()
        await providers.tailscale?.invalidateBaselines()
        await providers.containers?.invalidateBaselines()
        await providers.usb?.invalidateBaselines()
        await providers.thermals?.invalidateBaselines()
    }

    /// Capability of every domain. Domains without a collector are `.unsupported(.notImplemented)`.
    public func capabilities() async -> [MetricKind: TelemetryCapability] {
        func probe<R>(_ provider: (any TelemetryProvider<R>)?) async -> TelemetryCapability {
            guard let provider else { return .unsupported(.notImplemented) }
            return await provider.capability()
        }
        return [
            .cpu: await probe(providers.cpu),
            .memory: await probe(providers.memory),
            .disk: await probe(providers.disks),
            .network: await probe(providers.network),
            .gpu: await probe(providers.gpu),
            .energy: await probe(providers.energy),
            .processes: await probe(providers.processes),
            .cpuFrequency: await probe(providers.cpuFrequency),
            .tailscale: await probe(providers.tailscale),
            .containers: await probe(providers.containers),
            .usb: await probe(providers.usb),
            .thermals: await probe(providers.thermals),
        ]
    }

    // MARK: - Sampling

    /// Take one snapshot using the current effective policy. The loop uses this; tests may
    /// call it directly.
    public func sampleOnce() async -> SystemSnapshot {
        // Reserve the sequence number before suspending so re-entrant calls stay unique.
        let sequence = nextSequence
        nextSequence += 1
        let policy = effectivePolicy
        let timestamp = SampleTimestamp(monotonic: clock.now(), wallClock: wallClock())
        let instant = timestamp.monotonic

        async let cpu = Self.collect(providers.cpu, kind: .cpu, policy: policy, at: instant)
        async let memory = Self.collect(providers.memory, kind: .memory, policy: policy, at: instant)
        async let disks = Self.collect(providers.disks, kind: .disk, policy: policy, at: instant)
        async let network = Self.collect(providers.network, kind: .network, policy: policy, at: instant)
        async let gpu = Self.collect(providers.gpu, kind: .gpu, policy: policy, at: instant)
        async let energy = Self.collect(providers.energy, kind: .energy, policy: policy, at: instant)
        async let processes = Self.collect(providers.processes, kind: .processes, policy: policy, at: instant)
        async let cpuFrequency = Self.collect(providers.cpuFrequency, kind: .cpuFrequency, policy: policy, at: instant)
        async let tailscale = Self.collect(providers.tailscale, kind: .tailscale, policy: policy, at: instant)
        async let containers = Self.collect(providers.containers, kind: .containers, policy: policy, at: instant)
        async let usb = Self.collect(providers.usb, kind: .usb, policy: policy, at: instant)
        async let thermals = Self.collect(providers.thermals, kind: .thermals, policy: policy, at: instant)

        return SystemSnapshot(
            sequence: sequence,
            timestamp: timestamp,
            samplingMode: policy.mode,
            cpu: await cpu,
            memory: await memory,
            disks: await disks,
            network: await network,
            gpu: await gpu,
            energy: await energy,
            processes: await processes,
            cpuFrequency: await cpuFrequency,
            tailscale: await tailscale,
            containers: await containers,
            usb: await usb,
            thermals: await thermals
        )
    }

    private static func collect<Reading>(
        _ provider: (any TelemetryProvider<Reading>)?,
        kind: MetricKind,
        policy: SamplingPolicy,
        at instant: MonotonicInstant
    ) async -> MetricState<Reading> {
        guard policy.shouldSample(kind) else { return .notSampled }
        guard let provider else { return .unavailable(.notImplemented) }
        return await provider.sample(at: instant)
    }

    // MARK: - Loop

    private func restartLoop() {
        let previous = loopTask
        previous?.cancel()
        loopTask = nil
        guard isRunning, effectivePolicy.interval != nil else { return }
        loopTask = Task { [weak self] in
            // Never let two loops sample concurrently: wait for the cancelled one to exit.
            await previous?.value
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let snapshot = await sampleOnce()
            // A policy change or sleep may have cancelled this loop while sampling; the
            // replacement loop publishes its own fresh sample.
            guard !Task.isCancelled else { return }
            continuation.yield(snapshot)

            let policy = effectivePolicy
            guard let interval = policy.interval else { return }
            do {
                try await Task.sleep(for: interval, tolerance: policy.tolerance)
            } catch {
                return // cancelled
            }
        }
    }
}
