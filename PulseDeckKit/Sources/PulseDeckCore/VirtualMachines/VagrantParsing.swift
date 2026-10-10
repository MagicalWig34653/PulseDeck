import Foundation

/// Pure logic for the Vagrant adapter.
///
/// Sources (Vagrant `main`): `lib/vagrant/machine_index.rb` (the index file is
/// `<VAGRANT_HOME>/data/machine-index/index`, JSON `{"version": 1, "machines": {"<uuid>": {"name",
/// "provider", "architecture", "state", "vagrantfile_path", "local_data_path", "updated_at",
/// "extra_data"}}}`), `lib/vagrant/environment.rb` (`data/machine-index`),
/// `lib/vagrant/machine.rb` (the provider's VM id is stored in `<local_data_path>/machines/<name>/<provider>/id`)
/// and `lib/vagrant/plugin/v2/command.rb` (`with_target_vms`: a name that is found in the machine
/// index, by id or id prefix, works from any directory, so `vagrant up <index id>` needs no
/// working directory).
public enum VagrantVMParsing {
    public struct IndexEntry: Hashable, Sendable {
        /// Machine-index UUID (32 hex digits); accepted by `vagrant up|halt|reload`.
        public var id: String
        public var name: String
        /// Vagrant provider name: "virtualbox", "vmware_desktop", "parallels", "qemu", "docker" …
        public var provider: String
        public var architecture: String?
        /// Last state Vagrant recorded ("running", "poweroff", "saved", "not_created" …).
        public var state: String
        public var vagrantfilePath: String?
        public var localDataPath: String?

        public init(id: String, name: String, provider: String, architecture: String? = nil, state: String, vagrantfilePath: String? = nil, localDataPath: String? = nil) {
            self.id = id
            self.name = name
            self.provider = provider
            self.architecture = architecture
            self.state = state
            self.vagrantfilePath = vagrantfilePath
            self.localDataPath = localDataPath
        }

        /// File that holds the provider's own VM identifier, if the data directory is known.
        public var providerIDFilePath: String? {
            guard let localDataPath, !localDataPath.isEmpty else { return nil }
            return "\(localDataPath)/machines/\(name)/\(provider)/id"
        }

        /// Directory the provider keeps this machine's files in.
        var dataDirectory: String? {
            guard let localDataPath, !localDataPath.isEmpty else { return nil }
            return "\(localDataPath)/machines/\(name)/\(provider)/"
        }
    }

    /// Path of the index below the home directory.
    public static let indexPathComponents = [".vagrant.d", "data", "machine-index", "index"]

    // MARK: - Index

