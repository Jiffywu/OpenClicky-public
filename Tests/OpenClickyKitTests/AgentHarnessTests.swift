import Foundation
import Testing
@testable import OpenClickyKit

private let secret = "sk-test-SECRET-do-not-write-7f3a"
private let mcpToken = "mcp-token-SECRET-91c2"

private func baseEnvironment(_ temp: AgentTempDir, scenario: String, log: URL) -> [String: String] {
    ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": scenario, "FAKE_LOG": log.path,
     // Leftovers that must never reach a harness.
     "OPENCLICKY_KEY_OPENAI": secret, "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "outer", "ANTHROPIC_API_KEY": "user-shell-key"]
}

private func browserMCP() -> AgentMCPServer {
    AgentMCPServer(name: "browser", transport: .http(URL(string: "http://127.0.0.1:47011/mcp")!), bearerToken: mcpToken)
}

private func launch(_ temp: AgentTempDir, executable: URL, auth: HarnessAuth, scenario: String, log: URL, resume: String? = nil) throws -> HarnessLaunch {
    let folder = temp.paths.jobs.appendingPathComponent("job-1", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("output"), withIntermediateDirectories: true)
    return HarnessLaunch(folder: folder, instructions: "Test instructions.", model: "gpt-test", auth: auth, mcpServers: [browserMCP()],
                         resumeThreadID: resume, executable: executable, paths: temp.paths,
                         baseEnvironment: baseEnvironment(temp, scenario: scenario, log: log))
}

private let openAIProvider = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"),
                                            credential: "openai", headers: ["X-Title": "OpenClicky"])
private let anthropicProvider = ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")

// MARK: - Codex

@Test func codexRunnerReplaysATurnWithApprovalAndNeverWritesTheKey() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let session = try await CodexHarness().start(
        try launch(temp, executable: fake, auth: .provider(openAIProvider, apiKey: secret), scenario: "approve", log: log),
        message: "Write meeting notes", images: [])

    var events = await collect(session.events, until: { $0.approval != nil })
    let request = try #require(events.last?.approval)
    #expect(request.kind == .command)
    #expect(request.summary == "Run mkdir -p output")
    #expect(request.reason == "Needs network")
    try await session.respond(to: request.id, with: .approve(always: false))
    events += await collect(session.events, until: \.isTurnFinished)
    await session.close()

    #expect(events.contains(.sessionStarted(threadID: "thread-1")))
    #expect(events.contains(.progress("Running: mkdir -p output")))
    #expect(events.contains(.plan([AgentPlanStep(step: "Make the folder", status: .inProgress), AgentPlanStep(step: "Write notes", status: .pending)])))
    #expect(events.contains(.approvalResolved(id: request.id)))
    let folder = temp.paths.jobs.appendingPathComponent("job-1").standardizedFileURL.path
    #expect(events.contains(.fileChanged(path: folder + "/output/notes.md", change: "created")))
    #expect(events.contains(.usage(AgentTokenUsage(input: 120, cachedInput: 20, output: 30))))
    guard case .turnFinished(.completed, let final?, nil) = events.last else { Issue.record("no completed turn: \(events)"); return }
    let report = AgentFinalReport.parse(final)
    #expect(report.spoken == "Your notes are ready.")
    #expect(report.files == ["output/notes.md"])

    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains(#""decision":"accept""#))
    #expect(sent.contains(#""method":"thread/start""#))
    #expect(sent.contains(#""developerInstructions":"Test instructions.""#))
    #expect(sent.contains("env: OPENCLICKY_AGENT_API_KEY is set"))
    #expect(sent.contains("env: OPENCLICKY_MCP_TOKEN_BROWSER is set"))
    #expect(sent.contains("env: CODEX_HOME is set"))
    #expect(sent.contains("env: NO_PROXY has loopback"))
    #expect(!sent.contains("env: CLAUDECODE"))
    #expect(!sent.contains("env: ANTHROPIC_API_KEY"))

    // The generated CODEX_HOME config names the variables but holds neither secret, and no file anywhere does.
    let toml = try String(contentsOf: temp.paths.codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
    #expect(toml.contains(#"env_key = "OPENCLICKY_AGENT_API_KEY""#))
    #expect(toml.contains(#"bearer_token_env_var = "OPENCLICKY_MCP_TOKEN_BROWSER""#))
    #expect(toml.contains(#"wire_api = "responses""#))
    #expect(temp.filesContaining(secret).isEmpty)
    #expect(temp.filesContaining(mcpToken).isEmpty)
}

@Test func codexDeclineSkipsTheCommandAndTheTurnGoesOn() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let session = try await CodexHarness().start(
        try launch(temp, executable: try temp.script("codex", FakeHarnessScripts.codex), auth: .provider(openAIProvider, apiKey: secret), scenario: "approve", log: log),
        message: "Write meeting notes", images: [])
    let request = try #require(await collect(session.events, until: { $0.approval != nil }).last?.approval)
    try await session.respond(to: request.id, with: .decline)
    let events = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    #expect(events.contains(.progress("Skipped: mkdir -p output")))
    #expect(events.last.map { if case .turnFinished(.completed, _, _) = $0 { true } else { false } } == true)
    #expect(try String(contentsOf: log, encoding: .utf8).contains(#""decision":"decline""#))
}

