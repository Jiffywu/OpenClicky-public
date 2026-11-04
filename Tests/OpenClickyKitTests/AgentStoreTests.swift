import Foundation
import Testing
@testable import OpenClickyKit

@Test func newJobsGetTheirOwnFolderWithNotesOutputAndScratch() throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let now = Date(timeIntervalSince1970: 1_793_400_000)
    let record = try store.createJob(task: "Find three cheap flights to Denver next Tuesday and compare them", title: nil,
                                     harness: .codex, model: "gpt-6-luna", provider: "openai", now: now)
    #expect(record.title == "Find three cheap flights to Denver next Tuesday")
    #expect(record.id.hasPrefix("find-three-cheap-flights-to-denver-next-"))
    let hex = record.id.split(separator: "-").last.map(String.init) ?? ""
    #expect(hex.count == 10 && hex.allSatisfy(\.isHexDigit))
    #expect(record.folder.deletingLastPathComponent().standardizedFileURL == temp.paths.jobs.standardizedFileURL)
    for name in ["output", "tmp"] {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: record.folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
    let notes = try String(contentsOf: record.folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    #expect(notes.contains("output/") && notes.contains("tmp/") && notes.contains("## Notes"))
    #expect(record.status == .queued)

    let loaded = try #require(store.load(id: record.id))
    #expect(loaded == record)
    #expect(store.load(id: "../etc") == nil)
    #expect(store.load(id: ".hidden") == nil)
    #expect(store.load(id: "") == nil)
}

@Test func keptAgentsPersistAcrossTasksAndKeepTheirNotes() throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let agent = try store.keptAgent(named: "Research Buddy", role: "market researcher", harness: .claudeCode, model: nil, provider: "harness-login")
    #expect(agent.id == "research-buddy")
    #expect(agent.isKept)
    #expect(agent.folder.deletingLastPathComponent().standardizedFileURL == temp.paths.agents.standardizedFileURL)
    let notesURL = agent.folder.appendingPathComponent("AGENTS.md")
    let persona = try String(contentsOf: notesURL, encoding: .utf8)
    #expect(persona.contains("You are Research Buddy"))
    #expect(persona.contains("- Role: market researcher"))
    #expect(persona.contains("## Standing preferences") && persona.contains("## Notes"))

    // The agent edits its notes; asking for it again returns the same agent and keeps them.
    try (persona + "- 2026-10-31: prefers tables\n").write(to: notesURL, atomically: true, encoding: .utf8)
    var updated = agent
    updated.runs.append(AgentRun(ask: "First task", startedAt: Date()))
    try store.save(updated)
    let again = try store.keptAgent(named: "research buddy", role: "something else", harness: .codex, model: nil, provider: "openai")
    #expect(again.id == agent.id)
    #expect(again.runs.count == 1)
    #expect(again.harness == .claudeCode)
    #expect(try String(contentsOf: notesURL, encoding: .utf8).contains("prefers tables"))
}

@Test func eventsAreLoggedAsJSONLinesAndReadBack() throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let record = try store.createJob(task: "Log test", title: "Log test", harness: .codex, model: nil, provider: "harness-login")
    let request = AgentApprovalRequest(id: "7", kind: .command, summary: "Run curl", reason: "network", options: nil)
    let events: [AgentEvent] = [
        .sessionStarted(threadID: "t-1"), .turnStarted, .progress("Running: ls"), .thinking("Checking"), .commentary("Looking"),
        .plan([AgentPlanStep(step: "A", status: .completed), AgentPlanStep(step: "B", status: .inProgress)]),
        .fileChanged(path: "/x/output/a.md", change: "created"), .approvalRequested(request), .approvalResolved(id: "7"),
        .usage(AgentTokenUsage(input: 10, cachedInput: 2, output: 3)), .log("stderr line"), .error("retry", fatal: false),
        .turnFinished(.failed, finalText: "partial", error: "quota"),
    ]
    for event in events { store.append(event, to: record) }
    let text = try String(contentsOf: record.folder.appendingPathComponent("events.jsonl"), encoding: .utf8)
    #expect(text.split(separator: "\n").count == events.count)
    #expect(store.events(of: record).compactMap(\.event) == events)
    #expect(store.events(of: record, limit: 2).compactMap(\.event) == Array(events.suffix(2)))
}

