import Foundation
import Testing
@testable import OpenClickyKit

// Registry, read-only classification, read_connected_apps, the agent export and Composio.

// MARK: Registry

@Test func registryAddsWithSlugIDsAndRejectsDuplicatesAndBadURLs() throws {
    var registry = ConnectorRegistry()
    let notion = try registry.add(ConnectorConfig(id: "", name: "Notion (Work)", transport: .remote(URL(string: "https://mcp.notion.com/mcp")!), auth: .oauth))
    #expect(notion.id == "notion-work")
    let second = try registry.add(ConnectorConfig(id: "notion-work", name: "Notion Home", transport: .remote(URL(string: "https://mcp.notion.com/mcp")!)))
    #expect(second.id == "notion-work-2")
    let reserved = try registry.add(ConnectorConfig(id: "", name: "Obsidian", transport: .stdio(command: "obsidian-mcp", arguments: [])))
    #expect(reserved.id == "obsidian-2")
    #expect(throws: ConnectorRegistryError.duplicate("notion (work)")) {
        try registry.add(ConnectorConfig(id: "", name: "notion (work)", transport: .remote(URL(string: "https://x.example/mcp")!)))
    }
    #expect(throws: ConnectorRegistryError.self) {
        try registry.add(ConnectorConfig(id: "", name: "Plain", transport: .remote(URL(string: "http://example.com/mcp")!)))
    }
    #expect(throws: ConnectorRegistryError.invalidName) {
        try registry.add(ConnectorConfig(id: "", name: "  ", transport: .remote(URL(string: "https://x.example")!)))
    }
    #expect(ConnectorRegistry.isAcceptableRemoteURL(URL(string: "http://127.0.0.1:8123/mcp")!))
    #expect(ConnectorRegistry.isAcceptableRemoteURL(URL(string: "http://localhost:3000/mcp")!))
    #expect(!ConnectorRegistry.isAcceptableRemoteURL(URL(string: "ftp://x.example")!))
    #expect(!ConnectorRegistry.isAcceptableRemoteURL(URL(string: "https://me:hunter2@x.example/mcp")!))
    do {
        try registry.add(ConnectorConfig(id: "", name: "Creds", transport: .remote(URL(string: "https://me:hunter2@x.example/mcp")!)))
        Issue.record("a URL with a password was accepted")
    } catch {
        // The message names the URL without repeating the password.
        #expect(!String(describing: error).contains("hunter2"))
        #expect(String(describing: error).contains("x.example/mcp"))
    }
    #expect(registry.connector("NOTION (WORK)")?.id == "notion-work")
    #expect(try registry.remove("notion home").id == "notion-work-2")
    #expect(registry.connectors.count == 2)
}

@Test func registryRoundTripsWithoutSecrets() throws {
    var registry = ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: "/tmp/vault"), composio: ComposioSettings(userID: "me@example.com", toolkits: ["gmail"]))
    try registry.add(ConnectorConfig(id: "", name: "Files", transport: .stdio(command: "npx", arguments: ["-y", "files-mcp"]), auth: .none,
                                     accountLabel: "Laptop", environment: ["FILES_TOKEN": "connector-files-env-files-token"]))
    let url = try scratchFolder().appendingPathComponent("connectors.json")
    try registry.save(to: url)
    #expect(try ConnectorRegistry.load(from: url) == registry)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"type\" : \"stdio\""))
    #expect(try ConnectorRegistry.load(from: url.deletingLastPathComponent().appendingPathComponent("missing.json")) == ConnectorRegistry())
    // Older files without Composio's `enabled` flag still load.
    let legacy = #"{"version":1,"connectors":[],"composio":{"userID":"u"}}"#
    #expect(try JSONDecoder().decode(ConnectorRegistry.self, from: Data(legacy.utf8)).composio?.enabled == true)
}

