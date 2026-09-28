import Foundation
import PulseDeckCore

/// `UserDefaults` keys for persisted preferences (SPEC §32).
enum PreferenceKey {
    static let navigationPresentation = "navigationPresentation"
    static let showMainWindowAtLaunch = "showMainWindowAtLaunch"
    static let keepRunningWhenWindowCloses = "keepRunningWhenWindowCloses"
    static let menuBarMetric = "menuBarMetric"
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

/// The optional live metric shown next to the menu bar icon (SPEC §24). New display modes are
/// added as new cases plus a value in `MenuBarMetric.value(in:)`.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none
    case cpu
    case memory
    case gpu
    case networkDownload
    case networkUpload
    case energy

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .none: "Icon Only"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .networkDownload: "Network Download"
        case .networkUpload: "Network Upload"
        case .energy: "Energy"
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
        case .energy: .energy
        }
    }
}
