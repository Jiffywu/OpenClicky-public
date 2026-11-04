import Foundation

/// What the user sees of an always-on conversation (notch state, captions, tool status).
public enum RealtimeVoiceState: String, Sendable, Hashable {
    case listening
    case userSpeaking = "user_speaking"
    case thinking
    case speaking
    case ended
}

public struct RealtimeTranscriptLine: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable { case user, assistant, tool }
    public var role: Role
    public var text: String
    /// For assistant lines: how the reply ended ("completed", "interrupted", …).
    public var note: String?

    public init(role: Role, text: String, note: String? = nil) {
        self.role = role
        self.text = text
        self.note = note
    }
}

public enum RealtimeConversationUpdate: Sendable, Hashable {
    case state(RealtimeVoiceState)
    /// The user's words so far this turn (replaces the previous caption).
    case userCaption(String, isFinal: Bool)
    /// What the assistant has said so far in the current reply.
    case assistantCaption(String)
    /// A tool's status label while it runs; nil clears it.
    case status(String?)
    case tool(RealtimeToolActivity)
    /// The user talked over the reply after hearing `heard` seconds of it.
    case bargeIn(heard: TimeInterval)
    /// A committed user turn was dropped as silence or echo.
    case discardedTurn(reason: String)
    case responseFinished(RealtimeResponseSummary)
    /// An action held until after the reply ran but did not work; the note went into the conversation.
    case deferredActionFailed(String)
    case warning(String)
    /// The session is over; the text says why when it failed.
    case ended(error: String?)
}

