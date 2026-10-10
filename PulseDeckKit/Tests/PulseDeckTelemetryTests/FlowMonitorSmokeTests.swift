#if os(macOS)
import Foundation
import PulseDeckCore
import Testing
@testable import PulseDeckTelemetry

/// Smoke tests of the Traffic collectors against the real system. Readings are printed so the
/// CI log shows which source (network statistics control or socket table) a real Mac delivers.
@Suite("Flow collectors")
struct FlowMonitorSmokeTests {
    private let clock = SystemMonotonicClock()

    @Test func flows() async throws {
        let monitor = FlowMonitor()
        print("Flows capability:", await monitor.capability())
        _ = await monitor.sample(at: clock.now())
        try await Task.sleep(for: .milliseconds(500))
        let state = await monitor.sample(at: clock.now())
        let snapshot = try #require(state.value, "flows: \(String(describing: state.unavailableReason))")
        print("Flows: source", snapshot.source, "live", snapshot.flows.count, "closed", snapshot.closed.count)
        #expect(!snapshot.flows.isEmpty)
        #expect(Set(snapshot.flows.map(\.id)).count == snapshot.flows.count)
        for flow in snapshot.flows.prefix(15) {
            print("Flow:", flow.transport.name, flow.local.address, flow.local.port, "→", flow.remote.address, flow.remote.port,
                  flow.tcpState ?? "-", flow.processName ?? "?", flow.processID ?? -1, flow.interfaceName ?? "-",
                  "rx", String(describing: flow.bytesReceived.value), "tx", String(describing: flow.bytesSent.value),
                  "since", flow.startedAt.map { String(describing: $0) } ?? "-")
        }
        if snapshot.source == .networkStatistics {
            #expect(snapshot.flows.allSatisfy { $0.bytesReceived.value != nil && $0.bytesSent.value != nil })
        }

        // After a reconnect (as after sleep) open flows keep their IDs.
        await monitor.invalidateBaselines()
        let after = await monitor.sample(at: clock.now())
        if let reconnected = after.value, reconnected.source == .networkStatistics, snapshot.source == .networkStatistics {
            let kept = Set(reconnected.flows.map(\.id)).intersection(snapshot.flows.map(\.id))
            print("Flows: IDs kept across reconnect", kept.count, "of", snapshot.flows.count)
            #expect(!kept.isEmpty)
        }
    }

    @Test func resolverSkipsLocalAddresses() {
        #expect(!HostNameResolver.isResolvable("127.0.0.1"))
        #expect(!HostNameResolver.isResolvable("::1"))
        #expect(!HostNameResolver.isResolvable("::"))
        #expect(!HostNameResolver.isResolvable("0.0.0.0"))
        #expect(!HostNameResolver.isResolvable("169.254.10.1"))
        #expect(!HostNameResolver.isResolvable("fe80::1"))
        #expect(!HostNameResolver.isResolvable("224.0.0.251"))
        #expect(!HostNameResolver.isResolvable("ff02::fb"))
        #expect(!HostNameResolver.isResolvable("not an address"))
        #expect(HostNameResolver.isResolvable("1.1.1.1"))
        #expect(HostNameResolver.isResolvable("2606:4700:4700::1111"))
    }

    @Test func resolverReturnsCacheWithoutBlocking() async {
        let resolver = HostNameResolver()
        let start = ContinuousClock.now
        let names = await resolver.resolve(["1.1.1.1", "127.0.0.1", "8.8.8.8"])
        // Each lookup is abandoned after 1.5 s at the latest.
        #expect(ContinuousClock.now - start < .seconds(5))
        print("Resolved:", names)
        #expect(names["127.0.0.1"] == nil)
        #expect(names.values.allSatisfy { !$0.hasSuffix(".") })
    }
}
#endif
