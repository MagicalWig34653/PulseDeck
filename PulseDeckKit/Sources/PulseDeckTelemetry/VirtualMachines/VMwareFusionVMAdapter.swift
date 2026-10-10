#if os(macOS)
import Foundation
import PulseDeckCore

/// VMware Fusion. VMs are `.vmwarevm` bundles with a `.vmx` file; the list comes from Fusion's
/// inventory file plus the standard VM folders. Running = a `vmware-vmx` process that has the
/// `.vmx` path as argument; suspended = a `.vmss` next to the `.vmx`. Start / stop / reset use
/// `vmrun`; CPU and memory are changed by rewriting the powered-off VM's `.vmx` (see
/// `VMwareFusionParsing.applying`). Disk resizing needs `vmware-vdiskmanager` and is not offered.
public struct VMwareFusionVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.vmwareFusion

    private static let app = "/Applications/VMware Fusion.app"
    private static let vmrun = [app + "/Contents/Public/vmrun", "vmrun"]
    /// A text VMDK descriptor is tiny; sparse headers need only their first bytes.
    private static let descriptorLimit = HypervisorDiskHeader.maximumDescriptorLength

    public init() {}

    private func inventoryPath(_ environment: VMEnvironment) -> String {
        environment.homeDirectory + "/Library/Application Support/VMware Fusion/vmInventory"
    }

    private func machineFolders(_ environment: VMEnvironment) -> [String] {
        let home = environment.homeDirectory
        return [home + "/Virtual Machines.localized", home + "/Documents/Virtual Machines.localized", home + "/Virtual Machines", home + "/Documents/Virtual Machines"]
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        guard VMProviderFiles.isDirectory(Self.app) || VMProviderFiles.exists(inventoryPath(environment)) else { return nil }
        return VMProviderInstall(version: VMProviderFiles.appVersion(bundlePath: Self.app), note: "Resize of the virtual disk is not offered.")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        var paths = VMProviderFiles.text(at: inventoryPath(environment)).map(VMwareFusionParsing.inventoryPaths) ?? []
        for folder in machineFolders(environment) {
            for entry in VMProviderFiles.entries(in: folder) where entry.hasSuffix(".vmwarevm") {
                let bundle = folder + "/" + entry
                for file in VMProviderFiles.entries(in: bundle) where file.hasSuffix(".vmx") {
                    paths.append(bundle + "/" + file)
                }
            }
        }

        var seen = Set<String>()
        return paths.compactMap { path -> VMRecord? in
            guard seen.insert(path.lowercased()).inserted, let text = VMProviderFiles.text(at: path) else { return nil }
            let fallbackName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let config = VMwareFusionParsing.parseConfig(text, fallbackName: fallbackName)
            let suspendState = ((path as NSString).deletingPathExtension) + ".vmss"
            return VMwareFusionParsing.makeRecord(
                vmxPath: path,
                config: config,
                diskBytes: diskBytes(of: config, vmx: path),
                hasSuspendState: VMProviderFiles.exists(suspendState),
                processes: processes
            )
        }
    }

    /// Sum of the virtual sizes of the VM's `.vmdk` disks; unknown if any one cannot be read.
    private func diskBytes(of config: VMwareFusionParsing.Config, vmx: String) -> UInt64? {
        guard !config.diskFiles.isEmpty else { return nil }
        let directory = (vmx as NSString).deletingLastPathComponent
        var total: UInt64 = 0
        for file in config.diskFiles {
            let path = file.hasPrefix("/") ? file : directory + "/" + file
            guard let header = VMProviderFiles.prefix(of: path, length: Self.descriptorLimit) else { return nil }
            let descriptor = String(data: header, encoding: .utf8)
            guard let size = VMwareFusionParsing.diskSize(header: header, descriptorText: descriptor) else { return nil }
            total += size
        }
        return total
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let vmx = VMProviderFiles.nativeID(of: machine)
        let arguments: [String]
        switch action {
        case .start: arguments = VMwareFusionParsing.startArguments(vmx: vmx)
        case .stop: arguments = VMwareFusionParsing.stopArguments(vmx: vmx)
        case .restart: arguments = machine.state == .running ? VMwareFusionParsing.restartArguments(vmx: vmx) : VMwareFusionParsing.startArguments(vmx: vmx)
        }
        return VMProviderFiles.outcome(await environment.runner.run(tool: Self.vmrun, arguments: arguments, timeout: .seconds(180)))
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let vmx = VMProviderFiles.nativeID(of: machine)
        // Fusion rewrites the .vmx when it closes a running VM, which would undo the edit.
        guard machine.state != .running else { return .failure(.failed("Shut the VM down before changing its hardware.")) }
        guard let text = VMProviderFiles.text(at: vmx) else { return .failure(.failed("The VM configuration could not be read.")) }

        let cpus = resources.cpus != machine.resources.cpus ? resources.cpus : nil
        let memory = resources.memoryBytes != machine.resources.memoryBytes ? resources.memoryBytes.map(VMwareFusionParsing.memoryMiB(forBytes:)) : nil
        let edited = VMwareFusionParsing.applying(cpus: cpus, memoryMiB: memory, to: text)
        if edited != text {
            do {
                try edited.write(toFile: vmx, atomically: true, encoding: .utf8)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }
        guard restartIfRunning else { return .success(()) }
        return VMProviderFiles.outcome(await environment.runner.run(tool: Self.vmrun, arguments: VMwareFusionParsing.startArguments(vmx: vmx), timeout: .seconds(180)))
    }
}
#endif
