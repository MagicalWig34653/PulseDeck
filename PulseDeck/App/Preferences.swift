import Foundation
import PulseDeckCore

/// `UserDefaults` keys for persisted preferences (SPEC §32).
enum PreferenceKey {
    static let navigationPresentation = "navigationPresentation"
    static let showMainWindowAtLaunch = "showMainWindowAtLaunch"
    static let keepRunningWhenWindowCloses = "keepRunningWhenWindowCloses"
    static let menuBarMetric = "menuBarMetric"
    static let backgroundRefreshInterval = "backgroundRefreshInterval"
    static let foregroundRefreshInterval = "foregroundRefreshInterval"
    /// Charts scroll continuously between samples while the window is active.
    static let smoothChartScrolling = "smoothChartScrolling"
    static let chartGridStyle = "chartGridStyle"
    /// Disks and network interfaces shown/hidden in the Performance list (JSON).
    static let sidebarVisibility = "sidebarVisibility"
    /// Performance page to open at launch (not shown in Settings; used for screenshots).
    static let initialCategory = "initialCategory"
    /// Section to open at launch, `performance` or `processes` (used for screenshots).
    static let initialSection = "initialSection"
}

/// Scene identifiers.
enum SceneID {
    static let mainWindow = "main"
}

/// Main-window navigation presentation (SPEC §8). Persisted.
enum NavigationPresentation: String, CaseIterable, Identifiable {
    case topBar
    case sidebar

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .topBar: "Top Bar"
        case .sidebar: "Sidebar"
        }
    }
}

/// Background sampling interval in seconds, within SPEC §7's 2–5 s range.
enum BackgroundRefreshInterval: Int, CaseIterable, Identifiable {
    case frequent = 2
    case standard = 3
    case economical = 5

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .frequent: "Every 2 seconds"
        case .standard: "Every 3 seconds"
        case .economical: "Every 5 seconds (saves the most energy)"
        }
    }
}

/// Sampling interval while the main window or the menu bar panel is visible, in milliseconds.
enum ForegroundRefreshInterval: Int, CaseIterable, Identifiable {
    case fastest = 500
    case standard = 1000
    case relaxed = 2000
    case slow = 5000

    var id: Self { self }

    var duration: Duration { .milliseconds(rawValue) }

    var title: LocalizedStringResource {
        switch self {
        case .fastest: "Twice a second"
        case .standard: "Every second"
        case .relaxed: "Every 2 seconds"
        case .slow: "Every 5 seconds"
        }
    }
}

/// Background grid of full-size charts.
enum ChartGridStyle: String, CaseIterable, Identifiable {
    /// Task Manager style: a fine grid whose vertical lines move with the data.
    case scrolling
    /// Quarters and fixed 10-second columns.
    case simple

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .scrolling: "Fine, scrolling with the data"
        case .simple: "Simple"
        }
    }
}

/// The optional live metric shown next to the menu bar icon (SPEC §24). New display modes are
/// added as new cases plus a value in `MenuBarMetric.value(in:)`.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none
    case cpu
    case memory
    case gpu
    case networkDownload
    case networkUpload
    /// Battery charge/discharge power (derived). Raw value kept from v0.1 so saved
    /// preferences stay valid.
    case energy
    case batteryCharge

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .none: "Icon Only"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .networkDownload: "Network Download"
        case .networkUpload: "Network Upload"
        case .energy: "Battery Power"
        case .batteryCharge: "Battery Charge"
        }
    }

    /// The demand-driven domain this metric needs sampled while the window is closed.
    var requiredMetricKind: MetricKind? {
        switch self {
        case .none: nil
        case .cpu: .cpu
        case .memory: .memory
        case .gpu: .gpu
        case .networkDownload, .networkUpload: .network
        case .energy, .batteryCharge: .energy
        }
    }
}
