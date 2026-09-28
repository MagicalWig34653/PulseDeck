import PulseDeckCore
import SwiftUI

/// Preferences (SPEC §32): General (launch at login, window behaviour), Navigation, Sidebar
/// (which disks and interfaces the Performance list shows) and Menu Bar.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Navigation", systemImage: "sidebar.left") {
                NavigationSettings()
            }
            Tab("Sidebar", systemImage: "list.bullet") {
                SidebarSettings()
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

/// Which disks and network interfaces the Performance list shows. Lists every device currently
/// present, including those hidden by default (disk images, loopback, never-used interfaces).
private struct SidebarSettings: View {
    @Environment(AppState.self) private var appState

    private var disks: [DiskSnapshot] { appState.latestSnapshot?.disks.value ?? [] }

    private var interfaces: [NetworkInterfaceSnapshot] {
        (appState.latestSnapshot?.network.value?.interfaces ?? [])
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                if disks.isEmpty {
                    Text("No disks found.").foregroundStyle(.secondary)
                }
                ForEach(disks) { disk in
                    DeviceVisibilityToggle(
                        title: disk.name,
                        detail: [disk.id, disk.connection.label].joined(separator: " · "),
                        systemImage: disk.connection.systemImage,
                        key: SidebarVisibility.key(disk: disk.id),
                        hiddenByDefault: SidebarVisibility.isHiddenByDefault(disk),
                        defaultReason: "Disk images are hidden by default."
                    )
                }
            } header: {
                Text("Disks")
            }
            Section {
                ForEach(interfaces) { interface in
                    DeviceVisibilityToggle(
                        title: interface.title,
                        detail: [interface.id, interface.kind.label].joined(separator: " · "),
                        systemImage: interface.kind.systemImage,
                        key: SidebarVisibility.key(networkInterface: interface.id),
                        hiddenByDefault: SidebarVisibility.isHiddenByDefault(interface),
                        defaultReason: "Loopback and interfaces that have never carried traffic are hidden by default."
                    )
                }
            } header: {
                Text("Network Interfaces")
            } footer: {
                HStack {
                    Text("Hidden devices are still monitored. You can also hide a device from its context menu in the Performance list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        appState.sidebarVisibility = SidebarVisibility()
                    }
                    .disabled(!appState.sidebarVisibility.hasOverrides)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 360)
    }
}

private struct DeviceVisibilityToggle: View {
    @Environment(AppState.self) private var appState
    let title: String
    let detail: String
    let systemImage: String
    let key: String
    let hiddenByDefault: Bool
    let defaultReason: LocalizedStringResource

    var body: some View {
        Toggle(isOn: Binding(
            get: { appState.sidebarVisibility.isVisible(key, hiddenByDefault: hiddenByDefault) },
            set: { appState.sidebarVisibility.setVisible($0, key, hiddenByDefault: hiddenByDefault) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .help(hiddenByDefault ? Text(defaultReason) : Text(verbatim: ""))
    }
}
