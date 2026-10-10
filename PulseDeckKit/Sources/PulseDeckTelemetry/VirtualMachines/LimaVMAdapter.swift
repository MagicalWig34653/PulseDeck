#if os(macOS)
import Foundation
import PulseDeckCore

/// Lima (`~/.lima`, or `$LIMA_HOME`): every instance directory with a `lima.yaml`. State and host
/// processes come from the PID files checked against the process table; nothing is run to list.
/// Instances that belong to Colima (same Lima home through `LIMA_HOME`) are left to the Colima adapter.
public struct LimaVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .lima }

    private func limaHome(_ environment: VMEnvironment) -> String {
        LimaPaths.limaHome(environment: ProcessInfo.processInfo.environment, home: environment.homeDirectory)
    }

    private func installedVersion() -> VMVersion? {
        VMInfraFiles.homebrewVersion(formula: "lima").flatMap(VMVersion.init)
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMInfraFiles.toolExists(LimaCommands.tool, home: environment.homeDirectory) || VMInfraFiles.directoryExists(limaHome(environment)) else { return nil }
        return VMProviderInstall(version: VMInfraFiles.homebrewVersion(formula: "lima"))
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let home = limaHome(environment)
        guard !LimaPaths.isForeign(limaHome: home, home: environment.homeDirectory) else { return [] }
        let colimaInstalled = VMInfraFiles.directoryExists(environment.homeDirectory + "/.colima")
        let capabilities = LimaCapabilityRules.capabilities(installedVersion: installedVersion())
        return LimaInstanceReader.instanceNames(in: home)
            .filter { !(colimaInstalled && LimaPaths.isColimaInstance(name: $0)) }
            .map { name in
                let instance = LimaInstanceReader.inspect(name: name, directory: home + "/" + name, processes: processes)
                return LimaRecordBuilder.record(for: instance, nativeID: name, name: name, capabilities: capabilities)
            }
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let plans = LimaCommands.plans(for: action, instance: LimaFamilySupport.nativeID(of: machine), environment: LimaFamilySupport.limaEnvironment(home: environment.homeDirectory))
        return await environment.run(plans)
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        switch LimaFamilySupport.changes(requested: resources, machine: machine) {
        case .failure(let error): return .failure(error)
        case .success(let changes):
            let plans = LimaCommands.editPlans(instance: LimaFamilySupport.nativeID(of: machine), changes: changes, restartAfterwards: restartIfRunning, environment: LimaFamilySupport.limaEnvironment(home: environment.homeDirectory))
            return await environment.run(plans)
        }
    }
}
#endif
