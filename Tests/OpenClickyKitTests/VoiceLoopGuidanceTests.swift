import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// The voice loop with draw-to-ask, guided walkthroughs and take-over's reply hook wired in (docs/guided.md): the real
// orchestrator, narrator, drawing engine (offscreen) and walkthrough controller, with a scripted brain and fake voice.

/// A loop around a real `TurnOrchestrator` whose drawings run on the real engine, so the answers' guided marks arm the
/// walkthrough the way they do on screen.
@MainActor
private final class GuidedLoopRig {
    let trace = VoiceTrace()
    let brain: ScriptedBrain
    let clock = PlaybackClockDriver()
    let narrator: LineNarrator
    let screen: StillImageScreen
    let surfaces = OffscreenDrawingSurfaces()
    let guide: TurnPointingGuide
    let orchestrator: TurnOrchestrator
    var stt: SimulatedSpeechToText
    private(set) var records: [TurnRecord] = []
    private(set) var effects: [GuidedEffect] = []

    /// The bridge test page's "Say hello" button, in screenshot pixels (= points: one display at the origin).
    static let sayHello = TurnElement(id: "e5", role: "button", label: "Say hello", frame: CGRect(x: 32, y: 217, width: 71, height: 21))
    static let nameField = TurnElement(id: "e2", role: "text field", label: "Your name", frame: CGRect(x: 113, y: 125, width: 153, height: 21))

    init(heard: String = "how do I say hello", scripts: [[ScriptedBrain.Step]]) {
        brain = ScriptedBrain(trace: trace, scripts: scripts)
        let voice = FakeVoiceClient(name: "voice", trace: trace, seconds: 0.2)
        narrator = LineNarrator(voice: voice, fallback: nil, player: clock.player, policy: LineNarrator.Policy(firstAudioTimeout: 2))
        screen = StillImageScreen(imageData: StillImageScreen.blankCanvas(width: 640, height: 400),
                                  context: TurnContext(frontApp: "Safari", elements: [Self.sayHello, Self.nameField]))
        // No Accessibility or OCR in tests: the description says what was drawn and where.
        guide = TurnPointingGuide(drawToAsk: DrawToAskSession(harvester: HighlightHarvester(accessibility: nil, recognizer: nil)))
        stt = SimulatedSpeechToText(text: heard, chunksPerWord: 1)
        var settings = TurnOrchestrator.Settings()
        settings.transcriptTimeout = 3
        let services = TurnOrchestrator.Services(microphone: SilentMicrophone(chunkDuration: 0.01), speechToText: { SimulatedSpeechToText(text: "") },
                                                 screen: screen, brain: brain, narrator: narrator, drawings: surfaces, guidance: guide)
        orchestrator = TurnOrchestrator(services: services, settings: settings)
        orchestrator.services.speechToText = { [unowned self] in self.stt }
        orchestrator.onTurnFinished = { [unowned self] record in self.records.append(record) }
        guide.onEffect = { [unowned self] effect in self.effects.append(effect) }
    }

    func ask(holding seconds: TimeInterval = 0.12) async {
        orchestrator.pressBegan()
        try? await Task.sleep(for: .seconds(seconds))
        orchestrator.pressEnded()
    }

    @discardableResult
    func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The walkthrough's target, in AppKit global points.
    var target: GuidedTarget? { guide.guided.target }

    /// A step of a walkthrough: name the task, say one line, ring a control.
    static func step(_ line: String, task: String? = nil, target: String? = nil, wait: String? = nil, delay: TimeInterval = 0.02) -> [ScriptedBrain.Step] {
        var program = ""
        if let task { program += "task(\"\(task)\")\n" }
        program += "step(1)\nsay(\"\(line)\")\n"
        if let target { program += "target(\"\(target)\", \"Say hello\")\n" }
        if let wait { program += "waitForUser(\"\(wait)\")\n" }
        return [
            ScriptedBrain.Step(delay: delay, event: .programDelta(program)),
            ScriptedBrain.Step(delay: 0, event: .sayLine(index: 0, text: line)),
            ScriptedBrain.Step(delay: 0.01, event: .finished(TurnSummary(program: program, spokenLines: [line], rounds: 1, usage: nil,
                                                                          model: "scripted", firstTokenSeconds: 0.02, totalSeconds: 0.05))),
        ]
    }

