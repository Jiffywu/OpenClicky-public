import Foundation

/// The two loops every realtime adapter runs on its WebSocket: one task writes queued frames strictly in order, one
/// reads frames and hands them to the session. Either loop failing reports the error once; `close()` stops both and
/// suppresses the report.
final class RealtimeSocketPump: @unchecked Sendable {
    private let connection: any WebSocketConnection
    private let outgoing: AsyncStream<WebSocketMessage>
    private let queue: AsyncStream<WebSocketMessage>.Continuation
    private let lock = NSLock()
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var finished = false

    init(connection: any WebSocketConnection) {
        self.connection = connection
        (outgoing, queue) = AsyncStream<WebSocketMessage>.makeStream()
    }

    /// Starts both loops. `onMessage` runs for each frame, one at a time, in arrival order; `onFailure` runs at most
    /// once, when the socket fails before `close()`.
    func start(onMessage: @escaping @Sendable (WebSocketMessage) async -> Void,
               onFailure: @escaping @Sendable (Error) async -> Void) {
        let connection = connection
        let outgoing = outgoing
        let send = Task { [weak self] in
            for await message in outgoing {
                do {
                    try await connection.send(message)
                } catch {
                    if self?.claimFailure() == true { await onFailure(error) }
                    return
                }
            }
        }
        let receive = Task { [weak self] in
            while !Task.isCancelled {
                let message: WebSocketMessage
                do {
                    message = try await connection.receive()
                } catch {
                    if self?.claimFailure() == true { await onFailure(error) }
                    return
                }
                await onMessage(message)
            }
        }
        lock.withLock {
            sendTask = send
            receiveTask = receive
        }
    }

    /// Queues a JSON frame. Frames queued after `close()` are dropped.
    func send(_ json: JSONValue) {
        RealtimeTrace.log("out", json)
        queue.yield(.text(json.jsonString()))
    }

    var isFinished: Bool { lock.withLock { finished } }

    /// Stops both loops and closes the socket. Frames still queued are dropped.
    func close() async {
        let tasks: [Task<Void, Never>?] = lock.withLock {
            finished = true
            return [sendTask, receiveTask]
        }
        queue.finish()
        tasks.forEach { $0?.cancel() }
        await connection.close()
    }

    /// True for the first failure only, and never after `close()`.
    private func claimFailure() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    /// A frame as a JSON object: text and binary frames both carry UTF-8 JSON.
    static func json(_ message: WebSocketMessage) -> JSONValue? {
        let parsed: JSONValue?
        switch message {
        case .text(let text): parsed = try? JSONValue.parse(text)
        case .binary(let data): parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        guard case .object = parsed else { return nil }
        if let parsed { RealtimeTrace.log("in", parsed) }
        return parsed
    }
}

/// Waits for one value with a deadline, for "wait until the server accepts the session".
actor RealtimeReadySignal {
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func succeed() { settle(.success(())) }
    func fail(_ error: Error) { settle(.failure(error)) }

    private func settle(_ value: Result<Void, Error>) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: value) }
    }

    /// Returns once `succeed()` runs; throws what `fail` got, or `timeoutError` after `timeout`.
    func wait(timeout: Duration, timeoutError: @autoclosure @escaping @Sendable () -> Error) async throws {
        if let result { return try result.get() }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.fail(timeoutError()) }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let result {
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

/// Splits PCM into chunks of at most `maxBytes`, on whole 16-bit frames.
func realtimeAudioChunks(_ pcm: Data, maxBytes: Int) -> [Data] {
    let size = max(2, maxBytes - maxBytes % 2)
    var chunks: [Data] = []
    var offset = pcm.startIndex
    while offset < pcm.endIndex {
        let end = min(offset + size, pcm.endIndex)
        chunks.append(Data(pcm[offset..<end]))
        offset = end
    }
    return chunks
}

/// Opt-in wire trace for debugging adapters against a live provider: set `OPENCLICKY_REALTIME_TRACE=1` and each frame's
/// shape (its keys, event type and short text fields, never audio, images or base64) goes to standard error.
enum RealtimeTrace {
    static let enabled = ProcessInfo.processInfo.environment["OPENCLICKY_REALTIME_TRACE"] == "1"

    static func log(_ direction: String, _ json: JSONValue) {
        guard enabled else { return }
        // Outgoing microphone audio would drown everything else.
        if direction == "out", json["realtimeInput"]?["audio"] != nil || json["type"]?.stringValue == "input_audio_buffer.append" { return }
        FileHandle.standardError.write(Data("[trace \(direction)] \(shape(json, depth: 0))\n".utf8))
    }

    static let maskedKeys: Set<String> = ["newHandle", "handle", "client_secret", "value", "token", "apiKey", "key"]

    /// Keys and small values; strings longer than 80 characters (audio, images) are replaced by their length.
    static func shape(_ value: JSONValue, depth: Int) -> String {
        switch value {
        case .object(let object):
            guard depth < 5 else { return "{…}" }
            let parts = object.keys.sorted().map { key in
                // Session handles and secrets let someone resume or use the session: never print them.
                maskedKeys.contains(key) ? "\(key): <redacted>" : "\(key): \(shape(object[key]!, depth: depth + 1))"
            }
            return "{" + parts.joined(separator: ", ") + "}"
        case .array(let items):
            guard depth < 5 else { return "[…]" }
            return "[" + items.prefix(4).map { shape($0, depth: depth + 1) }.joined(separator: ", ") + (items.count > 4 ? ", …" : "") + "]"
        case .string(let text):
            return text.count > 80 ? "<\(text.count) chars>" : "\"\(text)\""
        default:
            return value.jsonString()
        }
    }
}
