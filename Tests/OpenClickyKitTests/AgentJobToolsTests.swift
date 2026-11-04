import Foundation
import Testing
@testable import OpenClickyKit

// OpenClicky's MCP tools for jobs, called over loopback HTTP the way a harness calls them: the job header names the
// calling job; web search goes through the configured lookups; progress reaches the HUD feed; adding a routine waits
// for the user's yes through the needs-you flow and lands in routines.json.

private struct FakeSearch: WebSearchProvider {
    var providerID: String { "fake" }
    func search(_ query: WebSearchQuery) async throws -> [WebSearchResult] {
        [WebSearchResult(title: "Swift 6.2 released", url: URL(string: "https://www.swift.org/blog/swift-6.2-released/")!,
                         snippet: "Swift 6.2 is now available.")]
    }
}

/// One tools/call over HTTP with the job header, returning the JSON-RPC result.
private func call(_ url: URL, token: String, tool: String, arguments: JSONValue, job: String?, meta: JSONValue? = nil) async throws -> JSONValue {
    var params: [String: JSONValue] = ["name": .string(tool), "arguments": arguments]
    if let meta { params["_meta"] = meta }
    let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": .object(params)]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let job { request.setValue(job, forHTTPHeaderField: AgentJobMCPTools.jobHeader) }
    request.httpBody = try body.jsonData()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 30
    let (data, _) = try await URLSession(configuration: configuration).data(for: request)
    let reply = try JSONDecoder().decode(JSONValue.self, from: data)
    return reply["result"] ?? reply
}

private struct ToolRig {
    let temp = AgentTempDir()
    let coordinator: AgentCoordinator
    let server: MCPHTTPServer
    let url: URL
    let token = "job-tools-token"

    init(search: Bool = true, script: @escaping @Sendable (ScriptedSession) async -> Void = { _ in }) throws {
        let harness = ScriptedHarness(script: script)
        let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness], approvalTimeout: 30) { _ in
            AgentLaunchSettings(harness: .codex, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin,
                                baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
        }
        coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
        let tools = coordinator.jobTools(lookups: { search ? LookupTools(services: LookupServices(webSearch: FakeSearch())) : nil })
        server = MCPHTTPServer(name: "openclicky_browser", version: "test", token: token, tools: tools.tools)
        url = try server.start()
    }

    /// A job that is running (its harness waits until the test finishes it).
    func runningJob() async throws -> AgentJobRecord {
        try await coordinator.manager.spawn(AgentSpawnRequest(task: "Watch fares", title: "Fares"), waitForStart: true).record
    }
}

