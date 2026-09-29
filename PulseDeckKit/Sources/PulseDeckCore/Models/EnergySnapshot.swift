/// Battery state from the power-source APIs (SPEC §19).
public struct BatterySnapshot: Hashable, Sendable {
    public enum PowerSource: Hashable, Sendable {
        case battery
        case ac
        case unknown
    }

    /// Charge in `0...1`.
    public var charge: Double
    public var isCharging: Bool
    /// The OS reports the battery as fully charged.
    public var isCharged: Bool
    public var powerSource: PowerSource
    /// Seconds until empty/full as estimated by the OS, when it provides one.
    public var timeRemaining: MetricState<Double>
    public var voltageVolts: MetricState<Double>
    /// Positive while charging, negative while discharging.
    public var currentAmperes: MetricState<Double>
    /// Battery charge/discharge power, derived from voltage × current. This is *battery* power
    /// and must never be presented as total system power (SPEC §19).
    public var batteryPowerWatts: MetricState<AttributedValue<Double>>
    /// Wear: cycle count, maximum capacity, temperature.
    public var health: MetricState<BatteryHealth>

    public init(charge: Double, isCharging: Bool, isCharged: Bool = false, powerSource: PowerSource, timeRemaining: MetricState<Double>, voltageVolts: MetricState<Double>, currentAmperes: MetricState<Double>, batteryPowerWatts: MetricState<AttributedValue<Double>>, health: MetricState<BatteryHealth> = .notSampled) {
        self.charge = charge
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.powerSource = powerSource
        self.timeRemaining = timeRemaining
        self.voltageVolts = voltageVolts
        self.currentAmperes = currentAmperes
        self.batteryPowerWatts = batteryPowerWatts
        self.health = health
    }
}

/// Energy/power telemetry. Each value states whether it was reported or derived; values
/// without a reliable source are `.unavailable` (see TECHNICAL_LIMITATIONS.md L‑2).
public struct EnergySnapshot: Hashable, Sendable {
    public var battery: MetricState<BatterySnapshot>
    /// Power flowing into the system from the power adapter (`PowerTelemetryData.SystemPowerIn`,
    /// undocumented, portables only — L‑2). `.notApplicable` on battery power.
    public var systemPowerWatts: MetricState<AttributedValue<Double>>
    public var cpuPowerWatts: MetricState<AttributedValue<Double>>
    public var gpuPowerWatts: MetricState<AttributedValue<Double>>
    /// Rated output of the connected power adapter. A rating, not a measurement of consumption.
    public var adapterRatingWatts: MetricState<Double>

    public init(battery: MetricState<BatterySnapshot>, systemPowerWatts: MetricState<AttributedValue<Double>>, cpuPowerWatts: MetricState<AttributedValue<Double>>, gpuPowerWatts: MetricState<AttributedValue<Double>>, adapterRatingWatts: MetricState<Double>) {
        self.battery = battery
        self.adapterRatingWatts = adapterRatingWatts
        self.systemPowerWatts = systemPowerWatts
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
    }
}
