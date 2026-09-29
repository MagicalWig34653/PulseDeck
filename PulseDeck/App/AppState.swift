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

    /// Last container list, kept like `latestProcesses` while the Containers section is shown.
    private(set) var latestContainers: MetricState<ContainersSnapshot>? = nil

    /// Last USB tree. Kept after leaving the USB page so its list entry can still show the
    /// device count; the tree is only re-read while the page is visible.
    private(set) var latestUSB: USBSnapshot? = nil

    /// Display updates are paused while Control is held (like Task Manager). Sampling continues;
    /// snapshots received meanwhile are applied when the pause ends, so no history is lost.
    private(set) var isPaused = false
    @ObservationIgnored private var pausedSnapshots: [SystemSnapshot] = []

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
            if visibleSection != .containers {
                latestContainers = nil
            }
            pushPolicy()
        }
    }

    /// Whether the menu bar extra's window is open.
    var isMenuBarWindowVisible = false {
        didSet { if isMenuBarWindowVisible != oldValue { pushPolicy() } }
    }

    /// Domains the visible Performance page needs beyond the list previews (CPU page → frequency,
    /// Tailscale interface → peers, USB page → USB tree). Set by the page.
    var detailPageDemand: Set<MetricKind> = [] {
        didSet { if detailPageDemand != oldValue { pushPolicy() } }
    }

    /// A page the main window should show next, requested from outside the window (e.g. a
    /// resource row in the menu bar panel). The window consumes and clears it.
    var requestedItem: PerformanceItem? = nil

    /// Which disks and network interfaces the Performance list shows. Persisted as JSON.
    var sidebarVisibility: SidebarVisibility {
        didSet {
            guard sidebarVisibility != oldValue else { return }
            if let data = try? JSONEncoder().encode(sidebarVisibility) {
                defaults.set(data, forKey: PreferenceKey.sidebarVisibility)
            }
        }
    }

    /// The sidebar presentation lists the resource previews next to Processes, so GPU and
    /// energy stay in demand there.
    var showsResourcePreviewsInEverySection = false {
        didSet { if showsResourcePreviewsInEverySection != oldValue { pushPolicy() } }
    }

    /// Sampling interval while only the menu bar is active (SPEC §7, §32 "refresh behavior").
    var backgroundRefreshInterval: BackgroundRefreshInterval {
        didSet {
            guard backgroundRefreshInterval != oldValue else { return }
            defaults.set(backgroundRefreshInterval.rawValue, forKey: PreferenceKey.backgroundRefreshInterval)
            pushPolicy()
        }
    }

    /// Sampling interval while the window or the menu bar panel is visible.
    var foregroundRefreshInterval: ForegroundRefreshInterval {
        didSet {
            guard foregroundRefreshInterval != oldValue else { return }
            defaults.set(foregroundRefreshInterval.rawValue, forKey: PreferenceKey.foregroundRefreshInterval)
            pushPolicy()
        }
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
        sidebarVisibility = defaults.data(forKey: PreferenceKey.sidebarVisibility)
            .flatMap { try? JSONDecoder().decode(SidebarVisibility.self, from: $0) } ?? SidebarVisibility()
        backgroundRefreshInterval = BackgroundRefreshInterval(rawValue: defaults.integer(forKey: PreferenceKey.backgroundRefreshInterval)) ?? .standard
        foregroundRefreshInterval = ForegroundRefreshInterval(rawValue: defaults.integer(forKey: PreferenceKey.foregroundRefreshInterval)) ?? .standard
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
        if isPaused {
            // Bounded: older snapshots than the history holds would be dropped anyway.
            pausedSnapshots.append(snapshot)
            if pausedSnapshots.count > SystemHistory.capacity {
                pausedSnapshots.removeFirst(pausedSnapshots.count - SystemHistory.capacity)
            }
            // The menu bar keeps updating; the pause is about the window's content.
            updateMenuBarLabel(from: snapshot)
            return
        }
        historyStorage.append(snapshot)
        publish(snapshot)
    }

    private func publish(_ snapshot: SystemSnapshot) {
        historyRevision &+= 1
        latestSnapshot = snapshot
        if case .notSampled = snapshot.processes {
            // Keep the previous table.
        } else if visibleSection == .processes {
            latestProcesses = snapshot.processes
        }
        if case .notSampled = snapshot.containers {
            // Keep the previous list.
        } else if visibleSection == .containers {
            latestContainers = snapshot.containers
        }
        if let usb = snapshot.usb.value {
            latestUSB = usb
        }
        updateMenuBarLabel()
    }

    /// Pauses or resumes display updates (Control held down).
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        guard !paused else { return }
        let pending = pausedSnapshots
        pausedSnapshots = []
        for snapshot in pending {
            historyStorage.append(snapshot)
        }
        if let newest = pending.last {
            publish(newest)
        }
    }

    private func updateMenuBarLabel(from snapshot: SystemSnapshot? = nil) {
        let text: String? = switch menuBarMetric {
        case .none:
            nil
        default:
            (snapshot ?? latestSnapshot).flatMap { menuBarMetric.value(in: $0).value } ?? Self.placeholder
        }
        if text != menuBarLabelText {
            menuBarLabelText = text
        }
    }

    /// Shown where a value is missing. The accessible label says "Not Available".
    static let placeholder = "—"

    // MARK: - Sampling policy

    /// Policy derived from what is currently on screen (SPEC §7, §26). The rules live in
    /// `SamplingDemand` (PulseDeckCore), where they are unit tested.
    var samplingPolicy: SamplingPolicy {
        let section: ObservationState.Section? = switch visibleSection {
        case .performance?: .performance
        case .processes?: .processes
        case .containers?: .containers
        case nil: nil
        }
        let state = ObservationState(
            isMainWindowVisible: mainWindowVisibility == .visible,
            visibleSection: section,
            showsResourcePreviewsInEverySection: showsResourcePreviewsInEverySection,
            isMenuBarPanelVisible: isMenuBarWindowVisible,
            menuBarMetricKind: menuBarMetric.requiredMetricKind,
            detailPageDemand: detailPageDemand
        )
        return SamplingDemand.policy(
            for: state,
            foregroundInterval: foregroundRefreshInterval.duration,
            backgroundInterval: .seconds(backgroundRefreshInterval.rawValue)
        )
    }

    private func pushPolicy() {
        commandContinuation.yield(.policy(samplingPolicy))
    }
}
