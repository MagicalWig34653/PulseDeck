import SwiftUI

@main
struct PulseDeckApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleController.self) private var lifecycle
    @AppStorage(PreferenceKey.showMainWindowAtLaunch) private var showMainWindowAtLaunch = true

    var body: some Scene {
        Window("PulseDeck", id: SceneID.mainWindow) {
            MainWindowView()
                .environment(lifecycle.appState)
        }
        .defaultSize(width: 980, height: 640)
        .defaultLaunchBehavior(showMainWindowAtLaunch ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarContentView()
                .environment(lifecycle.appState)
        } label: {
            MenuBarLabel()
                .environment(lifecycle.appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(lifecycle.appState)
        }
    }
}
