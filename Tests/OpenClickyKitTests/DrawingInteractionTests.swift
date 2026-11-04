import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

// What the user does to a drawing on the overlay (docs/overlay-interaction.md): drawn buttons, figures and cards through
// the pointer router and the handle panels, follow-ups that see and continue the drawing, finishing a drawing the voice
// left behind, and the stale watch.

private func futureClock() -> VirtualClock { VirtualClock(CACurrentMediaTime() + 100_000) }

/// A session drawn at once (pace now) and settled, on a virtual clock moved past its animations.
@MainActor
private func drawnSession(_ program: String, clock: VirtualClock, scale: Double = 1, stage: FigureStage? = nil) async throws -> DrawingSession {
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832, scale: scale), figureSink: stage, clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, scale: scale, pace: .now))
    session.append(program)
    session.end()
    await session.settle()
    clock.now += 10
    await session.settle()
    return session
}

private let cardProgram = """
const card = paper(100, 100, 420, 300, {title: "Notes"})
write(card.x + 10, card.y + 40, "Hello there")
button(card.x + 10, card.y + 200, "Tell me more")
circle(1000, 650, 40)
"""

// MARK: - The engine's card actions

@MainActor
@Test func cardsCarryWhatSitsOnThemAndScreenMarksStandAlone() async throws {
    let clock = futureClock()
    let session = try await drawnSession(cardProgram, clock: clock)
    let cards = await session.cards()
    #expect(cards.count == 1)
    let card = try #require(cards.first)
    #expect(card.kind == "paper" && card.title == "Notes" && card.isDraggable)
    #expect(card.box.minX >= 99 && card.box.width >= 419)
    // The paper, its words and its button ride together; the circle marks the screen.
    let kinds = Set(card.marks.compactMap { session.painter.entries[$0]?.mark.kind })
    #expect(kinds == ["paper", "text", "button"])
    let circle = try #require(session.painter.markIDs.first { session.painter.entries[$0]?.mark.kind == "circle" })
    #expect(!card.marks.contains(circle))
}

@MainActor
@Test func movingClosingAndDroppingScreenMarksChangeTheDrawingAndItsDescription() async throws {
    let clock = futureClock()
    let session = try await drawnSession(cardProgram, clock: clock, scale: 2)
    let card = try #require(await session.cards().first)
    let moved = try #require(await session.moveCard(card, by: CGSize(width: 50, height: 30)))
    #expect(moved == CGSize(width: 50, height: 30))
    let after = try #require(await session.cards().first)
    #expect(abs(after.box.minX - (card.box.minX + 50)) < 0.01 && abs(after.box.minY - (card.box.minY + 30)) < 0.01)
    // The painter shows the marks where the engine put them (scale 2: 100, 60 points).
    let paperLayer = try #require(session.painter.layer(forMark: card.id))
    #expect(abs(CATransform3DGetAffineTransform(paperLayer.transform).tx - 100) < 0.01)
    // Dragged off the canvas, a card stays on it.
    let clamped = try #require(await session.moveCard(after, by: CGSize(width: 5_000, height: 0)))
    #expect(clamped.width < 5_000)

    let text = try #require(session.describeOnScreen())
    #expect(text.contains("paper") && text.contains("Hello there"))

    let (kept, dropped) = await session.dropScreenMarks()
    #expect(kept == 1 && dropped == 1)
    #expect(!session.painter.markIDs.contains { session.painter.entries[$0]?.mark.kind == "circle" })

    let gone = await session.closeCard(try #require(await session.cards().first))
    #expect(gone == 3)
    #expect(session.painter.markIDs.isEmpty)
    #expect(await session.cards().isEmpty)
    #expect(session.describeOnScreen() == nil)
    // With no card left, the screen marks are all there was.
    let none = await session.dropScreenMarks()
    #expect(none.kept == 0 && none.dropped == 0)
}

@MainActor
@Test func aContinuedDrawingDropsWhatTheLastAnswerNeverDrewAndCanReuseItsNames() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    // Speech-paced: line 0 is heard, line 1 never is (the answer was cut off).
    _ = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech)))
    _ = host.perform(.append("""
    step(1)
    say("A box.")
    const b = box(100, 100, 200, 100, {label: "Server"})
    step(2)
    say("And a circle.")
    erase("p1")
    circle(600, 300, 50)
    """))
    _ = host.perform(.end)
    _ = host.perform(.lineStarted(0, 1))
    clock.now += 3
    _ = host.perform(.drain)
    _ = host.perform(.cancel)
    let drawn = host.describe(drawnOnly: true, maxCharacters: 12_000)
    #expect(drawn.contains("box") && !drawn.contains("circle"))
    // Everything, as the engine knew it, still lists the circle (and the erase that never happened hides the box).
    #expect(host.describe().contains("circle"))

    var options = DrawingBeginOptions(width: 1280, height: 832, pace: .now)
    options.keep = true
    let begun = host.perform(.begin(options))
    #expect(!begun.contains { if case .remove = $0 { true } else { false } })
    var events = host.perform(.append("const b = box(400, 400, 100, 100)\nrecolor(\"p1\", \"red\")\n"))
    events += host.perform(.end)
    clock.now += 5
    events += host.perform(.drain)
    #expect(!events.contains { if case .error = $0 { true } else { false } }, "\(events)")
    let now = host.describe(drawnOnly: true, maxCharacters: 12_000)
    #expect(now.contains("p1: box") && !now.contains("circle") && now.contains("turn 2"))
    // The program's variables for parts are named (the second `b` now holds the new box).
    #expect(now.contains("p3 (b): box"))
}

