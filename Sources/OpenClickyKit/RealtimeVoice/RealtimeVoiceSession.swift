import Foundation

// The realtime-voice slot: one speech-to-speech session that listens (with the provider's voice activity detection),
// answers aloud, looks at the screen when asked and calls tools. HeyClicky calls this "full voice" and runs it on
// gpt-realtime-2.1 for always-on mode and the onboarding interview (docs/re/02-voice-pipeline.md §1B, §8, §9).
//
// Adapters translate one provider's socket into these provider-neutral types, so the conversation loop, the echo gate
// and the tool dispatcher never care whether OpenAI Realtime or Gemini Live is on the other end.

/// How the provider decides the user has finished a turn.
public enum RealtimeTurnDetection: Sendable, Hashable {
    /// The provider listens for speech and silence itself (always-on).
    case serverVAD(RealtimeVADSettings)
    /// The app marks turns: audio between `sendAudio` calls is one turn until `endAudioTurn()` (push-to-talk).
    case manual
}

/// Voice activity detection tuning. Each adapter maps these onto its provider's knobs and leaves the rest at defaults.
public struct RealtimeVADSettings: Sendable, Hashable {
    /// 0…1; higher needs louder speech to count as the user talking. Nil leaves the provider default.
    public var threshold: Double?
    /// Audio kept from before speech was detected, so the first syllable isn't clipped.
    public var prefixPadding: Duration?
    /// Silence that ends the user's turn.
    public var silence: Duration?
    /// Whether the provider answers on its own when a turn ends (otherwise the app calls `createResponse`).
    public var autoRespond: Bool
    /// Whether the provider stops its own reply when it hears the user start speaking.
    public var interruptsResponse: Bool

    public init(threshold: Double? = nil, prefixPadding: Duration? = .milliseconds(300), silence: Duration? = .milliseconds(600),
                autoRespond: Bool = true, interruptsResponse: Bool = true) {
        self.threshold = threshold
        self.prefixPadding = prefixPadding
        self.silence = silence
        self.autoRespond = autoRespond
        self.interruptsResponse = interruptsResponse
    }

    /// Always-on with headphones: no echo to worry about, so the default sensitivity.
    public static let headphones = RealtimeVADSettings(threshold: 0.5)
    /// Always-on on speakers: a higher bar, so the assistant's own voice leaking into the mic doesn't count as the user.
    public static let speakers = RealtimeVADSettings(threshold: 0.72, silence: .milliseconds(700))
}

/// Microphone placement, for providers that clean up input noise.
public enum RealtimeNoiseReduction: String, Sendable, Hashable {
    /// A headset or a mic close to the mouth.
    case nearField = "near_field"
    /// A laptop or desk mic.
    case farField = "far_field"
}

/// Everything a session is opened with. OpenClicky writes the instructions and chooses the tools (HeyClicky's server
/// injected both).
public struct RealtimeSessionConfiguration: Sendable, Hashable {
    public var instructions: String
    public var tools: [ToolSpec]
    /// Voice id; nil uses the slot's voice, then the adapter's default.
    public var voice: String?
    public var turnDetection: RealtimeTurnDetection
    /// Transcribe what the user says (for captions and the history).
    public var transcribeInput: Bool
    /// Optional language hint for input transcription (ISO-639-1, e.g. "en").
    public var language: String?
    public var noiseReduction: RealtimeNoiseReduction?
    /// Speech speed, 0.5…1.5 where the provider supports it.
    public var speed: Double?
    /// Ask the provider for resumption handles (`RealtimeVoiceEvent.resumable`) where it offers them (Gemini Live), so
    /// a replacement session can pick the conversation up when this one is closed.
    public var resumable: Bool
    /// Resume the conversation of an earlier session from this handle instead of starting a new one.
    public var resumptionHandle: String?

