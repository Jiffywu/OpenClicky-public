import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// Always-on voice joined to the voice loop: the real TurnOrchestrator, LineNarrator and SpeechPlayer (fake output
// clock), a real AlwaysOnVoiceController and RealtimeConversation on a fake session, one SharedMicrophone over a fake
// device, and the always-on output on the narrator's player.

/// A microphone device that sends silence every 10 ms while open, and logs starts and stops.
final class FakeMicDevice: SharedMicrophoneDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var ticker: Task<Void, Never>?
    private var log: [String] = []

    func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let bytes = format.bytesPerSecond / 100 / 2 * 2
        let ticker = Task {
            while !Task.isCancelled {
                continuation.yield(Data(count: bytes))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        lock.withLock {
            // A stream still open is finished first, like MicrophoneCapture does.
            self.ticker?.cancel()
            self.continuation?.finish()
            self.continuation = continuation
            self.ticker = ticker
            log.append("start:\(format.sampleRate)")
        }
        return stream
    }

    func stop(keepWarm: Bool) {
        lock.withLock {
            ticker?.cancel()
            continuation?.finish()
            continuation = nil
            ticker = nil
            log.append(keepWarm ? "stop:warm" : "stop:cold")
        }
    }

    var level: Float { lock.withLock { continuation == nil ? 0 : 0.4 } }
    var entries: [String] { lock.withLock { log } }
    var isOpen: Bool { lock.withLock { continuation != nil } }
}

/// The voice loop rig plus always-on: what the app's VoiceLoopController puts together.
@MainActor
final class AlwaysOnRig {
    final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var _sessions: [FakeRealtimeVoiceSession] = []
        private var _route: AudioOutputRoute = .headphones
        private var _failBuild = false
        private var _holdConnect = false
        var sessions: [FakeRealtimeVoiceSession] { lock.withLock { _sessions } }
        /// While true, opening a session waits (the provider is slow to answer).
        var holdConnect: Bool {
            get { lock.withLock { _holdConnect } }
            set { lock.withLock { _holdConnect = newValue } }
        }
        var route: AudioOutputRoute {
            get { lock.withLock { _route } }
            set { lock.withLock { _route = newValue } }
        }
        var failBuild: Bool {
            get { lock.withLock { _failBuild } }
            set { lock.withLock { _failBuild = newValue } }
        }
        func add(_ session: FakeRealtimeVoiceSession) { lock.withLock { _sessions.append(session) } }
    }

    let voice: VoiceLoopRig
    let device = FakeMicDevice()
    let microphone: SharedMicrophone
    let shared = Shared()
    var loop: AlwaysOnVoiceLoop!
    private(set) var states: [AlwaysOnState] = []
    /// The notices the app would show for those states.
    private(set) var notices: [TurnNotice] = []
    private(set) var logs: [String] = []

    init(scripts: [[ScriptedBrain.Step]] = [ScriptedBrain.program(["First line.", "Second line."])], voiceSeconds: TimeInterval = 0.25) {
        voice = VoiceLoopRig(scripts: scripts, voiceSeconds: voiceSeconds)
        microphone = SharedMicrophone(device: device)
        voice.orchestrator.services.microphone = microphone.turns
        let shared = shared, player = voice.clock.player, alwaysOnMic = microphone.alwaysOn
        loop = AlwaysOnVoiceLoop(orchestrator: voice.orchestrator) {
            if shared.failBuild { throw EngineFactoryError.slotEmpty(.realtimeVoice) }
            let environment = AlwaysOnVoiceController.Environment(
                connect: { _ in
                    while shared.holdConnect { try await Task.sleep(for: .milliseconds(5)) }
                    let session = FakeRealtimeVoiceSession(inputFormat: .speech24k)
                    shared.add(session)
                    return session
                },
                configuration: { route in
                    RealtimeSessionConfiguration(instructions: "x", turnDetection: .serverVAD(route == .headphones ? .headphones : .speakers))
                },
                toolbox: RealtimeToolbox([]),
                makeOutput: { SpeechPlayerRealtimeOutput(player: player) },
                microphone: alwaysOnMic, outputRoute: { shared.route })
            return AlwaysOnVoiceController(environment: environment)
        }
        loop.willStart = { [unowned self] in
            voice.narrator.release()
            voice.trace.add("alwaysOn.willStart")
        }
        loop.onStateChange = { [unowned self] state in
            states.append(state)
            if let notice = loop.notice(for: state, talkKeys: "⌃⌥", keyPhrase: "Triple-tap Control") { notices.append(notice) }
        }
        loop.onLog = { [unowned self] text in logs.append(text) }
    }

    var orchestrator: TurnOrchestrator { voice.orchestrator }
    var session: FakeRealtimeVoiceSession? { shared.sessions.last }

    /// What the app does with the talk keys going down.
    func pressTalkKeys() {
        if !loop.talkKeysPressed() { orchestrator.pressBegan() }
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        await voice.wait(timeout, until: condition)
    }
}

