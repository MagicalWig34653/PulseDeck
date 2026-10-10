#if os(macOS)
import Foundation
import PulseDeckCore

/// Docker Desktop's Linux VM: resources are read from its settings file (read-only), the running
/// state from the VM's host process (`com.docker.virtualization`), start/stop/restart through
/// `docker desktop …`.
public struct DockerDesktopVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .dockerDesktop }

    private static let applicationPath = "/Applications/Docker.app"

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMInfraFiles.directoryExists(Self.applicationPath) || VMInfraFiles.directoryExists(DockerDesktopPaths.groupContainer(home: environment.homeDirectory)) else { return nil }
        return VMProviderInstall(version: VMInfraFiles.bundleVersion(ofApplicationAt: Self.applicationPath), note: "Resources are read-only")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let file = DockerDesktopPaths.settingsFiles(home: environment.homeDirectory).first { VMInfraFiles.exists($0) }
        let settings = file.flatMap(VMInfraFiles.read).map(DockerDesktopSettings.init(parsing:))
        return [DockerDesktopRecordBuilder.record(
            settings: settings,
            vmProcessIDs: DockerDesktopProcesses.vmProcessIDs(in: processes),
            backendRunning: DockerDesktopProcesses.backendIsRunning(in: processes),
            host: VMInfraFiles.hostInfo(),
            settingsFile: file
        )]
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        await environment.run(DockerDesktopCommands.plans(for: action))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        // Docker Desktop owns its settings (they can be locked by an administrator): read-only.
        .failure(.unsupported)
    }
}
#endif
