import Testing
@testable import PulseDeckCore

@Suite("SamplingPolicy")
struct SamplingPolicyTests {
    @Test func defaults() {
        let policy = SamplingPolicy()
        #expect(policy.mode == .foreground)
        #expect(policy.interval == .seconds(1))
        #expect(policy.tolerance == .milliseconds(100))
    }

    @Test func backgroundUsesReducedRate() {
        let policy = SamplingPolicy(mode: .background)
        #expect(policy.interval == .seconds(3))
    }

    @Test func backgroundIntervalIsClampedToSpecRange() {
        #expect(SamplingPolicy(backgroundInterval: .milliseconds(500)).backgroundInterval == .seconds(2))
        #expect(SamplingPolicy(backgroundInterval: .seconds(30)).backgroundInterval == .seconds(5))
        var policy = SamplingPolicy()
        policy.backgroundInterval = .seconds(60)
        #expect(policy.backgroundInterval == .seconds(5))
    }

    @Test func suspendedHasNoInterval() {
        let policy = SamplingPolicy(mode: .suspended)
        #expect(policy.interval == nil)
        #expect(policy.tolerance == nil)
        for kind in MetricKind.allCases {
            #expect(!policy.shouldSample(kind))
        }
    }

    @Test func expensiveMetricsAreDemandDriven() {
        var policy = SamplingPolicy()
        for kind in MetricKind.alwaysSampled {
            #expect(policy.shouldSample(kind))
        }
        #expect(!policy.shouldSample(.gpu))
        #expect(!policy.shouldSample(.energy))
        #expect(!policy.shouldSample(.processes))
        policy.demand = [.processes]
        #expect(policy.shouldSample(.processes))
        #expect(!policy.shouldSample(.gpu))
    }

    @Test func maximumGapScalesWithInterval() {
        #expect(SamplingPolicy(mode: .foreground).maximumSampleGap == .seconds(10))
        #expect(SamplingPolicy(mode: .background, backgroundInterval: .seconds(5)).maximumSampleGap == .seconds(15))
    }
}
