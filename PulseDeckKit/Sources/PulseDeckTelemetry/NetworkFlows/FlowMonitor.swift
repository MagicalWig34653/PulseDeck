#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// Layer 3/4 flows of this Mac (remote address, transport, ports, process) with cumulative byte
/// counters, for the Traffic section.
///
/// **Primary source — undocumented (TECHNICAL_LIMITATIONS L‑14):** the kernel's network
/// statistics control `com.apple.network.statistics`, which `nettop` and Activity Monitor read
/// through the private NetworkStatistics framework. PulseDeck does not load that framework; it
/// talks to the kernel control directly with public socket calls (`socket(PF_SYSTEM,
/// SOCK_DGRAM, SYSPROTO_CONTROL)`, `ioctl(CTLIOCGINFO)`, `connect`). The message formats are
/// only declared in the `PRIVATE` part of xnu's `ntstat.h`; encoding and decoding live in
/// `PulseDeckCore` (`NStat`, `NStatDecoder`, `NStatFlowTable`) where they are unit tested. No
/// privilege or entitlement is needed on macOS (`net.statistics_privcheck` is 0 there).
///
/// Protocol use:
/// - On connect: `ADD_ALL_SRCS` for TCP and UDP (kernel and userland/Skywalk) and QUIC sources,
///   with `SUPPRESS_SRC_ADDED` so subscribing to hundreds of existing sockets does not flood the
///   receive buffer (the kernel drops sources whose `SRC_ADDED` cannot be queued).
/// - Each tick: `GET_UPDATE` for all sources with the continuation flag. The kernel answers in
///   fragments of up to 100 `SRC_UPDATE`s (counts + descriptor), each ending in `SUCCESS`
///   flagged "continuation" until the last one. The kernel handles a request inside `send`, so
///   its answer is queued when `send` returns; reads are non-blocking with a deadline.
/// - Between ticks the kernel queues a final `CLOSING` update and `SRC_REMOVED` for every flow
///   that ends; they become `closed` flows of the next snapshot.
/// - The socket stays open across ticks (source references are per connection). Flow IDs
///   survive a reconnect (`NStatFlowTable` identities).
///
/// **Fallback — public, no byte counters:** if the control cannot be opened, refuses the
/// subscription, or a complete poll after connecting reports nothing, flows come from the
/// per-process socket table (libproc `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO`), source
/// `.socketTable`, with byte counters `.unavailable(.noPublicAPI)`. Other users' processes are
/// skipped (`EPERM`). The control is retried after `retryInterval`.
///
/// Demand-driven: sampled only while the Traffic section is visible or background recording is
/// on. A tick spends at most `tickBudget` talking to the kernel.
public actor FlowMonitor: TelemetryProvider {
    // MARK: Constants not reliably imported into Swift

    /// `PF_SYSTEM` / `AF_SYSTEM` (`sys/socket.h`).
    private static let systemProtocolFamily: Int32 = 32
    /// `SYSPROTO_CONTROL` (`sys/sys_domain.h`).
    private static let systemProtocolControl: Int32 = 2
    /// `AF_SYS_CONTROL` (`sys/sys_domain.h`), `sockaddr_ctl.ss_sysaddr`.
    private static let systemAddressControl: UInt16 = 2
    /// `CTLIOCGINFO` = `_IOWR('N', 3, struct ctl_info)` with `sizeof(struct ctl_info)` = 100
    /// (`u_int32_t ctl_id; char ctl_name[96]`), `sys/kern_control.h`.
    private static let controlInfoRequest: UInt = 0xC064_4E03
    private static let controlInfoSize = 100
    private static let controlNameCapacity = 96
    /// `sizeof(struct sockaddr_ctl)`: `sc_len`, `sc_family`, `ss_sysaddr` (u16), `sc_id`,
    /// `sc_unit`, `sc_reserved[5]` (u32 each).
    private static let controlAddressSize = 32

    // MARK: Tuning

    /// Longest time one tick waits for the kernel (the actor must not block the engine).
    private static let tickBudget: Duration = .milliseconds(150)
    /// Room for a whole poll fragment plus the closing updates of flows that end between ticks
    /// (~500 bytes each); the kernel caps it at `kern.ipc.maxsockbuf`.
    private static let receiveBufferSize: Int32 = 4 * 1024 * 1024
    /// One control-socket record: the largest message is `MAX_NSTAT_MSG_HDR_LENGTH` (65532).
    private static let recordBufferSize = 64 * 1024
    /// How long to stay on the socket-table fallback before trying the control again.
    private static let retryInterval: Duration = .seconds(60)
    /// Upper bound on flows per snapshot (a busy server can have tens of thousands of sockets).
    private static let maximumFlows = 20_000

    private enum Answer {
        case success(continuation: Bool)
        case refused(code: UInt32)
        case timedOut
        case failed
    }

    private var socketDescriptor: Int32 = -1
    private var table = NStatFlowTable(generation: 0)
    private var generation: UInt64 = 0
    private var context: UInt64 = 0
    /// The first complete poll after connecting has not happened yet.
    private var awaitsFirstPoll = false
    private var retryAt: ContinuousClock.Instant?
    private var record = [UInt8](repeating: 0, count: FlowMonitor.recordBufferSize)
    private let timebase: (numerator: UInt32, denominator: UInt32)?
    private var socketTable = SocketTableReader()

    public init() {
        var info = mach_timebase_info_data_t()
        if mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 {
            timebase = (numerator: info.numer, denominator: info.denom)
        } else {
            timebase = nil
        }
    }

    deinit {
        if socketDescriptor >= 0 {
            close(socketDescriptor)
        }
    }

    public func capability() -> TelemetryCapability {
        if socketDescriptor >= 0 || openControl(deadline: ContinuousClock.now.advanced(by: Self.tickBudget)) { return .supported }
        return socketTable.isUsable() ? .supported : .unsupported(.noPublicAPI)
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<NetworkFlowsSnapshot> {
        let deadline = ContinuousClock.now.advanced(by: Self.tickBudget)
        if let snapshot = sampleNetworkStatistics(deadline: deadline) {
            return .available(snapshot)
        }
        // The fallback gets its own budget: on the rare tick where the control failed, the
        // actor is busy for up to twice `tickBudget`.
        let fallbackDeadline = ContinuousClock.now.advanced(by: Self.tickBudget)
        if let snapshot = socketTable.snapshot(deadline: fallbackDeadline, limit: Self.maximumFlows) {
            return .available(snapshot)
        }
        return .unavailable(.transientFailure("neither network statistics nor the socket table could be read"))
    }

    /// After sleep: start over with a fresh control connection (flow IDs are carried over, so
    /// the ledger does not count open flows twice).
    public func invalidateBaselines() {
        closeControl()
        retryAt = nil
    }

    // MARK: - Network statistics control

    private func sampleNetworkStatistics(deadline: ContinuousClock.Instant) -> NetworkFlowsSnapshot? {
        if socketDescriptor < 0 {
            if let retryAt, ContinuousClock.now < retryAt { return nil }
            guard openControl(deadline: deadline) else {
                retryAt = ContinuousClock.now.advanced(by: Self.retryInterval)
                return nil
            }
        }
        let conversion = makeConversion()
        context &+= 1
        let pollContext = context
        let request = NStat.getUpdate(context: pollContext)
        table.beginPoll()
        var complete = false
        polling: while true {
            guard sendRequest(request) else {
                fail()
                return nil
            }
            switch receive(until: pollContext, deadline: deadline, conversion: conversion) {
            case .success(let continuation):
                if !continuation {
                    complete = true
                    break polling
                }
            case .timedOut, .refused:
                // Keep what arrived; the next tick polls again with a new context (the kernel
                // abandons the unfinished one with an EAGAIN error we ignore). A refused poll
                // (ENOBUFS while the receive buffer is full) is transient the same way.
                break polling
            case .failed:
                fail()
                return nil
            }
        }
        table.endPoll(complete: complete, conversion: conversion)
        if awaitsFirstPoll, complete {
            awaitsFirstPoll = false
            // Every Mac has open sockets (mDNSResponder alone holds several), so a complete
            // first poll with no sources means the control answers but is not delivering.
            if table.sourceCount == 0 {
                fail()
                return nil
            }
        }
        return table.snapshot(limit: Self.maximumFlows, conversion: conversion)
    }

    /// Opens, connects and subscribes. `false` (socket closed) on any failure.
    private func openControl(deadline: ContinuousClock.Instant) -> Bool {
        let descriptor = socket(Self.systemProtocolFamily, SOCK_DGRAM, Self.systemProtocolControl)
        guard descriptor >= 0 else { return false }
        var bufferSize = Self.receiveBufferSize
        // Best effort: a smaller buffer only means more lost closing updates.
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        guard let controlID = Self.controlID(descriptor: descriptor), Self.connect(descriptor: descriptor, controlID: controlID) else {
            close(descriptor)
            return false
        }
        socketDescriptor = descriptor
        generation &+= 1
        table = NStatFlowTable(generation: generation, inheriting: table.identities)
        awaitsFirstPoll = true

        let conversion = makeConversion()
        var subscribed = 0
        subscribing: for provider in NStat.Provider.flowProviders {
            context &+= 1
            guard sendRequest(NStat.addAllSources(provider: provider, context: context)) else { break }
            switch receive(until: context, deadline: deadline, conversion: conversion) {
            case .success:
                subscribed += 1
            case .refused:
                // e.g. a provider an older kernel does not know (ENOENT): use the others.
                continue subscribing
            case .timedOut, .failed:
                break subscribing
            }
        }
        guard subscribed > 0 else {
            closeControl()
            return false
        }
        return true
    }

    /// `ioctl(CTLIOCGINFO)`: the dynamic ID of the control named `NStat.controlName`.
    private static func controlID(descriptor: Int32) -> UInt32? {
        var info = [UInt8](repeating: 0, count: controlInfoSize)
        let name = Array(NStat.controlName.utf8)
        guard name.count < controlNameCapacity else { return nil }
        // ctl_name starts after the 4-byte ctl_id.
        info.replaceSubrange(4..<(4 + name.count), with: name)
        let status = info.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return ioctl(descriptor, controlInfoRequest, base)
        }
        guard status == 0 else { return nil }
        return info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    }

    /// `connect` with a `sockaddr_ctl` (unit 0: the kernel assigns one).
    private static func connect(descriptor: Int32, controlID: UInt32) -> Bool {
        var address = [UInt8](repeating: 0, count: controlAddressSize)
        address[0] = UInt8(controlAddressSize)                 // sc_len
        address[1] = UInt8(systemProtocolFamily)               // sc_family = AF_SYSTEM
        withUnsafeBytes(of: systemAddressControl) { address.replaceSubrange(2..<4, with: $0) }  // ss_sysaddr
        withUnsafeBytes(of: controlID) { address.replaceSubrange(4..<8, with: $0) }             // sc_id
        let status = address.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.connect(descriptor, base.assumingMemoryBound(to: sockaddr.self), socklen_t(controlAddressSize))
        }
        return status == 0
    }

    private func sendRequest(_ request: [UInt8]) -> Bool {
        let descriptor = socketDescriptor
        guard descriptor >= 0 else { return false }
        while true {
            let sent = request.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            if sent == request.count { return true }
            if sent < 0, errno == EINTR { continue }
            return false
        }
    }

    /// Reads records until the `SUCCESS` or `ERROR` for `expected`, applying every other message
    /// (updates, removals) to the table.
    private func receive(until expected: UInt64, deadline: ContinuousClock.Instant, conversion: NStatFlowTable.Conversion) -> Answer {
        let controlSocket = socketDescriptor
        while true {
            let count = record.withUnsafeMutableBytes { buffer in
                recv(controlSocket, buffer.baseAddress, buffer.count, MSG_DONTWAIT)
            }
            if count > 0 {
                var answer: Answer?
                for event in NStatDecoder.events(inRecord: Array(record[0..<count])) {
                    switch event {
                    case .success(let context, let flags) where context == expected:
                        answer = .success(continuation: flags.contains(.continuation))
                    case .error(let context, let code) where context == expected:
                        answer = .refused(code: code)
                    default:
                        table.apply(event, conversion: conversion)
                    }
                }
                if let answer { return answer }
                continue
            }
            if count == 0 { return .failed }
            let error = errno
            if error == EINTR { continue }
            guard error == EAGAIN || error == EWOULDBLOCK else { return .failed }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .timedOut }
            let milliseconds = Int32(clamping: max(1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            var descriptor = pollfd(fd: controlSocket, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, milliseconds) == 0 { return .timedOut }
        }
    }

    private func fail() {
        closeControl()
        retryAt = ContinuousClock.now.advanced(by: Self.retryInterval)
    }

    private func closeControl() {
        if socketDescriptor >= 0 {
            close(socketDescriptor)
        }
        socketDescriptor = -1
        awaitsFirstPoll = false
    }

    /// Interface names (cached for this tick: `if_indextoname` walks the interface list) and
    /// socket start dates (`mach_continuous_time` ticks → wall clock).
    private func makeConversion() -> NStatFlowTable.Conversion {
        var names: [UInt32: String] = [:]
        var missing: Set<UInt32> = []
        let now = Date()
        let nowTicks = mach_continuous_time()
        let timebase = self.timebase
        return NStatFlowTable.Conversion(
            interfaceName: { index in
                if let name = names[index] { return name }
                if missing.contains(index) { return nil }
                var buffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(index, &buffer) != nil else {
                    missing.insert(index)
                    return nil
                }
                let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                names[index] = name
                return name
            },
            startDate: { ticks in
                guard let timebase, ticks > 0, ticks <= nowTicks else { return nil }
                let nanoseconds = Double(nowTicks - ticks) * Double(timebase.numerator) / Double(timebase.denominator)
                return now.addingTimeInterval(-nanoseconds / 1_000_000_000)
            }
        )
    }
}