// MARK: - Shared microphone

@MainActor
@Test func theSharedMicGoesToWhoeverOpenedItLastAndIgnoresStaleStops() throws {
    let device = FakeMicDevice()
    let microphone = SharedMicrophone(device: device)
    _ = try microphone.turns.start(format: .speech16k)
    #expect(microphone.holder == .turns)
    #expect(microphone.turns.level > 0 && microphone.alwaysOn.level == 0)

    // Always-on takes it over; the voice loop's late stop must not close it.
    _ = try microphone.alwaysOn.start(format: .speech24k)
    #expect(microphone.holder == .alwaysOn)
    #expect(microphone.turns.level == 0 && microphone.alwaysOn.level > 0)
    microphone.turns.stop()
    #expect(device.isOpen)
    #expect(device.entries == ["start:16000", "start:24000"])

    // Always-on lets go at once; a press keeps a Bluetooth headset warm.
    microphone.alwaysOn.stop()
    #expect(!device.isOpen && microphone.holder == nil && microphone.level == 0)
    _ = try microphone.turns.start(format: .speech16k)
    microphone.turns.stop()
    microphone.turns.stop()
    #expect(device.entries == ["start:16000", "start:24000", "stop:cold", "start:16000", "stop:warm"])
}

// MARK: - Held turns

@MainActor
@Test func heldTurnsRefusePressesTypingAndWalkthroughStepsAndReportsWaitForTheRelease() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Your report is ready."])])
    rig.orchestrator.holdsTurns = true
    rig.orchestrator.pressBegan()
    #expect(!rig.orchestrator.isBusy && rig.orchestrator.phase == .idle)
    #expect(rig.microphone.starts == 0)
    rig.orchestrator.submitTyped("what is this")
    rig.orchestrator.runGuidedTurn(GuidedTurnRequest(trigger: .clickedTarget, step: 1, remainingRounds: 3, notes: []))
    rig.orchestrator.runReportTurn(note: "[Jobs came back] one job finished")
    try await Task.sleep(for: .milliseconds(600))
    #expect(rig.brain.inputs.isEmpty)
    #expect(!rig.orchestrator.isBusy)

    // Released: the report that waited is told.
    rig.orchestrator.holdsTurns = false
    #expect(await rig.waitForRecords(1))
    #expect(rig.brain.inputs.map(\.context.trigger) == ["job_report"])
    #expect(rig.records.first?.kind == .report)
}

@MainActor
@Test func isListeningIsTrueOnlyWhileAPressIsOpen() async throws {
    // The talk-key monitor asks this to drop a double-tapped question the orchestrator refused or ended another way.
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Fine."])])
    #expect(!rig.orchestrator.isListening)
    rig.orchestrator.holdsTurns = true
    rig.orchestrator.pressBegan()
    #expect(!rig.orchestrator.isListening, "a refused press is not open")
    rig.orchestrator.holdsTurns = false
    rig.orchestrator.pressBegan()
    #expect(rig.orchestrator.isListening)
    rig.orchestrator.submitTyped("what is this")
    #expect(!rig.orchestrator.isListening, "a typed question cut the press off")
    rig.orchestrator.pressBegan()
    #expect(rig.orchestrator.isListening)
    #expect(rig.orchestrator.interrupt())
    #expect(!rig.orchestrator.isListening, "Escape ended it")
    rig.orchestrator.pressBegan()
    rig.orchestrator.pressEnded()
    #expect(!rig.orchestrator.isListening, "let go: the turn runs, the press no longer listens")
    _ = rig.orchestrator.interrupt()
}

