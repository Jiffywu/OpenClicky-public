import Foundation
import Testing
@testable import OpenClickyKit

// Agent results: citation stripping, result cards and next-step chips, report turns that fail or say nothing,
// launch labels, task assets, the jobs note in every turn, read_job, and the agent sounds.

@Test func citationMarkersAreStrippedFromReports() {
    let text = "Fares start at $129 \u{E200}cite\u{E202}turn0search3\u{E201}. See [Kayak](turn1search2) and [the airline](https://example.com/fares). "
        + "Prices rose cite turn2news1 turn2news4 this week【4:0†source】."
    let clean = AgentText.stripCitations(text)
    #expect(clean == "Fares start at $129. See Kayak and [the airline](https://example.com/fares). Prices rose this week.")
    // Plain text is untouched.
    #expect(AgentText.stripCitations("Turn left at turn 3 (the second light).") == "Turn left at turn 3 (the second light).")
    let report = AgentFinalReport.parse("Cheapest is $129 turn0search3.\n<report>\nsay: The cheapest fare is $129 \u{E200}cite\u{E202}turn0search3\u{E201}.\nnext:\n- Compare cite turn0search1 return dates\n</report>")
    #expect(report.spoken == "The cheapest fare is $129.")
    #expect(report.markdown == "Cheapest is $129.")
    #expect(report.nextSteps == ["Compare return dates"])
}

@Test func resultCardsShowFilesAndTappableNextSteps() {
    let report = AgentJobReport(jobID: "flights-1", run: 1, title: "Denver Flights", agentName: "Travel Buddy", outcome: .done,
                                spoken: "I found three nonstop flights.", markdown: "## Options\n**United** $129 [link](turn0search1)",
                                files: ["/tmp/jobs/flights-1/output/flights.md", "https://www.kayak.com/flights/SFO-DEN"],
                                nextSteps: ["- Book the cheapest one.", "2. Set a fare alert", "Book the cheapest one", "", String(repeating: "x", count: 90),
                                            "Compare return dates", "Check bags"],
                                startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 130))
    var withKind = report
    withKind.kind = .document
    let card = AgentResultCard(report: withKind)
    #expect(card.chips == ["Book the cheapest one", "Set a fare alert", "Compare return dates"])
    #expect(card.subtitle == "Travel Buddy · done · 2 min")
    #expect(card.body == "## Options\n**United** $129 link")
    #expect(card.files.map(\.name) == ["flights.md", "www.kayak.com/flights/SFO-DEN"])
    #expect(card.files.map(\.isLink) == [false, true])
    #expect(card.symbol == "doc.text")
    #expect(card.question == nil)
    #expect(AgentResultCard.followUp(for: "Set a fare alert") == "Set a fare alert")
    var asking = report
    asking.outcome = .needsYou
    asking.question = "Window or aisle?"
    #expect(AgentResultCard(report: asking).question == "Window or aisle?")
    #expect(AgentResultCard(report: asking).symbol == "questionmark.bubble")
}

