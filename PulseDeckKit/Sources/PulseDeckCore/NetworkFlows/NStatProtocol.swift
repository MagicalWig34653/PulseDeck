import Foundation

/// Constants, layouts and request encoding for the kernel's network statistics control
/// (`com.apple.network.statistics`), the interface `nettop` and Activity Monitor's Network tab
/// read through the private NetworkStatistics framework. The control itself is reached with
/// public socket calls (`PF_SYSTEM` / `SYSPROTO_CONTROL`), but its messages are only declared in
/// the `PRIVATE` part of xnu's `bsd/net/ntstat.h` — undocumented, see TECHNICAL_LIMITATIONS L‑14.
///
/// Every definition here was taken from `bsd/net/ntstat.h` of xnu-12377.121.6 (macOS 26, identical
/// to xnu `main` at the time of writing) and checked against xnu-11417.140.69 (macOS 15),
/// xnu-10063.141.1 (macOS 14) and xnu-8796.141.3 (macOS 13): the message headers, provider IDs,
/// message types, `nstat_counts` and every descriptor field read below sit at the same offsets
/// in all four. (macOS 13 lacks `persona_id`/`uid`, which come after everything PulseDeck reads.)
/// The kernel side (`bsd/net/ntstat.c`) defines the request handling the monitor relies on.
/// Offsets were cross-checked against an independent client, makepad's
/// `apps/task/src/backend/macos_ntstat.rs` (update header 152 bytes, TCP descriptor 344 with
/// `pid` at 116, UDP descriptor 280 with `pid` at 128).
///
/// All integers are host order; every Mac PulseDeck supports (arm64, x86_64) is little-endian.
/// Structures marked `__attribute__((aligned(8)))` in the header are reflected in the offsets.
///
/// `nstat_msg_hdr` (16 bytes):
///
/// | offset | field |
/// |---|---|
/// | 0 | `context` (UInt64, echoed in responses) |
/// | 8 | `type` (UInt32) |
/// | 12 | `length` (UInt16, whole message including the header) |
/// | 14 | `flags` (UInt16) |
public enum NStat {
    /// `NET_STAT_CONTROL_NAME`, looked up with `ioctl(CTLIOCGINFO)`.
    public static let controlName = "com.apple.network.statistics"

    public static let headerSize = 16
    /// `MAX_NSTAT_MSG_HDR_LENGTH`: the largest message the kernel sends.
    public static let maximumMessageLength = 65532

    /// `NSTAT_SRC_REF_ALL`: "every source" in `GET_UPDATE` / `QUERY_SRC` / `GET_SRC_DESC`.
    public static let allSources: UInt64 = .max
    /// `NSTAT_SRC_REF_INVALID`.
    public static let invalidSource: UInt64 = 0

    /// `nstat_provider_type_t`.
    public enum Provider: UInt32, CaseIterable, Hashable, Sendable {
        case route = 1
        case tcpKernel = 2
        case tcpUserland = 3
        case udpKernel = 4
        case udpUserland = 5
        case interface = 6
        case systemInfo = 7
        /// QUIC flows of Network.framework (registered by NECP instead of a UDP source, so they
        /// are not counted twice). Its descriptor is `nstat_tcp_descriptor` (`typedef`).
        case quicUserland = 8
        /// Connection-level userland statistics; always requires an entitlement.
        case connectionUserland = 9
        case udpSubflow = 10

        /// The providers whose sources are individual layer 4 flows with addresses and
        /// counters, and which need no entitlement on macOS (`nstat_privcheck` is 0 there;
        /// `ntstat.c` `nstat_client_handle_add_all` only always checks `UDP_SUBFLOW` and
        /// `CONN_USERLAND`).
        public static let flowProviders: [Provider] = [.tcpKernel, .tcpUserland, .udpKernel, .udpUserland, .quicUserland]

        /// Which descriptor layout the provider's update/description messages carry.
        public var descriptorKind: DescriptorKind? {
            switch self {
            case .tcpKernel, .tcpUserland, .quicUserland: .tcp
            case .udpKernel, .udpUserland: .udp
            default: nil
            }
        }

        /// The layer 4 protocol on the wire. QUIC runs over UDP.
        public var transport: FlowTransport? {
            switch self {
            case .tcpKernel, .tcpUserland: .tcp
            case .udpKernel, .udpUserland, .quicUserland: .udp
            default: nil
            }
        }
    }

