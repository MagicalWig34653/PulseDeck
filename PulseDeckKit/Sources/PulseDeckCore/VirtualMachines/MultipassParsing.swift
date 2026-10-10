import Foundation

/// Pure logic for the Multipass adapter: JSON parsing of `multipass list|info --format json`,
/// state mapping, host process matching and the `multipass set` plan.
///
/// Sources (Multipass `main`): `src/client/cli/formatter/json_formatter.cpp` (JSON shapes),
/// `src/client/cli/formatter/format_utils.cpp` (status strings),
/// `src/daemon/instance_settings_handler.cpp` (`local.<instance>.cpus|memory|disk`, instance must be
/// stopped, disk can only grow, minimum 1 CPU / 512M / 1G) and `src/utils/memory_size.cpp`
/// (size syntax `<digits>[K|M|G][iB|B]`).
public enum MultipassVMParsing {
    // MARK: - Models

    /// One entry of `multipass list --format json` (`{"list": [...]}`).
    public struct ListedInstance: Hashable, Sendable {
        public var name: String
        /// Status string as printed by Multipass: "Running", "Stopped", "Starting", "Restarting",
        /// "Delayed Shutdown", "Suspending", "Suspended", "Deleted", "Unavailable", "Unknown".
        public var status: String
        public var ipv4: [String]
        /// "Ubuntu 24.04 LTS", or "Not Available" when the daemon cannot tell.
        public var release: String?

        public init(name: String, status: String, ipv4: [String] = [], release: String? = nil) {
            self.name = name
            self.status = status
            self.ipv4 = ipv4
            self.release = release
        }
    }

    /// The parts of `multipass info --format json` that PulseDeck shows.
    public struct InstanceInfo: Hashable, Sendable {
        public var cpuCount: Int?
        public var memoryTotalBytes: UInt64?
        public var diskTotalBytes: UInt64?
        public var ipv4: [String]
        public var imageRelease: String?
        public var snapshotCount: Int?

        public init(cpuCount: Int? = nil, memoryTotalBytes: UInt64? = nil, diskTotalBytes: UInt64? = nil, ipv4: [String] = [], imageRelease: String? = nil, snapshotCount: Int? = nil) {
            self.cpuCount = cpuCount
            self.memoryTotalBytes = memoryTotalBytes
            self.diskTotalBytes = diskTotalBytes
            self.ipv4 = ipv4
            self.imageRelease = imageRelease
            self.snapshotCount = snapshotCount
        }
    }

    // MARK: - Command lines

    /// `multipass list --format json`.
    public static let listArguments = ["list", "--format", "json"]

    /// `multipass info --format json <names…>`. Names are always passed explicitly because older
    /// Multipass versions require `--all` or a name while newer ones accept neither. With
    /// `skipRuntimeInformation` the (hidden) `--no-runtime-information` flag is added so the
    /// daemon does not open an SSH session into every running instance just for load figures;
    /// callers retry without it when the Multipass version does not know the flag.
    public static func infoArguments(names: [String], skipRuntimeInformation: Bool) -> [String] {
        var arguments = ["info", "--format", "json"]
        if skipRuntimeInformation { arguments.append("--no-runtime-information") }
        arguments.append(contentsOf: names)
        return arguments
    }

    /// The commands that perform `action` (run in order, stop at the first failure).
    public static func actionCommands(_ action: VMAction, instance: String) -> [[String]] {
        switch action {
        case .start: [["start", instance]]
        case .stop: [["stop", instance]]
        case .restart: [["restart", instance]]
        }
    }

    // MARK: - JSON

