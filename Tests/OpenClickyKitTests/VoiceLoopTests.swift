import Foundation
import Testing
@testable import OpenClickyKit

// Whole turns through the real TurnOrchestrator, LineNarrator and SpeechPlayer, with a scripted brain, fake voices,
// a fake playback clock, a silent mic with a scripted transcript, a still screenshot and a recording drawing.

@MainActor
@Test func voiceTurnSpeaksLinesInOrderPacesTheDrawingAndRunsDeferredActionsAfter() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["First line.", "Second line.", "Third line."], deferred: ["open_url"])])
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    let record = try #require(rig.records.first)

    // The brain got the words, the screenshot and the context.
    let input = try #require(rig.brain.inputs.first)
    #expect(input.words == "what does this button do")
    #expect(!input.isTyped)
    #expect(input.screenshots.count == 1)
    #expect(input.context.frontApp == "Safari")
    #expect(rig.brain.prewarms == 1)
    #expect(rig.screen.prefetches == 1)
    #expect(rig.microphone.starts == 1 && rig.microphone.stops >= 1)

    // One line at a time, in order, through the voice slot.
    #expect(rig.voice.spoken == ["First line.", "Second line.", "Third line."])
    #expect(rig.fallback.spoken.isEmpty)

    // The drawing began with speech pacing and heard each line start and finish, in order.
    let pacing = rig.trace.all.filter { $0.hasPrefix("draw.line") }
    #expect(pacing == ["draw.lineStarted:0", "draw.lineFinished:0", "draw.lineStarted:1", "draw.lineFinished:1",
                       "draw.lineStarted:2", "draw.lineFinished:2"])
    #expect(rig.trace.filtered("draw.begin") == ["draw.begin:speech"])
    let drawing = try #require(rig.surfaces.drawings.first)
    #expect(drawing.program.contains("say(\"Second line.\")"))
    #expect(drawing.options?.width == 320 && drawing.options?.height == 200)

    // The deferred action ran once the narration was over.
    let deferredAt = try #require(rig.trace.index(of: "deferred:open_url"))
    let lastLine = try #require(rig.trace.index(of: "draw.lineFinished:2"))
    #expect(deferredAt > lastLine)
    #expect(record.deferred.map(\.succeeded) == [true])

    #expect(record.outcome == .completed)
    #expect(record.narration?.heardEverything == true)
    #expect(rig.brain.notes.isEmpty)
    #expect(rig.orchestrator.phase == .idle)
    #expect(record.history?.spokenLines == ["First line.", "Second line.", "Third line."])
    #expect(record.history?.outcome == .completed)

    // Phases went the documented way.
    var phases: [TurnPhase] = []
    for display in rig.displays where phases.last != display.phase { phases.append(display.phase) }
    #expect(phases == [.listening, .transcribing, .capturing, .requesting, .speaking, .idle])

    // Every timing mark was taken.
    let timings = record.timings
    #expect(timings.releaseToTranscriptMs != nil)
    #expect(timings.requestToFirstTokenMs != nil)
    #expect(timings.firstTokenToFirstLineMs != nil)
    #expect(timings.firstLineToFirstAudioMs != nil)
    #expect(timings.originToFirstLineHeardMs != nil)
    #expect(timings.totalMs != nil)
    #expect(timings.report().contains("release → first line heard"))
}

@MainActor
@Test func liveTranscriptGrowsWhileTheKeysAreHeld() async throws {
    let rig = VoiceLoopRig(heard: "show me the share button please", scripts: [ScriptedBrain.program(["Here."])])
    rig.orchestrator.pressBegan()
    #expect(await rig.wait { rig.orchestrator.display.liveTranscript.split(separator: " ").count >= 3 })
    rig.orchestrator.pressEnded()
    #expect(await rig.waitForRecords(1))
    let transcripts = rig.displays.map(\.liveTranscript).filter { !$0.isEmpty }
    #expect(transcripts.first.map { $0.split(separator: " ").count < 6 } == true)
    #expect(rig.brain.inputs.first?.words == "show me the share button please")
}