    public enum DescriptorKind: Hashable, Sendable {
        /// `nstat_tcp_descriptor` (also `nstat_quic_descriptor`).
        case tcp
        /// `nstat_udp_descriptor`.
        case udp
    }

    /// `NSTAT_MSG_TYPE_*`.
    public enum MessageType {
        public static let success: UInt32 = 0
        public static let error: UInt32 = 1
        // Requests
        public static let addSource: UInt32 = 1001
        public static let addAllSources: UInt32 = 1002
        public static let removeSource: UInt32 = 1003
        public static let querySource: UInt32 = 1004
        public static let getSourceDescription: UInt32 = 1005
        public static let getUpdate: UInt32 = 1007
        public static let getDetails: UInt32 = 1009
        // Responses / notifications
        public static let sourceAdded: UInt32 = 10001
        public static let sourceRemoved: UInt32 = 10002
        public static let sourceDescription: UInt32 = 10003
        public static let sourceCounts: UInt32 = 10004
        public static let systemInfoCounts: UInt32 = 10005
        public static let sourceUpdate: UInt32 = 10006
        /// An update followed by extension items (domain info …), only sent to privileged
        /// clients that ask for extensions.
        public static let sourceExtendedUpdate: UInt32 = 10007
        public static let sourceDetails: UInt32 = 10008
        public static let sourceExtendedDetails: UInt32 = 10009
    }

