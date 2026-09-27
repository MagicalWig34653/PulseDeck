#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore
import SystemConfiguration

/// Per-interface network throughput (SPEC §16, §17).
///
/// Counters come from the routing sysctl `NET_RT_IFLIST2`, whose `if_msghdr2` messages carry
/// `struct if_data64` with 64-bit byte counters. (`getifaddrs(3)` exposes `struct if_data` with
/// 32-bit counters that wrap every 4 GiB, so it is not used.) One sysctl returns every
/// interface, so newly created or removed interfaces (VPN connect/disconnect, hot-plug) are
/// picked up on the next sample.
public actor NetworkMonitor: TelemetryProvider {
    private struct RawInterface {
        var name: String
        var index: UInt16
        var type: UInt8
        var flags: Int32
        var bytesReceived: UInt64
        var bytesSent: UInt64
    }

    private struct SystemConfigurationInfo {
        var type: String?
        var displayName: String?
    }

    /// How often the primary interface (default route) is re-read from configd.
    private static let primaryInterfaceRefreshInterval: Duration = .seconds(5)

    private var tracker = CounterRateTracker<String>()
    /// Grow-only scratch buffer for the sysctl result, reused across samples.
    private var buffer: [UInt8] = []
    private var configuration: [String: SystemConfigurationInfo] = [:]
    private var configuredNames: Set<String> = []
    private let store: SCDynamicStore?
    private var primaryInterface: String?
    private var primaryInterfaceReadAt: MonotonicInstant?

    public init() {
        store = SCDynamicStoreCreate(nil, "de.linolaske.PulseDeck.NetworkMonitor" as CFString, nil, nil)
    }

    public func capability() -> TelemetryCapability {
        readInterfaces() == nil ? .unsupported(.transientFailure("sysctl NET_RT_IFLIST2 failed")) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<NetworkSnapshot> {
        guard let raw = readInterfaces() else {
            return .unavailable(.transientFailure("sysctl NET_RT_IFLIST2 failed"))
        }
        let names = Set(raw.map(\.name))
        if names != configuredNames {
            configuration = Self.readSystemConfiguration()
            configuredNames = names
            // A changed interface set often means a changed default route (VPN, cable).
            primaryInterfaceReadAt = nil
        }
        refreshPrimaryInterface(at: instant)

        var interfaces: [NetworkInterfaceSnapshot] = []
        interfaces.reserveCapacity(raw.count)
        for item in raw {
            // The interface index changes when an interface is destroyed and re-created with
            // the same name (e.g. utunN on VPN reconnect): that starts a new baseline.
            let rates = tracker.update(key: item.name, generation: UInt64(item.index),
                                       counters: [item.bytesReceived, item.bytesSent], at: instant)
            let info = configuration[item.name]
            interfaces.append(NetworkInterfaceSnapshot(
                id: item.name,
                displayName: info?.displayName,
                kind: NetworkInterfaceClassifier.classify(
                    bsdName: item.name,
                    interfaceType: item.type,
                    isLoopback: item.flags & IFF_LOOPBACK != 0,
                    systemConfigurationType: info?.type,
                    displayName: info?.displayName
                ),
                isUp: item.flags & IFF_UP != 0 && item.flags & IFF_RUNNING != 0,
                receivedBytesPerSecond: rates[0],
                sentBytesPerSecond: rates[1],
                totalBytesReceived: item.bytesReceived,
                totalBytesSent: item.bytesSent
            ))
        }
        tracker.retainOnly(names)
        return .available(NetworkSnapshot(interfaces: interfaces, primaryInterfaceID: primaryInterface))
    }

    public func invalidateBaselines() {
        tracker.reset()
        primaryInterfaceReadAt = nil
    }

    // MARK: - Routing sysctl

    private func readInterfaces() -> [RawInterface]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The table can grow between the size query and the read (ENOMEM); retry a few times.
        let attempts = 3
        for _ in 0..<attempts {
            var needed = 0
            guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0 else { return nil }
            if buffer.count < needed {
                // Headroom for interfaces appearing before the second call.
                buffer = [UInt8](repeating: 0, count: needed + needed / 4)
            }
            var length = buffer.count
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                return parse(length: length)
            }
            guard errno == ENOMEM else { return nil }
            buffer = []
        }
        return nil
    }

    private func parse(length: Int) -> [RawInterface] {
        var result: [RawInterface] = []
        buffer.withUnsafeBytes { raw in
            let headerSize = MemoryLayout<if_msghdr>.size
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                // Skip multicast-address messages (RTM_NEWMADDR2) interleaved in the table.
                guard Int32(header.ifm_type) == RTM_IFINFO2,
                      messageLength >= MemoryLayout<if_msghdr2>.size
                else { continue }
                let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard let name = Self.interfaceName(in: raw, messageOffset: offset, messageLength: messageLength, message: message)
                else { continue }
                result.append(RawInterface(
                    name: name,
                    index: message.ifm_index,
                    type: message.ifm_data.ifi_type,
                    flags: message.ifm_flags,
                    bytesReceived: message.ifm_data.ifi_ibytes,
                    bytesSent: message.ifm_data.ifi_obytes
                ))
            }
        }
        return result
    }

    /// The interface name is carried by the `sockaddr_dl` that follows the message header when
    /// `RTA_IFP` is set; otherwise it is resolved from the index.
    private static func interfaceName(in raw: UnsafeRawBufferPointer, messageOffset: Int, messageLength: Int, message: if_msghdr2) -> String? {
        let addressOffset = messageOffset + MemoryLayout<if_msghdr2>.size
        let messageEnd = messageOffset + messageLength
        if message.ifm_addrs & RTA_IFP != 0,
           addressOffset + MemoryLayout<sockaddr_dl>.size <= messageEnd,
           let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) {
            let link = raw.loadUnaligned(fromByteOffset: addressOffset, as: sockaddr_dl.self)
            let start = addressOffset + dataOffset
            let nameLength = Int(link.sdl_nlen)
            if link.sdl_family == UInt8(AF_LINK), nameLength > 0, start + nameLength <= messageEnd {
                return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<(start + nameLength)]), as: UTF8.self)
            }
        }
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil else { return nil }
        return String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - SystemConfiguration

    /// Interface types and localized names ("Wi‑Fi", "Thunderbolt Bridge"). Only re-read when the
    /// set of interfaces changes.
    private static func readSystemConfiguration() -> [String: SystemConfigurationInfo] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: SystemConfigurationInfo] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            result[bsdName] = SystemConfigurationInfo(
                type: SCNetworkInterfaceGetInterfaceType(interface) as String?,
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            )
        }
        return result
    }

    /// The interface of the default IPv4 route, published by configd at
    /// `State:/Network/Global/IPv4` → `PrimaryInterface`.
    private func refreshPrimaryInterface(at instant: MonotonicInstant) {
        if let readAt = primaryInterfaceReadAt,
           instant.nanoseconds(since: readAt) < Self.primaryInterfaceRefreshInterval.nanosecondsClamped {
            return
        }
        primaryInterfaceReadAt = instant
        guard let store,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            primaryInterface = nil
            return
        }
        primaryInterface = value["PrimaryInterface"] as? String
    }
}
#endif
