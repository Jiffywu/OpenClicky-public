import Foundation

/// Ready-made provider entries the settings window offers, so users pick "OpenRouter" rather than typing a URL.
public struct ProviderPreset: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var config: ProviderConfig
    /// Where to get a key, shown next to the key field.
    public var keyHelpURL: URL?

    public static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI",
              config: .init(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
              keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "openai-realtime", name: "OpenAI Realtime voice",
              config: .init(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"), credential: "openai"),
              keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "openai-speech", name: "OpenAI text-to-speech",
              config: .init(id: "openai-speech", dialect: .openAISpeech, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
              keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "openai-transcription", name: "OpenAI transcription",
              config: .init(id: "openai-transcription", dialect: .openAITranscription, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
              keyHelpURL: URL(string: "https://platform.openai.com/api-keys")),
        .init(id: "anthropic", name: "Anthropic",
              config: .init(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
              keyHelpURL: URL(string: "https://console.anthropic.com/settings/keys")),
        .init(id: "openrouter", name: "OpenRouter",
              config: .init(id: "openrouter", dialect: .openAIChat, baseURL: URL(string: "https://openrouter.ai/api/v1"), credential: "openrouter",
                            headers: ["X-Title": "OpenClicky"]),
              keyHelpURL: URL(string: "https://openrouter.ai/settings/keys")),
        .init(id: "ollama", name: "Ollama (this Mac)",
              config: .init(id: "ollama", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:11434/v1"))),
        .init(id: "lmstudio", name: "LM Studio (this Mac)",
              config: .init(id: "lmstudio", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:1234/v1"))),
        .init(id: "deepgram", name: "Deepgram",
              config: .init(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"), credential: "deepgram"),
              keyHelpURL: URL(string: "https://console.deepgram.com")),
        .init(id: "elevenlabs", name: "ElevenLabs",
              config: .init(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
              keyHelpURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")),
        .init(id: "gemini-live", name: "Gemini Live (listening and always-on voice)",
              config: .init(id: "gemini-live", dialect: .geminiLive, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta"), credential: "gemini"),
              keyHelpURL: URL(string: "https://aistudio.google.com/apikey")),
        .init(id: "gemini-speech", name: "Gemini text-to-speech",
              config: .init(id: "gemini-speech", dialect: .geminiSpeech, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta"), credential: "gemini"),
              keyHelpURL: URL(string: "https://aistudio.google.com/apikey")),
        .init(id: "apple-speech", name: "Apple Speech (on device when available; may use Apple's servers)",
              config: .init(id: "apple-speech", dialect: .appleSpeech)),
        .init(id: "apple-voices", name: "macOS voices (on device)", config: .init(id: "apple-voices", dialect: .appleSpeechSynthesis)),
    ]
}
