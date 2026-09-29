#if os(macOS)
import Foundation
import IOKit
import PulseDeckCore

/// The USB tree: host controllers (buses) → hubs → devices, from the IORegistry's `IOUSB` plane
/// (the plane `ioreg -p IOUSB` and System Information show). Per device: negotiated link speed
/// and the bus power the host allocated to it. macOS does not measure per-port power; the
/// allocation is what the device requested and was granted (TECHNICAL_LIMITATIONS.md L‑12), read
/// from undocumented IORegistry keys and labelled as such.
///
/// Demand-driven: sampled only while the USB page is visible.
public actor USBMonitor: TelemetryProvider {
    private static let plane = "IOUSB"
    private static let deviceClass = "IOUSBHostDevice"
    /// `bDeviceClass` of a hub (USB 2.0 §11.23.1).
    private static let hubDeviceClass = 9

    public init() {}

    public func capability() -> TelemetryCapability {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return .unsupported(.transientFailure("no IORegistry root")) }
        IOObjectRelease(root)
        return .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<USBSnapshot> {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return .unavailable(.transientFailure("no IORegistry root")) }
        defer { IOObjectRelease(root) }
        let controllers = Self.children(of: root).map { entry in
            defer { IOObjectRelease(entry) }
            return Self.controllerNode(entry)
        }
        return .available(USBSnapshot(controllers: controllers.sorted { ($0.locationID ?? 0, $0.name) < ($1.locationID ?? 0, $1.name) }))
    }

    public func invalidateBaselines() {}

    // MARK: - Tree

    private static func controllerNode(_ entry: io_registry_entry_t) -> USBNode {
        USBNode(
            id: registryID(entry),
            kind: .controller,
            name: name(of: entry),
            locationID: number(entry, "locationID").map { UInt32(truncatingIfNeeded: $0) },
            children: deviceNodes(below: entry)
        )
    }

    /// Devices directly below `entry`. Non-device entries in between (ports, interfaces on some
    /// controllers) are skipped and their devices lifted up.
    private static func deviceNodes(below entry: io_registry_entry_t) -> [USBNode] {
        var nodes: [USBNode] = []
        for child in children(of: entry) {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, deviceClass) != 0 {
                nodes.append(deviceNode(child))
            } else {
                nodes.append(contentsOf: deviceNodes(below: child))
            }
        }
        return nodes.sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
    }

    private static func deviceNode(_ entry: io_registry_entry_t) -> USBNode {
        let isHub = number(entry, "bDeviceClass") == hubDeviceClass
        let product = string(entry, ["kUSBProductString", "USB Product Name"])
        return USBNode(
            id: registryID(entry),
            kind: isHub ? .hub : .device,
            name: product ?? name(of: entry),
            vendor: string(entry, ["kUSBVendorString", "USB Vendor Name"]),
            vendorID: number(entry, "idVendor"),
            productID: number(entry, "idProduct"),
            locationID: number(entry, "locationID").map { UInt32(truncatingIfNeeded: $0) },
            // `USBSpeed` (IOUSBHostFamily, macOS 10.11+) with the older `Device Speed` as
            // fallback; both use USBDeviceSpeed values.
            speed: (number(entry, "USBSpeed") ?? number(entry, "Device Speed")).flatMap(USBSpeed.init(rawValue:)),
            allocatedMilliamps: allocatedMilliamps(entry),
            portCurrentLimitMilliamps: number(entry, "kUSBWakePortCurrentLimit") ?? number(entry, "kUSBSleepPortCurrentLimit"),
            children: deviceNodes(below: entry)
        )
    }

    /// Power granted to the device, in mA. `UsbPowerSinkAllocation` is in mA; the legacy
    /// `Requested Power` is in the configuration descriptor's 2 mA units (USB 2.0 §9.6.3).
    private static func allocatedMilliamps(_ entry: io_registry_entry_t) -> Int? {
        if let milliamps = number(entry, "UsbPowerSinkAllocation") { return milliamps }
        let legacyUnitMilliamps = 2
        return number(entry, "Requested Power").map { $0 * legacyUnitMilliamps }
    }

    // MARK: - IORegistry helpers

    private static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_registry_entry_t] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            result.append(child)
        }
        return result
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "USB" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    private static func string(_ entry: io_registry_entry_t, _ keys: [String]) -> String? {
        for key in keys {
            if let value = property(entry, key) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    /// Power, current and speed related keys of every USB device, for the smoke test log (the
    /// allocation keys are undocumented and must be checked on real hardware).
    public static func diagnosticKeys() -> [String] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var lines: [String] = []
        func visit(_ entry: io_registry_entry_t, depth: Int) {
            var unmanaged: Unmanaged<CFMutableDictionary>?
            var keys: [String] = []
            if IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = unmanaged?.takeRetainedValue() as? [String: Any] {
                keys = properties.keys.filter { key in
                    ["power", "current", "speed", "bdeviceclass"].contains { key.lowercased().contains($0) }
                }.sorted().map { "\($0)=\(properties[$0].map { "\($0)" } ?? "")" }
            }
            lines.append(String(repeating: "  ", count: depth) + name(of: entry) + " " + keys.joined(separator: " "))
            for child in children(of: entry) {
                visit(child, depth: depth + 1)
                IOObjectRelease(child)
            }
        }
        for child in children(of: root) {
            visit(child, depth: 0)
            IOObjectRelease(child)
        }
        return lines
    }
}
#endif