    public init(instructions: String, tools: [ToolSpec] = [], voice: String? = nil,
                turnDetection: RealtimeTurnDetection = .serverVAD(.headphones), transcribeInput: Bool = true,
                language: String? = nil, noiseReduction: RealtimeNoiseReduction? = .nearField, speed: Double? = nil,
                resumable: Bool = false, resumptionHandle: String? = nil) {
        self.resumable = resumable
        self.resumptionHandle = resumptionHandle
        self.instructions = instructions
        self.tools = tools
        self.voice = voice
        self.turnDetection = turnDetection
        self.transcribeInput = transcribeInput
        self.language = language
        self.noiseReduction = noiseReduction
        self.speed = speed
    }
}

/// A tool call the realtime model made. `arguments` is JSON text exactly as the model wrote it.
public struct RealtimeToolCall: Sendable, Hashable {
    public var callID: String
    public var name: String
    public var arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// The answer to one tool call.
public struct RealtimeToolResult: Sendable, Hashable {
    public var callID: String
    public var name: String
    /// What the model reads. Objects are sent as they are; anything else is wrapped as `{"result": …}` where the
    /// provider wants an object.
    public var output: JSONValue
    /// Whether the model should speak about this result. False for superseded results: they are recorded in the
    /// conversation so the call is answered, but they must not start a new reply.
    public var respond: Bool

    public init(callID: String, name: String, output: JSONValue, respond: Bool = true) {
        self.callID = callID
        self.name = name
        self.output = output
        self.respond = respond
    }
}

/// How a model reply ended.
public enum RealtimeResponseStatus: String, Sendable, Hashable {
    case completed
    /// The app cancelled it (barge-in, Escape).
    case cancelled
    /// The provider stopped it because it heard the user start speaking.
    case interrupted
    /// It hit a length limit or content filter.
    case incomplete
    case failed
}

public struct RealtimeUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var inputAudioTokens: Int?
    public var outputAudioTokens: Int?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, inputAudioTokens: Int? = nil, outputAudioTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.inputAudioTokens = inputAudioTokens
        self.outputAudioTokens = outputAudioTokens
    }
}

public struct RealtimeResponseSummary: Sendable, Hashable {
    public var responseID: String
    public var status: RealtimeResponseStatus
    /// The assistant item(s) whose audio belonged to this response.
    public var itemIDs: [String]
    /// What the assistant said, from the provider's own transcript.
    public var transcript: String
    /// Tool calls the response made.
    public var toolCalls: [RealtimeToolCall]
    public var usage: RealtimeUsage?
    /// Provider detail when it failed or was cut short.
    public var detail: String?

    public init(responseID: String, status: RealtimeResponseStatus, itemIDs: [String] = [], transcript: String = "",
                toolCalls: [RealtimeToolCall] = [], usage: RealtimeUsage? = nil, detail: String? = nil) {
        self.responseID = responseID
        self.status = status
        self.itemIDs = itemIDs
        self.transcript = transcript
        self.toolCalls = toolCalls
        self.usage = usage
        self.detail = detail
    }
}

/// What a session reports, in order.
public enum RealtimeVoiceEvent: Sendable, Hashable {
    /// The provider heard the user start speaking. While the assistant is talking, this is a barge-in.
    case userSpeechStarted
    case userSpeechStopped
    /// The user's turn is in the conversation. `itemID` is the provider's item for it, where it has one.
    case userTurnCommitted(itemID: String?)
    /// Caption of the user's words: a non-final text replaces the previous one for the same turn; final settles it.
    case userTranscript(text: String, isFinal: Bool, itemID: String?)
    /// The model began a reply.
    case responseStarted(responseID: String)
    /// Speech for the reply, PCM16 in the session's `outputFormat`, whole frames, tagged with its assistant item.
    case audio(Data, itemID: String)
    /// More of what the assistant is saying.
    case assistantTranscriptDelta(String, itemID: String)
    /// The model wants a tool run. Answer with `sendToolResult`.
    case toolCall(RealtimeToolCall)
    /// The provider withdrew calls it had made (the user talked over it). Send no result for them.
    case toolCallsCancelled([String])
    case responseFinished(RealtimeResponseSummary)
    /// The provider will close the connection soon; open a new session to keep going.
    case goingAway(timeLeft: Duration?)
    /// A handle a replacement session can resume this conversation from (sessions opened `resumable`).
    case resumable(handle: String)
    /// The provider rejected one client event; the session carries on.
    case warning(String)
}

