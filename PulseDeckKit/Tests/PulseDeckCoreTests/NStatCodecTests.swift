import Foundation
import Testing
@testable import PulseDeckCore

/// Hand-built `ntstat.h` messages. Offsets are written out literally (not taken from
/// `NStat.*Offset`) so a wrong constant in the codec fails here.
private struct MessageBuilder {
    var bytes: [UInt8]

    init(size: Int) {
        bytes = [UInt8](repeating: 0, count: size)
    }

    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        for index in 0..<MemoryLayout<T>.size {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }

    mutating func put(_ raw: [UInt8], at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
    }

    mutating func header(context: UInt64, type: UInt32, flags: UInt16 = 0) {
        put(context, at: 0)
        put(type, at: 8)
        put(UInt16(bytes.count), at: 12)
        put(flags, at: 14)
    }

    /// `sockaddr_in` inside the 28-byte union.
    mutating func ipv4(_ address: [UInt8], port: UInt16, at offset: Int) {
        bytes[offset] = 16
        bytes[offset + 1] = 2
        bytes[offset + 2] = UInt8(port >> 8)
        bytes[offset + 3] = UInt8(port & 0xFF)
        put(address, at: offset + 4)
    }

    /// `sockaddr_in6` (28 bytes).
    mutating func ipv6(_ address: [UInt8], port: UInt16, at offset: Int) {
        bytes[offset] = 28
        bytes[offset + 1] = 30
        bytes[offset + 2] = UInt8(port >> 8)
        bytes[offset + 3] = UInt8(port & 0xFF)
        put(address, at: offset + 8)
    }

    mutating func name(_ text: String, at offset: Int) {
        put(Array(text.utf8), at: offset)
    }
}

/// `nstat_msg_src_update` (152-byte header) + `nstat_tcp_descriptor` (344 bytes).
private func tcpUpdate(source: UInt64, provider: UInt32 = 2, rxBytes: UInt64, txBytes: UInt64, flags: UInt16 = 0, context: UInt64 = 0, descriptorSize: Int = 344) -> [UInt8] {
    var message = MessageBuilder(size: 152 + max(descriptorSize, 344))
    message.put(source, at: 16)
    message.put(UInt64(7), at: 32)   // rxpackets
    message.put(rxBytes, at: 40)
    message.put(UInt64(5), at: 48)   // txpackets
    message.put(txBytes, at: 56)
    message.put(UInt64(111), at: 32 + 48) // wifi rx
    message.put(provider, at: 144)
    let base = 152
    message.put(UInt64(0xABCD), at: base + 0)       // upid
    message.put(UInt64(123_456_789), at: base + 16) // start_timestamp
    message.put(UInt32(4), at: base + 72)           // ifindex
    message.put(UInt32(4), at: base + 76)           // ESTABLISHED
    message.put(UInt32(321), at: base + 116)        // pid
    message.put(UInt32(654), at: base + 120)        // epid
    message.ipv4([192, 168, 1, 20], port: 52_000, at: base + 124)
    message.ipv4([93, 184, 216, 34], port: 443, at: base + 152)
    message.name("cubic", at: base + 180)
    message.name("Safari", at: base + 196)
    // Shorter (older or broken) or longer (newer) descriptors.
    message.bytes = Array(message.bytes.prefix(152 + descriptorSize))
    message.bytes += [UInt8](repeating: 0, count: 152 + descriptorSize - message.bytes.count)
    message.header(context: context, type: 10006, flags: flags)
    return message.bytes
}

/// `nstat_msg_src_update` + `nstat_udp_descriptor` (280 bytes), IPv6.
private func udpUpdate(source: UInt64, provider: UInt32 = 4, rxBytes: UInt64, txBytes: UInt64) -> [UInt8] {
    var message = MessageBuilder(size: 152 + 280)
    message.header(context: 0, type: 10006)
    message.put(source, at: 16)
    message.put(rxBytes, at: 40)
    message.put(txBytes, at: 56)
    message.put(provider, at: 144)
    let base = 152
    message.put(UInt64(99), at: base + 16)  // start_timestamp
    message.ipv6([0xFE, 0x80] + [UInt8](repeating: 0, count: 13) + [1], port: 5353, at: base + 56)
    message.ipv6([0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x68, 0x10, 0x84, 0xE5], port: 53, at: base + 84)
    message.put(UInt32(7), at: base + 112)   // ifindex
    message.put(UInt32(88), at: base + 128)  // pid
    message.name("mDNSResponder", at: base + 132)
    message.put(UInt32(89), at: base + 196)  // epid
    return message.bytes
}