@Test func showResultPresentsTheCardAndChipsGoBackToTheSameJob() async throws {
    let rig = ScriptedRig { session in await session.finish(reportText) }
    let shown = ReportBox()
    let tools = AgentTools(manager: rig.manager, presentResult: { shown.add([$0]) })
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Find flights", title: "Flights"), waitForStart: true)
    _ = await nextAgentReport(updates, for: result.record.id)
    let out = await tools.callJSON(name: "show_result", arguments: #"{"job_id":"\#(result.record.id)"}"#)
    #expect(out["status"] == "shown")
    let card = AgentResultCard(report: try #require(shown.batches.first?.first))
    #expect(card.chips == ["Book the cheapest one"])
    // A tapped chip is a follow-up to that job.
    _ = try await rig.manager.send(to: result.record.id, message: AgentResultCard.followUp(for: card.chips[0]))
    #expect(await agentEventually { rig.harness.launches.count == 2 })
    #expect(rig.harness.launches.last?.message.contains("Book the cheapest one") == true)
}

@MainActor
@Test func aFailedReportTurnIsTriedOnceMoreWithoutAnErrorLine() async throws {
    let failing: [ScriptedBrain.Step] = [ScriptedBrain.Step(delay: 0.02, event: .failed(spoken: "Something went wrong.", detail: "HTTP 529"))]
    let rig = VoiceLoopRig(scripts: [failing, ScriptedBrain.program(["Your flights are ready."])])
    rig.orchestrator.runReportTurn(note: "[Jobs came back] one job finished")
    #expect(await rig.wait(15) { rig.records.count >= 2 && !rig.orchestrator.isBusy })
    #expect(rig.brain.inputs.count == 2)
    let retry = rig.brain.inputs[1].appNotes
    #expect(retry.contains("[Jobs came back] one job finished"))
    #expect(retry.contains(TurnOrchestrator.reportRetryNote))
    #expect(rig.voice.spoken == ["Your flights are ready."])
    #expect(rig.records.allSatisfy { $0.kind == .report })
}

@MainActor
@Test func aReportTurnThatSaysNothingIsRetriedThenShownAnotherWay() async throws {
    let silent: [ScriptedBrain.Step] = [ScriptedBrain.Step(delay: 0.02, event: .finished(TurnSummary(
        program: "", spokenLines: [], rounds: 1, usage: nil, model: "scripted", firstTokenSeconds: nil, totalSeconds: 0.02)))]
    let rig = VoiceLoopRig(scripts: [silent, silent])
    var undelivered: [[String]] = []
    rig.orchestrator.onReportUndelivered = { undelivered.append($0) }
    let report = AgentJobReport(jobID: "j1", run: 1, title: "Flights", outcome: .done, spoken: "Your flight list is ready.",
                                startedAt: Date(), finishedAt: Date())
    let note = AgentReportTurn.note(for: [report])
    rig.orchestrator.runReportTurn(note: note)
    #expect(await rig.wait(15) { undelivered.count == 1 && !rig.orchestrator.isBusy })
    #expect(rig.brain.inputs.count == 2)
    #expect(undelivered.first == [note])
    #expect(rig.displays.contains { $0.notice?.title == "Your flight list is ready." })
    // Not tried a third time.
    try await Task.sleep(for: .milliseconds(700))
    #expect(rig.brain.inputs.count == 2)
    #expect(AgentReportTurn.fallbackText(notes: ["[Jobs came back] nothing parseable"]) == nil)
}

@Test func launchLabelsNameTheJobAndGiveAStartLine() async throws {
    #expect(ModelAgentLaunchLabeler.parse("```json\n{\"title\": \"Denver Flight Options.\", \"start\": \"I'm looking up flights to Denver.\"}\n```")
        == AgentLaunchLabels(title: "Denver Flight Options", startCue: "I'm looking up flights to Denver."))
    #expect(ModelAgentLaunchLabeler.parse("no json here") == nil)
    #expect(ModelAgentLaunchLabeler.parse(#"{"title": "", "start": "x"}"#) == nil)

    let rig = ScriptedRig { session in
        try? await Task.sleep(nanoseconds: 300_000_000)
        await session.finish(reportText)
    }
    await rig.manager.setLabeler(FakeLabeler(labels: AgentLaunchLabels(title: "Denver Flight Options", startCue: "I'm on the Denver flights.")))
    let updates = await rig.manager.subscribe()
    let launched = LaunchBox()
    let watcher = Task { for await update in updates { if case .launched(let record) = update { launched.add(record.id) } } }
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "find me nonstop flights to denver next tuesday"), waitForStart: true)
    #expect(result.record.title == "find me nonstop flights to denver next tuesday")
    #expect(await agentEventually { await rig.manager.job(result.record.id)?.title == "Denver Flight Options" })
    let record = try #require(await rig.manager.job(result.record.id))
    #expect(record.startCue == "I'm on the Denver flights.")
    #expect(await agentEventually { launched.ids == [result.record.id] })
    // A title the brain gave is kept; only the start line is added.
    let named = try await rig.manager.spawn(AgentSpawnRequest(task: "another task", title: "My Name"), waitForStart: true)
    #expect(await agentEventually { await rig.manager.job(named.record.id)?.startCue != nil })
    #expect(await rig.manager.job(named.record.id)?.title == "My Name")
    watcher.cancel()
}

