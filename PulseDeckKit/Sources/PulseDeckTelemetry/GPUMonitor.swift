#if os(macOS)
import Foundation
import IOKit
import Metal
import PulseDeckCore

/// GPU identification and utilization (SPEC §18).
///
/// - Identification: Metal `MTLCopyAllDevices()` (public).
/// - Utilization: `Device Utilization %` from the `PerformanceStatistics` dictionary of
///   `IOAccelerator` services. The IOKit calls are public, the key is **undocumented** (approved
///   by the product owner; TECHNICAL_LIMITATIONS.md L‑1). A missing key yields *Not Available*.
///   IOReport is private and deliberately not used.
///
/// Demand-driven: the engine samples it only while the GPU page, a preview or the GPU menu bar
/// metric is visible (`SamplingPolicy.demand`).
public actor GPUMonitor: TelemetryProvider {
    private struct DeviceInfo: Sendable {
        var id: UInt64
        var name: String
        var hasUnifiedMemory: Bool
        var isLowPower: Bool
        var isRemovable: Bool
        var location: GPULocation
    }

    private static let performanceStatisticsKey = "PerformanceStatistics"
    /// How many IORegistry parents of an accelerator are compared with Metal's `registryID`.
    /// Drivers attach the accelerator one or two levels below the device Metal names.
    private static let maximumAncestorDepth = 3

    private var devices: [DeviceInfo]
    /// Registry IDs of the accelerator services seen last time. A change (eGPU attached or
    /// removed) triggers a Metal re-enumeration; otherwise Metal is queried only once.
    private var acceleratorIDs: Set<UInt64> = []

    public init() {
        devices = Self.readDevices()
    }

    public func capability() -> TelemetryCapability {
        devices.isEmpty ? .unsupported(.unsupportedHardware) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<GPUSnapshot> {
        let accelerators = Self.readAccelerators()
        if let accelerators {
            let ids = Set(accelerators.compactMap(\.registryIDs.first))
            if ids != acceleratorIDs {
                acceleratorIDs = ids
                devices = Self.readDevices()
            }
        }
        guard !devices.isEmpty else { return .unavailable(.unsupportedHardware) }

        let utilization: [UInt64: MetricState<Double>]
        if let accelerators {
            utilization = GPUUtilization.match(deviceIDs: devices.map(\.id), accelerators: accelerators)
        } else {
            utilization = [:]
        }
        return .available(GPUSnapshot(devices: devices.map { device in
            GPUDeviceSnapshot(
                id: device.id,
                name: device.name,
                hasUnifiedMemory: device.hasUnifiedMemory,
                isLowPower: device.isLowPower,
                isRemovable: device.isRemovable,
                location: device.location,
                utilization: utilization[device.id] ?? .unavailable(.transientFailure("IOAccelerator lookup failed"))
            )
        }))
    }

    public func invalidateBaselines() {
        // Utilization is an instantaneous reading; re-enumerate devices after wake in case an
        // external GPU was attached or removed while asleep.
        acceleratorIDs = []
    }

    // MARK: - Metal

    private static func readDevices() -> [DeviceInfo] {
        // Integrated GPUs first, then discrete, then external; stable by registry ID within.
        MTLCopyAllDevices()
            .map { device in
                DeviceInfo(
                    id: device.registryID,
                    name: device.name,
                    hasUnifiedMemory: device.hasUnifiedMemory,
                    isLowPower: device.isLowPower,
                    isRemovable: device.isRemovable,
                    location: location(device.location)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isRemovable != rhs.isRemovable { return !lhs.isRemovable }
                if lhs.hasUnifiedMemory != rhs.hasUnifiedMemory { return lhs.hasUnifiedMemory }
                return lhs.id < rhs.id
            }
    }

    private static func location(_ location: MTLDeviceLocation) -> GPULocation {
        switch location {
        case .builtIn: .builtIn
        case .slot: .slot
        case .external: .external
        case .unspecified: .unspecified
        @unknown default: .unspecified
        }
    }

    // MARK: - IOKit

    /// Every `IOAccelerator` service with its registry lineage and utilization reading, or `nil`
    /// if the registry could not be queried.
    private static func readAccelerators() -> [AcceleratorStatistics]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var result: [AcceleratorStatistics] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let statistics = IORegistryEntryCreateCFProperty(service, performanceStatisticsKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            let percent = (statistics?[GPUUtilization.deviceUtilizationKey] as? NSNumber)?.doubleValue
            result.append(AcceleratorStatistics(registryIDs: lineage(of: service), deviceUtilizationPercent: percent))
        }
        return result
    }

    /// Registry entry IDs of `service` and up to `maximumAncestorDepth` parents (service plane).
    private static func lineage(of service: io_registry_entry_t) -> [UInt64] {
        var ids: [UInt64] = []
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
            ids.append(entryID)
        }
        // `current` owns one reference; the service itself is retained so the loop can release
        // uniformly.
        var current = service
        IOObjectRetain(current)
        for _ in 0..<maximumAncestorDepth {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            if IORegistryEntryGetRegistryEntryID(parent, &entryID) == KERN_SUCCESS {
                ids.append(entryID)
            }
        }
        IOObjectRelease(current)
        return ids
    }
}
#endif