@Test func theDescriptionFoldsItsOldestPartsToFitItsBudget() throws {
    let clock = VirtualClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    _ = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
    let program = (0..<40).map { "text(20, \(20 + $0 * 18), \"Line number \($0) of a long list\")" }.joined(separator: "\n")
    _ = host.perform(.append(program + "\n"))
    _ = host.perform(.end)
    clock.now += 30
    _ = host.perform(.drain)
    let full = host.describe(drawnOnly: true, maxCharacters: 100_000)
    let short = host.describe(drawnOnly: true, maxCharacters: 1_000)
    #expect(full.count > 1_000)
    #expect(short.count <= 1_000)
    #expect(short.contains("(left out to fit: p1–"))
    #expect(short.contains("p40"))
    #expect(short.hasPrefix("Canvas 1280x832"))
}

// MARK: - The pointer router

@MainActor
@Test func theRouterClicksDrawnButtonsDragsCardsAndClosesThem() async throws {
    let clock = futureClock()
    let session = try await drawnSession(cardProgram, clock: clock, scale: 2)
    var asked: [String] = []
    session.onEvent = { if case .ask(let text) = $0 { asked.append(text) } }
    let router = DrawingPointerRouter(session: session)
    await router.refresh()
    let button = try #require(session.painter.visibleButtons().first)
    let card = try #require(router.cards.first)
    let regions = router.regions()
    #expect(regions.contains { $0.target == .button(button.id) && $0.frame == button.frame })
    #expect(regions.contains { $0.target == .card(card.id) && $0.frame == router.frame(of: card) })

    let centre = CGPoint(x: button.frame.midX, y: button.frame.midY)
    #expect(router.hover(at: centre) == .pointingHand)
    #expect(router.hoveredCard == card.id)
    router.pointerDown(at: centre)
    router.pointerDragged(to: CGPoint(x: centre.x + 2, y: centre.y + 1))
    #expect(router.pointerUp(at: CGPoint(x: centre.x + 2, y: centre.y + 1)) == .asked(button: button.id))
    await session.settle()
    #expect(asked == ["Tell me more"])
    // A press that slides off the button asks nothing.
    router.pointerDown(at: centre)
    router.pointerDragged(to: CGPoint(x: centre.x + 400, y: centre.y))
    #expect(router.pointerUp(at: CGPoint(x: centre.x + 400, y: centre.y)) == .none)

    // The card's body drags it: the marks follow the pointer at once and the engine moves them on release.
    let frame = router.frame(of: card)
    let grab = CGPoint(x: frame.midX, y: frame.maxY - 20)
    #expect(router.target(at: grab) == .card(card.id))
    #expect(router.hover(at: grab) == .openHand)
    router.pointerDown(at: grab)
    router.pointerDragged(to: CGPoint(x: grab.x + 30, y: grab.y + 10))
    #expect(router.hover(at: CGPoint(x: grab.x + 30, y: grab.y + 10)) == .closedHand)
    #expect(router.frame(of: card).minX == frame.minX + 30)
    let paper = try #require(session.painter.layer(forMark: card.id))
    #expect(abs(CATransform3DGetAffineTransform(paper.transform).tx - 30) < 0.01)
    router.pointerDragged(to: CGPoint(x: grab.x + 60, y: grab.y + 20))
    #expect(router.pointerUp(at: CGPoint(x: grab.x + 60, y: grab.y + 20)) == .cardMoved(card: card.id, by: CGSize(width: 60, height: 20)))
    await router.settle()
    let movedCard = try #require(router.cards.first)
    // 60 × 20 points at 2 points a unit.
    #expect(abs(movedCard.box.minX - (card.box.minX + 30)) < 0.01 && abs(movedCard.box.minY - (card.box.minY + 10)) < 0.01)
    #expect(abs(router.frame(of: movedCard).minX - (frame.minX + 60)) < 0.01)

    // The close box in its top-right corner takes the card and everything on it away.
    let close = router.closeBox(of: movedCard)
    let closePoint = CGPoint(x: close.midX, y: close.midY)
    #expect(router.target(at: closePoint) == .closeBox(card: card.id))
    #expect(router.hover(at: closePoint) == .pointingHand)
    router.pointerDown(at: closePoint)
    #expect(router.pointerUp(at: closePoint) == .cardClosed(card: card.id))
    await router.settle()
    #expect(router.cards.isEmpty)
    #expect(!session.painter.markIDs.contains { ["paper", "text", "button"].contains(session.painter.entries[$0]?.mark.kind ?? "") })
    #expect(router.regions().isEmpty)
}

