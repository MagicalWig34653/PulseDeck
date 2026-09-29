#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// Tailscale peers and per-peer traffic from the local daemon's LocalAPI
/// (`GET /localapi/v0/status`), the interface the `tailscale` CLI uses. Read-only; nothing is
/// sent over the network. Approved by the product owner (documented, unversioned API — labelled
/// in the UI).
///
/// The daemon is found the way the CLI finds it (tailscale.com/safesocket, darwin):
/// 1. open-source `tailscaled`: Unix socket `/var/run/tailscaled.socket`, no token;
/// 2. standalone app (system extension): TCP port from the symlink target of
///    `/Library/Tailscale/ipnport`, token in `/Library/Tailscale/sameuserproof-<port>`;
/// 3. Mac App Store app: file `sameuserproof-<port>-<token>` in the app's group container.
/// TCP connections authenticate with HTTP Basic auth (empty user, token as password).
///
/// Demand-driven: sampled only while a Tailscale interface page is visible.
public actor TailscaleMonitor: TelemetryProvider {
    private struct Connection: Sendable, Equatable {
        var endpoint: LocalHTTPClient.Endpoint
        var token: String?
    }

    private static let socketPath = "/var/run/tailscaled.socket"
    private static let standaloneDirectory = "/Library/Tailscale"
    private static let appStoreGroupContainer = "Library/Group Containers/io.tailscale.ipn.macos"
    /// The LocalAPI checks this Host header to reject requests from web pages (DNS rebinding).
    private static let localAPIHost = "local-tailscaled.sock"

    private var tracker = TailscaleStatusTracker()
    private var connection: Connection?

    public init() {}

    public func capability() -> TelemetryCapability {
        Self.discover() == nil ? .unsupported(.notApplicable) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<TailscaleSnapshot> {
        // The port and token change when the app restarts: re-discover on every failure.
        guard let current = connection ?? Self.discover() else {
            tracker.reset()
            return .unavailable(.notApplicable)
        }
        var headers = ["Sec-Tailscale": "localapi"]
        if let token = current.token {
            headers["Authorization"] = "Basic " + Data(":\(token)".utf8).base64EncodedString()
        }
        switch LocalHTTPClient.send(path: "/localapi/v0/status", to: current.endpoint, host: Self.localAPIHost, headers: headers) {
        case .failure(let failure):
            connection = nil
            tracker.reset()
            return .unavailable(.transientFailure("Tailscale LocalAPI: \(failure)"))
        case .success(let response):
            guard (200..<300).contains(response.statusCode) else {
                connection = nil
                if response.statusCode == 401 || response.statusCode == 403 { return .unavailable(.permissionDenied) }
                return .unavailable(.transientFailure("Tailscale LocalAPI: HTTP \(response.statusCode)"))
            }
            connection = current
            guard let snapshot = tracker.snapshot(fromStatusJSON: response.body, at: instant) else {
                return .unavailable(.transientFailure("Tailscale LocalAPI: unexpected status document"))
            }
            return .available(snapshot)
        }
    }

    public func invalidateBaselines() {
        tracker.reset()
    }

    // MARK: - Discovery

    private static func discover() -> Connection? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            return Connection(endpoint: .unixSocket(path: socketPath), token: nil)
        }
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: standaloneDirectory + "/ipnport"),
           let port = UInt16(target),
           let token = try? String(contentsOfFile: "\(standaloneDirectory)/sameuserproof-\(port)", encoding: .utf8) {
            return Connection(endpoint: .loopback(port: port), token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let container = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(appStoreGroupContainer).path
        guard fileManager.fileExists(atPath: container),
              let names = try? fileManager.contentsOfDirectory(atPath: container)
        else { return nil }
        for name in names where name.hasPrefix("sameuserproof-") {
            // "sameuserproof-<port>-<token>"; the token itself contains no "-".
            let parts = name.split(separator: "-", maxSplits: 2)
            guard parts.count == 3, let port = UInt16(parts[1]), !parts[2].isEmpty else { continue }
            return Connection(endpoint: .loopback(port: port), token: String(parts[2]))
        }
        return nil
    }
}
#endif