    deinit { clock.stop() }
}

@MainActor
@Test func anAnswersTargetArmsTheWalkthroughAndAClickOnItStartsTheNextTurnByItself() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello, under the form.", task: "Say hello to the page", target: "e5"),
        GuidedLoopRig.step("That's it: the page greeted you."),
    ])
    await rig.ask()
    // The target arms when its line is heard, snapped to the named control.
    #expect(await rig.wait { rig.target != nil })
    let target = try #require(rig.target)
    #expect(target.element?.id == "e5")
    #expect(rig.guide.guided.status.task == "Say hello to the page")
    #expect(rig.orchestrator.canInterrupt)
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })

    // The user clicks the ringed button: the next turn starts with no words, the trigger and the walkthrough's notes,
    // captured after the screen settles.
    rig.guide.guided.handle(.mouseDown(target.center))
    #expect(await rig.wait { rig.records.count == 2 && !rig.orchestrator.isBusy })
    let follow = try #require(rig.brain.inputs.last)
    #expect(rig.brain.inputs.count == 2)
    #expect(follow.words.isEmpty)
    #expect(follow.context.trigger == "clicked_target")
    #expect(follow.appNotes.first?.contains("Say hello") == true)
    #expect(rig.records[1].kind == .guided)
    #expect(rig.screen.settledLooks == 1)
    // That answer armed nothing: the walkthrough is complete.
    #expect(await rig.wait { !rig.guide.isWalkthroughActive })
    #expect(rig.effects.contains(.ended(.completed)))
}

@MainActor
@Test func aManualStepStartsTheNextTurnOnceTheUserHasActedAndPaused() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Type your name in the box.", task: "Say hello to the page", wait: "Type your name"),
        GuidedLoopRig.step("Now click Say hello."),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.guide.guided.walkthrough.phase == .manual })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.keyDown)
    // 1.2 s of quiet after the typing, then `did_step` (the controller ticks itself).
    #expect(await rig.wait(6) { rig.brain.inputs.count == 2 })
    #expect(rig.brain.inputs[1].context.trigger == "did_step")
}