@Test func reportsIndexAndSearch() throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    var flights = try store.createJob(task: "Compare flights to Denver", title: "Denver flights", harness: .codex, model: nil, provider: "openai",
                                      now: Date(timeIntervalSince1970: 1_000))
    flights.status = .done
    flights.runs = [AgentRun(ask: "Compare flights to Denver", startedAt: Date(timeIntervalSince1970: 1_000))]
    flights.runs[0].outcome = .completed
    flights.runs[0].spoken = "Tuesday is cheapest."
    flights.report = AgentFinalReport(markdown: "**Tuesday** wins.", spoken: "Tuesday is cheapest.", title: "Cheap Flights")
    flights.updatedAt = Date(timeIntervalSince1970: 2_000)
    try store.save(flights)
    try store.writeReport(for: flights)
    var budget = try store.createJob(task: "Make a monthly budget spreadsheet", title: nil, harness: .claudeCode, model: nil, provider: "anthropic",
                                     now: Date(timeIntervalSince1970: 3_000))
    budget.status = .running
    budget.updatedAt = Date(timeIntervalSince1970: 3_000)
    try store.save(budget)
    try "a,b\n".write(to: budget.outputFolder.appendingPathComponent("budget.csv"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: budget.outputFolder.appendingPathComponent("charts"), withIntermediateDirectories: true)
    try "png".write(to: budget.outputFolder.appendingPathComponent("charts/pie.png"), atomically: true, encoding: .utf8)

    let report = try String(contentsOf: flights.folder.appendingPathComponent("report.md"), encoding: .utf8)
    #expect(report.hasPrefix("# Cheap Flights"))
    #expect(report.contains("**Tuesday** wins."))
    #expect(report.contains("completed · asked: Compare flights to Denver"))

    try store.writeIndex()
    let index = try String(contentsOf: temp.paths.projects.appendingPathComponent("WORK.md"), encoding: .utf8)
    let lines = index.split(separator: "\n").filter { $0.hasPrefix("- ") }
    #expect(lines.count == 2)
    #expect(lines[0].contains("Make a monthly budget spreadsheet") && lines[0].contains("working now"))
    #expect(lines[1].contains("jobs/\(flights.id)/") && lines[1].contains("Tuesday is cheapest."))

    #expect(store.all().map(\.id) == [budget.id, flights.id])
    #expect(store.find("denver").map(\.id) == [flights.id])
    #expect(store.find("tuesday").map(\.id) == [flights.id])  // matched in the report
    #expect(store.find("budget denver").isEmpty)  // every word must match
    #expect(store.find("").count == 2)
    #expect(Set(store.outputs(of: budget)) == ["output/budget.csv", "output/charts/pie.png"])
}

@Test func slugsAndTitles() {
    #expect(AgentJobStore.slug("Café Menu: Spring '27!") == "cafe-menu-spring-27")
    #expect(AgentJobStore.slug("  ---  ") == "job")
    #expect(AgentJobStore.slug(String(repeating: "abc ", count: 30)).count <= 40)
    #expect(!AgentJobStore.slug(String(repeating: "abc ", count: 30)).hasSuffix("-"))
    #expect(AgentJobStore.title("  ", from: "\n\nWrite a haiku about autumn leaves falling slowly in the park today") == "Write a haiku about autumn leaves falling slowly")
    #expect(AgentJobStore.title("Haiku", from: "anything") == "Haiku")
    #expect(AgentJobStore.title(nil, from: "") == "Job")
}

@Test func supportFolderLayout() {
    let paths = AgentPaths(root: URL(fileURLWithPath: "/tmp/oc", isDirectory: true))
    #expect(paths.jobs.path == "/tmp/oc/projects/jobs")
    #expect(paths.agents.path == "/tmp/oc/projects/agents")
    #expect(paths.routines.path == "/tmp/oc/routines.json")
    #expect(paths.codexHome.path == "/tmp/oc/harness/codex-home")
}

