import Foundation

// Rancher Desktop (rancher-sandbox/rancher-desktop). Verified against
// `src/go/rdctl/pkg/paths/paths_darwin.go`, `pkg/rancher-desktop/backend/lima.ts`,
// `pkg/rancher-desktop/config/settings.ts` and rdctl's `start.go` / `set.go` / `shutdown.go`:
// - app data `~/Library/Application Support/rancher-desktop`, Lima home `<appdata>/lima`, the VM is
//   the Lima instance `0` there; settings are NOT in the app data directory but in
//   `~/Library/Preferences/rancher-desktop/settings.json` (`virtualMachine.memoryInGB`,
//   `virtualMachine.numberCPUs`, `virtualMachine.type`, `containerEngine.name`);
// - `rdctl start` "Start up Rancher Desktop, or update its settings" accepts the settings as flags
//   (`--virtual-machine.memory-in-gb`, `--virtual-machine.number-cpus`); changing them restarts
//   the backend; `rdctl shutdown` quits the application (and with it the VM);
// - rdctl lives in `~/.rd/bin` and in the app bundle.

public enum RancherDesktopPaths {
    public static func applicationSupport(home: String) -> String { home + "/Library/Application Support/rancher-desktop" }
    public static func limaHome(home: String) -> String { applicationSupport(home: home) + "/lima" }
    public static let instanceName = "0"
    public static func instanceDirectory(home: String) -> String { limaHome(home: home) + "/" + instanceName }
    public static func settingsFile(home: String) -> String { home + "/Library/Preferences/rancher-desktop/settings.json" }
}

public struct RancherDesktopSettings: Sendable, Equatable {
    public var cpus: Int?
    public var memoryGiB: Double?
    public var vmType: String?
    public var containerEngine: String?

    /// Parses `settings.json`; unreadable or unexpected content yields all-`nil`.
    public init(parsing text: String) {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        if let machine = root["virtualMachine"] as? [String: Any] {
            if let count = (machine["numberCPUs"] as? NSNumber)?.intValue, count > 0 { cpus = count }
            if let memory = (machine["memoryInGB"] as? NSNumber)?.doubleValue, memory > 0, memory.isFinite { memoryGiB = memory }
            vmType = machine["type"] as? String
        }
        if let engine = root["containerEngine"] as? [String: Any] {
            containerEngine = engine["name"] as? String
        }
    }
}

public enum RancherDesktopCommands {
    static let startTimeout: Duration = .seconds(600)
    static let stopTimeout: Duration = .seconds(180)

    public static let tool = [
        "rdctl",
        "~/.rd/bin/rdctl",
        "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin/rdctl",
    ]

    public static func plans(for action: VMAction) -> [VMCommandPlan] {
        let start = VMCommandPlan(tool: tool, arguments: ["start"], timeout: startTimeout)
        let stop = VMCommandPlan(tool: tool, arguments: ["shutdown"], timeout: stopTimeout)
        switch action {
        case .start: return [start]
        case .stop: return [stop]
        case .restart: return [stop, start]
        }
    }

    /// `rdctl start` with settings flags updates a running application and restarts its backend.
    public static func applyPlan(changes: VMResources) -> VMCommandPlan? {
        var arguments = ["start"]
        if let cpus = changes.cpus { arguments.append("--virtual-machine.number-cpus=\(cpus)") }
        if let memory = changes.memoryBytes { arguments.append("--virtual-machine.memory-in-gb=\(VMSizeParsing.gibibyteFlagValue(fromBytes: memory))") }
        guard arguments.count > 1 else { return nil }
        return VMCommandPlan(tool: tool, arguments: arguments, timeout: startTimeout)
    }
}

public enum RancherDesktopRecordBuilder {
    /// CPUs and memory are applied through the running application (no stop needed); the disk size
    /// is an experimental setting that can only grow and is left read-only.
    public static let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: false, editRequiresStopped: false, diskCanOnlyGrow: true)

    public static func record(settings: RancherDesktopSettings?, instance: LimaInstance) -> VMRecord {
        var inst = instance
        var extra: [VMDetail] = []
        if let engine = settings?.containerEngine, !engine.isEmpty { extra.append(VMDetail(label: "Container engine", value: engine)) }
        if inst.vmType == nil, let type = settings?.vmType { inst.vmType = type }
        extra.append(VMDetail(label: "Applying changes", value: "Restarts the Rancher Desktop backend; the application must be running."))
        var record = LimaRecordBuilder.record(for: inst, nativeID: RancherDesktopPaths.instanceName, name: "Rancher Desktop", capabilities: capabilities, extraDetails: extra)
        if let cpus = settings?.cpus { record.resources.cpus = cpus }
        if let memory = settings?.memoryGiB.flatMap({ VMSizeParsing.bytes($0, unit: .gibibytes) }) { record.resources.memoryBytes = memory }
        record.capabilities = capabilities
        if record.resources.cpus == nil { record.capabilities.canEditCPUs = false }
        if record.resources.memoryBytes == nil { record.capabilities.canEditMemory = false }
        return record
    }
}
