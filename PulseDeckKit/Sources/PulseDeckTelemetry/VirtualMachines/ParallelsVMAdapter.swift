#if os(macOS)
import Foundation
import PulseDeckCore

/// Parallels Desktop. No readable registry of the registered VMs was found (the list lives in
/// Parallels' service, not in a documented file), so, as the one exception to "list from files",
/// the documented `prlctl list -a -i --json` is used, throttled to one call per
/// `minimumListInterval`. When `prlctl` cannot be run, `~/Parallels/*.pvm/config.pvs` (the
/// default VM folder) is read instead, which lists VMs as running or stopped only.
public struct ParallelsVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.parallels

    /// `prlctl` spawns a process and talks to the Parallels service; keep it infrequent.
    public var minimumListInterval: Duration { .seconds(5) }

    private static let app = "/Applications/Parallels Desktop.app"
    private static let tools = ["prlctl", "/usr/local/bin/prlctl", app + "/Contents/MacOS/prlctl"]

    public init() {}

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMProviderFiles.isDirectory(Self.app) || VMProviderFiles.isDirectory(environment.homeDirectory + "/Parallels") else { return nil }
        return VMProviderInstall(version: VMProviderFiles.appVersion(bundlePath: Self.app), note: nil)
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let result = await environment.runner.run(tool: Self.tools, arguments: ParallelsParsing.listArguments, timeout: .seconds(15))
        if let result, result.succeeded {
            return ParallelsParsing.parseList(result.standardOutput).map { ParallelsParsing.makeRecord($0, processes: processes) }
        }
        return bundleMachines(in: environment).map { ParallelsParsing.makeRecord($0, processes: processes) }
    }

    /// Fallback: the `.pvm` bundles of the default folder.
    private func bundleMachines(in environment: VMEnvironment) -> [ParallelsParsing.Machine] {
        let root = environment.homeDirectory + "/Parallels"
        return VMProviderFiles.entries(in: root).compactMap { entry -> ParallelsParsing.Machine? in
            guard entry.hasSuffix(".pvm") else { return nil }
            let bundle = root + "/" + entry
            guard let data = VMProviderFiles.data(at: bundle + "/config.pvs") else { return nil }
            return ParallelsParsing.parsePVS(data, bundlePath: bundle)
        }
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        // `prlctl restart` only works on a running VM; anything else is simply started.
        let effective: VMAction = (action == .restart && machine.state != .running) ? .start : action
        let arguments = ParallelsParsing.arguments(for: effective, uuid: VMProviderFiles.nativeID(of: machine))
        return VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(180)))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        for arguments in ParallelsParsing.setCommands(uuid: uuid, new: resources, current: machine.resources) {
            let result = VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(300)))
            if case .failure = result { return result }
        }
        if restartIfRunning {
            return VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: ParallelsParsing.arguments(for: .start, uuid: uuid), timeout: .seconds(180)))
        }
        return .success(())
    }
}
#endif
