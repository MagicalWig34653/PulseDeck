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

@Suite("Sampling demand")
struct SamplingDemandTests {
    @Test func menuBarOnlyIsBackgroundWithNothingOptional() {
        let policy = SamplingDemand.policy(for: ObservationState())
        #expect(policy.mode == .background)
        #expect(policy.interval == .seconds(3))
        #expect(policy.demand.isEmpty)
        for kind in [MetricKind.gpu, .energy, .processes] {
            #expect(!policy.shouldSample(kind))
        }
        // The always-sampled domains keep history complete while the window is closed.
        #expect(policy.shouldSample(.cpu) && policy.shouldSample(.network))
    }

    @Test func occludedWindowIsBackgroundEvenOnProcesses() {
        let state = ObservationState(isMainWindowVisible: false, visibleSection: .processes)
        let policy = SamplingDemand.policy(for: state)
        #expect(policy.mode == .background)
        #expect(!policy.shouldSample(.processes))
    }

    @Test func performanceSectionDemandsGPUAndEnergy() {
        let policy = SamplingDemand.policy(for: ObservationState(isMainWindowVisible: true, visibleSection: .performance))
        #expect(policy.mode == .foreground)
        #expect(policy.demand == [.gpu, .energy])
    }

    @Test func processesSectionDemandsOnlyProcessesInTopBar() {
        let policy = SamplingDemand.policy(for: ObservationState(isMainWindowVisible: true, visibleSection: .processes))
        #expect(policy.demand == [.processes])
    }

    @Test func sidebarKeepsPreviewsLiveNextToProcesses() {
        let state = ObservationState(isMainWindowVisible: true, visibleSection: .processes, showsResourcePreviewsInEverySection: true)
        #expect(SamplingDemand.policy(for: state).demand == [.gpu, .energy, .processes])
    }

    @Test func menuBarPanelIsForeground() {
        let policy = SamplingDemand.policy(for: ObservationState(isMenuBarPanelVisible: true))
        #expect(policy.mode == .foreground)
        #expect(policy.demand == [.gpu, .energy])
    }

    @Test func menuBarMetricDemandsItsDomain() {
        let gpu = SamplingDemand.policy(for: ObservationState(menuBarMetricKind: .gpu))
        #expect(gpu.mode == .background)
        #expect(gpu.demand == [.gpu])
        // Always-sampled domains are not added to the demand set.
        #expect(SamplingDemand.policy(for: ObservationState(menuBarMetricKind: .cpu)).demand.isEmpty)
    }

    @Test func backgroundIntervalIsConfigurableWithinRange() {
        #expect(SamplingDemand.policy(for: ObservationState(), backgroundInterval: .seconds(5)).interval == .seconds(5))
        #expect(SamplingDemand.policy(for: ObservationState(), backgroundInterval: .seconds(60)).interval == .seconds(5))
    }
}
