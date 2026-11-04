import Foundation

/// Modifier keys a dictation chord can use. Kept free of AppKit so settings load anywhere.
public enum DictationModifier: String, Codable, Sendable, CaseIterable {
    case control, option, command, shift, function
}

/// Dictation preferences, stored apart from the slot config in
/// `~/Library/Application Support/OpenClicky/dictation.json`. Missing keys take their defaults.
public struct DictationSettings: Codable, Sendable, Equatable {
    public struct Cleanup: Codable, Sendable, Equatable {
        public var enabled: Bool
        /// Provider id for cleanup; nil uses the brain-fast slot's provider (the brain slot's when brain-fast is empty).
        public var provider: String?
        /// A small, fast model for cleanup only; nil uses the brain-fast slot's model (or the brain slot's).
        public var model: String?
        /// nil picks the lowest effort the model's catalog entry lists.
        public var reasoningEffort: String?
        public var minimumWords: Int
        public var timeoutSeconds: Double

        public init(enabled: Bool = true, provider: String? = nil, model: String? = nil, reasoningEffort: String? = nil,
                    minimumWords: Int = 3, timeoutSeconds: Double = 6) {
            self.enabled = enabled
            self.provider = provider
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.minimumWords = minimumWords
            self.timeoutSeconds = timeoutSeconds
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Cleanup()
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            provider = try c.decodeIfPresent(String.self, forKey: .provider)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
            minimumWords = try c.decodeIfPresent(Int.self, forKey: .minimumWords) ?? defaults.minimumWords
            timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? defaults.timeoutSeconds
        }
    }

    /// Hold these keys to dictate. Default Control + Fn (the voice chord is Control + Option).
    public var holdChord: [DictationModifier]
    /// Double-tap the chord to dictate hands-free; tap once more to finish.
    public var handsFreeDoubleTap: Bool
    /// BCP-47 language hint for speech-to-text; nil lets the provider detect it.
    public var language: String?
    public var cleanup: Cleanup
    public var archiveTranscripts: Bool
    public var learnCorrections: Bool
    /// Add the macOS account's full name to the recognition keyterms.
    public var seedUserName: Bool
    /// Bundle id → insertion strategies, in order, overriding the built-in table.
    public var insertionOverrides: [String: [InsertionStrategy]]
    /// When the streaming session loses a press (it drops, or its last words never come), transcribe the kept audio
    /// again with the fallback recognizer.
    public var fallbackTranscription: Bool

    public init(holdChord: [DictationModifier] = [.control, .function], handsFreeDoubleTap: Bool = true,
                language: String? = nil, cleanup: Cleanup = Cleanup(), archiveTranscripts: Bool = true,
                learnCorrections: Bool = true, seedUserName: Bool = true, insertionOverrides: [String: [InsertionStrategy]] = [:],
                fallbackTranscription: Bool = true) {
        self.holdChord = holdChord
        self.handsFreeDoubleTap = handsFreeDoubleTap
        self.language = language
        self.cleanup = cleanup
        self.archiveTranscripts = archiveTranscripts
        self.learnCorrections = learnCorrections
        self.seedUserName = seedUserName
        self.insertionOverrides = insertionOverrides
        self.fallbackTranscription = fallbackTranscription
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DictationSettings()
        holdChord = try c.decodeIfPresent([DictationModifier].self, forKey: .holdChord) ?? d.holdChord
        handsFreeDoubleTap = try c.decodeIfPresent(Bool.self, forKey: .handsFreeDoubleTap) ?? d.handsFreeDoubleTap
        language = try c.decodeIfPresent(String.self, forKey: .language)
        cleanup = try c.decodeIfPresent(Cleanup.self, forKey: .cleanup) ?? d.cleanup
        archiveTranscripts = try c.decodeIfPresent(Bool.self, forKey: .archiveTranscripts) ?? d.archiveTranscripts
        learnCorrections = try c.decodeIfPresent(Bool.self, forKey: .learnCorrections) ?? d.learnCorrections
        seedUserName = try c.decodeIfPresent(Bool.self, forKey: .seedUserName) ?? d.seedUserName
        insertionOverrides = try c.decodeIfPresent([String: [InsertionStrategy]].self, forKey: .insertionOverrides) ?? [:]
        fallbackTranscription = try c.decodeIfPresent(Bool.self, forKey: .fallbackTranscription) ?? d.fallbackTranscription
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("dictation.json")
    }

