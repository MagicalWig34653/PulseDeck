#if os(macOS)
import Foundation
import PulseDeckCore

/// Thin file-system helpers for the adapters: reading small text files, directory listings,
/// installed tool and app versions. No logic worth testing lives here; it all sits in `PulseDeckCore`.
enum VMInfraFiles {
    /// Configuration files are a few KiB; refuse anything absurd rather than load it.
    private static let maximumFileSize = 2 * 1024 * 1024

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func read(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= maximumFileSize else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Names of the entries of a directory (empty if it cannot be read).
    static func entries(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Whether any of the tool candidates exists as an executable (no process is started).
    static func toolExists(_ candidates: [String], home: String) -> Bool {
        VMToolLocator.resolvedCandidates(candidates, home: home).contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Highest version of a Homebrew formula or cask (`Cellar/<name>/<version>`, `Caskroom/<name>/<version>`),
    /// `nil` if not installed by Homebrew.
    static func homebrewVersion(formula: String) -> String? {
        let roots = ["/opt/homebrew/Cellar/", "/usr/local/Cellar/", "/opt/homebrew/Caskroom/", "/usr/local/Caskroom/"]
        let names = roots.flatMap { entries(of: $0 + formula) }
        return VMVersion.newest(in: names)?.description
    }

    /// `CFBundleShortVersionString` of an application bundle.
    static func bundleVersion(ofApplicationAt path: String) -> String? {
        Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func hostInfo() -> LimaHostInfo {
        // `hw.optional.arm64` is 1 on Apple silicon, also for a process running under Rosetta.
        let isARM = Sysctl.integer("hw.optional.arm64", as: Int32.self) == 1
        return LimaHostInfo(
            cpuCount: ProcessInfo.processInfo.processorCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            architecture: isARM ? "arm64" : "x86_64"
        )
    }
}

/// Reads Lima instance directories (shared by the Lima, Colima, Finch and Rancher Desktop adapters).
enum LimaInstanceReader {
    /// Instance directories under a Lima home: every sub-directory that holds a `lima.yaml`.
    /// Names starting with `_` (`_config`, `_disks`, `_networks`) are Lima's own.
    static func instanceNames(in limaHome: String) -> [String] {
        VMInfraFiles.entries(of: limaHome)
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .filter { VMInfraFiles.exists(limaHome + "/" + $0 + "/lima.yaml") }
            .sorted()
    }

    static func read(name: String, directory: String) -> LimaInstanceFiles {
        var pidFiles: [String: String] = [:]
        for entry in VMInfraFiles.entries(of: directory) where entry.hasSuffix(".pid") {
            if let content = VMInfraFiles.read(directory + "/" + entry) { pidFiles[entry] = content }
        }
        return LimaInstanceFiles(
            name: name,
            directory: directory,
            limaYAML: VMInfraFiles.read(directory + "/lima.yaml"),
            sshConfig: VMInfraFiles.read(directory + "/ssh.config"),
            limaVersion: VMInfraFiles.read(directory + "/lima-version"),
            pidFiles: pidFiles,
            hostAgentStartedAt: VMInfraFiles.modificationDate(directory + "/ha.pid")
        )
    }

    static func inspect(name: String, directory: String, processes: [VMHostProcess]) -> LimaInstance {
        LimaInspector.inspect(read(name: name, directory: directory), processes: processes, host: VMInfraFiles.hostInfo())
    }
}

enum LimaFamilySupport {
    /// The provider's own identifier of a machine: `VirtualMachineSnapshot.id` is `"<provider>:<native id>"`.
    static func nativeID(of machine: VirtualMachineSnapshot) -> String {
        let prefix = machine.providerID + ":"
        return machine.id.hasPrefix(prefix) ? String(machine.id.dropFirst(prefix.count)) : machine.id
    }

    /// The fields that really change, or the reason the request is refused (nothing is run then).
    static func changes(requested: VMResources, machine: VirtualMachineSnapshot) -> Result<VMResources, VMControlError> {
        switch VMResourceEditing.changes(requested: requested, current: machine.resources, capabilities: machine.capabilities) {
        case .success(let changes): .success(changes)
        case .failure(let problem): .failure(.failed(problem.description))
        }
    }

    /// `LIMA_HOME` only when it differs from the default, so `limactl` finds the same instances PulseDeck listed.
    static func limaEnvironment(home: String) -> [String: String] {
        guard let custom = ProcessInfo.processInfo.environment["LIMA_HOME"], !custom.isEmpty else { return [:] }
        return ["LIMA_HOME": custom]
    }
}

/// Maps the result of a sequence of vendor commands to what the adapters return.
extension VMEnvironment {
    func run(_ plans: [VMCommandPlan]) async -> Result<Void, VMControlError> {
        guard !plans.isEmpty else { return .success(()) }
        return await runner.run(sequence: plans)
    }
}
#endif
