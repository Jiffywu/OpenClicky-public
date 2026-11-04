import Foundation
import os

/// What the engine factory adds around every engine it builds (docs/infra.md):
///
/// - **Retries.** HTTP adapters get a `RetryingHTTPTransport` with the slot's `RetryPolicy`; sessions that open over a
///   WebSocket (Deepgram, Gemini Live, OpenAI Realtime) are opened again on a retryable refusal.
/// - **Plain explanations.** When a listening, voice or always-on session still can't open, the provider is probed and
///   the error becomes a `ProviderUnavailableError` that says why (region, blocked network, offline, key, outage).
/// - **Usage.** Every call is written to the usage recorder (the ledger), and, when the user's limit stops calls,
///   refused with a `UsageLimitError`.
///
/// The app and `occtl` install one at launch (`ProviderResilience.install`). Factories built without one (tests, the
/// snapshot renderer) build bare adapters, exactly as before.
public final class ProviderResilience: Sendable {
    public struct Options: Sendable, Hashable {
        public var retries: Bool
        public var diagnose: Bool
        /// Per-slot overrides of `RetryPolicy.standard(for:)`.
        public var policies: [SlotID: RetryPolicy]
        /// "app" or "occtl", written on each usage record.
        public var client: String

        public init(retries: Bool = true, diagnose: Bool = true, policies: [SlotID: RetryPolicy] = [:], client: String = "app") {
            self.retries = retries
            self.diagnose = diagnose
            self.policies = policies
            self.client = client
        }
    }

    public let options: Options
    public let recorder: (any UsageRecording)?
    public let diagnostician: ProviderDiagnostician
    let sleep: @Sendable (TimeInterval) async throws -> Void
    let random: @Sendable () -> Double
    private let logger = Logger(subsystem: "app.openclicky", category: "providers")
    private let logSink: (@Sendable (String) -> Void)?

    public init(options: Options = Options(), recorder: (any UsageRecording)?, diagnostician: ProviderDiagnostician = ProviderDiagnostician(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                log: (@Sendable (String) -> Void)? = nil) {
        self.options = options
        self.recorder = recorder
        self.diagnostician = diagnostician
        self.sleep = sleep
        self.random = random
        self.logSink = log
    }

    /// The standard set-up: the usage ledger in Application Support, retries and diagnosis on unless the feature
    /// flags turn them off.
    ///
    /// - Parameter ledger: the ledger to write to when the flag keeps one (a new `UsageLedger()` when nil).
    public static func standard(client: String, flags: FeatureFlagStore = FeatureFlagStore(), ledger: UsageLedger? = nil) -> ProviderResilience {
        let options = Options(retries: flags.isOn(.providerRetries), diagnose: flags.isOn(.providerDiagnosis), client: client)
        return ProviderResilience(options: options, recorder: flags.isOn(.usageLedger) ? (ledger ?? UsageLedger()) : nil)
    }

    /// The feature flags `standard` reads. When one changes, install `refreshed(flags:)` so engines built from then on
    /// follow it.
    public static let flagsRead: Set<FeatureFlag> = [.providerRetries, .providerDiagnosis, .usageLedger]

    /// The standard set-up again, for the flags as they are now, keeping this one's client name and ledger (so
    /// anything following the ledger's records keeps following them).
    public func refreshed(flags: FeatureFlagStore) -> ProviderResilience {
        Self.standard(client: options.client, flags: flags, ledger: recorder as? UsageLedger)
    }

    // MARK: Installation

    private static let slot = OSAllocatedUnfairLock<ProviderResilience?>(initialState: nil)

    /// What new engine factories use by default; nil until the app or occtl installs one.
    public static var installed: ProviderResilience? { slot.withLock { $0 } }

    /// Sets what new engine factories use (nil removes it).
    public static func install(_ resilience: ProviderResilience?) { slot.withLock { $0 = resilience } }

    // MARK: Pieces

    public func policy(for slot: SlotID) -> RetryPolicy {
        options.retries ? (options.policies[slot] ?? .standard(for: slot)) : .none
    }

    /// The transport an adapter in `slot` should use.
    public func transport(_ base: any HTTPTransport, slot: SlotID) -> any HTTPTransport {
        let policy = policy(for: slot)
        guard policy.maxAttempts > 1 else { return base }
        return RetryingHTTPTransport(base: base, policy: policy, sleep: sleep, random: random) { [weak self] event in
            self?.log("\(slot.rawValue): \(event.description)")
        }
    }

    /// The transport lookups use: every request is counted in the ledger.
    public func lookupTransport(_ base: any HTTPTransport) -> any HTTPTransport {
        guard let recorder else { return base }
        return MeteredLookupTransport(base: base, recorder: recorder, prices: PriceBook(catalog: ModelCatalog(models: []),
                                                                                       services: PriceBook.builtInServicePrices()),
                                      client: options.client)
    }

    /// Opens a session (listening, always-on), retrying refusals that may pass, and turning a final failure into a
    /// plain `ProviderUnavailableError` when the provider can be probed.
    func open<T: Sendable>(slot: SlotID, provider: ProviderConfig, apiKey: @Sendable () -> String?,
                           _ operation: () async throws -> T) async throws -> T {
        let host = provider.baseURL?.host ?? provider.id
        do {
            if provider.dialect.opensOverWebSocket {
                return try await ProviderRetry.run(policy: policy(for: slot), host: host, sleep: sleep, random: random,
                                                   onRetry: { [weak self] in self?.log("\(slot.rawValue): \($0.description)") }, operation)
            }
            return try await operation()
        } catch {
            throw await explain(error, slot: slot, provider: provider, apiKey: apiKey)
        }
    }

    /// `error` explained when it is a connection failure a probe can account for; otherwise `error` itself.
    func explain(_ error: Error, slot: SlotID, provider: ProviderConfig, apiKey: @Sendable () -> String?) async -> Error {
        guard options.diagnose, !provider.dialect.isOnDevice, ProviderDiagnostician.shouldDiagnose(error), !Task.isCancelled else { return error }
        let diagnosis = await diagnostician.diagnose(provider: provider, apiKey: apiKey(), purpose: .init(slot: slot), failure: error)
        log("\(slot.rawValue): \(provider.id) \(diagnosis.verdict.rawValue): \(diagnosis.probe ?? "no probe")")
        let explained = ProviderUnavailableError(diagnosis: diagnosis, underlying: String(describing: error), providerError: error as? ProviderError)
        ProviderUnavailableFeed.publish(explained)
        return explained
    }

    func checkLimit() throws {
        guard let recorder else { return }
        let status = recorder.limitStatus()
        if status.blocksCalls { throw UsageLimitError(status: status) }
    }

    func log(_ text: String) {
        // Notice level: retries and diagnoses are rare and belong in the diagnostics bundle's log.
        logger.notice("\(text, privacy: .public)")
        logSink?(text)
    }
}

extension ProviderDialect {
    /// Sessions of these dialects open over a WebSocket, so the HTTP retry layer never sees their refusals.
    var opensOverWebSocket: Bool { self == .deepgramListen || self == .geminiLive || self == .openAIRealtime }
}

// MARK: - The factory's side

extension EngineFactory {
    /// Who the engines built here are metered and explained for.
    struct EngineIdentity: Sendable {
        var slot: SlotID
        var provider: ProviderConfig
        var model: String
        var prices: PriceBook
        var credentials: any CredentialStore
        var client: String

