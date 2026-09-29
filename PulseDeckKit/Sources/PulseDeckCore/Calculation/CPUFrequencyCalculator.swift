/// Derives cluster frequencies from performance-state residencies (SPEC §13 extension; source
/// approved as private, labelled — TECHNICAL_LIMITATIONS.md L‑11).
public enum CPUFrequencyCalculator {
    /// State names IOReport uses for a cluster that is not executing.
    public static let inactiveStateNames: Set<String> = ["IDLE", "OFF", "DOWN"]

    /// Plausible range for an Apple silicon CPU state frequency. Values outside it mean the table
    /// was read with the wrong unit or layout, so the table is rejected instead of shown.
    public static let plausibleHz: ClosedRange<Double> = 100_000_000 ... 7_000_000_000

    /// Parses a `pmgr` `voltage-states*` property: consecutive little-endian pairs of
    /// (frequency, voltage) as 32-bit integers. Older chips store Hz, newer ones kHz; the unit is
    /// chosen so the values fall in `plausibleHz`. Zero-frequency padding entries are dropped.
    ///
    /// - Returns: frequencies in Hz, ascending as stored, or `nil` if the data is not a plausible
    ///   table.
    public static func frequencyTable(fromVoltageStates bytes: [UInt8]) -> [Double]? {
        let entrySize = 8
        guard bytes.count >= entrySize, bytes.count % entrySize == 0 else { return nil }
        var raw: [Double] = []
        for start in stride(from: 0, to: bytes.count, by: entrySize) {
            let value = UInt32(bytes[start]) | UInt32(bytes[start + 1]) << 8
                | UInt32(bytes[start + 2]) << 16 | UInt32(bytes[start + 3]) << 24
            if value > 0 { raw.append(Double(value)) }
        }
        guard let maximum = raw.max() else { return nil }
        let kiloHertz = 1_000.0
        let scale = plausibleHz.contains(maximum) ? 1 : kiloHertz
        let table = raw.map { $0 * scale }
        guard table.allSatisfy(plausibleHz.contains) else { return nil }
        return table
    }

    /// Average frequency of a cluster over an interval.
    ///
    /// - Parameters:
    ///   - states: `(name, residency)` in IOReport order; inactive states (`IDLE`, `OFF`,
    ///     `DOWN`) first, then one entry per performance state from slowest to fastest.
    ///   - table: the cluster's state frequencies in Hz, same order as the active states.
    /// - Returns: `nil` if the state list does not match the table (unknown chip layout).
    public static func cluster(id: String, coreType: CoreType?, states: [(name: String, residency: Int64)], table: [Double]) -> ClusterFrequency? {
        let active = states.filter { !inactiveStateNames.contains($0.name.uppercased()) }
        guard !active.isEmpty, active.count <= table.count else { return nil }
        let total = states.reduce(0.0) { $0 + Double(max($1.residency, 0)) }
        let activeTotal = active.reduce(0.0) { $0 + Double(max($1.residency, 0)) }
        var weighted = 0.0
        for (index, state) in active.enumerated() {
            weighted += Double(max(state.residency, 0)) * table[index]
        }
        return ClusterFrequency(
            id: id,
            coreType: coreType,
            activeFrequencyHz: activeTotal > 0 ? weighted / activeTotal : nil,
            activeFraction: total > 0 ? activeTotal / total : 0,
            maximumFrequencyHz: table.max()
        )
    }

    /// Core type from an IOReport cluster channel name ("ECPU", "PCPU1", "EACC_CPU" …).
    public static func coreType(ofChannel name: String) -> CoreType? {
        let upper = name.uppercased()
        if upper.hasPrefix("E") { return .efficiency }
        if upper.hasPrefix("P") { return .performance }
        return nil
    }
}
