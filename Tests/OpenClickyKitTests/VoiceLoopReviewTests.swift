import Foundation
import Testing
@testable import OpenClickyKit

// Review checks for the voice loop: job reports that arrive while the user is pressing the keys, and the order of
// barge-in notes and requests when a turn is replaced before it reaches the brain.

@MainActor
@Test func aJobReportThatArrivedDuringABrushOfTheKeysStillRuns() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Your report is ready."])])
    rig.orchestrator.pressBegan()
    rig.orchestrator.runReportTurn(note: "[Jobs came back] one job finished")
    // The keys were only brushed: no turn ran, so nothing else will start the queued report.
    rig.orchestrator.pressCancelled()
    #expect(await rig.waitForRecords(1, timeout: 10))
    #expect(rig.records.first?.kind == .report)
    #expect(rig.brain.inputs.first?.appNotes.contains("[Jobs came back] one job finished") == true)
}

@MainActor
@Test func aJobReportThatArrivedWhileHoldingTheKeysRunsAfterEscape() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Your report is ready."])])
    rig.orchestrator.pressBegan()
    rig.orchestrator.runReportTurn(note: "[Jobs came back] one job finished")
    #expect(rig.orchestrator.interrupt())
    #expect(await rig.waitForRecords(1, timeout: 10))
    #expect(rig.records.first?.kind == .report)
}

@MainActor
@Test func reportsQueuedWhileBusyAreToldTogetherWhenANewReportFindsTheLoopIdle() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Both jobs are done."])])
    rig.orchestrator.pressBegan()
    rig.orchestrator.runReportTurn(note: "[Jobs came back] job A finished")
    rig.orchestrator.pressCancelled()
    rig.orchestrator.runReportTurn(note: "[Jobs came back] job B finished")
    #expect(await rig.waitForRecords(1, timeout: 10))
    try await Task.sleep(for: .milliseconds(600))
    // One report turn carries both notes; neither is lost or told twice.
    let notes = rig.brain.inputs.flatMap(\.appNotes).filter { $0.hasPrefix("[Jobs came back]") }
    #expect(notes.sorted() == ["[Jobs came back] job A finished", "[Jobs came back] job B finished"])
    #expect(rig.records.filter { $0.kind == .report }.count == 1)
}

@MainActor
@Test func aNewPressWhileTheLastOneIsStillTranscribingDropsTheOldWords() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Second answer."])])
    rig.orchestrator.settings.transcriptTimeout = 3
    rig.stt = SimulatedSpeechToText(text: "first question", behavior: .neverFinish, chunksPerWord: 1)
    await rig.ask(holding: 0.15)
    #expect(rig.orchestrator.phase == .transcribing)
    rig.stt = SimulatedSpeechToText(text: "second question", chunksPerWord: 1)
    await rig.ask(holding: 0.15)
    #expect(await rig.wait(10) { rig.records.count >= 2 && !rig.orchestrator.isBusy })
    #expect(rig.brain.inputs.map(\.words) == ["second question"])
    #expect(rig.records.first?.outcome == .notStarted)
    // Nothing was said in the dropped turn, so there is nothing to tell the brain about it.
    #expect(rig.brain.notes.isEmpty)
}

@MainActor
@Test func aTypedQuestionCutsTheVoiceOffAndTheNoteReachesTheBrainBeforeTheTypedRequest() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["One.", "Two.", "Three."]), ScriptedBrain.program(["Typed answer."])],
                           voiceSeconds: 0.6)
    await rig.ask()
    #expect(await rig.wait { rig.started(0) })
    rig.orchestrator.submitTyped("and in French?")
    #expect(await rig.waitForRecords(2, timeout: 15))
    guard case .cutOff(.typed, _, _, _)? = rig.records.first?.outcome else {
        Issue.record("expected a cut-off by a typed question, got \(String(describing: rig.records.first?.outcome))")
        return
    }
    let note = try #require(rig.trace.index(of: "brain.note"))
    let typed = try #require(rig.trace.index(of: "brain.run:and in French?"))
    #expect(note < typed)
    // Typed answers aren't read aloud by default.
    #expect(!rig.voice.spoken.contains("Typed answer."))
}

/// `occtl turn` writes what the user would hear into a WAV file. Closing the file while the render pump is mid-write
/// must still leave a well-formed file: a RIFF header at the start whose sizes match the bytes after it.
@Test func offlineSpeakersCloseAWellFormedWAVEvenWhileRendering() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-speakers-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for round in 0..<60 {
        let url = folder.appendingPathComponent("voice-\(round).wav")
        let speakers = try OfflineSpeakers(url: url)
        speakers.start(tick: 0.001)
        speakers.player.play(Data(count: 24_000), format: PCMFormat(sampleRate: 24_000), line: 0)
        // Close at a different point in the pump's cycle each round.
        Thread.sleep(forTimeInterval: 0.005 + Double(round % 13) * 0.00037)
        try speakers.finish()
        Thread.sleep(forTimeInterval: 0.01)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count >= 44)
        #expect(String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE")
        let dataSize = bytes[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(dataSize) == bytes.count - 44, "round \(round): header says \(dataSize) data bytes, file has \(bytes.count - 44)")
    }
}
