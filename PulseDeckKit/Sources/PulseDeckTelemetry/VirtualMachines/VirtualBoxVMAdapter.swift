#if os(macOS)
import Foundation
import PulseDeckCore

/// VirtualBox. The registry `~/Library/VirtualBox/VirtualBox.xml` names every machine's `.vbox`
/// file; running = a `VBoxHeadless` / `VirtualBoxVM` process started with `--startvm <uuid>`.
/// Actions and CPU / memory changes use `VBoxManage` (powered-off VMs only). Disk resizing
/// (`modifymedium --resize`) is not offered: it is refused for VMs with snapshots and for some
/// formats, which cannot be told apart without running the tool.
public struct VirtualBoxVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.virtualBox

    private static let app = "/Applications/VirtualBox.app"
    private static let tools = ["VBoxManage", "/usr/local/bin/VBoxManage", app + "/Contents/MacOS/VBoxManage"]

    public init() {}

    private func homeFolder(_ environment: VMEnvironment) -> String {
        environment.homeDirectory + "/Library/VirtualBox"
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMProviderFiles.isDirectory(Self.app) || VMProviderFiles.exists(homeFolder(environment) + "/VirtualBox.xml") else { return nil }
        return VMProviderInstall(version: VMProviderFiles.appVersion(bundlePath: Self.app), note: "Disk resizing is not offered; Restart is a virtual reset.")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let home = homeFolder(environment)
        guard let registry = VMProviderFiles.data(at: home + "/VirtualBox.xml") else { return [] }
        return VirtualBoxParsing.registryEntries(registry, virtualBoxHome: home).compactMap { entry -> VMRecord? in
            let folder = (entry.path as NSString).deletingLastPathComponent
            guard let data = VMProviderFiles.data(at: entry.path),
                  let config = VirtualBoxParsing.parseMachine(data, machineFolder: folder) else { return nil }
            return VirtualBoxParsing.makeRecord(config: config, vboxPath: entry.path, diskBytes: diskBytes(of: config), processes: processes)
        }
    }

    /// Sum of the virtual sizes read from the images' own headers (VDI, VMDK, QCOW2); unknown
    /// if any image has another format or cannot be read (VHD / VHDX are not parsed).
    private func diskBytes(of config: VirtualBoxParsing.Config) -> UInt64? {
        guard !config.diskPaths.isEmpty else { return nil }
        var total: UInt64 = 0
        for path in config.diskPaths {
            guard let size = VMProviderFiles.virtualDiskSize(at: path) else { return nil }
            total += size
        }
        return total
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        let arguments: [String]
        switch action {
        case .start: arguments = VirtualBoxParsing.startArguments(uuid: uuid)
        case .stop: arguments = VirtualBoxParsing.stopArguments(uuid: uuid)
        case .restart: arguments = machine.state == .running ? VirtualBoxParsing.restartArguments(uuid: uuid) : VirtualBoxParsing.startArguments(uuid: uuid)
        }
        return VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(120)))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        if let arguments = VirtualBoxParsing.modifyArguments(uuid: uuid, new: resources, current: machine.resources) {
            let result = VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(60)))
            if case .failure = result { return result }
        }
        guard restartIfRunning else { return .success(()) }
        return VMProviderFiles.outcome(await environment.runner.run(tool: Self.tools, arguments: VirtualBoxParsing.startArguments(uuid: uuid), timeout: .seconds(120)))
    }
}
#endif
