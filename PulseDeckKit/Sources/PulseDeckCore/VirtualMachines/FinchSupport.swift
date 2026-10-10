import Foundation

// Finch (runfinch/finch). Verified against `pkg/path/finch_remote.go`, `pkg/path/finch_darwin.go`
// and `cmd/finch/virtual_machine_settings_darwin.go`:
// - Finch lives in /Applications/Finch; its Lima home (LIMA_HOME) is `<finch>/lima/data`, the VM
//   is the Lima instance `finch` there, with Finch's bundled limactl in `<finch>/lima/bin`;
// - Finch's own configuration is `~/.finch/finch.yaml` (`cpus`, `memory`, `vmType` …);
// - `finch vm start|stop|status|init|remove`; `finch vm settings --cpus N --memory 4GiB
//   [--bootdisk … --datadisk …]` rewrites finch.yaml and says "restart the vm when applying this
//   change". The boot/data disk split is not mapped to a single disk size here, so the disk is
//   read-only.

public enum FinchPaths {
    public static let installDirectory = "/Applications/Finch"
    public static let limaHome = installDirectory + "/lima/data"
    public static let instanceName = "finch"
    public static let instanceDirectory = limaHome + "/" + instanceName

    public static func configFile(home: String) -> String { home + "/.finch/finch.yaml" }
}

public struct FinchConfig: Sendable, Equatable {
    public var cpus: Int?
    public var memoryBytes: UInt64?
    public var vmType: String?

    public init(parsing text: String) {
        let yaml = SimpleYAML(parsing: text)
        cpus = yaml.int("cpus").flatMap { $0 > 0 ? $0 : nil }
        memoryBytes = yaml.string("memory").flatMap { VMSizeParsing.bytes(from: $0) }.flatMap { $0 > 0 ? $0 : nil }
        vmType = yaml.string("vmType")
    }
}

public enum FinchCommands {
    static let startTimeout: Duration = .seconds(600)
    static let stopTimeout: Duration = .seconds(180)
    static let settingsTimeout: Duration = .seconds(60)

    public static let tool = ["finch", "/Applications/Finch/bin/finch", "/opt/homebrew/bin/finch", "/usr/local/bin/finch"]

    /// `finch vm` has no restart command: stop, then start.
    public static func plans(for action: VMAction) -> [VMCommandPlan] {
        let start = VMCommandPlan(tool: tool, arguments: ["vm", "start"], timeout: startTimeout)
        let stop = VMCommandPlan(tool: tool, arguments: ["vm", "stop"], timeout: stopTimeout)
        switch action {
        case .start: return [start]
        case .stop: return [stop]
        case .restart: return [stop, start]
        }
    }

    /// `finch vm settings` only edits finch.yaml; the values apply at the next VM start.
    public static func settingsPlans(changes: VMResources, startAfterwards: Bool) -> [VMCommandPlan] {
        var arguments = ["vm", "settings"]
        if let cpus = changes.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = changes.memoryBytes { arguments += ["--memory", VMSizeParsing.suffixedString(fromBytes: memory)] }
        var plans: [VMCommandPlan] = []
        if arguments.count > 2 { plans.append(VMCommandPlan(tool: tool, arguments: arguments, timeout: settingsTimeout)) }
        if startAfterwards { plans.append(contentsOf: self.plans(for: .start)) }
        return plans
    }
}

public enum FinchRecordBuilder {
    public static let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: false, editRequiresStopped: true, diskCanOnlyGrow: true)

    public static func record(config: FinchConfig?, instance: LimaInstance, configFile: String) -> VMRecord {
        var inst = instance
        var extra = [VMDetail(label: "Finch configuration", value: configFile)]
        if let vmType = config?.vmType, inst.vmType == nil { inst.vmType = vmType }
        if !instance.configurationReadable {
            extra.append(VMDetail(label: "Note", value: "The Finch VM has not been created yet (finch vm init)."))
        }
        var record = LimaRecordBuilder.record(for: inst, nativeID: FinchPaths.instanceName, name: "finch", capabilities: capabilities, extraDetails: extra)
        // finch.yaml is what `finch vm settings` edits and the next start applies.
        if let cpus = config?.cpus { record.resources.cpus = cpus }
        if let memory = config?.memoryBytes { record.resources.memoryBytes = memory }
        record.capabilities = capabilities
        if record.resources.cpus == nil { record.capabilities.canEditCPUs = false }
        if record.resources.memoryBytes == nil { record.capabilities.canEditMemory = false }
        return record
    }
}
