import CryptoKit
import Foundation
import Network
import Testing
@testable import OpenClickyKit

/// The real URLSession transports against a tiny server on 127.0.0.1, so what URLSession actually reports (chunk
/// timing, a refused upgrade, a close frame) is checked rather than assumed. Nothing leaves the machine.
@Suite struct URLSessionTransportTests {
    // MARK: - Binary streaming

    @Test func binaryModeDeliversBytesBeforeTheNextChunkIsSent() async throws {
        let firstSeen = Gate()
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Type: audio/pcm\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            // Five bytes with no newline: a newline-flushing reader would sit on them until the 4 KB mark.
            try await connection.write(Self.chunk(Data([1, 2, 3, 4, 5])))
            await firstSeen.wait()
            try await connection.write(Self.chunk(Data([6, 7])) + Data("0\r\n\r\n".utf8))
        }
        defer { server.stop() }

        let (body, response) = try await URLSessionTransport().stream(for: URLRequest(url: server.url("/speech")), mode: .binary)
        #expect(response.statusCode == 200)
        let (received, chunks) = try await withTimeout(.seconds(10)) {
            var received = Data()
            var chunks = 0
            for try await chunk in body {
                received += chunk
                chunks += 1
                if received.count == 5 { await firstSeen.open() }
            }
            return (received, chunks)
        }
        #expect(received == Data([1, 2, 3, 4, 5, 6, 7]))
        #expect(chunks >= 2)
    }

    @Test func linesModeStillFlushesAtNewlines() async throws {
        let firstSeen = Gate()
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            try await connection.write(Self.chunk(Data("data: 1\n\n".utf8)))
            await firstSeen.wait()
            try await connection.write(Self.chunk(Data("data: 2\n\n".utf8)) + Data("0\r\n\r\n".utf8))
        }
        defer { server.stop() }

        let stream = try await URLSessionTransport().checkedStream(for: URLRequest(url: server.url("/events")), provider: "local")
        let events = try await withTimeout(.seconds(10)) {
            var events: [String] = []
            for try await event in stream.serverSentEvents() {
                events.append(event.data)
                if events.count == 1 { await firstSeen.open() }
            }
            return events
        }
        #expect(events == ["1", "2"])
    }

    @Test func binaryModeReportsErrorStatusAndBody() async throws {
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            let body = #"{"error":{"message":"bad key"}}"#
            try await connection.write(Data("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        }
        defer { server.stop() }
        let error = await #expect(throws: ProviderError.self) {
            _ = try await URLSessionTransport().checkedStream(for: URLRequest(url: server.url("/x")), provider: "local", mode: .binary)
        }
        #expect(error?.status == 401)
        #expect(error?.message.contains("bad key") == true)
    }

    @Test func cancelledCallerSendsNothing() async throws {
        // Count requests for this test's own path rather than raw TCP connections: under the parallel suite, a
        // straggling connection from another test can land on a recycled loopback port and isn't a request from us.
        let seen = RequestLog()
        let server = try await LoopbackServer { connection in
            let head = try await connection.readRequestHead()
            seen.record(head)
            try await connection.write(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let url = server.url("/never")
        for mode in [HTTPStreamMode.lines, .binary] {
            let result = await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await URLSessionTransport().stream(for: URLRequest(url: url), mode: mode)
            }.result
            #expect(throws: CancellationError.self) { _ = try result.get() }
        }
        let dataResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await URLSessionTransport().data(for: URLRequest(url: url))
        }.result
        #expect(throws: CancellationError.self) { _ = try dataResult.get() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(seen.requests(for: "/never") == 0)
    }

    // MARK: - WebSocket errors

    @Test func refusedUpgradeSurfacesTheHTTPStatus() async throws {
        let server = try await LoopbackServer { connection in
            _ = try await connection.readRequestHead()
            try await connection.write(Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let socket = try await URLSessionWebSocketConnector().connect(URLRequest(url: server.url("/listen", scheme: "ws")))
        let error = await #expect(throws: ProviderError.self) {
            try await withTimeout(.seconds(10)) { _ = try await socket.receive() }
        }
        #expect(error?.status == 401)
        #expect(error?.provider == "127.0.0.1")
        await socket.close()
    }

    @Test func serverCloseSurfacesCodeAndReason() async throws {
        let server = try await LoopbackServer { connection in
            let head = try await connection.readRequestHead()
            let key = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) } ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            try await connection.write(Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n").utf8))
            // One text frame, then a close frame with code 4001 and a reason.
            try await connection.write(Data([0x81, 0x02]) + Data("hi".utf8))
            let reason = Data("bad model".utf8)
            try await connection.write(Data([0x88, UInt8(2 + reason.count), 0x0F, 0xA1]) + reason)
            try? await Task.sleep(for: .seconds(2))
        }
        defer { server.stop() }
        let socket = try await URLSessionWebSocketConnector().connect(URLRequest(url: server.url("/realtime", scheme: "ws")))
        #expect(try await withTimeout(.seconds(10)) { try await socket.receive() } == .text("hi"))
        let error = await #expect(throws: ProviderError.self) {
            try await withTimeout(.seconds(10)) { _ = try await socket.receive() }
        }
        #expect(error?.message == "The server closed the WebSocket (code 4001: bad model).")
        await socket.close()
    }

    // MARK: - Helpers

    static func chunk(_ data: Data) -> Data {
        Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8)
    }
}

struct TimedOut: Error {}

/// Fails the test instead of hanging when `body` does not finish in time.
func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimedOut()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimedOut() }
        return first
    }
}

/// A one-shot signal between the test and the server.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A TCP server on 127.0.0.1 that runs `handler` for each connection.
/// Request heads a loopback server received, for asserting which requests actually arrived.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var heads: [String] = []

    func record(_ head: String) { lock.withLock { heads.append(head) } }

    /// Requests whose request line targets `path`.
    func requests(for path: String) -> Int {
        lock.withLock { heads.filter { $0.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first == Substring(path) }.count }
    }
}

final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackServer")
    private let lock = NSLock()
    private var connections = 0
    private(set) var port: UInt16 = 0

    var connectionCount: Int { lock.withLock { connections } }

    init(handler: @escaping @Sendable (LoopbackConnection) async throws -> Void) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let lock = lock
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            lock.withLock { self?.connections += 1 }
            connection.start(queue: queue)
            Task {
                let wrapped = LoopbackConnection(connection)
                try? await handler(wrapped)
                connection.cancel()
            }
        }
        let ready = Gate()
        listener.stateUpdateHandler = { state in
            if case .ready = state { Task { await ready.open() } }
        }
        listener.start(queue: queue)
        await ready.wait()
        port = listener.port?.rawValue ?? 0
    }

    func url(_ path: String, scheme: String = "http") -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(port)\(path)")!
    }

    func stop() { listener.cancel() }
}

struct LoopbackConnection: Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    /// Reads up to the blank line ending the request head.
    func readRequestHead() async throws -> String {
        var data = Data()
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let piece: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let content, !content.isEmpty { continuation.resume(returning: content) }
                    else if isComplete { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            data += piece
        }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
