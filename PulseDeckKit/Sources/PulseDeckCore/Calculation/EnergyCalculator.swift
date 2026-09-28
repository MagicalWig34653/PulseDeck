/// The fields of one IOPS power-source description (`IOPSGetPowerSourceDescription`) that the
/// energy page uses. Key names and units are from IOKitUser `IOPSKeys.h` (public). Every field is
/// optional because a power source publishes only what its hardware reports.
public struct PowerSourceReading: Hashable, Sendable {
    /// `kIOPSCurrentCapacityKey` ("Current Capacity"), in units of `maxCapacity`.
    public var currentCapacity: Double?
    /// `kIOPSMaxCapacityKey` ("Max Capacity"). On Apple silicon both capacities are percentages.
    public var maxCapacity: Double?
    /// `kIOPSIsChargingKey`.
    public var isCharging: Bool?
    /// `kIOPSIsChargedKey`: present and `true` once the battery is full.
    public var isCharged: Bool?
    /// `kIOPSPowerSourceStateKey`: "AC Power", "Battery Power" or "Off Line".
    public var powerSourceState: String?
    /// `kIOPSTimeToEmptyKey`, minutes; `-1` while the OS is still estimating.
    public var timeToEmptyMinutes: Double?
    /// `kIOPSTimeToFullChargeKey`, minutes; `-1` while the OS is still estimating.
    public var timeToFullChargeMinutes: Double?
    /// `kIOPSVoltageKey`, millivolts.
    public var voltageMillivolts: Double?
    /// `kIOPSCurrentKey`, milliamperes; negative while discharging.
    public var currentMilliamperes: Double?

    public init(currentCapacity: Double? = nil, maxCapacity: Double? = nil, isCharging: Bool? = nil, isCharged: Bool? = nil, powerSourceState: String? = nil, timeToEmptyMinutes: Double? = nil, timeToFullChargeMinutes: Double? = nil, voltageMillivolts: Double? = nil, currentMilliamperes: Double? = nil) {
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.powerSourceState = powerSourceState
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullChargeMinutes = timeToFullChargeMinutes
        self.voltageMillivolts = voltageMillivolts
        self.currentMilliamperes = currentMilliamperes
    }
}

/// Energy calculations (SPEC §19). Keeps reported, derived and unavailable values apart and
/// never turns battery power into system power.
public enum EnergyCalculator {
    /// `kIOPSACPowerValue` / `kIOPSBatteryPowerValue`.
    public static let acPowerState = "AC Power"
    public static let batteryPowerState = "Battery Power"

    /// Upper bound for a plausible power reading. The largest Mac power adapters are rated
    /// well below this; anything above is a misread register, not a measurement.
    public static let maximumPlausibleWatts = 1_000.0

    private static let millisPerUnit = 1_000.0
    private static let secondsPerMinute = 60.0

    public static func powerSource(from state: String?) -> BatterySnapshot.PowerSource {
        switch state {
        case acPowerState?: .ac
        case batteryPowerState?: .battery
        default: .unknown
        }
    }

    /// Battery state from an internal-battery power-source description.
    ///
    /// Battery power is **derived** as voltage × current (positive while charging, negative while
    /// discharging). It is battery power only and must not be presented as system power.
    public static func battery(from reading: PowerSourceReading) -> MetricState<BatterySnapshot> {
        guard let current = reading.currentCapacity, let maximum = reading.maxCapacity,
              current.isFinite, maximum.isFinite, maximum > 0, current >= 0
        else {
            return .unavailable(.transientFailure("battery capacity missing"))
        }
        let source = powerSource(from: reading.powerSourceState)
        let isCharging = reading.isCharging ?? false
        let isCharged = reading.isCharged ?? false

        let voltage: MetricState<Double> = millis(reading.voltageMillivolts, requirePositive: true)
        let amperage: MetricState<Double> = millis(reading.currentMilliamperes, requirePositive: false)
        let power: MetricState<AttributedValue<Double>> = voltage.flatMap { volts in
            amperage.flatMap { amperes -> MetricState<AttributedValue<Double>> in
                let watts = volts * amperes
                guard abs(watts) <= maximumPlausibleWatts else {
                    return .unavailable(.transientFailure("implausible battery power"))
                }
                return .available(AttributedValue(watts, provenance: .derived))
            }
        }

        return .available(BatterySnapshot(
            charge: min(current / maximum, 1),
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: source,
            timeRemaining: timeRemaining(reading, source: source, isCharging: isCharging, isCharged: isCharged),
            voltageVolts: voltage,
            currentAmperes: amperage,
            batteryPowerWatts: power
        ))
    }

    /// Seconds until empty (discharging) or full (charging), as estimated by the OS.
    static func timeRemaining(_ reading: PowerSourceReading, source: BatterySnapshot.PowerSource, isCharging: Bool, isCharged: Bool) -> MetricState<Double> {
        let minutes: Double?
        if isCharging {
            minutes = reading.timeToFullChargeMinutes
        } else if source == .battery {
            minutes = reading.timeToEmptyMinutes
        } else {
            // On AC and not charging (full, or charging paused): nothing to count down.
            return .unavailable(.notApplicable)
        }
        guard let minutes, minutes.isFinite else { return .unavailable(.unsupportedHardware) }
        // -1 means the OS is still estimating after a state change.
        guard minutes > 0 else { return isCharged ? .unavailable(.notApplicable) : .unavailable(.awaitingBaseline) }
        return .available(minutes * secondsPerMinute)
    }

    /// `PowerTelemetryData.SystemPowerIn` of `AppleSmartBattery` (milliwatts): power flowing into
    /// the system from the power adapter. **Undocumented**; approved by the product owner as a
    /// labelled source, portables only (TECHNICAL_LIMITATIONS.md L‑2).
    ///
    /// On battery power nothing flows in from an adapter, so the value is `.notApplicable` rather
    /// than `0`, and battery discharge power is never substituted for it (SPEC §19).
    public static func systemPowerIn(milliwatts: Double?, powerSource: BatterySnapshot.PowerSource) -> MetricState<AttributedValue<Double>> {
        guard let milliwatts else { return .unavailable(.noPublicAPI) }
        guard powerSource != .battery else { return .unavailable(.notApplicable) }
        let watts = milliwatts / millisPerUnit
        // A running Mac on adapter power never draws 0 W: a zero is a missing reading.
        guard watts.isFinite, watts > 0, watts <= maximumPlausibleWatts else {
            return .unavailable(.transientFailure("implausible SystemPowerIn"))
        }
        return .available(AttributedValue(watts, provenance: .reported))
    }

    /// Adapter rating from `IOPSCopyExternalPowerAdapterDetails` (`kIOPSPowerAdapterWattsKey`).
    /// This is what the adapter can deliver, not what the Mac draws.
    public static func adapterRating(watts: Double?, isConnected: Bool) -> MetricState<Double> {
        guard isConnected else { return .unavailable(.notApplicable) }
        guard let watts else { return .unavailable(.unsupportedHardware) }
        guard watts.isFinite, watts > 0, watts <= maximumPlausibleWatts else {
            return .unavailable(.transientFailure("implausible adapter rating"))
        }
        return .available(watts)
    }

    private static func millis(_ value: Double?, requirePositive: Bool) -> MetricState<Double> {
        guard let value else { return .unavailable(.unsupportedHardware) }
        guard value.isFinite, !requirePositive || value > 0 else {
            return .unavailable(.transientFailure("implausible reading"))
        }
        return .available(value / millisPerUnit)
    }
}