/// The libproc socket table: every TCP/UDP socket of the processes this user may inspect, with
/// addresses, ports and TCP state but no byte counters. When the deadline hits, the list holds
/// the processes read so far (without counters nothing can be mis-credited; a flow missing from
/// one sample only lowers the active-flow count).
private struct SocketTableReader {
    /// `PROC_PIDLISTFDS`, `PROC_PIDFDSOCKETINFO`, `PROX_FDTYPE_SOCKET` (`sys/proc_info.h`).
    private static let listFileDescriptors: Int32 = 1
    private static let fileDescriptorSocketInfo: Int32 = 3
    private static let socketFileType: UInt32 = 2
    /// `SOCKINFO_IN`, `SOCKINFO_TCP` (anonymous enum in `sys/proc_info.h`).
    private static let socketKindInternet: Int32 = 1
    private static let socketKindTCP: Int32 = 2
    /// `INI_IPV4`, `INI_IPV6` (`in_sockinfo.insi_vflag`).
    private static let versionIPv4: UInt8 = 0x1
    private static let versionIPv6: UInt8 = 0x2
    /// `PROC_PIDPATHINFO_MAXSIZE`-sized name buffer is more than `proc_name` needs (2×MAXCOMLEN).
    private static let nameBufferSize = 256
    /// Room for processes started between sizing and listing.
    private static let processSlack = 64

