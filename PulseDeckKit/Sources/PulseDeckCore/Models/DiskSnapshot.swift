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

    public init(id: String, name: String, connection: DiskConnection, isRemovable: Bool, capacityBytes: MetricState<UInt64>, availableBytes: MetricState<UInt64>, readBytesPerSecond: MetricState<Double>, writeBytesPerSecond: MetricState<Double>, totalBytesRead: MetricState<UInt64>, totalBytesWritten: MetricState<UInt64>, activeTime: MetricState<Double>) {
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
    }
}
