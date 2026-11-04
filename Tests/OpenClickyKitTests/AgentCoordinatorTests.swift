import Foundation
import Testing
@testable import OpenClickyKit

private func record(_ id: String, status: AgentJobStatus, title: String = "Job", runs: Int = 1) -> AgentJobRecord {
    var record = AgentJobRecord(id: id, kind: .job, title: title, task: title, harness: .codex, model: nil, provider: "harness-login",
                                status: status, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                                runs: [], usage: .init(), folderPath: "/tmp/jobs/\(id)")
    record.runs = (0..<runs).map { AgentRun(ask: "ask \($0)", startedAt: Date(timeIntervalSince1970: 100)) }
    return record
}

private func report(_ id: String, outcome: AgentJobReport.Outcome, spoken: String = "It worked.", files: [String] = [],
                    question: String? = nil, routineID: String? = nil, agent: String? = nil) -> AgentJobReport {
    AgentJobReport(jobID: id, run: 1, title: "Flights", agentName: agent, outcome: outcome, spoken: spoken, markdown: "", files: files,
                   nextSteps: [], question: question, error: outcome == .failed ? "boom" : nil, routineID: routineID,
                   startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 42))
}

@Test func theCoordinatorBatchesReportsNotifiesAndClosesRoutineRuns() async throws {
    let temp = AgentTempDir()
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let manager = AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: "harness-login", auth: .harnessLogin, executable: codex,
                            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": "quick"])
    }
    let batches = ReportBox()
    let notices = NoticeBox()
    let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), reportDelay: 0.2,
                                       onReports: { batches.add($0) }, onNotice: { notices.add($0) })
    await coordinator.start()

    let routine = try await coordinator.routines.create(title: "Notes", task: "Write meeting notes", schedule: .every(minutes: 600))
    let jobID = try await coordinator.routines.runNow(routine.id)
    // Each run starts a harness process and waits for its report; the limits are hang guards for a busy machine.
    #expect(await agentEventually(30) { batches.batches.count == 1 })
    let batch = try #require(batches.batches.first)
    #expect(batch.map(\.jobID) == [jobID])
    #expect(batch.first?.routineID == routine.id)
    #expect(notices.all.map(\.title) == ["Meeting Notes is done"])
    #expect(notices.all.first?.body == "Your notes are ready. · notes.md")
    #expect(await agentEventually { await coordinator.routines.list().first?.lastOutcome == .completed })
    #expect(await coordinator.routines.list().first?.jobID == jobID)

    // The next run of the routine continues in the same folder and is told it is a repeat.
    let again = try await coordinator.routines.runNow(routine.id)
    #expect(again == jobID)
    #expect(await agentEventually(30) { batches.batches.count == 2 })
    #expect(await manager.job(jobID)?.runs.count == 2)

    let context = try #require(await coordinator.brainContext())
    #expect(context.hasPrefix("[Your jobs]"))
    #expect(context.contains("\(jobID) \"Notes\": done, said: Your notes are ready."))
    await coordinator.stop()
}

extension AgentReportBatcher {
    /// Adds `reports` in one turn on the batcher, so they arrive together however late a busy machine runs this task:
    /// the batch's timer can't fire between them.
    fileprivate func add(_ reports: [AgentJobReport]) {
        for report in reports { add(report) }
    }
}

@Test func reportBatcherGroupsReportsThatArriveTogether() async {
    let box = ReportBox()
    let batcher = AgentReportBatcher(delay: 0.15) { box.add($0) }
    await batcher.add([report("a", outcome: .done), report("b", outcome: .failed), report("a", outcome: .done, spoken: "Newer.")])
    // The limits only guard against a hang: a busy machine can run the batch's timer seconds late.
    #expect(await agentEventually { box.batches.count == 1 })
    #expect(box.batches.first?.map(\.jobID) == ["b", "a"])
    #expect(box.batches.first?.last?.spoken == "Newer.")
    await batcher.add(report("c", outcome: .done))
    #expect(await agentEventually { box.batches.count == 2 })
    #expect(box.batches.last?.map(\.jobID) == ["c"])
}

