import Foundation
import Testing
@testable import OpenClickyKit

// Agent limits, compaction and cleanup: the step cap, the per-run wall clock, the command timeout and compaction
// threshold the harnesses get, the ledger that survives compaction, the assume-and-say-so fallback, the idle end,
// the 30-day cleanup, the ownership marker and the deliverable kind.

@Test func aRunThatPassesTheStepCapIsStoppedAndSaysWhy() async throws {
    var limits = AgentLimits()
    limits.maxStepsPerRun = 3
    let rig = ScriptedRig(limits: limits) { session in
        for index in 1...10 { await session.emit(.progress("Running: step \(index)")) }
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Loop forever", title: "Loop"), waitForStart: true)
    let report = try #require(await nextAgentReport(updates, for: result.record.id))
    #expect(report.outcome == .stopped)
    #expect(report.spoken.contains("limit of 3 steps"))
    let record = try #require(await rig.manager.job(result.record.id))
    #expect(record.runs.last?.stopReason?.contains("limit of 3 steps") == true)
    #expect(await rig.harness.sessions.first?.interrupts == 1)
    // Failure and notice lines aren't steps.
    #expect(!AgentManager.isStep(.progress("Command failed (exit 1): ls")))
    #expect(!AgentManager.isStep(.progress("Got your follow-up")))
    #expect(AgentManager.isStep(.progress("Using notion: search")))
}

@Test func aRunPastItsWallClockIsStopped() async throws {
    var limits = AgentLimits()
    limits.maxRunSeconds = 0.4
    let rig = ScriptedRig(limits: limits) { session in
        await session.emit(.progress("Running: sleep 600"))
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Wait a long time", title: "Slow"), waitForStart: true)
    let report = try #require(await nextAgentReport(updates, for: result.record.id))
    #expect(report.outcome == .stopped)
    #expect(report.spoken.contains("the limit for one task"))
}

@Test func harnessesGetTheCommandTimeoutAndCompactionThreshold() throws {
    let temp = AgentTempDir()
    let claude = try temp.script("claude", "#!/bin/sh\nexit 0\n")
    let codex = try temp.script("codex", "#!/bin/sh\nexit 0\n")
    var limits = AgentLimits()
    limits.commandTimeoutSeconds = 120
    limits.compactionTokens = 150_000
    let launch = HarnessLaunch(folder: temp.url, instructions: "x", model: nil, auth: .harnessLogin, executable: claude, paths: temp.paths,
                               baseEnvironment: ["PATH": "/usr/bin", "HOME": temp.url.path, "BASH_MAX_TIMEOUT_MS": "1"], limits: limits)
    let plan = try ClaudeCodeHarness().plan(for: launch)
    #expect(plan.environment["BASH_DEFAULT_TIMEOUT_MS"] == "120000")
    #expect(plan.environment["BASH_MAX_TIMEOUT_MS"] == "120000")
    #expect(plan.environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] == "150000")

    var codexLaunch = launch
    codexLaunch.executable = codex
    codexLaunch.auth = .provider(ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"),
                                                credential: "openai"), apiKey: "sk-test")
    let codexPlan = try CodexHarness(listUserMCPServers: { _, _ in [] }).plan(for: codexLaunch)
    #expect(codexPlan.configTOML?.contains("model_auto_compact_token_limit = 150000") == true)
    // The instructions state the limits.
    let record = AgentJobRecord(id: "j", kind: .job, title: "T", task: "T", harness: .codex, model: nil, provider: "x", status: .queued,
                                createdAt: Date(), updatedAt: Date(), folderPath: temp.url.path)
    let text = AgentInstructions.developer(for: record, limits: limits)
    #expect(text.contains("about 120 tool steps") && text.contains("2 minutes") && text.contains("read state.md"))
}

@Test func theLedgerSurvivesCompaction() async throws {
    // The job approves a command, the user answers a question, a file is written and an app tool sends a message;
    // then Codex compacts. The agent is handed all four right after, state.md has them, and the run still finishes.
    let rig = ScriptedRig { session in
        await session.emit(.approvalRequested(AgentApprovalRequest(id: "a1", kind: .command, summary: "Run curl -X POST https://api.example.com/rsvp")))
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "RSVP to the dinner", title: "RSVP"), waitForStart: true)
    let id = result.record.id
    #expect(await agentEventually { await rig.manager.job(id)?.pendingRequest?.id == "a1" })
    try await rig.manager.answer(id, requestID: "a1", decision: .approve(always: false))
    let session = try #require(rig.harness.sessions.first)
    await session.emit(.approvalRequested(AgentApprovalRequest(id: "q1", kind: .question, summary: "Which dietary note should I add?")))
    #expect(await agentEventually { await rig.manager.job(id)?.pendingRequest?.id == "q1" })
    try await rig.manager.answer(id, requestID: "q1", decision: .answer("Vegetarian"))
    await session.emit(.fileChanged(path: result.record.folder.appendingPathComponent("output/rsvp.md").path, change: "created"))
    await session.emit(.progress("Using gmail: send_email"))
    await session.emit(.compacted)
    #expect(await agentEventually { await session.sent.count == 1 })
    let note = try #require(await session.sent.first)
    #expect(note.contains("compacted"))
    #expect(note.contains("With the user's yes: Run curl -X POST https://api.example.com/rsvp"))
    #expect(note.contains("Called gmail: send_email"))
    #expect(note.contains("Vegetarian"))
    #expect(note.contains("output/rsvp.md (created)"))
    let state = try String(contentsOf: result.record.folder.appendingPathComponent("state.md"), encoding: .utf8)
    #expect(state.contains("Called gmail: send_email") && state.contains("Vegetarian") && state.contains("output/rsvp.md"))

    await session.finish(reportText)
    let report = try #require(await nextAgentReport(updates, for: id))
    #expect(report.outcome == .done)
    #expect(report.spoken == "I found three flights.")
    let record = try #require(await rig.manager.job(id))
    #expect(record.ledger?.compactions == 1)
    #expect(record.runs.count == 1)
}

