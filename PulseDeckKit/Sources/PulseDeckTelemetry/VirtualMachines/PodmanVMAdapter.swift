#if os(macOS)
import Foundation
import PulseDeckCore

/// Podman Machine. Listing reads the machine configs below
/// `~/.config/containers/podman/machine/<provider>/<name>.json` and attributes the vfkit / krunkit /
/// QEMU process by its disk image path; no command is run. Start, stop and resource changes run
/// `podman machine …` once (`podman machine set` needs a stopped machine; the UI stops it first).
/// All parsing and planning is in `PodmanVMParsing`.
public struct PodmanVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .podman }

    private static let tools = ["/opt/homebrew/bin/podman", "/usr/local/bin/podman", "/opt/podman/bin/podman", "podman"]
    private static let cellars = ["/opt/homebrew/Cellar/podman", "/usr/local/Cellar/podman"]

    private func configDirectory(in environment: VMEnvironment) -> String {
        ([environment.homeDirectory] + PodmanVMParsing.configDirectoryComponents).joined(separator: "/")
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let fileManager = FileManager.default
        let hasTool = Self.tools.filter { $0.hasPrefix("/") }.contains { fileManager.fileExists(atPath: $0) }
        guard hasTool || fileManager.fileExists(atPath: configDirectory(in: environment)) else { return nil }
        // Homebrew keeps one directory per installed version; the pkg installer leaves no readable version.
        let versions = Self.cellars.flatMap { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }
        return VMProviderInstall(version: PodmanVMParsing.highestVersion(of: versions), note: nil)
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let fileManager = FileManager.default
        let base = configDirectory(in: environment)
        var machines: [PodmanVMParsing.Machine] = []
        for provider in ((try? fileManager.contentsOfDirectory(atPath: base)) ?? []).sorted() {
            let directory = base + "/" + provider
            let files = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
            for file in files {
                guard let data = fileManager.contents(atPath: directory + "/" + file),
                      let machine = PodmanVMParsing.parseMachine(data, provider: provider, fileName: file)
                else { continue }
                machines.append(machine)
            }
        }
        return PodmanVMParsing.records(machines: machines, processes: processes)
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await podmanRun(PodmanVMParsing.actionCommands(action, machine: machine.name), tools: Self.tools, timeout: .seconds(300), runner: environment.runner)
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let commands: [[String]]
        switch PodmanVMParsing.setCommands(machine: machine.name, current: machine.resources, requested: resources) {
        case .success(let planned): commands = planned
        case .failure(let error): return .failure(.failed(Self.message(for: error)))
        }
        let changed = await podmanRun(commands, tools: Self.tools, timeout: .seconds(120), runner: environment.runner)
        guard case .success = changed else { return changed }
        guard restartIfRunning else { return .success(()) }
        return await podmanRun(PodmanVMParsing.actionCommands(.start, machine: machine.name), tools: Self.tools, timeout: .seconds(300), runner: environment.runner)
    }

    private static func message(for error: PodmanVMParsing.EditError) -> String {
        switch error {
        case .invalidCPUCount: "A Podman machine needs at least 1 CPU."
        case .invalidMemory: "A Podman machine needs memory."
        case .diskMustGrow: "Podman can only enlarge a machine's disk, not shrink it."
        }
    }
}

/// Runs the commands in order and stops at the first failure.
private func podmanRun(_ commands: [[String]], tools: [String], timeout: Duration, runner: any VMCommandRunning) async -> Result<Void, VMControlError> {
    for arguments in commands {
        guard let result = await runner.run(tool: tools, arguments: arguments, timeout: timeout) else { return .failure(.providerUnavailable) }
        guard result.succeeded else {
            let text = [result.standardError, result.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return .failure(.failed(String((text ?? "podman exited with status \(result.exitStatus)").prefix(600))))
        }
    }
    return .success(())
}
#endif
