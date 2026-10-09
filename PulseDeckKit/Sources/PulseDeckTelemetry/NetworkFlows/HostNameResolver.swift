#if os(macOS)
import Foundation

/// STUB API (flows backend agent implements; keep the signatures). Reverse DNS for traffic
/// destinations with `getnameinfo` (off the MainActor, cached, rate-limited, never for private
/// addresses' noise beyond what the user's resolver does).
public actor HostNameResolver {
    public static let shared = HostNameResolver()

    /// Names for the addresses resolved so far (cached results only; never blocks).
    public func cachedNames() -> [String: String] { [:] }

    /// Starts lookups for addresses not yet tried (at most a few in flight) and returns the cache.
    public func resolve(_ addresses: [String]) async -> [String: String] { [:] }
}
#endif
