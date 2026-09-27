import Foundation
import Testing
@testable import PulseDeckCore

@Suite("GPU utilization")
struct GPUUtilizationTests {
    @Test func convertsPercentToFraction() {
        #expect(GPUUtilization.fraction(fromPercent: 37) == .available(0.37))
        #expect(GPUUtilization.fraction(fromPercent: 0) == .available(0))
        #expect(GPUUtilization.fraction(fromPercent: 100) == .available(1))
    }

    @Test func missingKeyIsNotAvailableNeverZero() {
        #expect(GPUUtilization.fraction(fromPercent: nil) == .unavailable(.noPublicAPI))
    }

    @Test func rejectsImplausibleValues() {
        #expect(GPUUtilization.fraction(fromPercent: 101).value == nil)
        #expect(GPUUtilization.fraction(fromPercent: -1).value == nil)
        #expect(GPUUtilization.fraction(fromPercent: .nan).value == nil)
    }

    @Test func matchesByRegistryIDOfServiceOrAncestor() {
        let result = GPUUtilization.match(
            deviceIDs: [10, 20],
            accelerators: [
                AcceleratorStatistics(registryIDs: [21, 20, 1], deviceUtilizationPercent: 80),  // parent is device 20
                AcceleratorStatistics(registryIDs: [10, 1], deviceUtilizationPercent: 5),
            ]
        )
        #expect(result[10] == .available(0.05))
        #expect(result[20] == .available(0.8))
    }

    @Test func prefersNearestMatch() {
        // Both accelerators descend from entry 1; the one that *is* entry 1 wins.
        let result = GPUUtilization.match(
            deviceIDs: [1],
            accelerators: [
                AcceleratorStatistics(registryIDs: [7, 1], deviceUtilizationPercent: 90),
                AcceleratorStatistics(registryIDs: [1], deviceUtilizationPercent: 10),
            ]
        )
        #expect(result[1] == .available(0.1))
    }

    @Test func pairsSingleDeviceWithSingleAccelerator() {
        let result = GPUUtilization.match(deviceIDs: [42], accelerators: [AcceleratorStatistics(registryIDs: [7], deviceUtilizationPercent: 12)])
        #expect(result[42] == .available(0.12))
    }

    @Test func unmatchedDevicesAreNotAvailable() {
        let result = GPUUtilization.match(
            deviceIDs: [1, 2],
            accelerators: [AcceleratorStatistics(registryIDs: [9], deviceUtilizationPercent: 50)]
        )
        #expect(result[1] == .unavailable(.noPublicAPI))
        #expect(result[2] == .unavailable(.noPublicAPI))
        #expect(GPUUtilization.match(deviceIDs: [1], accelerators: [])[1] == .unavailable(.noPublicAPI))
    }
}

@Suite("Energy")
struct EnergyCalculatorTests {
    private let discharging = PowerSourceReading(
        currentCapacity: 80, maxCapacity: 100, isCharging: false, isCharged: false,
        powerSourceState: "Battery Power", timeToEmptyMinutes: 240, timeToFullChargeMinutes: 0,
        voltageMillivolts: 12_500, currentMilliamperes: -800
    )

    @Test func dischargingBatteryDerivesNegativePower() throws {
        let battery = try #require(EnergyCalculator.battery(from: discharging).value)
        #expect(battery.charge == 0.8)
        #expect(battery.powerSource == .battery)
        #expect(!battery.isCharging)
        #expect(battery.voltageVolts == .available(12.5))
        #expect(battery.currentAmperes == .available(-0.8))
        let power = try #require(battery.batteryPowerWatts.value)
        #expect(abs(power.value - -10) < 1e-9)
        #expect(power.provenance == .derived)
        #expect(battery.timeRemaining == .available(240 * 60))
    }

    @Test func chargingUsesTimeToFull() throws {
        var reading = discharging
        reading.powerSourceState = "AC Power"
        reading.isCharging = true
        reading.currentMilliamperes = 2_000
        reading.timeToFullChargeMinutes = 45
        let battery = try #require(EnergyCalculator.battery(from: reading).value)
        #expect(battery.powerSource == .ac)
        #expect(battery.timeRemaining == .available(45 * 60))
        #expect(battery.batteryPowerWatts.value?.value == 25)
    }

    @Test func estimatingTimeIsNotZero() throws {
        var reading = discharging
        reading.timeToEmptyMinutes = -1
        let battery = try #require(EnergyCalculator.battery(from: reading).value)
        #expect(battery.timeRemaining == .unavailable(.awaitingBaseline))
    }

    @Test func fullOnACHasNoCountdown() throws {
        var reading = discharging
        reading.powerSourceState = "AC Power"
        reading.isCharged = true
        reading.currentMilliamperes = 0
        let battery = try #require(EnergyCalculator.battery(from: reading).value)
        #expect(battery.timeRemaining == .unavailable(.notApplicable))
        // 0 A at a valid voltage is a real measurement: the battery is idle.
        #expect(battery.batteryPowerWatts.value?.value == 0)
    }

