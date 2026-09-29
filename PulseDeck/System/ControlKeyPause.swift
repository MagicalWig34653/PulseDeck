import AppKit
import SwiftUI

/// Holding Control (alone) pauses display updates, as in Windows Task Manager, so a value or a
/// process row can be read without it changing. Releasing Control, leaving the app or closing the
/// window resumes.
struct ControlKeyPause: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear {
                remove()
                appState.setPaused(false)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                appState.setPaused(false)
            }
    }

    private func install() {
        guard monitor == nil else { return }
        let state = appState
        // Local monitors run on the main thread for events delivered to this app.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
            MainActor.assumeIsolated {
                state.setPaused(modifiers == .control)
            }
            return event
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