@MainActor
@Test func theHighlightDrawnWhileTheKeysAreHeldRidesWithThatTurn() async throws {
    let rig = GuidedLoopRig(heard: "what is this", scripts: [GuidedLoopRig.step("That's the name field.")])
    let shot = try #require(rig.screen.screenshot)
    let geometry = CaptureGeometry(turnScreenshot: shot, layout: try #require(rig.screen.layout))
    rig.guide.scriptedGesture = HighlightSimulator.gesture([.circle(center: CGPoint(x: 190, y: 135), radiusX: 95, radiusY: 26)],
                                                            geometry: geometry)
    await rig.ask()
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    let input = try #require(rig.brain.inputs.first)
    let description = try #require(input.context.highlightDescription)
    #expect(description.contains("circled"))
    // The ink is drawn into the screenshot the brain gets (the overlay itself is never captured).
    #expect(input.screenshots.first?.jpeg != shot.jpeg)
    #expect(rig.guide.highlightsAttached == 1)

    // The gesture belongs to that turn only.
    rig.orchestrator.submitTyped("and this?")
    #expect(await rig.wait { rig.records.count == 2 && !rig.orchestrator.isBusy })
    #expect(rig.brain.inputs.last?.context.highlightDescription == nil)
}

@MainActor
@Test func aBrushedPressOrNothingHeardPutsTheStepBackAndEscapeStopsTheWalkthrough() async throws {
    let rig = GuidedLoopRig(heard: "", scripts: [GuidedLoopRig.step("unused")])
    rig.guide.guided.screen = rig.screen.guidedScreen
    let armed = try #require(rig.guide.guided.arm(GuidedTargetRequest(.element("e5"), label: "Say hello")))
    #expect(rig.orchestrator.canInterrupt)

    // Key down: the step steps aside for the user's own turn; a brush brings it back.
    rig.orchestrator.pressBegan()
    #expect(rig.target == nil)
    rig.orchestrator.pressCancelled()
    #expect(rig.target?.id == armed.id)

    // A press with nothing heard is not a turn either.
    await rig.ask()
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    #expect(rig.records[0].outcome == .notStarted)
    #expect(rig.target?.id == armed.id)
    #expect(rig.brain.inputs.isEmpty)

    // Escape with nothing else running stops the walkthrough (and is swallowed), then passes through.
    #expect(rig.orchestrator.interrupt())
    #expect(!rig.guide.isWalkthroughActive)
    #expect(rig.effects.contains(.ended(.stopped)))
    #expect(!rig.orchestrator.interrupt())
}

@MainActor
@Test func actingWhileTheNextStepIsPreparedCapturesAgainBeforeAnything() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello.", task: "Say hello to the page", target: "e5"),
        GuidedLoopRig.step("Slow answer that is never heard.", delay: 3),
        GuidedLoopRig.step("Done."),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.brain.inputs.count == 2 })
    // Past the 0.6 s grace, the user scrolls on: the follow-up is taken again on a fresh screenshot.
    try await Task.sleep(for: .milliseconds(700))
    rig.guide.guided.handle(.scroll)
    #expect(await rig.wait { rig.brain.inputs.count == 3 })
    let fresh = rig.brain.inputs[2]
    #expect(fresh.context.trigger == "clicked_target")
    #expect(fresh.appNotes.contains(GuidedWalkthrough.freshnessNote))
    #expect(rig.screen.settledLooks == 2)
    #expect(await rig.wait { rig.records.count == 3 && !rig.orchestrator.isBusy })
    // The dropped follow-up never spoke; only one re-capture per step.
    #expect(rig.records[1].outcome == .droppedBeforeFirstLine(.steppedAhead))
}

@MainActor
@Test func stoppingTheWalkthroughCutsOffItsNextStepSoThatAnswerCannotArmItAgain() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello.", task: "Say hello to the page", target: "e5"),
        // The next step, still being worked out when the user picks Stop walkthrough: it would ring Say hello again.
        GuidedLoopRig.step("Click Say hello once more.", target: "e5", delay: 0.8),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.brain.inputs.count == 2 && rig.orchestrator.isBusy })

    #expect(rig.orchestrator.stopWalkthrough())
    #expect(!rig.guide.isWalkthroughActive)
    #expect(await rig.wait { rig.records.count == 2 && !rig.orchestrator.isBusy })
    #expect(rig.records.dropFirst().first?.kind == .guided)
    #expect(rig.records.dropFirst().first?.outcome == .droppedBeforeFirstLine(.stoppedWalkthrough))
    // The cut-off answer never arms its target: no walkthrough comes back by itself.
    try await Task.sleep(for: .milliseconds(1200))
    #expect(rig.target == nil)
    #expect(!rig.guide.isWalkthroughActive)
    #expect(rig.brain.inputs.count == 2)
    #expect(!rig.orchestrator.stopWalkthrough())
}