@MainActor
@Test func bargeInMidLineStopsTheVoiceAndTellsTheBrainWhereItWasCut() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["One.", "Two.", "Three."], deferred: ["open_url"]),
                                     ScriptedBrain.program(["New answer."])],
                           voiceSeconds: 0.6)
    await rig.ask()
    #expect(await rig.wait { rig.started(1) })
    // Line 2 is playing: press again.
    rig.orchestrator.pressBegan()
    #expect(rig.records.count == 1)
    let cut = try #require(rig.records.first)
    guard case .cutOff(let by, let heard, let cutLine, let total) = cut.outcome else {
        Issue.record("expected a cut-off, got \(cut.outcome)")
        return
    }
    #expect(by == .newPress)
    #expect(heard == 1)
    #expect(cutLine == 1)
    #expect(total == 3)
    #expect(cut.narration?.stopped == true)
    #expect(rig.trace.all.contains("draw.cancel"))
    // The deferred action was dropped, not run.
    #expect(cut.deferred.map(\.succeeded) == [nil])
    #expect(!rig.trace.all.contains("deferred:open_url"))
    // The brain had finished; the history notes that the narration was cut.
    #expect(cut.history?.narration?.contains("cut off") == true)
    #expect(rig.orchestrator.phase == .listening)

    try await Task.sleep(for: .milliseconds(100))
    rig.orchestrator.pressEnded()
    #expect(await rig.waitForRecords(2))
    // The note reached the brain before the new turn's request.
    let note = try #require(rig.brain.notes.first)
    #expect(note.contains("pressed the talk keys again"))
    #expect(note.contains("line 2 of 3"))
    #expect(note.contains("\"Three.\""))
    #expect(rig.trace.index(of: "brain.note")! < rig.trace.all.lastIndex(of: "brain.run:what does this button do")!)
    // "Three." was never heard (the voice may have synthesized it ahead).
    #expect(cut.narration?.started == [0, 1])
    #expect(rig.voice.spoken.last == "New answer.")
}

@MainActor
@Test func bargeInBeforeTheFirstLineDropsTheAnswer() async throws {
    var slow = ScriptedBrain.program(["Too late."])
    slow[0].delay = 1.0
    let rig = VoiceLoopRig(scripts: [slow, ScriptedBrain.program(["Fresh."])])
    await rig.ask()
    #expect(await rig.wait { rig.orchestrator.phase == .requesting })
    rig.orchestrator.pressBegan()
    let record = try #require(rig.records.first)
    #expect(record.outcome == .droppedBeforeFirstLine(.newPress))
    rig.orchestrator.pressCancelled()
    #expect(await rig.wait { rig.brain.notes.count == 1 })
    #expect(rig.brain.notes.first?.contains("none of it was heard") == true)
    #expect(rig.voice.spoken.isEmpty)
}

@MainActor
@Test func escapeStopsTheTurnThenClearsTheDrawingThenPassesThrough() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["One.", "Two."])], voiceSeconds: 0.6)
    await rig.ask()
    #expect(await rig.wait { rig.started(0) })
    #expect(rig.orchestrator.canInterrupt)
    #expect(rig.orchestrator.interrupt())
    #expect(rig.orchestrator.phase == .idle)
    guard case .cutOff(.escape, 0, 0, _)? = rig.records.first?.outcome else {
        Issue.record("expected a cut-off by Escape during line 1, got \(String(describing: rig.records.first?.outcome))")
        return
    }
    #expect(rig.clock.player.isIdle)
    // The drawing stays until a second Escape.
    #expect(rig.orchestrator.canInterrupt)
    #expect(rig.orchestrator.interrupt())
    #expect(rig.surfaces.cleared == 1)
    #expect(!rig.orchestrator.canInterrupt)
    #expect(!rig.orchestrator.interrupt())
    #expect(await rig.wait { rig.brain.notes.count == 1 })
    #expect(rig.brain.notes.first?.contains("pressed Escape") == true)
}

@MainActor
@Test func nothingHeardSaysSoAndNeverCallsTheBrain() async throws {
    let rig = VoiceLoopRig(heard: "", scripts: [ScriptedBrain.program(["Unused."])])
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    #expect(rig.records.first?.notice == .nothingHeard)
    #expect(rig.records.first?.outcome == .notStarted)
    #expect(rig.orchestrator.display.notice == .nothingHeard)
    #expect(rig.brain.inputs.isEmpty)
    #expect(rig.screen.cancelledPrefetches == 1)
    #expect(rig.voice.spoken.isEmpty)
}

@MainActor
@Test func aDroppedSpeechConnectionSaysSo() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Unused."])])
    rig.stt = SimulatedSpeechToText(text: "hello there", behavior: .dropAtFinish("socket closed"), chunksPerWord: 10_000)
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    let notice = try #require(rig.records.first?.notice)
    #expect(notice.title.contains("lost the speech connection"))
    #expect(rig.brain.inputs.isEmpty)

    // A session that can't even start says the same.
    rig.stt = SimulatedSpeechToText(text: "hello", behavior: .failToStart("no route to host"))
    await rig.ask()
    #expect(await rig.waitForRecords(2))
    #expect(rig.records.last?.notice?.title.contains("lost the speech connection") == true)

    // A final transcript that never comes times out, keeping the words heard so far.
    rig.orchestrator.settings.transcriptTimeout = 1.5
    rig.stt = SimulatedSpeechToText(text: "open my calendar", behavior: .neverFinish, chunksPerWord: 1)
    await rig.ask(holding: 0.2)
    #expect(await rig.waitForRecords(3))
    #expect(rig.brain.inputs.first?.words == "open my calendar")
}

