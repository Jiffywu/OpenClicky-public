import Foundation

/// A second cloud voice for the line narrator: when the voice slot's provider fails, HeyClicky moves to its other
/// cloud voice for ten minutes before anything else (docs/re/02-voice-pipeline.md §7). OpenClicky picks it from the
/// user's own configuration: another cloud speech provider whose credential is stored.
public struct AlternateVoice: Sendable {
    public var client: any SpeechOutputClient
    /// "provider / model", for logs.
    public var name: String
    public var providerID: String
    public var model: String

    public init(client: any SpeechOutputClient, name: String, providerID: String, model: String) {
        self.client = client
        self.name = name
        self.providerID = providerID
        self.model = model
    }
}

extension EngineFactory {
    /// The model an alternate voice on `dialect` speaks with: the adapter's own default.
    static func alternateVoiceModel(for dialect: ProviderDialect) -> String? {
        switch dialect {
        case .elevenLabsSpeech: ElevenLabsSpeechClient.defaultModel
        case .geminiSpeech: GeminiSpeechClient.defaultModel
        case .openAISpeech: OpenAISpeechClient.defaultModel
        case .openAIRealtime: OpenAIRealtimeSpeechClient.defaultModel
        default: nil
        }
    }

    /// Another configured cloud voice than the voice slot's: the first provider, in config order, that speaks
    /// (ElevenLabs, Gemini TTS, OpenAI speech or Realtime), isn't the voice slot's provider and has its credential
    /// stored. Built like the voice slot (metered under the voice slot), with the adapter's default model and voice.
    /// Nil when the voice slot is on device or empty, or no other cloud voice is set up. Reads credentials, no network.
    public func alternateSpeechOutput() -> AlternateVoice? {
        guard let current = try? resolve(.voice), let slotProvider = current.provider, !slotProvider.dialect.isOnDevice else { return nil }
        for provider in config.providers where provider.id != slotProvider.id {
            guard let model = Self.alternateVoiceModel(for: provider.dialect) else { continue }
            var swapped = config
            swapped.slots[.voice] = SlotSelection(provider: provider.id, model: model)
            let factory = EngineFactory(config: swapped, catalog: catalog, credentials: credentials, http: http, webSocket: webSocket,
                                        resilience: resilience)
            guard let client = try? factory.speechOutput() else { continue }
            return AlternateVoice(client: client, name: "\(provider.id) / \(model)", providerID: provider.id, model: model)
        }
        return nil
    }
}
