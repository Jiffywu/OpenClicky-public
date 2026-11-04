import Foundation

/// Scripted HTTP for tests and contract checks. Each request pops the next scripted response and is recorded,
/// so tests can assert both what an adapter sent and how it handled what came back.
public final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Scripted: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]

        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data]) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
        }

        public static func body(_ text: String, status: Int = 200, contentType: String = "application/json") -> Scripted {
            Scripted(status: status, headers: ["Content-Type": contentType], chunks: [Data(text.utf8)])
        }

        /// A server-sent-event body split into several chunks, the way networks deliver it.
        public static func sse(_ text: String, chunkSize: Int = 37) -> Scripted {
            let data = Data(text.utf8)
            let chunks = stride(from: 0, to: data.count, by: chunkSize).map { data[$0..<min($0 + chunkSize, data.count)] }
            return Scripted(headers: ["Content-Type": "text/event-stream"], chunks: chunks.map { Data($0) })
        }
    }

    private let lock = NSLock()
    private var queue: [Scripted]
    private var recordedRequests: [URLRequest] = []
    private var recordedModes: [HTTPStreamMode?] = []

    /// Every request made so far, in order. Read under the lock, so a test may read it while the adapter works.
    public var requests: [URLRequest] { lock.withLock { recordedRequests } }
    /// For each request in `requests`, the stream mode it asked for: nil for `data(for:)`, `.lines` for
    /// `stream(for:)`, otherwise the mode passed to `stream(for:mode:)`.
    public var streamModes: [HTTPStreamMode?] { lock.withLock { recordedModes } }

    public init(_ responses: [Scripted]) { self.queue = responses }

    private func next(_ request: URLRequest, mode: HTTPStreamMode?) throws -> (Scripted, HTTPURLResponse) {
        try lock.withLock {
            recordedRequests.append(request)
            recordedModes.append(mode)
            guard !queue.isEmpty else { throw URLError(.resourceUnavailable) }
            let scripted = queue.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: scripted.status, httpVersion: "HTTP/1.1", headerFields: scripted.headers)!
            return (scripted, response)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (scripted, response) = try next(request, mode: nil)
        return (scripted.chunks.reduce(Data(), +), response)
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await stream(for: request, mode: .lines)
    }

    /// Delivers the scripted chunks as they are, whatever the mode; the mode is recorded in `streamModes`.
    public func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (scripted, response) = try next(request, mode: mode)
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in scripted.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (stream, response)
    }

    /// The JSON body of the n-th request.
    public func jsonBody(_ index: Int = 0) throws -> JSONValue {
        let request = lock.withLock { recordedRequests[index] }
        return try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
    }
}

/// A scripted WebSocket. Inbound messages can be queued up front or pushed while a test runs; everything the
/// adapter sends is recorded.
public final class FakeWebSocket: WebSocketConnection, WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [WebSocketMessage]
    private var waiters: [CheckedContinuation<WebSocketMessage, Error>] = []
    private var closed = false
    /// Thrown by sends and receives once `close()` or `serverClose(with:)` has run.
    private var closeError: Error = URLError(.networkConnectionLost)
    private var sendHandler: (@Sendable (WebSocketMessage, FakeWebSocket) -> Void)?
    private var recordedSent: [WebSocketMessage] = []
    private var recordedConnectRequests: [URLRequest] = []

    /// Everything the adapter sent, in order. Read under the lock.
    public var sent: [WebSocketMessage] { lock.withLock { recordedSent } }
    /// Every request passed to `connect`, in order. Read under the lock.
    public var connectRequests: [URLRequest] { lock.withLock { recordedConnectRequests } }
    /// Called after every send, so a test can answer like a server would. Set and read under the lock, so a test
    /// may swap it while the adapter sends.
    public var onSend: (@Sendable (WebSocketMessage, FakeWebSocket) -> Void)? {
        get { lock.withLock { sendHandler } }
        set { lock.withLock { sendHandler = newValue } }
    }

    public init(inbound: [WebSocketMessage] = []) { self.inbound = inbound }

    public func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        lock.withLock { recordedConnectRequests.append(request) }
        return self
    }

    public func send(_ message: WebSocketMessage) async throws {
        let handler: (@Sendable (WebSocketMessage, FakeWebSocket) -> Void)? = try lock.withLock {
            // Like a real connection: after the server closed it (or refused the upgrade), sends fail with the same
            // error receives do.
            if closed { throw closeError }
            recordedSent.append(message)
            return sendHandler
        }
        handler?(message, self)
    }

    public func push(_ message: WebSocketMessage) {
        let waiter: CheckedContinuation<WebSocketMessage, Error>? = lock.withLock {
            if !waiters.isEmpty { return waiters.removeFirst() }
            inbound.append(message)
            return nil
        }
        waiter?.resume(returning: message)
    }

    public func pushJSON(_ value: JSONValue) { push(.text(value.jsonString())) }

    public func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbound.isEmpty {
                let message = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if closed {
                let error = closeError
                lock.unlock()
                continuation.resume(throwing: error)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func close() async {
        let pending: [CheckedContinuation<WebSocketMessage, Error>] = lock.withLock {
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    /// The server ends the connection: queued inbound messages are still delivered, then every receive and every send
    /// throws `error` (like a real connection's `ProviderError` carrying the close code or a refused upgrade's status).
    public func serverClose(with error: Error) {
        let pending: [CheckedContinuation<WebSocketMessage, Error>] = lock.withLock {
            closed = true
            closeError = error
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume(throwing: error) }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// Sent text frames parsed as JSON.
    public var sentJSON: [JSONValue] {
        sent.compactMap { if case .text(let t) = $0 { try? JSONValue.parse(t) } else { nil } }
    }
}