private func success(context: UInt64, flags: UInt16 = 0) -> [UInt8] {
    var message = MessageBuilder(size: 16)
    message.header(context: context, type: 0, flags: flags)
    return message.bytes
}

private func removed(source: UInt64, flags: UInt16 = 0) -> [UInt8] {
    var message = MessageBuilder(size: 24)
    message.header(context: 0, type: 10002, flags: flags)
    message.put(source, at: 16)
    return message.bytes
}

private var noConversion: NStatFlowTable.Conversion { NStatFlowTable.Conversion(interfaceName: { $0 == 4 ? "en0" : nil }, startDate: { _ in nil }) }

@Suite("Network statistics codec")
struct NStatCodecTests {
    @Test func encodesAddAllSources() {
        let message = NStat.addAllSources(provider: .udpUserland, context: 0x1122)
        #expect(message.count == 56)
        #expect(Array(message[0..<8]) == [0x22, 0x11, 0, 0, 0, 0, 0, 0])
        #expect(Array(message[8..<12]) == [0xEA, 0x03, 0, 0])   // 1002
        #expect(Array(message[12..<14]) == [56, 0])              // length
        #expect(Array(message[14..<16]) == [0, 0])
        // SUPPRESS_SRC_ADDED | USE_UPDATE_FOR_ADD = 0x0030_0000
        #expect(Array(message[16..<24]) == [0, 0, 0x30, 0, 0, 0, 0, 0])
        #expect(Array(message[24..<32]) == [UInt8](repeating: 0, count: 8)) // events
        #expect(Array(message[32..<36]) == [5, 0, 0, 0])         // provider
        #expect(Array(message[36..<56]) == [UInt8](repeating: 0, count: 20))
    }

    @Test func encodesGetUpdateForAllSourcesWithContinuation() {
        let message = NStat.getUpdate(context: 9)
        #expect(message.count == 24)
        #expect(message[0] == 9)
        #expect(Array(message[8..<12]) == [0xEF, 0x03, 0, 0])   // 1007
        #expect(Array(message[12..<14]) == [24, 0])
        #expect(Array(message[14..<16]) == [2, 0])               // CONTINUATION
        #expect(Array(message[16..<24]) == [UInt8](repeating: 0xFF, count: 8))
    }

    @Test func encodesQueryAndDescriptionRequests() {
        let query = NStat.querySource(42, context: 1, flags: [])
        #expect(Array(query[8..<12]) == [0xEC, 0x03, 0, 0])      // 1004
        #expect(query[16] == 42)
        let description = NStat.getSourceDescription(context: 1)
        #expect(Array(description[8..<12]) == [0xED, 0x03, 0, 0]) // 1005
    }

    @Test func decodesTCPUpdate() throws {
        let events = NStatDecoder.events(inRecord: tcpUpdate(source: 17, rxBytes: 5000, txBytes: 1200))
        #expect(events.count == 1)
        guard case .update(let source, let provider, let counts, let descriptor, let flags) = try #require(events.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(source == 17)
        #expect(provider == 2)
        #expect(flags == [])
        #expect(counts.receivedBytes == 5000)
        #expect(counts.sentBytes == 1200)
        #expect(counts.receivedPackets == 7)
        #expect(counts.sentPackets == 5)
        #expect(counts.wifiReceivedBytes == 111)
        let tcp = try #require(descriptor)
        #expect(tcp.provider == .tcpKernel)
        #expect(tcp.local?.address == "192.168.1.20")
        #expect(tcp.local?.port == 52_000)
        #expect(tcp.remote?.address == "93.184.216.34")
        #expect(tcp.remote?.port == 443)
        #expect(tcp.remote?.family == .v4)
        #expect(tcp.interfaceIndex == 4)
        #expect(tcp.tcpState == 4)
        #expect(tcp.pid == 321)
        #expect(tcp.effectivePID == 654)
        #expect(tcp.processName == "Safari")
        #expect(tcp.uniquePID == 0xABCD)
        #expect(tcp.startTimestamp == 123_456_789)
    }