    /// `NSTAT_MSG_HDR_FLAG_*`.
    public struct HeaderFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let supportsAggregate = HeaderFlags(rawValue: 1 << 0)
        /// On a poll request: the client accepts the answer in fragments. On the `SUCCESS` that
        /// ends a fragment: more sources remain, ask again with the same context.
        public static let continuation = HeaderFlags(rawValue: 1 << 1)
        /// On the final update of a source that is going away.
        public static let closing = HeaderFlags(rawValue: 1 << 2)
        /// On `SRC_REMOVED`: the final update could not be queued (receive buffer full).
        public static let closedAfterDrop = HeaderFlags(rawValue: 1 << 3)
        public static let closedAfterFilter = HeaderFlags(rawValue: 1 << 4)
        public static let closedAfterGone = HeaderFlags(rawValue: 1 << 6)
    }

    /// Provider-level filter bits of `nstat_msg_add_all_srcs.filter`. No `ACCEPT_*` interface
    /// bit set means every interface (`nstat_tcpudp_reporting_allowed`).
    public struct Filter: OptionSet, Hashable, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }

        /// `NSTAT_FILTER_SUPPRESS_SRC_ADDED`: no `SRC_ADDED` per source. Adding every existing
        /// socket would otherwise queue hundreds of messages at once and overflow the receive
        /// buffer, which makes the kernel drop those sources. Implies update messages.
        public static let suppressSourceAdded = Filter(rawValue: 0x0000_0000_0010_0000)
        /// `NSTAT_FILTER_USE_UPDATE_FOR_ADD`: declared by the header, not consulted by current
        /// kernels; set like makepad does for older ones.
        public static let useUpdateForAdd = Filter(rawValue: 0x0000_0000_0020_0000)
    }

    // MARK: - Layouts

    /// `nstat_msg_hdr`.
    enum HeaderOffset {
        static let context = 0
        static let type = 8
        static let length = 12
        static let flags = 14
    }

    /// `nstat_msg_add_all_srcs` (56 bytes): header, `filter` (u64 @16), `events` (u64 @24),
    /// `provider` (u32 @32), `target_pid` (i32 @36), `target_uuid` (16 bytes @40).
    enum AddAllOffset {
        static let filter = 16
        static let events = 24
        static let provider = 32
        static let targetPID = 36
        static let size = 56
    }

    /// `nstat_msg_query_src_req`, `nstat_msg_get_src_description`, `nstat_msg_rem_src_req`
    /// (24 bytes): header, `srcref` (u64 @16).
    enum SourceRequestOffset {
        static let sourceReference = 16
        static let size = 24
    }

    /// Responses. `srcref` is `aligned(8)` and directly follows the 16-byte header everywhere.
    enum ResponseOffset {
        static let sourceReference = 16
        /// `nstat_msg_error.error` (u32), 24 bytes; the kernel may append the failed request.
        static let errorCode = 16
        static let errorSize = 24
        /// `nstat_msg_src_added.provider`, 32 bytes.
        static let addedProvider = 24
        static let addedSize = 32
        /// `nstat_msg_src_removed`, 24 bytes.
        static let removedSize = 24
        /// `nstat_msg_src_description`: `event_flags` u64 @24, `provider` @32, reserved[4],
        /// descriptor @40.
        static let descriptionProvider = 32
        static let descriptionData = 40
        /// `nstat_msg_src_counts`: `event_flags` @24, `nstat_counts` @32, 144 bytes.
        static let countsCounts = 32
        static let countsSize = 144
        /// `nstat_msg_src_update`: `event_flags` @24, `nstat_counts` @32 (112 bytes), `provider`
        /// @144, reserved[4], descriptor @152.
        static let updateCounts = 32
        static let updateProvider = 144
        static let updateData = 152
    }

    /// `nstat_counts` (112 bytes, `aligned(8)` u64s, then eight u32s).
    enum CountsOffset {
        static let receivedPackets = 0
        static let receivedBytes = 8
        static let sentPackets = 16
        static let sentBytes = 24
        static let cellularReceivedBytes = 32
        static let cellularSentBytes = 40
        static let wifiReceivedBytes = 48
        static let wifiSentBytes = 56
        static let wiredReceivedBytes = 64
        static let wiredSentBytes = 72
        static let receivedDuplicateBytes = 80
        static let receivedOutOfOrderBytes = 84
        static let retransmittedBytes = 88
        static let connectAttempts = 92
        static let connectSuccesses = 96
        static let minimumRTT = 100
        static let averageRTT = 104
        static let rttVariance = 108
        static let size = 112
    }

    /// `nstat_tcp_descriptor` (344 bytes on macOS 14–26, 336 on macOS 13):
    ///
    /// | offset | field |
    /// |---|---|
    /// | 0 | `upid` (u64) |
    /// | 8 | `eupid` (u64) |
    /// | 16 | `start_timestamp` (u64, `mach_continuous_time`) |
    /// | 24 | `timestamp` (u64) |
    /// | 32 | `rx_transfer_size`, 40 `tx_transfer_size` (u64) |
    /// | 48 | `activity_bitmap_t` (24 bytes: start + 128-bit map) |
    /// | 72 | `ifindex` (u32) |
    /// | 76 | `state` (u32, `TCPS_*`) |
    /// | 80–112 | send/receive buffer sizes, window, traffic class, `traffic_mgt_flags` |
    /// | 116 | `pid` (u32) |
    /// | 120 | `epid` (u32) |
    /// | 124 | `local` (union `sockaddr_in`/`sockaddr_in6`, 28 bytes) |
    /// | 152 | `remote` (28 bytes) |
    /// | 180 | `cc_algo[16]` |
    /// | 196 | `pname[64]` |
    /// | 260 | `uuid`, `euuid`, `vuuid`, `fuuid` (16 each) |
    /// | 324 | `persona_id`, 328 `uid` |
    /// | 332 | `connstatus` (4), 336 `ifnet_properties` (u32), 340 `fallback_mode`, reserved[3] |
    enum TCPDescriptorOffset {
        static let uniquePID = 0
        static let startTimestamp = 16
        static let interfaceIndex = 72
        static let state = 76
        static let pid = 116
        static let effectivePID = 120
        static let local = 124
        static let remote = 152
        static let processName = 196
        static let processNameLength = 64
        /// Everything PulseDeck reads ends with `pname`.
        static let minimumSize = 260
        static let size = 344
    }

    /// `nstat_udp_descriptor` (280 bytes on macOS 14–26, 272 on macOS 13):
    ///
    /// | offset | field |
    /// |---|---|
    /// | 0 | `upid`, 8 `eupid`, 16 `start_timestamp`, 24 `timestamp` (u64) |
    /// | 32 | `activity_bitmap_t` (24 bytes) |
    /// | 56 | `local` (28 bytes) |
    /// | 84 | `remote` (28 bytes) |
    /// | 112 | `ifindex`, 116 `rcvbufsize`, 120 `rcvbufused`, 124 `traffic_class` (u32) |
    /// | 128 | `pid` (u32) |
    /// | 132 | `pname[64]` |
    /// | 196 | `epid` (u32) |
    /// | 200 | four UUIDs, 264 `persona_id`, 268 `uid`, 272 `ifnet_properties`, 276 `fallback_mode` |
    enum UDPDescriptorOffset {
        static let uniquePID = 0
        static let startTimestamp = 16
        static let local = 56
        static let remote = 84
        static let interfaceIndex = 112
        static let pid = 128
        static let processName = 132
        static let processNameLength = 64
        static let effectivePID = 196
        static let minimumSize = 200
        static let size = 280
    }

    /// The `sockaddr_in` / `sockaddr_in6` union inside descriptors (28 bytes): `sa_len` @0,
    /// `sa_family` @1, port (network order) @2, IPv4 address @4, IPv6 address @8.
    enum SocketAddressOffset {
        static let length = 0
        static let family = 1
        static let port = 2
        static let ipv4Address = 4
        static let ipv6Address = 8
        static let unionSize = 28
    }

    /// Darwin `AF_INET` / `AF_INET6` (`sys/socket.h`); `AF_INET6` is 30 on Darwin, not Linux's 10.
    static let addressFamilyIPv4: UInt8 = 2
    static let addressFamilyIPv6: UInt8 = 30

    // MARK: - Requests

    /// `NSTAT_MSG_TYPE_ADD_ALL_SRCS`: subscribe to every current and future source of
    /// `provider`. Answered with `SUCCESS` (same context) or `ERROR`.
    public static func addAllSources(provider: Provider, filter: Filter = [.suppressSourceAdded, .useUpdateForAdd], events: UInt64 = 0, context: UInt64) -> [UInt8] {
        var message = header(type: MessageType.addAllSources, length: AddAllOffset.size, context: context)
        write(filter.rawValue, to: &message, at: AddAllOffset.filter)
        write(events, to: &message, at: AddAllOffset.events)
        write(provider.rawValue, to: &message, at: AddAllOffset.provider)
        // target_pid 0 and a null target_uuid: no per-process restriction.
        return message
    }

    /// `NSTAT_MSG_TYPE_GET_UPDATE`: counts plus descriptor of `source` (or every source),
    /// answered by `SRC_UPDATE` messages and a final `SUCCESS`. With `.continuation` the kernel
    /// answers at most 100 sources per request and flags the `SUCCESS` with `.continuation`
    /// while more remain; the next request must reuse the same context.
    public static func getUpdate(source: UInt64 = allSources, context: UInt64, flags: HeaderFlags = .continuation) -> [UInt8] {
        sourceRequest(type: MessageType.getUpdate, source: source, context: context, flags: flags)
    }

    /// `NSTAT_MSG_TYPE_QUERY_SRC`: counts only (`SRC_COUNTS`).
    public static func querySource(_ source: UInt64 = allSources, context: UInt64, flags: HeaderFlags = .continuation) -> [UInt8] {
        sourceRequest(type: MessageType.querySource, source: source, context: context, flags: flags)
    }

    /// `NSTAT_MSG_TYPE_GET_SRC_DESC`: descriptors only (`SRC_DESC`).
    public static func getSourceDescription(_ source: UInt64 = allSources, context: UInt64, flags: HeaderFlags = .continuation) -> [UInt8] {
        sourceRequest(type: MessageType.getSourceDescription, source: source, context: context, flags: flags)
    }

    private static func sourceRequest(type: UInt32, source: UInt64, context: UInt64, flags: HeaderFlags) -> [UInt8] {
        var message = header(type: type, length: SourceRequestOffset.size, context: context, flags: flags)
        write(source, to: &message, at: SourceRequestOffset.sourceReference)
        return message
    }

    /// The kernel overwrites `flags` with 0 when `length` does not match the bytes sent
    /// (`nstat_client_send`: "Legacy clients may not set the length"), which would silently
    /// drop `.continuation` — so the length is always set.
    private static func header(type: UInt32, length: Int, context: UInt64, flags: HeaderFlags = []) -> [UInt8] {
        var message = [UInt8](repeating: 0, count: length)
        write(context, to: &message, at: HeaderOffset.context)
        write(type, to: &message, at: HeaderOffset.type)
        write(UInt16(length), to: &message, at: HeaderOffset.length)
        write(flags.rawValue, to: &message, at: HeaderOffset.flags)
        return message
    }

    static func write<T: FixedWidthInteger>(_ value: T, to buffer: inout [UInt8], at offset: Int) {
        for index in 0..<MemoryLayout<T>.size {
            buffer[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }

    // MARK: - TCP states

    /// `TCPS_*` from `netinet/tcp_fsm.h` (the same values as libproc's `TSI_S_*`), named the
    /// way `netstat` prints them.
    public static func tcpStateName(_ state: UInt32) -> String? {
        let names = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT",
                     "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]
        return state < names.count ? names[Int(state)] : nil
    }
}