@Test func reportTurnNoteAndJSONAreCompact() throws {
    let done = report("job-1", outcome: .done, files: ["/tmp/jobs/job-1/output/a.md"], routineID: "r1", agent: "Buddy")
    let json = done.json
    #expect(json["say"]?.stringValue == "It worked.")
    #expect(json["seconds"]?.intValue == 42)
    #expect(json["agent"]?.stringValue == "Buddy")
    #expect(json["routine_id"]?.stringValue == "r1")
    #expect(json["error"] == nil)
    #expect(report("x", outcome: .failed).json["error"]?.stringValue == "boom")
    let note = AgentReportTurn.note(for: [done, report("job-2", outcome: .needsYou, question: "Which account?")])
    #expect(note.hasPrefix("[Jobs came back] 2 background jobs finished"))
    #expect(note.contains("show_result"))
    let lines = note.split(separator: "\n").suffix(2)
    #expect(try lines.map { try JSONValue.parse(String($0))["job_id"]?.stringValue } == ["job-1", "job-2"])
}

@Test func reportsFromRecords() {
    var finished = record("j", status: .done, title: "Flights")
    finished.report = AgentFinalReport(markdown: "Body", spoken: "", title: nil)
    let made = AgentJobReport.make(record: finished, outputs: ["output/x.csv"])
    #expect(made.spoken == "Flights is done.")
    #expect(made.files == ["/tmp/jobs/j/output/x.csv"])
    var failed = record("k", status: .failed, title: "Budget")
    failed.error = "The model refused. Then more."
    #expect(AgentJobReport.make(record: failed, outputs: []).spoken == "Budget didn't work out: The model refused.")
    let stopped = record("s", status: .stopped, title: "Scan")
    #expect(AgentJobReport.make(record: stopped, outputs: []).spoken == "I stopped Scan before it finished.")
    var asking = record("q", status: .needsYou, title: "Form")
    asking.report = AgentFinalReport(markdown: "", spoken: "I filled most of it.", question: "Which address?")
    let question = AgentJobReport.make(record: asking, outputs: [])
    #expect(question.outcome == .needsYou && question.question == "Which address?")
}

@Test func noticesSayWhatHappened() {
    #expect(AgentNotice.make(from: report("a", outcome: .done, files: ["/x/output/plan.pdf"])).body == "It worked. · plan.pdf")
    #expect(AgentNotice.make(from: report("a", outcome: .done, files: ["https://example.com/page"])).body == "It worked. · example.com")
    let asking = AgentNotice.make(from: report("a", outcome: .needsYou, spoken: "Almost there.", question: "Which card?", agent: "Shopper"))
    #expect(asking.title == "Shopper needs you")
    #expect(asking.body == "Almost there. Which card?")
    #expect(asking.needsAttention)
    #expect(AgentNotice.make(from: report("a", outcome: .failed)).title == "Flights didn't finish")
    #expect(AgentNotice.make(from: report("a", outcome: .stopped)).title == "Flights stopped")
    #expect(AgentNotice.make(from: report("a", outcome: .done)).id == "a#1")
}

@Test func brainContextListsActiveWorkFirst() {
    var running = record("run-1", status: .running, title: "Research")
    running.lastProgress = "Searching: flights"
    var waiting = record("wait-1", status: .needsYou, title: "Form")
    waiting.pendingRequest = AgentApprovalRequest(id: "r9", kind: .command, summary: "Run curl")
    var done = record("done-1", status: .done, title: "Notes")
    done.report = AgentFinalReport(markdown: "", spoken: "Notes are ready.")
    let note = AgentBrainContext.note(jobs: [done, running, waiting], running: ["run-1"], now: Date(timeIntervalSince1970: 130)) ?? ""
    let lines = note.split(separator: "\n").map(String.init)
    #expect(lines.count == 4)
    #expect(lines[1] == "- run-1 \"Research\": WORKING NOW, latest: Searching: flights (30s)")
    #expect(lines[2] == "- wait-1 \"Form\": WAITING ON THE USER to approve: Run curl [request_id r9]")
    #expect(lines[3] == "- done-1 \"Notes\": done, said: Notes are ready.")
    #expect(AgentBrainContext.note(jobs: [], running: []) == nil)
}

