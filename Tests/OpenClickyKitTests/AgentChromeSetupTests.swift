import Foundation
import Testing
@testable import OpenClickyKit

// A job that needs the user's Chrome asks through a chrome_setup request; the brain answers it with
// sessions_answer_request, and the job hears back when Chrome connects (or that the user declined).

private func makeManager(_ temp: AgentTempDir, scenario: String = "quick") throws -> AgentManager {
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": scenario, "FAKE_LOG": temp.url.appendingPathComponent("harness.log").path]
    return AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: "harness-login", auth: .harnessLogin, executable: codex,
                            baseEnvironment: environment)
    }
}

private func call(_ tools: AgentTools, _ name: String, _ arguments: JSONValue) async -> JSONValue {
    await tools.callJSON(name: name, arguments: arguments.jsonString())
}

/// Spawns the quick fake job and waits for its report.
private func finishedJob(_ tools: AgentTools, _ manager: AgentManager, task: String) async throws -> String {
    let updates = await manager.subscribe()
    let spawned = await call(tools, "sessions_spawn", ["task": .string(task)])
    let jobID = try #require(spawned["job_id"]?.stringValue)
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { break } }
    return jobID
}

private final class SetupOpenCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func hit() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func aChromeSetupRequestRoundTripsThroughTheBrainsTools() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let opened = SetupOpenCount()
    var tools = AgentTools(manager: manager)
    tools.openBrowserSetup = {
        opened.hit()
        return ["Open Settings → Browser.", "Load the extension."]
    }
    let jobID = try await finishedJob(tools, manager, task: "Check my orders on the shop site")

    // The browser tool raises it (once) when the job has no browser.
    #expect(await manager.requestChromeSetup(jobID: jobID))
    #expect(await manager.requestChromeSetup(jobID: jobID))
    let status = await call(tools, "session_status", ["job_id": .string(jobID)])
    #expect(status["job"]?["state"]?.stringValue == "needs-you")
    let pending = try #require(status["job"]?["pending_request"])
    #expect(pending["kind"]?.stringValue == "chrome_setup")
    #expect(pending["options"] == ["Connect Chrome", "Not now"])
    let requestID = try #require(pending["request_id"]?.stringValue)

    let answered = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "request_id": .string(requestID), "decision": "approve"])
    #expect(answered["status"]?.stringValue == "answered")
    #expect(answered["request"]?.stringValue == "chrome_setup")
    #expect(answered["opened"]?.stringValue == "openclicky://settings/browser")
    #expect(answered["steps"] == ["Open Settings → Browser.", "Load the extension."])
    #expect(opened.value == 1)
    #expect(await manager.chromeSetupRequest(jobID) == nil)
    let record = try #require(await manager.job(jobID))
    #expect(record.pendingRequest == nil && record.status != .needsYou)

    // Chrome connects: the job is told to carry on, as a new run.
    let updates = await manager.subscribe()
    await manager.browserConnected()
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { break } }
    let resumed = try #require(await manager.job(jobID))
    #expect(resumed.runs.count == 2)
    #expect(resumed.runs.last?.ask == AgentManager.chromeConnectedMessage)
    // Nobody is waiting any more.
    await manager.browserConnected()
    #expect(try #require(await manager.job(jobID)).runs.count == 2)
}

@Test func decliningChromeSetupTellsTheJobToGoOnWithoutIt() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let tools = AgentTools(manager: manager)
    let jobID = try await finishedJob(tools, manager, task: "Find my last invoice")
    #expect(await manager.requestChromeSetup(jobID: jobID))
    let updates = await manager.subscribe()
    let answered = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "decision": "decline"])
    #expect(answered["status"]?.stringValue == "sent_as_follow_up")
    #expect(answered["request"]?.stringValue == "chrome_setup")
    #expect(answered["steps"] == nil)
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { break } }
    #expect(try #require(await manager.job(jobID)).runs.last?.ask == AgentManager.chromeDeclinedMessage)
    #expect(!(await manager.requestChromeSetup(jobID: "ghost")))
}

@Test func browserUsageLandsOnTheRunItBelongsTo() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let tools = AgentTools(manager: manager)
    let jobID = try await finishedJob(tools, manager, task: "Look something up")
    let run = try #require(await manager.job(jobID)?.runs.first)
    var usage = BrowserTurnUsage(turn: 1, firstCallAt: run.startedAt.addingTimeInterval(1))
    usage.operationCount = 4
    usage.tabsKept = 1
    await manager.recordBrowserUsage(jobID: jobID, usage)
    let stored = try #require(AgentJobStore(paths: temp.paths).load(id: jobID))
    // job.json keeps dates to the second, so compare the counters.
    let kept = try #require(stored.runs.first?.browser)
    #expect(kept.operationCount == 4 && kept.tabsKept == 1 && kept.turn == 1)
    #expect(abs(kept.firstCallAt.timeIntervalSince(usage.firstCallAt)) < 1)
}

/// Waits (at most `timeout` seconds) for the job's next report, so a job that hangs fails the test instead of
/// stalling the run.
private func reportArrives(_ updates: AsyncStream<AgentManagerUpdate>, for jobID: String, timeout: Double = 15) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await update in updates { if case .report(let report) = update, report.jobID == jobID { return true } }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

private func harnessLog(_ temp: AgentTempDir) -> String {
    (try? String(contentsOf: temp.url.appendingPathComponent("harness.log"), encoding: .utf8)) ?? ""
}

