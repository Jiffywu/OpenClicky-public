import Foundation

/// Builds cleanup clients from the language-model adapters in this build: OpenAI Responses, OpenAI-compatible Chat
/// Completions (OpenRouter, Ollama, LM Studio, vLLM) and Anthropic Messages.
///
/// The cleanup model is named in each request, so one client per provider serves whatever model the dictation
/// settings pick. The key is handed only to the adapter's `ProviderContext`; this factory keeps nothing. Building a
/// client never touches the network.
///
/// With a `ProviderResilience` (the installed one by default) each client is metered like the other brain-fast calls:
/// its replies are written to the usage ledger under the dictation surface, and a stopping limit refuses the call (the
/// cleaner then falls back to the local tidy).
public struct AdapterModelClientFactory: DictationModelClientFactory {
    public var http: any HTTPTransport
    public var resilience: ProviderResilience?
    public var prices: PriceBook

    public init(http: any HTTPTransport = URLSessionTransport(), resilience: ProviderResilience? = ProviderResilience.installed,
                prices: PriceBook = .builtIn()) {
        self.http = http
        self.resilience = resilience
        self.prices = prices
    }

    public static let dialects: Set<ProviderDialect> = [.openAIResponses, .openAIChat, .anthropicMessages]

    public func supports(_ dialect: ProviderDialect) -> Bool { Self.dialects.contains(dialect) }

    public func makeClient(provider: ProviderConfig, apiKey: String?) -> (any LanguageModelClient)? {
        guard let client = bareClient(provider: provider, apiKey: apiKey) else { return nil }
        guard let resilience else { return client }
        let credentials = InMemoryCredentialStore(provider.credential.flatMap { name in apiKey.map { [name: $0] } } ?? [:])
        let identity = EngineFactory.EngineIdentity(slot: .brainFast, provider: provider, model: "", prices: prices, credentials: credentials,
                                                    client: resilience.options.client)
        return DictationMeteredClient(metered: MeteredLanguageModelClient(base: client, identity: identity, resilience: resilience))
    }

    private func bareClient(provider: ProviderConfig, apiKey: String?) -> (any LanguageModelClient)? {
        let context = ProviderContext(provider: provider, apiKey: apiKey, http: http)
        switch provider.dialect {
        case .openAIResponses: return OpenAIResponsesClient(context: context)
        case .openAIChat: return OpenAIChatClient(context: context)
        case .anthropicMessages:
            // Cleanup is one turn that is never continued, so its replies are not recorded in the process-wide
            // thinking store (where they would push out the brain's turns), and its reasoning isn't streamed back.
            return AnthropicMessagesClient(context: context, thinkingDisplay: "omitted",
                                           thinkingReplay: AnthropicThinkingReplay(capacity: 1))
        default: return nil
        }
    }
}

/// A metered cleanup client whose records land under the dictation surface (unless the caller set a surface).
public struct DictationMeteredClient: LanguageModelClient {
    public let metered: MeteredLanguageModelClient

    public var base: any LanguageModelClient { metered.base }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let context = UsageContext.current
        guard context.surface == nil else { return metered.stream(request) }
        return UsageContext.$current.withValue(UsageContext(surface: .dictation, turnID: context.turnID)) { metered.stream(request) }
    }
}
