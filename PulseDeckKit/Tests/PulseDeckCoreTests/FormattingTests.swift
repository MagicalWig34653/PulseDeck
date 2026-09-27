import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Formatting")
struct FormattingTests {
    private let locale = Locale(identifier: "en_US")

    @Test func percent() {
        #expect(MetricFormatting.percent(0.423, locale: locale) == "42%")
        #expect(MetricFormatting.percent(0.4237, fractionDigits: 1, locale: locale) == "42.4%")
        #expect(MetricFormatting.percent(0, locale: locale) == "0%")
        #expect(MetricFormatting.percent(1, locale: locale) == "100%")
    }

    @Test func percentUsesLocale() {
        let german = Locale(identifier: "de_DE")
        #expect(MetricFormatting.percent(0.4237, fractionDigits: 1, locale: german).contains("42,4"))
    }

    @Test func watts() {
        #expect(MetricFormatting.watts(4.26, locale: locale) == "4.3 W")
        #expect(MetricFormatting.watts(12, fractionDigits: 0, locale: locale) == "12 W")
    }

    @Test func byteRateNeverNegative() {
        #expect(MetricFormatting.byteRate(-5, locale: locale) == MetricFormatting.byteRate(0, locale: locale))
        #expect(MetricFormatting.byteRate(.nan, locale: locale) == MetricFormatting.byteRate(0, locale: locale))
        #expect(MetricFormatting.byteRate(1_500_000, locale: locale).hasSuffix("/s"))
    }

    @Test func zeroIsANumber() {
        // Foundation spells zero out ("Zero KB") by default; a monitor shows digits.
        #expect(MetricFormatting.byteRate(0, locale: locale).hasPrefix("0"))
        #expect(MetricFormatting.memoryBytes(0, locale: locale).hasPrefix("0"))
    }

    @Test func byteStylesDiffer() {
        // 1 GiB is "1 GB" in memory style but ~"1.07 GB" in decimal file style.
        let gibibyte: UInt64 = 1 << 30
        #expect(MetricFormatting.memoryBytes(gibibyte, locale: locale) != MetricFormatting.storageBytes(gibibyte, locale: locale))
    }
}
