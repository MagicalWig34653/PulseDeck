/// Negotiated USB link speed (`USBDeviceSpeed` in IOUSBHostFamily: low = 0 … super-plus-by-2 = 5).
public enum USBSpeed: Int, Hashable, Sendable, Comparable {
    case low = 0
    case full = 1
    case high = 2
    case superSpeed = 3
    case superSpeedPlus = 4
    case superSpeedPlusBy2 = 5

    /// Signalling rate of the link.
    public var bitsPerSecond: UInt64 {
        switch self {
        case .low: 1_500_000
        case .full: 12_000_000
        case .high: 480_000_000
        case .superSpeed: 5_000_000_000
        case .superSpeedPlus: 10_000_000_000
        case .superSpeedPlusBy2: 20_000_000_000
        }
    }

    /// "USB 2.0 High Speed", "USB 3.2 Gen 2" …
    public var name: String {
        switch self {
        case .low: "USB 1.1 Low Speed"
        case .full: "USB 1.1 Full Speed"
        case .high: "USB 2.0 High Speed"
        case .superSpeed: "USB 3.2 Gen 1"
        case .superSpeedPlus: "USB 3.2 Gen 2"
        case .superSpeedPlusBy2: "USB 3.2 Gen 2×2"
        }
    }

    public static func < (lhs: USBSpeed, rhs: USBSpeed) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One node of the USB tree: a host controller (bus), a hub or a device.
public struct USBNode: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case controller
        case hub
        case device
    }

    /// IORegistry entry ID.
    public var id: UInt64
    public var kind: Kind
    public var name: String
    public var vendor: String?
    public var vendorID: Int?
    public var productID: Int?
    /// `locationID`, identifies bus and port path.
    public var locationID: UInt32?
    /// Negotiated link speed of this device's upstream link — the most it can transfer. For a
    /// hub, its children share this bandwidth.
    public var speed: USBSpeed?
    /// Power the device requested and was granted, in milliamps at 5 V (IORegistry; undocumented;
    /// allocated, not measured — L‑12).
    public var allocatedMilliamps: Int?
    /// Current the port can supply, in milliamps (IORegistry port limit; undocumented).
    public var portCurrentLimitMilliamps: Int?
    public var children: [USBNode]

    public init(id: UInt64, kind: Kind, name: String, vendor: String? = nil, vendorID: Int? = nil, productID: Int? = nil, locationID: UInt32? = nil, speed: USBSpeed? = nil, allocatedMilliamps: Int? = nil, portCurrentLimitMilliamps: Int? = nil, children: [USBNode] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.vendor = vendor
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.speed = speed
        self.allocatedMilliamps = allocatedMilliamps
        self.portCurrentLimitMilliamps = portCurrentLimitMilliamps
        self.children = children
    }

    /// USB bus voltage, used to express allocated current as power.
    public static let busVoltage = 5.0

    /// Allocated power in watts (`allocatedMilliamps` × 5 V).
    public var allocatedWatts: Double? {
        allocatedMilliamps.map { Double($0) / 1_000 * Self.busVoltage }
    }

    /// Sum of allocated power of this node and everything below it.
    public var totalAllocatedMilliamps: Int? {
        let own = allocatedMilliamps
        let below = children.compactMap(\.totalAllocatedMilliamps)
        if own == nil && below.isEmpty { return nil }
        return (own ?? 0) + below.reduce(0, +)
    }

    /// Fastest link among this node's devices (for a controller: the bus's fastest port in use).
    public var fastestSpeed: USBSpeed? {
        ([speed] + children.map(\.fastestSpeed)).compactMap { $0 }.max()
    }

    /// Number of devices (not hubs or controllers) in this subtree.
    public var deviceCount: Int {
        (kind == .device ? 1 : 0) + children.reduce(0) { $0 + $1.deviceCount }
    }
}

public struct USBSnapshot: Hashable, Sendable {
    /// Host controllers (buses) with their hubs and devices.
    public var controllers: [USBNode]

    public init(controllers: [USBNode]) {
        self.controllers = controllers
    }
}
