import Foundation
import Testing
@testable import OpenClickyKit

// Connected apps and the browser reach agent jobs: MCP servers with secret headers and stdio variables, the export
// applied at every launch (servers, the Connected apps and Obsidian sections, OBSIDIAN_VAULT_PATH), and the relay
// that keeps OAuth apps signed in through long jobs.

private let headerSecret = "hdr-SECRET-77aa"
private let envSecret = "env-SECRET-31bc"
private let bearerSecret = "bearer-SECRET-90ff"

private func sampleServers() -> [AgentMCPServer] {
    [
        AgentMCPServer(name: "linear", transport: .http(URL(string: "https://mcp.example.com/linear")!), bearerToken: bearerSecret,
                       tokenEnvironmentVariable: "OPENCLICKY_APP_LINEAR_TOKEN",
                       secretHeaders: ["X-Workspace-Key": "OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY"],
                       secretValues: ["OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY": headerSecret]),
        AgentMCPServer(name: "files", transport: .stdio(command: "/usr/local/bin/files-mcp", arguments: ["--root", "/tmp"]),
                       forwardedVariables: ["FILES_API_KEY"], environment: ["PATH": "/usr/local/bin:/usr/bin"],
                       secretValues: ["FILES_API_KEY": envSecret]),
    ]
}

@Test func codexGetsSecretHeadersAndStdioVariablesByNameOnly() throws {
    let temp = AgentTempDir()
    let codex = try temp.script("codex", "#!/bin/sh\nexit 0\n")
    let provider = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai")
    let launch = HarnessLaunch(folder: temp.url, instructions: "x", model: nil, auth: .provider(provider, apiKey: "sk-test"),
                               mcpServers: sampleServers(), executable: codex, paths: temp.paths,
                               baseEnvironment: ["PATH": "/usr/bin", "HOME": temp.url.path, "OPENCLICKY_APP_STALE_TOKEN": "old"],
                               environment: ["OBSIDIAN_VAULT_PATH": "/Users/me/Vault"])
    let plan = try CodexHarness(listUserMCPServers: { _, _ in [] }).plan(for: launch)
    let toml = try #require(plan.configTOML)
    #expect(toml.contains(#"env_http_headers = { X-Workspace-Key = "OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY" }"#))
    #expect(toml.contains(#"bearer_token_env_var = "OPENCLICKY_APP_LINEAR_TOKEN""#))
    #expect(toml.contains(#"env_vars = ["FILES_API_KEY"]"#))
    #expect(toml.contains(#"env = { PATH = "/usr/local/bin:/usr/bin" }"#))
    for secret in [headerSecret, envSecret, bearerSecret] {
        #expect(!toml.contains(secret))
        #expect(!plan.arguments.joined(separator: " ").contains(secret))
    }
    // Codex holds the secrets itself but keeps them from the agent's commands; the vault path stays visible.
    #expect(plan.environment["OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY"] == headerSecret)
    #expect(plan.environment["FILES_API_KEY"] == envSecret)
    #expect(plan.environment["OPENCLICKY_APP_LINEAR_TOKEN"] == bearerSecret)
    #expect(plan.environment["OBSIDIAN_VAULT_PATH"] == "/Users/me/Vault")
    #expect(plan.environment["OPENCLICKY_APP_STALE_TOKEN"] == nil)
    #expect(Set(plan.config.hiddenVariables).isSuperset(of: ["OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY", "FILES_API_KEY", "OPENCLICKY_APP_LINEAR_TOKEN"]))
    #expect(!plan.config.hiddenVariables.contains("OBSIDIAN_VAULT_PATH"))
}