@MainActor
@Test func aButtonTakesClicksOnlyOnceItHasAppeared() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech))
    session.append("step(1)\nsay(\"Click below.\")\nbutton(400, 400, \"Why?\")\n")
    session.end()
    session.lineStarted(0, expectedDuration: 3)
    await session.settle()
    let router = DrawingPointerRouter(session: session)
    let entry = try #require(painter.entries.values.first { $0.mark.kind == "button" })
    let start = painter.beginTime(entry.mark.json)
    #expect(start > clock.now)
    #expect(router.regions(at: clock.now).isEmpty)
    #expect(router.target(at: CGPoint(x: 420, y: 410)) == nil)
    clock.now = start + 0.01
    #expect(router.regions().count == 1)
    session.cancel()
}

@MainActor
@Test func clickingAFigurePartAsksAboutItByItsVariableAndDraggingTurnsIt() async throws {
    let clock = futureClock()
    let stage = FigureStage(kernel: FigureKernel(byteBudget: 32 << 20), drivesItself: false, clock: { clock.now })
    let canvas = DrawingDisplayCanvas(stage: stage)
    canvas.clock = { clock.now }
    canvas.offscreen = true
    var asked: [String] = []
    canvas.onAsk = { asked.append($0) }
    let shot = TurnScreenshot(jpeg: StillImageScreen.blankCanvas(width: 1280, height: 832), label: "main display", isCursorScreen: true,
                              pixelSize: CGSize(width: 1280, height: 832), displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 832))
    let (session, keep) = try #require(canvas.drawing(for: shot, image: nil, continuing: true))
    #expect(!keep)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now))
    session.append("""
    const f = figure(100, 80, 400, 300, { tilt: 0, spin: 0 });
    const rotor = f.box({ size: [1, 1, 1], at: [-1, 0, 0] });
    const knob = f.sphere({ r: 0.5, at: [1, 0, 0], name: "the knob" });
    f.label(knob, "knob");
    """)
    session.end()
    await session.settle()
    await stage.settle()
    clock.now += 6
    await session.settle()
    stage.renderFrame()
    let router = try #require(canvas.router)
    await router.refresh()
    #expect(router.cards.map(\.kind) == ["figure"])
    #expect(router.cards.first?.isDraggable == false)
    let figureFrame = try #require(session.painter.figureFrames["fig1"])
    #expect(router.regions().contains { $0.target == .figure("fig1") })
    let scene = try #require(stage.scene("fig1"))
    let frame = scene.frame(at: clock.now, viewport: figureFrame.size, framing: scene.framing(at: clock.now))
    let local = frame.project([-1, 0, 0.5])
    let point = CGPoint(x: figureFrame.minX + local.x, y: figureFrame.minY + local.y)
    #expect(router.target(at: point) == .figure("fig1"))
    #expect(router.hover(at: point) == .pointingHand)
    #expect(router.hover(at: CGPoint(x: figureFrame.minX + 30, y: figureFrame.maxY - 20)) == .openHand)

    router.pointerDown(at: point)
    guard case .figureClicked(let click) = router.pointerUp(at: point) else {
        Issue.record("the click didn't pick the part")
        return
    }
    #expect(click.name == "the rotor")
    #expect(asked == ["Tell me about the rotor in the 3D figure you just drew."])

    // A drag turns the figure and asks nothing.
    router.pointerDown(at: point)
    router.pointerDragged(to: CGPoint(x: point.x + 40, y: point.y + 10))
    #expect(router.pointerUp(at: CGPoint(x: point.x + 40, y: point.y + 10)) == .figureTurned("fig1"))
    #expect(scene.dragYaw < -10)
    #expect(asked.count == 1)

    // The figure's own description rides with the card's for a follow-up.
    let text = try #require(canvas.describeOnScreen())
    #expect(text.contains("p1 (f): figure") && text.contains("3D figure fig1") && text.contains("\"rotor\""))
    // The figure's parts are listed once, by the figure's own description.
    #expect(!text.contains("part3d"))

    // Closing the figure's card takes it off the stage.
    let close = router.closeBox(of: try #require(router.cards.first))
    router.pointerDown(at: CGPoint(x: close.midX, y: close.midY))
    #expect(router.pointerUp(at: CGPoint(x: close.midX, y: close.midY)) == .cardClosed(card: "fig1"))
    await router.settle()
    #expect(stage.figureIDs.isEmpty)
    #expect(canvas.describeOnScreen() == nil)
}

