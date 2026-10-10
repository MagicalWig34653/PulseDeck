import Foundation

public enum IPFamily: String, Hashable, Sendable {
    case v4
    case v6
}

/// Layer 4 protocol of a flow.
public enum FlowTransport: Hashable, Sendable {
    case tcp
    case udp
    /// Any other IP protocol number (ICMP = 1, ICMPv6 = 58 …).
    case other(UInt8)

    /// IANA protocol number.
    public var protocolNumber: UInt8 {
        switch self {
        case .tcp: 6
        case .udp: 17
        case .other(let number): number
        }
    }

    public var name: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .other(1): "ICMP"
        case .other(58): "ICMPv6"
        case .other(let number): "IP \(number)"
        }
    }
}

public struct FlowEndpoint: Hashable, Sendable {
    /// Numeric textual address ("93.184.216.34", "2606:2800::1"), no zone ID.
    public var address: String
    /// 0 when the protocol has no ports.
    public var port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// One layer 3/4 flow (connection or UDP association) of this Mac.
public struct NetworkFlow: Hashable, Sendable, Identifiable {
    /// Unique among the flows of one monitoring session (kernel source ID, or a hash of the
    /// 5-tuple + PID for the socket-table fallback).
    public var id: UInt64
    public var family: IPFamily
    public var transport: FlowTransport
    public var local: FlowEndpoint
    public var remote: FlowEndpoint
    /// "ESTABLISHED", "SYN_SENT", "TIME_WAIT" … (TCP only).
    public var tcpState: String?
    public var processName: String?
    public var processID: Int32?
    /// BSD name of the interface the flow uses, e.g. "en0".
    public var interfaceName: String?
    /// Cumulative since the flow started. `.unavailable` where the source does not count bytes.
    public var bytesReceived: MetricState<UInt64>
    public var bytesSent: MetricState<UInt64>
    public var startedAt: Date?

    public init(id: UInt64, family: IPFamily, transport: FlowTransport, local: FlowEndpoint, remote: FlowEndpoint, tcpState: String? = nil, processName: String? = nil, processID: Int32? = nil, interfaceName: String? = nil, bytesReceived: MetricState<UInt64> = .unavailable(.noPublicAPI), bytesSent: MetricState<UInt64> = .unavailable(.noPublicAPI), startedAt: Date? = nil) {
        self.id = id
        self.family = family
        self.transport = transport
        self.local = local
        self.remote = remote
        self.tcpState = tcpState
        self.processName = processName
        self.processID = processID
        self.interfaceName = interfaceName
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.startedAt = startedAt
    }
}

/// Where the flow list came from.
public enum FlowSource: String, Hashable, Sendable {
    /// The kernel's network statistics control (what `nettop` uses): flows with byte counters.
    /// Undocumented — see TECHNICAL_LIMITATIONS L-14.
    case networkStatistics
    /// The per-process socket table (libproc): flows without byte counters.
    case socketTable
}

public struct NetworkFlowsSnapshot: Hashable, Sendable {
    public var source: FlowSource
    /// Flows alive at this sample (including their current cumulative counters).
    public var flows: [NetworkFlow]
    /// Flows that ended since the previous sample, with their final counters, so the ledger can
    /// credit bytes that arrived between two samples.
    public var closed: [NetworkFlow]

    public init(source: FlowSource, flows: [NetworkFlow], closed: [NetworkFlow] = []) {
        self.source = source
        self.flows = flows
        self.closed = closed
    }
}
