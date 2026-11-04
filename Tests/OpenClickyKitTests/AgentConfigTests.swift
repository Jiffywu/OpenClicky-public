import Foundation
import Testing
@testable import OpenClickyKit

private func validator(_ secrets: [String: String] = [:]) throws -> ConfigValidator {
    ConfigValidator(catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore(secrets))
}

private func config(agent: SlotSelection, providers extra: [ProviderConfig] = []) -> OpenClickyConfig {
    var config = OpenClickyConfig.heyClickyLike
    config.providers += [ProviderConfig(id: "codex-login", dialect: .harnessLogin)] + extra
    config.slots[.agent] = agent
    return config
}

private func agentIssues(_ config: OpenClickyConfig, secrets: [String: String] = ["openai": "k", "deepgram": "k"]) throws -> [ConfigIssue] {
    try validator(secrets).validate(config).filter { $0.slot == .agent || $0.slot == nil }
}

@Test func harnessLoginFillsTheAgentSlotWithoutAKeyOrEndpoint() throws {
    #expect(ProviderDialect(rawValue: "harness-login") == .harnessLogin)
    #expect(!ProviderDialect.harnessLogin.needsBaseURL)
    #expect(!ProviderDialect.harnessLogin.isOnDevice)
    // No OpenClicky client talks to it, so nothing that wants a language model (brain, dictation cleanup) takes it.
    #expect(ProviderDialect.harnessLogin.servableKinds.isEmpty)
    #expect(ProviderDialect.openAIResponses.needsBaseURL && !ProviderDialect.appleSpeech.needsBaseURL)

    // "default" lets the harness pick; any name the catalog doesn't know is the harness's business.
    for model in ["default", "gpt-6-luna", "some-new-model", ""] {
        let issues = try agentIssues(config(agent: SlotSelection(provider: "codex-login", model: model, harness: .codex)))
        #expect(issues.isEmpty, "\(model): \(issues)")
    }
    let claude = try agentIssues(config(agent: SlotSelection(provider: "codex-login", model: "default", harness: .claudeCode)))
    #expect(claude.isEmpty)
}

@Test func harnessLoginIsCheckedLikeTheSlotItFills() throws {
    let noHarness = try agentIssues(config(agent: SlotSelection(provider: "codex-login", model: "default")))
    #expect(noHarness.contains { $0.severity == .error && $0.message.contains("needs a harness") })

    // A model the catalog knows must still be a language model that fits the agent slot.
    let speech = try agentIssues(config(agent: SlotSelection(provider: "codex-login", model: "gpt-realtime-2.1-mini", harness: .codex)))
    #expect(speech.contains { $0.severity == .error })

    var brain = config(agent: SlotSelection(provider: "openai", model: "gpt-6-luna", harness: .codex))
    brain.slots[.brain] = SlotSelection(provider: "codex-login", model: "default")
    let brainIssues = try validator(["openai": "k"]).validate(brain).filter { $0.slot == .brain }
    #expect(brainIssues.contains { $0.message.contains("only fills the agent slot") })

    let voice = try validator().validate({ var c = brain; c.slots[.brain] = .init(provider: "openai", model: "gpt-6.1-sol"); c.slots[.voice] = .init(provider: "codex-login", model: "default"); return c }())
        .filter { $0.slot == .voice }
    #expect(voice.contains { $0.severity == .error && $0.message.contains("only fills the agent slot") })
}

@Test func harnessLoginNeverStandsInForALanguageModel() throws {
    // Dictation cleanup (and anything else that wants a chat client) refuses it instead of failing later.
    let base = config(agent: SlotSelection(provider: "codex-login", model: "default", harness: .codex))
    let cleanup = DictationSettings.Cleanup(provider: "codex-login", model: "default")
    guard case .failure(.notALanguageModelProvider("codex-login")) = DictationCleanupModelChoice.resolve(config: base, cleanup: cleanup) else {
        Issue.record("dictation cleanup accepted the harness's own login")
        return
    }
    #expect(EngineFactory.adapterName(for: .harnessLogin).hasPrefix("no client"))
}

