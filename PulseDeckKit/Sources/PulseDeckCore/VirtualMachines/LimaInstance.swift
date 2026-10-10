import Foundation

// Lima instance directories (`~/.lima/<name>/`), shared by the Lima, Colima, Finch and Rancher
// Desktop adapters (all four run Lima instances, each with its own LIMA_HOME).
//
// Facts used here (verified against lima-vm/lima `pkg/limatype/filenames` and
// `pkg/store/instance.go`):
// - `lima.yaml` holds the instance configuration; `cpus`, `memory`, `disk`, `vmType`, `arch`, `os`
//   may be absent or `null`, in which case Lima's built-in defaults apply
//   (cpus = min(4, host cores), memory = min(4GiB, half of host memory), disk = 100GiB).
// - `ha.pid` is the PID of the host agent (`limactl hostagent`), `<vmType>.pid` (`qemu.pid`,
//   `vz.pid` …) the one of the VM driver. Lima calls the instance running when both exist and
//   the processes are alive; a PID file written before the last reboot must be ignored — PulseDeck
//   checks every PID against the live process table, which covers that case and PID reuse.
// - `ssh.config` contains a `Port <n>` line: the forwarded SSH port on 127.0.0.1.

/// The files of one instance directory, already read by the telemetry module.
public struct LimaInstanceFiles: Sendable, Equatable {
    public var name: String
    public var directory: String
    public var limaYAML: String?
    public var sshConfig: String?
    /// Contents of `lima-version` (the Lima version that created the instance).
    public var limaVersion: String?
    /// Contents of every `*.pid` file by file name (`ha.pid`, `qemu.pid`, `vz.pid`).
    public var pidFiles: [String: String]
    /// Modification date of `ha.pid` ≈ when the host agent started.
    public var hostAgentStartedAt: Date?

    public init(name: String, directory: String, limaYAML: String? = nil, sshConfig: String? = nil, limaVersion: String? = nil, pidFiles: [String: String] = [:], hostAgentStartedAt: Date? = nil) {
        self.name = name
        self.directory = directory
        self.limaYAML = limaYAML
        self.sshConfig = sshConfig
        self.limaVersion = limaVersion
        self.pidFiles = pidFiles
        self.hostAgentStartedAt = hostAgentStartedAt
    }
}

/// Host facts needed to resolve Lima's built-in defaults.
public struct LimaHostInfo: Sendable, Equatable {
    public var cpuCount: Int
    public var memoryBytes: UInt64
    /// "arm64" or "x86_64".
    public var architecture: String

    public init(cpuCount: Int, memoryBytes: UInt64, architecture: String) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.architecture = architecture
    }
}

/// What PulseDeck knows about one Lima instance.
public struct LimaInstance: Sendable, Equatable {
    public var name: String
    public var directory: String
    public var state: VMState
    public var resources: VMResources
    /// Which of CPUs / memory / disk are Lima's defaults because `lima.yaml` does not set them.
    public var defaultedResources: [String]
    public var vmType: String?
    public var architecture: String
    public var guestOS: String
    public var mountType: String?
    public var sshPort: Int?
    public var limaVersion: String?
    public var hostProcessIDs: [Int32]
    public var startedAt: Date?
    public var configurationReadable: Bool
}

public enum LimaInspector {
    /// Host agent seen without a driver PID file for this long counts as running (see `state`).
    static let startupGrace: TimeInterval = 120

    public static func inspect(_ files: LimaInstanceFiles, processes: [VMHostProcess], host: LimaHostInfo, now: Date = Date()) -> LimaInstance {
        let yaml = SimpleYAML(parsing: files.limaYAML ?? "")

        // Resources, with Lima's defaults where the file says nothing.
        var defaulted: [String] = []
        let cpus: Int
        if let configured = yaml.int("cpus"), configured > 0 {
            cpus = configured
        } else {
            cpus = max(1, min(4, host.cpuCount))
            defaulted.append("CPUs")
        }
        let memory: UInt64
        if let text = yaml.string("memory"), let parsed = VMSizeParsing.bytes(from: text, defaultUnit: .bytes), parsed > 0 {
            memory = parsed
        } else {
            memory = min(4 * VMSizeParsing.bytesPerGiB, host.memoryBytes / 2)
            defaulted.append("memory")
        }
        let disk: UInt64
        if let text = yaml.string("disk"), let parsed = VMSizeParsing.bytes(from: text, defaultUnit: .bytes), parsed > 0 {
            disk = parsed
        } else {
            disk = 100 * VMSizeParsing.bytesPerGiB
            defaulted.append("disk")
        }

        let (state, pids) = derive(files: files, processes: processes, now: now)
        return LimaInstance(
            name: files.name,
            directory: files.directory,
            state: state,
            resources: VMResources(cpus: cpus, memoryBytes: memory, diskBytes: disk),
            defaultedResources: defaulted,
            vmType: yaml.string("vmType").flatMap { $0 == "default" ? nil : $0 },
            architecture: architecture(yaml.string("arch"), host: host),
            guestOS: guestOS(yaml.string("os")),
            mountType: yaml.string("mountType"),
            sshPort: files.sshConfig.flatMap(LimaSSHConfig.port),
            limaVersion: files.limaVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            hostProcessIDs: pids,
            startedAt: state == .stopped ? nil : files.hostAgentStartedAt,
            configurationReadable: files.limaYAML != nil
        )
    }

