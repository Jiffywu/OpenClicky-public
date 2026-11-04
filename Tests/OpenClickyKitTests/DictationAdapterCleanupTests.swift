import Foundation
import Testing
@testable import OpenClickyKit

/// Cleanup through the real provider adapters, against scripted HTTP. No network; the key is a placeholder that the
/// tests only check is forwarded.
@Suite struct DictationAdapterCleanupTests {
    static let placeholderKey = "sk-test-not-a-real-key"

    static func chatSSE(_ deltas: [String], finish: String = "stop") -> String {
        var lines = deltas.map { delta in
            #"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":\#(JSONValue.string(delta).jsonString())},"finish_reason":null}]}"#
        }
        lines.append(#"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"\#(finish)"}]}"#)
        lines.append("data: [DONE]")
        return lines.map { $0 + "\n\n" }.joined()
    }

    static func responsesSSE(_ text: String) -> String {
        let delta = #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":\#(JSONValue.string(text).jsonString()),"sequence_number":1}"#
        let done = #"{"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","model":"gpt-5.4-mini","output":[],"usage":{"input_tokens":120,"output_tokens":14,"total_tokens":134}},"sequence_number":2}"#
        return "event: response.output_text.delta\ndata: \(delta)\n\nevent: response.completed\ndata: \(done)\n\n"
    }

    /// A local OpenAI-compatible server in the brain-fast slot.
    static let chatConfig = OpenClickyConfig(
        providers: [ProviderConfig(id: "gateway", dialect: .openAIChat, baseURL: URL(string: "https://gateway.example/v1"), credential: "gateway")],
        slots: [.brain: SlotSelection(provider: "gateway", model: "big-model"),
                .brainFast: SlotSelection(provider: "gateway", model: "small-model")])

    @Test func theFactoryCoversTheLanguageModelDialects() {
        let factory = AdapterModelClientFactory(http: FakeHTTPTransport([]))
        for dialect in ProviderDialect.allCases {
            let provider = ProviderConfig(id: dialect.rawValue, dialect: dialect)
            let client = factory.makeClient(provider: provider, apiKey: nil)
            #expect(factory.supports(dialect) == dialect.servableKinds.contains(.languageModel))
            #expect((client != nil) == factory.supports(dialect))
        }
        #expect(factory.makeClient(provider: ProviderConfig(id: "a", dialect: .openAIResponses), apiKey: nil) is OpenAIResponsesClient)
        #expect(factory.makeClient(provider: ProviderConfig(id: "b", dialect: .openAIChat), apiKey: nil) is OpenAIChatClient)
        #expect(factory.makeClient(provider: ProviderConfig(id: "c", dialect: .anthropicMessages), apiKey: nil) is AnthropicMessagesClient)
    }

    @Test func cleanupGoesThroughTheChatAdapterWithTheFieldContext() async throws {
        let transport = FakeHTTPTransport([.sse(Self.chatSSE(["So we should ", "ship it on Friday."]), chunkSize: 7)])
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: Self.chatConfig, settings: DictationSettings(), catalog: try ModelCatalog.builtIn(),
            factory: AdapterModelClientFactory(http: transport), credentials: InMemoryCredentialStore(["gateway": Self.placeholderKey])))
        let focus = makeFocus("Plan: ", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        let result = await cleaner.clean("um so we should uh ship it on friday", context: focus.context, vocabulary: ["OpenClicky"])
        #expect(result.source == .model)
        #expect(result.text == "So we should ship it on Friday.")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://gateway.example/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.placeholderKey)")
        let body = try transport.jsonBody(0)
        #expect(body["model"] == "small-model")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"]?.stringValue?.contains("not a message to you") == true)
        #expect(messages[0]["content"]?.stringValue?.contains("chat message") == true)
        let user = try #require(messages[1]["content"]?.stringValue)
        #expect(user.contains("app: Slack"))
        #expect(user.contains("text before caret: \"Plan: \""))
        #expect(user.contains("<vocabulary>\nOpenClicky\n</vocabulary>"))
        #expect(user.hasSuffix("<transcript>\num so we should uh ship it on friday\n</transcript>"))
        // An unknown model may reason, so the output limit leaves room for it.
        #expect(((body["max_tokens"] ?? body["max_completion_tokens"])?.intValue ?? 0) >= 1024)
        #expect(body["tools"] == nil)
    }