@Test func codexFollowUpSteersTheRunningTurnAndInterruptStopsIt() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let session = try await CodexHarness().start(
        try launch(temp, executable: fake, auth: .provider(openAIProvider, apiKey: secret), scenario: "wait", log: log),
        message: "Write meeting notes", images: [])
    _ = await collect(session.events, until: { $0 == .progress("Running: mkdir -p output") })
    #expect(try await session.send("Also add a summary") == .steered)
    let steered = await collect(session.events, until: \.isTurnFinished)
    #expect(steered.contains { if case .turnFinished(.completed, _, _) = $0 { true } else { false } })
    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains(#""expectedTurnId":"turn-1""#))
    #expect(sent.contains("Also add a summary"))

    // The session is idle now; the next message starts a new turn, which we interrupt.
    #expect(try await session.send("One more thing") == .startedTurn)
    _ = await collect(session.events, until: { $0 == .progress("Running: mkdir -p output") })
    await session.interrupt()
    let stopped = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    #expect(stopped.last == .turnFinished(.interrupted, finalText: nil, error: nil))
    #expect(try String(contentsOf: log, encoding: .utf8).contains(#""method":"turn/interrupt""#))
}

@Test func codexResumesAThreadByID() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("codex.log")
    let session = try await CodexHarness().start(
        try launch(temp, executable: try temp.script("codex", FakeHarnessScripts.codex), auth: .provider(openAIProvider, apiKey: secret),
                   scenario: "quick", log: log, resume: "thread-1"),
        message: "Follow-up", images: [])
    _ = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains(#""method":"thread/resume""#))
    #expect(sent.contains(#""threadId":"thread-1""#))
}

@Test func codexPlanForBringYourOwnKey() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let plan = try CodexHarness().plan(for: try launch(temp, executable: fake, auth: .provider(openAIProvider, apiKey: secret), scenario: "quick", log: temp.url))
    #expect(plan.arguments == ["app-server"])
    #expect(plan.environment["CODEX_HOME"] == temp.paths.codexHome.path)
    #expect(plan.environment[CodexHarness.apiKeyVariable] == secret)
    #expect(plan.environment["OPENCLICKY_KEY_OPENAI"] == nil)
    #expect(plan.environment["CLAUDECODE"] == nil && plan.environment["CLAUDE_CODE_SESSION_ID"] == nil)
    let toml = try #require(plan.configTOML)
    #expect(!toml.contains(secret) && !toml.contains(mcpToken))
    #expect(toml.contains(#"model = "gpt-test""#))
    #expect(toml.contains(#"model_provider = "openclicky""#))
    #expect(toml.contains(#"base_url = "https://api.openai.com/v1""#))
    #expect(toml.contains(#"http_headers = { X-Title = "OpenClicky" }"#))
    #expect(toml.contains(#"approval_policy = "on-request""#))
    #expect(toml.contains(#"sandbox_mode = "workspace-write""#))
    #expect(toml.contains("[mcp_servers.browser]"))
    #expect(toml.contains(#"url = "http://127.0.0.1:47011/mcp""#))
    #expect(toml.contains("[projects.\"\(temp.paths.projects.path)\"]"))
    #expect(toml.contains("[features]\nplugins = false\napps = false"))
    #expect(!toml.contains(".enabled = false"))
}

