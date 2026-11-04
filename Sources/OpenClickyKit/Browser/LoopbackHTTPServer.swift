import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    /// The path without the query string.
    public var path: String
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ value: JSONValue, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: Data(value.jsonString().utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Cache-Control"] = "no-store"
        all["Connection"] = "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// A minimal HTTP/1.1 server bound to 127.0.0.1. One request per connection (`Connection: close`), bodies by
/// `Content-Length` or chunked encoding, size-capped. Enough for MCP's Streamable HTTP transport with JSON responses.
///
/// Any local process can connect before it proves it holds a token, so reading a request is bounded: each connection
/// gets its own thread (never a shared GCD worker, which idle clients could exhaust), at most `maxConnections` are
/// served at once (the rest get 503), and the whole request must arrive within `requestTimeout` seconds.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// Longest chunk-size line accepted in a chunked body.
    static let maxChunkLine = 1024

    private let requestedPort: UInt16
    private let maxBodyBytes: Int
    private let maxConnections: Int
    private let requestTimeout: TimeInterval
    private let handler: Handler
    private let lock = NSLock()
    private var acceptor: SocketAcceptor?
    private var boundPort: UInt16 = 0
    private var active = 0

    public init(port: UInt16 = 0, maxBodyBytes: Int = 8 * 1024 * 1024, maxConnections: Int = 256,
                requestTimeout: TimeInterval = 15, handler: @escaping Handler) {
        self.requestedPort = port
        self.maxBodyBytes = maxBodyBytes
        self.maxConnections = max(1, maxConnections)
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    deinit { stop() }

    public var port: UInt16 { lock.withLock { boundPort } }

    /// Starts listening and returns the bound port.
    @discardableResult
    public func start() throws -> UInt16 {
        let (fd, port) = try BridgeSocket.listenLoopbackTCP(port: requestedPort)
        let acceptor = SocketAcceptor(listener: fd, label: "com.openclicky.loopback-http.accept") { [weak self] client in
            guard let self else { Darwin.close(client); return }
            self.admit(client)
        }
        lock.withLock {
            self.acceptor = acceptor
            self.boundPort = port
        }
        return port
    }

    public func stop() {
        let acceptor = lock.withLock { () -> SocketAcceptor? in
            defer { self.acceptor = nil }
            return self.acceptor
        }
        acceptor?.cancel()
    }

    private func admit(_ fd: Int32) {
        let admitted = lock.withLock { () -> Bool in
            guard active < maxConnections else { return false }
            active += 1
            return true
        }
        guard admitted else {
            // A fresh socket's send buffer takes this small reply without blocking the accept queue. Whatever the
            // client already sent is drained without waiting, so closing doesn't reset the connection over the reply.
            try? BridgeSocket.writeAll(fd, HTTPResponse.json(503, ["error": "busy"], headers: ["Retry-After": "1"]).serialized())
            Darwin.shutdown(fd, SHUT_WR)
            var scratch = [UInt8](repeating: 0, count: 4096)
            while scratch.withUnsafeMutableBytes({ recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }) > 0 {}
            Darwin.close(fd)
            return
        }
        Thread.detachNewThread { [self] in
            serve(fd)
            lock.withLock { active -= 1 }
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        BridgeSocket.setWriteTimeout(fd, seconds: 60)
        let response: HTTPResponse
        switch readRequest(fd, deadline: Date().addingTimeInterval(requestTimeout)) {
        case .success(let request):
            response = Self.await(handler, request)
        case .failure(let status):
            response = .json(status, ["error": .string(HTTPResponse.reason(status).lowercased().replacingOccurrences(of: " ", with: "_"))])
        }
        try? BridgeSocket.writeAll(fd, response.serialized())
        Darwin.shutdown(fd, SHUT_WR)
        // Lingering close: read (briefly) whatever the client is still sending, so closing with unread input doesn't
        // reset the connection and destroy the response before the client reads it.
        BridgeSocket.setReadTimeout(fd, seconds: 0.25)
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        var reads = 0
        while reads < 64, scratch.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) > 0 { reads += 1 }
    }

    /// Runs the async handler from this I/O thread (never a cooperative-pool thread) and waits for it.
    private static func await(_ handler: @escaping Handler, _ request: HTTPRequest) -> HTTPResponse {
        final class Box: @unchecked Sendable { var value: HTTPResponse? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await handler(request)
            done.signal()
        }
        done.wait()
        return box.value ?? .json(500, ["error": "internal"])
    }

    private enum ReadResult {
        case success(HTTPRequest)
        case failure(Int)
    }

    private func readRequest(_ fd: Int32, deadline: Date) -> ReadResult {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard buffer.count < 64 * 1024 else { return .failure(413) }
            guard let chunk = readChunk(fd, deadline: deadline) else { return .failure(buffer.isEmpty ? 400 : 408) }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failure(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        var body = Data(buffer[headerEnd!.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch readChunked(fd, initial: body, deadline: deadline) {
            case .success(let decoded): body = decoded
            case .failure(.status(let code)): return .failure(code)
            }
        } else {
            let field = headers["content-length"] ?? "0"
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(field) else { return .failure(400) }
            guard length <= maxBodyBytes else { return .failure(413) }
            while body.count < length {
                guard let chunk = readChunk(fd, deadline: deadline) else { return .failure(408) }
                body.append(chunk)
            }
            body = body.prefix(length)
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .success(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }

    /// The next bytes from the client, or nil at end of stream, on error, or once the request deadline has passed.
    private func readChunk(_ fd: Int32, deadline: Date) -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            BridgeSocket.setReadTimeout(fd, seconds: max(remaining, 0.01))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(bytes[0..<count]) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }

    /// The size on a chunk-size line: ASCII hex digits, optionally followed by whitespace and `;` extensions. No
    /// sign, no leading space, and at most 15 digits, so it can't overflow.
    static func chunkSize(_ line: Data) -> Int? {
        let isHex = { (byte: UInt8) in (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        let digits = line.prefix(while: isHex)
        guard !digits.isEmpty, digits.count <= 15 else { return nil }
        let rest = line.dropFirst(digits.count).drop { $0 == 0x20 || $0 == 0x09 }
        guard rest.isEmpty || rest.first == UInt8(ascii: ";") else { return nil }
        return Int(String(decoding: digits, as: UTF8.self), radix: 16)
    }

    private func readChunked(_ fd: Int32, initial: Data, deadline: Date) -> Result<Data, ChunkedError> {
        var raw = initial
        var output = Data()
        var cursor = raw.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            while raw[cursor...].range(of: crlf) == nil {
                guard raw.distance(from: cursor, to: raw.endIndex) <= Self.maxChunkLine else { return .failure(.status(400)) }
                guard let chunk = readChunk(fd, deadline: deadline) else { return .failure(.status(408)) }
                raw.append(chunk)
            }
            let lineEnd = raw[cursor...].range(of: crlf)!
            guard raw.distance(from: cursor, to: lineEnd.lowerBound) <= Self.maxChunkLine,
                  let size = Self.chunkSize(Data(raw[cursor..<lineEnd.lowerBound])) else { return .failure(.status(400)) }
            cursor = lineEnd.upperBound
            if size == 0 { return .success(output) }
            guard size <= maxBodyBytes - output.count else { return .failure(.status(413)) }
            while raw.distance(from: cursor, to: raw.endIndex) < size + 2 {
                guard let chunk = readChunk(fd, deadline: deadline) else { return .failure(.status(408)) }
                raw.append(chunk)
            }
            let dataEnd = raw.index(cursor, offsetBy: size)
            guard raw[dataEnd..<raw.index(dataEnd, offsetBy: 2)] == crlf else { return .failure(.status(400)) }
            output.append(raw[cursor..<dataEnd])
            cursor = raw.index(dataEnd, offsetBy: 2)
            // Drop what has been consumed so a long body isn't rescanned or held twice.
            raw = Data(raw[cursor...])
            cursor = raw.startIndex
        }
    }

    private enum ChunkedError: Error {
        case status(Int)
    }
}
