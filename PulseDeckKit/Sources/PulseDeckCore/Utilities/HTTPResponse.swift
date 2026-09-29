import Foundation

/// A minimal HTTP/1.1 response, as returned by local APIs PulseDeck reads over a socket (the
/// Docker Engine API on Colima's Unix socket, Tailscale's LocalAPI). Requests are sent with
/// `Connection: close`, so a response is complete when the peer closes the connection.
public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: [UInt8]

    public init(statusCode: Int, headers: [String: String], body: [UInt8]) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public enum ParseError: Error, Equatable {
        case incomplete
        case malformedStatusLine
        case malformedChunk
    }

    /// Parses a complete response: status line, headers, and a body that is either chunked,
    /// `Content-Length`-delimited or everything up to the end of the data.
    public static func parse(_ data: [UInt8]) throws(ParseError) -> HTTPResponse {
        let separator: [UInt8] = [13, 10, 13, 10] // \r\n\r\n
        guard let headerEnd = data.firstRange(of: separator) else { throw .incomplete }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw .malformedStatusLine }
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw .malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let rest = Array(data[headerEnd.upperBound...])
        let body: [UInt8]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(rest)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard rest.count >= length else { throw .incomplete }
            body = Array(rest.prefix(length))
        } else {
            body = rest
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    /// Decodes `Transfer-Encoding: chunked`: hex size line, data, CRLF, …, zero-size chunk.
    static func decodeChunked(_ data: [UInt8]) throws(ParseError) -> [UInt8] {
        let crlf: [UInt8] = [13, 10]
        var body: [UInt8] = []
        var index = 0
        while true {
            guard let lineEnd = data[index...].firstRange(of: crlf) else { throw .incomplete }
            let sizeLine = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            // Chunk extensions (";name=value") are allowed after the size.
            let sizeText = sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw .malformedChunk }
            index = lineEnd.upperBound
            if size == 0 { return body }
            guard index + size <= data.count else { throw .incomplete }
            body.append(contentsOf: data[index..<(index + size)])
            index += size
            guard index + crlf.count <= data.count else { throw .incomplete }
            guard Array(data[index..<(index + crlf.count)]) == crlf else { throw .malformedChunk }
            index += crlf.count
        }
    }

    /// Serialises a GET/POST request for a local API.
    public static func request(method: String, path: String, host: String, headers: [String: String] = [:]) -> [UInt8] {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: application/json\r\n"
        if method != "GET" { text += "Content-Length: 0\r\n" }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Array(text.utf8)
    }
}
