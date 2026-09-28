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

    @Test func gpu() async throws {
        let monitor = GPUMonitor()
        let state = await monitor.sample(at: clock.now())
        print("GPU capability:", await monitor.capability(), "state:", String(describing: state.unavailableReason))
        for device in state.value?.devices ?? [] {
            print("GPU:", device.name, "registryID", device.id, "unified", device.hasUnifiedMemory, "lowPower", device.isLowPower,
                  "removable", device.isRemovable, "location", device.location, "utilization", String(describing: device.utilization))
            switch device.utilization {
            case .available(let fraction):
                #expect((0...1).contains(fraction))
            case .unavailable(let reason):
                // Missing key: honest "Not Available" (L‑1), never a fabricated zero.
                #expect(reason == .noPublicAPI || reason.isTransientFailure)
            case .notSampled:
                Issue.record("collector must never return notSampled")
            }
        }
        if case .unavailable(let reason) = state {
            #expect(reason == .unsupportedHardware)
        }
    }

    @Test func energy() async throws {
        let energy = try #require(await EnergyMonitor().sample(at: clock.now()).value)
        print("Energy: battery", String(describing: energy.battery), "systemPowerIn", String(describing: energy.systemPowerWatts),
              "adapter", String(describing: energy.adapterRatingWatts))
        // CPU/GPU package power has no public API (L‑2).
        #expect(energy.cpuPowerWatts == .unavailable(.noPublicAPI))
        #expect(energy.gpuPowerWatts == .unavailable(.noPublicAPI))
        if let battery = energy.battery.value {
            #expect((0...1).contains(battery.charge))
            #expect(battery.batteryPowerWatts.value.map { $0.provenance == .derived } ?? true)
            if battery.powerSource == .battery {
                // Battery power is never reported as system power.
                #expect(energy.systemPowerWatts.value == nil)
            }
        } else {
            // Desktops and VMs: no battery is "Not Available", not 0 %.
            #expect(energy.battery.unavailableReason == .unsupportedHardware)
        }
    }

    @Test func processes() async throws {
        let monitor = ProcessMonitor()
        _ = await monitor.sample(at: clock.now())
        // Burn a little CPU so this process has a non-trivial delta.
        var sink: UInt64 = 0
        for value in 0..<5_000_000 as Range<UInt64> { sink &+= value &* value }
        try await Task.sleep(for: .milliseconds(300))
        let processes = try #require(await monitor.sample(at: clock.now()).value)
        let denied = processes.count(where: { $0.cpu.unavailableReason == .permissionDenied })
        print("Processes:", processes.count, "permission denied:", denied, "sink", sink)
        for process in processes.sorted(by: { ($0.cpu.value ?? -1) > ($1.cpu.value ?? -1) }).prefix(8) {
            print("Process:", process.pid, process.name, "cpu", String(describing: process.cpu.value),
                  "memory", String(describing: process.memoryBytes.value), "threads", String(describing: process.threadCount.value),
                  "read/s", String(describing: process.diskReadBytesPerSecond.value), "uid", String(describing: process.userID))
        }
        #expect(processes.count > 10)
        #expect(Set(processes.map(\.id)).count == processes.count)
        let current = try #require(processes.first { $0.pid == getpid() })
        let cpu = try #require(current.cpu.value)
        #expect(cpu > 0 && cpu < Double(ProcessInfo.processInfo.activeProcessorCount) + 0.5)
        #expect((current.memoryBytes.value ?? 0) > 0)
        #expect((current.threadCount.value ?? 0) >= 1)
        #expect(current.path != nil)
        // Other users' processes (root) are listed with name and PID; details are Not Available.
        let launchd = try #require(processes.first { $0.pid == 1 })
        print("launchd:", launchd.name, "uid", String(describing: launchd.userID), "cpu", String(describing: launchd.cpu))
        #expect(launchd.userID == 0)
        #expect(launchd.name == "launchd")
    }

    @Test func identityIsTheSameFromBothSources() throws {
        // Own process: proc_bsdinfo and kinfo_proc must yield the same start time, or a process
        // would change identity when the source changes.
        let pid = getpid()
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        #expect(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size)
        var kinfo = kinfo_proc()
        var kinfoSize = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        #expect(sysctl(&mib, UInt32(mib.count), &kinfo, &kinfoSize, nil, 0) == 0)
        #expect(BasicProcessInfo(bsd).startTimeMicroseconds == BasicProcessInfo(kinfo).startTimeMicroseconds)
        #expect(BasicProcessInfo(bsd).userID == BasicProcessInfo(kinfo).userID)
    }

    @Test func processControlRefusesReusedPID() throws {
        // Our own PID with a wrong start time must be treated as a different, exited process —
        // the signal must not be sent.
        let impostor = ProcessIdentity(pid: getpid(), startTimeMicroseconds: 1)
        #expect(!ProcessControl.isRunning(impostor))
        #expect(throws: ProcessControlError.processExited) { try ProcessControl.send(.kill, to: impostor).get() }
    }

    @Test func processControlTerminatesChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let info = try #require(ProcessControl.basicInfo(of: child.processIdentifier))
        let identity = ProcessIdentity(pid: child.processIdentifier, startTimeMicroseconds: info.startTimeMicroseconds)
        #expect(ProcessControl.isRunning(identity))
        try ProcessControl.send(.terminate, to: identity).get()
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
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
        #expect(snapshot.processes.value == nil)

        // With demand, the demand-driven collectors report real states, never "not implemented".
        await engine.updatePolicy(SamplingPolicy(demand: [.gpu, .energy, .processes]))
        let demanded = await engine.sampleOnce()
        #expect(demanded.gpu.unavailableReason != .notImplemented && demanded.gpu != .notSampled)
        #expect(demanded.energy.value != nil)
        #expect(demanded.processes.value != nil)
    }
}
#endif

#if os(macOS)
extension UnavailableReason {
    fileprivate var isTransientFailure: Bool {
        if case .transientFailure = self { true } else { false }
    }
}
#endif
