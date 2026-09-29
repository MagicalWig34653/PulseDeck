/// Battery wear, from the `AppleSmartBattery` IORegistry entry (undocumented keys, approved with
/// the other battery-controller values, L‑2/L‑13).
public struct BatteryHealth: Hashable, Sendable {
    public var cycleCount: Int?
    /// Cycles the battery is designed for (`DesignCycleCount9C`), typically 1000.
    public var designCycleCount: Int?
    /// Capacity when new, mAh.
    public var designCapacity: Int?
    /// Current full-charge capacity, mAh (`AppleRawMaxCapacity`, or `MaxCapacity` on Intel Macs
    /// where it is in mAh).
    public var fullChargeCapacity: Int?
    public var temperatureCelsius: Double?

    public init(cycleCount: Int?, designCycleCount: Int?, designCapacity: Int?, fullChargeCapacity: Int?, temperatureCelsius: Double?) {
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.temperatureCelsius = temperatureCelsius
    }

    /// Maximum capacity relative to design, as System Settings → Battery reports it. Values above
    /// 1 occur on new batteries and are kept.
    public var maximumCapacityFraction: Double? {
        guard let designCapacity, designCapacity > 0, let fullChargeCapacity, fullChargeCapacity > 0 else { return nil }
        return Double(fullChargeCapacity) / Double(designCapacity)
    }

    /// `AppleSmartBattery` `Temperature` is in hundredths of a degree Celsius.
    public static func celsius(fromRegistryTemperature value: Int) -> Double? {
        let celsius = Double(value) / 100
        return ThermalClassifier.isPlausible(celsius) ? celsius : nil
    }
}
