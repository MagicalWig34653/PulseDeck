import Foundation

// Colima (abiosoft/colima). Verified against `config/files.go`, `config/profile.go`,
// `config/config.go` and `cmd/start.go`:
// - config base: $COLIMA_HOME if it exists, else ~/.colima if it exists, else $XDG_CONFIG_HOME/colima
//   or ~/.config/colima if that exists, else ~/.colima on macOS;
// - a profile's configuration is `<base>/<profile>/colima.yaml`; the profile "default" has the Lima
//   instance `colima`, any other profile `colima-<profile>`, in `<base>/_lima` (or $LIMA_HOME);
// - `colima start [profile] --cpus N --memory GiB --disk GiB` applies and (by default, flag
//   `--save-config`) saves the resources; on a running VM it only warns "already running";
// - `colima.yaml`: `cpu: 2` (int), `memory: 2` (GiB, float), `disk: 100` (GiB, int), `runtime`,
//   `vmType`, `mountType`, `arch`, `kubernetes.enabled`, `network.address`.

public struct ColimaConfig: Sendable, Equatable {
    public var cpu: Int?
    public var memoryGiB: Double?
    public var diskGiB: Int?
    public var runtime: String?
    public var vmType: String?
    public var mountType: String?
    public var architecture: String?
    public var kubernetesEnabled: Bool?
    public var networkAddress: Bool?

    public init(parsing text: String) {
        let yaml = SimpleYAML(parsing: text)
        cpu = yaml.int("cpu")
        memoryGiB = yaml.double("memory")
        diskGiB = yaml.int("disk")
        runtime = yaml.string("runtime")
        vmType = yaml.string("vmType")
        mountType = yaml.string("mountType")
        architecture = yaml.string("arch")
        kubernetesEnabled = yaml.nestedBool("kubernetes", "enabled")
        networkAddress = yaml.nestedBool("network", "address")
    }

    public var resources: VMResources {
        VMResources(
            cpus: cpu.flatMap { $0 > 0 ? $0 : nil },
            memoryBytes: memoryGiB.flatMap { VMSizeParsing.bytes($0, unit: .gibibytes) }.flatMap { $0 > 0 ? $0 : nil },
            diskBytes: diskGiB.flatMap { $0 > 0 ? VMSizeParsing.bytes(Double($0), unit: .gibibytes) : nil }
        )
    }
}

public enum ColimaPaths {
    /// Mirrors `configBaseDir` of Colima. `exists` answers "is this an existing directory?".
    public static func configBase(environment: [String: String], home: String, exists: (String) -> Bool) -> String {
        if let custom = environment["COLIMA_HOME"], !custom.isEmpty, exists(custom) { return custom }
        let dotColima = home + "/.colima"
        if exists(dotColima) { return dotColima }
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        let xdgColima = xdg + "/colima"
        if exists(xdgColima) { return xdgColima }
        return dotColima
    }

    public static func limaHome(environment: [String: String], base: String) -> String {
        if let custom = environment["LIMA_HOME"], !custom.isEmpty { return custom }
        return base + "/_lima"
    }

    /// "default" → `colima`; any other profile → `colima-<profile>`.
    public static func limaInstanceName(profile: String) -> String {
        let short = profile.hasPrefix("colima-") ? String(profile.dropFirst("colima-".count)) : profile
        return short == "default" || short == "colima" || short.isEmpty ? "colima" : "colima-" + short
    }

    /// The profile name for a Lima instance of Colima, `nil` for a foreign instance.
    public static func profile(forLimaInstance name: String) -> String? {
        if name == "colima" { return "default" }
        if name.hasPrefix("colima-"), name.count > "colima-".count { return String(name.dropFirst("colima-".count)) }
        return nil
    }

    /// Profiles from the entries of the config base and of the Lima home: every directory of the
    /// base that is not internal (`_lima`, `_store`, `_templates` start with `_`) and holds a
    /// `colima.yaml`, plus every Lima instance Colima created (even if its config is gone).
    public static func profiles(configDirectoriesWithConfig: [String], limaInstances: [String]) -> [String] {
        var result = Set(configDirectoriesWithConfig.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") })
        for instance in limaInstances {
            if let profile = profile(forLimaInstance: instance) { result.insert(profile) }
        }
        return result.sorted { lhs, rhs in
            if lhs == "default" { return rhs != "default" }
            if rhs == "default" { return false }
            return lhs < rhs
        }
    }
}

public enum ColimaCommands {
    static let startTimeout: Duration = .seconds(900)
    static let stopTimeout: Duration = .seconds(300)

    public static let tool = ["colima", "/opt/homebrew/bin/colima", "/usr/local/bin/colima"]

    /// `[profile]` is a positional argument; the default profile needs none.
    static func profileArguments(_ profile: String) -> [String] {
        profile == "default" ? [] : [profile]
    }

