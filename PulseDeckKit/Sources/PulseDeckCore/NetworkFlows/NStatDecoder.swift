import Foundation

/// `nstat_counts`: cumulative since the source (socket / userland flow) was created.
public struct NStatCounts: Hashable, Sendable {
    public var receivedPackets: UInt64
    public var receivedBytes: UInt64
    public var sentPackets: UInt64
    public var sentBytes: UInt64
    public var cellularReceivedBytes: UInt64
    public var cellularSentBytes: UInt64
    public var wifiReceivedBytes: UInt64
    public var wifiSentBytes: UInt64
    public var wiredReceivedBytes: UInt64
    public var wiredSentBytes: UInt64

    public init(receivedPackets: UInt64 = 0, receivedBytes: UInt64 = 0, sentPackets: UInt64 = 0, sentBytes: UInt64 = 0, cellularReceivedBytes: UInt64 = 0, cellularSentBytes: UInt64 = 0, wifiReceivedBytes: UInt64 = 0, wifiSentBytes: UInt64 = 0, wiredReceivedBytes: UInt64 = 0, wiredSentBytes: UInt64 = 0) {
        self.receivedPackets = receivedPackets
        self.receivedBytes = receivedBytes
        self.sentPackets = sentPackets
        self.sentBytes = sentBytes
        self.cellularReceivedBytes = cellularReceivedBytes
        self.cellularSentBytes = cellularSentBytes
        self.wifiReceivedBytes = wifiReceivedBytes
        self.wifiSentBytes = wifiSentBytes
        self.wiredReceivedBytes = wiredReceivedBytes
        self.wiredSentBytes = wiredSentBytes
    }
}

/// An IPv4/IPv6 socket address from a descriptor's `sockaddr_in`/`sockaddr_in6` union.
public struct NStatSocketAddress: Hashable, Sendable {
    public var family: IPFamily
    /// 4 bytes (IPv4) or 16 bytes (IPv6), network order. IPv4-mapped IPv6 addresses
    /// (`::ffff:a.b.c.d`, dual-stack sockets) are stored as IPv4.
    public var bytes: [UInt8]
    public var port: UInt16

    public init(family: IPFamily, bytes: [UInt8], port: UInt16) {
        self.family = family
        self.bytes = bytes
        self.port = port
    }

    /// Numeric text ("93.184.216.34", "2606:2800:220:1::1"), RFC 5952 for IPv6.
    public var address: String {
        IPAddressText.format(bytes) ?? ""
    }

    public var isUnspecified: Bool {
        bytes.allSatisfy { $0 == 0 }
    }
}

/// What a TCP, UDP or QUIC descriptor says about a source.
public struct NStatDescriptor: Hashable, Sendable {
    public var provider: NStat.Provider
    public var local: NStatSocketAddress?
    public var remote: NStatSocketAddress?
    /// Outgoing interface (0 = not yet known).
    public var interfaceIndex: UInt32
    /// `TCPS_*` for TCP sources; `nil` for UDP and QUIC.
    public var tcpState: UInt32?
    /// The process that last used the socket (what `nettop` shows).
    public var pid: Int32
    /// The process the traffic was done on behalf of (e.g. an app behind `nsurlsessiond`).
    public var effectivePID: Int32
    public var processName: String?
    /// The kernel's never-reused process ID (`upid`).
    public var uniquePID: UInt64
    /// `mach_continuous_time()` when the socket was created; 0 when unknown.
    public var startTimestamp: UInt64

    public init(provider: NStat.Provider, local: NStatSocketAddress?, remote: NStatSocketAddress?, interfaceIndex: UInt32 = 0, tcpState: UInt32? = nil, pid: Int32 = 0, effectivePID: Int32 = 0, processName: String? = nil, uniquePID: UInt64 = 0, startTimestamp: UInt64 = 0) {
        self.provider = provider
        self.local = local
        self.remote = remote
        self.interfaceIndex = interfaceIndex
        self.tcpState = tcpState
        self.pid = pid
        self.effectivePID = effectivePID
        self.processName = processName
        self.uniquePID = uniquePID
        self.startTimestamp = startTimestamp
    }
}

