import Foundation

// Docker Desktop for Mac. The settings file is
// `~/Library/Group Containers/group.com.docker/settings-store.json` (Docker Desktop 4.35 and
// later; earlier versions used `settings.json` in the same directory) — path confirmed by
// Docker's documentation. The resource key names (`Cpus`/`cpus`, `MemoryMiB`/`memoryMiB`,
// `DiskSizeMiB`/`diskSizeMiB`) are community-reported, not documented, so they are looked up
// case-insensitively and an absent key stays unknown.
//
// The VM is read-only in PulseDeck: Docker Desktop owns its settings (they may be locked by an
// administrator and the app rewrites the file). Start/stop/restart use the `docker desktop` CLI
// (`docker desktop start|stop|restart`, Docker Desktop 4.37+); older versions answer with an
// error that is shown to the user.

public struct DockerDesktopSettings: Sendable, Equatable {
    public var cpus: Int?
    public var memoryMiB: UInt64?
    public var diskSizeMiB: UInt64?

    public init(parsing text: String) {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let lowered = Dictionary(root.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let value = (lowered["cpus"] as? NSNumber)?.intValue, value > 0 { cpus = value }
        if let value = (lowered["memorymib"] as? NSNumber)?.uint64Value, value > 0 { memoryMiB = value }
        if let value = (lowered["disksizemib"] as? NSNumber)?.uint64Value, value > 0 { diskSizeMiB = value }
    }

    public var resources: VMResources {
        VMResources(
            cpus: cpus,
            memoryBytes: memoryMiB.map { $0 * VMSizeParsing.bytesPerMiB },
            diskBytes: diskSizeMiB.map { $0 * VMSizeParsing.bytesPerMiB }
        )
    }
}

public enum DockerDesktopPaths {
    public static func groupContainer(home: String) -> String { home + "/Library/Group Containers/group.com.docker" }
    /// Newest format first.
    public static func settingsFiles(home: String) -> [String] {
        [groupContainer(home: home) + "/settings-store.json", groupContainer(home: home) + "/settings.json"]
    }
}

public enum DockerDesktopProcesses {
    /// The host processes that run the Docker Desktop VM: `com.docker.virtualization` (Apple
    /// Virtualization framework), `com.docker.hyperkit` (legacy), or a QEMU process started from
    /// the Docker application.
    public static func vmProcessIDs(in processes: [VMHostProcess]) -> [Int32] {
        processes.filter { process in
            let name = process.name.lowercased()
            if name == "com.docker.virtualization" || name == "com.docker.hyperkit" { return true }
            if name.hasPrefix("qemu-system") {
                let path = process.executablePath?.lowercased() ?? ""
                return path.contains("docker.app") || path.contains("com.docker")
            }
            return false
        }.map(\.pid)
    }

    /// The Docker Desktop application / backend is up (the VM may still be stopped, e.g. by Resource Saver).
    public static func backendIsRunning(in processes: [VMHostProcess]) -> Bool {
        processes.contains { $0.name.lowercased() == "com.docker.backend" || $0.name.lowercased() == "docker desktop" }
    }
}

public enum DockerDesktopCommands {
    static let startTimeout: Duration = .seconds(300)
    static let stopTimeout: Duration = .seconds(120)

    public static let tool = ["docker", "~/.docker/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker"]

    public static func plans(for action: VMAction) -> [VMCommandPlan] {
        switch action {
        case .start: [VMCommandPlan(tool: tool, arguments: ["desktop", "start"], timeout: startTimeout)]
        case .stop: [VMCommandPlan(tool: tool, arguments: ["desktop", "stop"], timeout: stopTimeout)]
        case .restart: [VMCommandPlan(tool: tool, arguments: ["desktop", "restart"], timeout: startTimeout + stopTimeout)]
        }
    }
}

public enum DockerDesktopRecordBuilder {
    public static let nativeID = "vm"
    public static let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true)

    public static func record(settings: DockerDesktopSettings?, vmProcessIDs: [Int32], backendRunning: Bool, host: LimaHostInfo, settingsFile: String?) -> VMRecord {
        var details = [VMDetail(label: "Settings", value: "Read-only: Docker Desktop manages its own VM settings.")]
        if let settingsFile { details.append(VMDetail(label: "Settings file", value: settingsFile)) }
        if vmProcessIDs.isEmpty, backendRunning {
            details.append(VMDetail(label: "Note", value: "The application is open but its VM is not running (for example paused by Resource Saver)."))
        }
        return VMRecord(
            nativeID: nativeID,
            name: "Docker Desktop",
            state: vmProcessIDs.isEmpty ? .stopped : .running,
            guestOS: "Linux",
            architecture: host.architecture,
            resources: settings?.resources ?? VMResources(),
            hostProcessIDs: vmProcessIDs,
            details: details,
            capabilities: capabilities
        )
    }
}
