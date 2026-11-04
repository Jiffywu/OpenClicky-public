import Foundation

/// The whole user configuration: providers (endpoint + dialect + credential name), extra model declarations,
/// and which provider/model fills each slot. Stored as JSON at
/// `~/Library/Application Support/OpenClicky/config.json`. Never holds a secret.
public struct OpenClickyConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var providers: [ProviderConfig]
    /// Models the built-in catalog doesn't know (or whose capabilities the user corrects).
    public var models: [ModelDescriptor]
    public var slots: [SlotID: SlotSelection]
    /// Optional per-harness overrides (executable path, extra args).
    public var harnesses: [HarnessKind: HarnessSettings]?
    /// Background-job limits (steps, time, compaction threshold, cleanup); nil uses `AgentLimits()`.
    public var agentLimits: AgentLimits?
    /// Optional element grounding (parity `other:grounding`): an Anthropic Messages provider and a model that takes the
    /// computer tool, used when a guided target can't be placed otherwise (docs/guided.md). Nil turns grounding off.
    public var grounding: SlotSelection?

    public init(version: Int = 1, providers: [ProviderConfig], models: [ModelDescriptor] = [],
                slots: [SlotID: SlotSelection], harnesses: [HarnessKind: HarnessSettings]? = nil) {
        self.version = version
        self.providers = providers
        self.models = models
        self.slots = slots
        self.harnesses = harnesses
    }

    public func provider(_ id: String) -> ProviderConfig? { providers.first { $0.id == id } }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> OpenClickyConfig {
        try JSONDecoder().decode(OpenClickyConfig.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// A config that mirrors HeyClicky's defaults with the user's own OpenAI key. Listening defaults to Apple's
    /// on-device recognizer (HeyClicky's own fallback) so one key is enough to start; Deepgram is preconfigured.
    public static let heyClickyLike = OpenClickyConfig(
        providers: [
            ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
            ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"), credential: "openai"),
            ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"), credential: "deepgram"),
            ProviderConfig(id: "apple-speech", dialect: .appleSpeech),
        ],
        slots: [
            .stt: SlotSelection(provider: "apple-speech", model: "on-device"),
            .voice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1-mini", voice: "cedar"),
            .brain: SlotSelection(provider: "openai", model: "gpt-6.1-sol"),
            .agent: SlotSelection(provider: "openai", model: "gpt-6-luna", harness: .codex),
            .brainFast: SlotSelection(provider: "openai", model: "gpt-5.4-mini"),
            .realtimeVoice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1", voice: "cedar"),
        ])

    /// The selection for a slot, falling back for optional slots that have one (brain-fast → brain).
    public func selection(for slot: SlotID) -> SlotSelection? {
        if let selection = slots[slot] { return selection }
        return slot == .brainFast ? slots[.brain] : nil
    }
}

public struct HarnessSettings: Codable, Sendable, Equatable {
    public var executable: String?
    public var extraArguments: [String]?

    public init(executable: String? = nil, extraArguments: [String]? = nil) {
        self.executable = executable
        self.extraArguments = extraArguments
    }
}