@Test func claudeCodeGetsSecretHeadersAndStdioVariablesAsReferences() throws {
    let temp = AgentTempDir()
    let claude = try temp.script("claude", "#!/bin/sh\nexit 0\n")
    let launch = HarnessLaunch(folder: temp.url, instructions: "x", model: nil, auth: .harnessLogin, mcpServers: sampleServers(),
                               executable: claude, paths: temp.paths, baseEnvironment: ["PATH": "/usr/bin", "HOME": temp.url.path],
                               environment: ["OBSIDIAN_VAULT_PATH": "/Users/me/Vault"])
    let plan = try ClaudeCodeHarness().plan(for: launch)
    let config = try JSONValue.parse(plan.mcpConfig)
    // Every secret travels under a plain alias Claude Code will expand (it withholds TOKEN/KEY-like names).
    #expect(plan.mcpVariables == ["FILES_API_KEY": "OPENCLICKY_MCPVAR_1", "OPENCLICKY_APP_LINEAR_HEADER_X_WORKSPACE_KEY": "OPENCLICKY_MCPVAR_2",
                                  "OPENCLICKY_APP_LINEAR_TOKEN": "OPENCLICKY_MCPVAR_3"])
    let linear = try #require(config["mcpServers"]?["linear"])
    #expect(linear["headers"]?["Authorization"] == "Bearer ${OPENCLICKY_MCPVAR_3}")
    #expect(linear["headers"]?["X-Workspace-Key"] == "${OPENCLICKY_MCPVAR_2}")
    let files = try #require(config["mcpServers"]?["files"])
    #expect(files["env"]?["FILES_API_KEY"] == "${OPENCLICKY_MCPVAR_1}")
    #expect(files["env"]?["PATH"] == "/usr/local/bin:/usr/bin")
    for secret in [headerSecret, envSecret, bearerSecret] { #expect(!plan.mcpConfig.contains(secret)) }
    #expect(plan.environment["OPENCLICKY_MCPVAR_1"] == envSecret)
    #expect(plan.environment["OPENCLICKY_MCPVAR_3"] == bearerSecret)
    #expect(plan.environment["FILES_API_KEY"] == nil)
    #expect(plan.environment["OBSIDIAN_VAULT_PATH"] == "/Users/me/Vault")
    #expect(!"\(sampleServers()[0])".contains(headerSecret))
}

@Test func theExportBecomesServersInstructionsAndTheVaultPath() {
    let export = ConnectedAppsAgentExport(
        servers: [
            AgentConnectorServer(key: "notion", displayName: "Notion", accountLabel: "Work", capability: "Search and edit pages.",
                                 transport: .http(url: URL(string: "https://mcp.notion.com/mcp")!, bearerTokenVariable: "OPENCLICKY_APP_NOTION_TOKEN",
                                                  headerVariables: ["X-Org": "OPENCLICKY_APP_NOTION_HEADER_X_ORG"]),
                                 startupTimeoutSeconds: 30, toolTimeoutSeconds: 900),
            AgentConnectorServer(key: "github", displayName: "GitHub", accountLabel: nil, capability: nil,
                                 transport: .stdio(command: "/opt/homebrew/bin/github-mcp", arguments: ["stdio"],
                                                   environmentVariables: ["GITHUB_TOKEN"], path: "/opt/homebrew/bin:/usr/bin"),
                                 startupTimeoutSeconds: 30, toolTimeoutSeconds: 900),
        ],
        environment: ["OPENCLICKY_APP_NOTION_TOKEN": "tok", "OPENCLICKY_APP_NOTION_HEADER_X_ORG": "org", "GITHUB_TOKEN": "gh"],
        obsidianVaultPath: "/Users/me/Notes")
    let extras = export.launchExtras()
    #expect(extras.mcpServers.map(\.name) == ["notion", "github"])
    let notion = extras.mcpServers[0]
    #expect(notion.bearerToken == "tok" && notion.tokenEnvironmentVariable == "OPENCLICKY_APP_NOTION_TOKEN")
    #expect(notion.secretHeaders == ["X-Org": "OPENCLICKY_APP_NOTION_HEADER_X_ORG"])
    #expect(notion.harnessSecrets == ["OPENCLICKY_APP_NOTION_TOKEN": "tok", "OPENCLICKY_APP_NOTION_HEADER_X_ORG": "org"])
    let github = extras.mcpServers[1]
    #expect(github.forwardedVariables == ["GITHUB_TOKEN"] && github.secretValues == ["GITHUB_TOKEN": "gh"])
    #expect(github.environment == ["PATH": "/opt/homebrew/bin:/usr/bin"])
    #expect(extras.environment == ["OBSIDIAN_VAULT_PATH": "/Users/me/Notes"])
    let text = extras.instructions.joined()
    #expect(text.contains("## Connected apps") && text.contains("`notion`: Notion (Work account)") && text.contains("## Obsidian notes"))
}