    /// The saved settings, or defaults when there is no file or it can't be read.
    public static func load(from url: URL = defaultURL) -> DictationSettings {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DictationSettings.self, from: $0) } ?? DictationSettings()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var strategyTable: InsertionStrategyTable { InsertionStrategyTable(overrides: insertionOverrides) }
}

/// Which provider and model clean up dictation: the brain-fast slot (which falls back to the brain slot), with an
/// optional dictation-only provider or model override from the dictation settings.
public struct DictationCleanupModelChoice: Sendable, Equatable {
    public var provider: ProviderConfig
    public var model: String
    public var reasoningEffort: String?
    /// False only when the catalog knows the model and it doesn't reason; unknown models get room to think.
    public var mayReason: Bool

    public init(provider: ProviderConfig, model: String, reasoningEffort: String?, mayReason: Bool = true) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.mayReason = mayReason
    }

    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case disabled
        case noBrainSlot
        case unknownProvider(String)
        case notALanguageModelProvider(String)

        public var description: String {
            switch self {
            case .disabled: "Dictation cleanup is turned off."
            case .noBrainSlot: "Neither the brain-fast slot nor the brain slot is set, so there is no model to clean up dictation with."
            case .unknownProvider(let id): "No provider named \"\(id)\" is configured."
            case .notALanguageModelProvider(let id): "Provider \"\(id)\" does not serve language models."
            }
        }
    }

    public static func resolve(config: OpenClickyConfig, cleanup: DictationSettings.Cleanup,
                               catalog: ModelCatalog? = nil) -> Result<DictationCleanupModelChoice, Problem> {
        guard cleanup.enabled else { return .failure(.disabled) }
        let slot = config.selection(for: .brainFast)
        guard let providerID = nonBlank(cleanup.provider) ?? slot?.provider else { return .failure(.noBrainSlot) }
        guard let provider = config.provider(providerID) else { return .failure(.unknownProvider(providerID)) }
        guard provider.dialect.servableKinds.contains(.languageModel) else { return .failure(.notALanguageModelProvider(providerID)) }
        guard let model = nonBlank(cleanup.model) ?? nonBlank(slot?.model) else { return .failure(.noBrainSlot) }
        let descriptor = catalog?.merging(config.models).model(model, servedBy: provider.dialect)
        let mayReason = descriptor.map { $0.capabilities.contains(.reasoning) } ?? true
        let effort = nonBlank(cleanup.reasoningEffort) ?? descriptor?.reasoningEfforts?.first
            ?? (mayReason ? quickestEffort(model: model) : nil)
        return .success(DictationCleanupModelChoice(provider: provider, model: model, reasoningEffort: effort, mayReason: mayReason))
    }

    /// The lowest reasoning effort for models whose catalog entry lists none. Left at the provider's default, the
    /// original GPT-5 family (gpt-5, -mini, -nano) reasons at "medium" and took over 6 s on a one-sentence cleanup, so
    /// every live try fell back to the local tidy; at "minimal" gpt-5-nano answered in about 1.3 s ("low" still timed
    /// out). Other models keep their default.
    static func quickestEffort(model: String) -> String? {
        let name = (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
        let family = ["gpt-5", "gpt-5-mini", "gpt-5-nano"]
        return family.contains(where: { name == $0 || name.hasPrefix($0 + "-20") }) ? "minimal" : nil
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func options(_ cleanup: DictationSettings.Cleanup) -> DictationCleanupOptions {
        DictationCleanupOptions(model: model, reasoningEffort: reasoningEffort, minimumWords: cleanup.minimumWords,
                                timeout: cleanup.timeoutSeconds, reasoningTokenHeadroom: mayReason ? 1024 : 0)
    }
}

/// Builds language-model clients for a provider. `AdapterModelClientFactory` is the real one; tests use stubs.
public protocol DictationModelClientFactory: Sendable {
    func supports(_ dialect: ProviderDialect) -> Bool
    func makeClient(provider: ProviderConfig, apiKey: String?) -> (any LanguageModelClient)?
}

/// A factory with no adapters: cleanup always resolves to the fake model (or, in the app, to the local tidy).
public struct NoModelClientFactory: DictationModelClientFactory {
    public init() {}
    public func supports(_ dialect: ProviderDialect) -> Bool { false }
    public func makeClient(provider: ProviderConfig, apiKey: String?) -> (any LanguageModelClient)? { nil }
}

/// Decides between a real cleanup client and the fake one. A real client needs an adapter for the provider's dialect
/// and, when the provider names a credential, that credential in the store. The store is only consulted when an
/// adapter exists.
public enum DictationCleanupClientResolver {
    public enum Resolution: Sendable {
        case real(any LanguageModelClient, DictationCleanupModelChoice)
        case fake(reason: String)

        public var isReal: Bool { if case .real = self { true } else { false } }
    }

    public static func resolve(choice: Result<DictationCleanupModelChoice, DictationCleanupModelChoice.Problem>,
                               factory: any DictationModelClientFactory, credentials: any CredentialStore) -> Resolution {
        let resolved: DictationCleanupModelChoice
        switch choice {
        case .failure(let problem): return .fake(reason: problem.description)
        case .success(let value): resolved = value
        }
        let choice = resolved
        guard factory.supports(choice.provider.dialect) else {
            return .fake(reason: "this build has no \(choice.provider.dialect.rawValue) adapter")
        }
        var key: String?
        if !choice.provider.dialect.isOnDevice, let name = choice.provider.credential {
            // An empty secret counts as missing, as it does for the engine factory: it could only ever get a 401.
            key = ((try? credentials.secret(named: name)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            guard key != nil else { return .fake(reason: "no credential \"\(name)\" is stored") }
        }
        guard let client = factory.makeClient(provider: choice.provider, apiKey: key) else {
            return .fake(reason: "the \(choice.provider.dialect.rawValue) adapter could not be built")
        }
        return .real(client, choice)
    }
}

/// A stand-in cleanup model that never touches the network: it reads the transcript out of the request and applies
/// simple rules (hesitations, self-corrections marked with "no" / "I mean", spacing, sentence case, a final period).
/// It records every request so the assembled prompt can be inspected.
public final class FakeCleanupModel: LanguageModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatRequest] = []

    public init() {}

    public var requests: [ChatRequest] { lock.withLock { recorded } }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { recorded.append(request) }
        let user = request.messages.last { $0.role == .user }?.text ?? ""
        let transcript = Self.between(user, "<transcript>\n", "\n</transcript>") ?? user
        let system = request.messages.first?.text ?? ""
        let singleLine = system.contains("single line")
        let literal = system.contains("terminal prompt") || system.contains("code editor")
        // Continue a sentence the caret is in the middle of.
        let before = user.components(separatedBy: "\n").first { $0.hasPrefix("text before caret: ") }
            .map { String($0.dropFirst("text before caret: ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) } ?? ""
        let midSentence = !before.isEmpty && !(before.hasSuffix(".") || before.hasSuffix("!") || before.hasSuffix("?") || before.hasSuffix("\\n"))
        let reply = Self.rewrite(transcript, singleLine: singleLine, sentenceCase: !literal && !midSentence, finalPeriod: !literal)
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }

    static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, options: .backwards), a.upperBound <= b.lowerBound else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }

    static func rewrite(_ transcript: String, singleLine: Bool, sentenceCase: Bool = true, finalPeriod: Bool = true) -> String {
        var text = LocalTidy.apply(transcript, context: FocusContext(beforeText: sentenceCase ? "" : "…"))
        // "at three, no, at four" → "at four": drop the phrase before a spoken correction marker.
        for marker in [", no, ", ", sorry, ", ", I mean, ", " no wait "] {
            while let range = text.range(of: marker, options: .caseInsensitive) {
                let head = text[..<range.lowerBound]
                let cut = head.range(of: " ", options: .backwards).map { head[..<$0.lowerBound] } ?? ""
                let dropped = head.split(separator: " ").count > 2 ? String(cut) : ""
                text = (dropped.isEmpty ? "" : dropped + " ") + text[range.upperBound...]
            }
        }
        // Collapse a word said twice in a row ("the the").
        var words: [Substring] = []
        for word in text.split(separator: " ") where words.last?.lowercased() != word.lowercased() { words.append(word) }
        text = words.joined(separator: " ")
        if sentenceCase, let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if finalPeriod, let last = text.last, !".!?".contains(last), !singleLine { text += "." }
        return text
    }
}

extension DictationCleanupClientResolver {
    /// The cleaner the app should use: a real model client when one can be built, otherwise nil (the local tidy
    /// only). The fake model is never used for real typing.
    public static func makeCleaner(config: OpenClickyConfig, settings: DictationSettings, catalog: ModelCatalog?,
                                   factory: any DictationModelClientFactory, credentials: any CredentialStore) -> DictationCleaner? {
        let choice = DictationCleanupModelChoice.resolve(config: config, cleanup: settings.cleanup, catalog: catalog)
        guard case .real(let client, let chosen) = resolve(choice: choice, factory: factory, credentials: credentials) else { return nil }
        return DictationCleaner(client: client, options: chosen.options(settings.cleanup))
    }
}
