import Foundation
import Testing
@testable import OpenClickyKit

@Suite struct EngineFactoryTests {
    static let catalog = try! ModelCatalog.builtIn()

    static let providers: [ProviderConfig] = [
        ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
        ProviderConfig(id: "openai-chat", dialect: .openAIChat, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
        ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
        ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"), credential: "openai"),
        ProviderConfig(id: "openai-speech", dialect: .openAISpeech, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
        ProviderConfig(id: "openai-transcription", dialect: .openAITranscription, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
        ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"), credential: "deepgram"),
        ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
        ProviderConfig(id: "apple-speech", dialect: .appleSpeech),
        ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis),
    ]

    static let allKeys = InMemoryCredentialStore(["openai": "sk-openai-SECRET", "anthropic": "sk-ant-SECRET",
                                                  "deepgram": "dg-SECRET", "elevenlabs": "el-SECRET"])

    static func factory(_ slots: [SlotID: SlotSelection], credentials: any CredentialStore = allKeys) -> EngineFactory {
        EngineFactory(config: OpenClickyConfig(providers: providers, slots: slots), catalog: catalog, credentials: credentials,
                      http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
    }

    // MARK: - Dialect to adapter

    @Test(arguments: [
        (SlotSelection(provider: "openai", model: "gpt-6.1-sol"), "OpenAIResponsesClient"),
        (SlotSelection(provider: "openai-chat", model: "gpt-6.1-sol"), "OpenAIChatClient"),
        (SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5"), "AnthropicMessagesClient"),
    ])
    func languageModelDialectsMapToTheirAdapters(_ selection: SlotSelection, _ adapter: String) throws {
        let client = try Self.factory([.brain: selection]).languageModel(for: .brain)
        #expect(String(describing: Swift.type(of: client)) == adapter)
        #expect(EngineFactory.adapterName(for: try #require(Self.providers.first { $0.id == selection.provider }).dialect) == adapter)
        switch adapter {
        case "OpenAIResponsesClient": #expect(client is OpenAIResponsesClient)
        case "OpenAIChatClient": #expect(client is OpenAIChatClient)
        default: #expect(client is AnthropicMessagesClient)
        }
    }

    @Test func speechToTextDialectsMapToTheirAdapters() throws {
        let deepgram = try Self.factory([.stt: SlotSelection(provider: "deepgram", model: "nova-3")]).speechToText()
        #expect((deepgram as? DeepgramListenClient)?.model == "nova-3")
        let openAI = try Self.factory([.stt: SlotSelection(provider: "openai-transcription", model: "gpt-transcribe")]).speechToText()
        #expect((openAI as? OpenAITranscriptionClient)?.model == "gpt-transcribe")
        let apple = try Self.factory([.stt: SlotSelection(provider: "apple-speech", model: "on-device")]).speechToText()
        #expect(apple is AppleSpeechClient)
    }

    @Test func speechOutputDialectsMapToTheirAdaptersWithTheChosenVoice() async throws {
        let realtime = try Self.factory([.voice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1-mini", voice: "marin")])
            .speechOutput()
        #expect((realtime as? OpenAIRealtimeSpeechClient)?.model == "gpt-realtime-2.1-mini")
        #expect((realtime as? OpenAIRealtimeSpeechClient)?.defaultVoice == "marin")

        let speech = try Self.factory([.voice: SlotSelection(provider: "openai-speech", model: "gpt-4o-mini-tts", voice: "nova")]).speechOutput()
        #expect((speech as? OpenAISpeechClient)?.model == "gpt-4o-mini-tts")
        #expect((speech as? OpenAISpeechClient)?.defaultVoice == "nova")

        let eleven = try Self.factory([.voice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5", voice: "JBFqnCBsd6RMkjVDRZzb")])
            .speechOutput()
        #expect((eleven as? ElevenLabsSpeechClient)?.model == "eleven_flash_v2_5")
        #expect((eleven as? ElevenLabsSpeechClient)?.defaultVoice == "JBFqnCBsd6RMkjVDRZzb")

        let apple = try Self.factory([.voice: SlotSelection(provider: "apple-voices", model: "system", voice: "en-GB")]).speechOutput()
        #expect((apple as? AppleSpeechSynthesisClient)?.defaultVoice == "en-GB")
    }

    @Test func everyDialectHasAnAdapterName() {
        for dialect in ProviderDialect.allCases where dialect != .harnessLogin {
            #expect(EngineFactory.adapterName(for: dialect).hasSuffix("Client"))
        }
        #expect(EngineFactory.adapterName(for: .harnessLogin).hasPrefix("no client"))
    }

    // MARK: - Credentials

    @Test func missingCredentialIsReportedByName() throws {
        let factory = Self.factory([.brain: SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5")],
                                   credentials: InMemoryCredentialStore(["openai": "sk"]))
        #expect(throws: EngineFactoryError.missingCredential(slot: .brain, provider: "anthropic", credential: "anthropic")) {
            _ = try factory.languageModel(for: .brain)
        }
        let empty = Self.factory([.voice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5", voice: "v")],
                                 credentials: InMemoryCredentialStore(["elevenlabs": ""]))
        let error = #expect(throws: EngineFactoryError.self) { _ = try empty.speechOutput() }
        #expect(error?.description.contains("occtl key set elevenlabs") == true)
    }

    @Test func onDeviceDialectsNeedNoCredential() throws {
        let factory = Self.factory([.stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                                    .voice: SlotSelection(provider: "apple-voices", model: "system")],
                                   credentials: InMemoryCredentialStore())
        _ = try factory.speechToText()
        _ = try factory.speechOutput()
    }

    @Test func keyGoesOnlyIntoTheAdapterContext() throws {
        let factory = Self.factory([.brain: SlotSelection(provider: "openai", model: "gpt-6.1-sol")])
        let client = try #require(try factory.languageModel(for: .brain) as? OpenAIResponsesClient)
        #expect(client.context.apiKey == "sk-openai-SECRET")
        var dumped = ""
        dump(factory, to: &dumped)
        #expect(!dumped.contains("SECRET"))
        #expect(!String(describing: factory).contains("SECRET"))
        #expect(!String(describing: client).contains("SECRET"))
    }

    @Test func unreadableCredentialIsReported() {
        struct BrokenStore: CredentialStore {
            func secret(named name: String) throws -> String? { throw CredentialError.keychain(-25_293) }
            func setSecret(_ secret: String, named name: String) throws {}
            func removeSecret(named name: String) throws {}
        }
        let factory = Self.factory([.brain: SlotSelection(provider: "openai", model: "gpt-6.1-sol")], credentials: BrokenStore())
        let error = #expect(throws: EngineFactoryError.self) { _ = try factory.languageModel(for: .brain) }
        guard case .unreadableCredential(.brain, "openai", _)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
    }

    // MARK: - Slots

    @Test func brainFastFallsBackToTheBrain() throws {
        let factory = Self.factory([.brain: SlotSelection(provider: "anthropic", model: "claude-opus-5-5")])
        let resolution = try factory.resolve(.brainFast)
        #expect(resolution.sourceSlot == .brain)
        #expect(resolution.selection.model == "claude-opus-5-5")
        #expect(try factory.languageModel(for: .brainFast) is AnthropicMessagesClient)

        let own = Self.factory([.brain: SlotSelection(provider: "anthropic", model: "claude-opus-5-5"),
                                .brainFast: SlotSelection(provider: "openai", model: "gpt-5.4-mini")])
        #expect(try own.resolve(.brainFast).sourceSlot == .brainFast)
        #expect(try own.languageModel(for: .brainFast) is OpenAIResponsesClient)
    }

    @Test func emptySlotsAreRefused() {
        let factory = Self.factory([:])
        #expect(throws: EngineFactoryError.slotEmpty(.brain)) { _ = try factory.languageModel(for: .brain) }
        #expect(throws: EngineFactoryError.slotEmpty(.brainFast)) { _ = try factory.languageModel(for: .brainFast) }
        #expect(throws: EngineFactoryError.slotEmpty(.stt)) { _ = try factory.speechToText() }
        #expect(throws: EngineFactoryError.slotEmpty(.voice)) { _ = try factory.speechOutput() }
    }

    @Test func slotsWithValidationErrorsAreRefused() throws {
        // A speech model in the brain slot.
        let wrongKind = Self.factory([.brain: SlotSelection(provider: "openai", model: "gpt-4o-mini-tts")])
        let error = #expect(throws: EngineFactoryError.self) { _ = try wrongKind.languageModel(for: .brain) }
        guard case .invalidSlot(.brain, let issues)? = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(issues.contains { $0.message.contains("text-to-speech") })

        // The agent slot without a harness, a provider that does not exist, a voice the model lacks.
        #expect(throws: EngineFactoryError.self) {
            _ = try Self.factory([.agent: SlotSelection(provider: "openai", model: "gpt-6-luna")]).languageModel(for: .agent)
        }
        #expect(throws: EngineFactoryError.self) {
            _ = try Self.factory([.brain: SlotSelection(provider: "nowhere", model: "gpt-6.1-sol")]).languageModel(for: .brain)
        }
        #expect(throws: EngineFactoryError.self) {
            _ = try Self.factory([.voice: SlotSelection(provider: "openai-speech", model: "gpt-4o-mini-tts", voice: "nobody")]).speechOutput()
        }
        // Errors elsewhere in the config do not block a valid slot.
        let mixed = Self.factory([.brain: SlotSelection(provider: "openai", model: "gpt-6.1-sol"),
                                  .stt: SlotSelection(provider: "openai", model: "nova-3")])
        #expect(try mixed.languageModel(for: .brain) is OpenAIResponsesClient)
    }

    @Test func insecureProviderIsRefused() throws {
        var config = OpenClickyConfig(providers: [ProviderConfig(id: "remote", dialect: .openAIChat,
                                                                 baseURL: URL(string: "http://example.com/v1"), credential: "openai")],
                                      slots: [.brain: SlotSelection(provider: "remote", model: "gpt-6.1-sol")])
        let factory = EngineFactory(config: config, catalog: Self.catalog, credentials: Self.allKeys, http: FakeHTTPTransport([]))
        let error = #expect(throws: EngineFactoryError.self) { _ = try factory.languageModel(for: .brain) }
        #expect(error?.description.contains("unencrypted") == true)
        config.providers[0].baseURL = URL(string: "http://127.0.0.1:11434/v1")
        let local = EngineFactory(config: config, catalog: Self.catalog, credentials: Self.allKeys, http: FakeHTTPTransport([]))
        #expect(try local.languageModel(for: .brain) is OpenAIChatClient)
    }

    @Test func wrongSlotForTheMethodIsRefused() throws {
        let factory = Self.factory([.stt: SlotSelection(provider: "deepgram", model: "nova-3")])
        #expect(throws: EngineFactoryError.self) { _ = try factory.languageModel(for: .stt) }
    }

    @Test func userDeclaredModelsAreHonoured() throws {
        let local = ModelDescriptor(id: "qwen3-coder", kind: .languageModel, capabilities: [.textInput, .textOutput, .toolCalling, .streaming])
        let config = OpenClickyConfig(providers: [ProviderConfig(id: "ollama", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:11434/v1"))],
                                      models: [local], slots: [.brain: SlotSelection(provider: "ollama", model: "qwen3-coder")])
        let factory = EngineFactory(config: config, catalog: Self.catalog, credentials: InMemoryCredentialStore(), http: FakeHTTPTransport([]))
        let client = try #require(try factory.languageModel(for: .brain) as? OpenAIChatClient)
        _ = client
    }

    @Test func builtClientUsesTheInjectedTransport() async throws {
        let fake = FakeHTTPTransport([.sse("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")])
        let factory = EngineFactory(config: OpenClickyConfig(providers: Self.providers,
                                                             slots: [.brain: SlotSelection(provider: "openai-chat", model: "gpt-6.1-sol")]),
                                    catalog: Self.catalog, credentials: Self.allKeys, http: fake)
        let reply = try await factory.languageModel(for: .brain).complete(ChatRequest(model: "gpt-6.1-sol", messages: [.user(.text("Hi"))]))
        #expect(reply.text == "Hi")
        #expect(fake.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai-SECRET")
    }
}