@Test func theActivityFeedFollowsJobsLive() throws {
    var feed = AgentActivityFeed(records: [record("old", status: .done, title: "Old")])
    var job = record("new", status: .queued, title: "New")
    feed.apply(.job(job))
    #expect(feed.items.map(\.id) == ["new", "old"])
    job.status = .running
    feed.apply(.job(job))
    feed.apply(.event(jobID: "new", .plan([AgentPlanStep(step: "Search", status: .completed), AgentPlanStep(step: "Write", status: .inProgress)])))
    for index in 0..<8 { feed.apply(.event(jobID: "new", .progress("line \(index)"))) }
    feed.apply(.event(jobID: "new", .progress("line 7")))
    feed.apply(.event(jobID: "new", .fileChanged(path: "/tmp/jobs/new/output/a.md", change: "created")))
    feed.apply(.event(jobID: "new", .log("ignored")))
    var item = try #require(feed.item("new"))
    #expect(item.lines.count == AgentActivityFeed.linesPerJob)
    #expect(item.lines.last == "Created a.md")
    #expect(item.planProgress == 0.5)
    #expect(item.touchedFiles == ["/tmp/jobs/new/output/a.md"])
    #expect(item.headline == "Created a.md")
    #expect(feed.active.map(\.id) == ["new"])

    job.status = .needsYou
    job.pendingRequest = AgentApprovalRequest(id: "1", kind: .tool, summary: "Use the browser")
    feed.apply(.job(job))
    #expect(feed.item("new")?.headline == "Needs a yes: Use the browser")
    #expect(feed.needsYouCount == 1)

    job.status = .done
    job.pendingRequest = nil
    feed.apply(.job(job))
    feed.apply(.report(report("new", outcome: .done, spoken: "All set.")))
    item = try #require(feed.item("new"))
    #expect(item.headline == "All set.")

    // A new run clears the previous run's lines and plan.
    job.runs.append(AgentRun(ask: "again", startedAt: Date()))
    job.status = .running
    feed.apply(.job(job))
    #expect(feed.item("new")?.lines.isEmpty == true)
    #expect(feed.item("new")?.planProgress == nil)
    feed.apply(.event(jobID: "ghost", .progress("nothing")))
    #expect(feed.items.count == 2)
}