@Test func codexLoginUsesItsOwnSignInWithoutWritingIntoTheUsersHome() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let launch = try launch(temp, executable: fake, auth: .harnessLogin, scenario: "quick", log: temp.url)

    // Not signed in inside OpenClicky's home: run on the user's Codex home, settings as -c overrides only, with the
    // user's own plugins, connectors and MCP servers switched off (ours stays on).
    let onUserHome = try CodexHarness(hasLogin: { _ in false }, listUserMCPServers: { _, _ in ["gigamail", "browser", "my server"] }).plan(for: launch)
    // All MCP settings in one inline table, first: Codex's -c parser can't address a quoted name like
    // `mcp_servers."my server".enabled` and then refuses to load its config (checked on codex-cli 0.165.0).
    let servers = #"mcp_servers={ browser = { bearer_token_env_var = "OPENCLICKY_MCP_TOKEN_BROWSER", startup_timeout_sec = 20, tool_timeout_sec = 900, url = "http://127.0.0.1:47011/mcp" }, gigamail = { enabled = false }, "my server" = { enabled = false } }"#
    #expect(Array(onUserHome.arguments.prefix(3)) == ["app-server", "-c", servers])
    #expect(!onUserHome.arguments.contains { $0.hasPrefix("mcp_servers.") })
    for feature in CodexConfig.isolatedFeatures { #expect(onUserHome.arguments.contains("features.\(feature)=false")) }
    #expect(onUserHome.configTOML == nil)
    #expect(onUserHome.environment["CODEX_HOME"] == nil)
    #expect(onUserHome.environment[CodexHarness.apiKeyVariable] == nil)
    #expect(onUserHome.arguments.first == "app-server")
    #expect(onUserHome.arguments.contains(#"model="gpt-test""#))
    #expect(onUserHome.arguments.contains(#"approval_policy="on-request""#))
    #expect(!onUserHome.arguments.contains { $0.hasPrefix("model_provider") })
    #expect(!onUserHome.arguments.contains { $0.hasPrefix("projects.") })
    #expect(onUserHome.codexHome.path.hasSuffix("/.codex"))

    // Signed in inside OpenClicky's home: use it, with no custom provider.
    let onOwnHome = try CodexHarness(hasLogin: { $0 == temp.paths.codexHome }).plan(for: launch)
    #expect(onOwnHome.environment["CODEX_HOME"] == temp.paths.codexHome.path)
    #expect(onOwnHome.configTOML?.contains("model_provider") == false)
}

@Test func codexRejectsChatCompletionsProviders() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let chat = ProviderConfig(id: "openrouter", dialect: .openAIChat, baseURL: URL(string: "https://openrouter.ai/api/v1"), credential: "openrouter")
    #expect(throws: AgentHarnessError.self) {
        try CodexHarness().plan(for: try launch(temp, executable: fake, auth: .provider(chat, apiKey: "x"), scenario: "quick", log: temp.url))
    }
}

@Test func missingHarnessExecutableIsReported() {
    let temp = AgentTempDir()
    let launch = HarnessLaunch(folder: temp.url, instructions: "", model: nil, auth: .harnessLogin, paths: temp.paths,
                               baseEnvironment: ["PATH": "/nonexistent", "HOME": "/nonexistent"])
    #expect(throws: AgentHarnessError.executableNotFound(.claudeCode)) { try ClaudeCodeHarness().plan(for: launch) }
}

// MARK: - Claude Code

