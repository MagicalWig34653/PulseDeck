/// One GPU as identified via Metal (SPEC §18).
public struct GPUDeviceSnapshot: Hashable, Sendable, Identifiable {
    /// Metal `registryID`, stable for the device's lifetime.
    public var id: UInt64
    public var name: String
    public var hasUnifiedMemory: Bool
    public var isLowPower: Bool
    public var isRemovable: Bool
    /// System-wide utilization in `0...1`. See TECHNICAL_LIMITATIONS.md L‑1.
    public var utilization: MetricState<Double>

    public init(id: UInt64, name: String, hasUnifiedMemory: Bool, isLowPower: Bool, isRemovable: Bool, utilization: MetricState<Double>) {
        self.id = id
        self.name = name
        self.hasUnifiedMemory = hasUnifiedMemory
        self.isLowPower = isLowPower
        self.isRemovable = isRemovable
        self.utilization = utilization
    }
}

public struct GPUSnapshot: Hashable, Sendable {
    public var devices: [GPUDeviceSnapshot]

    public init(devices: [GPUDeviceSnapshot]) {
        self.devices = devices
    }
}
