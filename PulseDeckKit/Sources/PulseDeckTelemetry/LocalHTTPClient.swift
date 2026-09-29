#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// Blocking HTTP/1.1 requests to local services (the Docker Engine API on a Unix socket,
/// Tailscale's LocalAPI on a Unix socket or loopback TCP port). One connection per request with
/// `Connection: close`; send and receive time out so a hung daemon cannot stall a collector for
/// longer than `timeout`. Nothing here leaves the machine.
enum LocalHTTPClient {
    enum Endpoint: Sendable, Hashable {
        case unixSocket(path: String)
        /// A port on 127.0.0.1.
        case loopback(port: UInt16)
    }

    enum Failure: Error, Equatable {
        case connect(Int32)
        case send(Int32)
        case receive(Int32)
        case responseTooLarge
        case malformed(HTTPResponse.ParseError)
    }

    /// Enough for `docker ps -a` / `tailscale status` with hundreds of entries.
    static let maximumResponseSize = 16 * 1024 * 1024

    static func send(
        _ method: String = "GET",
        path: String,
        to endpoint: Endpoint,
        host: String = "localhost",
        headers: [String: String] = [:],
        timeout: Duration = .seconds(2)
    ) -> Result<HTTPResponse, Failure> {
        let descriptor: Int32
        switch connect(to: endpoint, timeout: timeout) {
        case .success(let connected): descriptor = connected
        case .failure(let failure): return .failure(failure)
        }
        defer { close(descriptor) }

        let request = HTTPResponse.request(method: method, path: path, host: host, headers: headers)
        var sent = 0
        while sent < request.count {
            let written = request.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return .failure(.send(errno))
            }
            sent += written
        }

        var data: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { bytes in
                recv(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.receive(errno))
            }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= maximumResponseSize else { return .failure(.responseTooLarge) }
        }
        do {
            return .success(try HTTPResponse.parse(data))
        } catch {
            return .failure(.malformed(error))
        }
    }

    private static func connect(to endpoint: Endpoint, timeout: Duration) -> Result<Int32, Failure> {
        let family = switch endpoint {
        case .unixSocket: AF_UNIX
        case .loopback: AF_INET
        }
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(.connect(errno)) }

        // Never raise SIGPIPE when the daemon closes early.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let (seconds, attoseconds) = timeout.components
        let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000
        var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / attosecondsPerMicrosecond))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

        let status: Int32
        switch endpoint {
        case .unixSocket(let path):
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count < capacity else {
                close(descriptor)
                return .failure(.connect(ENAMETOOLONG))
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: pathBytes)
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        case .loopback(let port):
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_port = port.bigEndian
            // 127.0.0.1 (`INADDR_LOOPBACK` is a cast macro Swift does not import).
            let loopbackAddress: UInt32 = 0x7F00_0001
            address.sin_addr = in_addr(s_addr: loopbackAddress.bigEndian)
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard status == 0 else {
            let error = errno
            close(descriptor)
            return .failure(.connect(error))
        }
        return .success(descriptor)
    }
}
#endif
