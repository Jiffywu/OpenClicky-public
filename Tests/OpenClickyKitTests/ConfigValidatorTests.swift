import Foundation
import Testing
@testable import OpenClickyKit

private let keys = InMemoryCredentialStore(["openai": "sk-test", "deepgram": "dg-test", "anthropic": "ak-test", "openrouter": "or-test"])

private func validator() throws -> ConfigValidator {
    ConfigValidator(catalog: try .builtIn(), credentials: keys)
}

private func errors(_ issues: [ConfigIssue], _ slot: SlotID? = nil) -> [ConfigIssue] {
    issues.filter { $0.severity == .error && (slot == nil || $0.slot == slot) }
}

@Test func builtInCatalogLoadsAndCoversEveryKind() throws {
    let catalog = try ModelCatalog.builtIn()
    for kind in ModelKind.allCases {
        #expect(catalog.models.contains { $0.kind == kind }, "no \(kind) model in catalog")
    }
}

@Test func heyClickyLikeDefaultsAreValid() throws {
    let issues = try validator().validate(.heyClickyLike)
    #expect(errors(issues).isEmpty, "\(issues)")
}

@Test func speechModelIsRejectedFromBrain() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.providers.append(ProviderConfig(id: "openai-tts", dialect: .openAISpeech, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"))
    config.slots[.brain] = SlotSelection(provider: "openai-tts", model: "gpt-4o-mini-tts")
    let brainErrors = errors(try validator().validate(config), .brain)
    #expect(brainErrors.count == 1)
    #expect(brainErrors.first?.message.contains("can't serve a language model") == true)
}

@Test func speechModelNameOnLanguageProviderIsRejectedByKind() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.brain] = SlotSelection(provider: "openai", model: "gpt-realtime-2.1-mini")
    let brainErrors = errors(try validator().validate(config), .brain)
    #expect(brainErrors.first?.message.contains("is a realtime speech model") == true)
}

@Test func languageModelIsRejectedFromVoice() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.voice] = SlotSelection(provider: "openai", model: "gpt-6.1-sol")
    #expect(!errors(try validator().validate(config), .voice).isEmpty)
}

@Test func nonVisionLocalModelIsAllowedInBrainWithWarning() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.providers.append(ProviderConfig(id: "ollama", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:11434/v1")))
    config.models = [ModelDescriptor(id: "qwen3-coder:30b", kind: .languageModel,
                                     capabilities: [.textInput, .textOutput, .toolCalling, .streaming], dialects: [.openAIChat])]
    config.slots[.brain] = SlotSelection(provider: "ollama", model: "qwen3-coder:30b")
    let issues = try validator().validate(config).filter { $0.slot == .brain }
    #expect(errors(issues).isEmpty, "\(issues)")
    #expect(issues.contains { $0.severity == .warning && $0.message.contains("image-input") })
}

@Test func modelWithoutToolCallingIsRejectedFromBrain() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.providers.append(ProviderConfig(id: "lmstudio", dialect: .openAIChat, baseURL: URL(string: "http://localhost:1234/v1")))
    config.models = [ModelDescriptor(id: "tiny-chat", kind: .languageModel, capabilities: [.textInput, .textOutput, .streaming])]
    config.slots[.brain] = SlotSelection(provider: "lmstudio", model: "tiny-chat")
    let brainErrors = errors(try validator().validate(config), .brain)
    #expect(brainErrors.first?.message.contains("tool-calling") == true)
}

@Test func claudeCodeHarnessNeedsAnthropicDialect() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.agent] = SlotSelection(provider: "openai", model: "gpt-6-luna", harness: .claudeCode)
    #expect(errors(try validator().validate(config), .agent).first?.message.contains("claude-code harness can't use openai-responses") == true)

    config.providers.append(ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"))
    config.slots[.agent] = SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5", harness: .claudeCode)
    #expect(errors(try validator().validate(config), .agent).isEmpty)
}

@Test func agentSlotRequiresHarness() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.agent] = SlotSelection(provider: "openai", model: "gpt-6-luna")
    #expect(errors(try validator().validate(config), .agent).first?.message.contains("needs a harness") == true)
}

@Test func missingCredentialIsAnError() throws {
    let validator = ConfigValidator(catalog: try .builtIn(), credentials: InMemoryCredentialStore(["openai": "sk"]))
    let issues = validator.validate(.heyClickyLike)
    #expect(errors(issues).contains { $0.message.contains("\"deepgram\"") })
    let none = ConfigValidator(catalog: try .builtIn(), credentials: InMemoryCredentialStore()).validate(.heyClickyLike)
    #expect(errors(none).filter { $0.message.contains("\"openai\"") }.count == 1, "a shared credential is reported once")
}

@Test func remotePlainHTTPProviderIsRejected() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.providers[0].baseURL = URL(string: "http://api.example.com/v1")
    #expect(errors(try validator().validate(config)).contains { $0.message.contains("unencrypted") })
}

@Test func unknownVoiceIsRejected() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.voice]?.voice = "gandalf"
    #expect(errors(try validator().validate(config), .voice).first?.message.contains("no voice \"gandalf\"") == true)
}

@Test func unknownModelAsksForDeclaration() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.brain] = SlotSelection(provider: "openai", model: "gpt-99")
    #expect(errors(try validator().validate(config), .brain).first?.message.contains("Declare it under \"models\"") == true)
}

@Test func voiceCandidatesFromRealtimeDialect() throws {
    let ids = try ModelCatalog.builtIn().candidates(for: .voice, dialect: .openAIRealtime).map(\.id)
    #expect(ids.contains("gpt-realtime-2.1-mini"))
    #expect(try ModelCatalog.builtIn().candidates(for: .brain, dialect: .openAIRealtime).isEmpty)
}

@Test func configRoundTripsThroughJSON() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try OpenClickyConfig.heyClickyLike.save(to: url)
    #expect(try OpenClickyConfig.load(from: url) == .heyClickyLike)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("sk-"), "config must never contain secrets")
}

@Test func environmentOverridesKeychainName() throws {
    #expect(KeychainCredentialStore.environmentVariable(for: "open-router") == "OPENCLICKY_KEY_OPEN_ROUTER")
    let store = KeychainCredentialStore(environment: ["OPENCLICKY_KEY_ZZ_TEST": "value"])
    #expect(try store.secret(named: "zz-test") == "value")
}

@Test func optionalSlotsMayBeEmptyAndBrainFastFallsBack() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.slots[.brainFast] = nil
    config.slots[.realtimeVoice] = nil
    #expect(errors(try validator().validate(config)).isEmpty)
    #expect(config.selection(for: .brainFast) == config.slots[.brain])
    #expect(config.selection(for: .realtimeVoice) == nil)
}

@Test func textOnlyModelFitsBrainFastButNotRealtime() throws {
    var config = OpenClickyConfig.heyClickyLike
    config.providers.append(ProviderConfig(id: "ollama", dialect: .openAIChat, baseURL: URL(string: "http://127.0.0.1:11434/v1")))
    config.models = [ModelDescriptor(id: "llama3.2:3b", kind: .languageModel, capabilities: [.textInput, .textOutput, .streaming])]
    config.slots[.brainFast] = SlotSelection(provider: "ollama", model: "llama3.2:3b")
    #expect(errors(try validator().validate(config), .brainFast).isEmpty)
    config.slots[.realtimeVoice] = SlotSelection(provider: "openai", model: "gpt-6.1-sol")
    #expect(!errors(try validator().validate(config), .realtimeVoice).isEmpty)
}
