#if os(macOS)
import Foundation
import PulseDeckCore

/// Colima: one VM per profile. Profiles come from `<colima home>/<profile>/colima.yaml` and from
/// the Lima instances `colima` / `colima-<profile>` in `<colima home>/_lima`; state and host
/// processes from the Lima PID files checked against the process table. Nothing is run to list.
public struct ColimaVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .colima }

    private struct Locations {
        var base: String
        var limaHome: String
    }

    private func locations(_ environment: VMEnvironment) -> Locations {
        let variables = ProcessInfo.processInfo.environment
        let base = ColimaPaths.configBase(environment: variables, home: environment.homeDirectory, exists: VMInfraFiles.directoryExists)
        return Locations(base: base, limaHome: ColimaPaths.limaHome(environment: variables, base: base))
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let base = locations(environment).base
        guard VMInfraFiles.toolExists(ColimaCommands.tool, home: environment.homeDirectory) || VMInfraFiles.directoryExists(base) else { return nil }
        return VMProviderInstall(version: VMInfraFiles.homebrewVersion(formula: "colima"))
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let place = locations(environment)
        let withConfig = VMInfraFiles.entries(of: place.base).filter { VMInfraFiles.exists(place.base + "/" + $0 + "/colima.yaml") }
        let profiles = ColimaPaths.profiles(configDirectoriesWithConfig: withConfig, limaInstances: VMInfraFiles.entries(of: place.limaHome))
        let host = VMInfraFiles.hostInfo()
        return profiles.map { profile in
            let instanceName = ColimaPaths.limaInstanceName(profile: profile)
            let files = LimaInstanceReader.read(name: instanceName, directory: place.limaHome + "/" + instanceName)
            let instance = LimaInspector.inspect(files, processes: processes, host: host)
            let config = VMInfraFiles.read(place.base + "/" + profile + "/colima.yaml").map(ColimaConfig.init(parsing:))
            return ColimaRecordBuilder.record(profile: profile, config: config, instance: instance, host: host)
        }
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await environment.run(ColimaCommands.plans(for: action, profile: LimaFamilySupport.nativeID(of: machine)))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        switch LimaFamilySupport.changes(requested: resources, machine: machine) {
        case .failure(let error):
            return .failure(error)
        case .success(let changes):
            if VMResourceEditing.isEmpty(changes) { return .success(()) }
            let profile = LimaFamilySupport.nativeID(of: machine)
            if restartIfRunning {
                // `colima start --cpus … --memory … --disk …` applies, saves and starts.
                return await environment.run([ColimaCommands.startWithResources(profile: profile, changes: changes)])
            }
            // The VM stays stopped: change colima.yaml only; the next `colima start` applies it.
            let path = locations(environment).base + "/" + profile + "/colima.yaml"
            guard let text = VMInfraFiles.read(path), let edited = ColimaCommands.editedConfiguration(text, changes: changes) else {
                return .failure(.failed("colima.yaml could not be updated safely; edit \(path) by hand."))
            }
            do {
                try edited.write(toFile: path, atomically: true, encoding: .utf8)
                return .success(())
            } catch {
                return .failure(.failed("Could not write \(path): \(error.localizedDescription)"))
            }
        }
    }
}
#endif