// MARK: - Handle panels

@MainActor
@Test func synthesizedClicksOnAHandlePanelReachTheDrawing() async throws {
    let clock = futureClock()
    let session = try await drawnSession(cardProgram, clock: clock)
    var asked: [String] = []
    session.onEvent = { if case .ask(let text) = $0 { asked.append(text) } }
    let router = DrawingPointerRouter(session: session)
    await router.refresh()
    // A display at (200, 100) in AppKit coordinates, 1280 × 832 points.
    let display = CGRect(x: 200, y: 100, width: 1280, height: 832)
    let handles = DrawingHandles(showsPanels: false) { [DrawingHandles.Display(id: 7, frame: display, router: router)] }
    var outcomes: [DrawingPointerRouter.Outcome] = []
    handles.onOutcome = { _, outcome in outcomes.append(outcome) }
    handles.sync()
    let button = try #require(session.painter.visibleButtons().first)
    let card = try #require(router.cards.first)
    #expect(handles.panels.count == 2)
    let panel = try #require(handles.panel(display: 7, target: .button(button.id)))
    // The panel sits over the button: AppKit's y runs up from the display's bottom.
    // (Rounded outwards to whole points, as windows are.)
    #expect(panel.frame == CGRect(x: 200 + button.frame.minX, y: 100 + 832 - button.frame.maxY, width: button.frame.width,
                                  height: button.frame.height).integral)
    #expect(!panel.canBecomeKey && !panel.isVisible && !panel.ignoresMouseEvents)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    // When the overlay steps aside for system UI, the handles go with it (and stay placed for when it comes back).
    let shown = DrawingHandles(showsPanels: true) { [] }
    #expect(shown.showsOnScreen)
    shown.isHidden = true
    #expect(!shown.showsOnScreen)
    handles.isHidden = true
    handles.sync()
    #expect(!handles.showsOnScreen && handles.panels.count == 2 && !panel.isVisible)
    handles.isHidden = false

    func event(_ type: NSEvent.EventType, _ location: CGPoint, in panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let middle = CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
    let mapped = panel.handleView.canvasPoint(for: event(.mouseMoved, middle, in: panel))
    #expect(abs(mapped.x - button.frame.midX) < 1 && abs(mapped.y - button.frame.midY) < 1)
    panel.handleView.mouseMoved(with: event(.mouseMoved, middle, in: panel))
    #expect(panel.handleView.cursorShown == .pointingHand)
    panel.handleView.mouseDown(with: event(.leftMouseDown, middle, in: panel))
    panel.handleView.mouseUp(with: event(.leftMouseUp, middle, in: panel))
    await session.settle()
    #expect(asked == ["Tell me more"])
    #expect(outcomes == [.asked(button: button.id)])

    // Hovering the card shows its close box on the card's panel; a click there closes it and the panels go.
    let cardPanel = try #require(handles.panel(display: 7, target: .card(card.id)))
    let cardFrame = router.frame(of: card)
    let inside = CGPoint(x: 40, y: 40)
    cardPanel.handleView.mouseMoved(with: event(.mouseMoved, inside, in: cardPanel))
    #expect(router.hoveredCard == card.id)
    let box = try #require(cardPanel.handleView.closeBox)
    let panelTop = 100 + 832 - cardPanel.frame.maxY, panelLeft = cardPanel.frame.minX - 200
    #expect(box == router.closeBox(of: card).offsetBy(dx: -panelLeft, dy: -panelTop))
    #expect(abs(panelLeft - cardFrame.minX) <= 1 && abs(panelTop - cardFrame.minY) <= 1)
    let closeAt = CGPoint(x: box.midX, y: cardPanel.frame.height - box.midY)
    cardPanel.handleView.mouseDown(with: event(.leftMouseDown, closeAt, in: cardPanel))
    cardPanel.handleView.mouseUp(with: event(.leftMouseUp, closeAt, in: cardPanel))
    #expect(outcomes.last == .cardClosed(card: card.id))
    await router.settle()
    handles.sync()
    #expect(handles.panels.isEmpty)
    handles.stop()
}

// MARK: - Follow-ups in the turn loop

/// Records continuing and describing calls around `RecordingDrawing`s.
@MainActor
private final class FollowUpSurfaces: TurnDrawingSurfaces {
    let trace: VoiceTrace
    var description: String?
    private(set) var drawings: [RecordingDrawing] = []

    init(trace: VoiceTrace) { self.trace = trace }

