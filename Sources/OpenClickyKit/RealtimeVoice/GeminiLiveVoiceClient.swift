// The realtime-voice slot on the Gemini Live API with a native-audio model (gemini-3.8-live): mic audio streams in,
// Gemini's activity detection ends turns, the model answers aloud, calls tools and sees screenshots added to the
// conversation. Same socket and key as the stt slot's Gemini Live transcription. Wire details are in GeminiLiveVoiceWire.swift.

import Foundation

public struct GeminiLiveVoiceClient: RealtimeVoiceClient {
    public static let defaultModel = "gemini-3.8-live"
    public static let defaultVoice = "Kore"

    public struct Options: Sendable, Hashable {
        public var setupTimeout: Duration
        /// Force every tool to run blocking or non-blocking; nil keeps the model's default (non-blocking on 3.8).
        public var toolBehavior: ToolBehavior?
        /// Fold old context so the session outlives the ~15 minute (2 minute with pictures) limit.
        public var compressContext: Bool
        /// How screenshots reach the model (see GeminiLiveVoiceWire).
        public var imageDelivery: ImageDelivery
        /// `generationConfig.mediaResolution` for pictures: "MEDIA_RESOLUTION_LOW", "…_MEDIUM" or "…_HIGH"; nil leaves
        /// Gemini's default. gemini-3.8-live accepted HIGH in setup, but a tool-response screenshot cost 60 image tokens
        /// and read correctly either way, so the default is left alone.
        public var mediaResolution: String?

        public enum ToolBehavior: Sendable, Hashable { case blocking, nonBlocking }

        public enum ImageDelivery: Sendable, Hashable {
            /// Inline media in the `parts` of the tool response that follows (falls back to a conversation turn when
            /// no tool call is waiting).
            case toolResponseParts
            /// An `inlineData` part in a `clientContent` user turn: in the context at once.
            case conversationTurn
            /// A `realtimeInput.video` frame: joins the context with the user's next spoken turn.
            case videoFrame
        }

        public init(setupTimeout: Duration = .seconds(15), toolBehavior: ToolBehavior? = nil, compressContext: Bool = true,
                    imageDelivery: ImageDelivery = .toolResponseParts, mediaResolution: String? = nil) {
            self.mediaResolution = mediaResolution
            self.setupTimeout = setupTimeout
            self.toolBehavior = toolBehavior
            self.compressContext = compressContext
            self.imageDelivery = imageDelivery
        }
    }

    let context: ProviderContext
    public let model: String
    public let defaultVoice: String
    public let options: Options

    public init(context: ProviderContext, model: String = GeminiLiveVoiceClient.defaultModel, defaultVoice: String? = nil,
                options: Options = Options()) {
        self.context = context
        self.model = realtimeTrimmed(model) ?? Self.defaultModel
        self.defaultVoice = realtimeTrimmed(defaultVoice) ?? Self.defaultVoice
        self.options = options
    }

    public func connect(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession {
        let connection: any WebSocketConnection
        do {
            connection = try await context.webSocket.connect(makeRequest())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiLiveSession.providerError(error, provider: context.provider.id)
        }
        let behavior: GeminiLiveVoiceWire.Behavior? = options.toolBehavior.map { $0 == .blocking ? .blocking : .nonBlocking }
        let setup = GeminiLiveVoiceWire.setup(model: model, configuration: configuration,
                                              voice: realtimeTrimmed(configuration.voice) ?? defaultVoice,
                                              behavior: behavior, compressContext: options.compressContext,
                                              mediaResolution: options.mediaResolution)
        let session = GeminiLiveVoiceSession(connection: connection, provider: context.provider.id, model: model,
                                             turnDetection: configuration.turnDetection, imageDelivery: options.imageDelivery)
        try await session.open(setup: setup, timeout: options.setupTimeout)
        return session
    }

    /// The upgrade request, with the key in the `x-goog-api-key` header (never the URL).
    func makeRequest() -> URLRequest {
        var request = URLRequest(url: GeminiLiveWire.endpoint(base: context.provider.baseURL))
        for (name, value) in context.provider.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        if let key = realtimeTrimmed(context.apiKey) { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        return request
    }
}

extension GeminiLiveVoiceClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "GeminiLiveVoiceClient(provider: \(context.provider.id), model: \(model), apiKey: \(context.apiKey?.isEmpty == false ? "set" : "none"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "voice": defaultVoice], displayStyle: .struct)
    }
}

