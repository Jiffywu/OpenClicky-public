import Foundation

/// One Gemini Live socket used for one push-to-talk press.
///
/// Lifecycle: the socket opens and sends `setup` straight away. A warm session (opened ahead of key-down) then waits,
/// idle, until `activate()` makes it the press's session; a session opened at key-down is active from the start.
/// Audio sent before `setupComplete` is held and flushed after `activityStart`, so the first words are not lost.
/// `finish()` sends `activityEnd` and waits for the settled transcript:
/// - a `turnComplete` with no unsettled interim ends at once;
/// - a final that leaves nothing unsettled ends after a short quiet spell (`settleDelay`), in case another segment's
///   final is right behind it (the docs give no end-of-transcript marker for the transcription model);
/// - a press with nothing unsettled at key-up (Gemini heard nothing, or every word was already final) ends after
///   `quietFinishTimeout` if no final follows `activityEnd`;
/// - otherwise `finalTimeout` ends it, promoting the last interim to final text so no words are dropped.
///
/// Every outgoing frame goes through one queue that a single task writes in order, so `activityEnd` from the
/// key-release task can never overtake audio the capture task already handed over.
actor GeminiLiveSession: SpeechToTextSession, SpeechToTextSessionReadiness {
    enum Phase: Equatable {
        /// Opened ahead of key-down; waiting for `setupComplete`.
        case warming
        /// Warm and ready; waiting for a press.
        case warm
        /// Pressed before `setupComplete`; audio is held.
        case starting
        /// `activityStart` sent; audio flows.
        case live
        /// `activityEnd` sent; waiting for the settled transcript.
        case finishing
        case done
    }

    nonisolated let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let connection: any WebSocketConnection
    private let outgoing: AsyncStream<WebSocketMessage>
    private let outgoingQueue: AsyncStream<WebSocketMessage>.Continuation
    private let provider: String
    private let options: GeminiLiveSpeechToTextClient.Options
    private let setupMessage: JSONValue
    private(set) var phase: Phase = .warming
    private var mapper: GeminiLiveTranscriptMapper
    private var aligner = PCMFrameAligner(frameSize: 2)
    private var heldAudio: [Data] = []
    private var finishRequested = false
    private var setupCompleted = false
    /// Set when Gemini announced the connection is about to end.
    private var goAwayTimeLeft: Duration??
    private var finalAfterEnd = false
    private var turnCompleteAfterEnd = false
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var setupTimer: Task<Void, Never>?
    private var finalTimer: Task<Void, Never>?
    private var quietTimer: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    /// Opened ahead of key-down by `warmUp`.
    private var openedWarm = false
    /// Callers of `waitUntilReady()` waiting for `setupComplete`.
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []

    init(connection: any WebSocketConnection, provider: String, options: GeminiLiveSpeechToTextClient.Options,
         setup: JSONValue, joining: GeminiLiveTranscriptMapper.Joining) {
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        self.events = events
        self.continuation = continuation
        (self.outgoing, self.outgoingQueue) = AsyncStream<WebSocketMessage>.makeStream()
        self.connection = connection
        self.provider = provider
        self.options = options
        self.setupMessage = setup
        self.mapper = GeminiLiveTranscriptMapper(joining: joining)
    }

    /// Starts the socket's loops and sends `setup`. An `active` session is the press's session from the start.
    func begin(active: Bool) {
        phase = active ? .starting : .warming
        openedWarm = !active
        // A consumer that stops iterating (its task was cancelled) tears the session down, network included.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.shutDown(nil) }
        }
        receiveTask = Task { await self.receiveLoop() }
        sendTask = Task { await self.sendLoop() }
        // Setup goes first; nothing else may be sent until Gemini answers it.
        queue(setupMessage)
        let timeout = options.setupTimeout
        setupTimer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await self.setupTimedOut()
        }
    }

    // MARK: - SpeechToTextSessionReadiness

    var startedWarm: Bool { openedWarm }

    func waitUntilReady() async -> Bool {
        if setupCompleted { return true }
        if phase == .done { return false }
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func resumeReadyWaiters(_ ready: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    /// Still warm and unclaimed, so a press can use it.
    var isReusable: Bool { phase == .warming || phase == .warm }

    /// Makes a warm session the press's session. False if it can no longer be used.
    func activate() -> Bool {
        switch phase {
        case .warm:
            queue(GeminiLiveWire.activityStart)
            phase = .live
            return true
        case .warming:
            phase = .starting
            return true
        case .starting, .live, .finishing, .done:
            return false
        }
    }

    // MARK: - SpeechToTextSession

    /// Queues the audio and returns; the send loop writes it in order, so capture never waits on the network.
    func send(_ pcm: Data) async {
        guard phase == .starting || phase == .live, !finishRequested, !pcm.isEmpty else { return }
        let samples = aligner.push(pcm)
        guard !samples.isEmpty else { return }
        if phase == .starting {
            heldAudio.append(samples)
        } else {
            queueAudio(samples)
        }
    }

    func finish() async {
        switch phase {
        case .starting:
            finishRequested = true
        case .live:
            beginFinishing()
        case .warming, .warm:
            await shutDown(nil)
        case .finishing, .done:
            break
        }
    }

    func cancel() async {
        await shutDown(nil)
    }

    // MARK: - Outgoing

    private func queue(_ message: JSONValue) {
        outgoingQueue.yield(.text(message.jsonString()))
    }

    private func queueAudio(_ samples: Data) {
        var offset = samples.startIndex
        while offset < samples.endIndex {
            let end = min(offset + GeminiLiveWire.maxAudioChunkBytes, samples.endIndex)
            queue(GeminiLiveWire.audio(Data(samples[offset..<end])))
            offset = end
        }
    }

    private func beginFinishing() {
        phase = .finishing
        queue(GeminiLiveWire.activityEnd)
        let finalTimeout = options.finalTimeout
        finalTimer = Task {
            do { try await Task.sleep(for: finalTimeout) } catch { return }
            await self.finalTimedOut()
        }
        if !mapper.hasPendingInterim {
            let quiet = options.quietFinishTimeout
            quietTimer = Task {
                do { try await Task.sleep(for: quiet) } catch { return }
                await self.quietTimedOut()
            }
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

    // MARK: - Incoming

    private func receiveLoop() async {
        while phase != .done {
            let message: WebSocketMessage
            do {
                message = try await connection.receive()
            } catch {
                await receiveFailed(error)
                return
            }
            await handle(message)
        }
    }

    private func handle(_ message: WebSocketMessage) async {
        guard phase != .done, let json = GeminiLiveWire.parse(message) else { return }
        if let error = json["error"] {
            let (status, text) = GeminiLiveWire.errorMessage(error)
            await shutDown(ProviderError(provider: provider, status: status, message: "Gemini Live rejected the transcription session: \(text)"))
            return
        }
        if json["setupComplete"] != nil {
            setupDidComplete()
        }
        if let goAway = json["goAway"] {
            goAwayTimeLeft = .some(GeminiLiveWire.duration(goAway["timeLeft"]))
            // A warm socket that is about to be dropped is no use to the next press.
            if phase == .warming || phase == .warm {
                await shutDown(nil)
                return
            }
        }
        // Transcripts only matter once a press owns the session.
        guard phase == .live || phase == .finishing else { return }
        for event in mapper.map(json) { continuation.yield(event) }
        if phase == .finishing, let content = json["serverContent"] {
            if content["inputTranscription"] != nil { finalAfterEnd = true }
            if content["turnComplete"]?.boolValue == true { turnCompleteAfterEnd = true }
            await settleIfDone()
        }
    }

    private func setupDidComplete() {
        guard !setupCompleted else { return }
        setupCompleted = true
        setupTimer?.cancel()
        resumeReadyWaiters(true)
        switch phase {
        case .warming:
            phase = .warm
        case .starting:
            queue(GeminiLiveWire.activityStart)
            for samples in heldAudio { queueAudio(samples) }
            heldAudio.removeAll()
            phase = .live
            if finishRequested { beginFinishing() }
        case .warm, .live, .finishing, .done:
            break
        }
    }

    /// Ends the press once the transcript looks settled (see the type's documentation).
    private func settleIfDone() async {
        guard phase == .finishing else { return }
        settleTimer?.cancel()
        settleTimer = nil
        guard !mapper.hasPendingInterim else { return }
        if turnCompleteAfterEnd {
            await shutDown(nil)
        } else if finalAfterEnd {
            let delay = options.settleDelay
            settleTimer = Task {
                do { try await Task.sleep(for: delay) } catch { return }
                await self.settleElapsed()
            }
        }
    }

    private func settleElapsed() async {
        guard phase == .finishing, !mapper.hasPendingInterim else { return }
        await shutDown(nil)
    }

    // MARK: - Timers

    private func setupTimedOut() async {
        guard !setupCompleted, phase != .done else { return }
        await shutDown(ProviderError(provider: provider, message: "Gemini did not finish setting up the speech session within \(options.setupTimeout)."))
    }

    /// Nothing was unsettled at key-up and Gemini has not sent a final since: the transcript is complete. Text that
    /// arrived after key-up is left to the settle and final timers.
    private func quietTimedOut() async {
        guard phase == .finishing, !finalAfterEnd, !mapper.hasPendingInterim else { return }
        await shutDown(nil)
    }

    private func finalTimedOut() async {
        guard phase == .finishing else { return }
        for event in mapper.promotePendingInterim() { continuation.yield(event) }
        await shutDown(nil)
    }

    // MARK: - Ending

    private func receiveFailed(_ error: Error) async {
        await connectionLost(error)
    }

    /// A failed write ends the session too: Gemini never got audio or a marker the press depends on.
    private func sendFailed(_ error: Error) async {
        await connectionLost(error)
    }

    private func connectionLost(_ error: Error) async {
        switch phase {
        case .done:
            return
        case .finishing where mapper.heardText:
            // The key is up and the transcript was coming in; keep what arrived rather than failing the press.
            for event in mapper.promotePendingInterim() { continuation.yield(event) }
            await shutDown(nil)
        default:
            await shutDown(closedError(error))
        }
    }

    /// What to report when the connection fails. The shared URLSession connector already turns a refused upgrade or a
    /// server close into a `ProviderError` with the HTTP status or the close code and reason (the Live API explains
    /// a bad key or model in that reason); this keeps that detail, labels it with the provider and says what it means.
    private func closedError(_ error: Error) -> ProviderError {
        let underlying = error as? ProviderError
        let detail = (underlying?.message ?? error.localizedDescription).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = underlying?.status
        if let timeLeft = goAwayTimeLeft {
            let when = timeLeft.map { " (it had \($0) left)" } ?? ""
            return ProviderError(provider: provider, status: status,
                                 message: "Gemini ended the speech session after announcing it would close\(when). \(detail)")
        }
        if !setupCompleted {
            return ProviderError(provider: provider, status: status,
                                 message: "Gemini closed the speech session before it was set up: \(detail) "
                                    + "Check the API key and that the model supports the Live API.")
        }
        return ProviderError(provider: provider, status: status, message: "The Gemini Live connection failed: \(detail)")
    }

    /// Ends the session once: stops the timers, drops unsent frames, closes the socket, then finishes `events` (with
    /// `error`, if any).
    func shutDown(_ error: Error?) async {
        guard phase != .done else { return }
        phase = .done
        resumeReadyWaiters(setupCompleted)
        for timer in [setupTimer, finalTimer, quietTimer, settleTimer] { timer?.cancel() }
        receiveTask?.cancel()
        outgoingQueue.finish()
        sendTask?.cancel()
        heldAudio.removeAll()
        await connection.close()
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// Transport failures while connecting, as ProviderErrors labelled with the provider.
    static func providerError(_ error: Error, provider: String) -> ProviderError {
        let underlying = error as? ProviderError
        return ProviderError(provider: provider, status: underlying?.status,
                             message: "Could not connect to the Gemini Live API: \(underlying?.message ?? error.localizedDescription)")
    }
}