// MARK: - Always-on in the loop

@MainActor
@Test func tripleTapStopsTheRunningTurnHoldsTurnsAndTakesTheMicAndVoice() async throws {
    let rig = AlwaysOnRig(voiceSeconds: 1.5)
    // A voice turn is speaking when always-on is switched on.
    await rig.voice.ask()
    #expect(await rig.waitUntil { rig.voice.started(0) })
    rig.loop.toggle()
    #expect(!rig.orchestrator.isBusy)
    #expect(rig.orchestrator.holdsTurns)
    #expect(await rig.voice.waitForRecords(1))
    #expect(rig.voice.records.first?.outcome != .completed)
    #expect(rig.voice.trace.index(of: "alwaysOn.willStart") != nil)
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    #expect(rig.states == [.starting, .on])

    // Always-on holds the mic in its session's format.
    let session = try #require(rig.session)
    #expect(rig.microphone.holder == .alwaysOn)
    #expect(rig.device.entries.last == "start:24000")
    #expect(await rig.waitUntil { session.sentAudioBytes > 0 })
    #expect(rig.loop.display.notch(stopHint: "Triple-tap Control ends it")?.title == "Always-on · listening")

    // Its reply plays on the voice loop's player, and the last turn's narration hears none of it.
    let eventsBefore = rig.voice.voiceEvents.count
    let drawBefore = rig.voice.trace.filtered("draw.line").count
    session.emit(.userSpeechStarted)
    session.emit(.userSpeechStopped)
    session.emit(.userTurnCommitted(itemID: "u1"))
    session.emit(.responseStarted(responseID: "r1"))
    session.emit(.audio(speechTone(seconds: 0.4), itemID: "a1"))
    session.emit(.assistantTranscriptDelta("Paris.", itemID: "a1"))
    #expect(await rig.waitUntil { !rig.voice.clock.player.isIdle })
    #expect(await rig.waitUntil { rig.loop.display.voice == .speaking })
    #expect(rig.loop.display.assistantCaption == "Paris.")
    session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .completed, itemIDs: ["a1"], transcript: "Paris.")))
    #expect(await rig.waitUntil { rig.voice.clock.player.isIdle })
    #expect(rig.voice.voiceEvents.count == eventsBefore)
    #expect(rig.voice.trace.filtered("draw.line").count == drawBefore)

    // Off again: the session closes, the mic is let go and the loop's turns come back.
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .off })
    #expect(session.sent.last == .close)
    #expect(!rig.orchestrator.holdsTurns)
    #expect(rig.microphone.holder == nil)
    #expect(rig.device.entries.last == "stop:cold")
    #expect(rig.states == [.starting, .on, .off])
}

