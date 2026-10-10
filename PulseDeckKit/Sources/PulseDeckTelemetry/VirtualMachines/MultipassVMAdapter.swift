#if os(macOS)
import Foundation
import PulseDeckCore

/// Multipass (Canonical). Its instance data lives below a root-owned daemon directory
/// (`/var/root/Library/Application Support/multipassd`), so there are no files a normal user can
/// read. Listing therefore uses the `multipass` command-line tool (`list --format json`, then
/// `info --format json`), throttled by `minimumListInterval`. All parsing and planning is in
/// `MultipassVMParsing`.
public struct MultipassVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .multipass }

    /// Every listing spawns the Multipass CLI (and through it a daemon request), so the monitor
    /// must not do it on every sample.
    public var minimumListInterval: Duration { .seconds(10) }

    private static let tools = ["/usr/local/bin/multipass", "/opt/homebrew/bin/multipass", "multipass"]
    private static let appBundle = "/Applications/Multipass.app"
    private static let supportDirectory = "/Library/Application Support/com.canonical.multipass"

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let fileManager = FileManager.default
        let installed = (Self.tools.filter { $0.hasPrefix("/") } + [Self.appBundle, Self.supportDirectory])
            .contains { fileManager.fileExists(atPath: $0) }
        guard installed else { return nil }
        return VMProviderInstall(version: multipassBundleVersion(atPath: Self.appBundle + "/Contents/Info.plist"), note: nil)
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        guard let listed = await environment.runner.run(tool: Self.tools, arguments: MultipassVMParsing.listArguments, timeout: .seconds(20)),
              listed.succeeded,
              let instances = MultipassVMParsing.parseList(Data(listed.standardOutput.utf8))
        else { return [] }

        let names = instances.filter { MultipassVMParsing.vmState(forStatus: $0.status) != nil }.map(\.name)
        var info: [String: MultipassVMParsing.InstanceInfo] = [:]
        if !names.isEmpty { info = await loadInfo(names: names, runner: environment.runner) }
        return MultipassVMParsing.records(list: instances, info: info, processes: processes)
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await multipassRun(MultipassVMParsing.actionCommands(action, instance: machine.name), tools: Self.tools, timeout: .seconds(300), runner: environment.runner)
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let commands: [[String]]
        switch MultipassVMParsing.setCommands(instance: machine.name, current: machine.resources, requested: resources) {
        case .success(let planned): commands = planned
        case .failure(let error): return .failure(.failed(Self.message(for: error)))
        }
        let changed = await multipassRun(commands, tools: Self.tools, timeout: .seconds(120), runner: environment.runner)
        guard case .success = changed else { return changed }
        guard restartIfRunning else { return .success(()) }
        return await multipassRun(MultipassVMParsing.actionCommands(.start, instance: machine.name), tools: Self.tools, timeout: .seconds(300), runner: environment.runner)
    }

    /// `multipass info` for all instances. The hidden `--no-runtime-information` flag spares an
    /// SSH round trip into every running instance; if this Multipass version rejects it the call is
    /// repeated without. Failure leaves the resources unknown, never invented.
    private func loadInfo(names: [String], runner: any VMCommandRunning) async -> [String: MultipassVMParsing.InstanceInfo] {
        for skipRuntime in [true, false] {
            let arguments = MultipassVMParsing.infoArguments(names: names, skipRuntimeInformation: skipRuntime)
            if let result = await runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(30)),
               result.succeeded,
               let info = MultipassVMParsing.parseInfo(Data(result.standardOutput.utf8)) {
                return info
            }
        }
        return [:]
    }

    private static func message(for error: MultipassVMParsing.EditError) -> String {
        switch error {
        case .invalidCPUCount: "Multipass needs at least 1 CPU."
        case .memoryBelowMinimum: "Multipass needs at least 512 MiB of memory."
        case .diskBelowMinimum: "Multipass needs at least 1 GiB of disk."
        case .diskCannotShrink: "Multipass can only enlarge a disk, not shrink it."
        }
    }
}

/// Runs the commands in order and stops at the first failure.
private func multipassRun(_ commands: [[String]], tools: [String], timeout: Duration, runner: any VMCommandRunning) async -> Result<Void, VMControlError> {
    for arguments in commands {
        guard let result = await runner.run(tool: tools, arguments: arguments, timeout: timeout) else { return .failure(.providerUnavailable) }
        guard result.succeeded else {
            let text = [result.standardError, result.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return .failure(.failed(String((text ?? "multipass exited with status \(result.exitStatus)").prefix(600))))
        }
    }
    return .success(())
}

/// `CFBundleShortVersionString` of an app bundle's Info.plist, read without running the app.
private func multipassBundleVersion(atPath path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty
    else { return nil }
    return version
}
#endif
