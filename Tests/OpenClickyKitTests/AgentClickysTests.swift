import Foundation
import Testing
@testable import OpenClickyKit

// Kept agents ("Clickys") in the brain: the [Your Clickys] note, clicky_memory, clicky_artifacts, open_artifact,
// open_agent_dashboard, archive and unarchive, and revive-on-route.

/// Collects what the app-side closures were asked to open.
final class OpenedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [URL] = []
    private var _links: [String?] = []

    var files: [URL] { lock.withLock { _files } }
    var links: [String?] { lock.withLock { _links } }
    func add(_ url: URL) { lock.withLock { _files.append(url) } }
    func add(link: String?) { lock.withLock { _links.append(link) } }
}

enum ClickyFixtures {
    /// A kept agent "Scribe" (newsletter writer) with one finished run, a report, an output file and a note.
    static func scribe(_ store: AgentJobStore, now: Date = Date()) throws -> AgentJobRecord {
        var record = try store.keptAgent(named: "Scribe", role: "newsletter writer", harness: .codex, model: nil,
                                         provider: AgentLaunchSettings.loginProviderID, now: now)
        var run = AgentRun(ask: "Draft the October newsletter", startedAt: now.addingTimeInterval(-600))
        run.finishedAt = now.addingTimeInterval(-500)
        run.outcome = .completed
        run.spoken = "The October newsletter draft is ready."
        record.runs = [run]
        record.report = AgentFinalReport(markdown: "Draft in output/october.md", spoken: "The October newsletter draft is ready.")
        record.status = .done
        try store.save(record)
        try "# October\n\nHello readers.\n".write(to: record.outputFolder.appendingPathComponent("october.md"), atomically: true, encoding: .utf8)
        let notes = record.folder.appendingPathComponent("AGENTS.md")
        let memory = try String(contentsOf: notes, encoding: .utf8) + "- 2026-10-30: The user likes short intros.\n"
        try memory.write(to: notes, atomically: true, encoding: .utf8)
        return record
    }

    static func call(_ tools: AgentTools, _ name: String, _ arguments: JSONValue) async -> JSONValue {
        await tools.callJSON(name: name, arguments: arguments.jsonString())
    }
}

@Test func theClickysNoteListsNameRoleStatusAndLastSaidWithArchivedOnesApart() throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    let scribe = try ClickyFixtures.scribe(store)
    var scout = try store.keptAgent(named: "Scout", role: "price watcher", harness: .codex, model: nil, provider: "harness-login")
    scout.status = .running
    scout.lastProgress = "Searching: espresso machines"
    scout.lastSaid = "Two shops have it under 300 euros."
    scout.runs = [AgentRun(ask: "Watch espresso machine prices", startedAt: Date())]
    var old = try store.keptAgent(named: "Old Helper", role: nil, harness: .codex, model: nil, provider: "harness-login")
    old.archivedAt = Date()
    let job = try store.createJob(task: "One-off task", title: "One-off", harness: .codex, model: nil, provider: "harness-login")

    let note = try #require(AgentBrainContext.clickysNote(jobs: [scout, scribe, old, job], running: []))
    #expect(note.hasPrefix("[Your Clickys]"))
    #expect(note.contains("- Scout (scout), price watcher: WORKING NOW, latest: Searching: espresso machines; last said: \"Two shops have it under 300 euros.\""))
    #expect(note.contains("- Scribe (scribe), newsletter writer: idle; last said: \"The October newsletter draft is ready.\""))
    #expect(note.contains("Archived (routing work to one brings it back; tell the user when that happens): Old Helper (old-helper)"))
    #expect(!note.contains("One-off"))
    #expect(AgentBrainContext.clickysNote(jobs: [job], running: []) == nil)
}

@Test func coordinatorNotesCarryJobsAndClickysSeparately() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    _ = try ClickyFixtures.scribe(rig.manager.store)
    let coordinator = AgentCoordinator(manager: rig.manager, routineStore: RoutineStore(url: rig.temp.url.appendingPathComponent("routines.json")),
                                       onReports: { _ in })
    let notes = await BrainWiring.jobNotes(coordinator)()
    // [Your jobs] and [Your Clickys] from the coordinator, then [Your routines].
    #expect(notes.count == 3)
    #expect(notes[0].hasPrefix("[Your jobs]"))
    #expect(notes[1].hasPrefix("[Your Clickys]") && notes[1].contains("Scribe (scribe)"))
    #expect(notes[2].hasPrefix("[Your routines]"))
}