@Test func presetsUseOfficialHTTPSURLs() {
    #expect(ConnectorPreset.all.map(\.id) == ["github", "notion", "linear"])
    #expect(ConnectorPreset.all.allSatisfy { $0.url.scheme == "https" && ConnectorRegistry.isAcceptableRemoteURL($0.url) })
    #expect(ConnectorPreset.named("Linear")?.url.absoluteString == "https://mcp.linear.app/mcp")
    #expect(ConnectorPreset.named("notion")?.connector.auth == .oauth)
    #expect(ConnectorPreset.named("github")?.connector.auth == .bearer)
}

@Test func secretNamesWorkWithTheEnvironmentOverride() {
    #expect(ConnectorSecretNames.bearer("notion-work") == "connector-notion-work-bearer")
    #expect(KeychainCredentialStore.environmentVariable(for: ConnectorSecretNames.bearer("notion-work")) == "OPENCLICKY_KEY_CONNECTOR_NOTION_WORK_BEARER")
    let connector = ConnectorConfig(id: "x", name: "X", transport: .remote(URL(string: "https://x.example")!),
                                    secretHeaders: ["X-Api-Key": "connector-x-header-x-api-key", "Shared": "someone-elses"])
    let all = ConnectorSecretNames.all(for: connector)
    #expect(all.contains("connector-x-header-x-api-key"))
    #expect(!all.contains("someone-elses")) // never delete a credential another connector may own
}

// MARK: Read-only classification

@Test func toolSafetyTreatsOnlyClearReadsAsReads() {
    func access(_ name: String, readOnly: Bool? = nil, destructive: Bool? = nil) -> ToolAccess {
        ToolSafety.access(of: MCPToolDefinition(name: name, annotations: MCPToolAnnotations(readOnlyHint: readOnly, destructiveHint: destructive)))
    }
    for read in ["search_issues", "get_issue", "list_pages", "notion-fetch", "GMAIL_FETCH_EMAILS", "googlecalendar_find_event", "getFileContents", "get_post", "read_note"] {
        #expect(access(read) == .read, "\(read)")
    }
    for write in ["create_issue", "GMAIL_SEND_EMAIL", "update_page", "notion-move-pages", "post_message", "slack_post_message", "delete_file",
                  "search_and_replace", "list_and_archive", "status", "do_thing", "draft_reply"] {
        #expect(access(write) == .write, "\(write)")
    }
    // Hints can only add caution.
    #expect(access("send_email", readOnly: true) == .write)
    #expect(access("get_report", destructive: true) == .write)
    #expect(access("weather", readOnly: true) == .read)
    #expect(ToolSafety.tokens("getFileContents_v2") == ["get", "file", "contents", "v2"])
}

@Test func composioRunToolIsAReadOnlyWhenEveryActionReads() {
    let run = MCPToolDefinition(name: "COMPOSIO_MULTI_EXECUTE_TOOL")
    let composio = ComposioClient.connectorID
    #expect(ToolSafety.isArgumentGated(run, appID: composio))
    #expect(ToolSafety.access(ofCall: run, arguments: ["tools": [["tool_slug": "GMAIL_FETCH_EMAILS", "arguments": [:]],
                                                                 ["tool_slug": "GOOGLECALENDAR_FIND_EVENT", "arguments": [:]]]], appID: composio) == .read)
    #expect(ToolSafety.access(ofCall: run, arguments: ["tools": [["tool_slug": "GMAIL_FETCH_EMAILS"], ["tool_slug": "GMAIL_SEND_EMAIL"]]], appID: composio) == .write)
    #expect(ToolSafety.access(ofCall: run, arguments: ["unexpected": "shape"], appID: composio) == .write)
    // Any other server can call a tool "…execute_tool"; read-looking arguments must not make it a read there.
    let lookalike = MCPToolDefinition(name: "remote_execute_tool")
    #expect(!ToolSafety.isArgumentGated(lookalike, appID: "helpdesk"))
    #expect(ToolSafety.access(ofCall: lookalike, arguments: ["tools": [["tool_slug": "get_status"]]], appID: "helpdesk") == .write)
}