/// What a session can do beyond audio in and out.
public struct RealtimeFeatures: Sendable, Hashable {
    /// Screenshots can be added to the conversation.
    public var imageInput: Bool
    /// An interrupted reply can be cut to what the user actually heard, so the model knows where it was stopped.
    public var truncatesToHeardAudio: Bool
    /// A user turn can be removed from the conversation (to drop an echo or a silent commit).
    public var deletesItems: Bool
    /// Instructions can change mid-session.
    public var updatesInstructions: Bool

    public init(imageInput: Bool, truncatesToHeardAudio: Bool, deletesItems: Bool, updatesInstructions: Bool) {
        self.imageInput = imageInput
        self.truncatesToHeardAudio = truncatesToHeardAudio
        self.deletesItems = deletesItems
        self.updatesInstructions = updatesInstructions
    }
}

/// One open realtime speech-to-speech session.
///
/// Calls never throw: a session whose socket has failed ignores them and finishes `events` with the error. Every
/// outgoing message goes through one ordered queue, so an image added before a tool result reaches the model first.
public protocol RealtimeVoiceSession: AnyObject, Sendable {
    var events: AsyncThrowingStream<RealtimeVoiceEvent, Error> { get }
    /// The PCM16 mono format `sendAudio` takes (24 kHz for OpenAI, 16 kHz for Gemini).
    var inputFormat: PCMFormat { get }
    /// The PCM16 format of `.audio` events.
    var outputFormat: PCMFormat { get }
    var features: RealtimeFeatures { get }
    /// The model the provider confirmed (or the one asked for).
    var model: String { get }

    /// Microphone audio in `inputFormat`. Any length; the adapter chunks it.
    func sendAudio(_ pcm: Data) async
    /// Ends the user's spoken turn now: with manual turn detection this commits it and asks for a reply; with server
    /// VAD it flushes audio the provider is holding (end of a file, mic paused).
    func endAudioTurn() async
    /// Drops audio the provider has buffered but not yet committed.
    func clearAudio() async
    /// Adds a typed message or an `[App]` note. With `respond`, the model replies to it.
    func addText(_ text: String, respond: Bool) async
    /// Adds a screenshot so the model can see it. Adapters keep only the latest one where they can.
    func addImage(_ data: Data, mimeType: String, caption: String?) async
    /// Answers a tool call. The adapter asks for the model's next reply once every outstanding call of that reply has
    /// an answer with `respond`.
    func sendToolResult(_ result: RealtimeToolResult) async
    /// Asks the model to reply now, optionally with one-off instructions.
    func createResponse(instructions: String?) async
    /// Barge-in or Escape: stops the reply in flight and, where the provider supports it, cuts assistant item `itemID`
    /// to the `heard` seconds the user actually heard. `clearInput` also drops buffered user audio (Escape, not
    /// barge-in: a barge-in's audio is the user's next turn).
    func interrupt(itemID: String?, heard: TimeInterval?, clearInput: Bool) async
    /// Removes a user turn that turned out to be echo or silence, and cancels a reply it may have started.
    func discardUserTurn(itemID: String) async
    func updateInstructions(_ instructions: String) async
    func close() async
}

/// Opens sessions for the realtime-voice slot.
public protocol RealtimeVoiceClient: Sendable {
    var model: String { get }
    /// Connects, configures the session and returns once the provider has accepted the configuration.
    func connect(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession
}

extension RealtimeToolResult {
    /// `output` as an object: objects as they are, anything else under `result`.
    var outputObject: [String: JSONValue] {
        if case .object(let object) = output { return object }
        return ["result": output]
    }
}

extension Duration {
    /// Whole milliseconds, clamped to 0…Int.max/2.
    var realtimeMilliseconds: Int {
        let (seconds, attoseconds) = components
        let total = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        guard total.isFinite, total > 0 else { return 0 }
        return Int(min(total, Double(Int.max / 2)).rounded())
    }

    var realtimeSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// `text` trimmed, or nil when that leaves nothing.
func realtimeTrimmed(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}
