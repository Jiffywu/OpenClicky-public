import Foundation

/// A realtime session driven by hand: tests push provider events with `emit`, and everything the app sends is recorded.
public final class FakeRealtimeVoiceSession: RealtimeVoiceSession, @unchecked Sendable {
    public enum Sent: Sendable, Hashable {
        case audio(bytes: Int, silent: Bool)
        case endAudioTurn
        case clearAudio
        case text(String, respond: Bool)
        case image(bytes: Int, mimeType: String, caption: String?)
        case toolResult(RealtimeToolResult)
        case createResponse(String?)
        case interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool)
        case discard(String)
        case instructions(String)
        case close
    }

    public let events: AsyncThrowingStream<RealtimeVoiceEvent, Error>
    private let continuation: AsyncThrowingStream<RealtimeVoiceEvent, Error>.Continuation
    public let inputFormat: PCMFormat
    public let outputFormat: PCMFormat
    public let features: RealtimeFeatures
    public let model: String
    private let lock = NSLock()
    private var log: [Sent] = []
    private var handler: (@Sendable (Sent, FakeRealtimeVoiceSession) -> Void)?

    public init(inputFormat: PCMFormat = .speech24k, outputFormat: PCMFormat = .speech24k, model: String = "fake-realtime",
                features: RealtimeFeatures = RealtimeFeatures(imageInput: true, truncatesToHeardAudio: true, deletesItems: true,
                                                              updatesInstructions: true)) {
        (events, continuation) = AsyncThrowingStream<RealtimeVoiceEvent, Error>.makeStream()
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.features = features
        self.model = model
    }

    /// Everything sent so far, in order.
    public var sent: [Sent] { lock.withLock { log } }
    public var toolResults: [RealtimeToolResult] { sent.compactMap { if case .toolResult(let r) = $0 { r } else { nil } } }
    public var sentAudioBytes: Int { sent.reduce(0) { if case .audio(let n, _) = $1 { $0 + n } else { $0 } } }
    public var sentSilentAudioBytes: Int { sent.reduce(0) { if case .audio(let n, true) = $1 { $0 + n } else { $0 } } }

    /// Runs after each send, so a test can answer like a server.
    public var onSend: (@Sendable (Sent, FakeRealtimeVoiceSession) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    public func emit(_ event: RealtimeVoiceEvent) { continuation.yield(event) }
    public func finish(throwing error: Error? = nil) {
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private func record(_ entry: Sent) {
        let handler = lock.withLock { () -> (@Sendable (Sent, FakeRealtimeVoiceSession) -> Void)? in
            log.append(entry)
            return self.handler
        }
        handler?(entry, self)
    }

    public func sendAudio(_ pcm: Data) async {
        record(.audio(bytes: pcm.count, silent: !pcm.contains { $0 != 0 }))
    }
    public func endAudioTurn() async { record(.endAudioTurn) }
    public func clearAudio() async { record(.clearAudio) }
    public func addText(_ text: String, respond: Bool) async { record(.text(text, respond: respond)) }
    public func addImage(_ data: Data, mimeType: String, caption: String?) async {
        record(.image(bytes: data.count, mimeType: mimeType, caption: caption))
    }
    public func sendToolResult(_ result: RealtimeToolResult) async { record(.toolResult(result)) }
    public func createResponse(instructions: String?) async { record(.createResponse(instructions)) }
    public func interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool) async {
        record(.interrupt(itemID: itemID, heard: heard, clearInput: clearInput))
    }
    public func discardUserTurn(itemID: String) async { record(.discard(itemID)) }
    public func updateInstructions(_ instructions: String) async { record(.instructions(instructions)) }
    public func close() async {
        record(.close)
        continuation.finish()
    }
}

/// A stand-in realtime "server" for the headless simulator (`occtl realtime --simulate`) and tests: it listens to the
/// audio with a simple energy detector, commits a turn after a pause, calls `capture_screen` once if that tool is
/// offered, then answers with a short synthetic tone and a transcript. No network, no key.
public struct SimulatedRealtimeVoiceClient: RealtimeVoiceClient {
    public let model = "simulated-realtime"
    public var replyText: String
    public var replySeconds: Double
    /// Replies used in order, one per response (then `replyText`), for scripted runs such as the welcome chat.
    public var replies: [String]

    public init(replyText: String = "I heard you. This is the simulated always-on voice answering.", replySeconds: Double = 1.2,
                replies: [String] = []) {
        self.replyText = replyText
        self.replySeconds = replySeconds
        self.replies = replies
    }

