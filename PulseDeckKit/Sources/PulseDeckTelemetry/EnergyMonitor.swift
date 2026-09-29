#if os(macOS)
import Foundation
import IOKit
import IOKit.ps
import PulseDeckCore

/// Battery and power telemetry (SPEC §19). See `EnergyCalculator` for the rules.
///
/// - Battery: IOPS power-source descriptions (`IOPSCopyPowerSourcesInfo`, public keys from
///   `IOPSKeys.h`). Battery power is *derived* from voltage × current.
/// - System power in: `AppleSmartBattery` → `PowerTelemetryData` → `SystemPowerIn` (mW).
///   **Undocumented**, portables only; approved by the product owner as a labelled source with
///   fallback to *Not Available* (TECHNICAL_LIMITATIONS.md L‑2).
/// - CPU/GPU package power: no public API (IOReport is private, SMC undocumented) → always
///   *Not Available*.
///
/// Demand-driven: sampled only while the energy page/preview or the energy menu bar metric is
/// visible.
public actor EnergyMonitor: TelemetryProvider {
    /// Keys of an IOPS power-source description (`IOPSKeys.h`). Spelled out so the mapping to
    /// `PowerSourceReading` is explicit.
    private enum Key {
        static let type = "Type"                                    // kIOPSTypeKey
        static let internalBattery = "InternalBattery"              // kIOPSInternalBatteryType
        static let isPresent = "Is Present"                         // kIOPSIsPresentKey
        static let currentCapacity = "Current Capacity"             // kIOPSCurrentCapacityKey
        static let maxCapacity = "Max Capacity"                     // kIOPSMaxCapacityKey
        static let isCharging = "Is Charging"                       // kIOPSIsChargingKey
        static let isCharged = "Is Charged"                         // kIOPSIsChargedKey
        static let powerSourceState = "Power Source State"          // kIOPSPowerSourceStateKey
        static let timeToEmpty = "Time to Empty"                    // kIOPSTimeToEmptyKey
        static let timeToFullCharge = "Time to Full Charge"         // kIOPSTimeToFullChargeKey
        static let voltage = "Voltage"                              // kIOPSVoltageKey
        static let current = "Current"                              // kIOPSCurrentKey
        static let adapterWatts = "Watts"                           // kIOPSPowerAdapterWattsKey
    }

    /// Undocumented `AppleSmartBattery` registry keys (approved, L‑2).
    private enum SmartBatteryKey {
        static let serviceClass = "AppleSmartBattery"
        static let powerTelemetryData = "PowerTelemetryData"
        static let systemPowerIn = "SystemPowerIn"
        static let cycleCount = "CycleCount"
        static let designCycleCount = "DesignCycleCount9C"
        static let designCapacity = "DesignCapacity"
        /// Full-charge capacity in mAh on Apple silicon (`MaxCapacity` is a percentage there).
        static let rawMaxCapacity = "AppleRawMaxCapacity"
        static let nominalChargeCapacity = "NominalChargeCapacity"
        /// mAh on Intel Macs.
        static let maxCapacity = "MaxCapacity"
        /// Hundredths of a degree Celsius.
        static let temperature = "Temperature"
    }

    private enum SystemPowerReading {
        /// No `AppleSmartBattery` service: a desktop Mac.
        case noController
        case milliwatts(Double?)
    }

    public init() {}

    public func capability() -> TelemetryCapability {
        IOPSCopyPowerSourcesInfo()?.takeRetainedValue() == nil
            ? .unsupported(.transientFailure("IOPSCopyPowerSourcesInfo failed"))
            : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<EnergySnapshot> {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .unavailable(.transientFailure("IOPSCopyPowerSourcesInfo failed"))
        }
        let providingState: String? = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }

        let battery: MetricState<BatterySnapshot> = Self.internalBatteryReading(in: info)
            .map(EnergyCalculator.battery(from:)) ?? .unavailable(.unsupportedHardware)
        let powerSource = battery.value?.powerSource ?? EnergyCalculator.powerSource(from: providingState)

        let smartBattery = Self.readSmartBattery()
        let systemPower: MetricState<AttributedValue<Double>> = switch smartBattery.power {
        case .noController: .unavailable(.unsupportedHardware)
        case .milliwatts(let milliwatts): EnergyCalculator.systemPowerIn(milliwatts: milliwatts, powerSource: powerSource)
        }
        let batteryWithHealth = battery.map { snapshot in
            var snapshot = snapshot
            snapshot.health = smartBattery.health.map { .available($0) } ?? .unavailable(.unsupportedHardware)
            return snapshot
        }

        let adapter = Self.dictionary(IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue())
        let adapterRating = EnergyCalculator.adapterRating(
            watts: (adapter?[Key.adapterWatts] as? NSNumber)?.doubleValue,
            isConnected: powerSource == .ac
        )

        return .available(EnergySnapshot(
            battery: batteryWithHealth,
            systemPowerWatts: systemPower,
            cpuPowerWatts: .unavailable(.noPublicAPI),
            gpuPowerWatts: .unavailable(.noPublicAPI),
            adapterRatingWatts: adapterRating
        ))
    }

    public func invalidateBaselines() {
        // All energy values are instantaneous readings; there are no baselines.
    }

    // MARK: - IOPS

    private static func internalBatteryReading(in info: CFTypeRef) -> PowerSourceReading? {
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        for source in list as NSArray {
            guard let description = dictionary(IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue()),
                  description[Key.type] as? String == Key.internalBattery,
                  description[Key.isPresent] as? Bool ?? true
            else { continue }
            func number(_ key: String) -> Double? { (description[key] as? NSNumber)?.doubleValue }
            return PowerSourceReading(
                currentCapacity: number(Key.currentCapacity),
                maxCapacity: number(Key.maxCapacity),
                isCharging: description[Key.isCharging] as? Bool,
                isCharged: description[Key.isCharged] as? Bool,
                powerSourceState: description[Key.powerSourceState] as? String,
                timeToEmptyMinutes: number(Key.timeToEmpty),
                timeToFullChargeMinutes: number(Key.timeToFullCharge),
                voltageMillivolts: number(Key.voltage),
                currentMilliamperes: number(Key.current)
            )
        }
        return nil
    }

    /// CF dictionaries bridge through `NSDictionary`; the key/value types are checked at runtime.
    private static func dictionary(_ value: CFDictionary?) -> [String: Any]? {
        guard let value else { return nil }
        return (value as NSDictionary) as? [String: Any]
    }

    // MARK: - AppleSmartBattery (undocumented, approved)

    /// System power in and battery wear from one registry lookup.
    private static func readSmartBattery() -> (power: SystemPowerReading, health: BatteryHealth?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(SmartBatteryKey.serviceClass))
        guard service != 0 else { return (.noController, nil) }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func integer(_ key: String) -> Int? {
            (property(key) as? NSNumber)?.intValue
        }
        let telemetry = property(SmartBatteryKey.powerTelemetryData) as? [String: Any]
        let power = SystemPowerReading.milliwatts((telemetry?[SmartBatteryKey.systemPowerIn] as? NSNumber)?.doubleValue)

        // `MaxCapacity` is mAh only on Intel Macs; on Apple silicon it is ~100 (percent).
        let percentScaleLimit = 200
        let fullCharge = integer(SmartBatteryKey.rawMaxCapacity)
            ?? integer(SmartBatteryKey.nominalChargeCapacity)
            ?? integer(SmartBatteryKey.maxCapacity).flatMap { $0 > percentScaleLimit ? $0 : nil }
        let health = BatteryHealth(
            cycleCount: integer(SmartBatteryKey.cycleCount),
            designCycleCount: integer(SmartBatteryKey.designCycleCount).flatMap { $0 > 0 ? $0 : nil },
            designCapacity: integer(SmartBatteryKey.designCapacity).flatMap { $0 > 0 ? $0 : nil },
            fullChargeCapacity: fullCharge,
            temperatureCelsius: integer(SmartBatteryKey.temperature).flatMap(BatteryHealth.celsius(fromRegistryTemperature:))
        )
        let hasAny = health.cycleCount != nil || health.designCapacity != nil || health.fullChargeCapacity != nil
        return (power, hasAny ? health : nil)
    }
}
#endif
