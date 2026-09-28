import SwiftUI

/// Root of the main window. Switches between the top-bar and sidebar navigation
/// presentations (SPEC §8); both are built from native navigation/toolbar containers, which
/// macOS 26 renders with Liquid Glass (SPEC §9).
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PreferenceKey.navigationPresentation) private var presentation: NavigationPresentation = .topBar
    @SceneStorage("selectedSection") private var section: AppSection = .performance
    @SceneStorage("selectedCategory") private var category: ResourceCategory = .cpu

    var body: some View {
        Group {
            switch presentation {
            case .topBar:
                TopBarNavigation(section: $section, category: $category)
            case .sidebar:
                SidebarNavigation(section: $section, category: $category)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background {
            WindowVisibilityObserver { visibility in
                appState.mainWindowVisibility = visibility
            }
        }
        .onChange(of: section, initial: true) {
            appState.visibleSection = section
        }
        .onChange(of: appState.requestedCategory, initial: true) {
            guard let requested = appState.requestedCategory else { return }
            section = .performance
            category = requested
            appState.requestedCategory = nil
        }
        .onChange(of: presentation, initial: true) {
            appState.showsResourcePreviewsInEverySection = presentation == .sidebar
        }
        .onAppear(perform: applyInitialCategory)
    }

    /// Optional `initialCategory` / `initialSection` preferences (e.g. launch arguments
    /// `-initialCategory network`, `-initialSection processes`) open a specific page; used for
    /// automated screenshots.
    private func applyInitialCategory() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: PreferenceKey.initialCategory),
           let initial = ResourceCategory(rawValue: raw) {
            section = .performance
            category = initial
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
    @Binding var category: ResourceCategory

    var body: some View {
        Group {
            switch section {
            case .performance:
                PerformanceView(category: $category)
            case .processes:
                ProcessesView()
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

/// Sidebar presentation: one sidebar lists the performance categories and Processes.
private struct SidebarNavigation: View {
    @Binding var section: AppSection
    @Binding var category: ResourceCategory

    private enum Item: Hashable {
        case performance(ResourceCategory)
        case processes
    }

    private var selection: Binding<Item?> {
        Binding {
            switch section {
            case .performance: .performance(category)
            case .processes: .processes
            }
        } set: { item in
            switch item {
            case .performance(let newCategory)?:
                category = newCategory
                section = .performance
            case .processes?:
                section = .processes
            case nil:
                break
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    ForEach(ResourceCategory.allCases) { category in
                        ResourceListRow(category: category)
                            .tag(Item.performance(category))
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
                    .tag(Item.processes)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            switch section {
            case .performance:
                ResourceDetailView(category: category)
            case .processes:
                ProcessesView()
            }
        }
    }
}
