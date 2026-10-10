#if os(macOS)
import Darwin
import Dispatch
import Foundation
import PulseDeckCore

/// Reverse DNS for traffic destinations with `getnameinfo(NI_NAMEREQD)`, off the MainActor.
///
/// - Results are cached, hits and misses; a miss is retried after `missRetryInterval`.
/// - At most `maximumConcurrentLookups` lookups run at a time; addresses beyond that wait for a
///   later `resolve` call (the Traffic view calls it on every refresh).
/// - `getnameinfo` blocks and cannot be cancelled, so it runs on a global dispatch queue; the
///   caller stops waiting after `lookupTimeout` (the lookup is then counted as a miss and its
///   late answer is still cached when it arrives).
/// - Loopback, link-local, multicast and unspecified addresses are never sent to the resolver
///   (they have no meaningful PTR record and would only leak local noise to the DNS server).
public actor HostNameResolver {
    public static let shared = HostNameResolver()

    static let maximumConcurrentLookups = 4
    static let lookupTimeout: Duration = .milliseconds(1500)
    static let missRetryInterval: Duration = .seconds(600)
    static let maximumCacheEntries = 5000

    private enum Entry {
        case name(String)
        case miss(retryAfter: ContinuousClock.Instant)
    }

    private var cache: [String: Entry] = [:]
    /// Cache insertion order, for eviction.
    private var order: [String] = []
    private var inFlight: Set<String> = []

    public init() {}

    /// Names for the addresses resolved so far (cached results only; never blocks).
    public func cachedNames() -> [String: String] {
        var names: [String: String] = [:]
        for (address, entry) in cache {
            if case .name(let name) = entry { names[address] = name }
        }
        return names
    }

    /// Starts lookups for addresses not yet tried (at most a few in flight) and returns the cache.
    public func resolve(_ addresses: [String]) async -> [String: String] {
        let now = ContinuousClock.now
        var batch: [String] = []
        let capacity = Self.maximumConcurrentLookups - inFlight.count
        for address in addresses where batch.count < capacity {
            guard !inFlight.contains(address), Self.isResolvable(address) else { continue }
            switch cache[address] {
            case .name?:
                continue
            case .miss(let retryAfter)?:
                if now < retryAfter { continue }
            case nil:
                break
            }
            if batch.contains(address) { continue }
            batch.append(address)
        }
        guard !batch.isEmpty else { return cachedNames() }
        inFlight.formUnion(batch)

        await withTaskGroup(of: (String, String?).self) { group in
            for address in batch {
                group.addTask {
                    (address, await self.lookUpWithTimeout(address))
                }
            }
            for await (address, name) in group {
                store(name, for: address)
                inFlight.remove(address)
            }
        }
        return cachedNames()
    }

    private func store(_ name: String?, for address: String) {
        if cache[address] == nil {
            order.append(address)
        }
        if let name {
            cache[address] = .name(name)
        } else if case .name? = cache[address] {
            // A late answer already arrived; keep it.
        } else {
            cache[address] = .miss(retryAfter: ContinuousClock.now.advanced(by: Self.missRetryInterval))
        }
        while order.count > Self.maximumCacheEntries {
            cache.removeValue(forKey: order.removeFirst())
        }
    }

    /// Late result of a lookup the caller stopped waiting for.
    private func storeLate(_ name: String, for address: String) {
        store(name, for: address)
    }

    // MARK: - Lookup

    /// The name, or `nil` (no PTR record, failure or timeout).
    private nonisolated func lookUpWithTimeout(_ address: String) async -> String? {
        let box = ResultBox()
        let timeout = Self.lookupTimeout.components
        let milliseconds = Int(timeout.seconds * 1000 + timeout.attoseconds / 1_000_000_000_000_000)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            box.install(continuation)
            DispatchQueue.global(qos: .utility).async {
                let name = Self.lookUp(address)
                if !box.finish(name), let name {
                    // The caller already gave up: cache the answer for next time.
                    Task { await self.storeLate(name, for: address) }
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                _ = box.finish(nil)
            }
        }
    }

    /// One `getnameinfo` with `NI_NAMEREQD` (fail rather than return the numeric form).
    /// Blocking.
    private static func lookUp(_ address: String) -> String? {
        var storage = sockaddr_storage()
        let length: socklen_t
        if address.contains(":") {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, address, &socketAddress.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: socketAddress) { source in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: socketAddress) { source in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        var name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        while name.hasSuffix(".") { name.removeLast() }
        // A resolver that answers with the address itself is not a name.
        guard !name.isEmpty, name != address else { return nil }
        return name
    }

    /// Only addresses with a meaningful public PTR lookup: not loopback, link-local, multicast
    /// or unspecified (and only syntactically valid numeric addresses).
    static func isResolvable(_ address: String) -> Bool {
        if address.contains(":") {
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { return false }
            let raw = withUnsafeBytes(of: bytes, Array.init)
            if raw.allSatisfy({ $0 == 0 }) { return false }                         // ::
            if raw.prefix(15).allSatisfy({ $0 == 0 }) && raw[15] == 1 { return false } // ::1
            if raw[0] == 0xFE && raw[1] & 0xC0 == 0x80 { return false }             // fe80::/10
            if raw[0] == 0xFF { return false }                                     // ff00::/8
            if IPAddressText.isIPv4Mapped(raw) {
                return isResolvable(raw[12..<16].map(String.init).joined(separator: "."))
            }
            return true
        }
        var bytes = in_addr()
        guard inet_pton(AF_INET, address, &bytes) == 1 else { return false }
        let raw = withUnsafeBytes(of: bytes, Array.init)
        if raw[0] == 0 { return false }                        // 0.0.0.0/8
        if raw[0] == 127 { return false }                      // loopback
        if raw[0] == 169 && raw[1] == 254 { return false }     // link-local
        if raw[0] >= 224 { return false }                      // multicast, reserved, broadcast
        return true
    }
}

/// Resumes a continuation exactly once — from the lookup or from the timeout, whichever comes
/// first.
private final class ResultBox: @unchecked Sendable {
    // Guarded by `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if finished {
            continuation.resume(returning: nil)
        } else {
            self.continuation = continuation
        }
    }

    /// `true` if this call resumed the waiter.
    func finish(_ value: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        continuation?.resume(returning: value)
        continuation = nil
        return true
    }
}
#endif
