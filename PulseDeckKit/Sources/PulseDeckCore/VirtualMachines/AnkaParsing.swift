import Foundation

/// Veertu Anka. The VM library under `~/.anka` is internal (not documented as a readable
/// interface), so listing runs the documented machine-readable CLI (throttled by the adapter):
/// `anka --machine-readable list` → `{"status":"OK","body":[{"name","uuid","creation_date",
/// "version"?,"status"}]}` and `anka --machine-readable show <uuid>` → `body.cpu_cores`,
/// `body.ram_size`, `body.hard_drive` (bytes), `body.arch`. Both shapes are from Veertu's
/// command-line reference examples.
public enum AnkaParsing {
    public static let providerID = VMProviderID.anka.rawValue
    public static let bytesPerMiB: UInt64 = 1_048_576
    public static let bytesPerGiB: UInt64 = 1_073_741_824

    public struct ListEntry: Hashable, Sendable {
        public var uuid: String
        public var name: String
        /// Template tag (`vanilla`, `v2`, …).
        public var tag: String?
        public var status: String?
    }

    public struct Properties: Hashable, Sendable {
        public var cpuCores: Int?
        public var ramBytes: UInt64?
        public var diskBytes: UInt64?
        /// `arch` as reported (2 on Apple silicon in Veertu's `show` sample).
        public var arch: Int?
    }

    // MARK: JSON

    private static func body(_ output: String) -> Any? {
        guard let start = output.firstIndex(where: { $0 == "{" }),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              (object["status"] as? String) == "OK" else { return nil }
        return object["body"]
    }

    public static func parseList(_ output: String) -> [ListEntry] {
        guard let entries = body(output) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let uuid = entry["uuid"] as? String, let name = entry["name"] as? String else { return nil }
            return ListEntry(uuid: uuid, name: name, tag: entry["version"] as? String, status: entry["status"] as? String)
        }
    }

    public static func parseShow(_ output: String) -> Properties? {
        guard let body = body(output) as? [String: Any] else { return nil }
        return Properties(
            cpuCores: integer(body["cpu_cores"]).flatMap { $0 > 0 ? Int($0) : nil },
            ramBytes: integer(body["ram_size"]) ?? (body["ram"] as? String).flatMap { UInt64($0) },
            diskBytes: integer(body["hard_drive"]),
            arch: integer(body["arch"]).map { Int($0) }
        )
    }

    private static func integer(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber, number.int64Value >= 0 { return UInt64(number.int64Value) }
        if let text = value as? String { return UInt64(text) }
        return nil
    }

    public static func state(_ status: String?) -> VMState {
        switch status?.lowercased() {
        case "running", "started": .running
        case "stopped": .stopped
        case "suspended": .suspended
        case "paused": .paused
        case "starting": .starting
        case "stopping": .stopping
        default: .unknown
        }
    }

    // MARK: Record

    public static let hostUsageNote = "Anka does not document how its VM processes can be mapped to a VM, so host CPU and memory use are not shown."

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: true,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    public static func makeRecord(_ entry: ListEntry, properties: Properties?) -> VMRecord {
        var capabilities = Self.capabilities
        capabilities.canEditCPUs = properties?.cpuCores != nil
        capabilities.canEditMemory = properties?.ramBytes != nil
        capabilities.canEditDisk = properties?.diskBytes != nil
        var details: [VMDetail] = []
        if let tag = entry.tag { details.append(VMDetail(label: "Tag", value: tag)) }
        details.append(VMDetail(label: "UUID", value: entry.uuid))
        details.append(VMDetail(label: "Host usage", value: hostUsageNote))
        return VMRecord(
            nativeID: entry.uuid,
            name: entry.name,
            state: state(entry.status),
            guestOS: "macOS", // Anka runs macOS guests only
            architecture: properties?.arch == 2 ? "arm64" : nil,
            resources: VMResources(cpus: properties?.cpuCores, memoryBytes: properties?.ramBytes, diskBytes: properties?.diskBytes),
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: Commands

    /// `--machine-readable` (`-j`) is a global option and goes before the command.
    public static let listArguments = ["--machine-readable", "list"]
    public static func showArguments(uuid: String) -> [String] { ["--machine-readable", "show", uuid] }
    public static func startArguments(uuid: String) -> [String] { ["start", uuid] }
    public static func stopArguments(uuid: String) -> [String] { ["stop", uuid] }

    /// Size argument for `anka modify … ram|disk`: suffixes `T|G|M|K`; whole GiB when exact.
    public static func sizeArgument(bytes: UInt64) -> String {
        bytes % bytesPerGiB == 0 ? "\(bytes / bytesPerGiB)G" : "\(max(1, bytes / bytesPerMiB))M"
    }

    /// One `anka modify` call per changed value: `cpu N`, `ram SIZE`, `disk --size SIZE`
    /// (disk only when it grows; Anka cannot shrink disks).
    public static func modifyCommands(uuid: String, new: VMResources, current: VMResources) -> [[String]] {
        var commands: [[String]] = []
        if let cpus = new.cpus, cpus > 0, cpus != current.cpus {
            commands.append(["modify", uuid, "cpu", String(cpus)])
        }
        if let memory = new.memoryBytes, memory >= bytesPerMiB, memory != current.memoryBytes {
            commands.append(["modify", uuid, "ram", sizeArgument(bytes: memory)])
        }
        if let disk = new.diskBytes, disk > (current.diskBytes ?? 0) {
            commands.append(["modify", uuid, "disk", "--size", sizeArgument(bytes: disk)])
        }
        return commands
    }
}
