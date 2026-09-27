import AppKit
import PulseDeckCore

/// Application lifecycle (SPEC §25, §27): owns the monitoring engine and app state, keeps the
/// app alive in the menu bar when the window closes, switches the Dock presence, forwards
/// sleep/wake and stops monitoring cleanly on quit.
@MainActor
final class AppLifecycleController: NSObject, NSApplicationDelegate {
    let appState: AppState

    override init() {
        // Milestone 1 registers no collectors: every metric is reported as
        // `.unavailable(.notImplemented)` ("Not Available"), never as a fabricated value.
        // Darwin collectors are added to `TelemetryProviders` from Milestone 2 onwards.
        let engine = MonitoringEngine(providers: .none)
        appState = AppState(engine: engine)
        super.init()
        appState.onMainWindowOpenChanged = { isOpen in
            // Dock icon only while the main window is open; menu bar item always.
            NSApp.setActivationPolicy(isOpen ? .regular : .accessory)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let showWindow = UserDefaults.standard.object(forKey: PreferenceKey.showMainWindowAtLaunch) as? Bool ?? true
        if !showWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        appState.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let keepRunning = UserDefaults.standard.object(forKey: PreferenceKey.keepRunningWhenWindowCloses) as? Bool ?? true
        return !keepRunning
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the sampling loop before exiting so no work is in flight during teardown.
        Task {
            await appState.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        appState.systemWillSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        appState.systemDidWake()
    }
}