    /// `nil` when the file is not a version 1 index (Vagrant itself refuses other versions).
    public static func parseIndex(_ data: Data) -> [IndexEntry]? {
        guard let document = try? JSONDecoder().decode(IndexDocument.self, from: data), document.version == 1, let machines = document.machines else { return nil }
        return machines.compactMap { id, raw -> IndexEntry? in
            guard let name = raw.name, !name.isEmpty, let provider = raw.provider, !provider.isEmpty else { return nil }
            return IndexEntry(
                id: id, name: name, provider: provider,
                architecture: raw.architecture,
                state: raw.state ?? "unknown",
                vagrantfilePath: raw.vagrantfilePath?.isEmpty == false ? raw.vagrantfilePath : nil,
                localDataPath: raw.localDataPath?.isEmpty == false ? raw.localDataPath : nil
            )
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Maps the state id providers record. `nil` for "not_created": the machine does not exist
    /// (destroyed, the stale entry is left behind), so it is not listed.
    public static func vmState(indexState: String) -> VMState? {
        switch indexState.lowercased() {
        case "running": .running
        case "paused": .paused
        case "saved", "suspended": .suspended
        case "poweroff", "stopped", "not_running", "aborted", "shutoff", "off": .stopped
        case "starting", "resuming", "preparing": .starting
        case "stopping", "saving": .stopping
        case "not_created": nil
        default: .unknown
        }
    }

    /// Reads the content of a provider `id` file: one line with the VM identifier.
    public static func parseProviderID(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    // MARK: - Host processes

    /// Whether PulseDeck knows how to recognise the processes of a VM of `provider`.
    static func canAttributeProcesses(provider: String) -> Bool {
        let provider = provider.lowercased()
        return provider == "virtualbox" || provider.hasPrefix("vmware") || provider == "parallels" || provider == "qemu"
    }

    /// Names of the processes that run a VM, as the providers' own tools use them: VirtualBox runs
    /// `VBoxHeadless` (headless) or `VirtualBoxVM` (GUI) with `--startvm <uuid>`; VMware runs
    /// `vmware-vmx`; Parallels `prl_vm_app`; the QEMU plugin `qemu-system-*`.
    static func isHypervisorProcess(_ process: VMHostProcess, provider: String) -> Bool {
        let provider = provider.lowercased()
        if provider == "virtualbox" { return process.name == "VBoxHeadless" || process.name == "VirtualBoxVM" }
        if provider.hasPrefix("vmware") { return process.name == "vmware-vmx" }
        if provider == "parallels" { return process.name == "prl_vm_app" }
        if provider == "qemu" { return process.name.hasPrefix("qemu-system-") }
        return false
    }

    /// Case-insensitive, ignoring the braces some tools put around UUIDs.
    private static func normalizedIdentifier(_ text: String) -> String {
        text.lowercased().filter { $0 != "{" && $0 != "}" }
    }

    /// A hypervisor process belongs to the machine when an argument contains the provider's VM
    /// identifier (a UUID or other id of at least 16 characters, from the `id` file) or points into the
    /// machine's `.vagrant/machines/<name>/<provider>/` directory.
    public static func hostProcessIDs(entry: IndexEntry, providerVMID: String?, processes: [VMHostProcess]) -> [Int32] {
        let identifier = providerVMID.map(normalizedIdentifier).flatMap { $0.count >= 16 ? $0 : nil }
        let directory = entry.dataDirectory
        return processes.filter { process in
            guard isHypervisorProcess(process, provider: entry.provider) else { return false }
            return process.arguments.contains { argument in
                if let identifier, normalizedIdentifier(argument).contains(identifier) { return true }
                if let directory, argument.contains(directory) { return true }
                return false
            }
        }.map(\.pid).sorted()
    }

    // MARK: - Records

    /// Vagrant machines are configured in the user's Vagrantfile, so only power actions are offered.
    public static let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true)

    /// - Parameter providerVMIDs: contents of the machines' provider `id` files, keyed by index id.
    ///
    /// State rules: the index is only updated when a vagrant command runs, so it can be stale.
    /// Where the provider's process can be recognised (VirtualBox, VMware, Parallels, QEMU) a
    /// matching process proves "running". An index that says "running" without a matching process is
    /// reported as `unknown` (not guessed either way); any other index state is shown as recorded.
    /// For other providers the recorded state is shown and labelled as such.
    public static func records(entries: [IndexEntry], providerVMIDs: [String: String], processes: [VMHostProcess]) -> [VMRecord] {
        entries.compactMap { entry in
            guard let recorded = vmState(indexState: entry.state) else { return nil }
            let canAttribute = canAttributeProcesses(provider: entry.provider)
            let processIDs = canAttribute ? hostProcessIDs(entry: entry, providerVMID: providerVMIDs[entry.id], processes: processes) : []

            var state = recorded
            var details = [VMDetail(label: "Provider", value: entry.provider)]
            if let project = entry.vagrantfilePath { details.append(VMDetail(label: "Project", value: project)) }
            details.append(VMDetail(label: "Vagrant ID", value: String(entry.id.prefix(7))))

            if canAttribute {
                if !processIDs.isEmpty {
                    if recorded != .starting && recorded != .stopping { state = .running }
                } else if recorded == .running {
                    state = .unknown
                    details.append(VMDetail(label: "State", value: "Vagrant's index says running, but no VM process was found. The index may be outdated (the VM was stopped outside Vagrant)."))
                }
            } else {
                details.append(VMDetail(label: "State", value: "As recorded by Vagrant's index; it may be outdated. Host usage is not attributed for the \(entry.provider) provider."))
            }

            return VMRecord(
                nativeID: entry.id,
                name: displayName(of: entry),
                state: state,
                guestOS: nil,
                architecture: architectureName(entry.architecture),
                resources: VMResources(),
                ipAddress: nil,
                startedAt: nil,
                hostProcessIDs: processIDs,
                details: details,
                capabilities: capabilities
            )
        }
    }

    /// Vagrant machine names are usually "default"; the project folder tells them apart.
    static func displayName(of entry: IndexEntry) -> String {
        guard let path = entry.vagrantfilePath else { return entry.name }
        let folder = path.split(separator: "/").last.map(String.init) ?? ""
        return folder.isEmpty ? entry.name : "\(entry.name) (\(folder))"
    }

    static func architectureName(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "amd64", "x86_64": return "x86_64"
        case "arm64", "aarch64": return "arm64"
        default: return raw
        }
    }

    // MARK: - Actions

    /// The machine-index id of a snapshot id `"vagrant:<index id>"`.
    public static func indexID(fromVMID id: String) -> String {
        let prefix = "vagrant:"
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// `vagrant up|halt|reload <index id>`. `reload` of a stopped machine would only halt and boot it
    /// again, which is what restart means; a stopped machine is simply started.
    public static func actionCommands(_ action: VMAction, id: String, currentState: VMState) -> [[String]] {
        switch action {
        case .start: [["up", id]]
        case .stop: [["halt", id]]
        case .restart: currentState == .running ? [["reload", id]] : [["up", id]]
        }
    }

    // MARK: - Version

    /// Finds the Vagrant version in the names of `/opt/vagrant/embedded/gems/gems/` (the installer puts
    /// the `vagrant-<version>` gem there, see the Homebrew cask). Returns the highest version.
    public static func version(fromGemDirectoryNames names: [String]) -> String? {
        let versions = names.compactMap { name -> [Int]? in
            guard name.hasPrefix("vagrant-") else { return nil }
            let parts = name.dropFirst("vagrant-".count).split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            // Only "vagrant-2.4.9": rules out plugins such as "vagrant-vmware-desktop-3.0.3".
            guard !parts.isEmpty, numbers.count == parts.count else { return nil }
            return numbers
        }
        guard let best = versions.max(by: { $0.lexicographicallyPrecedes($1) }) else { return nil }
        return best.map(String.init).joined(separator: ".")
    }

    // MARK: - Decoding

    private struct IndexDocument: Decodable {
        var version: Int?
        var machines: [String: RawMachine]?

        enum CodingKeys: String, CodingKey { case version, machines }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
            machines = try? container.decodeIfPresent([String: RawMachine].self, forKey: .machines)
        }
    }

    private struct RawMachine: Decodable {
        var name: String?
        var provider: String?
        var architecture: String?
        var state: String?
        var vagrantfilePath: String?
        var localDataPath: String?

        enum CodingKeys: String, CodingKey {
            case name, provider, architecture, state
            case vagrantfilePath = "vagrantfile_path"
            case localDataPath = "local_data_path"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            provider = try? container.decodeIfPresent(String.self, forKey: .provider)
            architecture = try? container.decodeIfPresent(String.self, forKey: .architecture)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            vagrantfilePath = try? container.decodeIfPresent(String.self, forKey: .vagrantfilePath)
            localDataPath = try? container.decodeIfPresent(String.self, forKey: .localDataPath)
        }
    }
}
