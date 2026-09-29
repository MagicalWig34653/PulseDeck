/// Where on the logic board a temperature sensor sits, as far as its SMC key reveals it. Used
/// to place readings on the Thermals page's schematic board view.
public enum ThermalZone: String, CaseIterable, Hashable, Sendable {
    /// Apple silicon performance cores.
    case cpuPerformance
    /// Apple silicon efficiency cores.
    case cpuEfficiency
    /// CPU without a core-type distinction (Intel, or keys that don't say).
    case cpu
    case gpu
    case memory
    case storage
    case wireless
    case battery
    /// Power delivery: charger, voltage regulators.
    case power
    /// Airflow and ambient sensors.
    case ambient
    /// Palm rest / enclosure skin.
    case enclosure
}

/// One SMC temperature sensor.
public struct TemperatureSensor: Hashable, Sendable, Identifiable {
    /// Four-character SMC key, e.g. "Tp09".
    public var key: String
    public var zone: ThermalZone
    public var celsius: Double

    public var id: String { key }

    public init(key: String, zone: ThermalZone, celsius: Double) {
        self.key = key
        self.zone = zone
        self.celsius = celsius
    }
}

/// Summary of one zone's sensors.
public struct ThermalZoneReading: Hashable, Sendable, Identifiable {
    public var zone: ThermalZone
    public var maximumCelsius: Double
    public var averageCelsius: Double
    public var sensorCount: Int

    public var id: ThermalZone { zone }

    public init(zone: ThermalZone, maximumCelsius: Double, averageCelsius: Double, sensorCount: Int) {
        self.zone = zone
        self.maximumCelsius = maximumCelsius
        self.averageCelsius = averageCelsius
        self.sensorCount = sensorCount
    }
}

/// One fan, from the SMC (`F<n>Ac`, `F<n>Mn`, `F<n>Mx`, `F<n>Tg`), in revolutions per minute.
public struct FanReading: Hashable, Sendable, Identifiable {
    public var index: Int
    public var actualRPM: Double
    public var minimumRPM: Double?
    public var maximumRPM: Double?
    public var targetRPM: Double?

    public var id: Int { index }

    public init(index: Int, actualRPM: Double, minimumRPM: Double?, maximumRPM: Double?, targetRPM: Double?) {
        self.index = index
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
    }

    /// Position between minimum and maximum speed in `0...1`, if both are known.
    public var fractionOfRange: Double? {
        guard let minimumRPM, let maximumRPM, maximumRPM > minimumRPM else { return nil }
        return min(max((actualRPM - minimumRPM) / (maximumRPM - minimumRPM), 0), 1)
    }
}

/// Temperatures and fans from the System Management Controller (undocumented keys read through
/// the public IOKit user-client API; approved by the product owner, TECHNICAL_LIMITATIONS.md L‑13).
public struct ThermalSnapshot: Hashable, Sendable {
    public var sensors: [TemperatureSensor]
    /// `.unavailable(.notApplicable)` on Macs without fans (MacBook Air).
    public var fans: MetricState<[FanReading]>

    public init(sensors: [TemperatureSensor], fans: MetricState<[FanReading]>) {
        self.sensors = sensors
        self.fans = fans
    }

    /// One reading per zone that has sensors, hottest first.
    public var zones: [ThermalZoneReading] {
        let grouped = Dictionary(grouping: sensors, by: \.zone)
        return grouped.compactMap { zone, sensors -> ThermalZoneReading? in
            guard let maximum = sensors.map(\.celsius).max() else { return nil }
            let average = sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
            return ThermalZoneReading(zone: zone, maximumCelsius: maximum, averageCelsius: average, sensorCount: sensors.count)
        }
        .sorted { $0.maximumCelsius > $1.maximumCelsius }
    }

    public func zone(_ zone: ThermalZone) -> ThermalZoneReading? {
        zones.first { $0.zone == zone }
    }

    /// Hottest CPU sensor of any core type.
    public var cpuMaximumCelsius: Double? {
        sensors.filter { [.cpu, .cpuPerformance, .cpuEfficiency].contains($0.zone) }.map(\.celsius).max()
    }
}
