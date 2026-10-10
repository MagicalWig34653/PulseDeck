import Foundation

// OrbStack (closed source). What is documented (docs.orbstack.dev/settings, /headless):
// `orb`/`orbctl start`, `stop`, `list`, `config set <key> <value>` with the keys `memory_mib` and
// `cpu` (CPU cores as an integer; the UI shows it as a multiple of 100 %), `config show`.
// What is not documented and was taken from the product owner's brief / community use, and needs
// a real Mac to confirm: `orbctl list -f json` (output shape), per-machine
// `orbctl start|stop|restart <machine>`, and the output of `orbctl config show`.
//
// OrbStack runs ALL machines and containers inside ONE shared Linux VM, so CPU and memory are
// global settings: the "OrbStack" entry represents that VM (host usage of its helper process,
// editable resources); machines are listed for control only and have no host usage of their own.
// There are no files PulseDeck may read for the machine list, so the listing runs the CLI and the
// monitor throttles it (`minimumListInterval`) — the one documented exception to "no polling".

public struct OrbStackMachine: Sendable, Equatable {
    public var name: String
    public var state: VMState
    public var distribution: String?
    public var architecture: String?
}

public struct OrbStackConfig: Sendable, Equatable {
    public var cpu: Int?
    public var memoryMiB: UInt64?

    public init(cpu: Int? = nil, memoryMiB: UInt64? = nil) {
        self.cpu = cpu
        self.memoryMiB = memoryMiB
    }
}