@Test func capabilityLineComesFromToolVerbsAndNouns() {
    let tools = ["notion-search", "notion-fetch", "notion-create-pages", "notion-update-page", "notion-get-comments"].map { MCPToolDefinition(name: $0) }
    let line = CapabilityDeriver.describe(tools, appName: "Notion")
    #expect(line?.hasPrefix("Search, read, create and update") == true)
    #expect(line?.contains("pages") == true)
    #expect(line?.contains("notion") == false)
    #expect(CapabilityDeriver.describe([], appName: nil) == nil)
}

// MARK: read_connected_apps

private let issueTools = [
    MCPToolDefinition(name: "search_issues", description: "Search Linear issues by text", inputSchema: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]),
    MCPToolDefinition(name: "get_issue", description: "Get one issue by id", inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]),
    MCPToolDefinition(name: "create_issue", description: "Create an issue", inputSchema: ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]),
]

private func hubWithFakeApps() async throws -> (ConnectedAppsHub, FakeAppSource, FakeAppSource) {
    var registry = ConnectorRegistry()
    try registry.add(ConnectorConfig(id: "linear", name: "Linear", transport: .remote(URL(string: "https://mcp.linear.app/mcp")!), auth: .bearer, accountLabel: "Work"))
    try registry.add(ConnectorConfig(id: "notes", name: "Notes", transport: .remote(URL(string: "https://notes.example/mcp")!)))
    try registry.add(ConnectorConfig(id: "calendar", name: "Calendar", transport: .remote(URL(string: "https://cal.example/mcp")!), auth: .oauth))
    let credentials = InMemoryCredentialStore([ConnectorSecretNames.bearer("linear"): "lin_api_secret"])
    let hub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: credentials))
    let linear = FakeAppSource(tools: issueTools) { name, arguments in
        MCPToolResult(content: [.text("\(name): ENG-12 Login fails on Safari (\(arguments["query"]?.stringValue ?? arguments["id"]?.stringValue ?? ""))")])
    }
    let notes = FakeAppSource(tools: [MCPToolDefinition(name: "search_notes", description: "Search personal notes", inputSchema: ["type": "object", "properties": ["query": ["type": "string"]]])]) { _, _ in
        MCPToolResult(content: [.text("note: groceries")])
    }
    await hub.install(linear, for: "linear")
    await hub.install(notes, for: "notes")
    return (hub, linear, notes)
}

