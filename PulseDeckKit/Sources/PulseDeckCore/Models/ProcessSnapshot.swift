/// Identity of a process that is robust against PID reuse (SPEC §21, §28): a PID is only
/// considered the same process if its start time matches too.
public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    /// Process start time in microseconds since the Unix epoch.
    public var startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

/// One row of the process table.
public struct ProcessSnapshot: Hashable, Sendable, Identifiable {
    public var identity: ProcessIdentity
    public var name: String
    /// Executable path when permitted.
    public var path: String?
    /// CPU usage as a fraction of one logical processor (can exceed 1 for multithreaded work).
    public var cpu: MetricState<Double>
    /// Physical memory footprint in bytes.
    public var memoryBytes: MetricState<UInt64>
    public var threadCount: MetricState<Int>
    public var diskReadBytesPerSecond: MetricState<Double>
    public var diskWriteBytesPerSecond: MetricState<Double>

    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }

    public init(identity: ProcessIdentity, name: String, path: String?, cpu: MetricState<Double>, memoryBytes: MetricState<UInt64>, threadCount: MetricState<Int>, diskReadBytesPerSecond: MetricState<Double>, diskWriteBytesPerSecond: MetricState<Double>) {
        self.identity = identity
        self.name = name
        self.path = path
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
    }
}