@Test func sessionsSpawnHandsTheTurnsScreenshotAndFilesToTheJob() async throws {
    let rig = ScriptedRig { session in await session.finish(reportText) }
    let box = AgentTurnAssetsBox()
    let screenshot = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
    box.record(AgentTurnAssets(screenshots: [screenshot], capturedAt: Date()))
    let attachment = rig.temp.url.appendingPathComponent("brief.pdf")
    try Data("pdf".utf8).write(to: attachment)
    let tools = AgentTools(manager: rig.manager, turnAssets: { box.current() })
    let out = await tools.callJSON(name: "sessions_spawn", arguments: #"{"task":"Summarize the brief on my screen","title":"Brief","attachments":["\#(attachment.path)","/no/such/file"]}"#)
    #expect(out["status"] == "dispatched")
    #expect(out["screenshot_attached"] == true)
    #expect(out["attachments"] == 1)
    #expect(await agentEventually { rig.harness.launches.count == 1 })
    let launch = try #require(rig.harness.launches.first)
    let saved = try #require(launch.images.first)
    #expect(saved.path.hasSuffix("harness/task-assets/\(out["job_id"]?.stringValue ?? "")/run-1/screen-1.jpg"))
    #expect(try Data(contentsOf: saved) == screenshot)
    #expect(launch.message.contains("a screenshot of the user's screen") && launch.message.contains(attachment.path))

    // include_screen false: no screenshot; stale assets aren't used either.
    let none = await tools.callJSON(name: "sessions_spawn", arguments: #"{"task":"Something unrelated","include_screen":false}"#)
    #expect(none["screenshot_attached"] == nil)
    box.record(AgentTurnAssets(screenshots: [screenshot], capturedAt: Date(timeIntervalSinceNow: -3600)))
    #expect(box.current() == nil)
}

@Test func readJobReturnsTheReportOrTheConversation() async throws {
    let rig = ScriptedRig { session in
        await session.emit(.commentary("Checking three airlines first."))
        await session.emit(.progress("Searching: SFO to DEN"))
        await session.finish(reportText)
    }
    let tools = AgentTools(manager: rig.manager)
    let updates = await rig.manager.subscribe()
    let result = try await rig.manager.spawn(AgentSpawnRequest(task: "Flights", title: "Flights"), waitForStart: true)
    _ = await nextAgentReport(updates, for: result.record.id)
    let report = await tools.callJSON(name: "read_job", arguments: #"{"job_id":"\#(result.record.id)"}"#)
    #expect(report["status"] == "ok")
    #expect(report["report"]?.stringValue?.contains("Found three options.") == true)
    #expect(report["next"] == ["Book the cheapest one"])
    let conversation = await tools.callJSON(name: "read_job", arguments: #"{"job_id":"\#(result.record.id)","detail":"conversation"}"#)
    let lines = conversation["conversation"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(lines.contains("commentary: Checking three airlines first."))
    #expect(lines.contains("progress: Searching: SFO to DEN"))
    #expect(lines.last?.hasPrefix("final: Found three options.") == true)
    #expect(AgentTools.names.contains("read_job"))
    #expect(ToolRegistry.agentTools(tools).first { $0.name == "read_job" }?.kind == .read)
}

@MainActor
@Test func everyTurnCarriesTheJobsNoteAndRecordsItsScreenshot() async throws {
    let still = StillImageScreen(imageData: StillImageScreen.blankCanvas(width: 64, height: 40), context: TurnContext(frontApp: "Safari"))
    let box = AgentTurnAssetsBox()
    let screen = AgentContextScreen(base: still, assets: box, context: { "[Your jobs] Background work.\n- j1 \"Flights\": WORKING NOW" })
    let look = await screen.look()
    #expect(look.appNotes.last == "[Your jobs] Background work.\n- j1 \"Flights\": WORKING NOW")
    #expect(box.current()?.screenshots.first == look.cursorScreenshot?.jpeg)

    // The note lists what running jobs last said, for the brain only.
    var record = AgentJobRecord(id: "j1", kind: .job, title: "Flights", task: "Flights", harness: .codex, model: nil, provider: "x",
                                status: .running, createdAt: Date(), updatedAt: Date(), runs: [AgentRun(ask: "x", startedAt: Date())],
                                folderPath: "/tmp/j1")
    record.lastProgress = "Searching: SFO to DEN"
    record.lastSaid = "Checking three airlines first."
    let note = try #require(AgentBrainContext.note(jobs: [record], running: ["j1"]))
    #expect(note.contains("don't read this out"))
    #expect(note.contains("latest: Searching: SFO to DEN, it said: \"Checking three airlines first.\""))
}

@Test func theAgentSoundsAreDistinct() {
    let rate = 24_000.0
    let launch = UICue.agentLaunch.samples(sampleRate: rate)
    let needs = UICue.agentNeedsYou.samples(sampleRate: rate)
    let done = UICue.agentDone.samples(sampleRate: rate)
    #expect(Set([launch.count, needs.count, done.count]).count == 3)
    #expect(UICue.allCases.contains(.agentLaunch) && UICue.allCases.contains(.agentNeedsYou))
}

@Test func briefsDescribeTheirTaskAssets() {
    let record = AgentJobRecord(id: "j", kind: .job, title: "T", task: "T", harness: .codex, model: nil, provider: "x", status: .queued,
                                createdAt: Date(), updatedAt: Date(), folderPath: "/tmp/j")
    let shot = URL(fileURLWithPath: "/tmp/assets/run-1/screen-1.jpg")
    let image = URL(fileURLWithPath: "/tmp/assets/run-1/image-1.png")
    let brief = AgentInstructions.brief(task: "Do it", record: record, images: [shot, image])
    #expect(brief.contains("a screenshot of the user's screen") && brief.contains(shot.path) && brief.contains(image.path))
    let routine = AgentRoutine(id: "r", title: "Daily", task: "Check", schedule: .every(minutes: 60), createdAt: Date())
    #expect(AgentInstructions.brief(task: "Check", record: record, routine: routine).contains("No screenshot is attached"))
}

final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func add(_ id: String) { lock.withLock { _ids.append(id) } }
}