    public static func plans(for action: VMAction, profile: String) -> [VMCommandPlan] {
        let argument = profileArguments(profile)
        switch action {
        case .start:
            return [VMCommandPlan(tool: tool, arguments: ["start"] + argument, timeout: startTimeout)]
        case .stop:
            return [VMCommandPlan(tool: tool, arguments: ["stop"] + argument, timeout: stopTimeout)]
        case .restart:
            return [VMCommandPlan(tool: tool, arguments: ["restart"] + argument, timeout: startTimeout + stopTimeout)]
        }
    }

    /// `colima start [profile] --cpus N --memory G --disk G`. Colima persists the values in
    /// `colima.yaml` (flag `--save-config`, on by default) and starts the VM.
    public static func startWithResources(profile: String, changes: VMResources) -> VMCommandPlan {
        var arguments = ["start"] + profileArguments(profile)
        if let cpus = changes.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = changes.memoryBytes { arguments += ["--memory", VMSizeParsing.gibibyteFlagValue(fromBytes: memory)] }
        if let disk = changes.diskBytes { arguments += ["--disk", String(diskGiB(fromBytes: disk))] }
        return VMCommandPlan(tool: tool, arguments: arguments, timeout: startTimeout)
    }

    /// Whole GiB (Colima's `disk` is an integer), at least 1.
    public static func diskGiB(fromBytes bytes: UInt64) -> Int {
        max(1, Int((Double(bytes) / Double(VMSizeParsing.bytesPerGiB)).rounded()))
    }

    /// New text of `colima.yaml` with the changed resources, comments and everything else kept.
    /// Used when the VM is only to be reconfigured, not started. `nil` if a key is not a plain
    /// scalar line (the file is then left alone rather than rewritten blindly).
    public static func editedConfiguration(_ text: String, changes: VMResources) -> String? {
        var result = text
        if let cpus = changes.cpus {
            guard let edited = SimpleYAML.settingTopLevelScalar("cpu", to: String(cpus), in: result) else { return nil }
            result = edited
        }
        if let memory = changes.memoryBytes {
            guard let edited = SimpleYAML.settingTopLevelScalar("memory", to: VMSizeParsing.gibibyteFlagValue(fromBytes: memory), in: result) else { return nil }
            result = edited
        }
        if let disk = changes.diskBytes {
            guard let edited = SimpleYAML.settingTopLevelScalar("disk", to: String(diskGiB(fromBytes: disk)), in: result) else { return nil }
            result = edited
        }
        return result
    }
}

public enum ColimaRecordBuilder {
    /// Capabilities: Colima applies new resources only when it starts the VM; the disk can only grow.
    public static let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: true, editRequiresStopped: true, diskCanOnlyGrow: true)

    public static func record(profile: String, config: ColimaConfig?, instance: LimaInstance, host: LimaHostInfo) -> VMRecord {
        var extra: [VMDetail] = [VMDetail(label: "Profile", value: profile)]
        if let runtime = config?.runtime { extra.append(VMDetail(label: "Container runtime", value: runtime)) }
        if config?.kubernetesEnabled == true { extra.append(VMDetail(label: "Kubernetes", value: "enabled")) }
        if config?.networkAddress == true { extra.append(VMDetail(label: "Network", value: "reachable address enabled")) }

        var inst = instance
        let configured = config?.resources ?? VMResources()
        // `colima.yaml` is what the user edits and what the next start applies: prefer it.
        let resources = VMResources(
            cpus: configured.cpus ?? (instance.configurationReadable ? instance.resources.cpus : nil),
            memoryBytes: configured.memoryBytes ?? (instance.configurationReadable ? instance.resources.memoryBytes : nil),
            diskBytes: configured.diskBytes ?? (instance.configurationReadable ? instance.resources.diskBytes : nil)
        )
        if !instance.configurationReadable, let config {
            // Never started: no Lima instance yet, describe the profile from its own file.
            inst.architecture = LimaInspector.architecture(config.architecture, host: host)
            inst.vmType = config.vmType.flatMap { $0 == "default" ? nil : $0 }
            inst.mountType = config.mountType
            inst.configurationReadable = true
        }
        if configured.cpus != nil || configured.memoryBytes != nil || configured.diskBytes != nil {
            inst.defaultedResources.removeAll()
        }

        var record = LimaRecordBuilder.record(for: inst, nativeID: profile, name: profile == "default" ? "colima" : "colima (\(profile))", capabilities: capabilities, extraDetails: extra)
        record.resources = resources
        let hasConfiguration = config != nil || instance.configurationReadable
        if !hasConfiguration {
            record.capabilities.canEditCPUs = false
            record.capabilities.canEditMemory = false
            record.capabilities.canEditDisk = false
        } else {
            record.capabilities = capabilities
        }
        return record
    }
}
