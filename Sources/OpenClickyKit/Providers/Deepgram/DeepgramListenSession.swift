import Foundation

/// One live Deepgram stream: audio out as binary frames, results in as JSON text frames.
///
/// The session stays alive until its connection ends: after `finish()` once Deepgram has flushed its last results
/// (or `Options.finishTimeout` passes), on `cancel()`, on an error, or when the consumer stops iterating `events`.
///
/// Every outgoing frame (audio, KeepAlive, CloseStream) goes through one queue that a single task writes in order.
/// Writing from each caller instead would let frames overtake one another while the actor waits on the socket: a
/// `finish()` from the key-release task could put CloseStream on the wire before audio the capture task had already
/// handed over, and Deepgram takes no audio after CloseStream.
actor DeepgramListenSession: SpeechToTextSession {
    private enum Phase { case open, closing, done }

    nonisolated let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let connection: any WebSocketConnection
    private let outgoing: AsyncStream<WebSocketMessage>
    private let outgoingQueue: AsyncStream<WebSocketMessage>.Continuation
    private let provider: String
    private let keepAliveInterval: Duration
    private let finishTimeout: Duration
    private let clock = ContinuousClock()
    private var phase = Phase.open
    /// Deepgram has sent at least one frame, so the WebSocket upgrade succeeded.
    private var heardFromServer = false
    private var lastSent: ContinuousClock.Instant
    private var mapper = DeepgramTranscriptMapper()
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var finishTimer: Task<Void, Never>?

    init(connection: any WebSocketConnection, provider: String, options: DeepgramListenClient.Options) {
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.events = events
        self.continuation = continuation
        (self.outgoing, self.outgoingQueue) = AsyncStream<WebSocketMessage>.makeStream()
        self.connection = connection
        self.provider = provider
        self.keepAliveInterval = options.keepAliveInterval
        self.finishTimeout = options.finishTimeout
        self.lastSent = ContinuousClock.now
    }

    func start() {
        // A consumer that stops iterating (its task was cancelled) tears the stream down, network included.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.shutDown(nil) }
        }
        receiveTask = Task { await self.receiveLoop() }
        sendTask = Task { await self.sendLoop() }
        // A zero or negative interval would make the loop below send KeepAlive back to back, so it turns KeepAlive off.
        if keepAliveInterval > .zero {
            keepAliveTask = Task { await self.keepAliveLoop() }
        }
    }

    // MARK: - SpeechToTextSession

    /// Queues the audio and returns; the send loop writes it in order, so capture never waits on the network.
    func send(_ pcm: Data) async {
        // A zero-length frame makes Deepgram close the stream (troubleshooting doc), so never send one.
        guard phase == .open, !pcm.isEmpty else { return }
        lastSent = clock.now
        outgoingQueue.yield(.binary(pcm))
    }

    func finish() async {
        guard phase == .open else { return }
        phase = .closing
        keepAliveTask?.cancel()
        let timeout = finishTimeout
        finishTimer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await self.shutDown(nil)
        }
        // CloseStream flushes: Deepgram sends the remaining results, then a Metadata summary, then closes (close-stream doc).
        // It is queued behind any audio already handed over, so that audio is still transcribed.
        outgoingQueue.yield(Self.control("CloseStream"))
    }

    func cancel() async {
        await shutDown(nil)
    }

    // MARK: - Loops

    private func receiveLoop() async {
        while phase != .done {
            let message: WebSocketMessage
            do {
                message = try await connection.receive()
            } catch {
                await receiveFailed(error)
                return
            }
            heardFromServer = true
            await handle(message)
        }
    }

    private func handle(_ message: WebSocketMessage) async {
        // Deepgram's server messages are all JSON text frames; anything else is ignored.
        guard phase != .done, case .text(let text) = message, let json = try? JSONValue.parse(text) else { return }
        switch json["type"]?.stringValue {
        case "Metadata":
            // Sent as the summary after CloseStream; the socket closes right after it.
            if phase == .closing { await shutDown(nil) }
        case "Error":
            // The reference calls these non-fatal (e.g. an unparseable client message), but they mean this client's
            // side of the protocol went wrong, so the session ends with the error rather than carrying on.
            await shutDown(ProviderError(provider: provider, message: DeepgramListenClient.errorMessage(json)))
        default:
            for event in mapper.map(json) { continuation.yield(event) }
        }
    }

    /// Writes queued frames to the socket one at a time, in the order they were queued.
    private func sendLoop() async {
        for await message in outgoing {
            guard phase != .done else { return }
            do {
                try await connection.send(message)
            } catch {
                await sendFailed(error)
                return
            }
        }
    }

    /// Deepgram closes the stream after 10 s without audio or KeepAlive, so send one whenever audio has paused that long.
    private func keepAliveLoop() async {
        while phase == .open {
            do {
                try await Task.sleep(until: lastSent.advanced(by: keepAliveInterval), clock: clock)
            } catch {
                return
            }
            guard phase == .open, clock.now >= lastSent.advanced(by: keepAliveInterval) else { continue }
            lastSent = clock.now
            // Must be a text frame; a binary KeepAlive is read as audio (audio-keep-alive doc).
            outgoingQueue.yield(Self.control("KeepAlive"))
        }
    }

    /// A control message (KeepAlive, CloseStream) as the JSON text frame Deepgram expects.
    static func control(_ type: String) -> WebSocketMessage {
        .text(JSONValue.object(["type": .string(type)]).jsonString())
    }

    // MARK: - Ending

    private func receiveFailed(_ error: Error) async {
        switch phase {
        case .done:
            return
        case .closing:
            // After CloseStream the server ends the connection itself; that is the normal end of the stream.
            await shutDown(nil)
        case .open:
            await shutDown(streamError(error, while: "streaming"))
        }
    }

    /// A failed write is always an error: while closing, the queue holds only audio from before `finish()` and the
    /// CloseStream itself, so a failure means Deepgram never got the request to flush.
    private func sendFailed(_ error: Error) async {
        guard phase != .done else { return }
        await shutDown(streamError(error, while: phase == .closing ? "closing the stream" : "streaming"))
    }

    private func streamError(_ error: Error, while activity: String) -> ProviderError {
        if !heardFromServer, let refused = error as? ProviderError, let status = refused.status {
            // URLSessionWebSocketConnector reports a refused upgrade with the HTTP status Deepgram answered with.
            return ProviderError(provider: provider, status: status, message: "Deepgram refused the WebSocket connection "
                + "(HTTP \(status)). Check the API key, model, language and keywords.")
        }
        if !heardFromServer, (error as? URLError)?.code == .badServerResponse {
            // A transport that only reports a refused upgrade as "bad server response" (as URLSession itself does)
            // gives no status or dg-error header, so name the likely causes instead.
            return ProviderError(provider: provider, message: "Deepgram refused the WebSocket connection. "
                + "Check the API key, model, language and keywords. (The HTTP status is not available.)")
        }
        return Self.providerError(error, provider: provider, while: activity)
    }

    /// Ends the session once: stops the timers, drops unsent frames, closes the socket, then finishes `events` (with
    /// `error`, if any).
    private func shutDown(_ error: Error?) async {
        guard phase != .done else { return }
        phase = .done
        keepAliveTask?.cancel()
        finishTimer?.cancel()
        receiveTask?.cancel()
        outgoingQueue.finish()
        sendTask?.cancel()
        await connection.close()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// Transport failures as ProviderErrors; a ProviderError from the transport (e.g. a failed upgrade's status) passes
    /// through unchanged.
    static func providerError(_ error: Error, provider: String, while activity: String) -> ProviderError {
        if let error = error as? ProviderError { return error }
        return ProviderError(provider: provider, message: "Deepgram connection failed while \(activity): \(error.localizedDescription)")
    }
}
