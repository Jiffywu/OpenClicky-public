import Foundation
import Testing
@testable import OpenClickyKit

private let secret = "sk-manager-SECRET-5d1e"

/// A manager whose harnesses are the fake executables, with a bring-your-own-key provider so the key's path to the
/// harness is exercised.
private struct Rig {
    let temp = AgentTempDir()
    let log: URL
    let manager: AgentManager
    let codex: URL
    let claude: URL

    init(scenario: String, harness: HarnessKind = .codex, executable: URL? = nil, approvalTimeout: TimeInterval = 1800,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        log = temp.url.appendingPathComponent("harness.log")
        codex = try temp.script("codex", FakeHarnessScripts.codex)
        claude = try temp.script("claude", FakeHarnessScripts.claude)
        let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": scenario, "FAKE_LOG": log.path,
                           "OPENCLICKY_KEY_OPENAI": secret, "CLAUDECODE": "1"]
        let fakes = [HarnessKind.codex: codex, .claudeCode: claude]
        manager = AgentManager(store: AgentJobStore(paths: temp.paths), now: now, approvalTimeout: approvalTimeout) { [executable] preference in
            let kind = preference.harness ?? harness
            let provider = kind == .codex
                ? ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai")
                : ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")
            return AgentLaunchSettings(harness: kind, model: "test-model", providerID: preference.login ? "harness-login" : provider.id,
                                       auth: preference.login ? .harnessLogin : .provider(provider, apiKey: secret),
                                       executable: executable ?? fakes[kind], baseEnvironment: environment)
        }
    }

    var sent: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
}

