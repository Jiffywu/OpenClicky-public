import Foundation
import Testing
@testable import OpenClickyKit

// The manager's side of the Wave 4 agent work: a harness that dies mid-turn is restarted once and resumed; WAIT_FOR
// and ROUTINE blocks put a job in needs-you and are answered (also after a relaunch); seen and archived flags.

/// A harness whose sessions each run their own script, in order (the last one repeats).
private final class SequencedHarness: AgentHarness, @unchecked Sendable {
    let kind: HarnessKind
    private let lock = NSLock()
    private var scripts: [@Sendable (ScriptedSession) async -> Void]
    private var _launches: [(launch: HarnessLaunch, message: String)] = []

    init(kind: HarnessKind = .codex, scripts: [@Sendable (ScriptedSession) async -> Void]) {
        self.kind = kind
        self.scripts = scripts
    }

    var launches: [(launch: HarnessLaunch, message: String)] { lock.withLock { _launches } }

    func start(_ launch: HarnessLaunch, message: String, images: [URL]) async throws -> any AgentHarnessSession {
        let session = ScriptedSession(steerable: kind == .codex)
        let script: @Sendable (ScriptedSession) async -> Void = lock.withLock {
            _launches.append((launch, message))
            return scripts.count > 1 ? scripts.removeFirst() : scripts[0]
        }
        Task {
            await session.emit(.sessionStarted(threadID: "thread-7"))
            await session.emit(.turnStarted)
            await script(session)
        }
        return session
    }
}

/// The process died mid-turn: the harness reports the exit and its event stream ends.
private func crash(_ session: ScriptedSession, status: Int) async {
    await session.emit(.progress("Running: npm test"))
    await session.emit(.turnFinished(.failed, finalText: nil, error: "Codex stopped (exit \(status)): Segmentation fault"))
    await session.close()
}

private func manager(_ temp: AgentTempDir, _ harness: any AgentHarness, kind: HarnessKind = .codex) -> AgentManager {
    AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness]) { _ in
        AgentLaunchSettings(harness: kind, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin,
                            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
    }
}

@Suite struct AgentCrashResumeTests {
    @Test func oneCrashMidTurnRestartsTheHarnessResumesAndFinishes() async throws {
        let temp = AgentTempDir()
        let harness = SequencedHarness(scripts: [
            { session in await crash(session, status: 139) },
            { session in await session.finish(reportText) },
        ])
        let manager = manager(temp, harness)
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Find flights", title: "Flights"), waitForStart: true)
        let report = try #require(await nextAgentReport(updates, for: result.record.id))
        #expect(report.outcome == .done)
        #expect(report.spoken == "I found three flights.")

        #expect(harness.launches.count == 2)
        let resumed = harness.launches[1]
        #expect(resumed.launch.resumeThreadID == "thread-7")
        #expect(resumed.message.contains("You were interrupted"))
        #expect(resumed.message.contains("state.md"))
        let record = try #require(await manager.job(result.record.id))
        #expect(record.status == .done)
        #expect(record.runs.count == 1)
        #expect(record.runs[0].harnessExits == ["Codex stopped (exit 139): Segmentation fault"])
        let logs = manager.store.events(of: record).filter { $0.kind == "log" }.compactMap(\.text)
        #expect(logs.contains { $0.contains("restarting it once") })
    }

    @Test func aSecondCrashFailsTheRunWithBothExitsRecorded() async throws {
        let temp = AgentTempDir()
        let harness = SequencedHarness(scripts: [
            { session in await crash(session, status: 139) },
            { session in await crash(session, status: 9) },
            { session in await session.finish(reportText) },
        ])
        let manager = manager(temp, harness)
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Find flights", title: "Flights"), waitForStart: true)
        let report = try #require(await nextAgentReport(updates, for: result.record.id))
        #expect(report.outcome == .failed)
        #expect(harness.launches.count == 2)
        let record = try #require(await manager.job(result.record.id))
        #expect(record.status == .failed)
        #expect(record.runs[0].harnessExits == ["Codex stopped (exit 139): Segmentation fault", "Codex stopped (exit 9): Segmentation fault"])
        #expect(record.error == "The agent stopped twice mid-task: Codex stopped (exit 139): Segmentation fault; then Codex stopped (exit 9): Segmentation fault")

        // The next run gets its own restart again.
        _ = try await manager.send(to: record.id, message: "Try again")
        #expect(await agentEventually { await manager.job(record.id)?.status == .done })
        #expect(harness.launches.count == 3)
    }

