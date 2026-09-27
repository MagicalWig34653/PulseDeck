import Foundation

/// Localized formatting for metric values (SPEC §30). Overview labels use low precision;
/// hover inspection may request more fraction digits.
public enum MetricFormatting {
    /// `0.423` → "42%".
    public static func percent(_ fraction: Double, fractionDigits: Int = 0, locale: Locale = .current) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(locale))
    }

    /// Memory-style sizes (binary multiples, as Activity Monitor/Finder show RAM).
    public static func memoryBytes(_ bytes: UInt64, locale: Locale = .current) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory, spellsOutZero: false).locale(locale))
    }

    /// Storage/transfer sizes (decimal multiples, as macOS shows disk capacity).
    public static func storageBytes(_ bytes: UInt64, locale: Locale = .current) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// Throughput in decimal (SI) units from kB upwards: "0 kB/s", "0.5 kB/s", "12 kB/s",
    /// "1.5 MB/s". One fraction digit below 10 of a unit, none above.
    public static func byteRate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let units: [(divisor: Double, symbol: String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "kB")]
        let unit = units.first { value >= $0.divisor } ?? (1e3, "kB")
        let scaled = value / unit.divisor
        let maximumFractionDigits = scaled < 10 ? 1 : 0
        let number = scaled.formatted(.number.precision(.fractionLength(0...maximumFractionDigits)).locale(locale))
        return "\(number) \(unit.symbol)/s"
    }

    /// Power, e.g. "4.3 W".
    public static func watts(_ watts: Double, fractionDigits: Int = 1, locale: Locale = .current) -> String {
        let number = watts.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
        return "\(number) W"
    }
}
