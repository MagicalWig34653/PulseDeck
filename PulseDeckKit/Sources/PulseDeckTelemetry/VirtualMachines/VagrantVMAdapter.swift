#if os(macOS)
import Foundation
import PulseDeckCore

/// Vagrant. Listing reads Vagrant's machine index (`~/.vagrant.d/data/machine-index/index`) and each
/// machine's provider `id` file, then confirms "running" through the host process table; no command
/// is run. Power actions run `vagrant up|halt|reload <machine-index id>`, which Vagrant resolves from
/// any directory. Configuration lives in the user's Vagrantfile, so editing is not offered.
/// All parsing and planning is in `VagrantVMParsing`.
public struct VagrantVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .vagrant }

    private static let tools = ["/opt/vagrant/bin/vagrant", "/usr/local/bin/vagrant", "/opt/homebrew/bin/vagrant", "vagrant"]
    /// The installer package puts the `vagrant-<version>` gem here (see Homebrew's `vagrant` cask).
    private static let gemDirectory = "/opt/vagrant/embedded/gems/gems"

    private func indexPath(in environment: VMEnvironment) -> String {
        ([environment.homeDirectory] + VagrantVMParsing.indexPathComponents).joined(separator: "/")
    }

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let fileManager = FileManager.default
        let hasTool = Self.tools.filter { $0.hasPrefix("/") }.contains { fileManager.fileExists(atPath: $0) }
        guard hasTool || fileManager.fileExists(atPath: environment.homeDirectory + "/.vagrant.d") else { return nil }
        let gems = (try? fileManager.contentsOfDirectory(atPath: Self.gemDirectory)) ?? []
        return VMProviderInstall(version: VagrantVMParsing.version(fromGemDirectoryNames: gems), note: "Power actions only; configure machines in their Vagrantfile.")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        let fileManager = FileManager.default
        guard let data = fileManager.contents(atPath: indexPath(in: environment)),
              let entries = VagrantVMParsing.parseIndex(data)
        else { return [] }

        var providerVMIDs: [String: String] = [:]
        for entry in entries {
            guard let path = entry.providerIDFilePath,
                  let text = fileManager.contents(atPath: path).flatMap({ String(data: $0, encoding: .utf8) }),
                  let providerID = VagrantVMParsing.parseProviderID(text)
            else { continue }
            providerVMIDs[entry.id] = providerID
        }
        return VagrantVMParsing.records(entries: entries, providerVMIDs: providerVMIDs, processes: processes)
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        let indexID = VagrantVMParsing.indexID(fromVMID: machine.id)
        for arguments in VagrantVMParsing.actionCommands(action, id: indexID, currentState: machine.state) {
            // `vagrant up` provisions on first boot and can take many minutes.
            guard let result = await environment.runner.run(tool: Self.tools, arguments: arguments, timeout: .seconds(900)) else { return .failure(.providerUnavailable) }
            guard result.succeeded else {
                let text = [result.standardError, result.standardOutput]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                return .failure(.failed(String((text ?? "vagrant exited with status \(result.exitStatus)").suffix(600))))
            }
        }
        return .success(())
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        // Resources are defined in the Vagrantfile of the user's project, which PulseDeck does not edit.
        .failure(.unsupported)
    }
}
#endif
