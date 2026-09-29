import Foundation
import Testing
@testable import PulseDeckCore

private func instant(_ seconds: UInt64) -> MonotonicInstant {
    MonotonicInstant(nanoseconds: seconds * 1_000_000_000)
}

private func littleEndianPairs(_ values: [(UInt32, UInt32)]) -> [UInt8] {
    values.flatMap { frequency, voltage in
        withUnsafeBytes(of: frequency.littleEndian, Array.init) + withUnsafeBytes(of: voltage.littleEndian, Array.init)
    }
}

@Suite("CPU frequency")
struct CPUFrequencyTests {
    @Test func parsesHertzTable() throws {
        let bytes = littleEndianPairs([(600_000_000, 700), (1_200_000_000, 800), (3_200_000_000, 1000), (0, 0)])
        let table = try #require(CPUFrequencyCalculator.frequencyTable(fromVoltageStates: bytes))
        #expect(table == [600_000_000, 1_200_000_000, 3_200_000_000])
    }

    @Test func parsesKilohertzTable() throws {
        let bytes = littleEndianPairs([(912_000, 700), (4_512_000, 1000)])
        let table = try #require(CPUFrequencyCalculator.frequencyTable(fromVoltageStates: bytes))
        #expect(table == [912_000_000, 4_512_000_000])
    }

    @Test func rejectsImplausibleTables() {
        #expect(CPUFrequencyCalculator.frequencyTable(fromVoltageStates: [1, 2, 3]) == nil)
        #expect(CPUFrequencyCalculator.frequencyTable(fromVoltageStates: littleEndianPairs([(5, 1)])) == nil)
        #expect(CPUFrequencyCalculator.frequencyTable(fromVoltageStates: littleEndianPairs([(0, 0)])) == nil)
    }

    @Test func weightsActiveStatesByResidency() throws {
        let cluster = try #require(CPUFrequencyCalculator.cluster(
            id: "PCPU", coreType: .performance,
            states: [("IDLE", 500), ("V0P0", 250), ("V1P1", 0), ("V2P2", 250)],
            table: [1e9, 2e9, 3e9]
        ))
        // Active half the time; half of that at 1 GHz, half at 3 GHz.
        #expect(cluster.activeFraction == 0.5)
        #expect(cluster.activeFrequencyHz == 2e9)
        #expect(cluster.maximumFrequencyHz == 3e9)
    }

    @Test func idleClusterHasNoFrequencyNotZero() throws {
        let cluster = try #require(CPUFrequencyCalculator.cluster(
            id: "ECPU", coreType: .efficiency, states: [("IDLE", 1000), ("V0P0", 0)], table: [6e8]
        ))
        #expect(cluster.activeFrequencyHz == nil)
        #expect(cluster.activeFraction == 0)
    }

    @Test func mismatchedTableIsRejected() {
        #expect(CPUFrequencyCalculator.cluster(id: "PCPU", coreType: nil,
                                               states: [("V0", 1), ("V1", 1), ("V2", 1)], table: [1e9, 2e9]) == nil)
    }

    @Test func channelCoreTypes() {
        #expect(CPUFrequencyCalculator.coreType(ofChannel: "ECPU") == .efficiency)
        #expect(CPUFrequencyCalculator.coreType(ofChannel: "PCPU1") == .performance)
        #expect(CPUFrequencyCalculator.coreType(ofChannel: "GPU") == nil)
    }
}

@Suite("HTTP responses")
struct HTTPResponseTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func contentLength() throws {
        let response = try HTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]extra"))
        #expect(response.statusCode == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.body == bytes("[]"))
    }

    @Test func chunked() throws {
        let response = try HTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3;ext=1\r\n:1}\r\n0\r\n\r\n"))
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"a\":1}")
    }

    @Test func untilClose() throws {
        let response = try HTTPResponse.parse(bytes("HTTP/1.0 404 Not Found\r\n\r\nmissing"))
        #expect(response.statusCode == 404)
        #expect(response.body == bytes("missing"))
    }

    @Test func errors() {
        #expect(throws: HTTPResponse.ParseError.incomplete) { try HTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\n")) }
        #expect(throws: HTTPResponse.ParseError.malformedStatusLine) { try HTTPResponse.parse(bytes("garbage\r\n\r\n")) }
        #expect(throws: HTTPResponse.ParseError.malformedChunk) {
            try HTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"))
        }
        #expect(throws: HTTPResponse.ParseError.incomplete) {
            try HTTPResponse.parse(bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"))
        }
    }

    @Test func requestSerialisation() {
        let request = String(decoding: HTTPResponse.request(method: "POST", path: "/containers/x/stop", host: "docker"), as: UTF8.self)
        #expect(request.hasPrefix("POST /containers/x/stop HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n"))
        #expect(request.contains("Content-Length: 0\r\n"))
        #expect(request.hasSuffix("\r\n\r\n"))
    }
}