    @Test func aTurnTheModelFailedIsNotRetried() async throws {
        let temp = AgentTempDir()
        let harness = SequencedHarness(scripts: [{ session in
            await session.emit(.turnFinished(.failed, finalText: nil, error: "The model refused: rate limited"))
        }])
        let manager = manager(temp, harness)
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Find flights"), waitForStart: true)
        let report = try #require(await nextAgentReport(updates, for: result.record.id))
        #expect(report.outcome == .failed)
        #expect(harness.launches.count == 1)
        #expect(AgentHarnessExit.isExit("Claude Code stopped (exit 1): boom"))
        #expect(!AgentHarnessExit.isExit("The agent stopped unexpectedly."))
    }
}

@Suite struct AgentUserStepTests {
    static let waitText = """
    Filled in the form; it needs your sign-in.
    <report>
    say: I need you to sign in to the portal.
    </report>
    <wait_for>{"step": "Sign in to the expenses portal", "page": "https://expenses.example.com"}</wait_for>
    """

    @Test func aWaitForJobSurvivesARelaunchAndContinuesWhenTheUserIsDone() async throws {
        let temp = AgentTempDir()
        let first = SequencedHarness(scripts: [{ session in await session.finish(Self.waitText) }])
        let before = manager(temp, first)
        let updates = await before.subscribe()
        let result = try await before.spawn(AgentSpawnRequest(task: "File my expenses", title: "Expenses"), waitForStart: true)
        let report = try #require(await nextAgentReport(updates, for: result.record.id))
        #expect(report.outcome == .needsYou)
        #expect(report.userStep?.step == "Sign in to the expenses portal")
        #expect(report.json["user_step"]?["step"] == "Sign in to the expenses portal")
        #expect(AgentResultCard(report: report).userStep?.page == "https://expenses.example.com")
        let waiting = try #require(await before.job(result.record.id))
        #expect(waiting.status == .needsYou && waiting.waitingStep != nil)
        #expect(AgentBrainContext.note(jobs: [waiting], running: [])?.contains("to do a step: Sign in to the expenses portal") == true)
        await before.shutdown()

        // Relaunch: a new manager over the same folder keeps the job waiting.
        let second = SequencedHarness(scripts: [{ session in await session.finish(reportText) }])
        let after = manager(temp, second)
        await after.recoverInterruptedJobs()
        let recovered = try #require(await after.job(result.record.id))
        #expect(recovered.status == .needsYou)
        #expect(recovered.waitingStep?.step == "Sign in to the expenses portal")

        let afterUpdates = await after.subscribe()
        // "I'm done" from the card or the brain: an approval on the waiting job.
        #expect(try await after.answer(result.record.id, decision: .approve(always: false)) == .sentAsFollowUp)
        let next = try #require(await nextAgentReport(afterUpdates, for: result.record.id))
        #expect(next.outcome == .done)
        #expect(second.launches.first?.message.contains("finished the step you asked for: Sign in to the expenses portal") == true)
        let done = try #require(await after.job(result.record.id))
        #expect(done.runs.count == 2 && done.waitingStep == nil)
        #expect(done.ledger?.answers.contains { $0.text.contains("Did the step") } == true)
    }

    @Test func skippingTheStepEndsTheWait() async throws {
        let temp = AgentTempDir()
        let harness = SequencedHarness(scripts: [{ session in await session.finish(Self.waitText) }])
        let manager = manager(temp, harness)
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "File my expenses"), waitForStart: true)
        _ = await nextAgentReport(updates, for: result.record.id)
        #expect(try await manager.answer(result.record.id, decision: .decline) == .answered)
        let record = try #require(await manager.job(result.record.id))
        #expect(record.status == .done && record.waitingStep == nil)
        #expect(harness.launches.count == 1)
    }
}

@Suite struct AgentRoutineProposalTests {
    static let proposal = """
    Set up the check.
    <report>
    say: I can check prices every morning.
    </report>
    <routine>{"action": "create", "title": "Fare watch", "task": "Check SFO to DEN fares and report changes", "at": "08:00", "days": "weekdays"}</routine>
    """

