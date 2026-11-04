import Foundation
import Testing
@testable import OpenClickyKit

/// A manager over the fake Codex harness using the harness's own login (no key anywhere).
private func makeManager(_ temp: AgentTempDir, scenario: String = "quick") throws -> AgentManager {
    let codex = try temp.script("codex", FakeHarnessScripts.codex)
    let environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path, "FAKE_SCENARIO": scenario]
    return AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: "harness-login", auth: .harnessLogin, executable: codex,
                            baseEnvironment: environment)
    }
}

private func call(_ tools: AgentTools, _ name: String, _ arguments: JSONValue) async -> JSONValue {
    await tools.callJSON(name: name, arguments: arguments.jsonString())
}

@Test func toolSpecsAreWellFormedJSONSchemas() {
    let manager = AgentManager(store: AgentJobStore(paths: AgentTempDir().paths)) { _ in throw AgentManagerError.emptyTask }
    let scheduler = RoutineScheduler(store: RoutineStore(url: URL(fileURLWithPath: "/dev/null"))) { _, _ in "" }
    let withRoutines = AgentTools(manager: manager, routines: scheduler, openFile: { _ in true }, openLink: { _ in true }).specs
    #expect(Set(withRoutines.map(\.name)) == AgentTools.names)
    #expect(Set(AgentTools(manager: manager).specs.map(\.name)) == AgentTools.names.subtracting(["routines", "open_artifact", "open_agent_dashboard"]))
    for spec in withRoutines {
        #expect(spec.parameters["type"]?.stringValue == "object", "\(spec.name)")
        #expect(spec.parameters["additionalProperties"]?.boolValue == false, "\(spec.name)")
        let properties = Set(spec.parameters["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let required = Set(spec.parameters["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required.isSubset(of: properties), "\(spec.name)")
        #expect(!spec.description.isEmpty)
        for (key, schema) in spec.parameters["properties"]?.objectValue ?? [:] {
            #expect(schema["type"]?.stringValue != nil, "\(spec.name).\(key)")
        }
    }
    #expect(AgentTools.spawnSpec.parameters["required"] == ["task"])
    #expect(AgentTools.answerSpec.parameters["properties"]?["decision"]?["enum"] == ["approve", "decline", "answer"])
}

@Test func theBrainSpawnsFollowsAndReadsBackAJob() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let presented = ReportBox()
    let tools = AgentTools(manager: manager, presentResult: { report in presented.set(report) })
    let updates = await manager.subscribe()

    let spawned = await call(tools, "sessions_spawn", ["task": "Write meeting notes", "title": "Meeting notes"])
    #expect(spawned["status"]?.stringValue == "dispatched")
    let jobID = try #require(spawned["job_id"]?.stringValue)
    #expect(spawned["title"]?.stringValue == "Meeting notes")
    let again = await call(tools, "sessions_spawn", ["task": "Write meeting notes"])
    #expect(again["status"]?.stringValue == "already_started")
    #expect(again["job_id"]?.stringValue == jobID)

    var finished = false
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { finished = true; break } }
    #expect(finished)

    let one = await call(tools, "session_status", ["job_id": .string(jobID)])
    #expect(one["job"]?["state"]?.stringValue == "done")
    #expect(one["job"]?["latest_report"]?.stringValue == "Your notes are ready.")
    #expect(one["job"]?["recent_progress"]?.arrayValue?.isEmpty == false)
    let all = await call(tools, "session_status", [:])
    #expect(all["active"]?.arrayValue?.isEmpty == true)
    #expect(all["recent"]?.arrayValue?.first?["job_id"]?.stringValue == jobID)

    let found = await call(tools, "find_jobs", ["query": "meeting"])
    #expect(found["jobs"]?.arrayValue?.map { $0["job_id"]?.stringValue } == [jobID])
    #expect(found["jobs"]?.arrayValue?.first?["folder"]?.stringValue?.hasSuffix(jobID) == true)
    #expect(await call(tools, "find_jobs", ["query": "zebra"])["jobs"]?.arrayValue?.isEmpty == true)

    let shown = await call(tools, "show_result", ["job_id": .string(jobID)])
    #expect(shown["status"]?.stringValue == "shown")
    #expect(shown["say"]?.stringValue == "Your notes are ready.")
    #expect(shown["outcome"]?.stringValue == "done")
    #expect(shown["files"]?.arrayValue?.first?.stringValue?.hasSuffix("/output/notes.md") == true)
    #expect(presented.value?.jobID == jobID)

    let sent = await call(tools, "sessions_send", ["job_id": .string(jobID), "message": "Add a summary"])
    #expect(sent["status"]?.stringValue == "sent")
    #expect(sent["sent_as"]?.stringValue == "started_turn")
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { break } }

    let notRunning = await call(tools, "sessions_interrupt", ["job_id": .string(jobID)])
    #expect(notRunning["status"]?.stringValue == "not_running")
    let nothing = await call(tools, "sessions_answer_request", ["job_id": .string(jobID), "decision": "approve"])
    #expect(nothing["status"]?.stringValue == "error")
}