@Test func readConnectedAppsRoutesByKeywordsToAReadTool() async throws {
    let (hub, linear, notes) = try await hubWithFakeApps()
    let reader = ReadConnectedApps(hub: hub)
    let outcome = await reader.run(arguments: #"{"request":"the Linear issue about login failing"}"#)
    #expect(outcome.didRead)
    #expect(outcome.calls.map(\.tool) == ["search_issues"])
    #expect(linear.calls.all.first?.1["query"]?.stringValue == "the Linear issue about login failing")
    #expect(notes.calls.names.isEmpty)
    #expect(outcome.text.contains("From Linear (Work) (search_issues):"))
    #expect(outcome.text.contains("ENG-12"))
    #expect(outcome.status == "Read your apps")
    #expect(outcome.text.hasPrefix("What follows is content from the user's apps."))
    // The OAuth app with no tokens is skipped, not fatal.
    #expect(!outcome.text.contains("Calendar"))
}

@Test func readConnectedAppsRefusesWritesEvenWhenTheChooserAsks() async throws {
    let (hub, linear, _) = try await hubWithFakeApps()
    struct Pushy: ConnectedAppsToolChooser {
        func choose(request: String, candidates: [ConnectedAppTool], maxCalls: Int) async throws -> ToolChoice {
            ToolChoice(calls: [ChosenToolCall(appID: "linear", toolName: "create_issue", arguments: ["title": "x"]),
                               ChosenToolCall(appID: "linear", toolName: "get_issue", arguments: ["id": "ENG-12"])])
        }
    }
    let outcome = await ReadConnectedApps(hub: hub, chooser: Pushy()).run(request: "make an issue", app: "Linear")
    #expect(linear.calls.names == ["get_issue"])
    #expect(outcome.text.contains("Not run: create_issue isn't one of the readable tools."))
    #expect(outcome.didRead)
}

@Test func readConnectedAppsOnlyTrustsRunToolArgumentsFromComposio() async throws {
    // A user-added server whose tool happens to be named like Composio's runner, with read-looking arguments.
    var registry = ConnectorRegistry()
    try registry.add(ConnectorConfig(id: "helpdesk", name: "Helpdesk", transport: .remote(URL(string: "https://helpdesk.example/mcp")!)))
    let hub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: InMemoryCredentialStore()))
    let runner = MCPToolDefinition(name: "REMOTE_MULTI_EXECUTE_TOOL", description: "Runs anything",
                                   inputSchema: ["type": "object", "properties": ["tools": ["type": "array"]]])
    let helpdesk = FakeAppSource(tools: [runner]) { _, _ in MCPToolResult(content: [.text("ran")]) }
    await hub.install(helpdesk, for: "helpdesk")
    struct Sneaky: ConnectedAppsToolChooser {
        func choose(request: String, candidates: [ConnectedAppTool], maxCalls: Int) async throws -> ToolChoice {
            ToolChoice(calls: [ChosenToolCall(appID: "helpdesk", toolName: "REMOTE_MULTI_EXECUTE_TOOL",
                                              arguments: ["tools": [["tool_slug": "GET_TICKET"]]])])
        }
    }
    let outcome = await ReadConnectedApps(hub: hub, chooser: Sneaky()).run(request: "ticket 12")
    #expect(helpdesk.calls.names.isEmpty)
    #expect(!outcome.didRead)
}

@Test func readConnectedAppsUsesTheModelChooserAndMapsNamesBack() async throws {
    let (hub, linear, notes) = try await hubWithFakeApps()
    let model = ScriptedChooserModel { request in
        let name = request.tools.first { $0.name.hasSuffix("get_issue") }!.name
        return ("", [ToolCall(id: "c1", name: name, arguments: #"{"id":"ENG-12"}"#)])
    }
    let outcome = await ReadConnectedApps(hub: hub, chooser: ModelToolChooser(client: model, model: "fast-model")).run(request: "what's ENG-12 about?")
    #expect(linear.calls.names == ["get_issue"])
    #expect(linear.calls.all.first?.1 == ["id": "ENG-12"])
    #expect(notes.calls.names.isEmpty)
    #expect(outcome.calls.first?.succeeded == true)
    // The model only ever saw read tools, with provider-safe names.
    let offered = try #require(model.requests.first?.tools)
    #expect(offered.count == 3)
    #expect(!offered.contains { $0.name.contains("create_issue") })
    #expect(offered.allSatisfy { $0.name.count <= 64 && $0.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } })
    #expect(model.requests.first?.model == "fast-model")
}

@Test func readConnectedAppsExplainsUnknownAndUnavailableApps() async throws {
    let (hub, _, _) = try await hubWithFakeApps()
    let reader = ReadConnectedApps(hub: hub)
    let unknown = await reader.run(request: "anything", app: "Dropbox")
    #expect(unknown.text.contains("No connected app called \"Dropbox\""))
    #expect(!unknown.didRead)
    let signIn = await reader.run(request: "next meeting", app: "Calendar")
    #expect(signIn.text.contains("needs the user to sign in"))
    let bad = await reader.run(arguments: "{}")
    #expect(bad.text.contains("needs a \"request\""))
}

@Test func readToolSpecAndPromptSectionDescribeTheApps() async throws {
    let (hub, _, _) = try await hubWithFakeApps()
    let apps = await hub.summaries()
    #expect(apps.map(\.status) == [.ready, .ready, .needsSignIn])
    let spec = ReadConnectedApps.toolSpec(apps: apps)
    #expect(spec.name == "read_connected_apps")
    #expect(spec.parameters["properties"]?["app"]?["enum"] == ["Linear", "Notes"])
    #expect(spec.parameters["required"] == ["request"])
    let section = try #require(ConnectedAppsPrompt.section(apps))
    #expect(section.contains("- Linear (Work)"))
    #expect(section.contains("Calendar (needs sign-in)"))
    #expect(section.contains("read_connected_apps"))
    #expect(ConnectedAppsPrompt.section([]) == nil)
}

@Test func hubTestsObsidianAndReportsMissingSecrets() async throws {
    let root = try scratchFolder()
    try "# Hello".write(to: root.appendingPathComponent("Hello.md"), atomically: true, encoding: .utf8)
    var registry = ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: root.path))
    try registry.add(ConnectorConfig(id: "gh", name: "GitHub", transport: .remote(URL(string: "https://api.githubcopilot.com/mcp/")!), auth: .bearer))
    let hub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: InMemoryCredentialStore()))
    let obsidian = await hub.test("obsidian")
    guard case .reachable(let count, let reads, _, _, let capability) = obsidian else { Issue.record("\(obsidian)"); return }
    #expect(count == 6)
    #expect(reads == 4)
    #expect(capability?.isEmpty == false)
    let github = await hub.test("gh")
    #expect(github.summary.contains("Keychain item \"connector-gh-bearer\""))
    #expect(await hub.summaries().first?.status == .missingSecret)
}