public enum OrbStackParsing {
    /// Parses `orbctl list -f json`. Tolerant of both shapes seen in the wild: a top-level array of
    /// machine objects, or an object holding such an array. Each machine needs a `name`; its state
    /// comes from `state`, `status` or `record.state`, the distribution from `image.distro` or
    /// `distro`, the architecture from `image.arch`, `arch` or `config.arch`.
    public static func machines(fromJSON text: String) -> [OrbStackMachine] {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [[String: Any]] = []
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any] {
            for value in object.values {
                if let array = value as? [[String: Any]] {
                    items = array
                    break
                }
            }
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let record = item["record"] as? [String: Any]
            let image = item["image"] as? [String: Any]
            let config = item["config"] as? [String: Any]
            let stateText = (item["state"] as? String) ?? (item["status"] as? String) ?? (record?["state"] as? String)
            let distro = (image?["distro"] as? String) ?? (item["distro"] as? String)
            let version = (image?["version"] as? String)
            let arch = (image?["arch"] as? String) ?? (item["arch"] as? String) ?? (config?["arch"] as? String)
            return OrbStackMachine(
                name: name,
                state: state(from: stateText),
                distribution: [distro, version].compactMap { $0 }.joined(separator: " ").nonEmpty,
                architecture: arch.map(normalizeArchitecture)
            )
        }
    }

    static func state(from text: String?) -> VMState {
        switch text?.lowercased() {
        case "running": .running
        case "stopped", "exited": .stopped
        case "starting", "creating": .starting
        case "stopping": .stopping
        case "paused": .paused
        default: .unknown
        }
    }

    static func normalizeArchitecture(_ text: String) -> String {
        switch text.lowercased() {
        case "arm64", "aarch64": "arm64"
        case "amd64", "x86_64": "x86_64"
        default: text
        }
    }

    /// Parses `orbctl config show`: `key: value` or `key = value` lines (or a JSON object).
    /// Unknown formats yield an empty configuration, never a guess.
    public static func config(fromShowOutput text: String) -> OrbStackConfig {
        var values: [String: String] = [:]
        if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (key, value) in object {
                if let number = value as? NSNumber { values[key] = number.stringValue } else if let string = value as? String { values[key] = string }
            }
        } else {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == ":" || $0 == "=" })
                guard parts.count == 2 else { continue }
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return OrbStackConfig(
            cpu: values["cpu"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            memoryMiB: values["memory_mib"].flatMap { UInt64($0) }.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// The processes that make up OrbStack's VM on the host: `OrbStack Helper` (the VM manager,
    /// started with the argument `vmgr` where arguments are readable).
    public static func vmProcessIDs(in processes: [VMHostProcess]) -> [Int32] {
        let helpers = processes.filter { $0.name.lowercased() == "orbstack helper" }
        let manager = helpers.filter { $0.arguments.contains("vmgr") }
        return (manager.isEmpty ? helpers : manager).map(\.pid)
    }
}

public enum OrbStackCommands {
    static let startTimeout: Duration = .seconds(180)
    static let stopTimeout: Duration = .seconds(120)
    static let queryTimeout: Duration = .seconds(10)

    public static let tool = ["orbctl", "orb", "~/.orbstack/bin/orbctl"]

    public static let vmNativeID = "vm"

    public static var listPlan: VMCommandPlan { VMCommandPlan(tool: tool, arguments: ["list", "-f", "json"], timeout: queryTimeout) }
    public static var configPlan: VMCommandPlan { VMCommandPlan(tool: tool, arguments: ["config", "show"], timeout: queryTimeout) }

    /// Machine actions name the machine; the shared VM's start/stop take no name.
    public static func plans(for action: VMAction, machine: String?) -> [VMCommandPlan] {
        let target = machine.map { [$0] } ?? []
        func plan(_ verb: String, _ timeout: Duration) -> VMCommandPlan {
            VMCommandPlan(tool: tool, arguments: [verb] + target, timeout: timeout)
        }
        switch action {
        case .start: return [plan("start", startTimeout)]
        case .stop: return [plan("stop", stopTimeout)]
        case .restart:
            // Machines have `restart`; the whole VM is stopped and started again.
            return machine == nil ? [plan("stop", stopTimeout), plan("start", startTimeout)] : [plan("restart", startTimeout + stopTimeout)]
        }
    }

    /// `orbctl config set cpu N` / `memory_mib M` (global settings).
    public static func configPlans(changes: VMResources) -> [VMCommandPlan] {
        var plans: [VMCommandPlan] = []
        if let cpus = changes.cpus {
            plans.append(VMCommandPlan(tool: tool, arguments: ["config", "set", "cpu", String(cpus)], timeout: queryTimeout))
        }
        if let memory = changes.memoryBytes {
            let mebibytes = max(1, memory / VMSizeParsing.bytesPerMiB)
            plans.append(VMCommandPlan(tool: tool, arguments: ["config", "set", "memory_mib", String(mebibytes)], timeout: queryTimeout))
        }
        return plans
    }
}

public enum OrbStackRecordBuilder {
    public static let machineCapabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true)
    /// CPU and memory are global; they apply without stopping anything (documented as live
    /// settings). The disk is managed by OrbStack and cannot be set.
    public static let vmCapabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: false, editRequiresStopped: false, diskCanOnlyGrow: true)

    public static func records(machines: [OrbStackMachine], config: OrbStackConfig, vmProcessIDs: [Int32], host: LimaHostInfo) -> [VMRecord] {
        let running = !vmProcessIDs.isEmpty
        var vmCaps = vmCapabilities
        if config.cpu == nil { vmCaps.canEditCPUs = false }
        if config.memoryMiB == nil { vmCaps.canEditMemory = false }
        let vm = VMRecord(
            nativeID: OrbStackCommands.vmNativeID,
            name: "OrbStack",
            state: running ? .running : .stopped,
            guestOS: "Linux",
            architecture: host.architecture,
            resources: VMResources(cpus: config.cpu, memoryBytes: config.memoryMiB.map { $0 * VMSizeParsing.bytesPerMiB }, diskBytes: nil),
            hostProcessIDs: vmProcessIDs,
            details: [
                VMDetail(label: "Scope", value: "One shared Linux VM runs all OrbStack machines and containers; CPU and memory limits apply to it as a whole."),
                VMDetail(label: "Host usage", value: "Counts OrbStack's helper processes."),
            ],
            capabilities: vmCaps
        )
        let machineRecords = machines.map { machine in
            var details = [VMDetail(label: "Runs in", value: "The shared OrbStack VM; host usage is shown on the OrbStack entry.")]
            if let distribution = machine.distribution { details.insert(VMDetail(label: "Distribution", value: distribution), at: 0) }
            return VMRecord(
                nativeID: machine.name,
                name: machine.name,
                state: machine.state,
                guestOS: "Linux",
                architecture: machine.architecture,
                details: details,
                capabilities: machineCapabilities
            )
        }
        return [vm] + machineRecords
    }
}
