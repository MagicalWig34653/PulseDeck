import AppKit
import PulseDeckCore
import PulseDeckTelemetry
import UniformTypeIdentifiers

/// Process actions (SPEC §22). Destructive actions are confirmed by `ProcessesView` first.
@MainActor
enum ProcessActions {
    /// Quits (or force quits) `process`.
    ///
    /// Apps are asked through `NSRunningApplication` so they can show their own unsaved-changes
    /// prompts; everything else receives `SIGTERM` / `SIGKILL`. `ProcessControl` re-checks the
    /// PID's start time first, so a PID that was reused since the last sample is left alone.
    static func quit(_ process: ProcessSnapshot, force: Bool) -> Result<Void, ProcessControlError> {
        guard ProcessControl.isRunning(process.identity) else { return .failure(.processExited) }
        if let app = NSRunningApplication(processIdentifier: process.pid),
           force ? app.forceTerminate() : app.terminate() {
            return .success(())
        }
        return ProcessControl.send(force ? .kill : .terminate, to: process.identity)
    }

    /// Reveals the process's app bundle (or executable) in Finder.
    static func showInFinder(_ process: ProcessSnapshot) {
        guard let path = process.path else { return }
        let target = bundlePath(containing: path) ?? path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    static func copyPIDs(of processes: [ProcessSnapshot]) {
        copy(processes.map { String($0.pid) }.joined(separator: "\n"))
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Innermost `.app` bundle containing `path`, e.g. a helper app inside another app.
    static func bundlePath(containing path: String) -> String? {
        let marker = ".app/Contents/"
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        let appSuffixLength = ".app".count
        return String(path[..<path.index(range.lowerBound, offsetBy: appSuffixLength)])
    }
}

/// App icons for process rows, cached per bundle so scrolling and per-second updates do not
/// hit the icon services repeatedly. Bounded; cleared when full.
@MainActor
final class ProcessIconCache {
    private static let capacity = 512
    private var icons: [String: NSImage] = [:]
    private let executableIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for process: ProcessSnapshot) -> NSImage {
        guard let bundle = process.path.flatMap(ProcessActions.bundlePath(containing:)) else {
            return executableIcon
        }
        if let icon = icons[bundle] { return icon }
        if icons.count >= Self.capacity {
            icons.removeAll(keepingCapacity: true)
        }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        icons[bundle] = icon
        return icon
    }
}