/// One always-on conversation: microphone audio goes in through the echo gate, the model's voice comes out through a
/// `RealtimeAudioOutput`, tool calls go to the dispatcher, and barge-in stops the voice and cuts the reply to what the
/// user heard. Runs headlessly with a recording output and audio from a file (`occtl realtime`), or with the mic and the
/// speech player in the app.
public actor RealtimeConversation {
    public struct Options: Sendable {
        public var route: AudioOutputRoute
        public var echo: RealtimeEchoGate.Settings
        /// Drop user turns that had no real speech (where the provider can delete items).
        public var discardSilentTurns: Bool

        public init(route: AudioOutputRoute = .headphones, echo: RealtimeEchoGate.Settings = .init(), discardSilentTurns: Bool = true) {
            self.route = route
            self.echo = echo
            self.discardSilentTurns = discardSilentTurns
        }
    }

    public nonisolated let updates: AsyncStream<RealtimeConversationUpdate>
    private let continuation: AsyncStream<RealtimeConversationUpdate>.Continuation
    public nonisolated let session: any RealtimeVoiceSession
    public nonisolated let output: any RealtimeAudioOutput
    public nonisolated let dispatcher: RealtimeToolDispatcher?
    private let clock: @Sendable () -> TimeInterval
    private let options: Options
    private var gate: RealtimeEchoGate

    private var state: RealtimeVoiceState = .listening
    private var interruptedItems: Set<String> = []
    private var currentResponse: String?
    private var assistantCaption = ""
    private var userWords = ""
    private var drainToken = 0
    private var responseHadAudio = false
    private var activityTask: Task<Void, Never>?
    private var ended = false
    private var lines: [RealtimeTranscriptLine] = []
    /// Where each committed user turn's line sits, so a transcript that arrives after the reply still lands before it.
    private var userLineIndex: [String: Int] = [:]
    /// The conversation so far: user turns, replies and tool calls, in order.
    public var transcript: [RealtimeTranscriptLine] { lines.filter { !$0.text.isEmpty } }

    /// A point in the conversation, so whoever takes it over later can be told what was said after it.
    public struct TranscriptMark: Sendable, Hashable {
        let count: Int
        /// Lines that had no words yet (a committed turn whose transcript was still on its way).
        let blank: Set<Int>
    }

    /// The conversation so far and a mark at its end, read together.
    public func transcriptSnapshot() -> (lines: [RealtimeTranscriptLine], mark: TranscriptMark) {
        (transcript, TranscriptMark(count: lines.count, blank: Set(lines.indices.filter { lines[$0].text.isEmpty })))
    }

    /// What was said after `mark`: new lines, and earlier turns whose words only arrived after it.
    public func transcript(since mark: TranscriptMark) -> [RealtimeTranscriptLine] {
        lines.indices.filter { $0 >= mark.count || mark.blank.contains($0) }.map { lines[$0] }.filter { !$0.text.isEmpty }
    }
    public private(set) var responses: [RealtimeResponseSummary] = []
    public private(set) var bargeIns = 0
    public private(set) var discardedTurns = 0
    /// The latest handle the provider gave for resuming this conversation in a new session (nil: none offered).
    public private(set) var resumptionHandle: String?
    private var goingAwayHandler: (@Sendable (Duration?) async -> Void)?

    public init(session: any RealtimeVoiceSession, output: any RealtimeAudioOutput, dispatcher: RealtimeToolDispatcher? = nil,
                options: Options = Options(), clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.session = session
        self.output = output
        self.dispatcher = dispatcher
        self.options = options
        self.clock = clock
        gate = RealtimeEchoGate(route: options.route, settings: options.echo)
        (updates, continuation) = AsyncStream<RealtimeConversationUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    /// Handles session events until the session ends. Returns the error that ended it, or nil after `close()`.
    @discardableResult
    public func run() async -> Error? {
        if let dispatcher, activityTask == nil {
            activityTask = Task { [weak self] in
                for await activity in dispatcher.activity { await self?.toolActivity(activity) }
            }
        }
        var failure: Error?
        do {
            for try await event in session.events { await handle(event) }
        } catch {
            failure = error
        }
        await finish(failure)
        return failure
    }

    // MARK: - Input

    /// Microphone audio in the session's `inputFormat`, captured at `time` (seconds on the conversation's clock).
    public func feedMicrophone(_ pcm: Data, at time: TimeInterval? = nil) async {
        guard !ended, !pcm.isEmpty else { return }
        if gate.assistantSpeaking, !output.isPlaying { gate.assistantStoppedSpeaking(at: time ?? clock()) }
        switch gate.process(pcm, format: session.inputFormat, at: time ?? clock()) {
        case .forward:
            await session.sendAudio(pcm)
        case .mute:
            await session.sendAudio(Data(count: pcm.count))
        case .bargeIn(let prefix):
            await bargeIn()
            await session.sendAudio(prefix + pcm)
        }
    }

    /// Escape: stop talking, drop the user's buffered audio and stop running tools.
    public func interrupt() async {
        guard !ended else { return }
        let (item, heard) = output.stop()
        gate.assistantStoppedSpeaking(at: clock())
        if let item { interruptedItems.insert(item) }
        await session.interrupt(itemID: item ?? currentAssistantItem, heard: item == nil ? nil : heard, clearInput: true)
        await dispatcher?.userTurnStarted()
        setState(.listening)
    }

    /// Adds a typed message or `[App]` note to the conversation.
    public func addText(_ text: String, respond: Bool) async {
        await session.addText(text, respond: respond)
    }

    public func close() async {
        await dispatcher?.cancelAll()
        _ = output.stop()
        await session.close()
    }

    public var currentState: RealtimeVoiceState { state }

    /// Where the voice is coming out now. It decides whether the echo gate mutes the mic while the voice plays.
    public var outputRoute: AudioOutputRoute { gate.route }

    /// The output device changed under a running conversation: from now on the echo gate follows the new route, so
    /// sound that moved to the speakers can't be heard back as the user (and moving to headphones stops muting).
    public func outputRouteChanged(to route: AudioOutputRoute) {
        gate.route = route
    }

    /// The same, with the gate settings tuned for the new route (nil keeps the current ones).
    public func outputRouteChanged(to route: AudioOutputRoute, echo: RealtimeEchoGate.Settings?) {
        gate.route = route
        if let echo { gate.settings = echo }
    }

    /// The echo gate's settings now.
    public var echoSettings: RealtimeEchoGate.Settings { gate.settings }

    /// Called (once per announcement, off the event loop) when the provider says it will close the session soon, so
    /// the owner can open a replacement before it does.
    public func setGoingAwayHandler(_ handler: (@Sendable (Duration?) async -> Void)?) {
        goingAwayHandler = handler
    }

    /// Nothing in flight: listening, no reply being prepared or played, no tool running. A good moment to change
    /// sessions without cutting anything off.
    public var isIdle: Bool {
        get async {
            guard !ended, state == .listening, currentResponse == nil, !output.isPlaying else { return false }
            if let dispatcher, await dispatcher.runningCount > 0 { return false }
            return true
        }
    }

    /// Whether the session has ended.
    public var hasEnded: Bool { ended }

    // MARK: - Session events

    private var currentAssistantItem: String?

    private func handle(_ event: RealtimeVoiceEvent) async {
        switch event {
        case .userSpeechStarted:
            // The provider heard the user over the reply (headphones, or the gate already opened): stop talking.
            if output.isPlaying { await bargeIn() }
            setState(.userSpeaking)
        case .userSpeechStopped:
            setState(.thinking)
        case .userTurnCommitted(let itemID):
            await committed(itemID)
        case .userTranscript(let text, let isFinal, let itemID):
            userWords = text
            continuation.yield(.userCaption(text, isFinal: isFinal))
            if let itemID, let index = userLineIndex[itemID] {
                lines[index].text = text
            } else if isFinal, !text.isEmpty {
                // A turn the provider never committed (or committed without an id): keep its words, in place from now on.
                if let itemID { userLineIndex[itemID] = lines.count }
                lines.append(RealtimeTranscriptLine(role: .user, text: text))
            }
        case .responseStarted(let id):
            currentResponse = id
            assistantCaption = ""
            responseHadAudio = false
            if state != .speaking { setState(.thinking) }
        case .audio(let pcm, let itemID):
            guard !interruptedItems.contains(itemID) else { return }
            if !gate.assistantSpeaking { gate.assistantStartedSpeaking(at: clock()) }
            currentAssistantItem = itemID
            responseHadAudio = true
            output.enqueue(pcm, format: session.outputFormat, itemID: itemID)
            setState(.speaking)
        case .assistantTranscriptDelta(let delta, let itemID):
            guard !interruptedItems.contains(itemID) else { return }
            assistantCaption += delta
            continuation.yield(.assistantCaption(assistantCaption))
        case .toolCall(let call):
            if let dispatcher {
                await dispatcher.handle(call, session: session, userWords: userWords)
            } else {
                await session.sendToolResult(RealtimeToolResult(callID: call.callID, name: call.name, output: [
                    "status": "not_implemented", "message": "No tools are available in this session.",
                ]))
            }
        case .toolCallsCancelled(let ids):
            await dispatcher?.withdraw(ids)
        case .responseFinished(let summary):
            await responseFinished(summary)
        case .goingAway(let timeLeft):
            continuation.yield(.warning("The provider will close this session\(timeLeft.map { " in \($0)" } ?? " soon")."))
            if let handler = goingAwayHandler { Task { await handler(timeLeft) } }
        case .resumable(let handle):
            resumptionHandle = handle
        case .warning(let text):
            continuation.yield(.warning(text))
        }
    }

    private func committed(_ itemID: String?) async {
        let decision = gate.evaluateCommit()
        if case .discard(let reason) = decision, options.discardSilentTurns, session.features.deletesItems, let itemID {
            discardedTurns += 1
            await session.discardUserTurn(itemID: itemID)
            continuation.yield(.discardedTurn(reason: reason))
            setState(.listening)
            return
        }
        // A real new turn: older tool results are now superseded and held actions dropped.
        await dispatcher?.userTurnStarted()
        if let itemID, userLineIndex[itemID] == nil {
            userLineIndex[itemID] = lines.count
            lines.append(RealtimeTranscriptLine(role: .user, text: userWords))
        }
        if state == .userSpeaking { setState(.thinking) }
    }

    private func responseFinished(_ summary: RealtimeResponseSummary) async {
        for item in summary.itemIDs { output.finishItem(item) }
        responses.append(summary)
        let text = summary.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(RealtimeTranscriptLine(role: .assistant, text: text,
                                                     note: summary.status == .completed ? nil : summary.status.rawValue))
        }
        for call in summary.toolCalls {
            lines.append(RealtimeTranscriptLine(role: .tool, text: "\(call.name)(\(call.arguments))"))
        }
        continuation.yield(.responseFinished(summary))
        if currentResponse == summary.responseID { currentResponse = nil }
        let hadAudio = responseHadAudio && summary.status == .completed
        drainToken += 1
        let token = drainToken
        let output = output
        Task { [weak self] in
            await output.waitUntilDrained()
            await self?.playbackDrained(token: token, ranDeferred: hadAudio)
        }
    }

    /// The reply has been heard in full: the mic may listen again and held actions run.
    private func playbackDrained(token: Int, ranDeferred: Bool) async {
        guard !ended, token == drainToken, !output.isPlaying else { return }
        gate.assistantStoppedSpeaking(at: clock())
        if currentResponse == nil, state == .speaking || state == .thinking { setState(.listening) }
        guard ranDeferred, let dispatcher else { return }
        for work in await dispatcher.takeDeferredWork() {
            if let note = await work.run() {
                continuation.yield(.deferredActionFailed(note))
                await session.addText(note, respond: false)
            }
        }
    }

    private func bargeIn() async {
        let (item, heard) = output.stop()
        gate.assistantStoppedSpeaking(at: clock())
        guard let item else { return }
        interruptedItems.insert(item)
        bargeIns += 1
        await session.interrupt(itemID: item, heard: heard, clearInput: false)
        continuation.yield(.bargeIn(heard: heard))
    }

    private func toolActivity(_ activity: RealtimeToolActivity) {
        continuation.yield(.tool(activity))
        switch activity {
        case .started(_, _, let label): continuation.yield(.status(label))
        case .finished, .superseded, .withdrawn, .limitReached, .refused: continuation.yield(.status(nil))
        }
    }

    private func setState(_ new: RealtimeVoiceState) {
        guard state != new, !ended else { return }
        state = new
        continuation.yield(.state(new))
    }

    private func finish(_ error: Error?) async {
        guard !ended else { return }
        setState(.ended)
        ended = true
        activityTask?.cancel()
        await dispatcher?.cancelAll()
        continuation.yield(.ended(error: error.map { String(describing: $0) }))
        continuation.finish()
    }
}