@MainActor
@Test func aPressThatCutsOffTheNextStepAndComesToNothingAsksForItAgain() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello.", task: "Say hello to the page", target: "e5"),
        GuidedLoopRig.step("Slow next step that the press cuts off.", delay: 3),
        GuidedLoopRig.step("Done: the page greeted you."),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.brain.inputs.count == 2 })

    // The talk keys are only brushed while the next step is worked out: that turn is cut off, then asked for again
    // (rather than leaving the walkthrough "working out the next step" with nothing running).
    rig.orchestrator.pressBegan()
    #expect(rig.records.count == 2)
    #expect(rig.records.dropFirst().first?.outcome == .droppedBeforeFirstLine(.newPress))
    rig.orchestrator.pressCancelled()
    #expect(await rig.wait { rig.brain.inputs.count == 3 })
    let again = try #require(rig.brain.inputs.dropFirst(2).first)
    #expect(again.words.isEmpty)
    #expect(again.context.trigger == "clicked_target")
    #expect(again.appNotes.first?.contains("Say hello") == true)
    // Clicked once, so the screen settled once; the second ask doesn't wait for it again.
    #expect(rig.screen.settledLooks == 1)
    #expect(await rig.wait { rig.records.count == 3 && !rig.orchestrator.isBusy })
    #expect(rig.records.dropFirst(2).first?.kind == .guided)
    #expect(await rig.wait { rig.effects.contains(.ended(.completed)) })
}

@MainActor
@Test func whileTurnsAreHeldACutOffNextStepIsNotAskedForAgain() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello.", task: "Say hello to the page", target: "e5"),
        GuidedLoopRig.step("Slow next step that the press cuts off.", delay: 3),
        GuidedLoopRig.step("Never asked for."),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.brain.inputs.count == 2 })
    rig.orchestrator.pressBegan()
    // Always-on voice takes over before the brushed press ends: the walkthrough's turn must not start under it.
    rig.orchestrator.holdsTurns = true
    rig.orchestrator.pressCancelled()
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.brain.inputs.count == 2)
    #expect(!rig.orchestrator.isBusy)
}

@MainActor
@Test func aPressWithNothingHeardAfterCuttingOffTheNextStepAsksForItAgain() async throws {
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step("Click Say hello.", task: "Say hello to the page", target: "e5"),
        GuidedLoopRig.step("Slow next step that the press cuts off.", delay: 3),
        GuidedLoopRig.step("Done: the page greeted you."),
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.brain.inputs.count == 2 })
    rig.stt = SimulatedSpeechToText(text: "")
    await rig.ask()
    #expect(await rig.wait { rig.brain.inputs.count == 3 })
    #expect(rig.brain.inputs.dropFirst(2).first?.context.trigger == "clicked_target")
    #expect(await rig.wait { rig.records.count == 4 && !rig.orchestrator.isBusy })
    #expect(rig.records.map(\.kind) == [.voice, .guided, .voice, .guided])
    #expect(rig.records.dropFirst(2).first?.outcome == .notStarted)
    #expect(await rig.wait { rig.effects.contains(.ended(.completed)) })
}

