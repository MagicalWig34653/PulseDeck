#if os(macOS)
import Foundation
import PulseDeckCore

/// OrbStack: one shared Linux VM plus Linux machines. OrbStack keeps no files PulseDeck may read
/// for the machine list, so the listing runs `orbctl` (only while OrbStack's VM process is alive)
/// and the monitor throttles it with `minimumListInterval`. Control is `orbctl start|stop|restart`;
/// CPU and memory are OrbStack-wide settings (`orbctl config set cpu|memory_mib`).
public struct OrbStackVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .orbstack }

    /// One `orbctl list` and one `orbctl config show` per interval.
    public var minimumListInterval: Duration { .seconds(5) }

    private static let applicationPath = "/Applications/OrbStack.app"

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMInfraFiles.directoryExists(Self.applicationPath) || VMInfraFiles.directoryExists(environment.homeDirectory + "/.orbstack") else { return nil }
        return VMProviderInstall(version: VMInfraFiles.bundleVersion(ofApplicationAt: Self.applicationPath))
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let vmProcessIDs = OrbStackParsing.vmProcessIDs(in: processes)
        var machines: [OrbStackMachine] = []
        var config = OrbStackConfig()
        // Never run the CLI while OrbStack is not running: it could start the app.
        if !vmProcessIDs.isEmpty {
            async let listing = environment.runner.run(OrbStackCommands.listPlan)
            async let settings = environment.runner.run(OrbStackCommands.configPlan)
            if let result = await listing, result.succeeded {
                machines = OrbStackParsing.machines(fromJSON: result.standardOutput)
            }
            if let result = await settings, result.succeeded {
                config = OrbStackParsing.config(fromShowOutput: result.standardOutput)
            }
        }
        return OrbStackRecordBuilder.records(machines: machines, config: config, vmProcessIDs: vmProcessIDs, host: VMInfraFiles.hostInfo())
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let nativeID = LimaFamilySupport.nativeID(of: machine)
        let target = nativeID == OrbStackCommands.vmNativeID ? nil : nativeID
        return await environment.run(OrbStackCommands.plans(for: action, machine: target))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        guard LimaFamilySupport.nativeID(of: machine) == OrbStackCommands.vmNativeID else { return .failure(.unsupported) }
        switch LimaFamilySupport.changes(requested: resources, machine: machine) {
        case .failure(let error): return .failure(error)
        case .success(let changes): return await environment.run(OrbStackCommands.configPlans(changes: changes))
        }
    }
}
#endif