@Suite("Tailscale")
struct TailscaleTests {
    private let status = """
    {"BackendState":"Running","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::1"],
     "Self":{"HostName":"macbook","TailscaleIPs":["100.101.102.103"]},
     "CurrentTailnet":{"Name":"example.org"},
     "Peer":{
       "nodekey:a":{"ID":"n1","HostName":"nas","DNSName":"nas.example.ts.net.","OS":"linux","TailscaleIPs":["100.64.0.2"],
                    "Online":true,"Active":true,"CurAddr":"203.0.113.5:41641","Relay":"fra","RxBytes":1000,"TxBytes":500},
       "nodekey:b":{"ID":"n2","HostName":"phone","OS":"iOS","Online":true,"Active":true,"CurAddr":"","Relay":"ams","RxBytes":0,"TxBytes":0},
       "nodekey:c":{"ID":"n3","HostName":"old-laptop","Online":false,"Active":false,"RxBytes":0,"TxBytes":0}
     }}
    """

    @Test func decodesPeersAndConnections() throws {
        var tracker = TailscaleStatusTracker()
        let result = tracker.snapshot(fromStatusJSON: Array(status.utf8), at: instant(1))
        let snapshot = try #require(result)
        #expect(snapshot.backendState == "Running")
        #expect(snapshot.tailnetName == "example.org")
        #expect(snapshot.selfHostName == "macbook")
        #expect(snapshot.peers.map(\.hostName) == ["nas", "phone", "old-laptop"])
        let nas = snapshot.peers[0]
        #expect(nas.dnsName == "nas.example.ts.net")
        #expect(nas.connectionKind == .direct)
        #expect(snapshot.peers[1].connectionKind == .relayed("ams"))
        #expect(snapshot.peers[2].connectionKind == .idle)
        #expect(nas.receivedBytesPerSecond == .unavailable(.awaitingBaseline))
    }

    @Test func peerRatesFromCounters() throws {
        var tracker = TailscaleStatusTracker()
        _ = tracker.snapshot(fromStatusJSON: Array(status.utf8), at: instant(1))
        let later = status.replacingOccurrences(of: "\"RxBytes\":1000", with: "\"RxBytes\":3000")
        let result = tracker.snapshot(fromStatusJSON: Array(later.utf8), at: instant(3))
        let snapshot = try #require(result)
        #expect(snapshot.peers[0].receivedBytesPerSecond == .available(1000))
        #expect(snapshot.peers[0].sentBytesPerSecond == .available(0))
    }

    @Test func rejectsNonStatus() {
        var tracker = TailscaleStatusTracker()
        #expect(tracker.snapshot(fromStatusJSON: Array("not json".utf8), at: instant(1)) == nil)
    }

    @Test func detectsTailscaleInterfaces() {
        #expect(NetworkInterfaceClassifier.isTailscale(bsdName: "utun4", addresses: ["100.101.1.2"]))
        #expect(NetworkInterfaceClassifier.isTailscale(bsdName: "utun7", addresses: ["fd7a:115c:a1e0::53"]))
        // CGNAT addresses on a non-tunnel interface (carrier) are not Tailscale.
        #expect(!NetworkInterfaceClassifier.isTailscale(bsdName: "en0", addresses: ["100.72.1.1"]))
        #expect(!NetworkInterfaceClassifier.isTailscale(bsdName: "utun2", addresses: ["100.128.0.1", "10.0.0.1"]))
        let kind = NetworkInterfaceClassifier.classify(bsdName: "utun4", interfaceType: 0xff, isLoopback: false,
                                                       systemConfigurationType: nil, displayName: nil, addresses: ["100.100.1.1"])
        #expect(kind == .vpnTunnel(friendlyName: "Tailscale"))
    }
}

@Suite("Docker")
struct DockerTests {
    private let list = """
    [{"Id":"abc123","Names":["/web"],"Image":"nginx:latest","State":"running","Status":"Up 3 hours","Created":1700000000,
      "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"IP":"::","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"PrivatePort":443,"Type":"tcp"}],
      "Labels":{"com.docker.compose.project":"shop"}},
     {"Id":"def456","Names":["/db"],"Image":"postgres","State":"exited","Status":"Exited (0) 2 days ago","Created":1699000000}]
    """

    private func stats(cpu: UInt64, rx: UInt64) -> [UInt8] {
        Array("""
        {"cpu_stats":{"cpu_usage":{"total_usage":\(cpu)}},
         "memory_stats":{"usage":300000000,"limit":2000000000,"stats":{"inactive_file":100000000}},
         "networks":{"eth0":{"rx_bytes":\(rx),"tx_bytes":10}},"pids_stats":{"current":7}}
        """.utf8)
    }

    @Test func decodesContainerList() throws {
        let containers = try #require(DockerStatsTracker.containers(fromJSON: Array(list.utf8)))
        #expect(containers.count == 2)
        var tracker = DockerStatsTracker()
        let web = tracker.snapshot(for: containers[0], statsJSON: stats(cpu: 0, rx: 0), at: instant(1))
        #expect(web.name == "web")
        #expect(web.ports == ["8080→80/tcp", "443/tcp"])
        #expect(web.composeProject == "shop")
        #expect(web.isRunning)
        #expect(web.memoryBytes == .available(200_000_000))
        #expect(web.processCount == .available(7))
        #expect(web.cpu == .unavailable(.awaitingBaseline))
        let db = tracker.snapshot(for: containers[1], statsJSON: nil, at: instant(1))
        #expect(!db.isRunning)
        #expect(db.cpu == .unavailable(.notApplicable))
    }

