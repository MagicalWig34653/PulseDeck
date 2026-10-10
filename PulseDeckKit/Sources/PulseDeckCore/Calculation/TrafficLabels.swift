import Foundation

/// Text helpers for destinations: flags, country names and a stable colour per group.
public enum TrafficLabels {
    /// The flag emoji for an ISO 3166-1 alpha-2 code ("DE" → 🇩🇪): two regional indicator
    /// symbols. `nil` for anything that is not two ASCII letters.
    public static func flagEmoji(regionCode: String) -> String? {
        let letters = regionCode.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ $0.value >= 0x41 && $0.value <= 0x5A }) else { return nil }
        let regional = letters.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 0x41) }
        guard regional.count == 2 else { return nil }
        var flag = String.UnicodeScalarView()
        flag.append(contentsOf: regional)
        return String(flag)
    }

    /// The localized country name for a region code, if the system knows it.
    public static func countryName(regionCode: String, locale: Locale = .current) -> String? {
        guard !regionCode.isEmpty else { return nil }
        return locale.localizedString(forRegionCode: regionCode)
    }

    /// Index into a palette of `count` colours for `key`. Uses FNV-1a, which (unlike
    /// `Hashable`) gives the same result in every launch, so a country or provider keeps its
    /// colour.
    public static func paletteIndex(forKey key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(count))
    }

    /// Fraction of `part` in `whole`, 0…1; zero when `whole` is zero.
    public static func share(_ part: UInt64, of whole: UInt64) -> Double {
        guard whole > 0 else { return 0 }
        return min(Double(part) / Double(whole), 1)
    }
}
