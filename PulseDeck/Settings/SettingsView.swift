import SwiftUI

/// Preferences (SPEC §32). Launch at Login is added in Milestone 11 (SPEC §33).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Navigation", systemImage: "sidebar.left") {
                NavigationSettings()
            }
            Tab("Menu Bar", systemImage: "menubar.rectangle") {
                MenuBarSettings()
            }
        }
        .frame(width: 440)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PreferenceKey.showMainWindowAtLaunch) private var showMainWindowAtLaunch = true
    @AppStorage(PreferenceKey.keepRunningWhenWindowCloses) private var keepRunningWhenWindowCloses = true

    var body: some View {
        Form {
            Toggle("Show main window at launch", isOn: $showMainWindowAtLaunch)
            Toggle("Keep running when window closes", isOn: $keepRunningWhenWindowCloses)
        }
        .formStyle(.grouped)
    }
}

private struct NavigationSettings: View {
    @AppStorage(PreferenceKey.navigationPresentation) private var presentation: NavigationPresentation = .topBar

    var body: some View {
        Form {
            Picker("Navigation style", selection: $presentation) {
                ForEach(NavigationPresentation.allCases) { presentation in
                    Text(presentation.title).tag(presentation)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        Form {
            Picker("Menu bar metric", selection: $appState.menuBarMetric) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            Text("While the main window is closed, metrics refresh every few seconds to save energy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
