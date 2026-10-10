#if os(macOS)
import Foundation
import PulseDeckCore

/// Finch: the Lima instance `finch` in `/Applications/Finch/lima/data`, configured by
/// `~/.finch/finch.yaml`. Listing reads files and the process table only.
public struct FinchVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .finch }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMInfraFiles.directoryExists(FinchPaths.installDirectory) || VMInfraFiles.directoryExists(environment.homeDirectory + "/.finch") else { return nil }
        return VMProviderInstall(version: VMInfraFiles.homebrewVersion(formula: "finch"))
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        // No VM created yet (`finch vm init` not run): nothing to show.
        guard VMInfraFiles.exists(FinchPaths.instanceDirectory + "/lima.yaml") else { return [] }
        let instance = LimaInstanceReader.inspect(name: FinchPaths.instanceName, directory: FinchPaths.instanceDirectory, processes: processes)
        let configFile = FinchPaths.configFile(home: environment.homeDirectory)
        let config = VMInfraFiles.read(configFile).map(FinchConfig.init(parsing:))
        return [FinchRecordBuilder.record(config: config, instance: instance, configFile: configFile)]
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await environment.run(FinchCommands.plans(for: action))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        switch LimaFamilySupport.changes(requested: resources, machine: machine) {
        case .failure(let error): return .failure(error)
        case .success(let changes):
            return await environment.run(FinchCommands.settingsPlans(changes: changes, startAfterwards: restartIfRunning))
        }
    }
}
#endif
