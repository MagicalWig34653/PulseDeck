import Testing
@testable import PulseDeckCore

@Suite("MetricState")
struct MetricStateTests {
    @Test func mapPreservesUnavailableReason() {
        let state: MetricState<Int> = .unavailable(.noPublicAPI)
        #expect(state.map { $0 * 2 } == .unavailable(.noPublicAPI))
        #expect(state.value == nil)
        #expect(state.unavailableReason == .noPublicAPI)
    }

    @Test func mapTransformsValue() {
        #expect(MetricState.available(21).map { $0 * 2 } == .available(42))
        #expect(MetricState<Int>.notSampled.map { $0 * 2 } == .notSampled)
    }

    @Test func flatMapPropagatesInnerUnavailability() {
        let outer: MetricState<MetricState<Int>> = .available(.unavailable(.unsupportedHardware))
        #expect(outer.flatMap { $0 } == .unavailable(.unsupportedHardware))
        #expect(MetricState<Int>.unavailable(.permissionDenied).flatMap { MetricState.available($0) } == .unavailable(.permissionDenied))
        #expect(MetricState.available(1).flatMap { MetricState.available($0 + 1) } == .available(2))
    }
}