@MainActor
@Test func whileAlwaysOnRunsTheTalkKeysInterruptItsReplyAndStartNoTurn() async throws {
    let rig = AlwaysOnRig()
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    let session = try #require(rig.session)

    // While the user is talking a press throws nothing away (on OpenAI an interrupt clears the buffered speech).
    session.emit(.userSpeechStarted)
    #expect(await rig.waitUntil { rig.loop.display.voice == .userSpeaking })
    rig.pressTalkKeys()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!session.sent.contains { if case .interrupt = $0 { true } else { false } })
    #expect(rig.loop.display.voice == .userSpeaking)
    #expect(!rig.orchestrator.isBusy && rig.voice.brain.inputs.isEmpty)
    rig.orchestrator.pressEnded()
    session.emit(.userSpeechStopped)
    session.emit(.userTurnCommitted(itemID: "u1"))

    session.emit(.responseStarted(responseID: "r1"))
    session.emit(.audio(speechTone(seconds: 2), itemID: "a1"))
    #expect(await rig.waitUntil { rig.loop.display.voice == .speaking && !rig.voice.clock.player.isIdle })
    #expect(rig.loop.display.canInterrupt)

    rig.pressTalkKeys()
    #expect(await rig.waitUntil { session.sent.contains { if case .interrupt(_, _, true) = $0 { true } else { false } } })
    #expect(await rig.waitUntil { rig.voice.clock.player.isIdle })
    #expect(!rig.orchestrator.isBusy)
    #expect(rig.orchestrator.phase == .idle)
    #expect(rig.voice.brain.inputs.isEmpty)
    // The press didn't take the mic from always-on.
    #expect(rig.microphone.holder == .alwaysOn)
    rig.orchestrator.pressEnded()
    rig.orchestrator.pressCancelled()
    #expect(!rig.orchestrator.isBusy)

    // Escape with nothing to stop passes on; while it speaks it stops the reply.
    #expect(await rig.waitUntil { rig.loop.display.voice == .listening })
    #expect(!rig.loop.escape())
    session.emit(.responseStarted(responseID: "r2"))
    session.emit(.audio(speechTone(seconds: 2), itemID: "a2"))
    #expect(await rig.waitUntil { rig.loop.display.voice == .speaking })
    let interruptsBefore = session.sent.filter { if case .interrupt = $0 { true } else { false } }.count
    #expect(rig.loop.escape())
    #expect(await rig.waitUntil { session.sent.filter { if case .interrupt = $0 { true } else { false } }.count > interruptsBefore })

    // A typed question goes into the conversation, answered aloud.
    #expect(rig.loop.submitTyped("  what time is it  "))
    #expect(await rig.waitUntil { session.sent.contains(.text("what time is it", respond: true)) })
    #expect(rig.voice.brain.inputs.isEmpty)
    rig.loop.stop()
    #expect(await rig.waitUntil { rig.loop.display.state == .off })
    // Off, typed questions are the loop's again.
    #expect(!rig.loop.submitTyped("hello"))
}

@MainActor
@Test func aRefusalOrABuildFailureGivesTheTurnsStraightBack() async throws {
    let rig = AlwaysOnRig()
    rig.shared.route = .speakers
    rig.loop.toggle()
    #expect(await rig.waitUntil { if case .refused = rig.loop.display.state { true } else { false } })
    #expect(!rig.orchestrator.holdsTurns)
    #expect(rig.shared.sessions.isEmpty)
    #expect(rig.microphone.holder == nil)
    guard case .refused(let why) = rig.states.last else { Issue.record("expected a refusal, got \(rig.states)"); return }
    #expect(why.contains("headphones"))

    rig.shared.route = .headphones
    rig.shared.failBuild = true
    rig.loop.toggle()
    guard case .failed(let reason) = rig.loop.display.state else { Issue.record("expected a failure"); return }
    #expect(reason.contains("Always-on voice can't start"))
    #expect(!rig.orchestrator.holdsTurns)

    // The loop still answers presses afterwards.
    await rig.voice.ask()
    #expect(await rig.voice.waitForRecords(1))
    #expect(rig.voice.brain.inputs.count == 1)
}

@MainActor
@Test func aReportThatArrivesDuringAlwaysOnIsToldOnceItEnds() async throws {
    let rig = AlwaysOnRig(scripts: [ScriptedBrain.program(["Your export finished."])])
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    rig.orchestrator.runReportTurn(note: "[Jobs came back] export finished")
    try await Task.sleep(for: .milliseconds(600))
    #expect(rig.voice.brain.inputs.isEmpty)
    rig.loop.toggle()
    #expect(await rig.voice.waitForRecords(1))
    #expect(rig.voice.records.first?.kind == .report)
    #expect(rig.voice.voice.spoken == ["Your export finished."])
}

@MainActor
@Test func aQuestionTypedWhileTheSessionOpensGoesInOnceItIsOnAndIsDroppedIfItNeverIs() async throws {
    let rig = AlwaysOnRig()
    // The provider is slow to answer: the question waits for the session instead of being lost.
    rig.shared.holdConnect = true
    rig.loop.toggle()
    #expect(rig.loop.display.state == .starting)
    #expect(rig.loop.submitTyped("what's on my screen"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(rig.shared.sessions.isEmpty)
    rig.shared.holdConnect = false
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    let session = try #require(rig.session)
    #expect(await rig.waitUntil { session.sent.contains(.text("what's on my screen", respond: true)) })
    #expect(rig.voice.brain.inputs.isEmpty)
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .off })

    // Turned off before the session opened: the question goes nowhere, not into the next session.
    rig.shared.holdConnect = true
    rig.loop.toggle()
    #expect(rig.loop.submitTyped("never mind"))
    try await Task.sleep(for: .milliseconds(50))
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .off })
    rig.shared.holdConnect = false
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    let next = try #require(rig.session)
    #expect(next !== session)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!rig.shared.sessions.contains { $0.sent.contains(.text("never mind", respond: true)) })
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .off })
}