@Test func clickyMemoryReadsTheAgentsFileStateAndRecentRuns() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    let scribe = try ClickyFixtures.scribe(rig.manager.store)
    try "# State\n- Sent the draft to the user\n".write(to: scribe.folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
    let tools = AgentTools(manager: rig.manager)

    let memory = await ClickyFixtures.call(tools, "clicky_memory", ["agent": "Scribe"])
    #expect(memory["status"] == "ok")
    #expect(memory["job_id"] == "scribe")
    #expect(memory["role"] == "newsletter writer")
    #expect(memory["is_archived"] == false && memory["is_working_now"] == false)
    let markdown = try #require(memory["memory_markdown"]?.stringValue)
    #expect(markdown.contains("## Standing preferences") && markdown.contains("The user likes short intros."))
    #expect(memory["state_markdown"]?.stringValue?.contains("Sent the draft") == true)
    let runs = try #require(memory["recent_runs"]?.arrayValue)
    #expect(runs.first?["asked"] == "Draft the October newsletter")
    #expect(runs.first?["outcome"] == "completed")
    #expect(runs.first?["said"] == "The October newsletter draft is ready.")
    #expect(memory["latest_reply"] == "The October newsletter draft is ready.")

    // A long memory file is cut and says so.
    try String(repeating: "note line\n", count: 2_000).write(to: scribe.folder.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    let long = await ClickyFixtures.call(tools, "clicky_memory", ["agent": "scribe"])
    #expect(long["memory_markdown"]?.stringValue?.hasSuffix("(memory file truncated)") == true)

    let unknown = await ClickyFixtures.call(tools, "clicky_memory", ["agent": "Nobody"])
    #expect(unknown["status"] == "error")
}

@Test func clickyArtifactsListsAndReadsFilesOnlyInsideTheFolder() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    let scribe = try ClickyFixtures.scribe(rig.manager.store)
    try FileManager.default.createDirectory(at: scribe.outputFolder.appendingPathComponent("drafts"), withIntermediateDirectories: true)
    try "older".write(to: scribe.outputFolder.appendingPathComponent("drafts/september.md"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                          ofItemAtPath: scribe.outputFolder.appendingPathComponent("drafts/september.md").path)
    try "scratch".write(to: scribe.folder.appendingPathComponent("tmp/scratch.txt"), atomically: true, encoding: .utf8)
    try "secret".write(to: rig.temp.url.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    let tools = AgentTools(manager: rig.manager)

    let listing = await ClickyFixtures.call(tools, "clicky_artifacts", ["agent": "Scribe"])
    let paths = try #require(listing["files"]?.arrayValue).compactMap { $0["path"]?.stringValue }
    #expect(paths.first == "output/october.md")
    #expect(paths.contains("output/drafts/september.md"))
    #expect(!paths.contains { $0.hasPrefix("tmp/") || $0 == "job.json" || $0 == "AGENTS.md" })

    let read = await ClickyFixtures.call(tools, "clicky_artifacts", ["agent": "Scribe", "file": "october.md"])
    #expect(read["content"] == "# October\n\nHello readers.\n")
    #expect(read["file"] == "output/october.md")
    let nested = await ClickyFixtures.call(tools, "clicky_artifacts", ["agent": "Scribe", "file": "output/drafts/september.md"])
    #expect(nested["content"] == "older")

    for escape in ["../../../outside.txt", rig.temp.url.appendingPathComponent("outside.txt").path, "output/../../../../outside.txt"] {
        let refused = await ClickyFixtures.call(tools, "clicky_artifacts", ["agent": "Scribe", "file": .string(escape)])
        #expect(refused["status"] == "not_found", "\(escape)")
    }
    // File diffs hold copies of files changed anywhere (a .env, ~/.aws/config); the brain can't read them back.
    let diff = scribe.folder.appendingPathComponent("diffs/run-1/1-.env.diff")
    try FileManager.default.createDirectory(at: diff.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "-KEY=old\n+KEY=new\n".write(to: diff, atomically: true, encoding: .utf8)
    for name in ["diffs/run-1/1-.env.diff", "Diffs/run-1/1-.env.diff", diff.path] {
        let refused = await ClickyFixtures.call(tools, "clicky_artifacts", ["agent": "Scribe", "file": .string(name)])
        #expect(refused["status"] == "not_found", "\(name)")
        #expect(AgentArtifacts.resolve(name, in: scribe) == nil, "\(name)")
    }
}

@Test func openArtifactAndTheDashboardGoThroughTheAppsClosures() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    let scribe = try ClickyFixtures.scribe(rig.manager.store)
    let opened = OpenedBox()
    let tools = AgentTools(manager: rig.manager, openFile: { url in opened.add(url); return true },
                           openLink: { link in opened.add(link: link); return true })
    #expect(tools.specs.map(\.name).contains("open_artifact") && tools.specs.map(\.name).contains("open_agent_dashboard"))

    let newest = await ClickyFixtures.call(tools, "open_artifact", ["agent": "Scribe"])
    #expect(newest["status"] == "opened" && newest["file"] == "october.md")
    let named = await ClickyFixtures.call(tools, "open_artifact", ["agent": "scribe", "file": "output/october.md"])
    #expect(named["status"] == "opened")
    #expect(opened.files.map(\.lastPathComponent) == ["october.md", "october.md"])
    #expect(opened.files.allSatisfy { $0.path.hasSuffix("agents/scribe/output/october.md") })
    let missing = await ClickyFixtures.call(tools, "open_artifact", ["agent": "Scribe", "file": "nope.pdf"])
    #expect(missing["status"] == "not_found")
    #expect(opened.files.count == 2)

    let dashboard = await ClickyFixtures.call(tools, "open_agent_dashboard", [:])
    #expect(dashboard["status"] == "opened")
    let onJob = await ClickyFixtures.call(tools, "open_agent_dashboard", ["job_id": "Scribe"])
    #expect(onJob["link"] == "openclicky://job/scribe")
    let closed = await ClickyFixtures.call(tools, "open_agent_dashboard", ["action": "close"])
    #expect(closed["status"] == "closed")
    #expect(opened.links == ["openclicky://home/agents", "openclicky://job/scribe", nil])
    // The links the tool opens are ones the app's router accepts.
    #expect(OpenClickyURLRouter.parse("openclicky://home/agents").route == .home("agents"))
    #expect(OpenClickyURLRouter.parse("openclicky://job/\(scribe.id)").route == .job("scribe"))

    // Brain and realtime kinds: the reads need a round, the openers wait for the narration.
    let registry = ToolRegistry(ToolRegistry.agentTools(tools))
    #expect(registry.tool(named: "clicky_memory")?.kind == .read)
    #expect(registry.tool(named: "clicky_artifacts")?.kind == .read)
    #expect(registry.tool(named: "open_artifact")?.kind == .deferredAction)
    #expect(registry.tool(named: "open_agent_dashboard")?.kind == .deferredAction)
    #expect(registry.tool(named: "clicky_archive")?.kind == .action)
}

@Test func archiveSurvivesARelaunchAndOnlyAppliesToIdleKeptAgents() async throws {
    let temp = AgentTempDir()
    let store = AgentJobStore(paths: temp.paths)
    _ = try ClickyFixtures.scribe(store)
    let job = try store.createJob(task: "One-off task", title: "One-off", harness: .codex, model: nil, provider: "harness-login")
    let first = AgentManager(store: store) { _ in throw AgentManagerError.emptyTask }
    let tools = AgentTools(manager: first)

    let archived = await ClickyFixtures.call(tools, "clicky_archive", ["agent": "Scribe", "action": "archive"])
    #expect(archived["status"] == "archived")
    let notKept = await ClickyFixtures.call(tools, "clicky_archive", ["agent": .string(job.id), "action": "archive"])
    #expect(notKept["status"] == "error" && notKept["message"]?.stringValue?.contains("not a kept agent") == true)

    // A relaunch: a new manager over the same folders.
    let second = AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in throw AgentManagerError.emptyTask }
    let reloaded = try #require(await second.job("scribe"))
    #expect(reloaded.isArchived)
    #expect(AgentBrainContext.clickysNote(jobs: await second.jobs(), running: [])?.contains("Archived (routing work") == true)
    let memory = await ClickyFixtures.call(AgentTools(manager: second), "clicky_memory", ["agent": "Scribe"])
    #expect(memory["is_archived"] == true)

    let back = await ClickyFixtures.call(AgentTools(manager: second), "clicky_archive", ["agent": "Scribe", "action": "unarchive"])
    #expect(back["status"] == "unarchived")
    #expect(await AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in throw AgentManagerError.emptyTask }.job("scribe")?.isArchived == false)
}

@Test func aBusyKeptAgentCantBeArchived() async throws {
    let gate = BrainGate()
    let rig = ScriptedRig { session in
        await gate.wait()
        await session.finish("Done.")
    }
    _ = try await rig.manager.spawn(AgentSpawnRequest(task: "Keep watching prices", agent: "Scout", keep: true), waitForStart: true)
    await #expect(throws: AgentManagerError.busy("scout")) { try await rig.manager.archive("Scout") }
    gate.open()
}

@Test func sessionsSendToAnArchivedKeptAgentRevivesIt() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    _ = try ClickyFixtures.scribe(rig.manager.store)
    try await rig.manager.archive("scribe")
    let tools = AgentTools(manager: rig.manager)
    let sent = await ClickyFixtures.call(tools, "sessions_send", ["job_id": "Scribe", "message": "Add a section on the book club"])
    #expect(sent["status"] == "sent" && sent["revived"] == true)
    #expect(sent["message"]?.stringValue?.contains("was archived and is back") == true)
    #expect(await rig.manager.job("scribe")?.isArchived == false)
}