/// One decoded control message.
public enum NStatEvent: Hashable, Sendable {
    /// The request with `context` finished. `.continuation` in `flags`: more fragments remain.
    case success(context: UInt64, flags: NStat.HeaderFlags)
    /// The request with `context` failed with `errno` `code`.
    case error(context: UInt64, code: UInt32)
    case sourceAdded(source: UInt64, provider: UInt32)
    case sourceRemoved(source: UInt64, flags: NStat.HeaderFlags)
    /// `descriptor` is `nil` for providers PulseDeck does not read or a descriptor that fails
    /// the layout checks.
    case description(source: UInt64, provider: UInt32, descriptor: NStatDescriptor?)
    case counts(source: UInt64, counts: NStatCounts, flags: NStat.HeaderFlags)
    /// Counts and descriptor together (`SRC_UPDATE`, `SRC_EXTENDED_UPDATE`). `.closing` in
    /// `flags`: the source's final values, a `sourceRemoved` follows.
    case update(source: UInt64, provider: UInt32, counts: NStatCounts, descriptor: NStatDescriptor?, flags: NStat.HeaderFlags)
    /// A well-formed message of a type PulseDeck does not use (sysinfo, details …).
    case unknown(type: UInt32)
}

/// Splits control-socket data into messages and decodes them. Pure: no Darwin calls.
///
/// Framing: one `recv` on the control socket returns one record, which may hold several
/// messages back to back (`nstat_accumulate_msg` packs updates into 4 KiB records). Each message
/// starts with `nstat_msg_hdr`, whose `length` covers the whole message; the next message starts
/// exactly `length` bytes later (the kernel appends without padding). Unknown message types and
/// unknown trailing bytes inside a message (newer kernels, extension items) are skipped.
public struct NStatDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// Stream mode: decodes every complete message in `pending + bytes` and keeps an incomplete
    /// tail for the next call. A header with a length shorter than the header itself cannot be
    /// framed past, so the remaining bytes are discarded.
    public mutating func decode(_ bytes: some Sequence<UInt8>) -> [NStatEvent] {
        pending.append(contentsOf: bytes)
        let (events, consumed) = Self.decodeMessages(in: pending)
        pending.removeFirst(min(consumed, pending.count))
        return events
    }

    /// Bytes of an incomplete message carried over to the next `decode`.
    public var pendingByteCount: Int { pending.count }

    public mutating func reset() {
        pending.removeAll()
    }

    /// Datagram mode (one control-socket record): an incomplete trailing message is dropped.
    public static func events(inRecord bytes: [UInt8]) -> [NStatEvent] {
        decodeMessages(in: bytes).events
    }

    /// Decodes messages from the start of `bytes`. `consumed` is where the first incomplete
    /// message begins (or `bytes.count` when the rest cannot be framed).
    static func decodeMessages(in bytes: [UInt8]) -> (events: [NStatEvent], consumed: Int) {
        var events: [NStatEvent] = []
        var offset = 0
        while bytes.count - offset >= NStat.headerSize {
            let length = Int(read(UInt16.self, bytes, offset + NStat.HeaderOffset.length) ?? 0)
            guard length >= NStat.headerSize else {
                // Corrupt framing: nothing after this point can be trusted.
                return (events, bytes.count)
            }
            guard offset + length <= bytes.count else { break }
            if let event = decodeMessage(bytes[offset..<(offset + length)]) {
                events.append(event)
            }
            offset += length
        }
        return (events, offset)
    }

    /// Decodes one complete message (`message.count` == header length). `nil` when a known
    /// message type is too short for its fields.
    static func decodeMessage(_ slice: ArraySlice<UInt8>) -> NStatEvent? {
        let message = Array(slice)
        guard let context = read(UInt64.self, message, NStat.HeaderOffset.context),
              let type = read(UInt32.self, message, NStat.HeaderOffset.type),
              let rawFlags = read(UInt16.self, message, NStat.HeaderOffset.flags)
        else { return nil }
        let flags = NStat.HeaderFlags(rawValue: rawFlags)
        typealias Offset = NStat.ResponseOffset

        switch type {
        case NStat.MessageType.success:
            return .success(context: context, flags: flags)
        case NStat.MessageType.error:
            guard let code = read(UInt32.self, message, Offset.errorCode) else { return nil }
            return .error(context: context, code: code)
        case NStat.MessageType.sourceAdded:
            guard let source = read(UInt64.self, message, Offset.sourceReference),
                  let provider = read(UInt32.self, message, Offset.addedProvider)
            else { return nil }
            return .sourceAdded(source: source, provider: provider)
        case NStat.MessageType.sourceRemoved:
            guard let source = read(UInt64.self, message, Offset.sourceReference) else { return nil }
            return .sourceRemoved(source: source, flags: flags)
        case NStat.MessageType.sourceDescription:
            guard let source = read(UInt64.self, message, Offset.sourceReference),
                  let provider = read(UInt32.self, message, Offset.descriptionProvider),
                  message.count >= Offset.descriptionData
            else { return nil }
            let descriptor = decodeDescriptor(Array(message[Offset.descriptionData...]), provider: provider)
            return .description(source: source, provider: provider, descriptor: descriptor)
        case NStat.MessageType.sourceCounts:
            guard let source = read(UInt64.self, message, Offset.sourceReference),
                  let counts = decodeCounts(message, at: Offset.countsCounts)
            else { return nil }
            return .counts(source: source, counts: counts, flags: flags)
        case NStat.MessageType.sourceUpdate, NStat.MessageType.sourceExtendedUpdate:
            guard let source = read(UInt64.self, message, Offset.sourceReference),
                  let counts = decodeCounts(message, at: Offset.updateCounts),
                  let provider = read(UInt32.self, message, Offset.updateProvider),
                  message.count >= Offset.updateData
            else { return nil }
            // Extension items of an extended update follow the descriptor and are ignored.
            let descriptor = decodeDescriptor(Array(message[Offset.updateData...]), provider: provider)
            return .update(source: source, provider: provider, counts: counts, descriptor: descriptor, flags: flags)
        default:
            return .unknown(type: type)
        }
    }

    static func decodeCounts(_ message: [UInt8], at base: Int) -> NStatCounts? {
        typealias Offset = NStat.CountsOffset
        guard message.count >= base + Offset.size else { return nil }
        func value(_ offset: Int) -> UInt64 { read(UInt64.self, message, base + offset) ?? 0 }
        return NStatCounts(
            receivedPackets: value(Offset.receivedPackets),
            receivedBytes: value(Offset.receivedBytes),
            sentPackets: value(Offset.sentPackets),
            sentBytes: value(Offset.sentBytes),
            cellularReceivedBytes: value(Offset.cellularReceivedBytes),
            cellularSentBytes: value(Offset.cellularSentBytes),
            wifiReceivedBytes: value(Offset.wifiReceivedBytes),
            wifiSentBytes: value(Offset.wifiSentBytes),
            wiredReceivedBytes: value(Offset.wiredReceivedBytes),
            wiredSentBytes: value(Offset.wiredSentBytes)
        )
    }

    /// Decodes a TCP/QUIC or UDP descriptor. Descriptors longer than the known layout (a newer
    /// kernel appending fields) are accepted; shorter ones, unknown providers and addresses
    /// whose `sa_len`/`sa_family` are not a valid `sockaddr_in`/`sockaddr_in6` (a sign that the
    /// layout moved) yield `nil` rather than values read from the wrong bytes.
    static func decodeDescriptor(_ data: [UInt8], provider rawProvider: UInt32) -> NStatDescriptor? {
        guard let provider = NStat.Provider(rawValue: rawProvider), let kind = provider.descriptorKind else { return nil }
        switch kind {
        case .tcp:
            typealias Offset = NStat.TCPDescriptorOffset
            guard data.count >= Offset.minimumSize,
                  let local = decodeSocketAddress(data, at: Offset.local),
                  let remote = decodeSocketAddress(data, at: Offset.remote)
            else { return nil }
            let state = read(UInt32.self, data, Offset.state) ?? 0
            return NStatDescriptor(
                provider: provider,
                local: local.address,
                remote: remote.address,
                interfaceIndex: read(UInt32.self, data, Offset.interfaceIndex) ?? 0,
                // QUIC reuses the TCP descriptor; its `state` is not a TCP state.
                tcpState: provider == .quicUserland ? nil : state,
                pid: Int32(bitPattern: read(UInt32.self, data, Offset.pid) ?? 0),
                effectivePID: Int32(bitPattern: read(UInt32.self, data, Offset.effectivePID) ?? 0),
                processName: cString(data, at: Offset.processName, capacity: Offset.processNameLength),
                uniquePID: read(UInt64.self, data, Offset.uniquePID) ?? 0,
                startTimestamp: read(UInt64.self, data, Offset.startTimestamp) ?? 0
            )
        case .udp:
            typealias Offset = NStat.UDPDescriptorOffset
            guard data.count >= Offset.minimumSize,
                  let local = decodeSocketAddress(data, at: Offset.local),
                  let remote = decodeSocketAddress(data, at: Offset.remote)
            else { return nil }
            return NStatDescriptor(
                provider: provider,
                local: local.address,
                remote: remote.address,
                interfaceIndex: read(UInt32.self, data, Offset.interfaceIndex) ?? 0,
                tcpState: nil,
                pid: Int32(bitPattern: read(UInt32.self, data, Offset.pid) ?? 0),
                effectivePID: Int32(bitPattern: read(UInt32.self, data, Offset.effectivePID) ?? 0),
                processName: cString(data, at: Offset.processName, capacity: Offset.processNameLength),
                uniquePID: read(UInt64.self, data, Offset.uniquePID) ?? 0,
                startTimestamp: read(UInt64.self, data, Offset.startTimestamp) ?? 0
            )
        }
    }

    /// Wrapper so "valid but empty" (an all-zero union: no address yet) differs from "invalid".
    struct DecodedAddress {
        var address: NStatSocketAddress?
    }

    /// The 28-byte union at `offset`. All zero → no address (e.g. a socket that was never
    /// bound). A family other than `AF_INET`/`AF_INET6`, or an `sa_len` that does not match it,
    /// → `nil` (invalid).
    static func decodeSocketAddress(_ data: [UInt8], at offset: Int) -> DecodedAddress? {
        typealias Offset = NStat.SocketAddressOffset
        guard data.count >= offset + Offset.unionSize else { return nil }
        let union = data[offset..<(offset + Offset.unionSize)]
        if union.allSatisfy({ $0 == 0 }) { return DecodedAddress(address: nil) }
        let length = data[offset + Offset.length]
        let family = data[offset + Offset.family]
        let port = UInt16(data[offset + Offset.port]) << 8 | UInt16(data[offset + Offset.port + 1])
        switch family {
        case NStat.addressFamilyIPv4:
            // sizeof(struct sockaddr_in) = 16. Some kernel paths leave sa_len 0.
            guard length == 16 || length == 0 else { return nil }
            let start = offset + Offset.ipv4Address
            return DecodedAddress(address: NStatSocketAddress(family: .v4, bytes: Array(data[start..<(start + 4)]), port: port))
        case NStat.addressFamilyIPv6:
            // sizeof(struct sockaddr_in6) = 28.
            guard length == 28 || length == 0 else { return nil }
            let start = offset + Offset.ipv6Address
            let bytes = Array(data[start..<(start + 16)])
            if IPAddressText.isIPv4Mapped(bytes) {
                return DecodedAddress(address: NStatSocketAddress(family: .v4, bytes: Array(bytes[12..<16]), port: port))
            }
            return DecodedAddress(address: NStatSocketAddress(family: .v6, bytes: bytes, port: port))
        default:
            return nil
        }
    }

    static func cString(_ data: [UInt8], at offset: Int, capacity: Int) -> String? {
        guard data.count >= offset + capacity else { return nil }
        let field = data[offset..<(offset + capacity)]
        let bytes = field.prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Little-endian integer at `offset`, `nil` when out of bounds.
    static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], _ offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, bytes.count >= offset + size else { return nil }
        var value: T = 0
        for index in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        return value
    }
}

