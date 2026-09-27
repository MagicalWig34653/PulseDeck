import AppKit
import SwiftUI

/// Reports whether the hosting window is visible, occluded or closed, so sampling can drop to
/// the background rate when nobody can see the window (SPEC §7, §26).
///
/// A zero-size AppKit view is used because SwiftUI does not expose window occlusion. AppKit
/// posts `didChangeOcclusionStateNotification` when the window is minimised, moved to another
/// Space, fully covered or the screen is locked/asleep.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (WindowVisibility) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((WindowVisibility) -> Void)?
        private weak var observedWindow: NSWindow?
        private var lastReported: WindowVisibility?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observedWindow {
                center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
                center.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
            }
            observedWindow = window
            guard let window else {
                report(.closed)
                return
            }
            center.addObserver(self, selector: #selector(occlusionStateChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
            reportCurrentState()
        }

        @objc private func occlusionStateChanged(_ notification: Notification) {
            reportCurrentState()
        }

        @objc private func windowWillClose(_ notification: Notification) {
            report(.closed)
        }

        private func reportCurrentState() {
            guard let window else { return }
            report(window.occlusionState.contains(.visible) ? .visible : .occluded)
        }

        private func report(_ visibility: WindowVisibility) {
            guard visibility != lastReported else { return }
            lastReported = visibility
            // Deliver outside AppKit's layout/SwiftUI update pass: the callback mutates
            // observable app state.
            // The callback is captured strongly: the view may already be gone when a close is
            // delivered, and that event must not be lost.
            let callback = onChange
            Task { @MainActor in
                callback?(visibility)
            }
        }
    }
}
