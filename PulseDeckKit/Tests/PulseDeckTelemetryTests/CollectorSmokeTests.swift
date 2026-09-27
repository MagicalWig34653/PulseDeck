#if os(macOS)
import Foundation
import PulseDeckCore
import Testing
@testable import PulseDeckTelemetry

/// Smoke tests against the real system: values must be plausible and collectors must never
/// crash. Readings are printed so CI logs show what a real machine reports.
@Suite("Darwin collectors")
struct CollectorSmokeTests {
    private let clock = SystemMonotonicClock()

    @Test func cpu() async throws {
        let monitor = CPUMonitor()
        let first = await monitor.sample(at: clock.now())
        #expect(first.unavailableReason == .awaitingBaseline)
        try await Task.sleep(for: .milliseconds(500))
        let cpu = try #require(await monitor.sample(at: clock.now()).value)
        print("CPU:", cpu.info.modelName ?? "?", "logical", cpu.info.logicalProcessorCount,
              "physical", cpu.info.physicalCoreCount ?? -1, "levels", cpu.info.performanceLevels.map(\.name),
              "total", cpu.total, "user", cpu.user, "system", cpu.system)
        #expect(cpu.cores.count == cpu.info.logicalProcessorCount)
        #expect((0...1).contains(cpu.total))
        #expect(abs(cpu.user + cpu.system + cpu.idle - 1) < 1e-9)
        await monitor.invalidateBaselines()
        #expect(await monitor.sample(at: clock.now()).unavailableReason == .awaitingBaseline)
    }

    @Test func memory() async throws {
        let memory = try #require(await MemoryMonitor().sample(at: clock.now()).value)
        print("Memory: total", memory.physicalTotal, "used", memory.used, "app", memory.appMemory,
              "wired", memory.wired, "compressed", memory.compressed, "cached", memory.cachedFiles,
              "swap", String(describing: memory.swap.value), "pressure", String(describing: memory.pressure))
        #expect(memory.physicalTotal > 0)
        #expect(memory.used > 0 && memory.used <= memory.physicalTotal)
        #expect(memory.swap.value != nil)
        #expect(memory.pressure.value != nil)
    }

    @Test func network() async throws {
        let monitor = NetworkMonitor()
        _ = await monitor.sample(at: clock.now())
        try await Task.sleep(for: .milliseconds(500))
        let network = try #require(await monitor.sample(at: clock.now()).value)
        for interface in network.interfaces {
            print("Interface:", interface.id, interface.displayName ?? "-", interface.kind, "up", interface.isUp,
                  "rx", String(describing: interface.receivedBytesPerSecond.value),
                  "tx", String(describing: interface.sentBytesPerSecond.value),
                  "totals", interface.totalBytesReceived, interface.totalBytesSent)
        }
        print("Primary interface:", network.primaryInterfaceID ?? "none", "addresses", network.primaryInterface?.addresses ?? [])
        let loopback = try #require(network.interfaces.first { $0.id == "lo0" })
        #expect(loopback.kind == .loopback)
        #expect(loopback.addresses.contains("127.0.0.1"))
        #expect(loopback.receivedBytesPerSecond.value != nil)
        #expect(Set(network.interfaces.map(\.id)).count == network.interfaces.count)
    }

    @Test func disks() async throws {
        let monitor = DiskMonitor()
        _ = await monitor.sample(at: clock.now())
        try await Task.sleep(for: .milliseconds(500))
        let disks = try #require(await monitor.sample(at: clock.now()).value)
        for disk in disks {
            print("Disk:", disk.id, disk.name, disk.connection, "removable", disk.isRemovable,
                  "capacity", String(describing: disk.capacityBytes.value),
                  "available", String(describing: disk.availableBytes),
                  "read/s", String(describing: disk.readBytesPerSecond.value),
                  "write/s", String(describing: disk.writeBytesPerSecond.value))
        }
        #expect(!disks.isEmpty)
        #expect(disks.contains { $0.readBytesPerSecond.value != nil })
        #expect(disks.contains { $0.availableBytes.value != nil })
        #expect(disks.allSatisfy { $0.activeTime.unavailableReason == .noPublicAPI })
    }

    @Test func engineWithProductionCollectors() async throws {
        let engine = MonitoringEngine(providers: DarwinTelemetry.makeProviders())
        _ = await engine.sampleOnce()
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await engine.sampleOnce()
        #expect(snapshot.cpu.value != nil)
        #expect(snapshot.memory.value != nil)
        #expect(snapshot.network.value != nil)
        #expect(snapshot.disks.value != nil)
        #expect(snapshot.gpu == .notSampled)
    }
}
#endif
