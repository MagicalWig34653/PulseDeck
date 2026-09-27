import AppKit
import PulseDeckCore
import PulseDeckTelemetry

/// Application lifecycle (SPEC §25, §27): owns the monitoring engine and app state, keeps the
/// app alive in the menu bar when the window closes, switches the Dock presence, forwards
/// sleep/wake and stops monitoring cleanly on quit.
@MainActor
final class AppLifecycleController: NSObject, NSApplicationDelegate {
    let appState: AppState

    override init() {
        // CPU, memory, network and disk collectors. Domains without a collector yet (GPU,
        // energy, processes) are reported as "Not Available", never as fabricated values.
        let engine = MonitoringEngine(providers: DarwinTelemetry.makeProviders())
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
