// A tiny HTTP/1.1 server bound to 127.0.0.1 only. OpenClicky uses it for the OAuth redirect (RFC 8252 §7.3
// loopback redirect); tests use it to stand in for MCP and authorization servers.
//
// One request per connection (`Connection: close`). Bodies are read by `Content-Length`. Responses with several
// chunks are written as they come, close-delimited, so tests can serve Server-Sent Events.

import Foundation

public final class LocalHTTPListener: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// Path and query as sent, e.g. `/callback?code=…`.
        public var target: String
        /// Header names lower-cased.
        public var headers: [String: String]
        public var body: Data

        public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

        public var queryItems: [String: String] {
            guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return [:] }
            var items: [String: String] = [:]
            for item in components.queryItems ?? [] where items[item.name] == nil { items[item.name] = item.value ?? "" }
            return items
        }

        public func header(_ name: String) -> String? { headers[name.lowercased()] }

        public var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: body) }

        /// `application/x-www-form-urlencoded` body fields.
        public var formFields: [String: String] {
            let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: " ")
            var fields: [String: String] = [:]
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if let name = parts.first { fields[name] = parts.count > 1 ? parts[1] : "" }
            }
            return fields
        }
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]
        /// Pause between chunks (to exercise streaming clients).
        public var chunkDelay: Duration?

        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [], chunkDelay: Duration? = nil) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.chunkDelay = chunkDelay
        }

        public static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                     chunks: [Data(value.jsonString().utf8)])
        }

        public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8",
                                headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers.merging(["Content-Type": contentType]) { a, _ in a }, chunks: [Data(text.utf8)])
        }

        public static func empty(_ status: Int, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers)
        }
    }

    public typealias Handler = @Sendable (Request) -> Response

    public enum ServerError: Error, Equatable, CustomStringConvertible {
        case portUnavailable(UInt16)
        case socket(Int32)

        public var description: String {
            switch self {
            case .portUnavailable(let port): "Port \(port) on 127.0.0.1 is in use."
            case .socket(let code): "Couldn't open a loopback socket (errno \(code))."
            }
        }
    }

    /// The bound port.
    public let port: UInt16
    private let listener: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var stopped = false

    /// Binds 127.0.0.1. Port 0 picks a free port.
    public init(port requested: UInt16 = 0, handler: @escaping Handler) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? ServerError.portUnavailable(requested) : ServerError.socket(code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = UInt16(bigEndian: actual.sin_port)
        self.listener = fd
        self.handler = handler
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "OpenClicky loopback HTTP"
        thread.start()
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Stops accepting connections; the port is released within about 100 ms. The server keeps itself alive
    /// until then, so always call this.
    public func stop() { lock.withLock { stopped = true } }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 100)
            if ready <= 0 { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            let thread = Thread { [self] in serve(client) }
            thread.start()
        }
        // Closed here, not in stop(), so the descriptor can't be reused while this loop still polls it.
        close(listener)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let request = readRequest(client) else { return }
        // A connection accepted just before stop() must not reach the handler: its owner may be gone already.
        let response = isStopped ? Response.text("Shutting down", status: 503) : handler(request)
        writeResponse(response, to: client)
    }

    private func readRequest(_ client: Int32) -> Request? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(chunk, count: count)
            headerEnd = buffer.range(of: separator)
            if buffer.count > 1_048_576 { return nil }
        }
        guard let headerEnd else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        var body = Data(buffer[headerEnd.upperBound...])
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        // Nothing this listener serves needs a large body; don't let another local process make it buffer one.
        guard expected >= 0, expected <= Self.maximumBodyBytes else { return nil }
        while body.count < expected {
            let count = recv(client, &chunk, min(chunk.count, expected - body.count), 0)
            guard count > 0 else { return nil }
            body.append(chunk, count: count)
        }
        return Request(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body)
    }

    private func writeResponse(_ response: Response, to client: Int32) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Connection"] = "close"
        let streaming = response.chunks.count > 1 || response.chunkDelay != nil
        if !streaming { headers["Content-Length"] = String(response.chunks.first?.count ?? 0) }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        guard send(Data(head.utf8), to: client) else { return }
        for (index, chunk) in response.chunks.enumerated() {
            if index > 0, let delay = response.chunkDelay {
                Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
            }
            guard send(chunk, to: client) else { return }
        }
    }

    private func send(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Largest request body read (the OAuth callback has none; test servers get small JSON-RPC bodies).
    static let maximumBodyBytes = 8 * 1_048_576

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
