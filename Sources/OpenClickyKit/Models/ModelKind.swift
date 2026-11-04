import Foundation

/// What a model fundamentally is. A slot accepts only certain kinds, so a text-to-speech model can never
/// end up as the brain and a chat model can never end up as the voice.
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    /// Turns speech audio into text (Deepgram nova-3, Apple Speech, Whisper, gpt-4o-mini-transcribe).
    case speechToText = "speech-to-text"
    /// Turns text into speech audio, one request per line (AVSpeechSynthesizer, OpenAI TTS, ElevenLabs).
    case textToSpeech = "text-to-speech"
    /// A bidirectional realtime speech session that can speak lines it is given (gpt-realtime family).
    case realtimeSpeech = "realtime-speech"
    /// A chat/reasoning language model, possibly multimodal (GPT, Claude, Gemini, DeepSeek, local LLMs).
    case languageModel = "language-model"

    /// Human wording for messages: "a language model", "a text-to-speech model".
    public var phrase: String {
        switch self {
        case .speechToText: "speech-to-text model"
        case .textToSpeech: "text-to-speech model"
        case .realtimeSpeech: "realtime speech model"
        case .languageModel: "language model"
        }
    }
}

/// Individual abilities a model declares. Slots require some and prefer others.
public enum Capability: String, Codable, Sendable, CaseIterable, Comparable {
    case textInput = "text-input"
    case imageInput = "image-input"
    case audioInput = "audio-input"
    case textOutput = "text-output"
    case audioOutput = "audio-output"
    case streaming
    case toolCalling = "tool-calling"
    case reasoning
    /// Partial transcripts while the user is still speaking.
    case interimResults = "interim-results"
    /// Runs on this Mac with no network.
    case onDevice = "on-device"

    public static func < (lhs: Capability, rhs: Capability) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One concrete model offered by one provider dialect.
public struct ModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    /// The id sent to the provider (e.g. "gpt-6.1-sol", "claude-sonnet-5-5", "nova-3").
    public var id: String
    public var displayName: String?
    public var kind: ModelKind
    public var capabilities: Set<Capability>
    /// Provider dialects that can serve this model id. Empty means "any dialect" (user-declared local models).
    public var dialects: Set<ProviderDialect>
    /// Voices for speech-output models.
    public var voices: [String]?
    /// Reasoning effort levels the model accepts, lowest first.
    public var reasoningEfforts: [String]?
    public var notes: String?
    /// What the model costs, for the local usage ledger (docs/infra.md). Nil when OpenClicky doesn't know.
    public var price: ModelPrice?
    /// Why a catalog model has no price (the provider doesn't publish one). Every built-in model carries either a
    /// price or this marker, so a missing price is a decision rather than an oversight; the ledger leaves its cost blank.
    public var priceUnknown: String?

    public init(
        id: String, displayName: String? = nil, kind: ModelKind, capabilities: Set<Capability>,
        dialects: Set<ProviderDialect> = [], voices: [String]? = nil, reasoningEfforts: [String]? = nil, notes: String? = nil,
        price: ModelPrice? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.capabilities = capabilities
        self.dialects = dialects
        self.voices = voices
        self.reasoningEfforts = reasoningEfforts
        self.notes = notes
        self.price = price
    }

    public func has(_ capability: Capability) -> Bool { capabilities.contains(capability) }
}
