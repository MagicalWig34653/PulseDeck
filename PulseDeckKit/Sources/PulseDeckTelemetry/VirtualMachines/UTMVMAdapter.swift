#if os(macOS)
import Foundation
import PulseDeckCore

/// UTM. VMs are `<name>.utm` bundles with `config.plist` and a `Data/` folder holding the disk
/// images, in the sandbox container's `Documents` folder (the default library; VMs UTM keeps
/// elsewhere are registered in UTM's own preferences and are not listed). Start / stop go through
/// `utmctl`, which ships inside UTM.app and talks to the running app via Apple events. UTM
/// offers no command-line way to change a configuration, so VMs are not editable here.
public struct UTMVMAdapter: VMProviderAdapter {
    public let id = VMProviderID.utm

    private static let note = "Start / stop only. Lists VMs in UTM's default library."
    private static let restartTimeout: Duration = .seconds(90)

    public init() {}

    private func libraryDirectory(_ environment: VMEnvironment) -> String {
        environment.homeDirectory + "/Library/Containers/com.utmapp.UTM/Data/Documents"
    }

    private func appCandidates(_ environment: VMEnvironment) -> [String] {
        ["/Applications/UTM.app", environment.homeDirectory + "/Applications/UTM.app"]
    }

    private func utmctlCandidates(_ environment: VMEnvironment) -> [String] {
        appCandidates(environment).map { $0 + "/Contents/MacOS/utmctl" } + ["/opt/homebrew/bin/utmctl", "/usr/local/bin/utmctl"]
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let app = appCandidates(environment).first { VMProviderFiles.isDirectory($0) }
        guard app != nil || VMProviderFiles.isDirectory(libraryDirectory(environment)) else { return nil }
        return VMProviderInstall(version: app.flatMap { VMProviderFiles.appVersion(bundlePath: $0) }, note: Self.note)
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let root = libraryDirectory(environment)
        return VMProviderFiles.entries(in: root).compactMap { entry -> VMRecord? in
            guard entry.hasSuffix(".utm") else { return nil }
            let bundle = root + "/" + entry
            guard VMProviderFiles.isDirectory(bundle),
                  let data = VMProviderFiles.data(at: bundle + "/config.plist"),
                  let config = UTMParsing.parseConfig(data) else { return nil }
            return UTMParsing.makeRecord(config: config, diskBytes: diskBytes(of: config, bundle: bundle), bundlePath: bundle, processes: processes)
        }
    }

    /// Sum of the VM's own disk images: virtual size from the QCOW2 header, otherwise the file
    /// length (raw images, which is also what UTM itself displays for Apple-backend drives).
    /// Unknown if any image is unreadable.
    private func diskBytes(of config: UTMParsing.Config, bundle: String) -> UInt64? {
        let names = UTMParsing.diskImageNames(config)
        guard !names.isEmpty else { return nil }
        var total: UInt64 = 0
        for name in names {
            let path = bundle + "/Data/" + name
            guard let size = VMProviderFiles.virtualDiskSize(at: path) ?? VMProviderFiles.fileSize(at: path) else { return nil }
            total += size
        }
        return total
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let uuid = VMProviderFiles.nativeID(of: machine)
        let candidates = utmctlCandidates(environment)
        switch action {
        case .start:
            return await start(uuid, tools: candidates, in: environment)
        case .stop:
            return await stop(uuid, tools: candidates, in: environment)
        case .restart:
            // A VM whose state is unknown (Apple backend) is only started: stopping a VM that may
            // not be running would just fail.
            if machine.state == .running {
                let stopped = await stop(uuid, tools: candidates, in: environment)
                if case .failure = stopped { return stopped }
                guard await waitUntilStopped(uuid, tools: candidates, in: environment) else {
                    return .failure(.failed("The VM did not shut down within \(Int(Self.restartTimeout.components.seconds)) seconds."))
                }
            }
            return await start(uuid, tools: candidates, in: environment)
        }
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        .failure(.unsupported)
    }

    private func start(_ uuid: String, tools: [String], in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        VMProviderFiles.outcome(await environment.runner.run(tool: tools, arguments: UTMParsing.startArguments(uuid: uuid), timeout: .seconds(90)))
    }

    private func stop(_ uuid: String, tools: [String], in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        VMProviderFiles.outcome(await environment.runner.run(tool: tools, arguments: UTMParsing.stopArguments(uuid: uuid), timeout: .seconds(30)))
    }

    /// `utmctl stop --request` returns before the guest has shut down; a restart has to wait.
    /// This runs after a user's click, not on a polling timer.
    private func waitUntilStopped(_ uuid: String, tools: [String], in environment: VMEnvironment) async -> Bool {
        let deadline = ContinuousClock.now + Self.restartTimeout
        while ContinuousClock.now < deadline {
            let result = await environment.runner.run(tool: tools, arguments: UTMParsing.statusArguments(uuid: uuid), timeout: .seconds(10))
            if let result, result.succeeded, UTMParsing.parseStatus(result.standardOutput) == .stopped { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
#endif