@MainActor
@Test func theNoticeSaysWhetherAlwaysOnStoppedOrNeverStarted() async throws {
    let rig = AlwaysOnRig()
    // On speakers it never starts.
    rig.shared.route = .speakers
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.notices.count == 1 })
    #expect(rig.notices.last?.title == "Always-on voice didn't start.")
    #expect(rig.notices.last?.detail?.contains("headphones") == true)

    // Running with headphones, then the sound moves to the speakers: it stopped.
    rig.shared.route = .headphones
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    #expect(rig.notices.count == 1)
    rig.shared.route = .speakers
    rig.loop.outputRouteChanged()
    #expect(await rig.waitUntil { rig.notices.count == 2 })
    #expect(rig.notices.last?.title == "Always-on voice stopped.")
    #expect(rig.notices.last?.detail?.contains("speakers") == true)
    #expect(!rig.orchestrator.holdsTurns)

    // A realtime-voice slot that can't be built never started either.
    rig.shared.route = .headphones
    rig.shared.failBuild = true
    rig.loop.toggle()
    #expect(rig.notices.count == 3)
    #expect(rig.notices.last?.title == "Always-on voice didn't start." && rig.notices.last?.tone == .error)

    // Turned off by the user.
    rig.shared.failBuild = false
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.loop.display.state == .on })
    rig.loop.toggle()
    #expect(await rig.waitUntil { rig.notices.count == 4 })
    #expect(rig.notices.last == TurnNotice(.info, "Always-on voice is off.", detail: "Hold ⌃⌥ to talk. Triple-tap Control turns it back on."))
    #expect(rig.loop.notice(for: .off, talkKeys: "⌃⌥", keyPhrase: nil)?.detail == "Hold ⌃⌥ to talk. The menu turns it back on.")
    #expect(rig.loop.notice(for: .on, talkKeys: "⌃⌥", keyPhrase: nil) == nil)
}

// MARK: - The notch

@Test func theDisplayFollowsTheConversation() {
    var display = AlwaysOnDisplay()
    #expect(display.notch(stopHint: nil) == nil)
    display.apply(.state(.starting))
    #expect(display.notch(stopHint: "Triple-tap Control ends it") == .init(title: "Starting always-on…", detail: "Triple-tap Control ends it", icon: .working))
    display.apply(.state(.on))
    #expect(display.voice == .listening)
    #expect(display.notch(stopHint: "Triple-tap Control ends it")?.detail == "Just talk · Triple-tap Control ends it")
    display.apply(.conversation(.state(.userSpeaking)))
    display.apply(.conversation(.userCaption("what's on my calendar", isFinal: false)))
    #expect(display.notch(stopHint: nil) == .init(title: "Always-on · hearing you", detail: "what's on my calendar", icon: .listening))
    display.apply(.conversation(.state(.thinking)))
    display.apply(.conversation(.status("Looking at your screen…")))
    #expect(display.canInterrupt)
    #expect(display.notch(stopHint: nil)?.title == "Looking at your screen…")
    display.apply(.conversation(.status(nil)))
    display.apply(.conversation(.state(.speaking)))
    display.apply(.conversation(.assistantCaption("You have a dentist appointment on Thursday.")))
    #expect(display.notch(stopHint: nil) == .init(title: "Always-on · speaking", detail: "what's on my calendar", icon: .speaking))
    #expect(display.replyTail() == "You have a dentist appointment on Thursday.")
    // A new user turn clears the last exchange.
    display.apply(.conversation(.state(.userSpeaking)))
    #expect(display.userCaption.isEmpty && display.assistantCaption.isEmpty)
    // A dropped session reconnects.
    display.apply(.reconnecting)
    display.apply(.state(.starting))
    #expect(display.notch(stopHint: nil)?.title == "Reconnecting always-on…")
    display.apply(.state(.on))
    #expect(!display.reconnecting && display.voice == .listening)
    display.apply(.state(.failed("gone")))
    #expect(display == AlwaysOnDisplay(state: .failed("gone")))
    #expect(display.notch(stopHint: nil) == nil)

    var long = AlwaysOnDisplay(state: .on)
    long.assistantCaption = String(repeating: "word ", count: 80)
    let tail = long.replyTail(limit: 40) ?? ""
    #expect(tail.hasPrefix("…w") && tail.count <= 41)
}

