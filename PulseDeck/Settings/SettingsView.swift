import SwiftUI

/// Preferences (SPEC §32): General (launch at login, window behaviour), Navigation and Menu Bar.
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
    @State private var loginItem = LoginItemController()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.requiresApproval {
                    HStack {
                        Label("Allow PulseDeck in System Settings to finish turning this on.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                    .font(.callout)
                }
                if let error = loginItem.lastError {
                    Label {
                        Text("Launch at login could not be changed: \(error)")
                    } icon: {
                        Image(systemName: "xmark.octagon")
                    }
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Show main window at launch", isOn: $showMainWindowAtLaunch)
                Toggle("Keep running when window closes", isOn: $keepRunningWhenWindowCloses)
            } footer: {
                Text("When the window is closed, PulseDeck stays in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
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
            Section {
                Picker("Menu bar metric", selection: $appState.menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
            } footer: {
                Text("Battery Power is the battery's charge (+) or discharge (−) power, derived from voltage × current — not the Mac's total power use. Battery metrics need a Mac with a battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Refresh in background", selection: $appState.backgroundRefreshInterval) {
                    ForEach(BackgroundRefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            } footer: {
                Text("While the main window and the menu bar panel are closed, metrics refresh less often to save energy. GPU, energy and process data are then collected only if the menu bar metric needs them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