    @Test func decodesUDPUpdateWithIPv6() throws {
        let events = NStatDecoder.events(inRecord: udpUpdate(source: 3, rxBytes: 80, txBytes: 40))
        guard case .update(_, _, let counts, let descriptor, _) = try #require(events.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(counts.receivedBytes == 80)
        let udp = try #require(descriptor)
        #expect(udp.provider == .udpKernel)
        #expect(udp.tcpState == nil)
        #expect(udp.local?.address == "fe80::1")
        #expect(udp.local?.port == 5353)
        #expect(udp.remote?.address == "2606:4700::6810:84e5")
        #expect(udp.remote?.port == 53)
        #expect(udp.interfaceIndex == 7)
        #expect(udp.pid == 88)
        #expect(udp.effectivePID == 89)
        #expect(udp.processName == "mDNSResponder")
        #expect(udp.startTimestamp == 99)
    }

    @Test func quicUsesTCPDescriptorWithoutTCPState() throws {
        let events = NStatDecoder.events(inRecord: tcpUpdate(source: 1, provider: 8, rxBytes: 1, txBytes: 1))
        guard case .update(_, _, _, let descriptor, _) = try #require(events.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(descriptor?.provider == .quicUserland)
        #expect(descriptor?.tcpState == nil)
        #expect(NStat.Provider.quicUserland.transport == .udp)
    }

    @Test func framesBackToBackMessages() {
        let record = tcpUpdate(source: 1, rxBytes: 1, txBytes: 2) + udpUpdate(source: 2, rxBytes: 3, txBytes: 4)
            + removed(source: 9, flags: 0x8) + success(context: 77, flags: 2)
        let events = NStatDecoder.events(inRecord: record)
        #expect(events.count == 4)
        #expect(events[2] == .sourceRemoved(source: 9, flags: .closedAfterDrop))
        #expect(events[3] == .success(context: 77, flags: .continuation))
    }

    @Test func streamDecoderKeepsIncompleteTail() {
        let full = success(context: 1) + removed(source: 5)
        var decoder = NStatDecoder()
        let first = decoder.decode(full.prefix(20))
        #expect(first == [.success(context: 1, flags: [])])
        #expect(decoder.pendingByteCount == 4)
        let second = decoder.decode(full.dropFirst(20))
        #expect(second == [.sourceRemoved(source: 5, flags: [])])
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func corruptLengthStopsFraming() {
        var bad = MessageBuilder(size: 16)
        bad.put(UInt32(0), at: 8)
        bad.put(UInt16(4), at: 12) // shorter than the header
        var decoder = NStatDecoder()
        let events = decoder.decode(bad.bytes + success(context: 1))
        #expect(events.isEmpty)
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func decodesErrorAddedCountsAndUnknown() {
        var error = MessageBuilder(size: 24 + 24) // the kernel appends the failed request
        error.header(context: 5, type: 1)
        error.put(UInt32(1), at: 16)   // EPERM
        var added = MessageBuilder(size: 32)
        added.header(context: 0, type: 10001)
        added.put(UInt64(12), at: 16)
        added.put(UInt32(3), at: 24)
        var counts = MessageBuilder(size: 144)
        counts.header(context: 0, type: 10004)
        counts.put(UInt64(12), at: 16)
        counts.put(UInt64(1000), at: 40)
        counts.put(UInt64(2000), at: 56)
        var sysinfo = MessageBuilder(size: 40)
        sysinfo.header(context: 0, type: 10005)
        let events = NStatDecoder.events(inRecord: error.bytes + added.bytes + counts.bytes + sysinfo.bytes)
        #expect(events.count == 4)
        #expect(events[0] == .error(context: 5, code: 1))
        #expect(events[1] == .sourceAdded(source: 12, provider: 3))
        guard case .counts(12, let decoded, _) = events[2] else {
            Issue.record("expected counts")
            return
        }
        #expect(decoded.receivedBytes == 1000)
        #expect(decoded.sentBytes == 2000)
        #expect(events[3] == .unknown(type: 10005))
    }

    @Test func toleratesLongerDescriptorsAndRejectsShortOnes() throws {
        let longer = NStatDecoder.events(inRecord: tcpUpdate(source: 1, rxBytes: 1, txBytes: 1, descriptorSize: 400))
        guard case .update(_, _, _, let descriptor, _) = try #require(longer.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(descriptor?.processName == "Safari")

        // macOS 13's 336-byte descriptor still has every field PulseDeck reads.
        let older = NStatDecoder.events(inRecord: tcpUpdate(source: 1, rxBytes: 1, txBytes: 1, descriptorSize: 336))
        guard case .update(_, _, _, let olderDescriptor, _) = try #require(older.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(olderDescriptor?.pid == 321)

        let short = NStatDecoder.events(inRecord: tcpUpdate(source: 1, rxBytes: 1, txBytes: 1, descriptorSize: 200))
        guard case .update(_, _, let counts, let shortDescriptor, _) = try #require(short.first) else {
            Issue.record("expected an update")
            return
        }
        #expect(counts.receivedBytes == 1)
        #expect(shortDescriptor == nil)
    }

    @Test func rejectsInvalidAddressFamily() throws {
        var message = tcpUpdate(source: 1, rxBytes: 1, txBytes: 1)
        message[152 + 152 + 1] = 99 // remote sa_family
        guard case .update(_, _, _, let descriptor, _) = try #require(NStatDecoder.events(inRecord: message).first) else {
            Issue.record("expected an update")
            return
        }
        #expect(descriptor == nil)
    }