        /// The provider's key, read only when a probe needs it.
        var apiKey: @Sendable () -> String? {
            let credentials = credentials, provider = provider
            return { provider.credential.flatMap { try? credentials.secret(named: $0) } }
        }

        /// - Parameter estimated: the measure itself is an estimate (a reply that stopped before reporting its usage).
        func record(_ measure: UsageMeasure, turnFallbackSlot: String? = nil, estimated: Bool = false, recorder: any UsageRecording,
                    at: Date = Date()) {
            let context = UsageContext.current
            let price = prices.price(model: model, dialect: provider.dialect)
            let slotName = slot.rawValue
            recorder.record(UsageRecord(at: at, slot: slotName, surface: (context.surface ?? .fallback(for: slotName)).rawValue,
                                        provider: provider.id, model: model, turn: context.turnID, client: client, measure: measure,
                                        costUSD: price?.cost(of: measure), estimate: estimated ? true : price?.estimate))
        }
    }

    func identity(for slot: SlotID, resilience: ProviderResilience) -> EngineIdentity? {
        guard let resolution = try? resolve(slot), let provider = resolution.provider else { return nil }
        return EngineIdentity(slot: slot, provider: provider, model: resolution.selection.model,
                              prices: PriceBook(catalog: catalog.merging(config.models), services: [:]), credentials: credentials,
                              client: resilience.options.client)
    }
}

extension EngineFactory {
    /// The chat client for `.brain`, `.brainFast` (falls back to the brain's selection when empty) or `.agent` (the
    /// agent model; the harness that runs jobs is separate). Metered when `resilience` is set.
    public func languageModel(for slot: SlotID) throws -> any LanguageModelClient {
        let client = try bareLanguageModel(for: slot)
        guard let resilience, let identity = identity(for: slot, resilience: resilience) else { return client }
        return MeteredLanguageModelClient(base: client, identity: identity, resilience: resilience)
    }

    /// The speech-to-text client for the stt slot. With `resilience`, sessions open with retries and a plain
    /// explanation when they can't, and their audio is metered.
    public func speechToText() throws -> any SpeechToTextClient {
        let client = try bareSpeechToText()
        guard let resilience, let identity = identity(for: .stt, resilience: resilience) else { return client }
        let metered = MeteredSpeechToTextClient(base: client, identity: identity, resilience: resilience)
        if let warming = client as? any SpeechToTextWarming {
            return MeteredWarmingSpeechToTextClient(client: metered, warming: warming)
        }
        return metered
    }

    /// The client that speaks lines for the voice slot, using the selection's voice as its default. With
    /// `resilience`, lines are metered and a voice that can't connect says why.
    public func speechOutput() throws -> any SpeechOutputClient {
        let client = try bareSpeechOutput()
        guard let resilience, let identity = identity(for: .voice, resilience: resilience) else { return client }
        return MeteredSpeechOutputClient(base: client, identity: identity, resilience: resilience)
    }

    /// The realtime speech-to-speech client for the realtime-voice slot (always-on voice and the interview), using the
    /// selection's voice as its default. With `resilience`, sessions open with retries and a plain explanation, and
    /// replies are metered.
    public func realtimeVoice() throws -> any RealtimeVoiceClient {
        let client = try bareRealtimeVoice()
        guard let resilience, let identity = identity(for: .realtimeVoice, resilience: resilience) else { return client }
        return MeteredRealtimeVoiceClient(base: client, identity: identity, resilience: resilience)
    }

    /// The adapter inside a metered wrapper (for code that needs the concrete adapter, like Anthropic's computer tool).
    public static func unwrapped(_ client: any LanguageModelClient) -> any LanguageModelClient {
        (client as? MeteredLanguageModelClient)?.base ?? (client as? DictationMeteredClient)?.base ?? client
    }
}
