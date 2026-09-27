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

    /// Throughput, e.g. "1.2 MB/s" (decimal multiples).
    public static func byteRate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let bytes = bytesPerSecond.isFinite ? Int64(clamping: Int64(max(bytesPerSecond, 0).rounded())) : 0
        let size = bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
        return "\(size)/s"
    }

    /// Power, e.g. "4.3 W".
    public static func watts(_ watts: Double, fractionDigits: Int = 1, locale: Locale = .current) -> String {
        let number = watts.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
        return "\(number) W"
    }
}
