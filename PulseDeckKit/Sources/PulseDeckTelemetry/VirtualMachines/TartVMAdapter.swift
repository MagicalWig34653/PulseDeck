#if os(macOS)
import Foundation
import PulseDeckCore

/// Tart (cirruslabs/tart). VMs are directories `~/.tart/vms/<name>/` with `config.json`,
/// `disk.img` (sparse; its logical length is the disk size), `nvram.bin` and, when suspended,
/// `state.vzvmsave`. Everything is read from files and the host process table
/// (`tart run <name>`), no tool is run to list. `TART_HOME` is not honoured: the app does not
/// see the user's shell environment.
public struct TartVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.tart

    private static let tools = ["tart", "/opt/homebrew/bin/tart", "/usr/local/bin/tart", "/Applications/Tart.app/Contents/MacOS/tart"]

    public init() {}

    private func vmsDirectory(_ environment: VMEnvironment) -> String {
        environment.homeDirectory + "/.tart/vms"
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let hasTool = Self.tools.contains { $0.hasPrefix("/") && VMProviderFiles.isExecutable($0) }
        guard hasTool || VMProviderFiles.isDirectory(vmsDirectory(environment)) else { return nil }
        return VMProviderInstall(version: VMProviderFiles.appVersion(bundlePath: "/Applications/Tart.app"), note: nil)
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let root = vmsDirectory(environment)
        return VMProviderFiles.entries(in: root).compactMap { name -> VMRecord? in
            let directory = root + "/" + name
            guard VMProviderFiles.isDirectory(directory),
                  let data = VMProviderFiles.data(at: directory + "/config.json"),
                  let config = TartParsing.parseConfig(data) else { return nil }
            return TartParsing.makeRecord(
                name: name,
                config: config,
                diskBytes: VMProviderFiles.fileSize(at: directory + "/disk.img"),
                hasSavedState: VMProviderFiles.exists(directory + "/state.vzvmsave"),
                directory: directory,
                processes: processes
            )
        }
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let name = VMProviderFiles.nativeID(of: machine)
        switch action {
        case .start:
            return await start(name)
        case .stop:
            // `tart stop` waits up to 30 s for a graceful exit before killing the VM.
            return await stop(name, in: environment)
        case .restart:
            if machine.state == .running {
                let stopped = await stop(name, in: environment)
                if case .failure = stopped { return stopped }
            }
            return await start(name)
        }
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let name = VMProviderFiles.nativeID(of: machine)
        if let arguments = TartParsing.setArguments(name: name, new: resources, current: machine.resources) {
            let result = VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(120)))
            if case .failure = result { return result }
        }
        return restartIfRunning ? await start(name) : .success(())
    }

    private func stop(_ name: String, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: TartParsing.stopArguments(name: name), timeout: .seconds(90)))
    }

    /// `tart run` stays in the foreground for as long as the VM lives, so the command runner
    /// (which waits for the tool to exit) cannot start it. The VM process is launched here,
    /// detached from the app (no stdin/stdout, stderr into a temporary file), and the call
    /// returns when it has survived the first seconds or failed.
    private func start(_ name: String) async -> Result<Void, VMControlError> {
        guard let executable = Self.tools.first(where: { $0.hasPrefix("/") && VMProviderFiles.isExecutable($0) }) else {
            return .failure(.providerUnavailable)
        }
        return await DetachedLauncher.launch(executable: executable, arguments: TartParsing.startArguments(name: name))
    }
}

/// Starts a long-running tool and reports an early failure (non-zero exit within a few seconds).
private enum DetachedLauncher {
    private static let observation: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(100)

    static func launch(executable: String, arguments: [String]) async -> Result<Void, VMControlError> {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pulsedeck-vm-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return .failure(.failed("Could not create a temporary log file."))
        }
        // The child keeps its open descriptor after the file is unlinked.
        defer {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let deadline = ContinuousClock.now + observation
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        if process.isRunning || process.terminationStatus == 0 { return .success(()) }

        let message = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(.failed(message.isEmpty ? "The VM exited with status \(process.terminationStatus)." : message))
    }
}
#endif
