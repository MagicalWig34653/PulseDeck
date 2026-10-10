import Foundation

/// The client-side view of the kernel's network statistics sources, built from decoded control
/// messages, turned into `NetworkFlowsSnapshot`s. Pure; `FlowMonitor` feeds it.
///
/// - Every `SRC_UPDATE` replaces a source's descriptor and cumulative counts.
/// - `SRC_REMOVED` retires a source: its last values (the kernel sends a final update flagged
///   `CLOSING` first unless the receive buffer was full) go to `closed` for the next snapshot,
///   so the ledger can credit bytes that arrived since the previous poll.
/// - A complete poll (every fragment answered) reports every live source. A source it did not
///   report was removed while its `SRC_REMOVED` was lost, and is retired the same way
///   (makepad's ntstat reader does the same).
/// - Sources stay in the table between polls, so a poll cut short by the deadline still
///   reports every flow with its latest known counters.
/// - Flow IDs survive a reconnect: kernel source references restart with every control
///   connection, so a new table inherits the previous table's `identities` and gives a source
///   the old ID when provider, process (`upid`), start time and endpoints match. Otherwise the
///   ledger would see every open flow as new after a reconnect and credit its bytes twice.
public struct NStatFlowTable: Sendable {
    struct Source: Sendable {
        var descriptor: NStatDescriptor?
        var counts: NStatCounts?
        var flowID: UInt64?
    }

    /// What identifies a kernel flow independently of the client's source reference.
    public struct FlowKey: Hashable, Sendable {
        public var provider: NStat.Provider
        public var uniquePID: UInt64
        public var startTimestamp: UInt64
        public var local: NStatSocketAddress?
        public var remote: NStatSocketAddress?

        public init(_ descriptor: NStatDescriptor) {
            provider = descriptor.provider
            uniquePID = descriptor.uniquePID
            startTimestamp = descriptor.startTimestamp
            local = descriptor.local
            remote = descriptor.remote
        }
    }

    /// Kernel source references count up from 1 per client and restart when the control socket
    /// is reopened. The generation keeps flow IDs of different connections apart.
    public let generation: UInt64
    /// Bounds memory if closed flows are not collected (no snapshot taken for a long time).
    public static let maximumPendingClosed = 20_000

    private var sources: [UInt64: Source] = [:]
    private var pendingClosed: [NetworkFlow] = []
    private var reportedInPoll: Set<UInt64>?
    private var inherited: [FlowKey: UInt64]

    /// Platform hooks for the snapshot: interface index → BSD name, `mach_continuous_time`
    /// timestamp → date. Used synchronously, never stored.
    public struct Conversion {
        public var interfaceName: (UInt32) -> String?
        public var startDate: (UInt64) -> Date?

        public init(interfaceName: @escaping (UInt32) -> String?, startDate: @escaping (UInt64) -> Date?) {
            self.interfaceName = interfaceName
            self.startDate = startDate
        }
    }

    /// - Parameter inheriting: `identities` of the table this one replaces.
    public init(generation: UInt64, inheriting identities: [FlowKey: UInt64] = [:]) {
        self.generation = generation
        inherited = identities
    }

    /// Flow IDs of the live sources (plus inherited ones not matched yet), for the next table.
    public var identities: [FlowKey: UInt64] {
        var result = inherited
        for entry in sources.values {
            if let descriptor = entry.descriptor, let id = entry.flowID {
                result[FlowKey(descriptor)] = id
            }
        }
        return result
    }

    public var sourceCount: Int { sources.count }
    public var pendingClosedCount: Int { pendingClosed.count }

    /// Flow ID for a kernel source reference of this generation: generation in bits 40–62,
    /// the reference in the low 40 (a client would need 10¹² sources to overflow). Bit 63 is
    /// left clear for `SocketTableFlowID`.
    public func flowID(forSource source: UInt64) -> UInt64 {
        ((generation & 0x7F_FFFF) << 40) | (source & 0xFF_FFFF_FFFF)
    }

    public mutating func beginPoll() {
        reportedInPoll = []
    }

    /// Ends a poll. `complete`: the kernel answered every fragment, so sources it did not
    /// report no longer exist.
    public mutating func endPoll(complete: Bool, conversion: Conversion) {
        defer { reportedInPoll = nil }
        guard complete, let reported = reportedInPoll else { return }
        // Every live flow has been seen once: inherited IDs not claimed by now belong to flows
        // that ended while disconnected.
        inherited.removeAll()
        for source in Array(sources.keys) where !reported.contains(source) {
            retire(source, conversion: conversion)
        }
    }

