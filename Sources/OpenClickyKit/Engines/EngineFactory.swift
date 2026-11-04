import Foundation

/// Why the factory would not build an engine for a slot.
public enum EngineFactoryError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// Nothing is chosen for the slot (for brain-fast: nothing for brain either).
    case slotEmpty(SlotID)
    /// The slot's selection has validation errors; nothing is built until they are fixed.
    case invalidSlot(SlotID, [ConfigIssue])
    /// The slot's provider names a credential the store does not hold (or holds empty).
    case missingCredential(slot: SlotID, provider: String, credential: String)
    /// The credential store failed to read the credential.
    case unreadableCredential(slot: SlotID, credential: String, reason: String)
    /// The method asked for an engine this slot does not hold (e.g. a language model for the stt slot).
    case wrongSlot(SlotID, expected: String)

    public var description: String {
        switch self {
        case .slotEmpty(let slot):
            "No model is chosen for the \(slot.rawValue) slot."
        case .invalidSlot(let slot, let issues):
            "The \(slot.rawValue) slot can't start: "
                + issues.map(\.message).joined(separator: " ")
        case .missingCredential(let slot, let provider, let credential):
            "The \(slot.rawValue) slot's provider \"\(provider)\" needs the credential \"\(credential)\", which is not stored. "
                + "Add it with: occtl key set \(credential)"
        case .unreadableCredential(let slot, let credential, let reason):
            "Could not read the credential \"\(credential)\" for the \(slot.rawValue) slot: \(reason)"
        case .wrongSlot(let slot, let expected):
            "The \(slot.rawValue) slot does not hold \(expected)."
        }
    }

    public var errorDescription: String? { description }
}

/// Where a slot's engine comes from, worked out without a credential or the network (for `occtl engines` and the
/// settings window).
public struct EngineResolution: Sendable, Equatable {
    /// The slot asked about.
    public var slot: SlotID
    /// The slot whose selection is used: `.brain` when an empty brain-fast slot falls back to it.
    public var sourceSlot: SlotID
    public var selection: SlotSelection
    /// The configured provider the selection names; nil when no provider has that id.
    public var provider: ProviderConfig?
    /// The adapter type the factory builds, e.g. "OpenAIResponsesClient"; nil without a provider.
    public var adapter: String?
    /// Validation errors that stop the slot (empty when it can be built, credentials aside).
    public var errors: [ConfigIssue]
}

/// Builds the adapter for each model slot from the user's configuration.
///
/// The credential is read from the store each time an engine is built and handed only to that engine's
/// `ProviderContext`; the factory keeps no key. A slot is refused, with an `EngineFactoryError`, when it is empty,
/// when validation reports an error for it (or for its provider), or when its provider's credential is missing.
/// Building never touches the network: connections open when the engine is first used.
public struct EngineFactory: Sendable {
    public var config: OpenClickyConfig
    /// The model catalog with the config's declared models merged in (merging again is harmless).
    public var catalog: ModelCatalog
    public var credentials: any CredentialStore
    public var http: any HTTPTransport
    public var webSocket: any WebSocketConnector
    /// Retries, plain explanations and usage metering around every engine (docs/infra.md); nil builds bare adapters.
    /// Defaults to what the app or occtl installed at launch.
    public var resilience: ProviderResilience?

    public init(config: OpenClickyConfig, catalog: ModelCatalog, credentials: any CredentialStore,
                http: any HTTPTransport = URLSessionTransport(),
                webSocket: any WebSocketConnector = URLSessionWebSocketConnector(),
                resilience: ProviderResilience? = ProviderResilience.installed) {
        self.config = config
        self.catalog = catalog
        self.credentials = credentials
        self.http = http
        self.webSocket = webSocket
        self.resilience = resilience
    }

    // MARK: - Engines