@Test func claudeRunnerReplaysATurnWithPermissionPromptAndNeverWritesTheKey() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let fake = try temp.script("claude", FakeHarnessScripts.claude)
    let session = try await ClaudeCodeHarness().start(
        try launch(temp, executable: fake, auth: .provider(anthropicProvider, apiKey: secret), scenario: "approve", log: log),
        message: "Write meeting notes", images: [])

    var events = await collect(session.events, until: { $0.approval != nil })
    let request = try #require(events.last?.approval)
    #expect(request.id == "perm-1")
    #expect(request.kind == .tool)
    #expect(request.summary == "Run curl -s https://example.com")
    try await session.respond(to: request.id, with: .approve(always: true))
    events += await collect(session.events, until: \.isTurnFinished)

    #expect(events.contains(.turnStarted))
    #expect(events.contains(.sessionStarted(threadID: "sess-1")))
    #expect(events.contains(.commentary("Writing the notes now.")))
    #expect(events.contains(.plan([AgentPlanStep(step: "Write notes", status: .inProgress)])))
    #expect(events.contains(.progress("Writing notes.md")))
    let folder = temp.paths.jobs.appendingPathComponent("job-1").standardizedFileURL.path
    #expect(events.contains(.fileChanged(path: folder + "/output/notes.md", change: "created")))
    #expect(events.contains(.usage(AgentTokenUsage(input: 140, cachedInput: 40, output: 20))))
    guard case .turnFinished(.completed, let final?, nil) = events.last else { Issue.record("no completed turn: \(events)"); return }
    #expect(AgentFinalReport.parse(final).title == "Meeting Notes")

    // A follow-up after the turn runs as another turn of the same process.
    #expect(try await session.send("Add a summary") == .startedTurn)
    let followUp = await collect(session.events, until: \.isTurnFinished)
    #expect(followUp.last.flatMap { if case .turnFinished(_, let text, _) = $0 { text } else { nil } }.map { AgentFinalReport.parse($0).spoken } == "I added the summary too.")
    await session.close()

    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains(#""behavior":"allow""#))
    #expect(sent.contains(#""updatedPermissions""#))
    #expect(sent.contains("[--permission-prompt-tool] [stdio]"))
    #expect(sent.contains("[--input-format] [stream-json]"))
    #expect(sent.contains("[--append-system-prompt] [Test instructions.]"))
    #expect(sent.contains("[--model] [gpt-test]"))
    #expect(sent.contains("env: ANTHROPIC_API_KEY is set"))
    #expect(sent.contains("env: CLAUDE_CONFIG_DIR is set"))
    // The MCP token travels under a plain alias (Claude Code withholds TOKEN-like names from ${VAR} expansion).
    #expect(sent.contains("env: OPENCLICKY_MCPVAR_1 is set"))
    #expect(!sent.contains("env: OPENCLICKY_MCP_TOKEN_BROWSER is set"))
    #expect(!sent.contains("env: CLAUDECODE"))
    #expect(!sent.contains(secret))
    #expect(!sent.contains(mcpToken))
    #expect(sent.contains("Bearer ${OPENCLICKY_MCPVAR_1}"))
    #expect(temp.filesContaining(secret).isEmpty)
    #expect(temp.filesContaining(mcpToken).isEmpty)
}

@Test func claudeInterruptEndsTheTurnAsInterrupted() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let session = try await ClaudeCodeHarness().start(
        try launch(temp, executable: try temp.script("claude", FakeHarnessScripts.claude), auth: .provider(anthropicProvider, apiKey: secret),
                   scenario: "wait", log: log),
        message: "Write meeting notes", images: [])
    _ = await collect(session.events, until: { $0 == .progress("Writing notes.md") })
    await session.interrupt()
    let events = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    #expect(events.last == .turnFinished(.interrupted, finalText: nil, error: nil))
    #expect(try String(contentsOf: log, encoding: .utf8).contains(#""subtype":"interrupt""#))
}

@Test func claudeDeclineTellsTheAgentNotToRetry() async throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("claude.log")
    let session = try await ClaudeCodeHarness().start(
        try launch(temp, executable: try temp.script("claude", FakeHarnessScripts.claude), auth: .provider(anthropicProvider, apiKey: secret),
                   scenario: "approve", log: log),
        message: "Write meeting notes", images: [])
    let request = try #require(await collect(session.events, until: { $0.approval != nil }).last?.approval)
    try await session.respond(to: request.id, with: .decline)
    _ = await collect(session.events, until: \.isTurnFinished)
    await session.close()
    let sent = try String(contentsOf: log, encoding: .utf8)
    #expect(sent.contains(#""behavior":"deny""#))
    #expect(sent.contains(#""request_id":"perm-1""#))
}