    func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        trace.add("surfaces.fresh")
        let drawing = RecordingDrawing(trace: trace)
        drawings.append(drawing)
        return drawing
    }

    func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)? {
        let keep = !drawings.isEmpty
        trace.add("surfaces.continue:\(keep)")
        if keep, let last = drawings.last { return (last, true) }
        let drawing = RecordingDrawing(trace: trace)
        drawings.append(drawing)
        return (drawing, false)
    }

    var hasVisibleDrawing: Bool { !drawings.isEmpty }
    func clearAll() { drawings.removeAll() }
    func describeOnScreen(for screenshot: TurnScreenshot) -> String? {
        trace.add("surfaces.describe")
        return description
    }
}

@MainActor
@Test func followUpsSeeTheDrawingOnScreenAndContinueIt() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["A box."]), ScriptedBrain.program(["Now red."]),
                                     ScriptedBrain.program(["Jobs are done."])])
    let surfaces = FollowUpSurfaces(trace: rig.trace)
    rig.orchestrator.services.drawings = surfaces
    rig.orchestrator.submitTyped("draw a box")
    #expect(await rig.waitForRecords(1))
    #expect(rig.brain.inputs[0].context.drawingOnScreen == nil)
    #expect(surfaces.drawings.first?.options?.keep == false)

    surfaces.description = "Canvas 320x200 units, x to the right, y down. Parts on the card:\n  p1: box [10,10,200,100] (m1)"
    rig.orchestrator.submitTyped("make it red")
    #expect(await rig.waitForRecords(2))
    #expect(rig.brain.inputs[1].context.drawingOnScreen?.contains("p1: box") == true)
    #expect(surfaces.drawings.count == 1)
    #expect(surfaces.drawings[0].options?.keep == true)
    // The brain reads it in the turn notes, within the 12,000-character budget.
    let notes = BrainTurnNotes.notes(for: rig.brain.inputs[1])
    #expect(notes.contains("Your drawing still on screen:\nCanvas 320x200"))

    // A job report's turn starts a new drawing rather than continuing the user's, so it isn't told about the old one
    // (its program couldn't edit it).
    let described = rig.trace.all.filter { $0 == "surfaces.describe" }.count
    rig.orchestrator.runReportTurn(note: "[Your jobs] one finished")
    #expect(await rig.waitForRecords(3))
    #expect(rig.trace.all.contains("surfaces.fresh"))
    #expect(surfaces.drawings.last?.options?.keep == false)
    #expect(rig.brain.inputs[2].context.drawingOnScreen == nil)
    #expect(rig.trace.all.filter { $0 == "surfaces.describe" }.count == described)
}

@MainActor
@Test func aFollowUpIsShownOnlyTheDrawingItWillContinue() async throws {
    let clock = futureClock()
    let canvas = DrawingDisplayCanvas(stage: FigureStage(drivesItself: false))
    canvas.clock = { clock.now }
    canvas.offscreen = true
    let shot = TurnScreenshot(jpeg: Data(), label: "main display", isCursorScreen: true, pixelSize: CGSize(width: 1280, height: 832),
                              displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 832))
    #expect(canvas.describeOnScreen(for: shot) == nil)
    let session = try #require(canvas.drawing(for: shot, image: nil, continuing: true)?.session)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now))
    session.append(cardProgram)
    session.end()
    await session.settle()
    clock.now += 10
    await session.settle()
    #expect(canvas.describeOnScreen(for: shot)?.contains("paper") == true)
    // A screenshot of another size (another display, a new resolution) gets a new drawing, so it is shown nothing.
    var other = shot
    other.pixelSize = CGSize(width: 2560, height: 1440)
    other.displayFrame = CGRect(x: 1280, y: 0, width: 1280, height: 720)
    #expect(!canvas.continues(other))
    #expect(canvas.describeOnScreen(for: other) == nil)
    #expect(canvas.continues(shot))
    // Escape cleared it: nothing to continue or describe.
    canvas.clear()
    await session.settle()
    #expect(canvas.describeOnScreen(for: shot) == nil)
    #expect(canvas.drawing(for: shot, image: nil, continuing: true)?.keep == false)
}

@MainActor
@Test func theDrawingFinishesWhenTheVoiceIsDoneWithLinesItStillHolds() async throws {
    let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["First line.", "Second line."])])
    await rig.ask()
    #expect(await rig.waitForRecords(1))
    let trace = rig.trace.all
    let drained = try #require(trace.lastIndex { $0 == "draw.lineFinished:1" })
    let finished = try #require(trace.firstIndex(of: "draw.finishNow"))
    #expect(finished > drained)
    #expect(trace.filter { $0 == "draw.cancel" }.isEmpty)

    // A typed answer drawn at once (no voice) has nothing to finish.
    let quiet = VoiceLoopRig(scripts: [ScriptedBrain.program(["Shown, not said."])])
    quiet.orchestrator.submitTyped("hi")
    #expect(await quiet.waitForRecords(1))
    #expect(!quiet.trace.all.contains("draw.finishNow"))
}

