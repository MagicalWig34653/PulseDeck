import Foundation

/// Parsing and formatting of VM sizes as vendors write them in configuration files and accept
/// them on command lines ("4GiB", "512MiB", "100", `memoryMiB: 8192`).
///
/// Lima and Colima read sizes with `docker/go-units` `RAMInBytes`, where every suffix (`GB`,
/// `GiB`, `G`) is binary (1024ⁿ). The same convention is used here; `decimalSuffixes` switches
/// `KB`/`MB`/`GB`/`TB` to powers of 1000 for tools that mean that.
public enum VMSizeParsing {
    public enum Unit: Sendable, Equatable {
        case bytes
        case kibibytes
        case mebibytes
        case gibibytes

        var multiplier: UInt64 {
            switch self {
            case .bytes: 1
            case .kibibytes: 1 << 10
            case .mebibytes: 1 << 20
            case .gibibytes: 1 << 30
            }
        }
    }

    public static let bytesPerMiB: UInt64 = 1 << 20
    public static let bytesPerGiB: UInt64 = 1 << 30

    /// Parses a size such as `4GiB`, `4 GiB`, `4gb`, `1.5G`, `512MiB`, `100` (then `defaultUnit`).
    /// Returns `nil` for empty, negative, non-finite, unknown-unit or overflowing input.
    public static func bytes(from text: String, defaultUnit: Unit = .bytes, decimalSuffixes: Bool = false) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split into the numeric prefix and the unit suffix.
        var numberEnd = trimmed.startIndex
        while numberEnd < trimmed.endIndex, ("0"..."9").contains(trimmed[numberEnd]) || trimmed[numberEnd] == "." {
            numberEnd = trimmed.index(after: numberEnd)
        }
        let numberText = String(trimmed[trimmed.startIndex..<numberEnd])
        let suffix = trimmed[numberEnd...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !numberText.isEmpty, let number = Double(numberText), number.isFinite, number >= 0 else { return nil }

        let multiplier: UInt64
        switch suffix {
        case "": multiplier = defaultUnit.multiplier
        case "b": multiplier = 1
        case "k", "kib": multiplier = 1 << 10
        case "kb": multiplier = decimalSuffixes ? 1_000 : 1 << 10
        case "m", "mib": multiplier = 1 << 20
        case "mb": multiplier = decimalSuffixes ? 1_000_000 : 1 << 20
        case "g", "gib": multiplier = 1 << 30
        case "gb": multiplier = decimalSuffixes ? 1_000_000_000 : 1 << 30
        case "t", "tib": multiplier = 1 << 40
        case "tb": multiplier = decimalSuffixes ? 1_000_000_000_000 : 1 << 40
        default: return nil
        }
        let product = number * Double(multiplier)
        // 2⁶⁴ as a Double; anything at or above it does not fit.
        guard product < 18_446_744_073_709_551_616.0 else { return nil }
        return UInt64(product.rounded())
    }

    /// Bytes for a value expressed in a fixed unit (`memoryMiB: 8192`).
    public static func bytes(_ count: Double, unit: Unit) -> UInt64? {
        guard count.isFinite, count >= 0 else { return nil }
        let product = count * Double(unit.multiplier)
        guard product < 18_446_744_073_709_551_616.0 else { return nil }
        return UInt64(product.rounded())
    }

    /// A GiB figure for command-line flags that take GiB as a decimal number (`--memory 4`,
    /// `--memory 4.5`). Up to two decimals, trailing zeros removed, never scientific notation.
    public static func gibibyteFlagValue(fromBytes bytes: UInt64) -> String {
        let hundredths = (Double(bytes) / Double(bytesPerGiB) * 100).rounded()
        let whole = UInt64(hundredths) / 100
        let fraction = UInt64(hundredths) % 100
        if fraction == 0 { return String(whole) }
        let digits = fraction % 10 == 0 ? String(fraction / 10) : (fraction < 10 ? "0\(fraction)" : String(fraction))
        return "\(whole).\(digits)"
    }

    /// `"4GiB"` style string for YAML / settings that expect a unit suffix. Whole GiB when exact,
    /// otherwise whole MiB.
    public static func suffixedString(fromBytes bytes: UInt64) -> String {
        if bytes % bytesPerGiB == 0 { return "\(bytes / bytesPerGiB)GiB" }
        return "\(bytes / bytesPerMiB)MiB"
    }
}