    /// State from the PID files and the live process table.
    ///
    /// Lima's own rule: host agent and driver both alive = running, neither = stopped, one of
    /// them = broken. PulseDeck maps the in-between cases to what the user sees happening:
    /// only the host agent = starting, only the driver = stopping. Lima 2 drivers may not write a
    /// driver PID file at all; a host agent that has run for longer than `startupGrace` without
    /// one is therefore treated as running (unverified without a Mac — see the report).
    static func derive(files: LimaInstanceFiles, processes: [VMHostProcess], now: Date) -> (VMState, [Int32]) {
        let alive = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })

        var hostAgentAlive = false
        var pids: [Int32] = []
        if let pid = pidValue(files.pidFiles["ha.pid"]), let process = alive[pid], process.name.lowercased() == "limactl" {
            hostAgentAlive = true
            pids.append(pid)
        }
        var driverFileExists = false
        var driverAlive = false
        for (fileName, content) in files.pidFiles.sorted(by: { $0.key < $1.key }) where fileName != "ha.pid" && fileName.hasSuffix(".pid") {
            driverFileExists = true
            if let pid = pidValue(content), alive[pid] != nil {
                driverAlive = true
                if !pids.contains(pid) { pids.append(pid) }
            }
        }

        let state: VMState
        switch (hostAgentAlive, driverAlive) {
        case (true, true):
            state = .running
        case (false, false):
            state = .stopped
        case (true, false):
            let age = files.hostAgentStartedAt.map { now.timeIntervalSince($0) }
            if !driverFileExists, let age, age > startupGrace {
                state = .running
            } else {
                state = .starting
            }
        case (false, true):
            state = .stopping
        }
        return (state, pids)
    }

    static func pidValue(_ content: String?) -> Int32? {
        guard let text = content?.trimmingCharacters(in: .whitespacesAndNewlines), let value = Int32(text), value > 0 else { return nil }
        return value
    }

    static func architecture(_ configured: String?, host: LimaHostInfo) -> String {
        let value = configured?.lowercased() ?? "default"
        switch value {
        case "aarch64", "arm64": return "arm64"
        case "x86_64", "amd64": return "x86_64"
        case "default", "host": return host.architecture
        default: return value
        }
    }

    static func guestOS(_ configured: String?) -> String {
        let value = configured?.lowercased() ?? "linux"
        switch value {
        case "linux": return "Linux"
        case "darwin": return "macOS"
        default: return String(value.prefix(1)).uppercased() + String(value.dropFirst())
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

public enum LimaSSHConfig {
    /// The `Port <n>` line of Lima's generated `ssh.config`.
    public static func port(in text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[0].lowercased() == "port", let port = Int(parts[1]), (1...65535).contains(port) {
                return port
            }
        }
        return nil
    }
}

// MARK: - Locations and ownership

public enum LimaPaths {
    /// `LIMA_HOME` if set (a GUI app only sees it when launched from a shell), else `~/.lima`.
    public static func limaHome(environment: [String: String], home: String) -> String {
        if let custom = environment["LIMA_HOME"], !custom.isEmpty { return custom }
        return home + "/.lima"
    }

    /// Lima homes owned by other PulseDeck providers: their instances must not appear twice.
    public static func foreignHomes(home: String) -> [String] {
        [
            home + "/.colima/_lima",
            home + "/.config/colima/_lima",
            home + "/Library/Application Support/rancher-desktop/lima",
            "/Applications/Finch/lima/data",
        ]
    }

    public static func isForeign(limaHome: String, home: String) -> Bool {
        let normalized = normalize(limaHome)
        return foreignHomes(home: home).contains { normalize($0) == normalized }
    }

    /// An instance named like a Colima instance (`colima`, `colima-<profile>`) while Colima is
    /// installed belongs to Colima even if both share one directory through `LIMA_HOME`.
    public static func isColimaInstance(name: String) -> Bool {
        name == "colima" || name.hasPrefix("colima-")
    }

    static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

// MARK: - Capabilities and commands

public enum LimaCapabilityRules {
    /// `limactl edit --disk` (growing a disk of an existing instance) is accepted since Lima 1.1.0;
    /// Lima 1.0.x marks the flag "only valid for new instances".
    public static let diskEditMinimumVersion = VMVersion("1.1.0")

    /// Instances can always be started and stopped. CPUs and memory are editable on a stopped
    /// instance with `limactl edit` (flags exist since Lima 0.23 at the latest); the disk only
    /// when the installed Lima is known to be new enough — an unknown version is not guessed.
    public static func capabilities(installedVersion: VMVersion?) -> VMCapabilities {
        let diskEditable: Bool
        if let installedVersion, let minimum = diskEditMinimumVersion {
            diskEditable = installedVersion >= minimum
        } else {
            diskEditable = false
        }
        return VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: diskEditable, editRequiresStopped: true, diskCanOnlyGrow: true)
    }
}

public enum LimaCommands {
    /// `limactl start` can download an image on first start: generous.
    static let startTimeout: Duration = .seconds(600)
    static let stopTimeout: Duration = .seconds(180)
    static let editTimeout: Duration = .seconds(60)

    public static let tool = ["limactl", "/opt/homebrew/bin/limactl", "/usr/local/bin/limactl"]

    public static func plans(for action: VMAction, instance: String, tool: [String] = tool, environment: [String: String] = [:]) -> [VMCommandPlan] {
        switch action {
        case .start:
            [VMCommandPlan(tool: tool, arguments: ["start", instance], timeout: startTimeout, environment: environment)]
        case .stop:
            [VMCommandPlan(tool: tool, arguments: ["stop", instance], timeout: stopTimeout, environment: environment)]
        case .restart:
            [VMCommandPlan(tool: tool, arguments: ["restart", instance], timeout: startTimeout + stopTimeout, environment: environment)]
        }
    }

    /// `limactl edit <name> --cpus N --memory GiB --disk GiB` on a stopped instance, then a start
    /// when the instance was running before.
    public static func editPlans(instance: String, changes: VMResources, restartAfterwards: Bool, tool: [String] = tool, environment: [String: String] = [:]) -> [VMCommandPlan] {
        var arguments = ["edit", instance]
        if let cpus = changes.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = changes.memoryBytes { arguments += ["--memory", VMSizeParsing.gibibyteFlagValue(fromBytes: memory)] }
        if let disk = changes.diskBytes { arguments += ["--disk", VMSizeParsing.gibibyteFlagValue(fromBytes: disk)] }
        var plans: [VMCommandPlan] = []
        if arguments.count > 2 {
            plans.append(VMCommandPlan(tool: tool, arguments: arguments, timeout: editTimeout, environment: environment))
        }
        if restartAfterwards {
            plans.append(contentsOf: self.plans(for: .start, instance: instance, tool: tool, environment: environment))
        }
        return plans
    }
}

// MARK: - Records

public enum LimaRecordBuilder {
    /// Builds the provider-independent record for a Lima-based instance.
    public static func record(for instance: LimaInstance, nativeID: String, name: String, capabilities: VMCapabilities, extraDetails: [VMDetail] = []) -> VMRecord {
        var details: [VMDetail] = extraDetails
        if let vmType = instance.vmType { details.append(VMDetail(label: "VM type", value: vmType)) }
        if let mountType = instance.mountType { details.append(VMDetail(label: "Mount type", value: mountType)) }
        if let port = instance.sshPort { details.append(VMDetail(label: "SSH", value: "127.0.0.1:\(port)")) }
        if let version = instance.limaVersion { details.append(VMDetail(label: "Created with Lima", value: version)) }
        details.append(VMDetail(label: "Location", value: instance.directory))
        if !instance.defaultedResources.isEmpty {
            details.append(VMDetail(label: "Default values", value: "Not set in lima.yaml, Lima's built-in default shown for: " + instance.defaultedResources.joined(separator: ", ")))
        }
        if !instance.configurationReadable {
            details.append(VMDetail(label: "Configuration", value: "lima.yaml could not be read"))
        }
        return VMRecord(
            nativeID: nativeID,
            name: name,
            state: instance.state,
            guestOS: instance.guestOS,
            architecture: instance.architecture,
            resources: instance.configurationReadable ? instance.resources : VMResources(),
            ipAddress: nil,
            startedAt: instance.startedAt,
            hostProcessIDs: instance.hostProcessIDs,
            details: details,
            capabilities: instance.configurationReadable ? capabilities : VMCapabilities(canStart: capabilities.canStart, canStop: capabilities.canStop, canRestart: capabilities.canRestart, canEditCPUs: false, canEditMemory: false, canEditDisk: false)
        )
    }
}