    /// The chat client for `.brain`, `.brainFast` (falls back to the brain's selection when empty) or `.agent`
    /// (the agent model; the harness that runs jobs is separate).
    func bareLanguageModel(for slot: SlotID) throws -> any LanguageModelClient {
        guard [.brain, .brainFast, .agent].contains(slot) else { throw EngineFactoryError.wrongSlot(slot, expected: "a language model") }
        let (_, provider, context) = try prepare(slot)
        switch provider.dialect {
        case .openAIResponses: return OpenAIResponsesClient(context: context)
        case .openAIChat: return OpenAIChatClient(context: context)
        case .anthropicMessages: return AnthropicMessagesClient(context: context)
        default: throw EngineFactoryError.wrongSlot(slot, expected: "a language model")
        }
    }

    /// The speech-to-text client for the stt slot.
    func bareSpeechToText() throws -> any SpeechToTextClient {
        let (resolution, provider, context) = try prepare(.stt)
        let model = resolution.selection.model
        switch provider.dialect {
        case .deepgramListen: return DeepgramListenClient(context: context, model: model)
        case .openAITranscription: return OpenAITranscriptionClient(context: context, model: model)
        case .appleSpeech: return AppleSpeechClient(context: context)
        case .geminiLive: return GeminiLiveSpeechToTextClient(context: context, model: model)
        default: throw EngineFactoryError.wrongSlot(.stt, expected: "a speech-to-text model")
        }
    }

    /// The stt slot's batch side, for a press whose stream failed (`VoiceEars`): Gemini's unary transcription model for
    /// a Gemini Live slot; for the others, the slot's own client with the whole recording streamed in one pass.
    public func speechToTextBatch() throws -> any SpeechToTextBatchClient {
        let (resolution, provider, context) = try prepare(.stt)
        if provider.dialect == .geminiLive {
            let model = GeminiTranscriptionClient.batchModel(forLive: resolution.selection.model)
            let client = GeminiTranscriptionClient(context: context, model: model)
            guard let resilience, var identity = identity(for: .stt, resilience: resilience) else { return client }
            identity.model = model
            return MeteredSpeechToTextBatchClient(base: client, identity: identity, resilience: resilience)
        }
        return StreamingReplayBatchClient(client: try speechToText())
    }

    /// The client that speaks lines for the voice slot, using the selection's voice as its default.
    func bareSpeechOutput() throws -> any SpeechOutputClient {
        let (resolution, provider, context) = try prepare(.voice)
        let model = resolution.selection.model
        let voice = resolution.selection.voice.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch provider.dialect {
        case .openAIRealtime:
            return OpenAIRealtimeSpeechClient(context: context, model: model,
                                              defaultVoice: voice ?? OpenAIRealtimeSpeechClient.defaultVoice)
        case .openAISpeech: return OpenAISpeechClient(context: context, model: model, defaultVoice: voice)
        case .elevenLabsSpeech: return ElevenLabsSpeechClient(context: context, model: model, defaultVoice: voice)
        case .appleSpeechSynthesis: return AppleSpeechSynthesisClient(context: context, defaultVoice: voice)
        case .geminiSpeech: return GeminiSpeechClient(context: context, model: model, defaultVoice: voice)
        default: throw EngineFactoryError.wrongSlot(.voice, expected: "a speech output model")
        }
    }

    /// The realtime speech-to-speech client for the realtime-voice slot (always-on voice and the interview), using the
    /// selection's voice as its default.
    func bareRealtimeVoice() throws -> any RealtimeVoiceClient {
        let (resolution, provider, context) = try prepare(.realtimeVoice)
        let model = resolution.selection.model
        let voice = resolution.selection.voice.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch provider.dialect {
        case .openAIRealtime: return OpenAIRealtimeVoiceClient(context: context, model: model, defaultVoice: voice)
        case .geminiLive: return GeminiLiveVoiceClient(context: context, model: model, defaultVoice: voice)
        default: throw EngineFactoryError.wrongSlot(.realtimeVoice, expected: "a realtime speech model")
        }
    }

    // MARK: - Resolution