@Test func theDrawingStateBudgetIsTwelveThousandCharacters() {
    let long = String(repeating: "p1: box [10,10,200,100]\n", count: 500)
    var context = TurnContext()
    context.drawingOnScreen = long
    let notes = BrainTurnNotes.notes(for: TurnInput(words: "and now?", context: context))
    let shown = notes.components(separatedBy: "Your drawing still on screen:\n").last ?? ""
    #expect(shown.count >= 11_900)
    #expect(shown.count <= 12_100)
}

@MainActor
@Test func aRealDrawingIsContinuedEditedAndClickedThroughTheTurnLoop() async throws {
    let trace = VoiceTrace()
    let brain = ScriptedBrain(trace: trace, scripts: [
        [.init(delay: 0.02, event: .programDelta("const card = paper(100, 100, 420, 300, {title: \"Plan\"})\n")),
         .init(delay: 0, event: .programDelta("write(card.x + 10, card.y + 40, \"Step one\")\n")),
         .init(delay: 0, event: .programDelta("button(card.x + 10, card.y + 200, \"Show step two\")\n")),
         .init(delay: 0.01, event: .finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: nil, model: "s", firstTokenSeconds: 0, totalSeconds: 0)))],
        [.init(delay: 0.02, event: .programDelta("recolor(\"p2\", \"red\")\nwrite(card.x + 10, card.y + 80, \"Step two\")\n")),
         .init(delay: 0.01, event: .finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: nil, model: "s", firstTokenSeconds: 0, totalSeconds: 0)))],
    ])
    let screen = StillImageScreen(imageData: StillImageScreen.blankCanvas(width: 1280, height: 832))
    let surfaces = CanvasDrawingSurfaces()
    let services = TurnOrchestrator.Services(microphone: nil, speechToText: { SimulatedSpeechToText(text: "") }, screen: screen,
                                             brain: brain, narrator: nil, drawings: surfaces)
    let orchestrator = TurnOrchestrator(services: services)
    var records: [TurnRecord] = []
    orchestrator.onTurnFinished = { records.append($0) }
    surfaces.canvas.onAsk = { orchestrator.submitTyped($0) }
    var problems: [DrawingEvent] = []
    surfaces.canvas.onEvent = { if case .error = $0 { problems.append($0) } }

    orchestrator.submitTyped("plan it")
    while records.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
    while surfaces.session?.isDrawing == true { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(600))
    let router = try #require(surfaces.canvas.router)
    await router.refresh()
    let button = try #require(surfaces.session?.painter.visibleButtons().first)
    #expect(button.text == "Show step two")

    // The user clicks the drawn button: its words become the next typed turn, which sees and continues the drawing.
    router.pointerDown(at: CGPoint(x: button.frame.midX, y: button.frame.midY))
    #expect(router.pointerUp(at: CGPoint(x: button.frame.midX, y: button.frame.midY)) == .asked(button: button.id))
    while records.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(brain.inputs[1].words == "Show step two")
    let seen = try #require(brain.inputs[1].context.drawingOnScreen)
    #expect(seen.contains("p1 (card): paper"))
    #expect(seen.contains("Step one"))
    #expect(surfaces.canvas.sessionsMade == 1)
    while surfaces.session?.isDrawing == true { try await Task.sleep(for: .milliseconds(10)) }
    let after = try #require(surfaces.describeOnScreen())
    #expect(after.contains("Step two") && after.contains("turn 2"))
    #expect(problems.isEmpty, "\(problems)")
    // The edit recoloured the first turn's words.
    let words = try #require(surfaces.session?.painter.entries.values.first { $0.mark.json["text"]?.stringValue == "Step one" })
    #expect(words.mark.json["edit"]?.stringValue == "restyle")
}

// MARK: - The stale watch

private let front: Int32 = 100
private let own: Int32 = 1
private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let editor = ScreenWindow(number: 10, ownerPID: front, ownerName: "TextEdit", bounds: CGRect(x: 100, y: 80, width: 900, height: 700))
private let menuBar = ScreenWindow(number: 1, ownerPID: 50, ownerName: "Window Server", layer: 24, bounds: CGRect(x: 0, y: 0, width: 1440, height: 30))
private let ownOverlay = ScreenWindow(number: 2, ownerPID: own, ownerName: "OpenClicky", layer: 1000, bounds: display)

@Test func theWatchFollowsTheWindowTheDrawingWasMadeOver() {
    let watch = DrawingStaleWatch(windows: [menuBar, ownOverlay, editor], frontPID: front, area: display, ignoring: [own])
    #expect(watch.watched == editor)
    var still = watch
    #expect(still.check(windows: [menuBar, ownOverlay, editor], frontPID: front) == nil)
    // A shadow-sized shift isn't a move.
    var nudged = editor
    nudged.bounds.origin.x += 3
    #expect(still.check(windows: [ownOverlay, nudged], frontPID: front) == nil)

    var moved = watch
    var dragged = editor
    dragged.bounds.origin.y += 40
    #expect(moved.check(windows: [dragged], frontPID: front) == .windowMoved)
    // Once stale, it stays stale.
    #expect(moved.check(windows: [editor], frontPID: front) == .windowMoved)

    var closed = watch
    #expect(closed.check(windows: [menuBar], frontPID: front) == .windowClosed)
}