@Test func hubTalksToARealServerThroughTheFactory() async throws {
    let server = try FakeMCPHTTPServer(mode: .legacy)
    server.requiredToken = "tok"
    var registry = ConnectorRegistry()
    try registry.add(ConnectorConfig(id: "local", name: "Local", transport: .remote(server.url), auth: .bearer))
    let hub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: InMemoryCredentialStore([ConnectorSecretNames.bearer("local"): "tok"])))
    let result = await hub.test("local")
    #expect(result.isReachable)
    #expect(result.summary.contains("fake-legacy"))
    #expect(result.summary.contains("3 tools, 2 read-only"))
    let echo = try await hub.call(appID: "local", tool: "echo", arguments: ["text": "via hub"])
    #expect(echo.text == "echo: via hub")
    await hub.shutdown()
}

// MARK: Agent export

@Test func agentExportKeepsSecretsInTheEnvironmentOnly() async throws {
    let vault = try scratchFolder()
    var registry = ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: vault.path))
    try registry.add(ConnectorConfig(id: "github", name: "GitHub", transport: .remote(URL(string: "https://api.githubcopilot.com/mcp/")!), auth: .bearer,
                                     capabilityDescription: "Search and read issues"))
    try registry.add(ConnectorConfig(id: "notion", name: "Notion", transport: .remote(URL(string: "https://mcp.notion.com/mcp")!), auth: .oauth, accountLabel: "Work"))
    try registry.add(ConnectorConfig(id: "gateway", name: "Gateway", transport: .remote(URL(string: "https://gw.example/mcp")!),
                                     secretHeaders: ["X-Api-Key": "connector-gateway-header-x-api-key"]))
    try registry.add(ConnectorConfig(id: "files", name: "Files", transport: .stdio(command: "sh", arguments: ["-c", "echo"]),
                                     environment: ["FILES_TOKEN": "connector-files-env-files-token"]))
    try registry.add(ConnectorConfig(id: "linear", name: "Linear", transport: .remote(URL(string: "https://mcp.linear.app/mcp")!), auth: .oauth))
    try registry.add(ConnectorConfig(id: "off", name: "Off", transport: .remote(URL(string: "https://off.example/mcp")!), enabled: false))
    let credentials = InMemoryCredentialStore([
        ConnectorSecretNames.bearer("github"): "ghp_secret",
        "connector-gateway-header-x-api-key": "gw_secret",
        "connector-files-env-files-token": "files_secret",
    ])
    try MCPOAuthStore(credentials: credentials, connectorID: "notion").save(OAuthTokenSet(
        accessToken: "notion_access_secret", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), issuer: "https://mcp.notion.com",
        tokenEndpoint: URL(string: "https://mcp.notion.com/token")!, clientID: "c", resource: "https://mcp.notion.com/mcp"))

    let export = await ConnectedAppsAgentExporter(registry: registry, environment: ConnectorEnvironment(credentials: credentials, processEnvironment: ["PATH": "/usr/bin:/bin"])).export()
    #expect(export.servers.map(\.key) == ["github", "notion", "gateway", "files"])
    #expect(export.unavailable.map(\.name) == ["Linear"])
    #expect(export.environment["OPENCLICKY_APP_GITHUB_TOKEN"] == "ghp_secret")
    #expect(export.environment["OPENCLICKY_APP_NOTION_TOKEN"] == "notion_access_secret")
    #expect(export.environment["OPENCLICKY_APP_GATEWAY_HEADER_X_API_KEY"] == "gw_secret")
    #expect(export.environment["FILES_TOKEN"] == "files_secret")
    #expect(export.jobEnvironment["OBSIDIAN_VAULT_PATH"] == vault.resolvingSymlinksInPath().path)

    let toml = export.codexConfigTOML()
    let claude = export.claudeCodeMCPConfig()
    let overrides = export.codexConfigOverrides().joined(separator: "\n")
    for secret in ["ghp_secret", "notion_access_secret", "gw_secret", "files_secret"] {
        #expect(!toml.contains(secret))
        #expect(!claude.contains(secret))
        #expect(!overrides.contains(secret))
        #expect(!export.description.contains(secret))
        #expect(!export.instructions().contains(secret))
    }
    #expect(toml.contains("[mcp_servers.github]\nurl = \"https://api.githubcopilot.com/mcp/\"\nbearer_token_env_var = \"OPENCLICKY_APP_GITHUB_TOKEN\""))
    #expect(toml.contains("env_http_headers = { X-Api-Key = \"OPENCLICKY_APP_GATEWAY_HEADER_X_API_KEY\" }"))
    #expect(toml.contains("command = \"/bin/sh\"\nargs = [\"-c\", \"echo\"]"))
    #expect(toml.contains("env_vars = [\"FILES_TOKEN\"]"))
    #expect(toml.contains("tool_timeout_sec = 900.0"))
    #expect(overrides.contains("mcp_servers.notion.bearer_token_env_var=\"OPENCLICKY_APP_NOTION_TOKEN\""))

    let json = try JSONValue.parse(claude)
    #expect(json["mcpServers"]?["github"]?["headers"]?["Authorization"]?.stringValue == "Bearer ${OPENCLICKY_APP_GITHUB_TOKEN}")
    #expect(json["mcpServers"]?["gateway"]?["headers"]?["X-Api-Key"]?.stringValue == "${OPENCLICKY_APP_GATEWAY_HEADER_X_API_KEY}")
    #expect(json["mcpServers"]?["files"]?["type"]?.stringValue == "stdio")
    #expect(json["mcpServers"]?["files"]?["env"]?["FILES_TOKEN"]?.stringValue == "${FILES_TOKEN}")
    #expect(json["mcpServers"]?["notion"]?["url"]?.stringValue == "https://mcp.notion.com/mcp")

    let instructions = export.instructions()
    #expect(instructions.contains("`notion`: Notion (Work account)"))
    #expect(instructions.contains("Linear (needs sign-in)"))
    #expect(instructions.contains("$OBSIDIAN_VAULT_PATH"))
}

