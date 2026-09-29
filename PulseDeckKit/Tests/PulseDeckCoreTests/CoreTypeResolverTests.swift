import Testing
@testable import PulseDeckCore

@Suite struct CoreTypeResolverTests {
    private let m4Pro = [
        CPUInfo.PerformanceLevel(name: "Performance", physicalCoreCount: 10, logicalProcessorCount: 10),
        CPUInfo.PerformanceLevel(name: "Efficiency", physicalCoreCount: 4, logicalProcessorCount: 4),
    ]

    @Test func deviceTreeWins() throws {
        let tree = [
            DeviceTreeCPU(logicalID: 1, clusterType: "P\0"),
            DeviceTreeCPU(logicalID: 0, clusterType: "E"),
        ]
        let result = try #require(CoreTypeResolver.resolve(deviceTree: tree, levels: [], logicalCount: 2))
        #expect(result.types == [.efficiency, .performance])
        #expect(result.source == .deviceTree)
    }

    @Test func deviceTreeFallsBackToCPUIDAndNodeName() {
        let tree = [
            DeviceTreeCPU(cpuID: 0, clusterType: "E"),
            DeviceTreeCPU(name: "cpu1", clusterType: "P"),
        ]
        #expect(CoreTypeResolver.fromDeviceTree(tree, logicalCount: 2) == [.efficiency, .performance])
    }

    @Test func incompleteDeviceTreeUsesPerformanceLevels() throws {
        let tree = [DeviceTreeCPU(logicalID: 0, clusterType: nil)]
        let result = try #require(CoreTypeResolver.resolve(deviceTree: tree, levels: m4Pro, logicalCount: 14))
        #expect(result.source == .performanceLevelOrder)
        #expect(result.types == Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 10))
    }

    @Test func rejectsDuplicatesUnknownTypesAndGaps() {
        #expect(CoreTypeResolver.fromDeviceTree([DeviceTreeCPU(logicalID: 0, clusterType: "E"),
                                                 DeviceTreeCPU(logicalID: 0, clusterType: "P")], logicalCount: 2) == nil)
        #expect(CoreTypeResolver.fromDeviceTree([DeviceTreeCPU(logicalID: 0, clusterType: "S")], logicalCount: 1) == nil)
        #expect(CoreTypeResolver.fromDeviceTree([DeviceTreeCPU(logicalID: 0, clusterType: "E"),
                                                 DeviceTreeCPU(logicalID: 2, clusterType: "P")], logicalCount: 2) == nil)
    }

    @Test func performanceLevelsMustCoverEveryProcessorWithAnEfficiencyLevel() {
        #expect(CoreTypeResolver.fromPerformanceLevels(m4Pro, logicalCount: 16) == nil)
        #expect(CoreTypeResolver.fromPerformanceLevels([m4Pro[0]], logicalCount: 10) == nil)
        let unknownTier = [m4Pro[0], CPUInfo.PerformanceLevel(name: "Super", physicalCoreCount: 4, logicalProcessorCount: 4)]
        #expect(CoreTypeResolver.fromPerformanceLevels(unknownTier, logicalCount: 14) == nil)
        #expect(CoreTypeResolver.resolve(deviceTree: [], levels: [], logicalCount: 8) == nil)
    }
}
