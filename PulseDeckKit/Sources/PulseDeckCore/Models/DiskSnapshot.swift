/// How a storage device is attached.
public enum DiskConnection: Hashable, Sendable {
    case `internal`
    case external
    /// A mounted disk image.
    case diskImage
    case unknown
}

/// One physical or logical storage device.
public struct DiskSnapshot: Hashable, Sendable, Identifiable {
    /// Stable identifier for the lifetime of the device, e.g. the BSD name `disk0`.
    public var id: String
    /// User-facing name (media/volume name).
    public var name: String
    public var connection: DiskConnection
    public var isRemovable: Bool
    /// Size of the whole device.
    public var capacityBytes: MetricState<UInt64>
    /// Space available on the device's mounted volumes (APFS containers counted once).
    public var availableBytes: MetricState<UInt64>
    public var readBytesPerSecond: MetricState<Double>
    public var writeBytesPerSecond: MetricState<Double>
    /// Cumulative bytes since the driver was instantiated.
    public var totalBytesRead: MetricState<UInt64>
    public var totalBytesWritten: MetricState<UInt64>
    /// Fraction of time busy in `0...1`. See TECHNICAL_LIMITATIONS.md L‑3.
    public var activeTime: MetricState<Double>
    /// Physical interconnect as reported by the driver, e.g. "PCI-Express", "USB", "Thunderbolt".
    public var bus: String?
    /// Mount points of the disk's mounted volumes.
    public var mountPoints: [String]
    /// APFS snapshots on the disk's mounted volumes (`fs_snapshot_list`).
    public var snapshotCount: MetricState<Int>
    /// Space held only by snapshots. No public API reports it (L‑10).
    public var snapshotBytes: MetricState<UInt64>

    public init(id: String, name: String, connection: DiskConnection, isRemovable: Bool, capacityBytes: MetricState<UInt64>, availableBytes: MetricState<UInt64>, readBytesPerSecond: MetricState<Double>, writeBytesPerSecond: MetricState<Double>, totalBytesRead: MetricState<UInt64>, totalBytesWritten: MetricState<UInt64>, activeTime: MetricState<Double>, bus: String? = nil, mountPoints: [String] = [], snapshotCount: MetricState<Int> = .notSampled, snapshotBytes: MetricState<UInt64> = .unavailable(.noPublicAPI)) {
        self.id = id
        self.name = name
        self.connection = connection
        self.isRemovable = isRemovable
        self.capacityBytes = capacityBytes
        self.availableBytes = availableBytes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.totalBytesRead = totalBytesRead
        self.totalBytesWritten = totalBytesWritten
        self.activeTime = activeTime
        self.bus = bus
        self.mountPoints = mountPoints
        self.snapshotCount = snapshotCount
        self.snapshotBytes = snapshotBytes
    }
}
