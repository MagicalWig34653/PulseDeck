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
    public var powerSource: PowerSource
    /// Seconds until empty/full as estimated by the OS, when it provides one.
    public var timeRemaining: MetricState<Double>
    public var voltageVolts: MetricState<Double>
    /// Positive while charging, negative while discharging.
    public var currentAmperes: MetricState<Double>
    /// Battery charge/discharge power, derived from voltage × current. This is *battery* power
    /// and must never be presented as total system power (SPEC §19).
    public var batteryPowerWatts: MetricState<AttributedValue<Double>>

    public init(charge: Double, isCharging: Bool, powerSource: PowerSource, timeRemaining: MetricState<Double>, voltageVolts: MetricState<Double>, currentAmperes: MetricState<Double>, batteryPowerWatts: MetricState<AttributedValue<Double>>) {
        self.charge = charge
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.timeRemaining = timeRemaining
        self.voltageVolts = voltageVolts
        self.currentAmperes = currentAmperes
        self.batteryPowerWatts = batteryPowerWatts
    }
}

/// Energy/power telemetry. Each value states whether it was reported or derived; values
/// without a reliable source are `.unavailable` (see TECHNICAL_LIMITATIONS.md L‑2).
public struct EnergySnapshot: Hashable, Sendable {
    public var battery: MetricState<BatterySnapshot>
    public var systemPowerWatts: MetricState<AttributedValue<Double>>
    public var cpuPowerWatts: MetricState<AttributedValue<Double>>
    public var gpuPowerWatts: MetricState<AttributedValue<Double>>

    public init(battery: MetricState<BatterySnapshot>, systemPowerWatts: MetricState<AttributedValue<Double>>, cpuPowerWatts: MetricState<AttributedValue<Double>>, gpuPowerWatts: MetricState<AttributedValue<Double>>) {
        self.battery = battery
        self.systemPowerWatts = systemPowerWatts
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
    }
}