@Test func toolErrorsComeBackAsResults() async throws {
    let temp = AgentTempDir()
    let tools = AgentTools(manager: try makeManager(temp))
    #expect(await tools.callJSON(name: "sessions_spawn", arguments: "{not json")["status"]?.stringValue == "error")
    #expect(await call(tools, "sessions_spawn", [:])["message"]?.stringValue == "Missing task.")
    #expect(await call(tools, "sessions_send", ["job_id": "ghost", "message": "hi"])["message"]?.stringValue?.contains("ghost") == true)
    #expect(await call(tools, "show_result", ["job_id": "ghost"])["status"]?.stringValue == "error")
    #expect(await call(tools, "sessions_answer_request", ["job_id": "ghost", "decision": "maybe"])["status"]?.stringValue == "error")
    #expect(await call(tools, "routines", ["action": "list"])["status"]?.stringValue == "not_implemented")
    #expect(await call(tools, "teleport", [:])["status"]?.stringValue == "not_implemented")
    // The raw string form the brain runtime uses.
    let text = await tools.call(ToolCall(id: "c1", name: "session_status", arguments: ""))
    #expect(try JSONValue.parse(text)["status"]?.stringValue == "ok")
}

@Test func routinesThroughTheBrainTool() async throws {
    let temp = AgentTempDir()
    let manager = try makeManager(temp)
    let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
    let tools = coordinator.tools

    let created = await call(tools, "routines", ["action": "create", "title": "Morning brief", "task": "Summarize the news", "at": "07:30", "days": [1, 2, 3, 4, 5]])
    #expect(created["status"]?.stringValue == "created")
    let id = try #require(created["routine"]?["routine_id"]?.stringValue)
    #expect(created["routine"]?["schedule"]?.stringValue == "weekdays at 07:30")
    #expect(created["routine"]?["next_run"]?.stringValue != nil)

    #expect(await call(tools, "routines", ["action": "create", "task": "x"])["message"]?.stringValue?.contains("every_minutes") == true)
    #expect(await call(tools, "routines", ["action": "create", "task": "x", "at": "7pm"])["status"]?.stringValue == "error")
    #expect(await call(tools, "routines", ["action": "create", "task": "x", "cron": "* * *"])["status"]?.stringValue == "error")

    let paused = await call(tools, "routines", ["action": "pause", "routine_id": .string(id)])
    #expect(paused["routine"]?["paused"]?.boolValue == true)
    let updated = await call(tools, "routines", ["action": "update", "routine_id": .string(id), "every_minutes": 90])
    #expect(updated["routine"]?["schedule"]?.stringValue == "every 90 minutes")
    #expect(await call(tools, "routines", ["action": "list"])["routines"]?.arrayValue?.count == 1)

    let updates = await manager.subscribe()
    let started = await call(tools, "routines", ["action": "run_now", "routine_id": .string(id)])
    #expect(started["status"]?.stringValue == "started")
    let jobID = try #require(started["job_id"]?.stringValue)
    var routineID: String?
    for await update in updates { if case .report(let report) = update, report.jobID == jobID { routineID = report.routineID; break } }
    #expect(routineID == id)
    let job = try #require(await manager.job(jobID))
    #expect(job.title == "Morning brief")
    #expect(job.runs.first?.routineID == id)

    #expect(await call(tools, "routines", ["action": "delete", "routine_id": .string(id)])["status"]?.stringValue == "deleted")
    #expect(await call(tools, "routines", ["action": "explode"])["status"]?.stringValue == "error")
}

final class ReportBox: @unchecked Sendable {
    private var stored: AgentJobReport?
    private var all: [[AgentJobReport]] = []
    private let lock = NSLock()
    func set(_ report: AgentJobReport) { lock.withLock { stored = report } }
    func add(_ batch: [AgentJobReport]) { lock.withLock { all.append(batch) } }
    var value: AgentJobReport? { lock.withLock { stored } }
    var batches: [[AgentJobReport]] { lock.withLock { all } }
}