    public func connect(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession {
        let session = FakeRealtimeVoiceSession(model: model)
        let server = SimulatedRealtimeServer(session: session, configuration: configuration, replyText: replyText,
                                             replySeconds: replySeconds, replies: replies)
        session.onSend = { sent, _ in server.received(sent) }
        return session
    }
}

final class SimulatedRealtimeServer: @unchecked Sendable {
    private let session: FakeRealtimeVoiceSession
    private let configuration: RealtimeSessionConfiguration
    private let replyText: String
    private let replySeconds: Double
    private let lock = NSLock()
    private var speaking = false
    private var speech: TimeInterval = 0
    private var silence: TimeInterval = 0
    private var turn = 0
    private var waitingForTool: String?
    private var usedScreen = false
    private var replies: [String]
    private var textReplies = 0

    init(session: FakeRealtimeVoiceSession, configuration: RealtimeSessionConfiguration, replyText: String, replySeconds: Double,
         replies: [String] = []) {
        self.session = session
        self.configuration = configuration
        self.replyText = replyText
        self.replySeconds = replySeconds
        self.replies = replies
    }

    /// The next scripted reply, or the fixed one.
    private func nextReply() -> String {
        lock.withLock { replies.isEmpty ? replyText : replies.removeFirst() }
    }

    func received(_ sent: FakeRealtimeVoiceSession.Sent) {
        switch sent {
        case .audio(let bytes, let silent):
            listen(bytes: bytes, silent: silent)
        case .toolResult(let result):
            let due = lock.withLock { () -> Bool in
                guard waitingForTool == result.callID else { return false }
                waitingForTool = nil
                return result.respond
            }
            if due { reply(after: result) }
        case .endAudioTurn:
            if configuration.turnDetection == .manual { commit() }
        case .text(_, true), .createResponse:
            // A typed message or a note that asks for a reply gets one, like a server would give.
            let responseID = lock.withLock { () -> String in
                textReplies += 1
                return "sim-text-response-\(textReplies)"
            }
            session.emit(.responseStarted(responseID: responseID))
            speak(responseID: responseID, text: nextReply())
        default:
            break
        }
    }

    /// Energy only: the fake session records whether a chunk was all zeros, which is what the echo gate sends when it
    /// mutes, and what trailing silence in the simulator is. Anything else counts as speech.
    private func listen(bytes: Int, silent: Bool) {
        let seconds = Double(bytes) / Double(session.inputFormat.bytesPerSecond)
        let event: RealtimeVoiceEvent? = lock.withLock {
            if !silent {
                silence = 0
                speech += seconds
                if !speaking {
                    speaking = true
                    return .userSpeechStarted
                }
            } else if speaking {
                silence += seconds
                if silence >= 0.6 {
                    speaking = false
                    return .userSpeechStopped
                }
            }
            return nil
        }
        guard let event else { return }
        session.emit(event)
        if event == .userSpeechStopped, configuration.turnDetection != .manual { commit() }
    }

    private func commit() {
        let (item, heard) = lock.withLock { () -> (String, TimeInterval) in
            turn += 1
            defer { speech = 0 }
            return ("sim-user-\(turn)", speech)
        }
        session.emit(.userTurnCommitted(itemID: item))
        session.emit(.userTranscript(text: String(format: "(%.1f s of speech)", heard), isFinal: true, itemID: item))
        let responseID = "sim-response-\(turn)"
        let wantsScreen = configuration.tools.contains { $0.name == RealtimeToolName.captureScreen }
            && lock.withLock { !usedScreen }
        session.emit(.responseStarted(responseID: responseID))
        if wantsScreen {
            let call = RealtimeToolCall(callID: "sim-call-\(turn)", name: RealtimeToolName.captureScreen, arguments: "{}")
            lock.withLock {
                usedScreen = true
                waitingForTool = call.callID
            }
            session.emit(.toolCall(call))
            session.emit(.responseFinished(RealtimeResponseSummary(responseID: responseID, status: .completed, toolCalls: [call])))
        } else {
            speak(responseID: responseID, text: nextReply())
        }
    }

    private func reply(after result: RealtimeToolResult) {
        let responseID = "sim-response-\(turn)-after-tool"
        session.emit(.responseStarted(responseID: responseID))
        let saw = result.output["screen"]?.stringValue.map { " I looked at your \($0)." } ?? ""
        speak(responseID: responseID, text: nextReply() + saw)
    }

    private func speak(responseID: String, text: String) {
        let item = "\(responseID)-audio"
        let format = session.outputFormat
        let frames = Int(Double(format.sampleRate) * replySeconds)
        var samples = [Int16](repeating: 0, count: frames)
        for index in 0..<frames {
            let t = Double(index) / Double(format.sampleRate)
            let envelope = min(1, min(t, replySeconds - t) * 20)
            samples[index] = Int16(sin(2 * .pi * 330 * t) * 6_000 * envelope)
        }
        let pcm = PCMConverter.pcm16(fromSamples: samples)
        for chunk in realtimeAudioChunks(pcm, maxBytes: format.bytesPerSecond / 10) {
            session.emit(.audio(chunk, itemID: item))
        }
        session.emit(.assistantTranscriptDelta(text, itemID: item))
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: responseID, status: .completed, itemIDs: [item], transcript: text)))
    }
}
