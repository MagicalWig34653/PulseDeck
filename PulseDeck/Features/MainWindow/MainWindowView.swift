import SwiftUI

/// Root of the main window. Switches between the top-bar and sidebar navigation
/// presentations (SPEC §8); both are built from native navigation/toolbar containers, which
/// macOS 26 renders with Liquid Glass (SPEC §9).
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PreferenceKey.navigationPresentation) private var presentation: NavigationPresentation = .topBar
    @SceneStorage("selectedSection") private var section: AppSection = .performance
    @SceneStorage("selectedPerformanceItem") private var item: PerformanceItem = .category(.cpu)
    @AppStorage(PreferenceKey.smoothChartScrolling) private var smoothChartScrolling = true
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch presentation {
            case .topBar:
                TopBarNavigation(section: $section, item: $item)
            case .sidebar:
                SidebarNavigation(section: $section, item: $item)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .environment(\.chartScrollInterval, chartScrollInterval)
        .overlay(alignment: .bottom) {
            if appState.isPaused {
                PausedIndicator()
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .modifier(ControlKeyPause())
        .background {
            WindowVisibilityObserver { visibility in
                appState.mainWindowVisibility = visibility
            }
        }
        .onChange(of: section, initial: true) {
            appState.visibleSection = section
        }
        .onChange(of: appState.requestedItem, initial: true) {
            guard let requested = appState.requestedItem else { return }
            section = .performance
            item = requested
            appState.requestedItem = nil
        }
        .onChange(of: presentation, initial: true) {
            appState.showsResourcePreviewsInEverySection = presentation == .sidebar
        }
        .onAppear(perform: applyInitialCategory)
    }

    /// Smooth scrolling runs only while the window is in the foreground (active and visible),
    /// not while paused, and never with Reduce Motion.
    private var chartScrollInterval: Double? {
        guard smoothChartScrolling, appearsActive, !reduceMotion, !appState.isPaused,
              appState.mainWindowVisibility == .visible else { return nil }
        return appState.foregroundRefreshInterval.duration.secondsDouble
    }

    /// Optional `initialCategory` / `initialSection` preferences (e.g. launch arguments
    /// `-initialCategory network`, `-initialSection processes`) open a specific page; used for
    /// automated screenshots.
    private func applyInitialCategory() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: PreferenceKey.initialCategory),
           let initial = ResourceCategory(rawValue: raw) {
            section = .performance
            item = .category(initial)
        }
        if let raw = defaults.string(forKey: PreferenceKey.initialSection),
           let initial = AppSection(rawValue: raw) {
            section = initial
        }
    }
}

/// Top-bar presentation: the section picker lives in the window toolbar.
private struct TopBarNavigation: View {
    @Binding var section: AppSection
    @Binding var item: PerformanceItem

    var body: some View {
        Group {
            switch section {
            case .performance:
                PerformanceView(item: $item)
            case .processes:
                ProcessesView()
            case .containers:
                ContainersView()
            case .usb:
                USBView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(AppSection.allCases) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            Image(systemName: section.systemImage)
                        }
                        .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// Sidebar presentation: one sidebar lists the Performance entries (each disk and network
/// interface individually) and Processes.
private struct SidebarNavigation: View {
    @Environment(AppState.self) private var appState
    @Binding var section: AppSection
    @Binding var item: PerformanceItem

    private enum Entry: Hashable {
        case performance(PerformanceItem)
        case processes
        case containers
        case usb
    }

    private var selection: Binding<Entry?> {
        Binding {
            switch section {
            case .performance: .performance(appState.resolve(item))
            case .processes: .processes
            case .containers: .containers
            case .usb: .usb
            }
        } set: { entry in
            switch entry {
            case .performance(let newItem)?:
                item = newItem
                section = .performance
            case .processes?:
                section = .processes
            case .containers?:
                section = .containers
            case .usb?:
                section = .usb
            case nil:
                break
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(appState.performanceItems) { item in
                        PerformanceItemRow(item: item)
                            .tag(Entry.performance(item))
                    }
                } header: {
                    Text(AppSection.performance.title)
                }
                Section {
                    Label {
                        Text(AppSection.processes.title)
                    } icon: {
                        Image(systemName: AppSection.processes.systemImage)
                    }
                    .tag(Entry.processes)
                    Label {
                        Text(AppSection.containers.title)
                    } icon: {
                        Image(systemName: AppSection.containers.systemImage)
                    }
                    .tag(Entry.containers)
                    Label {
                        Text(AppSection.usb.title)
                    } icon: {
                        Image(systemName: AppSection.usb.systemImage)
                    }
                    .tag(Entry.usb)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            switch section {
            case .performance:
                ResourceDetailView(item: appState.resolve(item))
            case .processes:
                ProcessesView()
            case .containers:
                ContainersView()
            case .usb:
                USBView()
            }
        }
    }
}

/// Shown while Control is held and updates are paused.
private struct PausedIndicator: View {
    var body: some View {
        Label("Updates paused — release Control to resume", systemImage: "pause.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