/// Numeric text for raw IP addresses, without Darwin's `inet_ntop` (the core stays
/// platform-independent).
public enum IPAddressText {
    /// 4 bytes → dotted quad, 16 bytes → RFC 5952 text (lowercase, longest run of two or more
    /// zero groups compressed to "::", the first one on a tie, IPv4-mapped as "::ffff:a.b.c.d").
    public static func format(_ bytes: [UInt8]) -> String? {
        switch bytes.count {
        case 4:
            return bytes.map(String.init).joined(separator: ".")
        case 16:
            if isIPv4Mapped(bytes) {
                return "::ffff:" + bytes[12..<16].map(String.init).joined(separator: ".")
            }
            let groups = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
            var bestStart = -1
            var bestLength = 0
            var index = 0
            while index < 8 {
                guard groups[index] == 0 else {
                    index += 1
                    continue
                }
                let start = index
                while index < 8, groups[index] == 0 { index += 1 }
                if index - start > bestLength {
                    bestStart = start
                    bestLength = index - start
                }
            }
            let hex = groups.map { String($0, radix: 16) }
            guard bestLength >= 2 else { return hex.joined(separator: ":") }
            let head = hex[0..<bestStart].joined(separator: ":")
            let tail = hex[(bestStart + bestLength)...].joined(separator: ":")
            return head + "::" + tail
        default:
            return nil
        }
    }

    /// `::ffff:0:0/96`.
    public static func isIPv4Mapped(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }
}
