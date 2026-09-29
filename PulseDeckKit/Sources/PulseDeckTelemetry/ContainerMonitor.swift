#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// Local Docker containers from the Docker Engine API on a Unix socket — Colima's first
/// (`~/.colima/<profile>/docker.sock`), then Docker Desktop's and the classic path. The Engine API
/// is documented and versioned; PulseDeck only lists containers and reads one-shot stats, and
/// starts/stops/restarts a container when the user asks (`ContainerControl`).
///
/// Demand-driven: sampled only while the Containers section is visible.
public actor ContainerMonitor: TelemetryProvider {
    private var tracker = DockerStatsTracker()
    private var engineVersion: (socket: String, version: String?)?

    public init() {}

    public func capability() -> TelemetryCapability {
        DockerEngine.discover() == nil ? .unsupported(.notApplicable) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<ContainersSnapshot> {
        guard let engine = DockerEngine.discover() else {
            tracker.reset()
            return .unavailable(.notApplicable)
        }
        let endpoint = LocalHTTPClient.Endpoint.unixSocket(path: engine.socketPath)
        let list: HTTPResponse
        switch LocalHTTPClient.send(path: "/containers/json?all=1", to: endpoint) {
        case .success(let response):
            list = response
        case .failure(.connect(let error)) where error == ECONNREFUSED || error == ENOENT:
            // A socket file left behind by a stopped VM.
            tracker.reset()
            return .unavailable(.notApplicable)
        case .failure(.connect(let error)) where error == EACCES || error == EPERM:
            return .unavailable(.permissionDenied)
        case .failure(let failure):
            return .unavailable(.transientFailure("Docker API: \(failure)"))
        }
        guard list.statusCode == 200, let summaries = DockerStatsTracker.containers(fromJSON: list.body) else {
            return .unavailable(.transientFailure("Docker API: HTTP \(list.statusCode)"))
        }

        if engineVersion?.socket != engine.socketPath {
            let version = try? LocalHTTPClient.send(path: "/version", to: endpoint).get()
            engineVersion = (engine.socketPath, version.flatMap { DockerStatsTracker.engineVersion(fromJSON: $0.body) })
        }

        var containers: [ContainerSnapshot] = []
        containers.reserveCapacity(summaries.count)
        for summary in summaries {
            var stats: [UInt8]?
            if summary.State == "running" {
                // one-shot: return the current counters immediately instead of waiting for a
                // second internal sample (Engine API ≥ 1.41).
                let path = "/containers/\(summary.Id)/stats?stream=false&one-shot=true"
                if case .success(let response) = LocalHTTPClient.send(path: path, to: endpoint), response.statusCode == 200 {
                    stats = response.body
                }
            }
            containers.append(tracker.snapshot(for: summary, statsJSON: stats, at: instant))
        }
        tracker.retainOnly(Set(summaries.map(\.Id)))
        return .available(ContainersSnapshot(
            engineName: engine.name,
            socketPath: engine.socketPath,
            engineVersion: engineVersion?.version,
            containers: containers
        ))
    }

    public func invalidateBaselines() {
        tracker.reset()
    }
}

/// Finds the Docker Engine socket.
enum DockerEngine {
    struct Location: Sendable, Equatable {
        var name: String
        var socketPath: String
    }

    static func discover() -> Location? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [Location] = []
        // DOCKER_HOST=unix:///path overrides everything, as for the docker CLI.
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            candidates.append(Location(name: "Docker", socketPath: String(host.dropFirst("unix://".count))))
        }
        let colima = home + "/.colima"
        candidates.append(Location(name: "Colima", socketPath: colima + "/default/docker.sock"))
        if let profiles = try? fileManager.contentsOfDirectory(atPath: colima) {
            for profile in profiles.sorted() where profile != "default" && !profile.hasPrefix("_") {
                candidates.append(Location(name: "Colima (\(profile))", socketPath: "\(colima)/\(profile)/docker.sock"))
            }
        }
        candidates.append(Location(name: "Colima", socketPath: colima + "/docker.sock"))
        candidates.append(Location(name: "Docker Desktop", socketPath: home + "/.docker/run/docker.sock"))
        candidates.append(Location(name: "Docker", socketPath: "/var/run/docker.sock"))
        return candidates.first { isSocket($0.socketPath) }
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFSOCK
    }
}

/// Container actions.
public enum ContainerAction: String, Sendable, CaseIterable {
    case start
    case stop
    case restart
}

public enum ContainerControlError: Error, Hashable, Sendable {
    case engineUnavailable
    case notFound
    case failed(String)
}

/// Starts, stops or restarts a container through the Engine API (`POST /containers/{id}/{action}`).
public enum ContainerControl {
    /// Stopping waits for the container's grace period (10 s by default) before Docker kills it.
    private static let timeout: Duration = .seconds(30)

    public static func perform(_ action: ContainerAction, containerID: String, socketPath: String) async -> Result<Void, ContainerControlError> {
        await Task.detached(priority: .userInitiated) {
            let path = "/containers/\(containerID)/\(action.rawValue)"
            switch LocalHTTPClient.send("POST", path: path, to: .unixSocket(path: socketPath), timeout: timeout) {
            case .failure(.connect):
                return .failure(.engineUnavailable)
            case .failure(let failure):
                return .failure(.failed("\(failure)"))
            case .success(let response):
                switch response.statusCode {
                // 304: already started/stopped — the requested state holds.
                case 200..<300, 304: return .success(())
                case 404: return .failure(.notFound)
                default:
                    let message = String(decoding: response.body, as: UTF8.self)
                    return .failure(.failed(message.isEmpty ? "HTTP \(response.statusCode)" : message))
                }
            }
        }.value
    }
}
#endif