    private func rig(_ temp: AgentTempDir) async -> (AgentCoordinator, SequencedHarness) {
        let harness = SequencedHarness(scripts: [{ session in await session.finish(Self.proposal) }, { session in await session.finish(reportText) }])
        let manager = manager(temp, harness)
        let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
        await coordinator.connectRoutines()
        return (coordinator, harness)
    }

    @Test func aRoutineBlockWaitsForTheUsersYesThenLandsInRoutinesJSON() async throws {
        let temp = AgentTempDir()
        let (coordinator, harness) = await rig(temp)
        let manager = coordinator.manager
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Watch fares", title: "Fares"), waitForStart: true)
        let report = try #require(await nextAgentReport(updates, for: result.record.id))
        #expect(report.outcome == .needsYou)
        #expect(report.routineProposals?.first?.title == "Fare watch")
        #expect(report.json["routine_proposal"] == "Create the routine \"Fare watch\", weekdays at 08:00")
        let waiting = try #require(await manager.job(result.record.id))
        let request = try #require(waiting.pendingRequest)
        #expect(request.id.hasPrefix("openclicky-routine-"))
        #expect(await coordinator.routines.list().isEmpty)

        // Survives a relaunch too.
        await manager.recoverInterruptedJobs()
        #expect(await manager.job(result.record.id)?.status == .needsYou)

        #expect(try await manager.answer(result.record.id, requestID: request.id, decision: .approve(always: false)) == .answered)
        let routines = RoutineStore(url: temp.paths.routines).load()
        #expect(routines.count == 1)
        #expect(routines.first?.title == "Fare watch")
        #expect(routines.first?.jobID == result.record.id)
        #expect(routines.first?.schedule == .daily(TimeOfDay(hour: 8, minute: 0), weekdays: [1, 2, 3, 4, 5]))
        let record = try #require(await manager.job(result.record.id))
        #expect(record.status == .done && record.pendingRoutines == nil && record.pendingRequest == nil)
        #expect(record.lastProgress?.hasPrefix("Created the routine \"Fare watch\"") == true)

        // The next launch's instructions list it as this folder's routine.
        _ = try await manager.send(to: record.id, message: "Thanks")
        #expect(await agentEventually {
            let current = await manager.job(record.id)
            return current?.status == .done && current?.runs.count == 2
        })
        let relaunch = try #require(harness.launches.last)
        #expect(relaunch.launch.instructions.contains("\"Fare watch\" [\(try #require(routines.first?.id))]"))
        #expect(relaunch.launch.instructions.contains("(runs in this folder)"))
    }

    @Test func noLeavesRoutinesAlone() async throws {
        let temp = AgentTempDir()
        let (coordinator, _) = await rig(temp)
        let manager = coordinator.manager
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Watch fares"), waitForStart: true)
        _ = await nextAgentReport(updates, for: result.record.id)
        #expect(try await manager.answer(result.record.id, decision: .decline) == .answered)
        #expect(RoutineStore(url: temp.paths.routines).load().isEmpty)
        #expect(await manager.job(result.record.id)?.status == .done)
    }

    @Test func changesFindTheRoutineByTitlePreferringTheJobsOwn() async throws {
        let temp = AgentTempDir()
        let routines = RoutineScheduler(store: RoutineStore(url: temp.paths.routines)) { _, _ in "job" }
        let mine = try await routines.create(title: "Digest", task: "a", schedule: .every(minutes: 60), jobID: "job-1")
        _ = try await routines.create(title: "Digest", task: "b", schedule: .every(minutes: 60), jobID: "job-2")
        let job = AgentJobRecord(id: "job-1", kind: .job, title: "J", task: "t", harness: .codex, model: nil, provider: "p", status: .done,
                                 createdAt: Date(), updatedAt: Date(), folderPath: "/tmp/job-1")
        let said = try await AgentCoordinator.apply(AgentRoutineRequest(action: .pause, title: "digest"), job: job, routines: routines)
        #expect(said == "Paused the routine \"Digest\"")
        #expect(await routines.list().first { $0.id == mine.id }?.isPaused == true)
        #expect(await routines.list().filter(\.isPaused).count == 1)
        await #expect(throws: RoutineError.self) {
            try await AgentCoordinator.apply(AgentRoutineRequest(action: .delete, title: "Nope"), job: job, routines: routines)
        }
    }
}

