import Foundation
import Observation
import PulseDeckCore

/// Visibility of the main window, reported by `WindowVisibilityObserver`.
enum WindowVisibility: Equatable {
    /// Not open.
    case closed
    /// Open but minimised, on another Space or fully covered.
    case occluded
    /// At least partly visible on screen.
    case visible
}

/// The single observable object the UI reads (SPEC §5): the latest immutable snapshot plus
/// the UI state that determines the sampling policy. Lives on the MainActor; it never
/// collects telemetry itself.
@MainActor
@Observable
final class AppState {
    /// Most recent snapshot from the engine, `nil` until the first sample arrives.
    private(set) var latestSnapshot: SystemSnapshot? = nil

    /// Bounded chart history, appended once per snapshot. Stored outside observation and
    /// exposed through `history`, so appending mutates the ring buffers in place instead of
    /// copying them; `historyRevision` is what views actually observe.
    @ObservationIgnored private var historyStorage = SystemHistory()
    private(set) var historyRevision: UInt64 = 0

    var history: SystemHistory {
        _ = historyRevision
        return historyStorage
    }

    /// Last sampled process table. Kept across ticks where processes were not sampled (e.g. the
    /// tick that raced the section switch) and dropped when the Processes section is left, so a
    /// stale table is never shown and nothing large is retained in the background.
    private(set) var latestProcesses: MetricState<[ProcessSnapshot]>? = nil

    /// Text shown next to the menu bar icon, `nil` for icon only. Assigned only when it
    /// actually changes so the status item is not re-rendered every tick (SPEC §24).
    private(set) var menuBarLabelText: String? = nil

    var mainWindowVisibility: WindowVisibility = .closed {
        didSet {
            guard mainWindowVisibility != oldValue else { return }
            let wasOpen = oldValue != .closed
            let isOpen = mainWindowVisibility != .closed
            if wasOpen != isOpen {
                onMainWindowOpenChanged?(isOpen)
            }
            pushPolicy()
        }
    }

    /// The section currently shown in the main window.
    var visibleSection: AppSection? = nil {
        didSet {
            guard visibleSection != oldValue else { return }
            if visibleSection != .processes {
                latestProcesses = nil
            }
            pushPolicy()
        }
    }

    /// Whether the menu bar extra's window is open.
    var isMenuBarWindowVisible = false {
        didSet { if isMenuBarWindowVisible != oldValue { pushPolicy() } }
    }

    var menuBarMetric: MenuBarMetric {
        didSet {
            guard menuBarMetric != oldValue else { return }
            defaults.set(menuBarMetric.rawValue, forKey: PreferenceKey.menuBarMetric)
            updateMenuBarLabel()
            pushPolicy()
        }
    }

    /// Called when the main window opens (`true`) or closes (`false`).
    @ObservationIgnored var onMainWindowOpenChanged: ((Bool) -> Void)? = nil

    /// Commands to the engine are delivered through one ordered channel so that, e.g., a
    /// policy change can never overtake a later sleep notification.
    private enum EngineCommand: Sendable {
        case start
        case policy(SamplingPolicy)
        case systemWillSleep
        case systemDidWake
        case shutdown
    }

    @ObservationIgnored private let engine: MonitoringEngine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let commands: AsyncStream<EngineCommand>
    @ObservationIgnored private let commandContinuation: AsyncStream<EngineCommand>.Continuation
    @ObservationIgnored private var commandTask: Task<Void, Never>? = nil
    @ObservationIgnored private var snapshotTask: Task<Void, Never>? = nil

    init(engine: MonitoringEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        menuBarMetric = defaults.string(forKey: PreferenceKey.menuBarMetric)
            .flatMap(MenuBarMetric.init(rawValue:)) ?? .none
        let (stream, continuation) = AsyncStream.makeStream(of: EngineCommand.self)
        commands = stream
        commandContinuation = continuation
        updateMenuBarLabel()
    }

    // MARK: - Lifecycle

    /// Starts the engine and begins consuming snapshots. Idempotent.
    func start() {
        guard commandTask == nil else { return }

        commandTask = Task { [engine, commands] in
            for await command in commands {
                switch command {
                case .start: await engine.start()
                case .policy(let policy): await engine.updatePolicy(policy)
                case .systemWillSleep: await engine.systemWillSleep()
                case .systemDidWake: await engine.systemDidWake()
                case .shutdown:
                    await engine.shutdown()
                    return
                }
            }
        }

        snapshotTask = Task { [weak self, engine] in
            for await snapshot in engine.snapshots {
                guard let self else { return }
                self.receive(snapshot)
            }
        }

        pushPolicy()
        commandContinuation.yield(.start)
    }

    /// Stops monitoring cleanly (explicit Quit, SPEC §25). Waits until the engine has stopped.
    func shutdown() async {
        commandContinuation.yield(.shutdown)
        commandContinuation.finish()
        await commandTask?.value
        snapshotTask?.cancel()
        commandTask = nil
        snapshotTask = nil
    }

    func systemWillSleep() {
        commandContinuation.yield(.systemWillSleep)
    }

    func systemDidWake() {
        commandContinuation.yield(.systemDidWake)
    }

    // MARK: - Snapshots

    private func receive(_ snapshot: SystemSnapshot) {
        historyStorage.append(snapshot)
        historyRevision &+= 1
        latestSnapshot = snapshot
        if case .notSampled = snapshot.processes {
            // Keep the previous table.
        } else if visibleSection == .processes {
            latestProcesses = snapshot.processes
        }
        updateMenuBarLabel()
    }

    private func updateMenuBarLabel() {
        let text: String? = switch menuBarMetric {
        case .none:
            nil
        default:
            latestSnapshot.flatMap { menuBarMetric.value(in: $0).value } ?? Self.placeholder
        }
        if text != menuBarLabelText {
            menuBarLabelText = text
        }
    }

    /// Shown where a value is missing. The accessible label says "Not Available".
    static let placeholder = "—"

    // MARK: - Sampling policy

    /// Policy derived from what is currently on screen (SPEC §7, §26).
    var samplingPolicy: SamplingPolicy {
        let windowVisible = mainWindowVisibility == .visible
        var demand: Set<MetricKind> = []
        if windowVisible, let visibleSection {
            switch visibleSection {
            case .performance:
                // The resource list shows live previews of every category.
                demand.formUnion([.gpu, .energy])
            case .processes:
                demand.insert(.processes)
            }
        }
        if isMenuBarWindowVisible {
            // The menu bar overview shows CPU, memory, GPU, energy and network.
            demand.formUnion([.gpu, .energy])
        }
        if let kind = menuBarMetric.requiredMetricKind {
            demand.insert(kind)
        }
        return SamplingPolicy(mode: windowVisible ? .foreground : .background, demand: demand)
    }

    private func pushPolicy() {
        commandContinuation.yield(.policy(samplingPolicy))
    }
}
