import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests for problems found reviewing the agent harness. Each one failed (or hung) before its fix.

private let reviewSecret = "sk-review-SECRET-0b7e"

/// A manager over the fake Codex harness whose settings take `delay` seconds to arrive, the way reading the config
/// and the Keychain does, so two calls can interleave at that suspension.
private func slowSettingsManager(_ temp: AgentTempDir, delay: Double) throws -> AgentManager {
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": "wait"]
    return AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return AgentLaunchSettings(harness: .codex, model: "test-model", providerID: "harness-login", auth: .harnessLogin,
                                   executable: codex, baseEnvironment: environment)
    }
}

@Test func twoIdenticalSpawnsAtOnceStartOneJob() async throws {
    let temp = AgentTempDir()
    let manager = try slowSettingsManager(temp, delay: 0.2)
    async let first = manager.spawn(AgentSpawnRequest(task: "Summarize the quarterly numbers"))
    async let second = manager.spawn(AgentSpawnRequest(task: "Summarize the quarterly numbers"))
    let results = try await [first, second]

    #expect(results.filter(\.alreadyStarted).count == 1)
    #expect(Set(results.map(\.record.id)).count == 1)
    #expect(manager.store.all().count == 1)
    await manager.shutdown()
}

@Test func twoIdenticalSpawnsForANewKeptAgentStartItOnce() async throws {
    let temp = AgentTempDir()
    let manager = try slowSettingsManager(temp, delay: 0.2)
    async let first = manager.spawn(AgentSpawnRequest(task: "Track the launch", agent: "Scout", keep: true))
    async let second = manager.spawn(AgentSpawnRequest(task: "Track the launch", agent: "Scout", keep: true))
    let results = try await [first, second]

    #expect(results.filter(\.alreadyStarted).count == 1)
    let record = try #require(manager.store.load(id: "scout"))
    #expect(record.runs.count == 1)
    await manager.shutdown()
}

@Test func twoDifferentTasksForANewKeptAgentAtOnceShareOneHarness() async throws {
    // Two sessions_spawn calls in one reply, each its own task, both creating the same kept agent.
    let temp = AgentTempDir()
    let harness = ScriptedHarness { _ in }
    let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness]) { _ in
        try await Task.sleep(nanoseconds: 200_000_000)
        return AgentLaunchSettings(harness: .codex, model: nil, providerID: "harness-login", auth: .harnessLogin,
                                   baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
    }
    async let first = manager.spawn(AgentSpawnRequest(task: "Take notes in the standup", agent: "Scribe", keep: true))
    async let second = manager.spawn(AgentSpawnRequest(task: "Draft the weekly summary", agent: "Scribe", keep: true))
    let results = try await [first, second]

    #expect(Set(results.map(\.record.id)) == ["scribe"])
    // One started the agent; the other reached it as a follow-up.
    #expect(results.filter { $0.sentAs == nil }.count == 1)
    let session = try #require(await agentEventually { harness.sessions.count == 1 } ? harness.sessions.first : nil)
    #expect(await agentEventually { await session.sent.count == 1 })
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(harness.launches.count == 1)
    let launched = try #require(harness.launches.first?.message)
    let followUp = try #require(await session.sent.first)
    #expect([launched, followUp].contains { $0.contains("Take notes in the standup") })
    #expect([launched, followUp].contains { $0.contains("Draft the weekly summary") })
    await manager.shutdown()
}