@Suite struct AgentListStateTests {
    @Test func seenDismissedAndArchivedFlagsRoundTripAndArchivedJobsLeaveTheList() async throws {
        let rig = ScriptedRig { session in await session.finish(reportText) }
        let updates = await rig.manager.subscribe()
        let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Find flights", title: "Flights"), waitForStart: true)
        _ = await nextAgentReport(updates, for: result.record.id)
        let id = result.record.id
        let store = rig.manager.store
        #expect(store.load(id: id)?.isUnseen == true)
        #expect(store.load(id: id)?.isDismissed == nil)

        await rig.manager.markSeen(id)
        #expect(store.load(id: id)?.isSeen == true)
        await rig.manager.setDismissed(id)
        #expect(store.load(id: id)?.isDismissed == true)
        let updatedAt = store.load(id: id)?.updatedAt
        await rig.manager.setArchived(id)
        let archived = try #require(store.load(id: id))
        #expect(archived.isArchived == true && !archived.isListed)
        #expect(archived.updatedAt == updatedAt)
        #expect(store.listed().isEmpty)
        #expect(store.listed(includeArchived: true).map(\.id) == [id])

        // A new run brings it back, unseen once it finishes.
        _ = try await rig.manager.send(to: id, message: "And hotels?")
        #expect(await agentEventually { store.load(id: id)?.runs.count == 2 && store.load(id: id)?.status == .done })
        let back = try #require(store.load(id: id))
        #expect(back.isListed && back.isUnseen && back.isDismissed == nil)
        #expect(store.listed().map(\.id) == [id])

        await rig.manager.setArchived(id, false)
        #expect(store.load(id: id)?.isArchived == false)
    }

    @Test func recordsFromBeforeTheFlagsCountAsSeenAndListed() throws {
        let json = #"{"id":"old","kind":"job","title":"Old","task":"t","harness":"codex","provider":"p","status":"done","createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z","runs":[],"usage":{"input":0,"cachedInput":0,"output":0},"folderPath":"/tmp/old"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(AgentJobRecord.self, from: Data(json.utf8))
        #expect(!record.isUnseen && record.isListed && record.waitingStep == nil)
    }
}

/// A report with both a <wait_for> step and a <routine> proposal: each is answered on its own. "I'm done" and "Skip"
/// (no request id) are about the step; the routines go by their confirmation's id, and wait for it across new turns.
@Suite struct AgentStepAndRoutineTests {
    static let both = """
    Filled in the form; it needs your sign-in.
    <report>
    say: Sign in, and I can check this every morning.
    </report>
    <wait_for>{"step": "Sign in to the expenses portal"}</wait_for>
    <routine>{"action": "create", "title": "Expense check", "task": "Check for new expenses", "at": "08:00"}</routine>
    """

    private func rig(_ temp: AgentTempDir, scripts: [@Sendable (ScriptedSession) async -> Void]) async -> (AgentCoordinator, SequencedHarness) {
        let harness = SequencedHarness(scripts: scripts)
        let manager = manager(temp, harness)
        let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
        await coordinator.connectRoutines()
        return (coordinator, harness)
    }