@Test func theBrowserBridgeMCPServerIsOfferedOnlyWhileItRuns() throws {
    let temp = AgentTempDir()
    let file = temp.url.appendingPathComponent("mcp.json")
    let token = "f00d" + String(repeating: "a", count: 60)
    func write(_ json: String) throws { try json.write(to: file, atomically: true, encoding: .utf8) }

    try write(#"{"url":"http://127.0.0.1:59213/mcp","token":"\#(token)","serverName":"openclicky_browser","tokenEnvironmentVariable":"OPENCLICKY_BROWSER_MCP_TOKEN","transport":"streamable-http","pid":\#(getpid()),"startedAt":"2026-10-31T00:00:00Z"}"#)
    let server = try #require(AgentMCPDiscovery.browserServer(file: file))
    #expect(server.name == "openclicky_browser")
    #expect(server.transport == .http(URL(string: "http://127.0.0.1:59213/mcp")!))
    #expect(server.bearerToken == token)
    #expect(server.tokenEnvironmentVariable == "OPENCLICKY_BROWSER_MCP_TOKEN")
    #expect(server.toolTimeout == 900)

    // Codex gets the URL and the variable's name in its config; the token only in the environment.
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let launch = HarnessLaunch(folder: temp.url, instructions: "", model: nil, auth: .harnessLogin, mcpServers: [server],
                               executable: codex, paths: temp.paths, baseEnvironment: ["PATH": "/usr/bin", "HOME": temp.url.path])
    let plan = try CodexHarness(hasLogin: { _ in true }).plan(for: launch)
    #expect(plan.configTOML?.contains("[mcp_servers.openclicky_browser]") == true)
    #expect(plan.configTOML?.contains(#"bearer_token_env_var = "OPENCLICKY_BROWSER_MCP_TOKEN""#) == true)
    #expect(plan.configTOML?.contains(token) == false)
    #expect(plan.environment["OPENCLICKY_BROWSER_MCP_TOKEN"] == token)
    let claude = try ClaudeCodeHarness().plan(for: { var l = launch; l.executable = try! temp.script("claude", FakeHarnessScripts.claude); return l }())
    // Claude Code reads it under a plain alias (it withholds TOKEN-like names from expansion when scrubbing).
    #expect(claude.mcpConfig.contains("Bearer ${OPENCLICKY_MCPVAR_1}"))
    #expect(claude.mcpVariables == ["OPENCLICKY_BROWSER_MCP_TOKEN": "OPENCLICKY_MCPVAR_1"])
    #expect(claude.environment["OPENCLICKY_MCPVAR_1"] == token)
    #expect(!claude.mcpConfig.contains(token))

    // Stale (dead process), remote, malformed or missing: not offered.
    #expect(AgentMCPDiscovery.browserServer(file: file, isAlive: { _ in false }) == nil)
    try write(#"{"url":"http://example.com:59213/mcp","token":"t","pid":\#(getpid())}"#)
    #expect(AgentMCPDiscovery.browserServer(file: file) == nil)
    try write("{nope")
    #expect(AgentMCPDiscovery.browserServer(file: file) == nil)
    #expect(AgentMCPDiscovery.browserServer(file: temp.url.appendingPathComponent("missing.json")) == nil)
    // Odd names fall back to safe ones.
    try write(#"{"url":"http://localhost:1/mcp","token":"t","serverName":"bad name]","tokenEnvironmentVariable":"lower-case"}"#)
    let fallback = try #require(AgentMCPDiscovery.browserServer(file: file))
    #expect(fallback.name == "openclicky_browser")
    #expect(fallback.tokenEnvironmentVariable == "OPENCLICKY_MCP_TOKEN_OPENCLICKY_BROWSER")
}

@Test func harnessEnvironmentDropsInheritedKeysAndNestingMarkers() {
    let child = HarnessEnvironment.child(
        base: ["PATH": "/usr/bin", "HOME": "/Users/x", "OPENAI_API_KEY": "a", "ANTHROPIC_API_KEY": "b", "ANTHROPIC_BASE_URL": "c",
               "OPENCLICKY_KEY_OPENAI": "d", "OPENCLICKY_MCP_TOKEN_X": "e", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ACCESS_TOKEN": "f",
               "CODEX_THREAD_ID": "g", "LANG": "en_US.UTF-8", "NO_PROXY": "corp.example"],
        stripping: [], adding: ["ANTHROPIC_API_KEY": "mine"], executable: URL(fileURLWithPath: "/opt/tools/bin/claude"))
    #expect(child["ANTHROPIC_API_KEY"] == "mine")
    for gone in ["OPENAI_API_KEY", "ANTHROPIC_BASE_URL", "OPENCLICKY_KEY_OPENAI", "OPENCLICKY_MCP_TOKEN_X", "CLAUDECODE",
                 "CLAUDE_CODE_SESSION_ACCESS_TOKEN", "CODEX_THREAD_ID"] {
        #expect(child[gone] == nil, "\(gone)")
    }
    #expect(child["LANG"] == "en_US.UTF-8")
    #expect(child["PATH"]?.hasPrefix("/opt/tools/bin:/usr/bin:/opt/homebrew/bin:") == true)
    #expect(child["PATH"]?.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count == 1)
    #expect(child["NO_PROXY"] == "corp.example,localhost,127.0.0.1,::1")
}

final class NoticeBox: @unchecked Sendable {
    private var notices: [AgentNotice] = []
    private let lock = NSLock()
    func add(_ notice: AgentNotice) { lock.withLock { notices.append(notice) } }
    var all: [AgentNotice] { lock.withLock { notices } }
}