@Test func aFollowUpSentAsTheTurnEndsBecomesTheNextRun() async throws {
    // Claude Code queues a message sent while it is busy; Codex starts a new turn when the steer finds the turn over.
    for (kind, answer) in [(HarnessKind.claudeCode, AgentSendDisposition.queued), (.codex, .startedTurn)] {
        let rig = ScriptedRig(kind: kind) { _ in }
        let updates = await rig.manager.subscribe()
        let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Write notes", title: "Notes"), waitForStart: true).record
        let session = try #require(rig.harness.sessions.first)
        // The turn ends while the follow-up is on its way to the harness.
        await session.setOnSend { session in
            await session.finish("<report>\nsay: Notes done.\n</report>")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return answer
        }
        let (_, disposition) = try await rig.manager.send(to: job.id, message: "Add a summary")
        #expect(disposition == .startedTurn, "\(kind)")
        #expect(await nextAgentReport(updates, for: job.id)?.run == 1, "\(kind)")
        var record = try #require(await rig.manager.job(job.id))
        #expect(record.runs.count == 2 && record.status == .running, "\(kind)")
        #expect(record.runs.first?.outcome == .completed, "\(kind)")
        let running = await rig.manager.isRunning(job.id)
        let closed = await session.isClosed
        #expect(running && !closed, "\(kind): the session was closed under the follow-up")

        // The follow-up's turn is its own run, and the session closes after it.
        await session.finish("<report>\nsay: Summary added.\n</report>")
        let second = try #require(await nextAgentReport(updates, for: job.id), "\(kind)")
        #expect(second.run == 2 && second.spoken == "Summary added.", "\(kind)")
        record = try #require(await rig.manager.job(job.id))
        #expect(record.status == .done && record.runs.map(\.spoken) == ["Notes done.", "Summary added."], "\(kind)")
        #expect(await agentEventually {
            let closed = await session.isClosed
            let running = await rig.manager.isRunning(job.id)
            return closed && !running
        }, "\(kind)")
        #expect(rig.harness.launches.count == 1, "\(kind)")
    }
}

@Test func aKeptAgentNamedInAnotherCaseKeepsItsOwnFolderPath() async throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let agent = try store.keptAgent(named: "Scribe", role: "note taker", harness: .codex, model: nil, provider: "harness-login")
    #expect(agent.id == "scribe")

    // On a case-insensitive volume agents/Scribe/ opens agents/scribe/; that must not become the record's folder.
    #expect(store.load(id: "Scribe") == nil)
    let manager = AgentManager(store: store) { _ in throw AgentManagerError.configuration("not used") }
    let resolved = try #require(await manager.resolve("Scribe"))
    #expect(resolved.id == "scribe")
    #expect(resolved.folderPath == agent.folderPath)
    #expect(resolved.folder.lastPathComponent == "scribe")
}

@Test func stoppingAChildIsNotHeldUpByAWriteItStoppedReading() async throws {
    // `sleep` never reads stdin, so a write bigger than the pipe buffer blocks until the child dies.
    let child = HarnessProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
                             directory: FileManager.default.temporaryDirectory)
    try child.start()
    let writeEnded = Flag()
    Thread.detachNewThread {
        _ = try? child.writeLine(String(repeating: "x", count: 1 << 20))
        writeEnded.set()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(!writeEnded.isSet, "the write should be stuck on the full pipe")

    let stopped = Flag()
    Task.detached {
        await child.terminate(grace: 0.5)
        stopped.set()
    }
    // The limits are hang guards, well short of the 30 s a terminate() stuck behind the write would wait for the child.
    #expect(await agentEventually { stopped.isSet }, "terminate() waited behind the stuck write")
    #expect(await agentEventually { !child.isRunning })
    #expect(await agentEventually { writeEnded.isSet }, "the stuck write should fail once the child is gone")
    #expect(throws: AgentHarnessError.notRunning) { try child.writeLine("late") }
}

@Test func aCronScheduleThatNeverComesRoundIsRejected() throws {
    #expect(throws: RoutineError.self) { try RoutineSchedule.cron("0 0 30 2 *").validate() }
    #expect(throws: RoutineError.self) { try RoutineSchedule.cron("15 9 31 4,6,9,11 *").validate() }
    // Rare but real dates still pass: leap days, and the 31st in months that have one.
    try RoutineSchedule.cron("0 0 29 2 *").validate()
    try RoutineSchedule.cron("0 0 31 * *").validate()
}

@Test func discoveryReadsTheFileTheBrowserBridgeWrites() throws {
    let temp = AgentTempDir()
    let paths = BrowserBridgePaths(directory: temp.url.appendingPathComponent("BrowserBridge", isDirectory: true))
    let endpoint = BrowserMCPEndpoint(url: URL(string: "http://127.0.0.1:47123/mcp")!, token: "bridge-token-1", pid: getpid())
    try endpoint.write(to: paths)

    let server = try #require(AgentMCPDiscovery.browserServer(file: paths.mcpEndpoint))
    #expect(server.name == BrowserMCPEndpoint.serverName)
    #expect(server.tokenEnvironmentVariable == BrowserMCPEndpoint.tokenEnvironmentVariable)
    #expect(server.bearerToken == "bridge-token-1")
    #expect(server.transport == .http(URL(string: "http://127.0.0.1:47123/mcp")!))
    // The agent looks where the bridge writes, whatever OPENCLICKY_SUPPORT_DIR says.
    #expect(AgentMCPDiscovery.browserEndpointFile == BrowserBridgePaths.standard.mcpEndpoint)
}