@Test func harnessLoginIgnoresACredentialAndNeedsNoBaseURL() throws {
    let withKey = config(agent: SlotSelection(provider: "login", model: "default", harness: .codex),
                         providers: [ProviderConfig(id: "login", dialect: .harnessLogin, credential: "nope")])
    let issues = try agentIssues(withKey)
    #expect(issues.contains { $0.severity == .warning && $0.message.contains("credential is ignored") })
    #expect(!issues.contains { $0.severity == .error })

    let codable = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"id":"login","dialect":"harness-login"}"#.utf8))
    #expect(codable.dialect == .harnessLogin)
}

@Test func launchSettingsFromConfig() throws {
    let secrets = InMemoryCredentialStore(["openai": "sk-openai", "anthropic": "sk-ant"])
    var base = OpenClickyConfig.heyClickyLike
    base.providers.append(ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"))
    base.providers.append(ProviderConfig(id: "login", dialect: .harnessLogin))
    base.harnesses = [.codex: HarnessSettings(executable: "~/bin/codex", extraArguments: ["--enable", "x"])]

    // Bring your own key: the slot's provider, model and key.
    let byok = try AgentLaunchSettings.fromConfig(base, credentials: secrets)
    #expect(byok.harness == .codex)
    #expect(byok.model == "gpt-6-luna")
    #expect(byok.providerID == "openai")
    guard case .provider(let provider, let key) = byok.auth else { Issue.record("expected a provider"); return }
    #expect(provider.id == "openai" && key == "sk-openai")
    #expect(byok.executable?.path == NSHomeDirectory() + "/bin/codex")
    #expect(byok.extraArguments == ["--enable", "x"])

    // --login on a keyed slot: the harness's own sign-in and its default model.
    let forced = try AgentLaunchSettings.fromConfig(base, credentials: secrets, forceLogin: true)
    #expect(forced.auth.isLogin && forced.providerID == "harness-login" && forced.model == nil)
    let forcedModel = try AgentLaunchSettings.fromConfig(base, credentials: secrets, forceLogin: true, model: "gpt-5.5")
    #expect(forcedModel.model == "gpt-5.5")

    // A harness-login slot keeps its model; "default" means the harness's.
    var login = base
    login.slots[.agent] = SlotSelection(provider: "login", model: "default", harness: .claudeCode)
    let loginSettings = try AgentLaunchSettings.fromConfig(login, credentials: InMemoryCredentialStore())
    #expect(loginSettings.harness == .claudeCode && loginSettings.auth.isLogin && loginSettings.model == nil)
    login.slots[.agent]?.model = "sonnet"
    #expect(try AgentLaunchSettings.fromConfig(login, credentials: InMemoryCredentialStore()).model == "sonnet")
    // Switching harness for one job drops a model named for the other harness.
    #expect(try AgentLaunchSettings.fromConfig(login, credentials: InMemoryCredentialStore(), harness: .codex).model == nil)

    // Claude Code with the Anthropic provider.
    var claude = base
    claude.slots[.agent] = SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5", harness: .claudeCode)
    let claudeSettings = try AgentLaunchSettings.fromConfig(claude, credentials: secrets)
    guard case .provider(let anthropic, let anthropicKey) = claudeSettings.auth else { Issue.record("expected a provider"); return }
    #expect(anthropic.id == "anthropic" && anthropicKey == "sk-ant")

    // Mismatches and missing keys are explained.
    #expect(throws: AgentManagerError.self) { try AgentLaunchSettings.fromConfig(base, credentials: secrets, harness: .claudeCode) }
    #expect(throws: AgentManagerError.configuration(CredentialError.missing("openai").description)) {
        try AgentLaunchSettings.fromConfig(base, credentials: InMemoryCredentialStore())
    }
    var empty = base
    empty.slots[.agent] = nil
    #expect(throws: AgentManagerError.self) { try AgentLaunchSettings.fromConfig(empty, credentials: secrets) }
}