    @Test func imDoneContinuesTheStepAndLeavesTheRoutinesForTheirOwnYes() async throws {
        let temp = AgentTempDir()
        let (coordinator, harness) = await rig(temp, scripts: [{ session in await session.finish(Self.both) }, { session in await session.finish(reportText) }])
        let manager = coordinator.manager
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "File my expenses"), waitForStart: true)
        let id = result.record.id
        let report = try #require(await nextAgentReport(updates, for: id))
        #expect(report.userStep?.step == "Sign in to the expenses portal")
        #expect(report.routineProposals?.map(\.title) == ["Expense check"])
        let routineRequest = try #require(report.routineRequestID)
        #expect(routineRequest.hasPrefix("openclicky-routine-"))
        // The brain sees both, and how to answer each.
        let waiting = try #require(await manager.job(id))
        let note = try #require(AgentBrainContext.note(jobs: [waiting], running: []))
        #expect(note.contains("to approve: Create the routine \"Expense check\""))
        #expect(note.contains("; and to do a step: Sign in to the expenses portal (approve with no request_id when they say it's done)"))

        // "I'm done": the step goes on; no routine is created behind the user's back.
        #expect(try await manager.answer(id, decision: .approve(always: false)) == .sentAsFollowUp)
        #expect(RoutineStore(url: temp.paths.routines).load().isEmpty)
        let next = try #require(await nextAgentReport(updates, for: id))
        #expect(harness.launches.count == 2)
        #expect(harness.launches[1].message.contains("finished the step you asked for"))
        // The routines weren't answered: the finished run asks again.
        #expect(next.outcome == .needsYou && next.userStep == nil)
        #expect(next.routineProposals?.map(\.title) == ["Expense check"])
        #expect(next.routineRequestID != nil)

        // The card's "Set it up" still answers them (by the id it was shown with).
        #expect(try await manager.answer(id, requestID: routineRequest, decision: .approve(always: false)) == .answered)
        #expect(RoutineStore(url: temp.paths.routines).load().map(\.title) == ["Expense check"])
        let done = try #require(await manager.job(id))
        #expect(done.status == .done && done.pendingRoutines == nil && done.pendingRequest == nil)
        await #expect(throws: AgentManagerError.self) {
            try await manager.answer(id, requestID: routineRequest, decision: .approve(always: false))
        }
    }

    @Test func skipEndsTheStepButTheRoutinesStillWaitForTheirAnswer() async throws {
        let temp = AgentTempDir()
        let (coordinator, harness) = await rig(temp, scripts: [{ session in await session.finish(Self.both) }])
        let manager = coordinator.manager
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "File my expenses"), waitForStart: true)
        let id = result.record.id
        let report = try #require(await nextAgentReport(updates, for: id))

        #expect(try await manager.answer(id, decision: .decline) == .answered)
        let skipped = try #require(await manager.job(id))
        #expect(skipped.waitingStep == nil && skipped.status == .needsYou)
        #expect(skipped.pendingRoutines?.count == 1 && skipped.pendingRequest?.id == report.routineRequestID)

        #expect(try await manager.answer(id, requestID: report.routineRequestID, decision: .decline) == .answered)
        #expect(await manager.job(id)?.status == .done)
        #expect(RoutineStore(url: temp.paths.routines).load().isEmpty)
        #expect(harness.launches.count == 1)
    }

    /// A follow-up queued behind the turn that proposed a routine starts at once: the harness's own approval in that
    /// turn reaches the user, and the routines are still answered by their id.
    @Test func aQueuedFollowUpsApprovalIsNotBlockedByTheRoutineConfirmation() async throws {
        let temp = AgentTempDir()
        let harness = ScriptedHarness(kind: .claudeCode)
        let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness]) { _ in
            AgentLaunchSettings(harness: .claudeCode, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin,
                                baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
        }
        let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
        await coordinator.connectRoutines()
        let updates = await manager.subscribe()
        let result = try await manager.spawn(AgentSpawnRequest(task: "Watch fares"), waitForStart: true)
        let id = result.record.id
        let session = try #require(harness.sessions.first)
        #expect(try await manager.send(to: id, message: "Also check LAX").1 == .queued)

        await session.finish(AgentRoutineProposalTests.proposal)
        let report = try #require(await nextAgentReport(updates, for: id))
        let routineRequest = try #require(report.routineRequestID)
        #expect(await agentEventually { await manager.job(id)?.runs.count == 2 })
        let working = try #require(await manager.job(id))
        #expect(working.status == .running && working.pendingRequest == nil && working.pendingRoutines?.count == 1)

        let command = AgentApprovalRequest(id: "perm-1", kind: .command, summary: "Run: npm test")
        await session.emit(.approvalRequested(command))
        #expect(await agentEventually { await manager.job(id)?.pendingRequest?.id == "perm-1" })
        // The routines are answered by their id mid-turn, without touching the harness's request.
        #expect(try await manager.answer(id, requestID: routineRequest, decision: .approve(always: false)) == .answered)
        #expect(RoutineStore(url: temp.paths.routines).load().map(\.title) == ["Fare watch"])
        let mid = try #require(await manager.job(id))
        #expect(mid.pendingRequest?.id == "perm-1" && mid.status == .needsYou && mid.pendingRoutines == nil)
        // The HUD's Allow reaches the harness.
        #expect(try await manager.answer(id, requestID: "perm-1", decision: .approve(always: false)) == .answered)
        #expect(await session.responses.map(\.0) == ["perm-1"])
        #expect(await agentEventually { await manager.job(id)?.status == .running })

        await session.finish(reportText)
        #expect(await agentEventually { await manager.job(id)?.status == .done })
        #expect(await manager.job(id)?.pendingRequest == nil)
    }
}