    @Test func cpuAndNetworkRates() throws {
        let summary = try #require(DockerStatsTracker.containers(fromJSON: Array(list.utf8))?.first)
        var tracker = DockerStatsTracker()
        _ = tracker.snapshot(for: summary, statsJSON: stats(cpu: 0, rx: 0), at: instant(10))
        // 1.5 s of CPU over 2 s = 0.75 of one CPU.
        let web = tracker.snapshot(for: summary, statsJSON: stats(cpu: 1_500_000_000, rx: 4_000), at: instant(12))
        #expect(web.cpu == .available(0.75))
        #expect(web.networkReceivedBytesPerSecond == .available(2_000))
    }

    @Test func failedStatsAreTransientNotZero() throws {
        let summary = try #require(DockerStatsTracker.containers(fromJSON: Array(list.utf8))?.first)
        var tracker = DockerStatsTracker()
        let web = tracker.snapshot(for: summary, statsJSON: Array("oops".utf8), at: instant(1))
        #expect(web.memoryBytes.value == nil)
        #expect(web.cpu.value == nil)
    }

    @Test func engineVersion() {
        #expect(DockerStatsTracker.engineVersion(fromJSON: Array("{\"Version\":\"27.3.1\"}".utf8)) == "27.3.1")
    }
}

@Suite("USB tree")
struct USBTreeTests {
    @Test func aggregatesPowerAndSpeed() {
        let keyboard = USBNode(id: 3, kind: .device, name: "Keyboard", speed: .full, allocatedMilliamps: 100)
        let drive = USBNode(id: 4, kind: .device, name: "SSD", speed: .superSpeedPlus, allocatedMilliamps: 896)
        let hub = USBNode(id: 2, kind: .hub, name: "Hub", speed: .superSpeed, children: [keyboard, drive])
        let bus = USBNode(id: 1, kind: .controller, name: "XHCI", children: [hub])
        #expect(bus.totalAllocatedMilliamps == 996)
        #expect(bus.fastestSpeed == .superSpeedPlus)
        #expect(bus.deviceCount == 2)
        #expect(drive.allocatedWatts == 4.48)
        #expect(USBNode(id: 9, kind: .controller, name: "Empty").totalAllocatedMilliamps == nil)
        #expect(USBSpeed.high.bitsPerSecond == 480_000_000)
    }

    @Test func wifiStandards() {
        #expect(WiFiStandard(phyModeRawValue: 6) == .wifi6)
        #expect(WiFiStandard(phyModeRawValue: 7) == .wifi7)
        #expect(WiFiStandard(phyModeRawValue: 0) == nil)
    }
}

@Suite("Feature demand")
struct FeatureDemandTests {
    @Test func containersSectionDemandsContainers() {
        let policy = SamplingDemand.policy(for: ObservationState(isMainWindowVisible: true, visibleSection: .containers))
        #expect(policy.demand == [.containers])
    }

    @Test func detailPagesAddTheirDomainsOnlyInPerformance() {
        let performance = ObservationState(isMainWindowVisible: true, visibleSection: .performance, detailPageDemand: [.cpuFrequency])
        #expect(SamplingDemand.policy(for: performance).demand == [.gpu, .energy, .cpuFrequency])
        var processes = performance
        processes.visibleSection = .processes
        #expect(!SamplingDemand.policy(for: processes).demand.contains(.cpuFrequency))
    }

    @Test func foregroundIntervalIsConfigurableAndClamped() {
        let visible = ObservationState(isMainWindowVisible: true, visibleSection: .performance)
        #expect(SamplingDemand.policy(for: visible, foregroundInterval: .milliseconds(500)).interval == .milliseconds(500))
        #expect(SamplingDemand.policy(for: visible, foregroundInterval: .milliseconds(100)).interval == .milliseconds(500))
        #expect(SamplingDemand.policy(for: visible, foregroundInterval: .seconds(60)).interval == .seconds(5))
    }

    @Test func memoryCompression() {
        let snapshot = MemoryCalculator.snapshot(
            physicalTotal: 16 << 30, pageSize: 16_384,
            pages: VMPageCounts(free: 0, active: 0, inactive: 0, wired: 0, speculative: 0, purgeable: 0,
                                compressor: 1_000, internalPages: 0, externalPages: 0, uncompressedInCompressor: 3_500),
            swap: .unavailable(.notImplemented), pressure: .unavailable(.notImplemented)
        )
        #expect(snapshot.compressed == 16_384_000)
        #expect(snapshot.compressedOriginal == 57_344_000)
        #expect(snapshot.compressionRatio == 3.5)
    }
}
