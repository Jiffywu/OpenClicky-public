import Foundation

/// How a streamed response body is cut into chunks.
public enum HTTPStreamMode: String, Sendable, Hashable {
    /// Flush at every newline (and every 4 KB), so each server-sent-event line is handed on as soon as it is
    /// complete. What `stream(for:)` does.
    case lines
    /// Hand on bytes as the network delivers them, in whatever sizes they arrive (streamed audio). No byte is
    /// held back waiting for a newline or a full buffer.
    case binary
}

/// The network as adapters see it. Production uses URLSession; tests script responses with `FakeHTTPTransport`.
public protocol HTTPTransport: Sendable {
    /// A whole response body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The response body as it arrives, in chunks (for SSE and streamed audio).
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
    /// The response body as it arrives, chunked as `mode` says. Transports that only have one way of chunking
    /// (the default implementation) use `stream(for:)` for both; adapters must cope with any chunk boundaries.
    func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
}

extension HTTPTransport {
    public func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await stream(for: request)
    }
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Nothing is sent for a caller that is already cancelled.
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await stream(for: request, mode: .lines)
    }

    public func stream(for request: URLRequest, mode: HTTPStreamMode) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try Task.checkCancellation()
        switch mode {
        case .lines: return try await lineStream(for: request)
        case .binary: return try await BinaryResponseStream.start(request, session: session)
        }
    }

    private func lineStream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush on newlines so SSE events are not held back, or every 4 KB for binary audio.
                        if byte == 0x0A || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

/// A data task whose task-specific delegate yields each `didReceive` chunk the moment URLSession delivers it.
/// The task holds its delegate until it completes. Ending the body stream in any way (cancelling the reader,
/// breaking out of the loop, or dropping the stream unread) cancels the task, as does cancelling the caller while it
/// waits for the response head.
///
/// The delegate keeps only the stream's continuation, never the stream itself: an `AsyncThrowingStream` reports
/// `onTermination` when its last copy goes away, so the caller's copy must be the only one.
final class BinaryResponseStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var head: CheckedContinuation<HTTPURLResponse, Error>?
    private var headResult: Result<HTTPURLResponse, Error>?
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private init(body: AsyncThrowingStream<Data, Error>.Continuation) {
        bodyContinuation = body
        super.init()
    }

    static func start(_ request: URLRequest, session: URLSession) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let receiver = BinaryResponseStream(body: bodyContinuation)
        let task = session.dataTask(with: request)
        task.delegate = receiver
        bodyContinuation.onTermination = { _ in task.cancel() }
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let ready: Result<HTTPURLResponse, Error>? = receiver.lock.withLock {
                    if let result = receiver.headResult { return result }
                    receiver.head = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) } else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
        return (body, response)
    }

    private func resolveHead(_ result: Result<HTTPURLResponse, Error>) {
        let waiter: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            guard headResult == nil else { return nil }
            headResult = result
            defer { head = nil }
            return head
        }
        waiter?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            resolveHead(.success(http))
            completionHandler(.allow)
        } else {
            resolveHead(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resolveHead(.failure(error ?? URLError(.badServerResponse)))
        if let error { bodyContinuation.finish(throwing: error) } else { bodyContinuation.finish() }
    }
}

extension HTTPTransport {
    /// Throws a ProviderError carrying the body text when the status is not 2xx.
    public func checkedStream(for request: URLRequest, provider: String) async throws -> AsyncThrowingStream<Data, Error> {
        try await checkedStream(for: request, provider: provider, mode: .lines)
    }

    /// `checkedStream(for:provider:)` with a chunking mode.
    public func checkedStream(for request: URLRequest, provider: String, mode: HTTPStreamMode) async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, response) = try await stream(for: request, mode: mode)
        guard (200..<300).contains(response.statusCode) else {
            var body = Data()
            for try await chunk in stream where body.count < 16_384 { body.append(chunk) }
            throw ProviderError(provider: provider, status: response.statusCode, message: String(decoding: body, as: UTF8.self))
        }
        return stream
    }

    public func checkedData(for request: URLRequest, provider: String) async throws -> Data {
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError(provider: provider, status: response.statusCode, message: String(decoding: data.prefix(16_384), as: UTF8.self))
        }
        return data
    }
}

/// One server-sent event.
public struct ServerSentEvent: Sendable, Hashable {
    public var event: String?
    public var data: String
    public var id: String?
}

/// Parses `text/event-stream` from raw chunks. Keeps blank lines (they end events), unlike line sequences
/// that drop empty lines, and joins multi-line `data:` fields with "\n" as the SSE spec says.
public struct SSEParser: Sendable {
    private var pending = Data()
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [ServerSentEvent] {
        pending.append(chunk)
        var events: [ServerSentEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            pending.removeSubrange(pending.startIndex...newline)
            if let event = process(String(decoding: lineData, as: UTF8.self)) { events.append(event) }
        }
        return events
    }

    /// Flush a final event that was not followed by a blank line.
    public mutating func finish() -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !pending.isEmpty, let event = process(String(decoding: pending, as: UTF8.self)) { events.append(event) }
        pending.removeAll()
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func process(_ line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        case "id": id = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer { event = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(event: event, data: dataLines.joined(separator: "\n"), id: id)
    }
}

extension AsyncThrowingStream where Element == Data, Failure == Error {
    /// The chunks of a `text/event-stream` body as parsed events.
    public func serverSentEvents() -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream<ServerSentEvent, Error> { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await chunk in self {
                        for event in parser.feed(chunk) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