@Test func codexKeepsOpenClickySecretsAwayFromTheAgentsCommands() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let folder = temp.paths.jobs.appendingPathComponent("job-1", isDirectory: true)
    let provider = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai")
    let browser = AgentMCPServer(name: "browser", transport: .http(URL(string: "http://127.0.0.1:47011/mcp")!), bearerToken: "tok")
    let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path]

    // Own key: OpenClicky's CODEX_HOME, where the filters can be written.
    let keyed = try CodexHarness().plan(for: HarnessLaunch(
        folder: folder, instructions: "x", model: nil, auth: .provider(provider, apiKey: reviewSecret), mcpServers: [browser],
        executable: fake, paths: temp.paths, baseEnvironment: environment))
    let toml = try #require(keyed.configTOML)
    #expect(toml.contains("[shell_environment_policy.filters]\nOPENCLICKY_AGENT_API_KEY = \"exclude\"\nOPENCLICKY_MCP_TOKEN_BROWSER = \"exclude\"\n"))
    #expect(toml.contains("\nnotify = []\n"))
    #expect(!toml.contains(reviewSecret))
    #expect(keyed.environment[CodexHarness.apiKeyVariable] == reviewSecret)

    // Harness login on the user's own home: no filters (they would switch off the user's own exclude list), but
    // their notify program is still kept out of the job.
    let login = try CodexHarness(hasLogin: { _ in false }, listUserMCPServers: { _, _ in [] }).plan(for: HarnessLaunch(
        folder: folder, instructions: "x", model: nil, auth: .harnessLogin, mcpServers: [browser],
        executable: fake, paths: temp.paths, baseEnvironment: environment))
    #expect(login.configTOML == nil)
    #expect(!login.arguments.contains { $0.hasPrefix("shell_environment_policy") })
    #expect(login.arguments.contains("notify=[]"))
    #expect(login.environment[CodexHarness.apiKeyVariable] == nil)
}

@Test func claudeCodeStripsTheKeyFromTheAgentsCommandsWhenItHoldsOne() throws {
    let temp = AgentTempDir()
    let fake = try temp.script("claude", FakeHarnessScripts.claude)
    let folder = temp.paths.jobs.appendingPathComponent("job-1", isDirectory: true)
    let provider = ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")
    let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path]

    let keyed = try ClaudeCodeHarness().plan(for: HarnessLaunch(
        folder: folder, instructions: "x", model: nil, auth: .provider(provider, apiKey: reviewSecret), executable: fake,
        paths: temp.paths, baseEnvironment: environment))
    #expect(keyed.environment["ANTHROPIC_API_KEY"] == reviewSecret)
    #expect(keyed.environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == "1")

    let login = try ClaudeCodeHarness().plan(for: HarnessLaunch(
        folder: folder, instructions: "x", model: nil, auth: .harnessLogin, executable: fake, paths: temp.paths,
        baseEnvironment: environment))
    #expect(login.environment["ANTHROPIC_API_KEY"] == nil)
    #expect(login.environment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] == nil)
}

@Test func listingTheUsersCodexServersNeverHoldsACooperativeThread() async throws {
    // `codex mcp list` can take seconds; the voice pipeline shares Swift's few cooperative threads.
    let temp = AgentTempDir()
    let fake = try temp.script("codex", FakeHarnessScripts.codex)
    let folder = temp.paths.jobs.appendingPathComponent("job-1", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let queue = Box<String>()
    let harness = CodexHarness(hasLogin: { _ in false }, listUserMCPServers: { _, _ in
        queue.value = String(cString: __dispatch_queue_get_label(nil))
        return []
    })
    let session = try await harness.start(HarnessLaunch(
        folder: folder, instructions: "x", model: nil, auth: .harnessLogin, executable: fake, paths: temp.paths,
        baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": "quick"]), message: "hi", images: [])
    await session.close()
    let label = try #require(queue.value)
    #expect(!label.contains("cooperative"), "ran on \(label)")
}

/// A thread-safe box for one value.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private var stored: Value?
    private let lock = NSLock()
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A thread-safe one-way flag.
private final class Flag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
