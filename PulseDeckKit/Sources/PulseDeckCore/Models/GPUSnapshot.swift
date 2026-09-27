/// Where a GPU is attached (Metal `MTLDeviceLocation`).
public enum GPULocation: Hashable, Sendable {
    case builtIn
    case slot
    case external
    case unspecified
}

/// One GPU as identified via Metal (SPEC §18).
public struct GPUDeviceSnapshot: Hashable, Sendable, Identifiable {
    /// Metal `registryID`, stable for the device's lifetime.
    public var id: UInt64
    public var name: String
    public var hasUnifiedMemory: Bool
    public var isLowPower: Bool
    public var isRemovable: Bool
    public var location: GPULocation
    /// System-wide utilization in `0...1` from the undocumented `IOAccelerator`
    /// `PerformanceStatistics` (approved, labelled in the UI). See TECHNICAL_LIMITATIONS.md L‑1.
    public var utilization: MetricState<Double>

    public init(id: UInt64, name: String, hasUnifiedMemory: Bool, isLowPower: Bool, isRemovable: Bool, location: GPULocation = .unspecified, utilization: MetricState<Double>) {
        self.id = id
        self.name = name
        self.hasUnifiedMemory = hasUnifiedMemory
        self.isLowPower = isLowPower
        self.isRemovable = isRemovable
        self.location = location
        self.utilization = utilization
    }
}

public struct GPUSnapshot: Hashable, Sendable {
    public var devices: [GPUDeviceSnapshot]

    public init(devices: [GPUDeviceSnapshot]) {
        self.devices = devices
    }
}
