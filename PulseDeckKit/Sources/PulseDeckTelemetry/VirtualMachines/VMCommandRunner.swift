#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// Runs vendor command-line tools: an explicit executable (`Process`, no shell), an argument
/// array, a minimal environment, a timeout that kills the process, and both output streams read
/// concurrently so a chatty tool cannot deadlock on a full pipe.
///
/// The work happens on a dispatch queue thread, never on the cooperative pool or an actor's
/// executor: a tool may run for minutes (`colima start` downloads an image).
public struct VMCommandRunner: VMCommandRunning {
    /// Exit status reported when the timeout killed the tool (the convention of `timeout(1)`).
    public static let timedOutStatus: Int32 = 124
    /// Exit status when the executable exists but could not be launched (shell convention).
    public static let launchFailedStatus: Int32 = 126
    /// Output kept per stream; the rest is read and discarded so the tool is never blocked.
    private static let outputLimit = 4 * 1024 * 1024
    /// After SIGTERM the tool gets this long before SIGKILL.
    private static let terminationGrace: TimeInterval = 3
    /// After the tool exited, wait this long for the pipes to reach EOF (a background child that
    /// inherited them can keep them open indefinitely).
    private static let drainGrace: TimeInterval = 2

    private let homeDirectory: String

    public init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    public func run(tool candidates: [String], arguments: [String], timeout: Duration) async -> VMCommandResult? {
        await run(plan: VMCommandPlan(tool: candidates, arguments: arguments, timeout: timeout))
    }

    /// Runs a plan, including its extra environment variables (e.g. `LIMA_HOME`). `nil` when none
    /// of the plan's tools exists.
    public func run(plan: VMCommandPlan) async -> VMCommandResult? {
        let home = homeDirectory
        let paths = VMToolLocator.resolvedCandidates(plan.tool, home: home)
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let environment = VMToolLocator.childEnvironment(home: home, userName: NSUserName(), temporaryDirectory: NSTemporaryDirectory())
            .merging(plan.environment) { _, new in new }
        let seconds = max(1, plan.timeout.secondsDouble)
        let arguments = plan.arguments
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executable: executable, arguments: arguments, environment: environment, home: home, timeout: seconds))
            }
        }
    }

    // MARK: - Blocking implementation

    private static func runBlocking(executable: String, arguments: [String], environment: [String: String], home: String, timeout: TimeInterval) -> VMCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return VMCommandResult(exitStatus: launchFailedStatus, standardOutput: "", standardError: "Could not launch \(executable): \(error.localizedDescription)")
        }

        let output = LockedBuffer(limit: outputLimit)
        let errors = LockedBuffer(limit: outputLimit)
        let readers = DispatchGroup()
        for (handle, buffer) in [(outputPipe.fileHandleForReading, output), (errorPipe.fileHandleForReading, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                }
                readers.leave()
            }
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()  // SIGTERM
            if finished.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + terminationGrace)
            }
        }
        _ = readers.wait(timeout: .now() + drainGrace)

        var message = errors.string
        if timedOut {
            let note = "Timed out after \(Int(timeout)) s and was stopped."
            message = message.isEmpty ? note : message + "\n" + note
        }
        return VMCommandResult(
            exitStatus: timedOut ? timedOutStatus : process.terminationStatus,
            standardOutput: output.string,
            standardError: message
        )
    }
}

/// Output collected from a reader thread.
private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
