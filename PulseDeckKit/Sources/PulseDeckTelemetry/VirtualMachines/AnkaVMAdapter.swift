#if os(macOS)
import Foundation
import PulseDeckCore

/// Veertu Anka. The VM library under `~/.anka` is not a documented, stable interface, so this is
/// the one provider (with Parallels) that lists through its CLI: `anka --machine-readable list`
/// plus one `anka --machine-readable show <uuid>` per VM for CPU / RAM / disk, throttled to one
/// refresh per `minimumListInterval`. Host process attribution is not offered (Anka documents no
/// mapping from its processes to VMs), so usage stays unavailable.
public struct AnkaVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.anka

    public var minimumListInterval: Duration { .seconds(10) }

    private static let app = "/Applications/Anka.app"
    private static let tools = ["anka", "/usr/local/bin/anka", "/opt/homebrew/bin/anka"]
    /// Upper bound of `show` calls per refresh.
    private static let maximumVMs = 64

    public init() {}

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let hasTool = Self.tools.contains { $0.hasPrefix("/") && VMProviderFiles.isExecutable($0) }
        guard hasTool || VMProviderFiles.isDirectory(Self.app) || VMProviderFiles.isDirectory(environment.homeDirectory + "/.anka") else { return nil }
        return VMProviderInstall(version: VMProviderFiles.appVersion(bundlePath: Self.app), note: "Host CPU / memory use per VM is not available.")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let runner = environment.runner
        guard let listing = await runner.run(tool: Self.tools, arguments: AnkaParsing.listArguments, timeout: .seconds(15)), listing.succeeded else { return [] }
        let entries = AnkaParsing.parseList(listing.standardOutput)
        let limited = Array(entries.prefix(Self.maximumVMs))

        let properties = await withTaskGroup(of: (String, AnkaParsing.Properties?).self) { group in
            for entry in limited {
                group.addTask {
                    let result = await runner.run(tool: Self.tools, arguments: AnkaParsing.showArguments(uuid: entry.uuid), timeout: .seconds(10))
                    guard let result, result.succeeded else { return (entry.uuid, nil) }
                    return (entry.uuid, AnkaParsing.parseShow(result.standardOutput))
                }
            }
            var collected: [String: AnkaParsing.Properties] = [:]
            for await (uuid, value) in group {
                if let value { collected[uuid] = value }
            }
            return collected
        }
        return limited.map { AnkaParsing.makeRecord($0, properties: properties[$0.uuid]) }
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        switch action {
        case .start:
            return await run(AnkaParsing.startArguments(uuid: uuid), timeout: .seconds(180), in: environment)
        case .stop:
            return await run(AnkaParsing.stopArguments(uuid: uuid), timeout: .seconds(120), in: environment)
        case .restart:
            if machine.state == .running {
                let stopped = await run(AnkaParsing.stopArguments(uuid: uuid), timeout: .seconds(120), in: environment)
                if case .failure = stopped { return stopped }
            }
            return await run(AnkaParsing.startArguments(uuid: uuid), timeout: .seconds(180), in: environment)
        }
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        for arguments in AnkaParsing.modifyCommands(uuid: uuid, new: resources, current: machine.resources) {
            let result = await run(arguments, timeout: .seconds(120), in: environment)
            if case .failure = result { return result }
        }
        guard restartIfRunning else { return .success(()) }
        return await run(AnkaParsing.startArguments(uuid: uuid), timeout: .seconds(180), in: environment)
    }

    private func run(_ arguments: [String], timeout: Duration, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: timeout))
    }
}
#endif
