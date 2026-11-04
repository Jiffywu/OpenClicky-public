import CoreGraphics
import Foundation
@testable import OpenClickyKit
import Testing

// Drawings paced by the voice beyond line starts: pauses in narration gaps and audio stalls, running spoken-word counts,
// and always-on drawings paced by the realtime reply's playback (docs/dsl.md "Pacing").

/// Records every pacing call a drawing gets, on top of `RecordingDrawing`'s.
@MainActor
final class PacedRecordingDrawing: TurnDrawing {
    let trace: VoiceTrace
    private(set) var options: DrawingBeginOptions?
    private(set) var spokenCounts: [Int] = []
    var isDrawing = false
    var onMarks: (([DrawingMark]) -> Void)?

    init(trace: VoiceTrace) { self.trace = trace }

    func begin(_ options: DrawingBeginOptions) {
        self.options = options
        isDrawing = true
        trace.add("draw.begin:\(options.pace.rawValue)")
    }
    func append(_ text: String) { trace.add("draw.append") }
    func end() { trace.add("draw.end") }
    func finishNow() { trace.add("draw.finishNow") }
    func cancel() {
        isDrawing = false
        trace.add("draw.cancel")
    }
    func clear() { isDrawing = false }
    func pause() { trace.add("draw.pause") }
    func resume() { trace.add("draw.resume") }
    func wordsSpoken(_ count: Int) {
        spokenCounts.append(count)
        trace.add("draw.spoken:\(count)")
    }
    nonisolated func lineStarted(_ index: Int, expectedDuration: TimeInterval?) { trace.add("draw.lineStarted:\(index)") }
    nonisolated func lineFinished(_ index: Int) { trace.add("draw.lineFinished:\(index)") }
}

@MainActor
final class PacedSurfaces: TurnDrawingSurfaces {
    let trace: VoiceTrace
    private(set) var drawings: [PacedRecordingDrawing] = []
    private(set) var screenshots: [TurnScreenshot] = []

    init(trace: VoiceTrace) { self.trace = trace }

    func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        screenshots.append(screenshot)
        let drawing = PacedRecordingDrawing(trace: trace)
        drawings.append(drawing)
        return drawing
    }

    var hasVisibleDrawing: Bool { !drawings.isEmpty }
    func clearAll() { drawings.removeAll() }
}

@Suite struct NarrationPacerTests {
    /// A playback position and a clock set by hand.
    @MainActor
    final class Playback {
        var position: SpeechPlayer.Position?
        var now: TimeInterval = 100
    }

    @MainActor
    @Test func gapsAndStallsHoldThePenAndWordsAreCountedAcrossLines() {
        let trace = VoiceTrace()
        let drawing = PacedRecordingDrawing(trace: trace)
        let playback = Playback()
        let pacer = NarrationPacer(policy: .init(gap: 0.3, stall: 0.35), position: { playback.position }, now: { playback.now })
        pacer.drawing = drawing
        pacer.line(0, "Here is the settings button.")
        pacer.line(1, "Click it to open your preferences.")

        // Line 0 plays: words appear as its audio is heard, never its last word before the line ends.
        pacer.lineStarted(0)
        for step in 1...18 {
            playback.now += 0.1
            playback.position = SpeechPlayer.Position(lineIndex: 0, elapsed: Double(step) * 0.1, duration: 2.0)
            pacer.tick()
        }
        #expect(drawing.spokenCounts.last == 4)
        // The audio stands still: a stall pauses the drawing; moving again resumes it.
        playback.now += 0.4
        pacer.tick()
        #expect(pacer.hold == .stall)
        playback.now += 0.05
        playback.position = SpeechPlayer.Position(lineIndex: 0, elapsed: 2.0, duration: 2.0)
        pacer.tick()
        #expect(pacer.hold == nil)
        pacer.lineFinished(0)
        #expect(drawing.spokenCounts.last == 5)

        // Nothing plays for longer than the gap: the drawing pauses until the next line is heard.
        playback.position = nil
        playback.now += 0.2
        pacer.tick()
        #expect(pacer.hold == nil)
        playback.now += 0.2
        pacer.tick()
        #expect(pacer.hold == .gap)
        pacer.lineStarted(1)
        #expect(pacer.hold == nil)
        playback.now += 0.5
        playback.position = SpeechPlayer.Position(lineIndex: 1, elapsed: 0.5, duration: 2.4)
        pacer.tick()
        pacer.lineFinished(1)
        pacer.finish()

        #expect(pacer.beats.filter { $0 == .paused(.stall) }.count == 1)
        #expect(pacer.beats.filter { $0 == .paused(.gap) }.count == 1)
        #expect(pacer.beats.filter { $0 == .resumed }.count == 2)
        #expect(drawing.spokenCounts == drawing.spokenCounts.sorted() && Set(drawing.spokenCounts).count == drawing.spokenCounts.count)
        #expect(drawing.spokenCounts.last == 11)
        #expect(trace.filtered("draw.pause").count == 2 && trace.filtered("draw.resume").count == 2)
    }