@Test func aScriptedVoiceTurnRoutesWorkToAnArchivedClickyAndRevivesIt() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.\n\n<report>\nsay: The November draft is ready.\n</report>") }
    _ = try ClickyFixtures.scribe(rig.manager.store)
    try await rig.manager.archive("Scribe")
    let coordinator = AgentCoordinator(manager: rig.manager, routineStore: RoutineStore(url: rig.temp.url.appendingPathComponent("routines.json")),
                                       onReports: { _ in })
    let model = BrainScriptModel([
        [.text("```js\nsay(\"I'll have Scribe draft it.\")\n"),
         .call("c1", "sessions_spawn", #"{"task":"Draft the November newsletter","agent":"Scribe","include_screen":false}"#),
         .text("\n```"), .finish(.toolCalls)],
    ])
    let runtime = BrainContextFixtures.runtime(model, tools: ToolRegistry.agentTools(coordinator.tools),
                                               sources: BrainContextSources(turnNotes: BrainWiring.jobNotes(coordinator)))
    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("have scribe draft the november newsletter"))
    let heard = BrainContextFixtures.lastUserText(try #require(model.requests.first))
    #expect(heard.contains("[Your Clickys]"))
    #expect(heard.contains("Archived (routing work to one brings it back; tell the user when that happens): Scribe (scribe)"))

    #expect(await agentEventually { rig.harness.launches.count == 1 })
    let launch = try #require(rig.harness.launches.first)
    #expect(launch.launch.folder.path.hasSuffix("agents/scribe"))
    #expect(launch.message.contains("Draft the November newsletter"))
    let revived = try #require(await rig.manager.job("scribe"))
    #expect(!revived.isArchived)
    #expect(await agentEventually { await rig.manager.job("scribe")?.runs.count == 2 })

    // The next turn hears Scribe back in the list, not among the archived.
    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("thanks"))
    let next = BrainContextFixtures.lastUserText(model.requests[1])
    #expect(next.contains("- Scribe (scribe), newsletter writer"))
    #expect(!next.contains("Archived ("))
}