@Test func jobsLaunchWithConnectedAppsAndTheBrowser() async throws {
    // A real registry with a bearer-token connector and an Obsidian vault, exported at launch the way the app does it.
    let temp = AgentTempDir()
    let vault = temp.url.appendingPathComponent("Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try "# Hello".write(to: vault.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    let registryURL = temp.url.appendingPathComponent("connectors.json")
    try ConnectorRegistry(connectors: [ConnectorConfig(id: "linear", name: "Linear", transport: .remote(URL(string: "https://mcp.linear.app/mcp")!),
                                                       auth: .bearer, accountLabel: "Work")],
                          obsidian: ObsidianSettings(vaultPath: vault.path)).save(to: registryURL)
    let credentials = InMemoryCredentialStore([ConnectorSecretNames.bearer("linear"): bearerSecret])
    let apps = AgentConnectedApps(registryURL: registryURL, environment: ConnectorEnvironment(credentials: credentials))
    let browser = AgentMCPServer(name: "openclicky_browser", transport: .http(URL(string: "http://127.0.0.1:4555/mcp")!), bearerToken: "b")

    let harness = ScriptedHarness { session in await session.finish(reportText) }
    let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness]) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: "harness-login", auth: .harnessLogin, mcpServers: [browser],
                            baseEnvironment: ["PATH": "/usr/bin"], extraInstructions: "## Skills\nNone.")
    }
    await manager.setLaunchExtras { _ in await apps.extras() }
    let updates = await manager.subscribe()
    let result = try await manager.spawn(AgentSpawnRequest(task: "Summarize my Linear issues into my vault", title: "Issues"), waitForStart: true)
    _ = await nextAgentReport(updates, for: result.record.id)
    let launch = try #require(harness.launches.first?.launch)
    #expect(launch.mcpServers.map(\.name) == ["openclicky_browser", "linear"])
    #expect(launch.mcpServers[1].bearerToken == bearerSecret)
    #expect(launch.environment[ConnectedAppsAgentExport.obsidianVariable]?.hasSuffix("/Vault") == true)
    #expect(launch.instructions.contains("## Skills"))
    #expect(launch.instructions.contains("## Connected apps") && launch.instructions.contains("`linear`: Linear (Work account)"))
    #expect(launch.instructions.contains("## Obsidian notes"))
    // The record and the log never hold the token.
    #expect(temp.filesContaining(bearerSecret).isEmpty)
}

@Test func theRelayRefreshesAnExpiredTokenAndGuardsItsRoutes() async throws {
    let upstream = FakeHTTPTransport([
        .body(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"expired"}}"#, status: 401),
        FakeHTTPTransport.Scripted(status: 200, headers: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "s-1"],
                                   chunks: [Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".utf8)]),
    ])
    let tokens = TokenSource()
    let relay = AgentConnectorRelay(http: upstream)
    defer { relay.stop() }
    let local = try relay.route(key: "notion", upstream: URL(string: "https://mcp.notion.com/mcp?x=1")!, token: { force in tokens.next(force) })
    #expect(local.url.host == "127.0.0.1" && local.url.path == "/apps/notion/mcp")
    // A later launch updates the route but keeps its address and token, so a running job keeps access.
    let again = try relay.route(key: "notion", upstream: URL(string: "https://mcp.notion.com/mcp?x=1")!, token: { force in tokens.next(force) })
    #expect(again == local)

    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
    var request = URLRequest(url: local.url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    // Without the relay's token: refused, nothing sent upstream.
    let (_, refused) = try await URLSession.shared.data(for: request)
    #expect((refused as? HTTPURLResponse)?.statusCode == 401)
    #expect(upstream.requests.isEmpty)

    request.setValue("Bearer \(local.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    #expect(http.statusCode == 200)
    #expect(http.value(forHTTPHeaderField: "Mcp-Session-Id") == "s-1")
    #expect(String(decoding: data, as: UTF8.self).contains("\"result\""))
    // The first token was refused, so the relay refreshed once and tried again with the new one.
    #expect(upstream.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
    #expect(upstream.requests.first?.url?.absoluteString == "https://mcp.notion.com/mcp?x=1")
    #expect(upstream.requests.first?.httpBody == body)
    #expect(tokens.forced == 1)

    // GET (the optional event stream) isn't relayed.
    var get = URLRequest(url: local.url)
    get.setValue("Bearer \(local.token)", forHTTPHeaderField: "Authorization")
    let (_, getResponse) = try await URLSession.shared.data(for: get)
    #expect((getResponse as? HTTPURLResponse)?.statusCode == 405)
}

@Test func theRelaySaysSoWhenTheAppNeedsSigningInAgain() async throws {
    let relay = AgentConnectorRelay(http: FakeHTTPTransport([]))
    defer { relay.stop() }
    let local = try relay.route(key: "notion", upstream: URL(string: "https://mcp.notion.com/mcp")!, token: { _ in throw MCPOAuthError.needsSignIn })
    var request = URLRequest(url: local.url)
    request.httpMethod = "POST"
    request.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
    request.setValue("Bearer \(local.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    let json = try JSONValue.parse(String(decoding: data, as: UTF8.self))
    #expect(json["id"] == 7)
    #expect(json["error"]?["message"]?.stringValue?.contains("sign in again") == true)
}

private final class TokenSource: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var forced = 0
    func next(_ force: Bool) -> String {
        lock.withLock {
            if force { forced += 1 }
            if force || count == 0 { count += 1 }
            return "token-\(count)"
        }
    }
}