    @Test func missingVoltageOrCurrentIsNotAvailable() throws {
        var reading = discharging
        reading.voltageMillivolts = nil
        let battery = try #require(EnergyCalculator.battery(from: reading).value)
        #expect(battery.voltageVolts == .unavailable(.unsupportedHardware))
        #expect(battery.batteryPowerWatts == .unavailable(.unsupportedHardware))
    }

    @Test func missingCapacityIsUnavailable() {
        #expect(EnergyCalculator.battery(from: PowerSourceReading(maxCapacity: 100)).value == nil)
        #expect(EnergyCalculator.battery(from: PowerSourceReading(currentCapacity: 5, maxCapacity: 0)).value == nil)
    }

    @Test func systemPowerInIsReportedOnAdapterOnly() {
        #expect(EnergyCalculator.systemPowerIn(milliwatts: 23_450, powerSource: .ac) == .available(AttributedValue(23.45, provenance: .reported)))
        // On battery nothing flows in from an adapter: not applicable, never 0 W and never
        // replaced by battery power.
        #expect(EnergyCalculator.systemPowerIn(milliwatts: 0, powerSource: .battery) == .unavailable(.notApplicable))
        #expect(EnergyCalculator.systemPowerIn(milliwatts: nil, powerSource: .ac) == .unavailable(.noPublicAPI))
        #expect(EnergyCalculator.systemPowerIn(milliwatts: 0, powerSource: .ac).value == nil)
        #expect(EnergyCalculator.systemPowerIn(milliwatts: 5_000_000, powerSource: .ac).value == nil)
    }

    @Test func adapterRating() {
        #expect(EnergyCalculator.adapterRating(watts: 96, isConnected: true) == .available(96))
        #expect(EnergyCalculator.adapterRating(watts: 96, isConnected: false) == .unavailable(.notApplicable))
        #expect(EnergyCalculator.adapterRating(watts: nil, isConnected: true) == .unavailable(.unsupportedHardware))
    }

    @Test func historySplitsChargingAndDischarging() {
        func energy(batteryWatts: Double?, systemWatts: Double?) -> EnergySnapshot {
            let battery = BatterySnapshot(
                charge: 0.5, isCharging: false, powerSource: .battery, timeRemaining: .unavailable(.notApplicable),
                voltageVolts: .available(12), currentAmperes: .available(0),
                batteryPowerWatts: batteryWatts.map { .available(AttributedValue($0, provenance: .derived)) } ?? .unavailable(.unsupportedHardware)
            )
            return EnergySnapshot(
                battery: .available(battery),
                systemPowerWatts: systemWatts.map { .available(AttributedValue($0, provenance: .reported)) } ?? .unavailable(.notApplicable),
                cpuPowerWatts: .unavailable(.noPublicAPI), gpuPowerWatts: .unavailable(.noPublicAPI),
                adapterRatingWatts: .unavailable(.notApplicable)
            )
        }
        #expect(SystemHistory.energyValues(energy(batteryWatts: -7, systemWatts: nil)) == [nil, nil, 7])
        #expect(SystemHistory.energyValues(energy(batteryWatts: 20, systemWatts: 45)) == [45, 20, nil])
        #expect(SystemHistory.energyValues(energy(batteryWatts: nil, systemWatts: nil)) == [nil, nil, nil])
    }
}

@Suite("GPU and energy history")
struct GPUEnergyHistoryTests {
    private func snapshot(_ second: UInt64, gpu: MetricState<GPUSnapshot>, energy: MetricState<EnergySnapshot> = .notSampled) -> SystemSnapshot {
        SystemSnapshot(
            sequence: second,
            timestamp: SampleTimestamp(monotonic: MonotonicInstant(nanoseconds: second * 1_000_000_000), wallClock: Date(timeIntervalSince1970: TimeInterval(second))),
            samplingMode: .foreground,
            cpu: .notSampled, memory: .notSampled, disks: .notSampled, network: .notSampled,
            gpu: gpu, energy: energy, processes: .notSampled
        )
    }

    private func gpu(_ utilization: MetricState<Double>) -> MetricState<GPUSnapshot> {
        .available(GPUSnapshot(devices: [
            GPUDeviceSnapshot(id: 7, name: "Test GPU", hasUnifiedMemory: true, isLowPower: false, isRemovable: false, utilization: utilization),
        ]))
    }

    @Test func recordsPerDeviceUtilizationAndGaps() {
        var history = SystemHistory()
        history.append(snapshot(1, gpu: gpu(.available(0.25))))
        history.append(snapshot(2, gpu: gpu(.unavailable(.noPublicAPI))))
        history.append(snapshot(3, gpu: .notSampled))
        #expect(history.gpus[7]?.samples.map(\.values) == [[0.25], [nil]])
        #expect(history.energy.samples.isEmpty)
    }

    @Test func unsampledGPUHistoryIsPruned() {
        var history = SystemHistory()
        history.append(snapshot(1, gpu: gpu(.available(0.5))))
        history.append(snapshot(100, gpu: .notSampled, energy: .unavailable(.unsupportedHardware)))
        #expect(history.gpus.isEmpty)
        #expect(history.energy.latest?.values == [nil, nil, nil])
    }
}
