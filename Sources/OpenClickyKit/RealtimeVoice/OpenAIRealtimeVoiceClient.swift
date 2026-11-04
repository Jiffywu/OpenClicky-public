// The realtime-voice slot on the OpenAI Realtime API (GA) over WebSocket, the way HeyClicky's "full voice" runs
// gpt-realtime-2.1: mic audio streams in, server VAD ends turns, the model answers aloud, calls tools and can be shown
// screenshots. Wire details and doc links are in OpenAIRealtimeVoiceWire.swift. No OpenAI key was available while
// this was written, so it is checked only against fake sockets (Tests/OpenClickyKitTests/RealtimeVoiceOpenAITests.swift).

import Foundation

public struct OpenAIRealtimeVoiceClient: RealtimeVoiceClient {
    public static let defaultModel = "gpt-realtime-2.1"
    public static let defaultVoice = "cedar"
    /// The input transcription model (`gpt-4o-mini-transcribe` is retired on 2027-02-26).
    public static let defaultTranscriptionModel = "gpt-transcribe"

    public struct Options: Sendable, Hashable {
        /// How long the server may take to accept `session.update`.
        public var setupTimeout: Duration
        public var transcriptionModel: String

        public init(setupTimeout: Duration = .seconds(10), transcriptionModel: String = OpenAIRealtimeVoiceClient.defaultTranscriptionModel) {
            self.setupTimeout = setupTimeout
            self.transcriptionModel = transcriptionModel
        }
    }

    let context: ProviderContext
    public let model: String
    public let defaultVoice: String
    public let options: Options

    public init(context: ProviderContext, model: String = OpenAIRealtimeVoiceClient.defaultModel,
                defaultVoice: String? = nil, options: Options = Options()) {
        self.context = context
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
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
            throw ProviderError(provider: context.provider.id, status: (error as? ProviderError)?.status,
                                message: "Could not connect to the OpenAI Realtime API: \((error as? ProviderError)?.message ?? error.localizedDescription)")
        }
        let session = OpenAIRealtimeVoiceSession(connection: connection, provider: context.provider.id, model: model,
                                                 configuration: configuration)
        let voice = realtimeTrimmed(configuration.voice) ?? defaultVoice
        try await session.open(update: OpenAIRealtimeVoiceWire.sessionUpdate(configuration, voice: voice,
                                                                             transcriptionModel: options.transcriptionModel),
                               timeout: options.setupTimeout)
        return session
    }

    /// The upgrade request: `wss://…/realtime?model=`, provider headers, then the bearer key (never in the URL).
    func makeRequest() -> URLRequest {
        var request = URLRequest(url: OpenAIRealtimeWire.endpoint(base: context.provider.baseURL, model: model))
        for (name, value) in ProviderContext.mergedHeaders(provider: context.provider.headers ?? [:], adapter: [:]) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let key = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

extension OpenAIRealtimeVoiceClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenAIRealtimeVoiceClient(provider: \(context.provider.id), model: \(model), apiKey: \(context.apiKey?.isEmpty == false ? "set" : "none"))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "voice": defaultVoice], displayStyle: .struct)
    }
}

