/// Utilization statistics of one `IOAccelerator` service, as read from the IORegistry.
///
/// Source: the `PerformanceStatistics` dictionary of `IOAccelerator` services. The IOKit calls are
/// public, but the dictionary's keys are **undocumented** and driver-specific (approved by the
/// product owner as a labelled source; see TECHNICAL_LIMITATIONS.md L‑1).
public struct AcceleratorStatistics: Hashable, Sendable {
    /// IORegistry entry IDs of the accelerator service and its ancestors (nearest first). Metal's
    /// `MTLDevice.registryID` names one of these entries, depending on the driver.
    public var registryIDs: [UInt64]
    /// Raw value of `Device Utilization %`, `nil` if the driver does not publish the key.
    public var deviceUtilizationPercent: Double?

    public init(registryIDs: [UInt64], deviceUtilizationPercent: Double?) {
        self.registryIDs = registryIDs
        self.deviceUtilizationPercent = deviceUtilizationPercent
    }
}

/// Turns accelerator statistics into per-GPU utilization (SPEC §18). Never reports a value the
/// driver did not publish: missing or implausible readings are `.unavailable` (L‑1).
public enum GPUUtilization {
    /// Key in the `PerformanceStatistics` dictionary (undocumented; AGX, AMD and Intel drivers
    /// publish it as an integer percentage).
    public static let deviceUtilizationKey = "Device Utilization %"

    /// Converts a `Device Utilization %` reading to a fraction in `0...1`.
    ///
    /// - Returns: `.unavailable(.noPublicAPI)` if the key is missing (there is no documented
    ///   alternative), `.unavailable(.transientFailure)` for values outside `0...100`.
    public static func fraction(fromPercent percent: Double?) -> MetricState<Double> {
        guard let percent else { return .unavailable(.noPublicAPI) }
        guard percent.isFinite, (0...100).contains(percent) else {
            return .unavailable(.transientFailure("implausible GPU utilization \(percent)"))
        }
        return .available(percent / 100)
    }

    /// Utilization for each Metal device, keyed by `registryID`.
    ///
    /// A device matches the accelerator whose own entry or ancestor entry has the device's
    /// registry ID. If that fails and there is exactly one device and one accelerator, they are
    /// the same GPU (the common Apple silicon case) and are paired. Anything else stays
    /// unmatched and is reported as `.unavailable(.noPublicAPI)` rather than guessed.
    public static func match(deviceIDs: [UInt64], accelerators: [AcceleratorStatistics]) -> [UInt64: MetricState<Double>] {
        var result: [UInt64: MetricState<Double>] = [:]
        var usedAccelerators = Set<Int>()
        for deviceID in deviceIDs {
            // Prefer the accelerator whose *nearest* entry matches (index 0 = the service itself).
            let candidates = accelerators.enumerated().compactMap { index, accelerator -> (index: Int, depth: Int)? in
                guard !usedAccelerators.contains(index),
                      let depth = accelerator.registryIDs.firstIndex(of: deviceID) else { return nil }
                return (index, depth)
            }
            if let best = candidates.min(by: { $0.depth < $1.depth }) {
                usedAccelerators.insert(best.index)
                result[deviceID] = fraction(fromPercent: accelerators[best.index].deviceUtilizationPercent)
            }
        }
        if deviceIDs.count == 1, accelerators.count == 1, let deviceID = deviceIDs.first, result[deviceID] == nil {
            result[deviceID] = fraction(fromPercent: accelerators[0].deviceUtilizationPercent)
        }
        for deviceID in deviceIDs where result[deviceID] == nil {
            result[deviceID] = .unavailable(.noPublicAPI)
        }
        return result
    }
}