@Test func theWatchNoticesAppsWindowsInFrontScrollingAndSpaces() {
    let watch = DrawingStaleWatch(windows: [editor], frontPID: front, area: display, ignoring: [own])
    var switched = watch
    #expect(switched.check(windows: [editor], frontPID: 200, frontName: "Safari") == .appChanged("Safari"))
    // OpenClicky itself coming forward (the typed question panel, Home) doesn't count.
    var ours = watch
    #expect(ours.check(windows: [editor], frontPID: own) == nil)

    let small = ScreenWindow(number: 30, ownerPID: 300, ownerName: "Notes", bounds: CGRect(x: 120, y: 100, width: 120, height: 80))
    let big = ScreenWindow(number: 31, ownerPID: 300, ownerName: "Notes", bounds: CGRect(x: 200, y: 150, width: 600, height: 500))
    var covered = watch
    #expect(covered.check(windows: [small, editor], frontPID: front) == nil)
    #expect(covered.check(windows: [big, editor], frontPID: front) == .covered(by: "Notes"))
    // A window already in front when the drawing began is part of what the drawing was made over.
    var before = DrawingStaleWatch(windows: [big, editor], frontPID: front, area: display, ignoring: [own])
    #expect(before.check(windows: [big, editor], frontPID: front) == nil)
    // Menus, panels and OpenClicky's own windows never cover.
    let menu = ScreenWindow(number: 40, ownerPID: front, ownerName: "TextEdit", layer: 101, bounds: CGRect(x: 100, y: 80, width: 900, height: 700))
    let ownPanel = ScreenWindow(number: 41, ownerPID: own, ownerName: "OpenClicky", bounds: CGRect(x: 100, y: 80, width: 900, height: 700))
    #expect(before.check(windows: [menu, ownPanel, big, editor], frontPID: front) == nil)

    var scrolling = watch
    #expect(scrolling.scroll(dx: 0, dy: 50, at: CGPoint(x: 1300, y: 850)) == nil) // beside the window
    #expect(scrolling.scrolled == 0)
    #expect(scrolling.scroll(dx: 0, dy: -50, at: CGPoint(x: 400, y: 400)) == nil)
    #expect(scrolling.scroll(dx: 0, dy: -40, at: CGPoint(x: 400, y: 400)) == .scrolled(90))

    var space = watch
    #expect(space.spaceChanged() == .spaceChanged)
}

@MainActor
@Test func theMonitorFiresOnceAndStopsWatching() {
    var windows = [editor]
    var frontApp: (pid: Int32, name: String)? = (front, "TextEdit")
    let monitor = DrawingStaleMonitor(sources: .init(windows: { windows }, frontApp: { frontApp }), ignoring: [own], observesSystem: false)
    var reasons: [DrawingStaleReason] = []
    monitor.onStale = { reasons.append($0) }
    monitor.arm(area: display)
    #expect(monitor.isArmed)
    monitor.poll()
    #expect(reasons.isEmpty)
    windows[0].bounds.origin.x += 100
    monitor.poll()
    monitor.poll()
    #expect(reasons == [.windowMoved])
    #expect(!monitor.isArmed)
    monitor.arm(area: display)
    frontApp = (500, "Finder")
    monitor.poll()
    #expect(reasons == [.windowMoved, .appChanged("Finder")])
}

@MainActor
@Test func aStaleScreenTakesScreenMarksAwayAndKeepsCards() async throws {
    let clock = futureClock()
    let canvas = DrawingDisplayCanvas(stage: FigureStage(drivesItself: false))
    canvas.clock = { clock.now }
    canvas.offscreen = true
    let shot = TurnScreenshot(jpeg: Data(), label: "main display", isCursorScreen: true, pixelSize: CGSize(width: 1280, height: 832),
                              displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 832))
    let session = try #require(canvas.drawing(for: shot, image: nil, continuing: false)?.session)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now))
    session.append(cardProgram)
    session.end()
    await session.settle()
    clock.now += 10
    await session.settle()
    #expect(await canvas.screenChanged() == 1)
    #expect(canvas.hasVisibleDrawing)
    #expect(!session.painter.markIDs.contains { session.painter.entries[$0]?.mark.kind == "circle" })

    // Only screen marks: the stale screen clears everything.
    let next = try #require(canvas.drawing(for: shot, image: nil, continuing: false)?.session)
    next.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now))
    next.append("point(300, 300, \"Here\")\ncircle(700, 400, 30)\n")
    next.end()
    await next.settle()
    clock.now += 10
    await next.settle()
    #expect(canvas.hasVisibleDrawing)
    #expect(await canvas.screenChanged() == 0)
    await next.settle()
    #expect(!canvas.hasVisibleDrawing)
}