@Test func agentExportWithNothingConnectedSaysSo() async {
    let export = await ConnectedAppsAgentExporter(registry: ConnectorRegistry(), environment: ConnectorEnvironment(credentials: InMemoryCredentialStore())).export()
    #expect(export.servers.isEmpty)
    #expect(export.instructions().contains("No connected apps"))
    #expect(try! JSONValue.parse(export.claudeCodeMCPConfig()) == ["mcpServers": [:]])
    #expect(export.codexConfigTOML().isEmpty)
}

@Test func tomlStringsAreEscaped() {
    #expect(TOML.string("a\"b\\c\nd\u{1}") == #""a\"b\\c\nd\u0001""#)
    #expect(TOML.key("plain-key_1") == "plain-key_1")
    #expect(TOML.key("has space") == "\"has space\"")
}

// MARK: Composio

@Test func composioSessionRequestUsesTheUsersKeyAndNeverLeaksIt() async throws {
    let fake = FakeHTTPTransport([
        .body(#"{"session_id":"trs_1","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/trs_1/mcp"},"tool_router_tools":["COMPOSIO_SEARCH_TOOLS","COMPOSIO_MULTI_EXECUTE_TOOL"],"config":{},"config_version":1}"#, status: 201),
        .body(#"{"error":{"message":"invalid key ck_live_secret"}}"#, status: 401),
    ])
    let client = ComposioClient(apiKey: "ck_live_secret", http: fake)
    let session = try await client.createSession(userID: "jeff@example.com", toolkits: ["gmail", "googlecalendar"])
    #expect(session.sessionID == "trs_1")
    #expect(session.tools.contains("COMPOSIO_MULTI_EXECUTE_TOOL"))
    let request = fake.requests[0]
    #expect(request.url?.absoluteString == "https://backend.composio.dev/api/v3.1/tool_router/session")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "ck_live_secret")
    let body = try fake.jsonBody(0)
    #expect(body["user_id"]?.stringValue == "jeff@example.com")
    #expect(body["toolkits"]?["enable"] == ["gmail", "googlecalendar"])
    #expect(client.mcpHeaders(for: session.mcpURL) == ["x-api-key": "ck_live_secret"])
    #expect(client.mcpHeaders(for: URL(string: "https://elsewhere.example/mcp")!).isEmpty)
    #expect(!String(describing: client).contains("ck_live_secret"))
    do {
        _ = try await client.createSession(userID: "u")
        Issue.record("expected an error")
    } catch let error as ComposioError {
        #expect(!error.description.contains("ck_live_secret"))
        #expect(error.description.contains("<redacted>"))
    }
}

@Test func composioIsExportedWithItsKeyInAnEnvironmentVariable() async throws {
    let fake = FakeHTTPTransport([
        .body(#"{"session_id":"trs_2","mcp":{"type":"http","url":"https://backend.composio.dev/tool_router/trs_2/mcp"},"tool_router_tools":[]}"#, status: 201),
    ])
    let registry = ConnectorRegistry(composio: ComposioSettings(userID: "u1"))
    let environment = ConnectorEnvironment(credentials: InMemoryCredentialStore([ComposioClient.credentialName: "ck_secret"]), http: fake)
    let export = await ConnectedAppsAgentExporter(registry: registry, environment: environment).export()
    #expect(export.servers.map(\.key) == ["composio"])
    #expect(export.environment[ConnectedAppsAgentExporter.composioKeyVariable] == "ck_secret")
    #expect(export.codexConfigTOML().contains("env_http_headers = { x-api-key = \"OPENCLICKY_COMPOSIO_API_KEY\" }"))
    #expect(!export.codexConfigTOML().contains("ck_secret"))
    #expect(try fake.jsonBody(0)["toolkits"] == nil)
}
