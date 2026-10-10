#if os(macOS)
import Foundation
import PulseDeckCore

/// minikube. Profiles are read from `~/.minikube/profiles/<name>/config.json`; the VM process is
/// recognised through the driver's pid file (`machines/<machine>/vfkit.pid` or `qemu.pid`) and the
/// machine directory in the hypervisor's arguments. Start / stop run `minikube start|stop -p`.
/// minikube refuses to change CPUs, memory or disk of an existing cluster, so editing is not offered.
/// All parsing and planning is in `MinikubeVMParsing`.
public struct MinikubeVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .minikube }

    private static let tools = ["/opt/homebrew/bin/minikube", "/usr/local/bin/minikube", "minikube"]
    private static let cellars = ["/opt/homebrew/Cellar/minikube", "/usr/local/Cellar/minikube"]

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let fileManager = FileManager.default
        let hasTool = Self.tools.filter { $0.hasPrefix("/") }.contains { fileManager.fileExists(atPath: $0) }
        guard hasTool || fileManager.fileExists(atPath: environment.homeDirectory + "/.minikube") else { return nil }
        let versions = Self.cellars.flatMap { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }
        return VMProviderInstall(version: PodmanVMParsing.highestVersion(of: versions), note: "Resources of an existing cluster cannot be changed (read-only).")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let fileManager = FileManager.default
        let root = environment.homeDirectory + "/.minikube"
        var profiles: [MinikubeVMParsing.Profile] = []
        var pidFilePIDs: [String: Int32] = [:]
        for directory in ((try? fileManager.contentsOfDirectory(atPath: root + "/profiles")) ?? []).sorted() {
            guard let data = fileManager.contents(atPath: root + "/profiles/" + directory + "/config.json"),
                  let profile = MinikubeVMParsing.parseProfile(data, directoryName: directory)
            else { continue }
            profiles.append(profile)
            guard let pidFileName = MinikubeVMParsing.pidFileName(forDriver: profile.driver) else { continue }
            for machine in profile.machineNames {
                if let text = fileManager.contents(atPath: root + "/machines/" + machine + "/" + pidFileName).flatMap({ String(data: $0, encoding: .utf8) }),
                   let pid = MinikubeVMParsing.parsePID(text) {
                    pidFilePIDs[machine] = pid
                }
            }
        }
        return MinikubeVMParsing.records(profiles: profiles, pidFilePIDs: pidFilePIDs, processes: processes)
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let allowed: Bool
        switch action {
        case .start: allowed = machine.capabilities.canStart
        case .stop: allowed = machine.capabilities.canStop
        case .restart: allowed = machine.capabilities.canRestart
        }
        guard allowed else { return .failure(.unsupported) }

        let profile = MinikubeVMParsing.profileName(fromVMID: machine.id)
        for arguments in MinikubeVMParsing.actionCommands(action, profile: profile) {
            guard let result = await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(600)) else { return .failure(.providerUnavailable) }
            guard result.succeeded else {
                let text = [result.standardError, result.standardOutput]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return .failure(.failed(String((text ?? "minikube exited with status \(result.exitStatus)").suffix(600))))
            }
        }
        return .success(())
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        // `minikube start` warns "You cannot change the memory size / CPUs / disk size for an
        // existing minikube cluster. Please first delete the cluster."
        .failure(.unsupported)
    }
}
#endif