@MainActor
@Test func aShortTapIsDroppedQuietly() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Unused."])])
    rig.orchestrator.pressBegan()
    rig.orchestrator.pressCancelled()
    #expect(rig.orchestrator.phase == .idle)
    #expect(rig.microphone.stops >= 1)
    #expect(rig.screen.cancelledPrefetches == 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.brain.inputs.isEmpty)
    #expect(rig.records.isEmpty)
    #expect(rig.orchestrator.display.notice == nil)
}

@MainActor
@Test func aBrainFailureIsSpokenAfterWhatWasAlreadySaid() async throws {
    let script: [ScriptedBrain.Step] = [
        .init(delay: 0.02, event: .programDelta("say(\"Let me look.\")\n")),
        .init(delay: 0, event: .sayLine(index: 0, text: "Let me look.")),
        .init(delay: 0.05, event: .failed(spoken: "Sorry, I couldn't get an answer just now.", detail: "HTTP 529 overloaded")),
    ]
    let rig = VoiceLoopRig(scripts: [script])
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    let record = try #require(rig.records.first)
    #expect(rig.voice.spoken == ["Let me look.", "Sorry, I couldn't get an answer just now."])
    #expect(record.outcome == .failed("Sorry, I couldn't get an answer just now."))
    #expect(record.failure?.detail == "HTTP 529 overloaded")
    #expect(rig.orchestrator.display.notice?.tone == .error)
    #expect(record.history?.outcome == .failed)
}

@MainActor
@Test func aTypedQuestionDrawsAtOnceAndIsNotReadAloudByDefault() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Typed answer one.", "Typed answer two."])])
    rig.orchestrator.submitTyped("  how do I share this?  ")
    #expect(await rig.waitForRecords(1))
    let input = try #require(rig.brain.inputs.first)
    #expect(input.words == "how do I share this?")
    #expect(input.isTyped)
    #expect(rig.voice.spoken.isEmpty)
    #expect(rig.trace.filtered("draw.begin") == ["draw.begin:now"])
    #expect(rig.orchestrator.display.lines == ["Typed answer one.", "Typed answer two."])
    #expect(rig.records.first?.history?.source == .text)
    #expect(rig.records.first?.timings.originToBrainFinishedMs != nil)

    // With "read typed answers aloud" on, it speaks and paces like a voice turn.
    rig.orchestrator.settings.speaksTypedAnswers = true
    rig.orchestrator.submitTyped("again please")
    #expect(await rig.waitForRecords(2))
    #expect(rig.voice.spoken == ["Typed answer one.", "Typed answer two."])
    #expect(rig.trace.filtered("draw.begin").last == "draw.begin:speech")
}

@MainActor
@Test func aJobReportWaitsUntilTheUserIsDoneThenRunsAsAnAppTurn() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Answer."]), ScriptedBrain.program(["Your report is ready."])])
    rig.orchestrator.pressBegan()
    rig.orchestrator.runReportTurn(note: "[Jobs came back] one job finished")
    try await Task.sleep(for: .milliseconds(80))
    rig.orchestrator.pressEnded()
    #expect(await rig.waitForRecords(2, timeout: 15))
    #expect(rig.brain.inputs.count == 2)
    let report = rig.brain.inputs[1]
    #expect(report.words.isEmpty)
    #expect(report.context.trigger == "job_report")
    #expect(report.appNotes.contains("[Jobs came back] one job finished"))
    #expect(rig.records.last?.kind == .report)
    #expect(rig.records.last?.history?.source == .app)
    #expect(rig.voice.spoken == ["Answer.", "Your report is ready."])
}

@MainActor
@Test func microphoneAndListeningProblemsAreExplained() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Unused."])])
    rig.microphone.failure = "Microphone access is off for OpenClicky."
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    #expect(rig.records.first?.notice?.title == "I couldn't open the microphone.")
    #expect(rig.records.first?.notice?.detail == "Microphone access is off for OpenClicky.")

    rig.microphone.failure = nil
    rig.orchestrator.services.speechToText = { throw EngineFactoryError.slotEmpty(.stt) }
    await rig.ask()
    #expect(await rig.waitForRecords(2))
    #expect(rig.records.last?.notice?.title == "Listening isn't set up yet.")
    #expect(rig.brain.inputs.isEmpty)
}

