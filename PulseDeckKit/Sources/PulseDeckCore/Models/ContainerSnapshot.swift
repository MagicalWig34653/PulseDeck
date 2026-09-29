import Foundation

/// One Docker container, from the Docker Engine API of the local engine (Colima's VM, or
/// Docker Desktop) over its Unix socket.
public struct ContainerSnapshot: Hashable, Sendable, Identifiable {
    /// Full container ID.
    public var id: String
    /// Name without the leading slash.
    public var name: String
    public var image: String
    /// "running", "exited", "paused", "created", "restarting", "dead".
    public var state: String
    /// Human status from the engine, e.g. "Up 3 hours".
    public var status: String
    public var created: Date?
    /// "8080→80/tcp" style port mappings.
    public var ports: [String]
    /// Compose project, if the container belongs to one.
    public var composeProject: String?
    /// CPU as a fraction of one CPU of the VM (can exceed 1).
    public var cpu: MetricState<Double>
    public var memoryBytes: MetricState<UInt64>
    public var memoryLimitBytes: MetricState<UInt64>
    public var networkReceivedBytesPerSecond: MetricState<Double>
    public var networkSentBytesPerSecond: MetricState<Double>
    public var processCount: MetricState<Int>

    public var isRunning: Bool { state == "running" }

    public init(id: String, name: String, image: String, state: String, status: String, created: Date?, ports: [String], composeProject: String?, cpu: MetricState<Double>, memoryBytes: MetricState<UInt64>, memoryLimitBytes: MetricState<UInt64>, networkReceivedBytesPerSecond: MetricState<Double>, networkSentBytesPerSecond: MetricState<Double>, processCount: MetricState<Int>) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.created = created
        self.ports = ports
        self.composeProject = composeProject
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond
        self.processCount = processCount
    }
}

/// The Docker engine PulseDeck talks to, and its containers.
public struct ContainersSnapshot: Hashable, Sendable {
    /// Where the engine was found, e.g. "Colima (default)".
    public var engineName: String
    public var socketPath: String
    public var engineVersion: String?
    public var containers: [ContainerSnapshot]

    public init(engineName: String, socketPath: String, engineVersion: String?, containers: [ContainerSnapshot]) {
        self.engineName = engineName
        self.socketPath = socketPath
        self.engineVersion = engineVersion
        self.containers = containers
    }
}