// MARK: - Transcripts

/// A job log as `AgentJobStore.append` writes it: two runs, the first from before run markers existed (split at its
/// finished turn), the second with its marker, a plan, a reasoning heading, tool steps, a file and a report.
let recordedEventsJSONL = """
{"id":"019a4c55-7d1e-7c3a-9f0e-2f3b1c9d8e11","kind":"session","t":"2026-11-03T09:00:01Z"}
{"kind":"turn_started","t":"2026-11-03T09:00:01Z"}
{"kind":"thinking","t":"2026-11-03T09:00:03Z","text":"Planning the fare search"}
{"kind":"commentary","t":"2026-11-03T09:00:04Z","text":"Checking three airlines first [Kayak](turn0search1)."}
{"kind":"progress","t":"2026-11-03T09:00:05Z","text":"Searching: SFO to DEN nonstop"}
{"kind":"progress","t":"2026-11-03T09:00:05Z","text":"Searching: SFO to DEN nonstop"}
{"kind":"file","path":"/tmp/jobs/flights/output/flights.md","change":"created","t":"2026-11-03T09:00:20Z"}
{"kind":"usage","t":"2026-11-03T09:00:21Z","usage":{"cachedInput":20,"input":120,"output":30}}
{"kind":"turn_finished","outcome":"completed","t":"2026-11-03T09:00:22Z","text":"Found three options.\\n\\n<report>\\nsay: I found three flights.\\ntitle: Denver Flights\\nfiles:\\n- output/flights.md\\nnext:\\n- Book the cheapest one\\n</report>"}
{"id":"2","kind":"run","t":"2026-11-03T09:05:00Z","text":"And the return on Sunday?"}
{"kind":"turn_started","t":"2026-11-03T09:05:01Z"}
{"kind":"plan","plan":[{"status":"completed","step":"Search Sunday fares"},{"status":"in_progress","step":"Update the table"}],"t":"2026-11-03T09:05:02Z"}
{"kind":"progress","t":"2026-11-03T09:05:03Z","text":"Editing: output/flights.md"}
{"kind":"file","path":"/tmp/jobs/flights/output/flights.md","change":"changed","t":"2026-11-03T09:05:09Z"}
{"kind":"error","fatal":false,"t":"2026-11-03T09:05:10Z","text":"Reconnecting 1/5"}
{"kind":"log","t":"2026-11-03T09:05:10Z","text":"stderr: warning"}
{"kind":"turn_finished","outcome":"completed","t":"2026-11-03T09:05:30Z","text":"Added Sunday.\\n<report>\\nsay: Sunday's cheapest return is 141 dollars.\\n</report>\\n<answer>{\\"outcome\\":\\"Return from 141 dollars\\",\\"numbers\\":[{\\"value\\":\\"$141\\",\\"label\\":\\"Sunday return\\"}]}</answer>"}
"""

func transcriptRecord(folder: String = "/tmp/jobs/flights") -> AgentJobRecord {
    let start = ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z")!
    var first = AgentRun(ask: "Find nonstop flights SFO to DEN on Tuesday", startedAt: start)
    first.finishedAt = start.addingTimeInterval(22)
    first.outcome = .completed
    first.spoken = "I found three flights."
    var second = AgentRun(ask: "And the return on Sunday?", startedAt: start.addingTimeInterval(300))
    second.finishedAt = start.addingTimeInterval(330)
    second.outcome = .completed
    second.spoken = "Sunday's cheapest return is 141 dollars."
    return AgentJobRecord(id: "flights", kind: .job, title: "Flights", task: first.ask, harness: .codex, model: nil, provider: "p",
                          status: .done, createdAt: start, updatedAt: start.addingTimeInterval(330), runs: [first, second], folderPath: folder)
}