    public static func parseList(_ data: Data) -> [ListedInstance]? {
        guard let document = try? JSONDecoder().decode(ListDocument.self, from: data), let list = document.list else { return nil }
        return list.compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return ListedInstance(name: name, status: entry.state ?? "Unknown", ipv4: entry.ipv4 ?? [], release: entry.release)
        }
    }

    /// Instance name → info. `nil` when the document is not valid JSON of the expected shape.
    public static func parseInfo(_ data: Data) -> [String: InstanceInfo]? {
        guard let document = try? JSONDecoder().decode(InfoDocument.self, from: data), let info = document.info else { return nil }
        var result: [String: InstanceInfo] = [:]
        for (name, entry) in info {
            // The disk is reported under a fixed device name ("sda1", a TODO in Multipass); fall
            // back to any entry should that change.
            let disk = entry.disks?["sda1"] ?? entry.disks?.sorted(by: { $0.key < $1.key }).first?.value
            result[name] = InstanceInfo(
                cpuCount: entry.cpuCount,
                memoryTotalBytes: entry.memoryTotal,
                diskTotalBytes: disk?.total,
                ipv4: entry.ipv4 ?? [],
                imageRelease: entry.imageRelease,
                snapshotCount: entry.snapshotCount
            )
        }
        return result
    }

    // MARK: - State

    /// Maps Multipass' status text. `nil` for "Deleted": the instance is in the trash
    /// (`multipass delete` without `--purge`), not usable and not listed by PulseDeck.
    public static func vmState(forStatus status: String) -> VMState? {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "running": .running
        case "stopped": .stopped
        case "starting", "restarting": .starting
        case "suspended": .suspended
        case "suspending", "delayed shutdown": .stopping
        case "deleted": nil
        default: .unknown
        }
    }

    // MARK: - Host processes

    /// Multipass instances run as a `qemu-system-*` child of the root-owned daemon (`multipassd`).
    /// QEMU gets no `-name`, but its disk (`-drive file=`) and cloud-init (`-cdrom`) images live in
    /// `<daemon data>/vault/instances/<instance>/`, which identifies the instance. The match is on
    /// that directory (with trailing slash, so `ubuntu` never matches `ubuntu-2`).
    public static func hostProcessIDs(instance: String, processes: [VMHostProcess]) -> [Int32] {
        let marker = "/vault/instances/\(instance)/"
        return processes
            .filter { $0.name.hasPrefix("qemu-system-") && $0.arguments.contains(where: { $0.contains(marker) }) }
            .map(\.pid)
            .sorted()
    }

    // MARK: - Records

    /// What can be done with an instance in `state`. Multipass applies `set` only to stopped
    /// instances; PulseDeck stops a running one first (`VMCapabilities.editRequiresStopped`).
    public static func capabilities(for state: VMState) -> VMCapabilities {
        let editable = state == .running || state == .stopped
        return VMCapabilities(
            canStart: true, canStop: true, canRestart: true,
            canEditCPUs: editable, canEditMemory: editable, canEditDisk: editable,
            editRequiresStopped: true, diskCanOnlyGrow: true
        )
    }

    public static func records(list: [ListedInstance], info: [String: InstanceInfo], processes: [VMHostProcess]) -> [VMRecord] {
        list.compactMap { listed in
            guard let state = vmState(forStatus: listed.status) else { return nil }
            let extra = info[listed.name]
            let processIDs = hostProcessIDs(instance: listed.name, processes: processes)

            var details: [VMDetail] = []
            if let release = listed.release ?? extra?.imageRelease, release != "Not Available" {
                details.append(VMDetail(label: "Image", value: release))
            }
            if let snapshots = extra?.snapshotCount, snapshots > 0 {
                details.append(VMDetail(label: "Snapshots", value: String(snapshots)))
            }
            if state == .running, processIDs.isEmpty {
                // The daemon (and therefore QEMU) runs as root; macOS refuses to hand a normal
                // user the arguments of root processes, so the VM cannot be attributed.
                details.append(VMDetail(label: "Host usage", value: "Not available: Multipass runs its VMs as root, so their processes cannot be attributed to this instance."))
            }
            details.append(VMDetail(label: "Listing", value: "From the multipass command-line tool (refreshed every few seconds)."))

            return VMRecord(
                nativeID: listed.name,
                name: listed.name,
                state: state,
                guestOS: "Linux",
                architecture: nil,
                resources: VMResources(cpus: extra?.cpuCount, memoryBytes: extra?.memoryTotalBytes, diskBytes: extra?.diskTotalBytes),
                ipAddress: (listed.ipv4.first ?? extra?.ipv4.first).flatMap { $0.isEmpty ? nil : $0 },
                startedAt: nil,
                hostProcessIDs: processIDs,
                details: details,
                capabilities: capabilities(for: state)
            )
        }
    }

    // MARK: - Editing

    public enum EditError: Error, Hashable, Sendable {
        case invalidCPUCount
        case memoryBelowMinimum
        case diskBelowMinimum
        case diskCannotShrink
    }

    /// Multipass' minimums (`min_cpu_cores`, `min_memory_size`, `min_disk_size` in `constants.h`).
    static let minimumCPUs = 1
    static let minimumMemoryBytes: UInt64 = 512 * 1_048_576
    static let minimumDiskBytes: UInt64 = 1_073_741_824

    /// `multipass set local.<instance>.<key>=<value>` for every value that differs from `current`.
    /// Memory and disk are passed in whole MiB (`4096M`, rounded up) which Multipass parses exactly.
    public static func setCommands(instance: String, current: VMResources, requested: VMResources) -> Result<[[String]], EditError> {
        var commands: [[String]] = []
        if let cpus = requested.cpus, cpus != current.cpus {
            guard cpus >= minimumCPUs else { return .failure(.invalidCPUCount) }
            commands.append(["set", "local.\(instance).cpus=\(cpus)"])
        }
        if let memory = requested.memoryBytes, memory != current.memoryBytes {
            guard memory >= minimumMemoryBytes else { return .failure(.memoryBelowMinimum) }
            commands.append(["set", "local.\(instance).memory=\(mebibytesRoundedUp(memory))M"])
        }
        if let disk = requested.diskBytes, disk != current.diskBytes {
            guard disk >= minimumDiskBytes else { return .failure(.diskBelowMinimum) }
            if let existing = current.diskBytes, disk < existing { return .failure(.diskCannotShrink) }
            commands.append(["set", "local.\(instance).disk=\(mebibytesRoundedUp(disk))M"])
        }
        return .success(commands)
    }

    private static func mebibytesRoundedUp(_ bytes: UInt64) -> UInt64 {
        let mebi: UInt64 = 1_048_576
        let (sum, overflow) = bytes.addingReportingOverflow(mebi - 1)
        return (overflow ? UInt64.max : sum) / mebi
    }

    // MARK: - Decoding helpers

    private struct ListDocument: Decodable {
        var list: [ListEntry]?
    }

    private struct ListEntry: Decodable {
        var name: String?
        var state: String?
        var ipv4: [String]?
        var release: String?

        enum CodingKeys: String, CodingKey { case name, state, ipv4, release }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            state = try? container.decodeIfPresent(String.self, forKey: .state)
            ipv4 = try? container.decodeIfPresent([String].self, forKey: .ipv4)
            release = try? container.decodeIfPresent(String.self, forKey: .release)
        }
    }

    private struct InfoDocument: Decodable {
        var info: [String: InfoEntry]?
    }

    private struct DiskEntry: Decodable {
        var total: UInt64?

        enum CodingKeys: String, CodingKey { case total }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? container.decodeIfPresent(LenientUnsigned.self, forKey: .total))?.value
        }
    }

    private struct MemoryEntry: Decodable {
        var total: UInt64?

        enum CodingKeys: String, CodingKey { case total }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? container.decodeIfPresent(LenientUnsigned.self, forKey: .total))?.value
        }
    }

    private struct InfoEntry: Decodable {
        var cpuCount: Int?
        var memoryTotal: UInt64?
        var disks: [String: DiskEntry]?
        var ipv4: [String]?
        var imageRelease: String?
        var snapshotCount: Int?

        enum CodingKeys: String, CodingKey {
            case cpuCount = "cpu_count"
            case memory, disks, ipv4
            case imageRelease = "image_release"
            case snapshotCount = "snapshot_count"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `cpu_count` is a string ("2") in current Multipass; accept numbers as well.
            cpuCount = (try? container.decodeIfPresent(LenientUnsigned.self, forKey: .cpuCount))?.value.flatMap { Int(exactly: $0) }
            memoryTotal = (try? container.decodeIfPresent(MemoryEntry.self, forKey: .memory))?.total
            disks = try? container.decodeIfPresent([String: DiskEntry].self, forKey: .disks)
            ipv4 = try? container.decodeIfPresent([String].self, forKey: .ipv4)
            imageRelease = try? container.decodeIfPresent(String.self, forKey: .imageRelease)
            // `snapshot_count` is emitted as a string.
            snapshotCount = (try? container.decodeIfPresent(LenientUnsigned.self, forKey: .snapshotCount))?.value.flatMap { Int(exactly: $0) }
        }
    }

    /// A non-negative integer that Multipass emits either as a JSON number or as a string.
    private struct LenientUnsigned: Decodable {
        var value: UInt64?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(UInt64.self) {
                value = number
            } else if let text = try? container.decode(String.self) {
                value = UInt64(text.trimmingCharacters(in: .whitespaces))
            } else if let double = try? container.decode(Double.self), double.isFinite, double >= 0, double < 1.8e19 {
                value = UInt64(double)
            } else {
                value = nil
            }
        }
    }
}
