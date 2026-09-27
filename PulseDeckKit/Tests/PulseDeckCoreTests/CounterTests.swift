import Testing
@testable import PulseDeckCore

@Suite("Counter deltas")
struct CounterDeltaTests {
    @Test func monotonicIncrease() {
        #expect(CounterDelta.monotonic(previous: 100, current: 250) == 150)
        #expect(CounterDelta.monotonic(previous: 7, current: 7) == 0)
    }

    @Test func monotonicResetIsInvalid() {
        #expect(CounterDelta.monotonic(previous: 1_000, current: 10) == nil)
    }

    @Test func monotonicNearMaximum() {
        #expect(CounterDelta.monotonic(previous: .max - 10, current: .max) == 10)
    }

    @Test func wrapping32HandlesOverflow() {
        #expect(CounterDelta.wrapping32(previous: .max - 4, current: 5) == 10)
        #expect(CounterDelta.wrapping32(previous: 10, current: 30) == 20)
    }

    @Test func wrapping32RejectsImplausibleDelta() {
        // A reset from 1000 to 10 looks like a huge wrap; the plausibility bound rejects it.
        #expect(CounterDelta.wrapping32(previous: 1_000, current: 10, maximumPlausible: 10_000) == nil)
        #expect(CounterDelta.wrapping32(previous: 1_000, current: 1_500, maximumPlausible: 10_000) == 500)
    }
}

@Suite("Rates")
struct RateCalculatorTests {
    private let second: UInt64 = 1_000_000_000
    private let gap: Duration = .seconds(10)

    private func reading(_ value: UInt64, atNanoseconds nanoseconds: UInt64) -> CounterReading {
        CounterReading(value: value, instant: MonotonicInstant(nanoseconds: nanoseconds))
    }

    @Test func firstSampleAwaitsBaseline() {
        let state = RateCalculator.rate(previous: nil, current: reading(10, atNanoseconds: second), maximumGap: gap)
        #expect(state == .unavailable(.awaitingBaseline))
    }

    @Test func rateUsesActualElapsedTime() {
        let previous = reading(1_000, atNanoseconds: 10 * second)
        let current = reading(4_000, atNanoseconds: 10 * second + 1_500_000_000)
        let state = RateCalculator.rate(previous: previous, current: current, maximumGap: gap)
        #expect(state == .available(2_000))
    }

    @Test func zeroTrafficIsAValidZero() {
        let state = RateCalculator.rate(
            previous: reading(500, atNanoseconds: second),
            current: reading(500, atNanoseconds: 2 * second),
            maximumGap: gap
        )
        #expect(state == .available(0))
    }

    @Test func counterResetIsInvalid() {
        let state = RateCalculator.rate(
            previous: reading(5_000, atNanoseconds: second),
            current: reading(100, atNanoseconds: 2 * second),
            maximumGap: gap
        )
        #expect(state == .unavailable(.invalidDelta))
    }

    @Test func nonPositiveElapsedIsInvalid() {
        let same = RateCalculator.rate(
            previous: reading(1, atNanoseconds: second),
            current: reading(2, atNanoseconds: second),
            maximumGap: gap
        )
        #expect(same == .unavailable(.invalidDelta))
        let backwards = RateCalculator.rate(
            previous: reading(1, atNanoseconds: 2 * second),
            current: reading(2, atNanoseconds: second),
            maximumGap: gap
        )
        #expect(backwards == .unavailable(.invalidDelta))
    }

    @Test func gapLongerThanMaximumIsInvalid() {
        // e.g. a sleep that was not reported: never average over an unknown period.
        let state = RateCalculator.rate(
            previous: reading(0, atNanoseconds: second),
            current: reading(1_000_000, atNanoseconds: 60 * second),
            maximumGap: gap
        )
        #expect(state == .unavailable(.invalidDelta))
    }
}

@Suite("Monotonic time")
struct MonotonicTimeTests {
    @Test func signedElapsed() {
        let a = MonotonicInstant(nanoseconds: 100)
        let b = MonotonicInstant(nanoseconds: 350)
        #expect(b.nanoseconds(since: a) == 250)
        #expect(a.nanoseconds(since: b) == -250)
    }

    @Test func advancedBy() {
        let a = MonotonicInstant(nanoseconds: 1_000)
        #expect(a.advanced(by: .nanoseconds(500)).nanoseconds == 1_500)
        #expect(a.advanced(by: .nanoseconds(-5_000)).nanoseconds == 0)
    }

    @Test func durationConversion() {
        #expect(Duration.milliseconds(1_500).nanosecondsClamped == 1_500_000_000)
        #expect(Duration.seconds(2).secondsDouble == 2)
    }

    @Test func systemClockIsNonDecreasing() {
        let clock = SystemMonotonicClock()
        var previous = clock.now()
        for _ in 0..<1_000 {
            let next = clock.now()
            #expect(next >= previous)
            previous = next
        }
    }
}