    @Test func mapsIPv4MappedIPv6ToIPv4() throws {
        let mapped = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 1, 1, 1, 1]
        var data = [UInt8](repeating: 0, count: 28)
        data[0] = 28
        data[1] = 30
        data[3] = 53
        data.replaceSubrange(8..<24, with: mapped)
        let decoded = try #require(NStatDecoder.decodeSocketAddress(data, at: 0)?.address)
        #expect(decoded.family == .v4)
        #expect(decoded.address == "1.1.1.1")
        #expect(decoded.port == 53)
    }

    @Test func formatsIPv6PerRFC5952() {
        func bytes(_ groups: [UInt16]) -> [UInt8] { groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        #expect(IPAddressText.format(bytes([0, 0, 0, 0, 0, 0, 0, 1])) == "::1")
        #expect(IPAddressText.format(bytes([0, 0, 0, 0, 0, 0, 0, 0])) == "::")
        #expect(IPAddressText.format(bytes([0x2001, 0xdb8, 0, 0, 1, 0, 0, 1])) == "2001:db8::1:0:0:1")
        #expect(IPAddressText.format(bytes([0x2001, 0xdb8, 0, 1, 1, 1, 1, 1])) == "2001:db8:0:1:1:1:1:1")
        #expect(IPAddressText.format(bytes([0x2001, 0, 0, 1, 0, 0, 0, 1])) == "2001:0:0:1::1")
        #expect(IPAddressText.format([10, 0, 0, 1]) == "10.0.0.1")
        #expect(IPAddressText.format([1, 2, 3]) == nil)
    }

    @Test func namesTCPStates() {
        #expect(NStat.tcpStateName(4) == "ESTABLISHED")
        #expect(NStat.tcpStateName(10) == "TIME_WAIT")
        #expect(NStat.tcpStateName(11) == nil)
    }
}

@Suite("Network statistics flow table")
struct NStatFlowTableTests {
    private func apply(_ record: [UInt8], to table: inout NStatFlowTable) {
        for event in NStatDecoder.events(inRecord: record) {
            table.apply(event, conversion: noConversion)
        }
    }

    @Test func mapsUpdatesToFlows() throws {
        var table = NStatFlowTable(generation: 3)
        apply(tcpUpdate(source: 17, rxBytes: 5000, txBytes: 1200), to: &table)
        let snapshot = table.snapshot(conversion: noConversion)
        #expect(snapshot.source == .networkStatistics)
        let flow = try #require(snapshot.flows.first)
        #expect(flow.id == (3 << 40) | 17)
        #expect(flow.transport == .tcp)
        #expect(flow.family == .v4)
        #expect(flow.remote == FlowEndpoint(address: "93.184.216.34", port: 443))
        #expect(flow.local == FlowEndpoint(address: "192.168.1.20", port: 52_000))
        #expect(flow.tcpState == "ESTABLISHED")
        #expect(flow.processName == "Safari")
        #expect(flow.processID == 321)
        #expect(flow.interfaceName == "en0")
        #expect(flow.bytesReceived == .available(5000))
        #expect(flow.bytesSent == .available(1200))
        #expect(snapshot.closed.isEmpty)
    }

    @Test func closingUpdateThenRemovalBecomesClosedFlow() throws {
        var table = NStatFlowTable(generation: 1)
        apply(tcpUpdate(source: 1, rxBytes: 100, txBytes: 10), to: &table)
        _ = table.snapshot(conversion: noConversion)
        apply(tcpUpdate(source: 1, rxBytes: 150, txBytes: 20, flags: 0x4) + removed(source: 1), to: &table)
        let snapshot = table.snapshot(conversion: noConversion)
        #expect(snapshot.flows.isEmpty)
        let closed = try #require(snapshot.closed.first)
        #expect(closed.bytesReceived == .available(150))
        // Collected once.
        #expect(table.snapshot(conversion: noConversion).closed.isEmpty)
    }

