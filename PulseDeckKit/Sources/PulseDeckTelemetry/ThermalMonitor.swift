#if os(macOS)
import Darwin
import Foundation
import IOKit
import PulseDeckCore

/// Temperatures and fans from the System Management Controller.
///
/// macOS has no public temperature or fan API. The SMC is reached through the public IOKit
/// user-client calls (`IOServiceOpen` on `AppleSMC`, `IOConnectCallStructMethod`) — no private
/// framework and no privileges — but its keys are undocumented. Approved by the product owner,
/// labelled in the UI, falling back to *Not Available* (TECHNICAL_LIMITATIONS.md L‑13).
///
/// Sensor keys differ per Mac model, so none are hard-coded: on the first sample every SMC key
/// is enumerated once (`#KEY` count, then key by index), temperature keys ("T…") with a
/// supported data type and a plausible reading are kept and classified by `ThermalClassifier`.
/// Fans: `FNum`, then `F<n>Ac` (actual), `F<n>Mn`/`F<n>Mx` (range), `F<n>Tg` (target).
///
/// Demand-driven: sampled only while the Thermals page is visible.
public actor ThermalMonitor: TelemetryProvider {
    private struct Sensor {
        let code: UInt32
        let name: String
        let info: SMC.KeyInfo
        let zone: ThermalZone
    }

    private let connection: io_connect_t
    private var sensors: [Sensor]?
    private var keyInfo: [UInt32: SMC.KeyInfo] = [:]

    private static let architecture: ThermalClassifier.Architecture = {
        #if arch(arm64)
        return .appleSilicon
        #else
        return .intel
        #endif
    }()

    public init() {
        var connection: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS {
                connection = 0
            }
            IOObjectRelease(service)
        }
        self.connection = connection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    public func capability() -> TelemetryCapability {
        connection == 0 ? .unsupported(.unsupportedHardware) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<ThermalSnapshot> {
        guard connection != 0 else { return .unavailable(.unsupportedHardware) }
        let sensors = self.sensors ?? discoverSensors()
        self.sensors = sensors

        var readings: [TemperatureSensor] = []
        for sensor in sensors {
            guard let celsius = value(of: sensor.code, info: sensor.info), ThermalClassifier.isPlausible(celsius) else { continue }
            readings.append(TemperatureSensor(key: sensor.name, zone: sensor.zone, celsius: celsius))
        }
        let fans = readFans()
        if readings.isEmpty, fans.value == nil {
            return .unavailable(.unsupportedHardware)
        }
        return .available(ThermalSnapshot(sensors: readings, fans: fans))
    }

    public func invalidateBaselines() {
        // Instantaneous readings; the sensor list stays valid across sleep.
    }

    // MARK: - Discovery

    private func discoverSensors() -> [Sensor] {
        guard let countKey = SMC.fourCC("#KEY"), let count = read(countKey), count > 0 else { return [] }
        // Bounded: real SMCs have a few thousand keys.
        let maximumKeys = 10_000
        var result: [Sensor] = []
        for index in 0..<min(Int(count), maximumKeys) {
            guard let response = call(SMC.request(.readIndex, index: UInt32(index))),
                  SMC.result(of: response) == 0,
                  let code = SMC.key(of: response)
            else { continue }
            let name = SMC.string(fromFourCC: code)
            guard let zone = ThermalClassifier.zone(ofKey: name, architecture: Self.architecture),
                  let info = info(of: code),
                  let celsius = value(of: code, info: info),
                  ThermalClassifier.isPlausible(celsius)
            else { continue }
            result.append(Sensor(code: code, name: name, info: info, zone: zone))
        }
        return result
    }

    // MARK: - Fans

    private func readFans() -> MetricState<[FanReading]> {
        guard let countKey = SMC.fourCC("FNum"), let count = read(countKey) else {
            return .unavailable(.unsupportedHardware)
        }
        guard count > 0 else { return .unavailable(.notApplicable) }
        // The SMC addresses fans 0–9 with one digit.
        let maximumFans = 10
        var fans: [FanReading] = []
        for index in 0..<min(Int(count), maximumFans) {
            func fanValue(_ suffix: String) -> Double? {
                SMC.fourCC("F\(index)\(suffix)").flatMap { read($0) }
            }
            guard let actual = fanValue("Ac"), actual >= 0 else { continue }
            fans.append(FanReading(index: index, actualRPM: actual, minimumRPM: fanValue("Mn"),
                                   maximumRPM: fanValue("Mx"), targetRPM: fanValue("Tg")))
        }
        return fans.isEmpty ? .unavailable(.transientFailure("no fan readings")) : .available(fans)
    }

    // MARK: - SMC calls

    private func read(_ code: UInt32) -> Double? {
        info(of: code).flatMap { value(of: code, info: $0) }
    }

    private func info(of code: UInt32) -> SMC.KeyInfo? {
        if let cached = keyInfo[code] { return cached }
        guard let response = call(SMC.request(.readKeyInfo, key: code)), let info = SMC.keyInfo(of: response) else { return nil }
        keyInfo[code] = info
        return info
    }

    private func value(of code: UInt32, info: SMC.KeyInfo) -> Double? {
        guard let response = call(SMC.request(.readBytes, key: code, dataSize: info.dataSize)),
              let bytes = SMC.valueBytes(of: response, size: info.dataSize)
        else { return nil }
        return SMC.decode(bytes, type: info.dataType)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: SMC.structureSize)
        var outputSize = SMC.structureSize
        let status = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(connection, SMC.selector, inputBytes.baseAddress, inputBytes.count,
                                          outputBytes.baseAddress, &outputSize)
            }
        }
        return status == KERN_SUCCESS ? output : nil
    }
}
#endif
