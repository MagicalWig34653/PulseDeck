/// What is currently on screen, as far as sampling is concerned (SPEC §7, §24, §26).
public struct ObservationState: Hashable, Sendable {
    /// The primary section shown in the main window.
    public enum Section: Hashable, Sendable {
        case performance
        case processes
        case containers
        case usb
    }

    /// The main window is at least partly visible (not closed, minimised or fully covered).
    public var isMainWindowVisible: Bool
    /// Section shown in the main window, `nil` before the window reported one.
    public var visibleSection: Section?
    /// Resource previews (list rows with live values and sparklines) are on screen even outside
    /// the Performance section — the sidebar presentation lists them next to Processes.
    public var showsResourcePreviewsInEverySection: Bool
    /// The menu bar extra's panel is open.
    public var isMenuBarPanelVisible: Bool
    /// Domain needed by the live metric in the menu bar, if one is selected.
    public var menuBarMetricKind: MetricKind?
    /// Extra domains the Performance page on screen needs beyond the list previews (CPU page →
    /// frequency, Tailscale interface → peers, Memory page pie chart → processes).
    public var detailPageDemand: Set<MetricKind>

    public init(isMainWindowVisible: Bool = false, visibleSection: Section? = nil, showsResourcePreviewsInEverySection: Bool = false, isMenuBarPanelVisible: Bool = false, menuBarMetricKind: MetricKind? = nil, detailPageDemand: Set<MetricKind> = []) {
        self.isMainWindowVisible = isMainWindowVisible
        self.visibleSection = visibleSection
        self.showsResourcePreviewsInEverySection = showsResourcePreviewsInEverySection
        self.isMenuBarPanelVisible = isMenuBarPanelVisible
        self.menuBarMetricKind = menuBarMetricKind
        self.detailPageDemand = detailPageDemand
    }
}

/// Derives the sampling policy from what is on screen. Kept in the core so the rules — reduced
/// background sampling, demand-driven GPU/energy/process collection — are unit tested.
public enum SamplingDemand {
    /// - Foreground (1 Hz) while the main window or the menu bar panel is visible: the user is
    ///   looking at live values. Otherwise background (2–5 s, `backgroundInterval`).
    /// - GPU and energy only while their previews are visible (Performance section, sidebar
    ///   previews, menu bar panel) or the menu bar metric needs them.
    /// - Processes only while the Processes section is visible (the most expensive collector).
    public static func policy(
        for state: ObservationState,
        foregroundInterval: Duration = SamplingPolicy.defaultForegroundInterval,
        backgroundInterval: Duration = SamplingPolicy.defaultBackgroundInterval
    ) -> SamplingPolicy {
        var demand: Set<MetricKind> = []
        if state.isMainWindowVisible, let section = state.visibleSection {
            if section == .performance || state.showsResourcePreviewsInEverySection {
                demand.formUnion([.gpu, .energy])
            }
            if section == .processes {
                demand.insert(.processes)
            }
            if section == .containers {
                demand.insert(.containers)
            }
            if section == .usb {
                demand.insert(.usb)
            }
            if section == .performance {
                demand.formUnion(state.detailPageDemand)
            }
        }
        if state.isMenuBarPanelVisible {
            demand.formUnion([.gpu, .energy])
        }
        if let kind = state.menuBarMetricKind, !MetricKind.alwaysSampled.contains(kind) {
            demand.insert(kind)
        }
        let isForeground = state.isMainWindowVisible || state.isMenuBarPanelVisible
        return SamplingPolicy(
            mode: isForeground ? .foreground : .background,
            foregroundInterval: foregroundInterval,
            backgroundInterval: backgroundInterval,
            demand: demand
        )
    }
}