/// One OpenAI Realtime conversation.
actor OpenAIRealtimeVoiceSession: RealtimeVoiceSession {
    nonisolated let events: AsyncThrowingStream<RealtimeVoiceEvent, Error>
    private let continuation: AsyncThrowingStream<RealtimeVoiceEvent, Error>.Continuation
    nonisolated let inputFormat = PCMFormat.speech24k
    nonisolated let outputFormat = PCMFormat.speech24k
    nonisolated let features = RealtimeFeatures(imageInput: true, truncatesToHeardAudio: true, deletesItems: true, updatesInstructions: true)
    nonisolated let model: String

    private let pump: RealtimeSocketPump
    private let provider: String
    private let configuration: RealtimeSessionConfiguration
    private let ready = RealtimeReadySignal()
    private var isReady = false
    private var closed = false

    // Reply state.
    private var responseInFlight: String?
    private var responseRequested = false
    private var current: RealtimeResponseSummary?
    /// Tool calls the model made that have no answer yet.
    private var outstandingCalls: Set<String> = []
    private var seenCalls: Set<String> = []
    /// An answer with `respond` arrived since the last `response.create`.
    private var answersWaitingForReply = false
    private var aligner = PCMFrameAligner(frameSize: 2)
    private var alignerItem: String?
    /// Bytes of audio received per assistant item, so truncation never points past the end.
    private var audioBytes: [String: Int] = [:]
    private var userTranscripts: [String: String] = [:]
    private var latestImageItem: String?
    private var imageCounter = 0
    /// Replies the app cancelled (barge-in, Escape, a dropped echo turn). Calls they still deliver are not handed to
    /// the app: they would run (open a link, play music) after the user said stop.
    private var cancelledResponses: Set<String> = []
    /// A cancel went out before the requested reply was created; the next `response.created` is that reply.
    private var cancelNextCreated = false

    init(connection: any WebSocketConnection, provider: String, model: String, configuration: RealtimeSessionConfiguration) {
        (events, continuation) = AsyncThrowingStream<RealtimeVoiceEvent, Error>.makeStream()
        pump = RealtimeSocketPump(connection: connection)
        self.provider = provider
        self.model = model
        self.configuration = configuration
    }

    /// Starts the socket loops, sends the session configuration and waits for `session.updated`.
    func open(update: JSONValue, timeout: Duration) async throws {
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.close() }
        }
        pump.start(onMessage: { [weak self] message in await self?.receive(message) },
                   onFailure: { [weak self] error in await self?.socketFailed(error) })
        pump.send(update)
        let provider = provider
        do {
            try await ready.wait(timeout: timeout, timeoutError: ProviderError(
                provider: provider, message: "The OpenAI Realtime API did not accept the session within \(timeout)."))
        } catch {
            await shutDown(nil)
            throw error
        }
    }

    // MARK: - RealtimeVoiceSession

    func sendAudio(_ pcm: Data) async {
        guard isReady, !closed, !pcm.isEmpty else { return }
        for chunk in realtimeAudioChunks(pcm, maxBytes: OpenAIRealtimeVoiceWire.maxAudioChunkBytes) {
            pump.send(OpenAIRealtimeVoiceWire.appendAudio(chunk))
        }
    }

    func endAudioTurn() async {
        guard isReady, !closed else { return }
        switch configuration.turnDetection {
        case .manual:
            pump.send(OpenAIRealtimeVoiceWire.commitAudio)
            requestResponse(instructions: nil)
        case .serverVAD(let vad):
            // The server ends turns itself; a commit here would race it. Without auto replies, ask for one.
            if !vad.autoRespond {
                pump.send(OpenAIRealtimeVoiceWire.commitAudio)
                requestResponse(instructions: nil)
            }
        }
    }

    func clearAudio() async {
        guard isReady, !closed else { return }
        pump.send(OpenAIRealtimeVoiceWire.clearAudio)
    }

    func addText(_ text: String, respond: Bool) async {
        guard isReady, !closed else { return }
        pump.send(OpenAIRealtimeVoiceWire.userText(text))
        if respond { requestResponse(instructions: nil) }
    }

    func addImage(_ data: Data, mimeType: String, caption: String?) async {
        guard isReady, !closed, !data.isEmpty else { return }
        imageCounter += 1
        let itemID = "ocimg_\(imageCounter)_\(UInt32.random(in: 0...UInt32.max))"
        pump.send(OpenAIRealtimeVoiceWire.userImage(itemID: itemID, data: data, mimeType: mimeType, caption: caption))
        // Keep only the latest screenshot in the conversation: older ones cost tokens and confuse "what's on screen".
        if let previous = latestImageItem { pump.send(OpenAIRealtimeVoiceWire.deleteItem(previous)) }
        latestImageItem = itemID
    }

    func sendToolResult(_ result: RealtimeToolResult) async {
        guard isReady, !closed else { return }
        pump.send(OpenAIRealtimeVoiceWire.functionOutput(result))
        outstandingCalls.remove(result.callID)
        if result.respond { answersWaitingForReply = true }
        replyToAnswersIfDue()
    }

    func createResponse(instructions: String?) async {
        guard isReady, !closed else { return }
        requestResponse(instructions: instructions)
    }

    func interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool) async {
        guard isReady, !closed else { return }
        cancelReplyInFlight()
        if clearInput { pump.send(OpenAIRealtimeVoiceWire.clearAudio) }
        if let itemID, let heard {
            let receivedMilliseconds = (audioBytes[itemID] ?? 0) * 1_000 / outputFormat.bytesPerSecond
            let milliseconds = min(Int((max(heard, 0) * 1_000).rounded(.down)), receivedMilliseconds)
            pump.send(OpenAIRealtimeVoiceWire.truncate(itemID: itemID, audioEndMilliseconds: milliseconds))
        }
    }

    func discardUserTurn(itemID: String) async {
        guard isReady, !closed else { return }
        cancelReplyInFlight()
        pump.send(OpenAIRealtimeVoiceWire.deleteItem(itemID))
        userTranscripts[itemID] = nil
    }

    func updateInstructions(_ instructions: String) async {
        guard isReady, !closed else { return }
        pump.send(OpenAIRealtimeVoiceWire.instructionsUpdate(instructions))
    }

    func close() async {
        await shutDown(nil)
    }

    // MARK: - Replies

    /// Sends `response.cancel` when a reply is running or requested, and remembers that reply as cancelled.
    private func cancelReplyInFlight() {
        guard responseInFlight != nil || responseRequested else { return }
        pump.send(OpenAIRealtimeVoiceWire.responseCancel)
        if let id = responseInFlight { cancelledResponses.insert(id) } else { cancelNextCreated = true }
        responseRequested = false
    }

    private func requestResponse(instructions: String?) {
        pump.send(OpenAIRealtimeVoiceWire.responseCreate(instructions: instructions))
        responseRequested = true
        answersWaitingForReply = false
    }

    /// Once every call of a reply has its answer, ask for the next reply, but never while one is still running.
    private func replyToAnswersIfDue() {
        guard answersWaitingForReply, outstandingCalls.isEmpty, responseInFlight == nil, !responseRequested else { return }
        requestResponse(instructions: nil)
    }

    // MARK: - Server events

    private func receive(_ message: WebSocketMessage) async {
        guard !closed, let event = RealtimeSocketPump.json(message), let type = event["type"]?.stringValue else { return }
        switch type {
        case "session.updated":
            if !isReady {
                isReady = true
                await ready.succeed()
            }
        case "error":
            await handleError(event)
        case "input_audio_buffer.speech_started":
            continuation.yield(.userSpeechStarted)
        case "input_audio_buffer.speech_stopped":
            continuation.yield(.userSpeechStopped)
        case "input_audio_buffer.committed":
            continuation.yield(.userTurnCommitted(itemID: event["item_id"]?.stringValue))
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event["item_id"]?.stringValue, let delta = event["delta"]?.stringValue else { return }
            let text = (userTranscripts[itemID] ?? "") + delta
            userTranscripts[itemID] = text
            continuation.yield(.userTranscript(text: text, isFinal: false, itemID: itemID))
        case "conversation.item.input_audio_transcription.completed":
            let itemID = event["item_id"]?.stringValue
            let text = event["transcript"]?.stringValue ?? itemID.flatMap { userTranscripts[$0] } ?? ""
            if let itemID { userTranscripts[itemID] = nil }
            continuation.yield(.userTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: true, itemID: itemID))
        case "conversation.item.input_audio_transcription.failed":
            let reason = event["error"]?["message"]?.stringValue ?? "unknown reason"
            continuation.yield(.warning("Input transcription failed: \(reason)"))
        case "response.created":
            let id = event["response"]?["id"]?.stringValue ?? "response"
            responseInFlight = id
            responseRequested = false
            if cancelNextCreated {
                cancelNextCreated = false
                cancelledResponses.insert(id)
            }
            current = RealtimeResponseSummary(responseID: id, status: .completed)
            continuation.yield(.responseStarted(responseID: id))
        case "response.output_audio.delta", "response.audio.delta":
            audioDelta(event)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = event["delta"]?.stringValue, let itemID = event["item_id"]?.stringValue else { return }
            current?.transcript += delta
            noteItem(itemID)
            continuation.yield(.assistantTranscriptDelta(delta, itemID: itemID))
        case "response.function_call_arguments.done":
            toolCall(callID: event["call_id"]?.stringValue, name: event["name"]?.stringValue, arguments: event["arguments"]?.stringValue,
                     responseID: event["response_id"]?.stringValue)
        case "response.output_item.done":
            functionCallItem(event["item"], responseID: event["response_id"]?.stringValue)
        case "response.done":
            responseDone(event["response"])
        default:
            break
        }
    }

    private func audioDelta(_ event: JSONValue) {
        guard let base64 = event["delta"]?.stringValue, let data = Data(base64Encoded: base64),
              let itemID = event["item_id"]?.stringValue else { return }
        if alignerItem != itemID {
            aligner = PCMFrameAligner(frameSize: 2)
            alignerItem = itemID
        }
        let whole = aligner.push(data)
        guard !whole.isEmpty else { return }
        audioBytes[itemID, default: 0] += whole.count
        noteItem(itemID)
        continuation.yield(.audio(whole, itemID: itemID))
    }

    private func noteItem(_ itemID: String) {
        if current?.itemIDs.contains(itemID) == false { current?.itemIDs.append(itemID) }
    }

    private func functionCallItem(_ item: JSONValue?, responseID: String?) {
        guard item?["type"]?.stringValue == "function_call" else { return }
        // A call the model never finished writing (its reply was cut off) is not a request.
        if let status = item?["status"]?.stringValue, status != "completed" { return }
        toolCall(callID: item?["call_id"]?.stringValue, name: item?["name"]?.stringValue, arguments: item?["arguments"]?.stringValue,
                 responseID: responseID)
    }

    private func toolCall(callID: String?, name: String?, arguments: String?, responseID: String?) {
        guard let callID, let name, seenCalls.insert(callID).inserted else { return }
        if let reply = responseID ?? responseInFlight, cancelledResponses.contains(reply) { return }
        let call = RealtimeToolCall(callID: callID, name: name, arguments: arguments ?? "{}")
        outstandingCalls.insert(callID)
        current?.toolCalls.append(call)
        continuation.yield(.toolCall(call))
    }

    private func responseDone(_ response: JSONValue?) {
        // Calls the streaming events missed are still in the final output list.
        let responseID = response?["id"]?.stringValue
        for item in response?["output"]?.arrayValue ?? [] { functionCallItem(item, responseID: responseID) }
        var summary = current ?? RealtimeResponseSummary(responseID: response?["id"]?.stringValue ?? "response", status: .completed)
        summary.status = OpenAIRealtimeVoiceWire.status(of: response)
        summary.usage = OpenAIRealtimeVoiceWire.usage(of: response)
        if summary.status == .failed || summary.status == .incomplete {
            let details = response?["status_details"]
            summary.detail = details?["error"]?["message"]?.stringValue ?? details?["reason"]?.stringValue
        }
        current = nil
        responseInFlight = nil
        if let responseID { cancelledResponses.remove(responseID) }
        continuation.yield(.responseFinished(summary))
        replyToAnswersIfDue()
    }

    private func handleError(_ event: JSONValue) async {
        let error = OpenAIRealtimeServerError(event: event)
        if !isReady {
            await ready.fail(ProviderError(provider: provider, message: "The OpenAI Realtime API rejected the session: \(error.code.map { "\($0): " } ?? "")\(error.message)"))
            return
        }
        if let code = error.code, OpenAIRealtimeVoiceWire.harmlessErrorCodes.contains(code) { return }
        continuation.yield(.warning(error.code.map { "\($0): \(error.message)" } ?? error.message))
    }

    // MARK: - Ending

    private func socketFailed(_ error: Error) async {
        let underlying = (error as? ProviderError)?.message ?? error.localizedDescription
        let failure = ProviderError(provider: provider, status: (error as? ProviderError)?.status,
                                    message: "The OpenAI Realtime connection closed: \(underlying)")
        if !isReady { await ready.fail(failure) }
        await shutDown(failure)
    }

    private func shutDown(_ error: Error?) async {
        guard !closed else { return }
        closed = true
        await pump.close()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