@Test func aRecordedEventLogReplaysIntoTurns() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entries = try recordedEventsJSONL.split(separator: "\n").map { try decoder.decode(AgentLogEntry.self, from: Data($0.utf8)) }
    let transcript = AgentTranscript.build(record: transcriptRecord(), entries: entries)
    #expect(transcript.turns.count == 2)

    let first = transcript.turns[0]
    #expect(first.number == 1 && first.ask == "Find nonstop flights SFO to DEN on Tuesday")
    #expect(first.reasoning == ["Planning the fare search"])
    #expect(first.messages == ["Checking three airlines first Kayak."])
    #expect(first.toolSteps == ["Searching: SFO to DEN nonstop"])  // the repeated line once
    #expect(first.files == [AgentTranscriptFile(path: "/tmp/jobs/flights/output/flights.md", change: "created")])
    #expect(first.report?.spoken == "I found three flights.")
    #expect(first.report?.title == "Denver Flights")
    #expect(first.suggestedNext == ["Book the cheapest one"])
    #expect(first.outcome == .completed)

    let second = transcript.turns[1]
    #expect(second.ask == "And the return on Sunday?")
    #expect(second.plan.map(\.step) == ["Search Sunday fares", "Update the table"])
    #expect(second.toolSteps == ["Editing: output/flights.md"])
    #expect(second.files.first?.change == "changed")
    #expect(second.steps.allSatisfy { $0.kind != .error })  // a retried, non-fatal error isn't shown
    #expect(second.report?.answer?.numbers?.first?.value == "$141")
    #expect(transcript.preview == "Sunday's cheapest return is 141 dollars.")

    let lines = transcript.brainLines().compactMap(\.stringValue)
    #expect(lines.first == "ask (run 1): Find nonstop flights SFO to DEN on Tuesday")
    #expect(lines.contains("thinking: Planning the fare search"))
    #expect(lines.contains("final: Found three options.\nsuggested next: Book the cheapest one"))
    #expect(lines.last == "final: Added Sunday.")
}

@Test func aRunWhoseLogWasCleanedUpKeepsItsAskAndResult() {
    let transcript = AgentTranscript.build(record: transcriptRecord(), entries: [])
    #expect(transcript.turns.map(\.ask) == ["Find nonstop flights SFO to DEN on Tuesday", "And the return on Sunday?"])
    #expect(transcript.turns.map { $0.report?.spoken } == ["I found three flights.", "Sunday's cheapest return is 141 dollars."])
}

@Test func theTranscriptReadsTheSameAfterARelaunch() async throws {
    let rig = ScriptedRig { session in
        await session.emit(.thinking("Looking at fares"))
        await session.emit(.commentary("Checking three airlines first."))
        await session.emit(.plan([AgentPlanStep(step: "Search", status: .inProgress)]))
        await session.emit(.progress("Searching: SFO to DEN"))
        await session.emit(.fileChanged(path: "/tmp/flights.md", change: "created"))
        await session.finish(reportText)
    }
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Flights to Denver", title: "Flights"), waitForStart: true)
    _ = await nextAgentReport(updates, for: result.record.id)
    _ = try await rig.manager.send(to: result.record.id, message: "And hotels near the airport?")
    #expect(await agentEventually {
        let current = await rig.manager.job(result.record.id)
        return current?.runs.count == 2 && current?.status == .done
    })
    let record = try #require(await rig.manager.job(result.record.id))
    let before = rig.manager.store.transcript(of: record)
    #expect(before.turns.count == 2)
    #expect(before.turns[1].ask == "And hotels near the airport?")
    #expect(before.turns[0].messages == ["Checking three airlines first."])
    #expect(before.turns[1].messages == ["Checking three airlines first."])

    // A new process: a fresh manager and store over the same folder.
    let relaunched = AgentManager(store: AgentJobStore(paths: rig.temp.paths), harnesses: [ScriptedHarness()]) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin)
    }
    await relaunched.recoverInterruptedJobs()
    let reloaded = try #require(await relaunched.job(result.record.id))
    #expect(relaunched.store.transcript(of: reloaded) == before)
    let entries = relaunched.store.allEvents(of: reloaded)
    #expect(entries.filter { $0.kind == "run" }.compactMap(\.id) == ["1", "2"])
}