    @MainActor
    @Test func finishingNeverLeavesThePenHeldAndADrawingThatJoinsLateCatchesUp() {
        let trace = VoiceTrace()
        let playback = Playback()
        let pacer = NarrationPacer(position: { playback.position }, now: { playback.now })
        pacer.line(0, "One two three.")
        pacer.lineStarted(0)
        pacer.lineFinished(0)
        playback.now += 1
        pacer.tick()
        #expect(pacer.hold == .gap)
        // The drawing begins only now (the program came after the first line): it hears the count and the hold.
        let drawing = PacedRecordingDrawing(trace: trace)
        pacer.drawing = drawing
        #expect(drawing.spokenCounts == [3])
        #expect(trace.all == ["draw.spoken:3", "draw.pause"])
        pacer.finish()
        #expect(trace.all.last == "draw.resume")
        // After finish nothing more reaches the drawing.
        pacer.lineStarted(1)
        pacer.tick()
        #expect(trace.all.count == 3)
    }
}

@Suite struct DrawingPacingTurnTests {
    @MainActor
    @Test func aNarrationGapPausesTheDrawingAndTheNextLineResumesIt() async throws {
        // The brain takes 0.7 s to write each line; each line plays for 0.3 s, so the voice waits between lines.
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["First we open the menu.", "Then we pick a colour."], gap: 0.7)],
                               voiceSeconds: 0.3)
        let surfaces = PacedSurfaces(trace: rig.trace)
        rig.orchestrator.services.drawings = surfaces
        rig.orchestrator.settings.narrationPacing = NarrationPacer.Policy(gap: 0.15, stall: 0.5)
        var log: [String] = []
        rig.orchestrator.onLog = { log.append($0) }
        await rig.ask()
        #expect(await rig.waitForRecords(1))

        let drawing = try #require(surfaces.drawings.first)
        #expect(drawing.options?.pace == .speech)
        let all = rig.trace.all
        let finished0 = try #require(all.firstIndex(of: "draw.lineFinished:0"))
        let started1 = try #require(all.firstIndex(of: "draw.lineStarted:1"))
        let pause = try #require(all.firstIndex(of: "draw.pause"))
        let resume = try #require(all.firstIndex(of: "draw.resume"))
        // Paused in the gap after line 0, resumed when line 1's audio began.
        #expect(finished0 < pause && pause < started1 && started1 < resume)
        #expect(all.filter { $0 == "draw.pause" }.count == all.filter { $0 == "draw.resume" }.count)
        // Spoken words only ever go up and reach every word of the answer.
        #expect(drawing.spokenCounts == drawing.spokenCounts.sorted())
        #expect(Set(drawing.spokenCounts).count == drawing.spokenCounts.count)
        #expect(drawing.spokenCounts.last == 10)
        #expect(log.contains("pacing: paused (gap)") && log.contains("pacing: resumed"))
        // The rest is drawn after the narration, with the pen released first.
        let lastResume = try #require(all.lastIndex(of: "draw.resume"))
        let finishNow = try #require(all.lastIndex(of: "draw.finishNow"))
        #expect(lastResume < finishNow)
    }

    @MainActor
    @Test func aTurnCutOffWhilePausedReleasesThePenBeforeCancelling() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["One line now.", "Another much later."], gap: 1.5),
                                         ScriptedBrain.program(["Ok."])], voiceSeconds: 0.2)
        let surfaces = PacedSurfaces(trace: rig.trace)
        rig.orchestrator.services.drawings = surfaces
        rig.orchestrator.settings.narrationPacing = NarrationPacer.Policy(gap: 0.1, stall: 0.5)
        await rig.ask()
        #expect(await rig.wait(6) { rig.trace.all.contains("draw.pause") })
        _ = rig.orchestrator.interrupt()
        #expect(await rig.waitForRecords(1))
        let all = rig.trace.all
        let resume = try #require(all.lastIndex(of: "draw.resume"))
        let cancel = try #require(all.lastIndex(of: "draw.cancel"))
        #expect(resume < cancel)
    }
}

@Suite struct AlwaysOnDrawingPacingTests {
    @MainActor static var shot: TurnScreenshot { TurnScreenshot(jpeg: StillImageScreen.blankCanvas(width: 320, height: 200), label: "main display", isCursorScreen: true,
                                     pixelSize: CGSize(width: 320, height: 200), displayFrame: CGRect(x: 0, y: 0, width: 320, height: 200)) }