@Test func theLedgerFileCapForgetsTheLeastRecentlyTouchedFile() throws {
    var ledger = AgentJobLedger()
    for page in 1...AgentJobLedger.maxFiles { ledger.touch(String(format: "/job/output/page-%02d.png", page), change: "created") }
    // Touched again, so no longer the oldest.
    ledger.touch("/job/output/page-01.png", change: "changed")
    // Sorts before every other path, and is the one the agent just made.
    ledger.touch("/job/output/a-summary.md", change: "created")
    #expect(ledger.files.count == AgentJobLedger.maxFiles)
    #expect(ledger.files["/job/output/a-summary.md"] == "created")
    #expect(ledger.files["/job/output/page-01.png"] == "created")
    #expect(ledger.files["/job/output/page-02.png"] == nil)
    #expect(ledger.markdown(folder: URL(fileURLWithPath: "/job")).contains("output/a-summary.md (created)"))
    // The order survives a save, and a ledger saved before the order was kept still loads.
    let decoded = try JSONDecoder().decode(AgentJobLedger.self, from: JSONEncoder().encode(ledger))
    #expect(decoded == ledger)
    let old = try JSONDecoder().decode(AgentJobLedger.self, from: Data(#"{"sideEffects":[],"answers":[],"files":{"/b":"created","/a":"changed"},"compactions":2}"#.utf8))
    #expect(old.files == ["/a": "changed", "/b": "created"])
    #expect(old.fileOrder == ["/a", "/b"])
    #expect(old.compactions == 2)
}

@Test func onlyApprovalsThatChangeThingsCountAsSideEffects() {
    func command(_ text: String) -> AgentApprovalRequest { AgentApprovalRequest(id: "1", kind: .command, summary: "Run " + text) }
    #expect(AgentJobLedger.approvalIsSideEffect(command("curl -X POST https://api.example.com/rsvp")))
    #expect(AgentJobLedger.approvalIsSideEffect(command("rm -rf ~/Desktop/old")))
    #expect(AgentJobLedger.approvalIsSideEffect(command("git push origin main")))
    #expect(!AgentJobLedger.approvalIsSideEffect(command("ls -la /tmp/vault | head -50")))
    #expect(!AgentJobLedger.approvalIsSideEffect(command("curl -s https://example.com")))
    #expect(AgentJobLedger.approvalIsSideEffect(AgentApprovalRequest(id: "2", kind: .tool, summary: "Write /Users/me/Vault/Note.md")))
    #expect(!AgentJobLedger.approvalIsSideEffect(AgentApprovalRequest(id: "3", kind: .tool, summary: "Use Browser")))
    #expect(AgentJobLedger.approvalIsSideEffect(AgentApprovalRequest(id: "4", kind: .fileChange, summary: "Change files in /Users/me")))
}

@Test func claudeCodeIsNotSteeredAfterCompactionButItsStateIsWritten() async throws {
    let rig = ScriptedRig(kind: .claudeCode) { session in
        await session.emit(.fileChanged(path: "/tmp/elsewhere/notes.md", change: "changed"))
        await session.emit(.compacted)
        await session.finish(reportText)
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Notes", title: "Notes"), waitForStart: true)
    _ = try #require(await nextAgentReport(updates, for: result.record.id))
    #expect(await rig.harness.sessions.first?.sent.isEmpty == true)
    let state = try String(contentsOf: result.record.folder.appendingPathComponent("state.md"), encoding: .utf8)
    #expect(state.contains("/tmp/elsewhere/notes.md (changed)"))
    #expect(await rig.manager.job(result.record.id)?.runs.count == 1)
}

@Test func compactionEventsComeFromBothHarnessesOnceEach() {
    var codex = CodexEventNormalizer(folder: URL(fileURLWithPath: "/tmp/job"))
    let item: JSONValue = ["item": ["type": "contextCompaction", "id": "c1"]]
    #expect(codex.notification(method: "item/completed", params: item) == [.compacted])
    #expect(codex.notification(method: "thread/compacted", params: ["threadId": "t"]).isEmpty)
    #expect(codex.notification(method: "thread/compacted", params: ["threadId": "t"]) == [.compacted])
    #expect(codex.notification(method: "item/completed", params: item).isEmpty)
    var claude = ClaudeEventNormalizer(folder: URL(fileURLWithPath: "/tmp/job"))
    #expect(claude.message(["type": "system", "subtype": "compact_boundary"]) == [.compacted])
    // The log round-trips the new event.
    #expect(AgentLogEntry(.compacted, at: Date()).event == .compacted)
}

@Test func anUnansweredQuestionIsAssumedAndSaidSo() async throws {
    var limits = AgentLimits()
    limits.assumeAfterSeconds = 0.3
    let rig = ScriptedRig(limits: limits) { session in
        await session.finish("Drafted the email.\n<report>\nsay: The draft is ready.\nquestion: Should it go to Sam or Alex?\n</report>")
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Draft the invite", title: "Invite"), waitForStart: true)
    let first = try #require(await nextAgentReport(updates, for: result.record.id))
    #expect(first.outcome == .needsYou)
    // Nobody answers: the job is told to carry on with an assumption, once.
    #expect(await agentEventually { rig.harness.launches.count == 2 })
    let message = try #require(rig.harness.launches.last?.message)
    #expect(message.contains("Should it go to Sam or Alex?") && message.contains("say plainly what you assumed"))
    #expect(message.contains("Don't send, post, buy, delete"))
    let record = try #require(await rig.manager.job(result.record.id))
    #expect(record.runs.last?.trigger == AgentRun.assumeTrigger)
    // It asked again: no second assumption.
    _ = await nextAgentReport(updates, for: result.record.id)
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(rig.harness.launches.count == 2)
}

@Test func answeringBeforeTheDeadlineCancelsTheAssumption() async throws {
    var limits = AgentLimits()
    limits.assumeAfterSeconds = 0.4
    let runs = TestCounter()
    let rig = ScriptedRig(limits: limits) { session in
        // Only the first run asks; the answered one finishes.
        await session.finish(runs.next() == 1 ? "<report>\nsay: Ready.\nquestion: Which day?\n</report>" : "<report>\nsay: Planned for Tuesday.\n</report>")
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Plan it", title: "Plan"), waitForStart: true)
    _ = await nextAgentReport(updates, for: result.record.id)
    try await rig.manager.answer(result.record.id, decision: .answer("Tuesday"))
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(rig.harness.launches.count == 2)
    #expect(rig.harness.launches.last?.message.contains("Tuesday") == true)
    var ledger = try #require(await rig.manager.job(result.record.id)?.ledger)
    #expect(ledger.answers.map(\.text) == ["Answered \"Which day?\": Tuesday"])
    // A follow-up the user sends is kept too, and survives the run it starts.
    _ = await nextAgentReport(updates, for: result.record.id)
    try await rig.manager.send(to: result.record.id, message: "Make it a lunch instead")
    _ = await nextAgentReport(updates, for: result.record.id)
    ledger = try #require(await rig.manager.job(result.record.id)?.ledger)
    #expect(ledger.answers.map(\.text) == ["Answered \"Which day?\": Tuesday", "Follow-up: Make it a lunch instead"])
}

@Test func maintenanceEndsIdleWaitsAndCleansOldJobsItOwns() async throws {
    let clock = AgentTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let rig = ScriptedRig(now: { clock.now }) { session in
        await session.finish("<report>\nsay: Ready.\nquestion: Which day?\n</report>")
    }
    let store = rig.manager.store
    let updates = await rig.manager.subscribe()
    // A job waiting on the user.
    let waiting = try await rig.manager.spawn(AgentSpawnRequest(task: "Plan the trip", title: "Trip"), waitForStart: true)
    _ = await nextAgentReport(updates, for: waiting.record.id)
    #expect(await agentEventually { await !rig.manager.isRunning(waiting.record.id) })
    // An old finished job with scratch, a log and task screenshots, and one in a folder it doesn't own.
    var old = try store.createJob(task: "Old work", title: "Old", harness: .codex, model: nil, provider: "x", now: clock.now)
    old.status = .done
    try store.save(old)
    try "scratch".write(to: old.folder.appendingPathComponent("tmp/scratch.txt"), atomically: true, encoding: .utf8)
    try "keep".write(to: old.outputFolder.appendingPathComponent("result.md"), atomically: true, encoding: .utf8)
    store.append(.log("hello"), to: old)
    _ = try AgentTaskAssets.save(screenshots: [Data([0xFF, 0xD8])], images: [], paths: store.paths, jobID: old.id, run: 1)
    var foreign = try store.createJob(task: "Foreign", title: "Foreign", harness: .codex, model: nil, provider: "x", now: clock.now)
    foreign.status = .done
    try store.save(foreign)
    try FileManager.default.removeItem(at: AgentFolderOwnership.markerURL(in: foreign.folder))
    try "scratch".write(to: foreign.folder.appendingPathComponent("tmp/scratch.txt"), atomically: true, encoding: .utf8)
    #expect(AgentFolderOwnership.owns(old.folder, jobID: old.id))
    #expect(!AgentFolderOwnership.owns(foreign.folder, jobID: foreign.id))

    var limits = AgentLimits()
    limits.assumeAfterSeconds = 0
    // Nothing is due yet.
    var result = await rig.manager.maintain(limits: limits)
    #expect(result == AgentManager.MaintenanceResult())

    clock.advance(31 * 86_400)
    result = await rig.manager.maintain(limits: limits)
    #expect(result.ended == [waiting.record.id])
    #expect(Set(result.cleaned) == [old.id, foreign.id])
    let ended = try #require(await rig.manager.job(waiting.record.id))
    #expect(ended.status == .done)
    #expect(ended.lastProgress?.hasPrefix("Ended: no answer after 6 hours") == true)
    // The cleanup keeps deliverables and the record and leaves a folder it doesn't own alone.
    #expect(!FileManager.default.fileExists(atPath: old.folder.appendingPathComponent("tmp/scratch.txt").path))
    #expect(!FileManager.default.fileExists(atPath: old.folder.appendingPathComponent("events.jsonl").path))
    #expect(!FileManager.default.fileExists(atPath: store.paths.taskAssets.appendingPathComponent(old.id).path))
    #expect(FileManager.default.fileExists(atPath: old.outputFolder.appendingPathComponent("result.md").path))
    #expect(FileManager.default.fileExists(atPath: foreign.folder.appendingPathComponent("tmp/scratch.txt").path))
    // Sweeps don't reorder the list, and a cleaned job isn't cleaned again.
    #expect(store.load(id: old.id)?.updatedAt == old.updatedAt)
    #expect(store.load(id: old.id)?.cleanedAt != nil)
    // The next sweep cleans only the job it just ended (idle for a month too), never the cleaned ones again.
    #expect(await rig.manager.maintain(limits: limits).cleaned == [waiting.record.id])
    #expect(await rig.manager.maintain(limits: limits) == AgentManager.MaintenanceResult())
}

@Test func keptAgentsInUseLoseOldScreenshotsAndResumedJobsAreCleanedAgain() async throws {
    let clock = AgentTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let rig = ScriptedRig(now: { clock.now }) { session in await session.finish("<report>\nsay: Done.\n</report>") }
    let store = rig.manager.store
    let manager = FileManager.default
    // A kept agent used yesterday (so never idle for 30 days), with screenshots from a run 40 days ago and from yesterday.
    var agent = try store.keptAgent(named: "Scribe", role: nil, harness: .codex, model: nil, provider: "x", now: clock.now)
    agent.status = .done
    agent.updatedAt = clock.now.addingTimeInterval(-86_400)
    agent.cleanedAt = clock.now.addingTimeInterval(-100 * 86_400)
    try store.save(agent)
    for run in 1...2 { _ = try AgentTaskAssets.save(screenshots: [Data([0xFF, 0xD8])], images: [], paths: store.paths, jobID: agent.id, run: run) }
    let oldRun = AgentTaskAssets.folder(paths: store.paths, jobID: agent.id, run: 1)
    let newRun = AgentTaskAssets.folder(paths: store.paths, jobID: agent.id, run: 2)
    try manager.setAttributes([.modificationDate: clock.now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: oldRun.path)
    try manager.setAttributes([.modificationDate: clock.now.addingTimeInterval(-86_400)], ofItemAtPath: newRun.path)
    var limits = AgentLimits()
    limits.assumeAfterSeconds = 0
    #expect(await rig.manager.maintain(limits: limits).cleaned == [agent.id])
    #expect(!manager.fileExists(atPath: oldRun.path))
    #expect(manager.fileExists(atPath: newRun.path))
    #expect(store.load(id: agent.id)?.updatedAt == agent.updatedAt)

    // A one-off job cleaned once and then picked up again is cleaned again after its new run goes idle.
    var job = try store.createJob(task: "Old work", title: "Old", harness: .codex, model: nil, provider: "x", now: clock.now)
    job.status = .done
    job.cleanedAt = clock.now
    try store.save(job)
    let updates = await rig.manager.subscribe()
    try await rig.manager.send(to: job.id, message: "One more thing", waitForStart: true)
    _ = await nextAgentReport(updates, for: job.id)
    #expect(await agentEventually { await !rig.manager.isRunning(job.id) })
    #expect(await rig.manager.job(job.id)?.cleanedAt == nil)
    clock.advance(31 * 86_400)
    #expect(await rig.manager.maintain(limits: limits).cleaned.contains(job.id))
}

@Test func aQuestionLeftWhileOpenClickyWasClosedIsAssumedBySweep() async throws {
    let clock = AgentTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let rig = ScriptedRig(now: { clock.now }) { session in
        await session.finish("<report>\nsay: Ready.\nquestion: Which day?\n</report>")
    }
    var record = try rig.manager.store.createJob(task: "Plan", title: "Plan", harness: .codex, model: nil, provider: "harness-login", now: clock.now)
    record.status = .needsYou
    record.report = AgentFinalReport(markdown: "", spoken: "Ready.", question: "Which day?")
    record.runs = [AgentRun(ask: "Plan", startedAt: clock.now)]
    record.runs[0].finishedAt = clock.now
    try rig.manager.store.save(record)
    clock.advance(45 * 60)
    // OpenClicky starts again: the recovery at launch leaves a finished report's question waiting.
    await rig.manager.recoverInterruptedJobs()
    #expect(await rig.manager.job(record.id)?.status == .needsYou)
    let result = await rig.manager.maintain(limits: AgentLimits())
    #expect(result.assumed == [record.id])
    #expect(await agentEventually { rig.harness.launches.count == 1 })
    #expect(rig.harness.launches.first?.message.contains("Which day?") == true)
}

@Test func finishedRunsGetADeliverableKind() async throws {
    #expect(AgentDeliverableKind.classify(files: ["/x/output/report.pdf", "/x/a.csv"], reportLength: 10) == .pdf)
    #expect(AgentDeliverableKind.classify(files: ["https://example.com/page"], reportLength: 10) == .page)
    #expect(AgentDeliverableKind.classify(files: ["/x/data.xlsx"], reportLength: 10) == .sheet)
    #expect(AgentDeliverableKind.classify(files: [], reportLength: 900) == .research)
    #expect(AgentDeliverableKind.classify(files: [], reportLength: 20) == .message)
    let rig = ScriptedRig { session in await session.finish(reportText) }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Flights", title: "Flights"), waitForStart: true)
    let report = try #require(await nextAgentReport(updates, for: result.record.id))
    #expect(report.kind == .document)
    #expect(report.json["kind"] == "document")
}

@Test func limitsDecodePartially() throws {
    let limits = try JSONDecoder().decode(AgentLimits.self, from: Data(#"{"maxStepsPerRun": 40, "cleanupAfterDays": 7}"#.utf8))
    #expect(limits.maxStepsPerRun == 40 && limits.cleanupAfterDays == 7)
    #expect(limits.maxRunSeconds == 1800 && limits.commandTimeoutSeconds == 300 && limits.compactionTokens == 160_000)
    var config = OpenClickyConfig.heyClickyLike
    config.agentLimits = limits
    let settings = try AgentLaunchSettings.fromConfig(config, credentials: InMemoryCredentialStore(["openai": "sk"]))
    #expect(settings.limits.maxStepsPerRun == 40)
}

final class AgentTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