@Test func theTripleTapComesWithADoubleTapTextKey() {
    #expect(TalkKeyTrigger.doubleTap(.control).tripleTapPhrase == "Triple-tap Control")
    #expect(TalkKeyTrigger.hold(.control, .option).tripleTapPhrase == nil)
}

// MARK: - The brain behind send_to_higher_model

@MainActor
@Test func theBrainsDrawingAppearsOnTheScreenshotItWasAskedAbout() async throws {
    let trace = VoiceTrace()
    let surfaces = RecordingSurfaces(trace: trace)
    let drawing = RealtimeBrainDrawing(surfaces: surfaces)
    let shot = TurnScreenshot(jpeg: StillImageScreen.blankCanvas(width: 320, height: 200), label: "main display", isCursorScreen: true,
                              pixelSize: CGSize(width: 320, height: 200), displayFrame: CGRect(x: 0, y: 0, width: 320, height: 200))
    let screen = drawing.screen(StaticRealtimeScreenSource(screenshot: shot))
    let observe = drawing.observer

    // No capture for this request: nothing to draw on.
    observe(.programDelta("circle([10,10], 5)\n"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(surfaces.drawings.isEmpty)

    _ = try await screen.captureCursorScreen()
    observe(.programDelta("say(\"Here.\")\n"))
    observe(.programDelta("circle([40,40], 20)\n"))
    observe(.finished(TurnSummary(program: "", spokenLines: ["Here."], rounds: 1, usage: nil, model: "m", firstTokenSeconds: 0, totalSeconds: 0)))
    #expect(await waitUntil { trace.all.contains("draw.end") })
    #expect(trace.all == ["draw.begin:now", "draw.append", "draw.append", "draw.end"])
    #expect(surfaces.drawings.first?.program.contains("circle([40,40], 20)") == true)
    #expect(surfaces.drawings.first?.options?.width == 320)
    #expect(!drawing.isDrawing)

    // A call cut short leaves its drawing open; the next capture ends it.
    _ = try await screen.captureCursorScreen()
    observe(.programDelta("line([0,0],[10,10])\n"))
    #expect(await waitUntil { drawing.isDrawing })
    _ = try await screen.captureCursorScreen()
    #expect(await waitUntil { !drawing.isDrawing })
    #expect(trace.all.suffix(3) == ["draw.begin:now", "draw.append", "draw.end"])
}

@Test func theBrainsHeldActionsRunAfterTheRealtimeReplyIsHeard() async throws {
    let trace = VoiceTrace()
    let brain = ScriptedBrain(trace: trace, scripts: [ScriptedBrain.program(["Opening it now."], deferred: ["open_url"])])
    let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: nil)
    let outcome = await tool.run(RealtimeToolInvocation(callID: "c1", name: RealtimeToolName.sendToHigherModel,
                                                        arguments: ["question": .string("open the docs")], userWords: ""))
    #expect(outcome.succeeded)
    #expect(outcome.output["answer"]?.stringValue == "Opening it now.")
    let work = try #require(outcome.deferred)
    #expect(work.name == "open_url" && work.callID == "c1")
    #expect(trace.filtered("deferred:").isEmpty)
    #expect(await work.run() == nil)
    #expect(trace.filtered("deferred:") == ["deferred:open_url"])

    brain.deferredResult = ["status": "failed"]
    #expect(await work.run()?.contains("open_url didn't work") == true)

    // No held actions, nothing to run later.
    let plain = ScriptedBrain(trace: trace, scripts: [ScriptedBrain.program(["Just words."])])
    let quiet = await RealtimeTools.sendToHigherModel(brain: plain, screen: nil)
        .run(RealtimeToolInvocation(callID: "c2", name: RealtimeToolName.sendToHigherModel, arguments: ["question": .string("hi")], userWords: ""))
    #expect(quiet.deferred == nil)
}