@MainActor
@Test func aScreenChangeMidAnswerLetsTheAnswerFinishAndThenSettlesIt() async throws {
    let clock = futureClock()
    let canvas = DrawingDisplayCanvas(stage: FigureStage(drivesItself: false))
    canvas.clock = { clock.now }
    canvas.offscreen = true
    let shot = TurnScreenshot(jpeg: Data(), label: "main display", isCursorScreen: true, pixelSize: CGSize(width: 1280, height: 832),
                              displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 832))
    let session = try #require(canvas.drawing(for: shot, image: nil, continuing: false)?.session)
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech))
    session.append("""
    step(1)
    say("This one.")
    circle(300, 300, 40)
    step(2)
    say("And that one.")

    """)
    session.lineStarted(0, expectedDuration: 1)
    await session.settle()
    clock.now += 3
    await session.settle()
    let circles = { session.painter.entries.values.filter { $0.mark.kind == "circle" }.count }
    #expect(circles() == 1)
    #expect(session.isDrawing)

    // The user switches apps while the voice is still on line 1: the first ring goes, but the answer isn't cut off and
    // what it still sends is drawn.
    #expect(await canvas.screenChanged() == 0)
    await session.settle()
    #expect(session.isDrawing)
    #expect(circles() == 0)
    session.append("circle(800, 500, 40)\n")
    session.end()
    await session.settle()
    session.lineFinished(0)
    session.lineStarted(1, expectedDuration: 1)
    await session.settle()
    clock.now += 3
    await session.settle()
    #expect(circles() == 1)

    // Once the answer is done, what it drew for the old screen goes too (no card is left, so everything goes).
    session.lineFinished(1)
    clock.now += 3
    for _ in 0..<50 where canvas.hasVisibleDrawing {
        session.tick()
        await session.settle()
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!session.isDrawing)
    #expect(!canvas.hasVisibleDrawing)

    // A follow-up that starts while a stale answer is still drawing is drawn for the screen as it is now: the stale
    // pass waiting for the old answer to finish never touches it.
    let carded = try #require(canvas.drawing(for: shot, image: nil, continuing: false)?.session)
    carded.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech))
    carded.append("step(1)\nsay(\"A card.\")\nconst card = paper(100, 100, 420, 300)\nstep(2)\nsay(\"A ring.\")\ncircle(1000, 650, 40)\n")
    carded.end()
    carded.lineStarted(0, expectedDuration: 1)
    await carded.settle()
    clock.now += 3
    await carded.settle()
    #expect(await canvas.screenChanged() == 1)
    #expect(carded.isDrawing)
    let (followUp, keep) = try #require(canvas.drawing(for: shot, image: nil, continuing: true))
    #expect(followUp === carded && keep)
    var options = DrawingBeginOptions(width: 1280, height: 832, pace: .now)
    options.keep = true
    followUp.begin(options)
    followUp.append("circle(700, 600, 30)\n")
    followUp.end()
    await followUp.settle()
    clock.now += 3
    for _ in 0..<50 where followUp.isDrawing {
        followUp.tick()
        await followUp.settle()
        try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(100))
    await followUp.settle()
    #expect(!followUp.isDrawing)
    #expect(followUp.painter.entries.values.contains { $0.mark.kind == "circle" })
    #expect(canvas.hasVisibleDrawing)
}

@MainActor
@Test func linkedWordsAndActionButtonsUseTheOverlayPointerRouter() async throws {
    let clock = futureClock()
    let session = try await drawnSession("""
    text(100, 100, "Read [the docs](https://example.com/docs)")
    button(100, 220, "Copy", {copy: "fixture words"})
    """, clock: clock)
    var actions: [DrawingAction] = []
    session.onEvent = { if case .action(let action) = $0 { actions.append(action) } }
    let router = DrawingPointerRouter(session: session)
    await router.refresh()
    let controls = session.painter.visibleButtons()
    #expect(controls.count == 2)
    for control in controls {
        let point = CGPoint(x: control.frame.midX, y: control.frame.midY)
        #expect(router.target(at: point) == .button(control.id))
        router.pointerDown(at: point)
        _ = router.pointerUp(at: point)
        await session.settle()
    }
    #expect(actions.count == 2)
    #expect(actions.contains { $0.role == .open && $0.url?.absoluteString == "https://example.com/docs" })
    #expect(actions.contains { $0.role == .copy && $0.text == "fixture words" })
    #expect(actions.allSatisfy { $0.fromClick })
}