    public mutating func apply(_ event: NStatEvent, conversion: Conversion) {
        switch event {
        case .update(let source, let provider, let counts, let descriptor, _):
            guard NStat.Provider(rawValue: provider)?.descriptorKind != nil else { return }
            var entry = sources[source] ?? Source()
            if let descriptor { entry.descriptor = descriptor }
            entry.counts = counts
            assignID(to: &entry, source: source)
            sources[source] = entry
            reportedInPoll?.insert(source)
        case .counts(let source, let counts, _):
            guard sources[source] != nil else { return }
            sources[source]?.counts = counts
            reportedInPoll?.insert(source)
        case .description(let source, _, let descriptor):
            guard let descriptor else { return }
            var entry = sources[source] ?? Source()
            entry.descriptor = descriptor
            assignID(to: &entry, source: source)
            sources[source] = entry
        case .sourceRemoved(let source, _):
            retire(source, conversion: conversion)
        case .sourceAdded, .success, .error, .unknown:
            break
        }
    }

    /// Live flows (largest first, at most `limit`) plus every flow closed since the previous
    /// snapshot. Sources without a parseable descriptor or without counts yet are left out.
    public mutating func snapshot(limit: Int = 20_000, conversion: Conversion) -> NetworkFlowsSnapshot {
        var flows: [NetworkFlow] = []
        flows.reserveCapacity(min(sources.count, limit))
        for (source, entry) in sources {
            if let flow = makeFlow(source: source, entry: entry, conversion: conversion) {
                flows.append(flow)
            }
        }
        if flows.count > limit {
            flows.sort { lhs, rhs in
                let left = (lhs.bytesReceived.value ?? 0) &+ (lhs.bytesSent.value ?? 0)
                let right = (rhs.bytesReceived.value ?? 0) &+ (rhs.bytesSent.value ?? 0)
                return left != right ? left > right : lhs.id < rhs.id
            }
            flows.removeLast(flows.count - limit)
        }
        let closed = pendingClosed
        pendingClosed.removeAll(keepingCapacity: true)
        return NetworkFlowsSnapshot(source: .networkStatistics, flows: flows, closed: closed)
    }

    private mutating func assignID(to entry: inout Source, source: UInt64) {
        guard entry.flowID == nil, let descriptor = entry.descriptor else { return }
        entry.flowID = inherited.removeValue(forKey: FlowKey(descriptor)) ?? flowID(forSource: source)
    }

    private mutating func retire(_ source: UInt64, conversion: Conversion) {
        guard let entry = sources.removeValue(forKey: source) else { return }
        if let flow = makeFlow(source: source, entry: entry, conversion: conversion) {
            if pendingClosed.count >= Self.maximumPendingClosed {
                pendingClosed.removeFirst()
            }
            pendingClosed.append(flow)
        }
    }

    func makeFlow(source: UInt64, entry: Source, conversion: Conversion) -> NetworkFlow? {
        guard let descriptor = entry.descriptor,
              let counts = entry.counts,
              let id = entry.flowID,
              let transport = descriptor.provider.transport
        else { return nil }
        // A socket that is not connected has no remote address yet (all-zero union): it is
        // reported as the unspecified address of the local family, port 0.
        guard let family = descriptor.remote?.family ?? descriptor.local?.family else { return nil }
        func endpoint(_ address: NStatSocketAddress?) -> FlowEndpoint {
            guard let address else {
                return FlowEndpoint(address: family == .v4 ? "0.0.0.0" : "::", port: 0)
            }
            return FlowEndpoint(address: address.address, port: address.port)
        }
        return NetworkFlow(
            id: id,
            family: family,
            transport: transport,
            local: endpoint(descriptor.local),
            remote: endpoint(descriptor.remote),
            tcpState: descriptor.tcpState.flatMap(NStat.tcpStateName),
            processName: descriptor.processName,
            processID: descriptor.pid > 0 ? descriptor.pid : nil,
            interfaceName: descriptor.interfaceIndex > 0 ? conversion.interfaceName(descriptor.interfaceIndex) : nil,
            bytesReceived: .available(counts.receivedBytes),
            bytesSent: .available(counts.sentBytes),
            startedAt: descriptor.startTimestamp > 0 ? conversion.startDate(descriptor.startTimestamp) : nil
        )
    }
}

/// Identity for flows from the per-process socket table, which has no kernel source reference.
public enum SocketTableFlowID {
    /// FNV-1a over transport, both endpoints and the PID, with the top bit set so it can never
    /// equal a network statistics flow ID (whose generation stays far below 2²³). Stable across
    /// samples and launches.
    public static func make(transport: FlowTransport, local: FlowEndpoint, remote: FlowEndpoint, processID: Int32?) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        mix([transport.protocolNumber])
        mix(local.address.utf8)
        mix([0, UInt8(local.port >> 8), UInt8(local.port & 0xFF)])
        mix(remote.address.utf8)
        mix([0, UInt8(remote.port >> 8), UInt8(remote.port & 0xFF)])
        let pid = UInt32(bitPattern: processID ?? -1)
        mix((0..<4).map { UInt8(truncatingIfNeeded: pid >> (8 * $0)) })
        return hash | (1 << 63)
    }
}