/// One Gemini Live native-audio conversation.
///
/// Gemini has no item ids, so each model turn gets one (`gemini-turn-N`) and each user turn one (`gemini-user-N`).
/// Gemini also has no "cancel": `interrupt` drops the rest of the current turn on this side (the user has already
/// stopped hearing it) and reports it cancelled; with activity detection on, the server stops the turn itself as soon as
/// it hears the user.
actor GeminiLiveVoiceSession: RealtimeVoiceSession {
    nonisolated let events: AsyncThrowingStream<RealtimeVoiceEvent, Error>
    private let continuation: AsyncThrowingStream<RealtimeVoiceEvent, Error>.Continuation
    nonisolated let inputFormat = GeminiLiveVoiceWire.inputFormat
    nonisolated let outputFormat = GeminiLiveVoiceWire.outputFormat
    nonisolated let features = RealtimeFeatures(imageInput: true, truncatesToHeardAudio: false, deletesItems: false, updatesInstructions: false)
    nonisolated let model: String

    private let pump: RealtimeSocketPump
    private let provider: String
    private let turnDetection: RealtimeTurnDetection
    private let imageDelivery: GeminiLiveVoiceClient.Options.ImageDelivery
    private let ready = RealtimeReadySignal()
    private var isReady = false
    private var closed = false
    private var goAwayTimeLeft: Duration??

    private var turnCounter = 0
    private var turn: RealtimeResponseSummary?
    /// A turn the app interrupted: its remaining parts are dropped until Gemini ends it.
    private var discardingTurn = false
    private var userCounter = 0
    private var userItem: String?
    private var userText = ""
    private var userInterim = ""
    private var userCommitted = false
    private var userSpeaking = false
    /// Gemini reports activity start and end, so a user turn begins at speech, not at its first transcript.
    private var sawVoiceActivity = false
    /// The last settled user turn, for transcript text that arrives after it was settled.
    private var lastUser: (item: String, text: String)?
    private var activityOpen = false
    private var aligner = PCMFrameAligner(frameSize: 2)
    private var usage: RealtimeUsage?
    private var outstandingCalls: Set<String> = []
    /// Screenshots waiting to ride along with the next tool response.
    private var pendingImages: [RealtimeImage] = []

    init(connection: any WebSocketConnection, provider: String, model: String, turnDetection: RealtimeTurnDetection,
         imageDelivery: GeminiLiveVoiceClient.Options.ImageDelivery = .toolResponseParts) {
        self.imageDelivery = imageDelivery
        (events, continuation) = AsyncThrowingStream<RealtimeVoiceEvent, Error>.makeStream()
        pump = RealtimeSocketPump(connection: connection)
        self.provider = provider
        self.model = model
        self.turnDetection = turnDetection
    }

    func open(setup: JSONValue, timeout: Duration) async throws {
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.close() }
        }
        pump.start(onMessage: { [weak self] message in await self?.receive(message) },
                   onFailure: { [weak self] error in await self?.socketFailed(error) })
        pump.send(setup)
        let provider = provider
        do {
            try await ready.wait(timeout: timeout, timeoutError: ProviderError(
                provider: provider, message: "Gemini did not finish setting up the voice session within \(timeout)."))
        } catch {
            await shutDown(nil)
            throw error
        }
    }

    private var isManual: Bool { turnDetection == .manual }

    // MARK: - RealtimeVoiceSession

    func sendAudio(_ pcm: Data) async {
        guard isReady, !closed, !pcm.isEmpty else { return }
        if isManual, !activityOpen {
            pump.send(["realtimeInput": ["activityStart": [:]]])
            activityOpen = true
        }
        for chunk in realtimeAudioChunks(pcm, maxBytes: GeminiLiveVoiceWire.maxAudioChunkBytes) {
            pump.send(GeminiLiveVoiceWire.audio(chunk))
        }
    }

    func endAudioTurn() async {
        guard isReady, !closed else { return }
        if isManual {
            guard activityOpen else { return }
            pump.send(["realtimeInput": ["activityEnd": [:]]])
            activityOpen = false
        } else {
            pump.send(GeminiLiveVoiceWire.audioStreamEnd)
        }
    }

    func clearAudio() async {}

    func addText(_ text: String, respond: Bool) async {
        guard isReady, !closed else { return }
        pump.send(GeminiLiveVoiceWire.userText(text, turnComplete: respond))
    }

    func addImage(_ data: Data, mimeType: String, caption: String?) async {
        guard isReady, !closed, !data.isEmpty else { return }
        switch imageDelivery {
        case .toolResponseParts where !outstandingCalls.isEmpty:
            pendingImages.append(RealtimeImage(data: data, mimeType: mimeType, caption: caption))
        case .toolResponseParts, .conversationTurn:
            pump.send(GeminiLiveVoiceWire.imageTurn(data, mimeType: mimeType, caption: caption))
        case .videoFrame:
            pump.send(GeminiLiveVoiceWire.videoFrame(data, mimeType: mimeType))
            if let caption = realtimeTrimmed(caption) { pump.send(GeminiLiveVoiceWire.userText(caption, turnComplete: false)) }
        }
    }

    func sendToolResult(_ result: RealtimeToolResult) async {
        guard isReady, !closed else { return }
        // A call Gemini already withdrew needs no answer, and an answer to it would be refused. A screenshot taken for
        // it is dropped too, so it can't ride along with some later, unrelated tool response.
        guard outstandingCalls.remove(result.callID) != nil else {
            pendingImages.removeAll()
            return
        }
        let images = result.respond ? pendingImages : []
        pendingImages.removeAll()
        pump.send(GeminiLiveVoiceWire.toolResponse(result, scheduling: result.respond ? .whenIdle : .silent, images: images))
    }

    func createResponse(instructions: String?) async {
        guard isReady, !closed else { return }
        if let instructions = realtimeTrimmed(instructions) {
            pump.send(GeminiLiveVoiceWire.userText(instructions, turnComplete: true))
        } else {
            pump.send(GeminiLiveVoiceWire.turnComplete)
        }
    }

    func interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool) async {
        guard isReady, !closed, var summary = turn else { return }
        summary.status = .cancelled
        turn = nil
        discardingTurn = true
        continuation.yield(.responseFinished(summary))
    }

    func discardUserTurn(itemID: String) async {}

    func updateInstructions(_ instructions: String) async {
        guard isReady, !closed else { return }
        // A Live session's system instruction is fixed at setup; the nearest thing is a note in the conversation.
        pump.send(GeminiLiveVoiceWire.userText("[App] From now on: \(instructions)", turnComplete: false))
    }

    func close() async { await shutDown(nil) }

    // MARK: - Server messages

    private func receive(_ message: WebSocketMessage) async {
        guard !closed, let json = RealtimeSocketPump.json(message) else { return }
        if let error = json["error"] {
            let (status, text) = GeminiLiveWire.errorMessage(error)
            let failure = ProviderError(provider: provider, status: status, message: "Gemini Live rejected the voice session: \(text)")
            if !isReady { await ready.fail(failure) }
            await shutDown(failure)
            return
        }
        if json["setupComplete"] != nil, !isReady {
            isReady = true
            await ready.succeed()
        }
        if let metadata = json["usageMetadata"] { usage = GeminiLiveVoiceWire.usage(metadata) ?? usage }
        if let goAway = json["goAway"] {
            let timeLeft = GeminiLiveWire.duration(goAway["timeLeft"])
            goAwayTimeLeft = .some(timeLeft)
            continuation.yield(.goingAway(timeLeft: timeLeft))
        }
        if let update = json["sessionResumptionUpdate"], update["resumable"]?.boolValue != false,
           let handle = realtimeTrimmed(update["newHandle"]?.stringValue) {
            continuation.yield(.resumable(handle: handle))
        }
        if let activity = json["voiceActivity"] { voiceActivity(activity) }
        if let calls = json["toolCall"]?["functionCalls"]?.arrayValue { toolCalls(calls) }
        if let ids = json["toolCallCancellation"]?["ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty {
            ids.forEach { outstandingCalls.remove($0) }
            if outstandingCalls.isEmpty { pendingImages.removeAll() }
            continuation.yield(.toolCallsCancelled(ids))
        }
        if let content = json["serverContent"] { serverContent(content) }
    }

    private func voiceActivity(_ activity: JSONValue) {
        let kind = (activity["voiceActivityType"]?.stringValue ?? activity["type"]?.stringValue ?? "").uppercased()
        if kind.contains("START") {
            sawVoiceActivity = true
            userStartedSpeaking()
            openUserTurnIfNeeded()
        }
        if kind.contains("END"), userSpeaking {
            userSpeaking = false
            continuation.yield(.userSpeechStopped)
        }
    }

    private func userStartedSpeaking() {
        guard !userSpeaking else { return }
        userSpeaking = true
        continuation.yield(.userSpeechStarted)
    }

    private func serverContent(_ content: JSONValue) {
        if let text = content["inputTranscription"]?["text"]?.stringValue, !text.isEmpty {
            // Input transcription has no ordering guarantee. When Gemini marks speech, text with no turn open belongs to
            // the turn just settled, not to a new one (which would supersede tools still running for it).
            if userItem == nil, sawVoiceActivity, var last = lastUser {
                last.text += text
                lastUser = last
                continuation.yield(.userTranscript(text: last.text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: true,
                                                   itemID: last.item))
                return
            }
            openUserTurnIfNeeded()
            userText += text
            userInterim = ""
            continuation.yield(.userTranscript(text: userCaption, isFinal: false, itemID: userItem))
        }
        if let text = content["interimInputTranscription"]?["text"]?.stringValue, !text.isEmpty {
            openUserTurnIfNeeded()
            userInterim = text
            continuation.yield(.userTranscript(text: userCaption, isFinal: false, itemID: userItem))
        }
        for part in content["modelTurn"]?["parts"]?.arrayValue ?? [] {
            guard let inline = part["inlineData"], let mime = inline["mimeType"]?.stringValue, mime.hasPrefix("audio/"),
                  let base64 = inline["data"]?.stringValue, let data = Data(base64Encoded: base64) else { continue }
            guard !discardingTurn else { continue }
            let itemID = audioItem()
            let whole = aligner.push(data)
            if !whole.isEmpty { continuation.yield(.audio(whole, itemID: itemID)) }
        }
        if let text = content["outputTranscription"]?["text"]?.stringValue, !text.isEmpty, !discardingTurn {
            let itemID = audioItem()
            turn?.transcript += text
            continuation.yield(.assistantTranscriptDelta(text, itemID: itemID))
        }
        if content["interrupted"]?.boolValue == true {
            // The server heard the user over the reply and dropped the rest of it.
            userStartedSpeaking()
            finishTurn(discardingTurn ? .cancelled : .interrupted)
        }
        if content["turnComplete"]?.boolValue == true {
            finishTurn(discardingTurn ? .cancelled : .completed)
            settleUserTurn()
        }
    }

    private var userCaption: String {
        (userText + userInterim).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openUserTurnIfNeeded() {
        guard userItem == nil else { return }
        userCounter += 1
        userItem = "gemini-user-\(userCounter)"
        userCommitted = false
    }

    /// The model is answering, so the user's turn has ended: say so once.
    private func commitUserTurnIfNeeded() {
        if userSpeaking {
            userSpeaking = false
            continuation.yield(.userSpeechStopped)
        }
        guard let item = userItem, !userCommitted else { return }
        userCommitted = true
        continuation.yield(.userTurnCommitted(itemID: item))
    }

    /// Input transcription can trail the reply, so the user's caption is final only once the turn is complete.
    private func settleUserTurn() {
        guard let item = userItem else { return }
        if !userCommitted { continuation.yield(.userTurnCommitted(itemID: item)) }
        continuation.yield(.userTranscript(text: userCaption, isFinal: true, itemID: item))
        lastUser = (item, userText + userInterim)
        userItem = nil
        userText = ""
        userInterim = ""
        userCommitted = false
    }

    /// Opens a model turn if none is open and returns its id (also the id of its one audio item).
    @discardableResult
    private func startTurnIfNeeded() -> String {
        if let turn { return turn.responseID }
        commitUserTurnIfNeeded()
        turnCounter += 1
        let id = "gemini-turn-\(turnCounter)"
        turn = RealtimeResponseSummary(responseID: id, status: .completed)
        aligner = PCMFrameAligner(frameSize: 2)
        continuation.yield(.responseStarted(responseID: id))
        return id
    }

    /// The turn's audio item, listed in its summary once it actually carries speech.
    private func audioItem() -> String {
        let id = startTurnIfNeeded()
        if turn?.itemIDs.isEmpty == true { turn?.itemIDs = [id] }
        return id
    }

    private func toolCalls(_ calls: [JSONValue]) {
        guard !calls.isEmpty else { return }
        if !discardingTurn { startTurnIfNeeded() }
        for (index, call) in calls.enumerated() {
            guard let name = call["name"]?.stringValue else { continue }
            let id = call["id"]?.stringValue ?? "gemini-call-\(turnCounter)-\(index)"
            if discardingTurn {
                // The user stopped this reply (Escape, barge-in) and Gemini can't be told to drop it, so a call it
                // makes afterwards would otherwise run (opening a link, playing music) after the user said stop.
                // Answer it here, silently, and never hand it to the app.
                let result = RealtimeToolResult(callID: id, name: name, output: [
                    "status": "cancelled", "message": "The user stopped this reply, so this did not run. Don't bring it up.",
                ], respond: false)
                pump.send(GeminiLiveVoiceWire.toolResponse(result, scheduling: .silent))
                continue
            }
            let arguments = call["args"].map { $0.objectValue == nil ? "{}" : $0.jsonString() } ?? "{}"
            let toolCall = RealtimeToolCall(callID: id, name: name, arguments: arguments)
            outstandingCalls.insert(id)
            turn?.toolCalls.append(toolCall)
            continuation.yield(.toolCall(toolCall))
        }
    }

    private func finishTurn(_ status: RealtimeResponseStatus) {
        discardingTurn = false
        guard var summary = turn else { return }
        turn = nil
        summary.status = status
        summary.usage = usage
        usage = nil
        continuation.yield(.responseFinished(summary))
    }

    // MARK: - Ending

    private func socketFailed(_ error: Error) async {
        let underlying = (error as? ProviderError)?.message ?? error.localizedDescription
        let status = (error as? ProviderError)?.status
        let failure: ProviderError
        if !isReady {
            failure = ProviderError(provider: provider, status: status,
                                    message: "Gemini closed the voice session before it was set up: \(underlying) "
                                        + "Check the API key and that the model is a Live native-audio model.")
            await ready.fail(failure)
        } else if let timeLeft = goAwayTimeLeft {
            failure = ProviderError(provider: provider, status: status,
                                    message: "Gemini ended the voice session after announcing it would close"
                                        + "\(timeLeft.map { " (it had \($0) left)" } ?? ""). \(underlying)")
        } else {
            failure = ProviderError(provider: provider, status: status, message: "The Gemini Live connection failed: \(underlying)")
        }
        await shutDown(failure)
    }

    private func shutDown(_ error: Error?) async {
        guard !closed else { return }
        closed = true
        await pump.close()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
