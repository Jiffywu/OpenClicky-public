import Foundation

public enum WebSocketMessage: Sendable, Hashable {
    case text(String)
    case binary(Data)
}

public protocol WebSocketConnection: Sendable {
    func send(_ message: WebSocketMessage) async throws
    /// Waits for the next message. Throws once the socket closes.
    func receive() async throws -> WebSocketMessage
    func close() async
}

public protocol WebSocketConnector: Sendable {
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection
}

/// WebSockets over URLSession.
///
/// `connect` returns at once; the opening handshake runs in the background and the first `send` or `receive` waits
/// for it. When the server refuses the upgrade, those calls throw a `ProviderError` carrying the HTTP status the
/// server answered with (401 for a bad key, 404 for a wrong path), instead of URLSession's bare "bad server
/// response". When the server closes the socket, `receive` throws a `ProviderError` with the close code and reason.
/// The error's `provider` is the server's host; adapters may re-label it.
public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        try Task.checkCancellation()
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionWebSocketConnection(task: task, label: request.url?.host ?? "websocket")
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let label: String
    private let lock = NSLock()
    private var closedLocally = false

    init(task: URLSessionWebSocketTask, label: String = "websocket") {
        self.task = task
        self.label = label
    }

    func send(_ message: WebSocketMessage) async throws {
        do {
            switch message {
            case .text(let text): try await task.send(.string(text))
            case .binary(let data): try await task.send(.data(data))
            }
        } catch {
            throw surfaced(error)
        }
    }

    func receive() async throws -> WebSocketMessage {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw surfaced(error)
        }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func close() async {
        lock.withLock { closedLocally = true }
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Replaces URLSession's generic error with what actually happened: the HTTP status of a refused upgrade, or
    /// the close code and reason the server sent. Errors after our own `close()` pass through unchanged.
    private func surfaced(_ error: Error) -> Error {
        if error is CancellationError || lock.withLock({ closedLocally }) { return error }
        return Self.describe(error, response: task.response as? HTTPURLResponse, closeCode: task.closeCode.rawValue,
                             closeReason: task.closeReason, label: label)
    }

    /// The error to report, given what the task knows. Separate from the task so it can be tested directly.
    static func describe(_ error: Error, response: HTTPURLResponse?, closeCode: Int, closeReason: Data?, label: String) -> Error {
        if let response, response.statusCode != 101 {
            let status = response.statusCode
            return ProviderError(provider: label, status: status,
                                 message: "The server refused the WebSocket connection (HTTP \(status) "
                                    + "\(HTTPURLResponse.localizedString(forStatusCode: status))).")
        }
        // 0 is URLSessionWebSocketTask.CloseCode.invalid: no close frame was received.
        if closeCode != 0 {
            let reason = closeReason.map { String(decoding: $0, as: UTF8.self) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProviderError(provider: label, status: nil,
                                 message: "The server closed the WebSocket (code \(closeCode)\(reason.isEmpty ? "" : ": \(reason)")).")
        }
        return error
    }
}

extension WebSocketConnection {
    /// Sends a JSON object as a text frame.
    public func sendJSON(_ value: JSONValue) async throws { try await send(.text(value.jsonString())) }

    /// Every incoming message until the socket closes, as a stream.
    public func messages() -> AsyncThrowingStream<WebSocketMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled { continuation.yield(try await receive()) }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