    @MainActor
    @Test func aDrawingStartedByARealtimeReplyIsPacedByItsPlayback() async throws {
        let trace = VoiceTrace()
        let surfaces = PacedSurfaces(trace: trace)
        let clock = PlaybackClockDriver()
        defer { clock.stop() }
        let output = SpeechPlayerRealtimeOutput(player: clock.player)
        let drawing = RealtimeBrainDrawing(surfaces: surfaces, pacing: .init(replyTimeout: 3, quietAfterReply: 0.3))
        drawing.playback = { clock.player.position() }
        let screen = drawing.screen(StaticRealtimeScreenSource(screenshot: Self.shot))
        let observe = drawing.observer

        _ = try await screen.captureCursorScreen()
        observe(.programDelta("say(\"Here is the button.\")\ncircle([40,40], 20)\n"))
        observe(.programDelta("say(\"And here is the menu next to it.\")\nbox(100, 20, 80, 40)\n"))
        observe(.finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: nil, model: "m", firstTokenSeconds: 0, totalSeconds: 0)))
        #expect(await waitUntil { trace.all.contains("draw.end") })
        let paced = try #require(surfaces.drawings.first)
        #expect(paced.options?.pace == .speech)
        // Still playing: the reply hasn't been heard yet.
        #expect(drawing.isDrawing)
        #expect(!trace.all.contains("draw.finishNow"))

        // The realtime voice speaks its reply (1.5 s of audio) through the shared player.
        output.enqueue(Data(count: 24_000 * 2 * 3 / 2), format: .speech24k, itemID: "reply-1")
        output.finishItem("reply-1")
        #expect(await waitUntil { trace.all.contains("draw.finishNow") })
        #expect(!drawing.isDrawing)
        // Words went up as the reply played, then the rest was drawn.
        #expect(paced.spokenCounts.count >= 2)
        #expect(paced.spokenCounts == paced.spokenCounts.sorted())
        #expect((paced.spokenCounts.last ?? 0) >= 3)
        let lastSpoken = try #require(trace.all.lastIndex { $0.hasPrefix("draw.spoken:") })
        #expect(lastSpoken < trace.all.lastIndex(of: "draw.finishNow")!)
    }

    @MainActor
    @Test func withoutAReplyThePacedDrawingIsDrawnOutAfterTheTimeout() async throws {
        let trace = VoiceTrace()
        let surfaces = PacedSurfaces(trace: trace)
        let drawing = RealtimeBrainDrawing(surfaces: surfaces, pacing: .init(replyTimeout: 0.2))
        drawing.playback = { nil }
        let screen = drawing.screen(StaticRealtimeScreenSource(screenshot: Self.shot))
        _ = try await screen.captureCursorScreen()
        drawing.observer(.programDelta("say(\"Here.\")\ncircle([40,40], 20)\n"))
        drawing.observer(.finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: nil, model: "m", firstTokenSeconds: 0, totalSeconds: 0)))
        #expect(await waitUntil { trace.all.contains("draw.finishNow") })
        #expect(trace.all.first == "draw.begin:speech")
        #expect(!drawing.isDrawing)
    }
    /// A brain that streams part of a drawing program, then either stalls until the call is cancelled or breaks off
    /// with an error, never reaching `.finished`.
    final class StallingProgramBrain: BrainTurnRunning, @unchecked Sendable {
        let error: Error?
        init(error: Error? = nil) { self.error = error }

        func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
            let error = error
            return AsyncThrowingStream { continuation in
                continuation.yield(.programDelta("say(\"Here is the button.\")\ncircle([40,40], 20)\n"))
                if let error { continuation.finish(throwing: error) }
                // Otherwise the stream stays open until the consuming task is cancelled.
            }
        }

        func prewarm() async {}
        func recordOutcome(_ note: String) async {}
        func endSession() async {}
    }

    @MainActor
    @Test func aBrainCallCutShortLetsGoOfItsPacedDrawing() async throws {
        for brain in [StallingProgramBrain(), StallingProgramBrain(error: URLError(.networkConnectionLost))] {
            let trace = VoiceTrace()
            let surfaces = PacedSurfaces(trace: trace)
            // A player that never plays: only a terminal event from the call can end the paced drawing.
            let drawing = RealtimeBrainDrawing(surfaces: surfaces, pacing: .init(replyTimeout: 0.2))
            drawing.playback = { nil }
            let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: drawing.screen(StaticRealtimeScreenSource(screenshot: Self.shot)),
                                                       observe: drawing.observer)
            let call = Task {
                await tool.run(RealtimeToolInvocation(callID: "c1", name: RealtimeToolName.sendToHigherModel,
                                                      arguments: ["question": .string("What is this?")]))
            }
            #expect(await waitUntil { trace.all.contains("draw.begin:speech") })
            if brain.error == nil {
                // Stalled and still held; then superseded or timed out: the dispatcher cancels the call.
                try await Task.sleep(for: .milliseconds(400))
                #expect(drawing.isDrawing)
                call.cancel()
            }
            let outcome = await call.value
            #expect(outcome.output["status"] != "answer")
            #expect(await waitUntil { trace.all.contains("draw.cancel") }, "\(trace.all)")
            #expect(!drawing.isDrawing)
        }
    }
}
