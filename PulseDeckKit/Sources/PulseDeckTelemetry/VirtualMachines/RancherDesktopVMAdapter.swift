#if os(macOS)
import Foundation
import PulseDeckCore

/// Rancher Desktop: its Lima instance `0` in `~/Library/Application Support/rancher-desktop/lima`,
/// settings from `~/Library/Preferences/rancher-desktop/settings.json`, control through `rdctl`.
public struct RancherDesktopVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .rancherDesktop }

    private static let applicationPath = "/Applications/Rancher Desktop.app"

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let support = RancherDesktopPaths.applicationSupport(home: environment.homeDirectory)
        guard VMInfraFiles.directoryExists(Self.applicationPath) || VMInfraFiles.directoryExists(support) else { return nil }
        return VMProviderInstall(version: VMInfraFiles.bundleVersion(ofApplicationAt: Self.applicationPath))
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let directory = RancherDesktopPaths.instanceDirectory(home: environment.homeDirectory)
        // The application has not created its VM yet.
        guard VMInfraFiles.exists(directory + "/lima.yaml") else { return [] }
        let instance = LimaInstanceReader.inspect(name: RancherDesktopPaths.instanceName, directory: directory, processes: processes)
        let settings = VMInfraFiles.read(RancherDesktopPaths.settingsFile(home: environment.homeDirectory)).map(RancherDesktopSettings.init(parsing:))
        return [RancherDesktopRecordBuilder.record(settings: settings, instance: instance)]
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await environment.run(RancherDesktopCommands.plans(for: action))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        switch LimaFamilySupport.changes(requested: resources, machine: machine) {
        case .failure(let error):
            return .failure(error)
        case .success(let changes):
            guard let plan = RancherDesktopCommands.applyPlan(changes: changes) else { return .success(()) }
            // `rdctl start --virtual-machine…` would also launch a closed application; the settings
            // are only changed through the running one.
            guard machine.state == .running else {
                return .failure(.failed("Start Rancher Desktop first: its settings are applied through the running application."))
            }
            return await environment.run([plan])
        }
    }
}
#endif