@Test func claudePlans() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("claude", FakeHarnessScripts.claude)

    let byok = try ClaudeCodeHarness().plan(for: try launch(temp, executable: fake, auth: .provider(anthropicProvider, apiKey: secret), scenario: "quick", log: temp.url))
    #expect(byok.environment["ANTHROPIC_API_KEY"] == secret)
    #expect(byok.environment["ANTHROPIC_BASE_URL"] == "https://api.anthropic.com")
    #expect(byok.environment["CLAUDE_CONFIG_DIR"] == temp.paths.claudeConfig.path)
    #expect(byok.environment[byok.mcpVariables[browserMCP().tokenEnvironmentVariable] ?? ""] == mcpToken)
    #expect(!byok.arguments.joined(separator: " ").contains(secret))
    #expect(!byok.arguments.joined(separator: " ").contains(mcpToken))
    #expect(byok.arguments.contains("--strict-mcp-config"))
    let mcp = try JSONValue.parse(byok.mcpConfig)
    #expect(mcp["mcpServers"]?["browser"]?["url"]?.stringValue == "http://127.0.0.1:47011/mcp")
    #expect(byok.arguments.contains("acceptEdits"))

    var login = try launch(temp, executable: fake, auth: .harnessLogin, scenario: "quick", log: temp.url)
    login.approvalMode = .fullAccess
    let plan = try ClaudeCodeHarness().plan(for: login)
    // The subscription login is used: no key from the user's shell, no separate config folder.
    #expect(plan.environment["ANTHROPIC_API_KEY"] == nil)
    #expect(plan.environment["CLAUDE_CONFIG_DIR"] == nil)
    #expect(plan.arguments.contains("--dangerously-skip-permissions"))

    let openAI = try launch(temp, executable: fake, auth: .provider(openAIProvider, apiKey: secret), scenario: "quick", log: temp.url)
    #expect(throws: AgentHarnessError.self) { try ClaudeCodeHarness().plan(for: openAI) }
}

// MARK: - TOML

@Test func tomlRenderingQuotesAndGroupsTables() {
    #expect(TOMLValue.quote("a \"b\" \\ c\nd") == #""a \"b\" \\ c\nd""#)
    #expect(TOMLValue.key("browser") == "browser")
    #expect(TOMLValue.key("/Users/x/projects") == #""/Users/x/projects""#)
    #expect(TOMLValue.splitKey(#"projects."/a.b/c".trust_level"#) == ["projects", #""/a.b/c""#, "trust_level"])
    let config = CodexConfig(model: "m", provider: nil, approvalMode: .fullAccess)
    let toml = config.renderTOML()
    #expect(toml.contains(#"approval_policy = "never""#))
    #expect(toml.contains(#"sandbox_mode = "danger-full-access""#))
    #expect(!toml.contains("sandbox_workspace_write"))
    #expect(config.overrideArguments().contains("analytics.enabled=false"))
}

@Test func listingTheUsersCodexServersKeepsOnlyTheirNames() throws {
    let temp = AgentTempDir()
    let log = temp.url.appendingPathComponent("list.log")
    let lister = try temp.script("codex-list", """
    #!/bin/sh
    echo "$@" > "\(log.path)"
    echo '[{"name":"gigamail","enabled":true,"transport":{"type":"stdio","command":"ssh","env":{"TOKEN":"x"}}},{"name":"notion","enabled":true}]'
    """)
    #expect(CodexHarness.configuredMCPServers(lister, ["PATH": "/usr/bin:/bin"]) == ["gigamail", "notion"])
    let args = try String(contentsOf: log, encoding: .utf8)
    #expect(args.contains("-c features.plugins=false"))
    #expect(args.hasSuffix("mcp list --json\n"))
    let failing = try temp.script("codex-fail", "#!/bin/sh\necho oops\nexit 3\n")
    #expect(CodexHarness.configuredMCPServers(failing, [:]).isEmpty)
}