/// Waits for the next report for `jobID` on a subscription.
private func nextReport(_ updates: AsyncStream<AgentManagerUpdate>, for jobID: String? = nil, timeout: Double = 15) async -> AgentJobReport? {
    await withTaskGroup(of: AgentJobReport?.self) { group in
        group.addTask {
            for await update in updates {
                if case .report(let report) = update, jobID == nil || report.jobID == jobID { return report }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Test func aJobRunsToAReportWithItsFolderLogAndIndex() async throws {
    let rig = try Rig(scenario: "quick")
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Write meeting notes from today's call", title: "Meeting notes"), waitForStart: true)
    #expect(!result.alreadyStarted)
    let report = try #require(await nextReport(updates, for: result.record.id))

    #expect(report.outcome == .done)
    #expect(report.spoken == "Your notes are ready.")
    #expect(report.title == "Meeting Notes")
    #expect(report.files == [result.record.folder.appendingPathComponent("output/notes.md").standardizedFileURL.path])
    #expect(report.run == 1)

    let record = try #require(await rig.manager.job(result.record.id))
    #expect(record.status == .done)
    #expect(record.threadID == "thread-1")
    #expect(record.runs.count == 1 && record.runs[0].outcome == .completed && record.runs[0].spoken == "Your notes are ready.")
    #expect(record.usage == AgentTokenUsage(input: 120, cachedInput: 20, output: 30))
    #expect(record.report?.files == ["output/notes.md"])
    #expect(await agentEventually { await !rig.manager.isRunning(record.id) })

    let kinds = rig.manager.store.events(of: record).map(\.kind)
    #expect(kinds.contains("session") && kinds.contains("plan") && kinds.contains("file") && kinds.last == "turn_finished")
    let index = try String(contentsOf: rig.temp.paths.projects.appendingPathComponent("WORK.md"), encoding: .utf8)
    #expect(index.contains("jobs/\(record.id)/ · Your notes are ready."))
    #expect(FileManager.default.fileExists(atPath: record.folder.appendingPathComponent("report.md").path))

    // The brief carries the task; the developer instructions carry OpenClicky's job rules and report format.
    #expect(rig.sent.contains("Task from the user:\\nWrite meeting notes from today's call"))
    #expect(rig.sent.contains("<report>"))
    #expect(rig.temp.filesContaining(secret).isEmpty)
}

@Test func aFollowUpAfterTheRunResumesTheSameConversation() async throws {
    let rig = try Rig(scenario: "quick")
    let updates = await rig.manager.subscribe()
    let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Write meeting notes"), waitForStart: true).record
    _ = await nextReport(updates, for: job.id)
    #expect(await agentEventually { await !rig.manager.isRunning(job.id) })

    let (record, disposition) = try await rig.manager.send(to: job.id, message: "Add a summary at the top", waitForStart: true)
    #expect(disposition == .startedTurn)
    #expect(record.runs.count == 2)
    let second = try #require(await nextReport(updates, for: job.id))
    #expect(second.run == 2)
    #expect(rig.sent.contains(#""method":"thread/resume""#))
    #expect(rig.sent.contains("Follow-up from the user:\\nAdd a summary at the top"))
    #expect(rig.temp.filesContaining(secret).isEmpty)
}

@Test func keptAgentsTakeLaterTasksInTheirOwnFolder() async throws {
    let rig = try Rig(scenario: "quick", harness: .claudeCode)
    let updates = await rig.manager.subscribe()
    let first = try await rig.manager.spawn(AgentSpawnRequest(task: "Track my reading list", agent: "Research Buddy", agentRole: "librarian", keep: true),
                                            waitForStart: true).record
    #expect(first.id == "research-buddy" && first.isKept)
    _ = try #require(await nextReport(updates, for: first.id))
    #expect(await agentEventually { await !rig.manager.isRunning(first.id) })

    let second = try await rig.manager.spawn(AgentSpawnRequest(task: "Add the new Ishiguro novel", agent: "research buddy"), waitForStart: true).record
    #expect(second.id == first.id)
    #expect(second.folderPath == first.folderPath)
    let report = try #require(await nextReport(updates, for: first.id))
    #expect(report.agentName == "Research Buddy")
    #expect(report.run == 2)
    #expect(rig.sent.contains("[--resume] [sess-1]"))
    #expect(rig.sent.contains("Being a kept agent"))
    #expect(await rig.manager.jobs().filter(\.isKept).count == 1)

    // Unknown kept agents aren't created without keep.
    await #expect(throws: AgentManagerError.unknownJob("Nobody")) {
        try await rig.manager.spawn(AgentSpawnRequest(task: "x", agent: "Nobody"))
    }
}

@Test func approvalsWaitForTheUserAndAnswersReachTheHarness() async throws {
    let rig = try Rig(scenario: "approve")
    let updates = await rig.manager.subscribe()
    let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Fetch the page"), waitForStart: true).record
    #expect(await agentEventually { await rig.manager.job(job.id)?.status == .needsYou })
    let waiting = try #require(await rig.manager.job(job.id))
    #expect(waiting.pendingRequest?.summary == "Run mkdir -p output")
    #expect(waiting.lastProgress == "Needs a yes: Run mkdir -p output")

    let tools = AgentTools(manager: rig.manager)
    let status = await tools.callJSON(name: "session_status", arguments: "{}")
    #expect(status["active"]?.arrayValue?.first?["pending_request"]?["asks"]?.stringValue == "Run mkdir -p output")
    let answer = await tools.callJSON(name: "sessions_answer_request", arguments: #"{"job_id":"\#(job.id)","decision":"approve"}"#)
    #expect(answer["status"]?.stringValue == "answered")
    let report = try #require(await nextReport(updates, for: job.id))
    #expect(report.outcome == .done)
    #expect(rig.sent.contains(#""decision":"accept""#))
    #expect(await rig.manager.job(job.id)?.pendingRequest == nil)
}

@Test func interruptStopsTheJobAndReportsItStopped() async throws {
    let rig = try Rig(scenario: "wait", harness: .claudeCode)
    let updates = await rig.manager.subscribe()
    let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Write meeting notes"), waitForStart: true).record
    #expect(await agentEventually { await rig.manager.job(job.id)?.lastProgress == "Writing notes.md" })
    #expect(await rig.manager.interrupt(job.id))
    let report = try #require(await nextReport(updates, for: job.id))
    #expect(report.outcome == .stopped)
    #expect(await rig.manager.job(job.id)?.status == .stopped)
    #expect(await rig.manager.job(job.id)?.runs.last?.outcome == .interrupted)
    #expect(await !rig.manager.interrupt("no-such-job"))
}

@Test func aHarnessThatCantStartFailsTheJobWithAReport() async throws {
    let rig = try Rig(scenario: "quick", executable: URL(fileURLWithPath: "/nonexistent/codex"))
    let updates = await rig.manager.subscribe()
    await #expect(throws: AgentHarnessError.executableNotFound(.codex)) {
        try await rig.manager.spawn(AgentSpawnRequest(task: "Anything"), waitForStart: true)
    }
    let report = try #require(await nextReport(updates))
    #expect(report.outcome == .failed)
    #expect(report.spoken.contains("didn't work out"))
    #expect(report.error?.contains("Couldn't find the codex command") == true)
    #expect(await rig.manager.job(report.jobID)?.status == .failed)
}

@Test func theSameTaskTwiceInARowStartsOnce() async throws {
    let rig = try Rig(scenario: "wait")
    let first = try await rig.manager.spawn(AgentSpawnRequest(task: "Summarize my inbox"), waitForStart: true)
    let second = try await rig.manager.spawn(AgentSpawnRequest(task: "  summarize my inbox "))
    #expect(second.alreadyStarted)
    #expect(second.record.id == first.record.id)
    await #expect(throws: AgentManagerError.emptyTask) { try await rig.manager.spawn(AgentSpawnRequest(task: "   ")) }
    await rig.manager.shutdown()
}

@Test func jobsLeftRunningByAQuitAreMarkedStopped() async throws {
    let rig = try Rig(scenario: "quick")
    var record = try rig.manager.store.createJob(task: "Long job", title: nil, harness: .codex, model: nil, provider: "openai")
    record.status = .running
    record.runs = [AgentRun(ask: "Long job", startedAt: Date())]
    try rig.manager.store.save(record)
    await rig.manager.recoverInterruptedJobs()
    let recovered = try #require(await rig.manager.job(record.id))
    #expect(recovered.status == .stopped)
    #expect(recovered.runs.last?.outcome == .interrupted)
    // A job that was waiting on a live approval had a harness open: it was cut off too.
    var approving = try rig.manager.store.createJob(task: "Approving job", title: nil, harness: .codex, model: nil, provider: "openai")
    approving.status = .needsYou
    approving.pendingRequest = AgentApprovalRequest(id: "a1", kind: .command, summary: "Run ls")
    approving.report = AgentFinalReport(markdown: "", spoken: "Earlier.", question: "Earlier question?")
    approving.runs = [AgentRun(ask: "Approving job", startedAt: Date())]
    try rig.manager.store.save(approving)
    await rig.manager.recoverInterruptedJobs()
    #expect(await rig.manager.job(approving.id)?.status == .stopped)
    // The next run in that folder is told the last one was cut off (kept agents) or given the earlier task.
    let brief = AgentInstructions.brief(task: "Again", record: recovered, interruptedBefore: true)
    #expect(brief.contains("stopped before it finished"))
}

@Test func secretsNeverReachDiskAcrossAWholeJobInEitherHarness() async throws {
    for harness in HarnessKind.allCases {
        let rig = try Rig(scenario: "quick", harness: harness)
        let updates = await rig.manager.subscribe()
        let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Write meeting notes"), waitForStart: true).record
        _ = await nextReport(updates, for: job.id)
        _ = try await rig.manager.send(to: job.id, message: "And a summary", waitForStart: true)
        _ = await nextReport(updates, for: job.id)
        #expect(rig.temp.filesContaining(secret).isEmpty, "\(harness)")
        #expect(!rig.sent.contains(secret), "\(harness): the key appeared in the harness's arguments or input")
    }
}

@Test func anUnansweredApprovalIsDeclinedAfterTheTimeout() async throws {
    let rig = try Rig(scenario: "approve", approvalTimeout: 0.3)
    let updates = await rig.manager.subscribe()
    let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Fetch the page"), waitForStart: true).record
    let report = try #require(await nextReport(updates, for: job.id))
    #expect(report.outcome == .done)
    #expect(rig.sent.contains(#""decision":"decline""#))
    let log = rig.manager.store.events(of: try #require(await rig.manager.job(job.id))).compactMap(\.text)
    #expect(log.contains { $0.hasPrefix("No answer to \"Run mkdir -p output\"") && $0.hasSuffix("declined.") })
}

@Test func parallelApprovalsFaceTheUserOneAtATime() async throws {
    let rig = try Rig(scenario: "approve2")
    let updates = await rig.manager.subscribe()
    let job = try await rig.manager.spawn(AgentSpawnRequest(task: "Clean up and write notes"), waitForStart: true).record
    #expect(await agentEventually { await rig.manager.job(job.id)?.pendingRequest?.id == "0" })
    try await rig.manager.answer(job.id, decision: .approve(always: false))
    #expect(await agentEventually { await rig.manager.job(job.id)?.pendingRequest?.id == "1" })
    let second = try #require(await rig.manager.job(job.id))
    #expect(second.status == .needsYou)
    #expect(second.pendingRequest?.summary == "Run rm -rf tmp/cache")
    try await rig.manager.answer(job.id, decision: .decline)
    let report = try #require(await nextReport(updates, for: job.id))
    #expect(report.outcome == .done)
    let decisions = rig.sent.split(separator: "\n").filter { $0.hasPrefix("decision: ") }
    #expect(decisions.count == 2)
    #expect(decisions.first?.contains(#""id":0"#) == true && decisions.first?.contains("accept") == true)
    #expect(decisions.last?.contains(#""id":1"#) == true && decisions.last?.contains("decline") == true)
}