    @Test func completePollRetiresUnreportedSources() {
        var table = NStatFlowTable(generation: 1)
        table.beginPoll()
        apply(tcpUpdate(source: 1, rxBytes: 1, txBytes: 1) + udpUpdate(source: 2, rxBytes: 1, txBytes: 1), to: &table)
        table.endPoll(complete: true, conversion: noConversion)
        #expect(table.sourceCount == 2)

        // Source 2 is not reported by an interrupted poll: kept.
        table.beginPoll()
        apply(tcpUpdate(source: 1, rxBytes: 2, txBytes: 1), to: &table)
        table.endPoll(complete: false, conversion: noConversion)
        #expect(table.sourceCount == 2)

        // …but a complete poll without it means its removal was lost.
        table.beginPoll()
        apply(tcpUpdate(source: 1, rxBytes: 3, txBytes: 1), to: &table)
        table.endPoll(complete: true, conversion: noConversion)
        #expect(table.sourceCount == 1)
        let snapshot = table.snapshot(conversion: noConversion)
        #expect(snapshot.flows.count == 1)
        #expect(snapshot.closed.count == 1)
    }

    @Test func unconnectedSocketHasUnspecifiedRemote() throws {
        var message = udpUpdate(source: 4, rxBytes: 0, txBytes: 0)
        message.replaceSubrange((152 + 84)..<(152 + 112), with: [UInt8](repeating: 0, count: 28))
        var table = NStatFlowTable(generation: 1)
        apply(message, to: &table)
        let flow = try #require(table.snapshot(conversion: noConversion).flows.first)
        #expect(flow.remote == FlowEndpoint(address: "::", port: 0))
        #expect(flow.family == .v6)
    }

    @Test func limitsFlowCountKeepingLargest() {
        var table = NStatFlowTable(generation: 1)
        for source in 1...5 {
            apply(tcpUpdate(source: UInt64(source), rxBytes: UInt64(source * 100), txBytes: 0), to: &table)
        }
        let snapshot = table.snapshot(limit: 2, conversion: noConversion)
        #expect(snapshot.flows.map { $0.bytesReceived.value } == [500, 400])
    }

    @Test func flowIDsSurviveReconnect() throws {
        var first = NStatFlowTable(generation: 1)
        apply(tcpUpdate(source: 17, rxBytes: 100, txBytes: 1) + udpUpdate(source: 18, rxBytes: 1, txBytes: 1), to: &first)
        let before = first.snapshot(conversion: noConversion).flows.sorted { $0.id < $1.id }

        // New connection: the kernel numbers sources from 1 again.
        var second = NStatFlowTable(generation: 2, inheriting: first.identities)
        second.beginPoll()
        apply(tcpUpdate(source: 1, rxBytes: 150, txBytes: 1) + udpUpdate(source: 2, rxBytes: 1, txBytes: 1)
              + tcpUpdate(source: 3, provider: 3, rxBytes: 9, txBytes: 9), to: &second)
        second.endPoll(complete: true, conversion: noConversion)
        let after = second.snapshot(conversion: noConversion).flows
        #expect(Set(after.map(\.id)).isSuperset(of: before.map(\.id)))
        // A different provider is a different flow.
        #expect(after.count == 3)
        #expect(after.contains { $0.id == second.flowID(forSource: 3) })
        // Unclaimed inherited IDs are dropped after the first complete poll.
        #expect(second.identities.count == 3)
    }

    @Test func socketTableIDsAreStableAndDistinct() {
        let local = FlowEndpoint(address: "10.0.0.2", port: 50_000)
        let remote = FlowEndpoint(address: "1.1.1.1", port: 443)
        let first = SocketTableFlowID.make(transport: .tcp, local: local, remote: remote, processID: 10)
        #expect(first == SocketTableFlowID.make(transport: .tcp, local: local, remote: remote, processID: 10))
        #expect(first != SocketTableFlowID.make(transport: .udp, local: local, remote: remote, processID: 10))
        #expect(first != SocketTableFlowID.make(transport: .tcp, local: local, remote: remote, processID: 11))
        #expect(first & (1 << 63) != 0)
        #expect(NStatFlowTable(generation: 0x7F_FFFF).flowID(forSource: 0xFF_FFFF_FFFF) & (1 << 63) == 0)
    }
}