    @Test func cleanupThroughTheResponsesAdapterIsStatelessAndUsesTheLowestEffort() async throws {
        let transport = FakeHTTPTransport([.sse(Self.responsesSSE("Can you send me the deck before Friday?"))])
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: .heyClickyLike, settings: DictationSettings(), catalog: try ModelCatalog.builtIn(),
            factory: AdapterModelClientFactory(http: transport), credentials: InMemoryCredentialStore(["openai": Self.placeholderKey])))
        let result = await cleaner.clean("can you uh send me the deck before friday", context: nil, vocabulary: [])
        // A question in the transcript is typed, not answered.
        #expect(result.source == .model)
        #expect(result.text == "Can you send me the deck before Friday?")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        let body = try transport.jsonBody(0)
        #expect(body["model"] == "gpt-5.4-mini")
        #expect(body["store"] == false)
        #expect(body["reasoning"]?["effort"] == "low")
        #expect(body["instructions"]?.stringValue?.hasPrefix("You turn raw speech-recognition output") == true)
    }

    @Test func aReplyCutOffByTheOutputLimitIsNotTyped() async throws {
        let transport = FakeHTTPTransport([.sse(Self.chatSSE(["So we should"], finish: "length"))])
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: Self.chatConfig, settings: DictationSettings(), catalog: nil,
            factory: AdapterModelClientFactory(http: transport), credentials: InMemoryCredentialStore(["gateway": Self.placeholderKey])))
        let result = await cleaner.clean("um so we should ship it on friday", context: nil, vocabulary: [])
        #expect(result.source == .fallback("reply cut off (length)"))
        #expect(result.text == "So we should ship it on friday")
    }

    @Test func providerErrorsFallBackToTheLocalTidyWithoutLeakingTheKey() async throws {
        let transport = FakeHTTPTransport([.body(#"{"error":{"message":"Incorrect API key provided: sk-test-****-key","type":"invalid_request_error"}}"#, status: 401)])
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: Self.chatConfig, settings: DictationSettings(), catalog: nil,
            factory: AdapterModelClientFactory(http: transport), credentials: InMemoryCredentialStore(["gateway": Self.placeholderKey])))
        let result = await cleaner.clean("please review the pull request today", context: nil, vocabulary: [])
        guard case .fallback(let why) = result.source else { Issue.record("expected a fallback"); return }
        #expect(why.contains("401"))
        #expect(!why.contains(Self.placeholderKey))
        #expect(result.text == "Please review the pull request today")
    }

    @Test func modelsTheCatalogSaysDontReasonGetNoThinkingRoom() throws {
        let config = OpenClickyConfig(
            providers: [ProviderConfig(id: "local", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:11434/v1"))],
            models: [ModelDescriptor(id: "tiny", kind: .languageModel, capabilities: [.textInput, .textOutput, .streaming],
                                     dialects: [.openAIChat])],
            slots: [.brain: SlotSelection(provider: "local", model: "tiny")])
        let choice = try DictationCleanupModelChoice.resolve(config: config, cleanup: .init(), catalog: try ModelCatalog.builtIn()).get()
        #expect(!choice.mayReason)
        let options = choice.options(.init())
        #expect(options.reasoningTokenHeadroom == 0)
        let request = DictationCleanupPrompt.request(transcript: String(repeating: "word ", count: 40), context: nil, vocabulary: [], options: options)
        #expect(request.maxOutputTokens == 164)
    }
}