    /// The adapter type the factory builds for a dialect.
    public static func adapterName(for dialect: ProviderDialect) -> String {
        switch dialect {
        case .openAIResponses: "OpenAIResponsesClient"
        case .openAIChat: "OpenAIChatClient"
        case .anthropicMessages: "AnthropicMessagesClient"
        case .openAIRealtime: "OpenAIRealtimeSpeechClient"
        case .openAISpeech: "OpenAISpeechClient"
        case .openAITranscription: "OpenAITranscriptionClient"
        case .deepgramListen: "DeepgramListenClient"
        case .elevenLabsSpeech: "ElevenLabsSpeechClient"
        case .appleSpeech: "AppleSpeechClient"
        case .appleSpeechSynthesis: "AppleSpeechSynthesisClient"
        case .geminiLive: "GeminiLiveSpeechToTextClient"
        case .geminiSpeech: "GeminiSpeechClient"
        case .harnessLogin: "no client (the agent harness signs in by itself)"
        }
    }

    /// The adapter type the factory builds for a dialect in a given slot: the realtime-voice slot has its own adapters.
    public static func adapterName(for dialect: ProviderDialect, slot: SlotID) -> String {
        guard slot == .realtimeVoice else { return adapterName(for: dialect) }
        switch dialect {
        case .openAIRealtime: return "OpenAIRealtimeVoiceClient"
        case .geminiLive: return "GeminiLiveVoiceClient"
        default: return adapterName(for: dialect)
        }
    }

    /// Which selection, provider and adapter `slot` resolves to, and the validation errors that would stop it.
    /// Reads no credential. Throws only when the slot (and, for brain-fast, the brain slot) is empty.
    public func resolve(_ slot: SlotID) throws -> EngineResolution {
        let sourceSlot: SlotID = config.slots[slot] == nil && slot == .brainFast ? .brain : slot
        guard let selection = config.selection(for: slot) else { throw EngineFactoryError.slotEmpty(slot) }
        let provider = config.provider(selection.provider)
        // Validate just this selection and its provider, so problems elsewhere in the config never block it.
        let subset = OpenClickyConfig(version: config.version, providers: provider.map { [$0] } ?? [], models: config.models,
                                      slots: [sourceSlot: selection], harnesses: config.harnesses)
        let errors = ConfigValidator(catalog: catalog.merging(config.models)).validate(subset)
            .filter { $0.severity == .error && ($0.slot == sourceSlot || $0.slot == nil) }
        return EngineResolution(slot: slot, sourceSlot: sourceSlot, selection: selection, provider: provider,
                                adapter: provider.map { Self.adapterName(for: $0.dialect, slot: slot) }, errors: errors)
    }

    /// Resolves the slot, refuses it on validation errors, and reads its credential into a fresh context.
    private func prepare(_ slot: SlotID) throws -> (resolution: EngineResolution, provider: ProviderConfig, context: ProviderContext) {
        let resolution = try resolve(slot)
        guard resolution.errors.isEmpty, let provider = resolution.provider else {
            throw EngineFactoryError.invalidSlot(slot, resolution.errors)
        }
        var apiKey: String?
        if !provider.dialect.isOnDevice, let name = provider.credential {
            let secret: String?
            do {
                secret = try credentials.secret(named: name)
            } catch {
                throw EngineFactoryError.unreadableCredential(slot: slot, credential: name, reason: String(describing: error))
            }
            guard let secret, !secret.isEmpty else {
                throw EngineFactoryError.missingCredential(slot: slot, provider: provider.id, credential: name)
            }
            apiKey = secret
        }
        let transport = resilience?.transport(http, slot: slot) ?? http
        return (resolution, provider, ProviderContext(provider: provider, apiKey: apiKey, http: transport, webSocket: webSocket))
    }
}

// The credential store may be an in-memory one holding secrets, and provider headers may hold credentials, so
// printing or dumping a factory shows only provider ids and filled slots.
extension EngineFactory: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "EngineFactory(providers: \(config.providers.map(\.id)), slots: \(config.slots.keys.map(\.rawValue).sorted()))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["providers": config.providers.map(\.id), "slots": config.slots.keys.map(\.rawValue).sorted()],
               displayStyle: .struct)
    }
}