@Test func spawnResultSaysTheKeptAgentWasRevived() async throws {
    let rig = ScriptedRig { session in await session.finish("Done.") }
    _ = try ClickyFixtures.scribe(rig.manager.store)
    try await rig.manager.archive("Scribe")
    let tools = AgentTools(manager: rig.manager)
    let result = await ClickyFixtures.call(tools, "sessions_spawn", ["task": "Draft the December newsletter", "agent": "Scribe", "include_screen": false])
    #expect(result["status"] == "dispatched")
    #expect(result["revived"] == true)
    #expect(result["message"]?.stringValue?.hasPrefix("Scribe was archived and is back in the list now") == true)
}

@Test func aRoutineRunsOnAnArchivedKeptAgentWithoutBringingItBack() async throws {
    // Archiving keeps a kept agent's routines; their scheduled runs used to un-archive it every time, unannounced.
    let rig = ScriptedRig { session in await session.finish("Done.") }
    _ = try ClickyFixtures.scribe(rig.manager.store)
    try await rig.manager.archive("Scribe")
    let updates = await rig.manager.subscribe()
    let routine = AgentRoutine(id: "weekly", title: "Weekly", task: "Draft the weekly newsletter", schedule: .every(minutes: 60), agent: "Scribe")
    let id = try await rig.manager.runRoutine(routine, runNumber: 1)
    #expect(id == "scribe")
    _ = await nextAgentReport(updates, for: id)
    let after = try #require(await rig.manager.job("scribe"))
    #expect(after.runs.count == 2 && after.runs.last?.routineID == "weekly")
    #expect(after.isArchived, "still archived after its routine ran")
    // Work the user routes to it still brings it back.
    let spawned = try await rig.manager.spawn(AgentSpawnRequest(task: "Draft the December newsletter", agent: "Scribe"))
    #expect(spawned.revived)
}