@Test func approvingChromeSetupWhileABrowserIsConnectedCarriesTheJobOnAtOnce() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    // The user opened Chrome before answering: the connect event has come and gone.
    await manager.setBrowserConnectedCheck { true }
    var tools = AgentTools(manager: manager)
    tools.openBrowserSetup = { ["Open Settings → Browser."] }
    let jobID = try await finishedJob(tools, manager, task: "Check my orders on the shop site")
    #expect(await manager.requestChromeSetup(jobID: jobID))

    let updates = await manager.subscribe()
    let answered = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "decision": "approve"])
    #expect(answered["status"]?.stringValue == "sent_as_follow_up")
    #expect(answered["next"]?.stringValue?.contains("already connected") == true)
    #expect(answered["steps"] == nil)
    #expect(await reportArrives(updates, for: jobID), "the job finished its turn instead of hanging")
    let resumed = try #require(await manager.job(jobID))
    #expect(resumed.runs.count == 2)
    #expect(resumed.runs.last?.ask == AgentManager.chromeConnectedMessage)
}

@Test func aHarnessApprovalRaisedWhileChromeSetupWaitsIsShownAndAnsweredFirst() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp, scenario: "wait-approve")
    let tools = AgentTools(manager: manager)
    let jobID = try await manager.spawn(AgentSpawnRequest(task: "Compare my plan prices"), waitForStart: true).record.id
    #expect(await agentEventually { await manager.job(jobID)?.status == .running })
    // The job's browser call raised chrome_setup; it carries on with the parts that need no website…
    #expect(await manager.requestChromeSetup(jobID: jobID))
    #expect(await manager.job(jobID)?.pendingRequest?.kind == .chromeSetup)
    // …and hits a command approval.
    let updates = await manager.subscribe()
    _ = try await manager.send(to: jobID, message: "Go on")
    #expect(await agentEventually { await manager.job(jobID)?.pendingRequest?.kind == .command })
    let status = await call(tools, "session_status", ["job_id": .string(jobID)])
    #expect(status["job"]?["pending_request"]?["kind"]?.stringValue == "command", "the brain sees the harness's request")

    // An answer without a request id goes to the request the user was shown.
    let answered = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "decision": "approve"])
    #expect(answered["status"]?.stringValue == "answered")
    #expect(answered["request"] == nil)
    #expect(await reportArrives(updates, for: jobID), "the job finished its turn instead of hanging")
    #expect(harnessLog(temp).contains(#""decision":"accept""#))
    // The turn ended still waiting for Chrome: chrome_setup faces the user again.
    let after = try #require(await manager.job(jobID))
    #expect(after.status == .needsYou && after.pendingRequest?.kind == .chromeSetup)
}

@Test func anAnswerWithoutARequestIDGoesToTheHarnessApprovalAlreadyShown() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp, scenario: "approve")
    let tools = AgentTools(manager: manager)
    let updates = await manager.subscribe()
    let jobID = try await manager.spawn(AgentSpawnRequest(task: "Fetch the page"), waitForStart: true).record.id
    #expect(await agentEventually { await manager.job(jobID)?.pendingRequest?.kind == .command })
    #expect(await manager.requestChromeSetup(jobID: jobID))
    #expect(await manager.job(jobID)?.pendingRequest?.kind == .command, "the harness's request stays in front")

    let answered = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "decision": "approve"])
    #expect(answered["status"]?.stringValue == "answered")
    #expect(answered["request"] == nil, "not taken as the answer to chrome_setup")
    #expect(await reportArrives(updates, for: jobID), "the job finished its turn instead of hanging")
    #expect(harnessLog(temp).contains(#""decision":"accept""#))
    #expect(await manager.chromeSetupRequest(jobID) != nil)
}

@Test func stoppingAJobEndsItsWaitForChrome() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let tools = AgentTools(manager: manager)

    // Approved, then stopped before Chrome connected: it doesn't start again when Chrome does.
    let approvedID = try await finishedJob(tools, manager, task: "Check my orders")
    #expect(await manager.requestChromeSetup(jobID: approvedID))
    _ = try await manager.answer(approvedID, decision: .approve(always: false))
    let stopped = await call(tools, "sessions_interrupt", ["job_id": .string(approvedID)])
    #expect(stopped["status"]?.stringValue == "interrupted")
    #expect(await manager.job(approvedID)?.status == .stopped)
    await manager.browserConnected()
    #expect(try #require(await manager.job(approvedID)).runs.count == 1)

    // Asking, between turns: stopping clears the request.
    let askingID = try await finishedJob(tools, manager, task: "Find my last invoice")
    #expect(await manager.requestChromeSetup(jobID: askingID))
    #expect(await manager.interrupt(askingID))
    let asking = try #require(await manager.job(askingID))
    #expect(asking.status == .stopped && asking.pendingRequest == nil)
    #expect(await manager.chromeSetupRequest(askingID) == nil)
}

@Test func stoppingAJobMidTurnWhileItAsksForChromeLeavesItStopped() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp, scenario: "wait")
    let updates = await manager.subscribe()
    let jobID = try await manager.spawn(AgentSpawnRequest(task: "Book the table"), waitForStart: true).record.id
    #expect(await agentEventually { await manager.job(jobID)?.status == .running })
    #expect(await manager.requestChromeSetup(jobID: jobID))
    #expect(await manager.interrupt(jobID))
    #expect(await reportArrives(updates, for: jobID), "the job finished its turn instead of hanging")
    let record = try #require(await manager.job(jobID))
    #expect(record.status == .stopped, "not back to needs-you for Chrome")
    #expect(record.pendingRequest == nil)
    #expect(await manager.chromeSetupRequest(jobID) == nil)
}