@MainActor
@Test func aBrushedPressAfterTheNextStepArmedPutsThatStepBackWithoutAskingAgain() async throws {
    let first = "Click Say hello."
    let armed = "Now click Say hello again."
    let program = "step(1)\nsay(\"\(armed)\")\ntarget(\"e5\", \"Say hello\")\nstep(2)\nsay(\"Then you're done.\")\n"
    let rig = GuidedLoopRig(scripts: [
        GuidedLoopRig.step(first, task: "Say hello to the page", target: "e5"),
        // The next step rings its target on its first line; the second line is still coming when the keys are brushed.
        [
            ScriptedBrain.Step(delay: 0.02, event: .programDelta(program)),
            ScriptedBrain.Step(delay: 0, event: .sayLine(index: 0, text: armed)),
            ScriptedBrain.Step(delay: 3, event: .sayLine(index: 1, text: "Then you're done.")),
        ],
    ])
    await rig.ask()
    #expect(await rig.wait { rig.target != nil })
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    rig.guide.guided.handle(.mouseDown(try #require(rig.target).center))
    #expect(await rig.wait { rig.target != nil && rig.brain.inputs.count == 2 })
    let rearmed = try #require(rig.target)

    rig.orchestrator.pressBegan()
    #expect(rig.target == nil)
    rig.orchestrator.pressCancelled()
    // The armed step comes back; nothing is asked again.
    #expect(rig.target?.id == rearmed.id)
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.brain.inputs.count == 2)
    #expect(!rig.orchestrator.isBusy)
    #expect(rig.guide.guided.walkthrough.phase == .armed)
}

@MainActor
@Test func theUsersWordsReachTheReplyHookBeforeTheBrainAndNotesReachTheNextTurn() async throws {
    let rig = GuidedLoopRig(heard: "yes go ahead", scripts: [GuidedLoopRig.step("Okay, driving now.")])
    var heard: [String] = []
    rig.orchestrator.onUserWords = { words in
        heard.append(words)
        rig.trace.add("reply:\(words)")
    }
    rig.orchestrator.noteForNextTurn("[App] Take-over \"Title the note\" ended: finished.")
    await rig.ask()
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    #expect(heard == ["yes go ahead"])
    let reply = try #require(rig.trace.index(of: "reply:yes go ahead"))
    let run = try #require(rig.trace.index(of: "brain.run:yes go ahead"))
    #expect(reply < run)
    #expect(rig.brain.notes == ["[App] Take-over \"Title the note\" ended: finished."])
}

@MainActor
@Test func aJobReportNeitherArmsTargetsNorEndsAWalkthrough() async throws {
    let rig = GuidedLoopRig(scripts: [GuidedLoopRig.step("Your research is done. Click Say hello.", target: "e5")])
    rig.guide.guided.screen = rig.screen.guidedScreen
    let armed = try #require(rig.guide.guided.arm(GuidedTargetRequest(.element("e2"), label: "Your name")))
    rig.orchestrator.runReportTurn(note: "[App] A background job finished.")
    #expect(await rig.wait { rig.records.count == 1 && !rig.orchestrator.isBusy })
    try await Task.sleep(for: .milliseconds(300))
    #expect(rig.records[0].kind == .report)
    #expect(rig.target?.id == armed.id)
    #expect(rig.guide.isWalkthroughActive)
}

@Test func takeoverToolsRegisterAsActionsWithTheirOwnPromptRule() async throws {
    let controller = TakeoverController(makeSetup: { _ in throw CancellationError() })
    var registry = ToolRegistry()
    registry.register(contentsOf: ToolRegistry.takeoverTools(TakeoverTools(controller: controller)))
    #expect(registry.names == [TakeoverTools.offerName, TakeoverTools.startName, TakeoverTools.endName])
    #expect(registry.tools.allSatisfy { $0.kind == .action && $0.group == .takeover })
    #expect(registry.groups == [.takeover])
    let rules = BrainInstructions.tools(registry.groups)
    #expect(rules.contains("offer_screen_takeover") && rules.contains("start_screen_takeover"))
    #expect(!BrainInstructions.tools([.memory]).contains("offer_screen_takeover"))

    // Starting without the user's yes is refused; an offer waits for them.
    let start = await registry.tool(named: TakeoverTools.startName)!.run([:], context: BrainToolContext(sessionID: "s", turn: 1, callID: "c1"))
    #expect(start["status"]?.stringValue == "refused")
    let offer = await registry.tool(named: TakeoverTools.offerName)!.run(["task": "Title the note"],
                                                                          context: BrainToolContext(sessionID: "s", turn: 1, callID: "c2"))
    #expect(offer["status"]?.stringValue == "needs_confirmation")
    #expect(await controller.userReplied("yes, go ahead").name == "approved")
}

@Test func voiceLoopSettingsKeepTakeoverInputOffUnlessTurnedOn() throws {
    #expect(VoiceLoopSettings().takeoverPostsInput == false)
    let old = try JSONDecoder().decode(VoiceLoopSettings.self, from: Data(#"{"speaksTypedAnswers": true}"#.utf8))
    #expect(old.takeoverPostsInput == false && old.speaksTypedAnswers)
    var on = VoiceLoopSettings()
    on.takeoverPostsInput = true
    let decoded = try JSONDecoder().decode(VoiceLoopSettings.self, from: try JSONEncoder().encode(on))
    #expect(decoded.takeoverPostsInput)
}