// MARK: - Narrator health and fallback

@MainActor
@Test func aSilentFirstLineReopensTheVoiceAndSendsTheLineAgain() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Hello there.", "Second."])],
                           policy: LineNarrator.Policy(firstAudioTimeout: 0.8))
    rig.voice.then(.silent)
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    #expect(rig.voice.spoken == ["Hello there.", "Hello there.", "Second."])
    #expect(rig.voice.stopAlls == 1)
    #expect(rig.voice.warmUps >= 2)
    #expect(rig.voiceEvents.contains { if case .reopened(0, _) = $0 { true } else { false } })
    #expect(rig.records.first?.narration?.resentLines == [0])
    #expect(rig.records.first?.outcome == .completed)
    #expect(rig.fallback.spoken.isEmpty)
}

@MainActor
@Test func aFailingVoiceFallsBackToTheAppleVoiceForTheRestOfTheTurnAndLater() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["One.", "Two."]), ScriptedBrain.program(["Later."])])
    rig.voice.always(.fail("overloaded"))
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    // Tried, reopened and tried again, then the fallback spoke it and everything after.
    #expect(rig.voice.spoken == ["One.", "One."])
    #expect(rig.fallback.spoken == ["One.", "Two."])
    #expect(rig.records.first?.narration?.fallbackLines == [0, 1])
    #expect(rig.records.first?.narration?.heardEverything == true)
    #expect(rig.narrator.isUsingFallback)
    #expect(rig.orchestrator.display.usingFallbackVoice)
    // The next turn keeps using the fallback for a while.
    await rig.ask()
    #expect(await rig.waitForRecords(2))
    #expect(rig.fallback.spoken.last == "Later.")
    #expect(rig.voice.spoken.count == 2)
}

@MainActor
@Test func aLineNoVoiceCanSayStillTakesItsTurnSoTheDrawingKeepsPace() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Lost line.", "Spoken line."])],
                           policy: LineNarrator.Policy(firstAudioTimeout: 0.2, wordsPerSecond: 20))
    rig.voice.then(.fail("down"), .fail("still down"))
    rig.fallback.then(.fail("apple voice missing"))
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    let narration = try #require(rig.records.first?.narration)
    #expect(narration.failedLines == [0])
    #expect(narration.finished == [0, 1])
    #expect(rig.trace.all.filter { $0.hasPrefix("draw.line") } == ["draw.lineStarted:0", "draw.lineFinished:0",
                                                                    "draw.lineStarted:1", "draw.lineFinished:1"])
}

// MARK: - Timings and outcome notes

@Test func timingReportListsTheStepsInOrder() {
    var timings = TurnTimings(kind: .voice)
    let start = Date(timeIntervalSince1970: 1000)
    timings.pressedAt = start
    timings.releasedAt = start.addingTimeInterval(2)
    timings.transcriptAt = start.addingTimeInterval(2.3)
    timings.captureStartedAt = start.addingTimeInterval(2.3)
    timings.captureFinishedAt = start.addingTimeInterval(2.45)
    timings.requestStartedAt = start.addingTimeInterval(2.5)
    timings.firstTokenAt = start.addingTimeInterval(3.2)
    timings.firstLineAt = start.addingTimeInterval(3.5)
    timings.firstAudioAt = start.addingTimeInterval(4.0)
    timings.firstLineHeardAt = start.addingTimeInterval(4.1)
    timings.finishedAt = start.addingTimeInterval(9)
    #expect(timings.steps.map(\.0) == ["held", "release → transcript", "screen capture", "transcript → request", "request → first token",
                                       "first token → first line", "first line → first audio", "first audio → heard",
                                       "release → first line heard", "total"])
    #expect(timings.releaseToTranscriptMs == 300)
    #expect(timings.originToFirstLineHeardMs == 2100)
    #expect(timings.json["request_to_first_token_ms"]?.intValue == 700)
}

@Test func outcomeNotesSayWhatWasAndWasNotHeard() {
    let lines = ["Click Share.", "Then pick Mail.", "Add a subject.", "Send it."]
    let note = NarrationOutcome.cutOff(by: .escape, heard: 1, cutLine: 1, total: 4).note(lines: lines)
    #expect(note?.hasPrefix("[App] The user pressed Escape") == true)
    #expect(note?.contains("during line 2 of 4 (\"Then pick Mail.\")") == true)
    #expect(note?.contains("Not heard: \"Add a subject.\" \"Send it.\"") == true)
    #expect(NarrationOutcome.completed.note(lines: lines) == nil)
    #expect(NarrationOutcome.droppedBeforeFirstLine(.typed).note(lines: [])?.contains("typed a new question") == true)
}
