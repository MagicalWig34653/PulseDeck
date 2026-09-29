import Foundation

/// Decodes Docker Engine API responses (`/containers/json`, `/containers/{id}/stats`,
/// `/version`) and derives rates. Field names follow the Docker Engine API reference.
public struct DockerStatsTracker: Sendable {
    public struct ContainerSummary: Decodable, Sendable {
        public var Id: String
        public var Names: [String]?
        public var Image: String?
        public var State: String?
        public var Status: String?
        public var Created: Int64?
        public var Ports: [Port]?
        public var Labels: [String: String]?

        public struct Port: Decodable, Sendable {
            public var privatePort: Int?
            public var publicPort: Int?
            public var protocolName: String?

            enum CodingKeys: String, CodingKey {
                case privatePort = "PrivatePort"
                case publicPort = "PublicPort"
                case protocolName = "Type"
            }
        }
    }

    struct Stats: Decodable {
        var cpu_stats: CPUStats?
        var memory_stats: MemoryStats?
        var networks: [String: NetworkStats]?
        var pids_stats: PIDs?

        struct CPUStats: Decodable {
            var cpu_usage: CPUUsage?
        }

        struct CPUUsage: Decodable {
            var total_usage: UInt64?
        }

        struct MemoryStats: Decodable {
            var usage: UInt64?
            var limit: UInt64?
            var stats: [String: UInt64]?
        }

        struct NetworkStats: Decodable {
            var rx_bytes: UInt64?
            var tx_bytes: UInt64?
        }

        struct PIDs: Decodable {
            var current: Int?
        }
    }

    struct VersionInfo: Decodable {
        var version: String?

        enum CodingKeys: String, CodingKey {
            case version = "Version"
        }
    }

    private var rates = CounterRateTracker<String>()

    public init() {}

    public static func containers(fromJSON json: [UInt8]) -> [ContainerSummary]? {
        try? JSONDecoder().decode([ContainerSummary].self, from: Data(json))
    }

    public static func engineVersion(fromJSON json: [UInt8]) -> String? {
        (try? JSONDecoder().decode(VersionInfo.self, from: Data(json)))?.version
    }

    /// Builds a container row. `statsJSON` is the one-shot stats document of a running container,
    /// `nil` for stopped ones (their resource columns are not applicable) or when it failed.
    public mutating func snapshot(for summary: ContainerSummary, statsJSON: [UInt8]?, at instant: MonotonicInstant) -> ContainerSnapshot {
        let isRunning = summary.State == "running"
        var cpu: MetricState<Double> = .unavailable(.notApplicable)
        var memory: MetricState<UInt64> = .unavailable(.notApplicable)
        var limit: MetricState<UInt64> = .unavailable(.notApplicable)
        var received: MetricState<Double> = .unavailable(.notApplicable)
        var sent: MetricState<Double> = .unavailable(.notApplicable)
        var processes: MetricState<Int> = .unavailable(.notApplicable)

        if isRunning {
            if let json = statsJSON, let stats = try? JSONDecoder().decode(Stats.self, from: Data(json)) {
                let cpuNanoseconds = stats.cpu_stats?.cpu_usage?.total_usage ?? 0
                let networks = Array((stats.networks ?? [:]).values)
                let rx = networks.reduce(UInt64(0)) { $0 &+ ($1.rx_bytes ?? 0) }
                let tx = networks.reduce(UInt64(0)) { $0 &+ ($1.tx_bytes ?? 0) }
                let counters = rates.update(key: summary.Id, generation: 0, counters: [cpuNanoseconds, rx, tx], at: instant)
                let nanosecondsPerSecond = 1e9
                cpu = counters[0].map { $0 / nanosecondsPerSecond }
                received = counters[1]
                sent = counters[2]
                memory = Self.workingSet(stats.memory_stats).map { .available($0) } ?? .unavailable(.transientFailure("no memory stats"))
                limit = stats.memory_stats?.limit.map { .available($0) } ?? .unavailable(.transientFailure("no memory limit"))
                processes = stats.pids_stats?.current.map { .available($0) } ?? .unavailable(.transientFailure("no pid stats"))
            } else {
                let failure = UnavailableReason.transientFailure("stats request failed")
                (cpu, memory, limit, received, sent, processes) = (.unavailable(failure), .unavailable(failure), .unavailable(failure), .unavailable(failure), .unavailable(failure), .unavailable(failure))
            }
        }

        return ContainerSnapshot(
            id: summary.Id,
            name: summary.Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(summary.Id.prefix(12)),
            image: summary.Image ?? "",
            state: summary.State ?? "unknown",
            status: summary.Status ?? "",
            created: summary.Created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            ports: Self.ports(summary.Ports ?? []),
            composeProject: summary.Labels?["com.docker.compose.project"],
            cpu: cpu,
            memoryBytes: memory,
            memoryLimitBytes: limit,
            networkReceivedBytesPerSecond: received,
            networkSentBytesPerSecond: sent,
            processCount: processes
        )
    }

    /// Forgets containers that no longer exist.
    public mutating func retainOnly(_ ids: Set<String>) {
        rates.retainOnly(ids)
    }

    public mutating func reset() {
        rates.reset()
    }

    /// Memory the way `docker stats` reports it: usage minus reclaimable page cache
    /// (`inactive_file` on cgroup v2, `total_inactive_file`/`cache` on v1).
    static func workingSet(_ memory: Stats.MemoryStats?) -> UInt64? {
        guard let memory, let usage = memory.usage else { return nil }
        let reclaimable = memory.stats?["inactive_file"] ?? memory.stats?["total_inactive_file"] ?? memory.stats?["cache"] ?? 0
        return usage >= reclaimable ? usage - reclaimable : usage
    }

    /// "8080→80/tcp"; unpublished ports as "80/tcp". Duplicates (IPv4 and IPv6 bindings) merged.
    static func ports(_ ports: [ContainerSummary.Port]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for port in ports {
            guard let privatePort = port.privatePort else { continue }
            let protocolName = port.protocolName ?? "tcp"
            let text = port.publicPort.map { "\($0)→\(privatePort)/\(protocolName)" } ?? "\(privatePort)/\(protocolName)"
            if seen.insert(text).inserted { result.append(text) }
        }
        return result
    }
}