@Suite struct AgentJobToolsTests {
    @Test func theToolsAreListedNextToEachOther() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let client = MCPHTTPClient(url: rig.url, token: rig.token, timeout: 10)
        _ = try await client.initialize()
        let names = try await client.listTools().compactMap { $0["name"]?.stringValue }
        #expect(names == AgentJobMCPTools.names)
    }

    @Test func webSearchUsesTheConfiguredServiceAndNotesTheStep() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let job = try await rig.runningJob()
        let updates = await rig.coordinator.manager.subscribe()
        let result = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.webSearchName,
                                    arguments: ["query": "swift 6.2 release", "count": 2], job: job.id)
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["provider"] == "fake")
        #expect(result["structuredContent"]?["results"]?.arrayValue?.first?["url"] == "https://www.swift.org/blog/swift-6.2-released/")
        #expect(await agentEventually {
            rig.coordinator.manager.store.events(of: job).contains { $0.kind == "progress" && $0.text == "Searching the web: swift 6.2 release" }
        })
        _ = updates

        // No service set up: a clear error, not a crash.
        let bare = try ToolRig(search: false)
        defer { bare.server.stop() }
        let none = try await call(bare.url, token: bare.token, tool: AgentJobMCPTools.webSearchName, arguments: ["query": "x"], job: nil)
        #expect(none["isError"] == true)
        #expect(none["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("No web search service") == true)
    }

    @Test func progressReachesTheHUDFeedAndTheJobLog() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let job = try await rig.runningJob()
        let updates = await rig.coordinator.manager.subscribe()
        let collector = Task { () -> AgentActivityFeed in
            var feed = AgentActivityFeed(records: [job])
            for await update in updates {
                feed.apply(update)
                if feed.item(job.id)?.plan.count == 2, feed.item(job.id)?.lines.last == "Comparing three airlines" { break }
            }
            return feed
        }
        let result = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.progressName, arguments: [
            "line": "Comparing three airlines",
            "plan": [["step": "Search fares", "status": "completed"], ["step": "Compare", "status": "in_progress"]],
        ], job: job.id)
        #expect(result["isError"] == false)
        let feed = await collector.value
        #expect(feed.item(job.id)?.plan.map(\.status) == [.completed, .inProgress])
        #expect(feed.item(job.id)?.planProgress == 0.5)
        let record = try #require(await rig.coordinator.manager.job(job.id))
        #expect(record.lastSaid == "Comparing three airlines")
        let kinds = rig.coordinator.manager.store.events(of: record).map(\.kind)
        #expect(kinds.contains("plan") && kinds.contains("commentary"))

        // Without the header (or a known thread in _meta) the job can't be told.
        let unknown = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.progressName, arguments: ["line": "x"], job: nil)
        #expect(unknown["isError"] == true)
        // Codex's turn metadata names the thread; that finds the job too.
        let byThread = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.progressName, arguments: ["line": "From Codex"], job: nil,
                                      meta: ["x-codex-turn-metadata": ["thread_id": "scripted-thread", "turn_id": "t1"]])
        #expect(byThread["isError"] == false)
        #expect(await rig.coordinator.manager.job(job.id)?.lastSaid == "From Codex")
    }

    @Test func addingARoutineWaitsForTheUsersYesThenItIsInRoutinesJSON() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let job = try await rig.runningJob()
        let manager = rig.coordinator.manager
        let adding = Task {
            try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName, arguments: [
                "action": "add", "title": "Fare watch", "task": "Check SFO to DEN fares", "every_minutes": 120,
            ], job: job.id)
        }
        // The job waits on the user, with the request in the usual place.
        #expect(await agentEventually { await manager.job(job.id)?.pendingRequest?.summary.hasPrefix("Set up a routine: Create the routine \"Fare watch\"") == true })
        let waiting = try #require(await manager.job(job.id))
        #expect(waiting.status == .needsYou)
        #expect(RoutineStore(url: rig.temp.paths.routines).load().isEmpty)

        #expect(try await manager.answer(job.id, decision: .approve(always: false)) == .answered)
        let result = try await adding.value
        #expect(result["structuredContent"]?["status"] == "created")
        let routines = RoutineStore(url: rig.temp.paths.routines).load()
        #expect(routines.map(\.title) == ["Fare watch"])
        #expect(routines.first?.jobID == job.id)
        #expect(routines.first?.schedule == .every(minutes: 120))
        #expect(await manager.job(job.id)?.status == .running)
        #expect(await manager.job(job.id)?.pendingRequest == nil)

        // list marks it as this job's; pause changes only this job's routines.
        let list = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName, arguments: ["action": "list"], job: job.id)
        #expect(list["structuredContent"]?["routines"]?.arrayValue?.first?["this_job"] == true)
        let paused = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName,
                                    arguments: ["action": "pause", "title": "fare watch"], job: job.id)
        #expect(paused["structuredContent"]?["status"] == "paused")
        #expect(RoutineStore(url: rig.temp.paths.routines).load().first?.isPaused == true)
        let other = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName,
                                   arguments: ["action": "pause", "title": "Someone else's"], job: job.id)
        #expect(other["isError"] == true)
    }

    @Test func aDeclinedRoutineIsNotCreated() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let job = try await rig.runningJob()
        let manager = rig.coordinator.manager
        let adding = Task {
            try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName, arguments: [
                "action": "add", "title": "Fare watch", "task": "Check fares", "at": "08:00", "days": ["mon", "fri"],
            ], job: job.id)
        }
        #expect(await agentEventually { await manager.job(job.id)?.pendingRequest != nil })
        #expect(try await manager.answer(job.id, decision: .decline) == .answered)
        #expect(try await adding.value["structuredContent"]?["status"] == "declined")
        #expect(RoutineStore(url: rig.temp.paths.routines).load().isEmpty)

        let invalid = try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName,
                                     arguments: ["action": "add", "title": "No task", "every_minutes": 5], job: job.id)
        #expect(invalid["isError"] == true)
    }

    @Test func stoppingTheJobEndsAWaitingConfirmationAndTheToolCallReturns() async throws {
        let rig = try ToolRig()
        defer { rig.server.stop() }
        let job = try await rig.runningJob()
        let manager = rig.coordinator.manager
        let adding = Task {
            try await call(rig.url, token: rig.token, tool: AgentJobMCPTools.routinesName, arguments: [
                "action": "add", "title": "Fare watch", "task": "Check fares", "every_minutes": 120,
            ], job: job.id)
        }
        #expect(await agentEventually { await manager.job(job.id)?.pendingRequest != nil })
        #expect(await manager.interrupt(job.id))
        let result = try await adding.value
        #expect(result["structuredContent"]?["status"] == "no_answer")
        let stopped = try #require(await manager.job(job.id))
        #expect(stopped.status == .stopped && stopped.pendingRequest == nil)
        #expect(RoutineStore(url: rig.temp.paths.routines).load().isEmpty)
        // A confirmation waits less than the 900 s the harnesses give OpenClicky's tools.
        #expect(AgentManager.localConfirmTimeout < AgentMCPServer(name: "x", transport: .http(URL(string: "http://127.0.0.1:9/mcp")!)).toolTimeout)
    }

    @Test func theInstructionsDoNotNameOneServerForTheTools() {
        // The app offers them on openclicky_browser, `occtl agent run --job-tools` on openclicky_tools.
        #expect(!AgentInstructions.jobTools.contains("openclicky_browser"))
        #expect(!AgentInstructions.jobTools.contains(AgentJobToolServer.serverName))
        #expect(AgentInstructions.jobTools.contains(AgentJobMCPTools.routinesName))
    }

    @Test func launchesCarryTheJobHeaderAsASecret() {
        var server = AgentMCPServer(name: "openclicky_browser", transport: .http(URL(string: "http://127.0.0.1:9/mcp")!), bearerToken: "t")
        server.jobHeaderName = AgentJobMCPTools.jobHeader
        let plain = AgentMCPServer(name: "other", transport: .http(URL(string: "http://127.0.0.1:8/mcp")!))
        let launched = AgentManager.identifyingJob("fares-0123456789", in: [server, plain])
        #expect(launched[0].secretHeaders == [AgentJobMCPTools.jobHeader: "OPENCLICKY_MCP_JOB_OPENCLICKY_BROWSER"])
        #expect(launched[0].harnessSecrets["OPENCLICKY_MCP_JOB_OPENCLICKY_BROWSER"] == "fares-0123456789")
        #expect(launched[1] == plain)
        // Claude Code gets it as a ${VAR} header, never the value itself.
        let config = ClaudeCodeHarness.mcpConfig(launched, aliases: ClaudeCodeHarness.mcpVariableAliases(launched))
        #expect(config.contains("\"X-OpenClicky-Job\":\"${OPENCLICKY_MCPVAR_"))
        #expect(!config.contains("fares-0123456789"))
    }

    @Test func planStepsSentAsAStringOrPlainTextAreRead() throws {
        let asString = AgentJobMCPTools.planSteps(.string(#"[{"step":"Search","status":"done"},{"step":"Write","status":"in-progress"}]"#))
        #expect(asString?.map(\.step) == ["Search", "Write"])
        #expect(asString?.map(\.status) == [.completed, .inProgress])
        let plain = AgentJobMCPTools.planSteps(.array([.string("Search"), .string(" ")]))
        #expect(plain?.map(\.step) == ["Search"])
        #expect(plain?.first?.status == .pending)
        #expect(AgentJobMCPTools.planSteps(.string("not a plan")) == nil)
    }

    @Test func claudeCodeMayCallTheJobToolsWithoutAsking() {
        var server = AgentMCPServer(name: "openclicky_browser", transport: .http(URL(string: "http://127.0.0.1:9/mcp")!))
        server.trustedTools = AgentJobMCPTools.names + ["bad name"]
        let other = AgentMCPServer(name: "other", transport: .http(URL(string: "http://127.0.0.1:8/mcp")!))
        #expect(ClaudeCodeHarness.trustedToolNames([server, other]) == AgentJobMCPTools.names.map { "mcp__openclicky_browser__\($0)" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("endpoint-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(BrowserMCPEndpoint(url: URL(string: "http://127.0.0.1:9/mcp")!, token: "t", pid: 1)).write(to: file)
        #expect(AgentMCPDiscovery.browserServer(file: file, isAlive: { _ in true })?.trustedTools == AgentJobMCPTools.names)
    }
}