    private var pids: [Int32] = []
    private var fileDescriptors: [proc_fdinfo] = []

    func isUsable() -> Bool {
        proc_listallpids(nil, 0) > 0
    }

    mutating func snapshot(deadline: ContinuousClock.Instant, limit: Int) -> NetworkFlowsSnapshot? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        let capacity = Int(estimate) + Self.processSlack
        if pids.count < capacity {
            pids = [Int32](repeating: 0, count: capacity)
        }
        let listed = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard listed > 0 else { return nil }

        var flows: [NetworkFlow] = []
        var seen: Set<UInt64> = []
        for pid in pids.prefix(min(Int(listed), pids.count)) where pid > 0 {
            if flows.count >= limit || ContinuousClock.now >= deadline { break }
            flows.append(contentsOf: sockets(of: pid, limit: limit - flows.count).filter { seen.insert($0.id).inserted })
        }
        return NetworkFlowsSnapshot(source: .socketTable, flows: flows)
    }

    private mutating func sockets(of pid: Int32, limit: Int) -> [NetworkFlow] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Size query; fails with EPERM for other users' processes, which are skipped.
        let needed = proc_pidinfo(pid, Self.listFileDescriptors, 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / stride + 16
        if fileDescriptors.count < capacity {
            fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        }
        let filled = fileDescriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, Self.listFileDescriptors, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        let count = min(Int(filled) / stride, fileDescriptors.count)

        var name: String?
        var flows: [NetworkFlow] = []
        for index in 0..<count where fileDescriptors[index].proc_fdtype == Self.socketFileType {
            guard flows.count < limit else { break }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fileDescriptors[index].proc_fd, Self.fileDescriptorSocketInfo, &info, size) == size else { continue }
            if name == nil { name = Self.processName(of: pid) }
            if let flow = Self.flow(from: info.psi, pid: pid, processName: name) {
                flows.append(flow)
            }
        }
        return flows
    }

    private static func flow(from socket: socket_info, pid: Int32, processName: String?) -> NetworkFlow? {
        let transport: FlowTransport
        let internet: in_sockinfo
        var tcpState: String?
        switch socket.soi_kind {
        case socketKindTCP:
            transport = .tcp
            internet = socket.soi_proto.pri_tcp.tcpsi_ini
            tcpState = NStat.tcpStateName(UInt32(bitPattern: socket.soi_proto.pri_tcp.tcpsi_state))
        case socketKindInternet where socket.soi_protocol == IPPROTO_UDP:
            transport = .udp
            internet = socket.soi_proto.pri_in
        default:
            return nil
        }
        let family: IPFamily
        let localBytes: [UInt8]
        let remoteBytes: [UInt8]
        if internet.insi_vflag & versionIPv4 != 0 {
            family = .v4
            localBytes = withUnsafeBytes(of: internet.insi_laddr.ina_46.i46a_addr4.s_addr, Array.init)
            remoteBytes = withUnsafeBytes(of: internet.insi_faddr.ina_46.i46a_addr4.s_addr, Array.init)
        } else if internet.insi_vflag & versionIPv6 != 0 {
            family = .v6
            localBytes = withUnsafeBytes(of: internet.insi_laddr.ina_6, Array.init)
            remoteBytes = withUnsafeBytes(of: internet.insi_faddr.ina_6, Array.init)
        } else {
            return nil
        }
        // Ports are stored in network byte order in an `int`.
        func port(_ value: Int32) -> UInt16 {
            UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
        }
        func endpoint(_ bytes: [UInt8], port: UInt16) -> FlowEndpoint {
            // IPv4-mapped addresses of dual-stack sockets are shown as IPv4 (as the network
            // statistics decoder does).
            let address = IPAddressText.isIPv4Mapped(bytes) ? Array(bytes[12..<16]) : bytes
            return FlowEndpoint(address: IPAddressText.format(address) ?? "", port: port)
        }
        let local = endpoint(localBytes, port: port(internet.insi_lport))
        let remote = endpoint(remoteBytes, port: port(internet.insi_fport))
        let mappedFamily: IPFamily = family == .v6 && IPAddressText.isIPv4Mapped(remoteBytes) ? .v4 : family
        return NetworkFlow(
            id: SocketTableFlowID.make(transport: transport, local: local, remote: remote, processID: pid),
            family: mappedFamily,
            transport: transport,
            local: local,
            remote: remote,
            tcpState: tcpState,
            processName: processName,
            processID: pid,
            interfaceName: nil,
            bytesReceived: .unavailable(.noPublicAPI),
            bytesSent: .unavailable(.noPublicAPI),
            startedAt: nil
        )
    }

    private static func processName(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: nameBufferSize)
        let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}
#endif
