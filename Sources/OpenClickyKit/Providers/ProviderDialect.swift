import Foundation

/// The wire protocol a provider speaks. One dialect can be served by many vendors: OpenAI-compatible chat
/// covers OpenRouter, Ollama, LM Studio and vLLM; Anthropic Messages covers Anthropic and compatible gateways.
public enum ProviderDialect: String, Codable, Sendable, CaseIterable {
    /// OpenAI Responses API (`POST /responses`).
    case openAIResponses = "openai-responses"
    /// OpenAI-compatible Chat Completions (`POST /chat/completions`): OpenAI, OpenRouter, Ollama, LM Studio, vLLM.
    case openAIChat = "openai-chat"
    /// Anthropic Messages (`POST /v1/messages`).
    case anthropicMessages = "anthropic-messages"
    /// OpenAI Realtime over WebSocket (`wss://…/realtime?model=`).
    case openAIRealtime = "openai-realtime"
    /// OpenAI audio speech (`POST /audio/speech`).
    case openAISpeech = "openai-speech"
    /// OpenAI audio transcription (`POST /audio/transcriptions`).
    case openAITranscription = "openai-transcription"
    /// Deepgram live transcription over WebSocket (`wss://api.deepgram.com/v1/listen`).
    case deepgramListen = "deepgram-listen"
    /// ElevenLabs text-to-speech (`POST /v1/text-to-speech/{voice_id}/stream`).
    case elevenLabsSpeech = "elevenlabs-speech"
    /// Apple Speech framework. Prefers on-device recognition; for a language without an on-device model, Apple's
    /// servers do the recognition. No credential.
    case appleSpeech = "apple-speech"
    /// AVSpeechSynthesizer, on device. No credential.
    case appleSpeechSynthesis = "apple-speech-synthesis"
    /// Gemini Live API over WebSocket (`…GenerativeService.BidiGenerateContent`): input transcription for the stt slot,
    /// native-audio conversation for the realtime-voice slot.
    case geminiLive = "gemini-live"
    /// Gemini text-to-speech, streamed from the Interactions API (`POST /v1beta/interactions`).
    case geminiSpeech = "gemini-speech"
    /// The agent harness's own sign-in (ChatGPT login for Codex, a Claude subscription for Claude Code). No base
    /// URL and no credential: the harness talks to its vendor with the login it already has. Agent slot only.
    case harnessLogin = "harness-login"

    /// Dialects that run on this Mac and never need an API key.
    public var isOnDevice: Bool { self == .appleSpeech || self == .appleSpeechSynthesis }

    /// Dialects with a network endpoint the config must name. On-device dialects and the harness's own login have none.
    public var needsBaseURL: Bool { !isOnDevice && self != .harnessLogin }

    /// The model kinds this dialect can serve at all. None for the harness's own login: no OpenClicky client can
    /// talk to it, so it never stands in for a language model (brain, dictation cleanup); the validator accepts it
    /// in the agent slot only.
    public var servableKinds: Set<ModelKind> {
        switch self {
        case .harnessLogin: []
        case .openAIResponses, .openAIChat, .anthropicMessages: [.languageModel]
        case .openAIRealtime: [.realtimeSpeech]
        case .openAISpeech, .elevenLabsSpeech, .appleSpeechSynthesis, .geminiSpeech: [.textToSpeech]
        case .openAITranscription, .deepgramListen, .appleSpeech: [.speechToText]
        case .geminiLive: [.speechToText, .realtimeSpeech]
        }
    }

    /// Whether OpenClicky has an adapter for this dialect in `slot`. A dialect can serve a model kind a slot accepts
    /// and still have no adapter there: Gemini Live's native-audio models are realtime speech models, but they fill
    /// only the realtime-voice slot, not the voice slot that reads lines aloud.
    public func canFill(_ slot: SlotID) -> Bool {
        switch (self, slot) {
        case (.geminiLive, .voice): false
        case (.openAIRealtime, .realtimeVoice), (.geminiLive, .realtimeVoice): true
        case (_, .realtimeVoice): false
        default: true
        }
    }
}

/// A configured endpoint: a dialect, a base URL and which stored credential to send.
public struct ProviderConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var dialect: ProviderDialect
    /// Base URL including the version path, e.g. `https://api.openai.com/v1`, `https://openrouter.ai/api/v1`,
    /// `http://127.0.0.1:11434/v1`. Ignored for on-device dialects.
    ///
    /// Anthropic (`https://api.anthropic.com`) and ElevenLabs (`https://api.elevenlabs.io`) bases are conventionally
    /// given without `/v1`, since their adapters add the version to each path; both adapters also accept a base that
    /// already ends in `/v1`, so either form works.
    public var baseURL: URL?
    /// Name of a credential in the credential store. Nil for on-device dialects and keyless local servers.
    public var credential: String?
    /// Extra headers some gateways want (e.g. OpenRouter's `HTTP-Referer`, `X-Title`).
    public var headers: [String: String]?

    public init(id: String, dialect: ProviderDialect, baseURL: URL? = nil, credential: String? = nil, headers: [String: String]? = nil) {
        self.id = id
        self.dialect = dialect
        self.baseURL = baseURL
        self.credential = credential
        self.headers = headers
    }
}
