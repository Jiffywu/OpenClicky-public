import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// Guided walkthroughs: placing and snapping targets, the trigger state machine, guided markers from drawings, the
// controller's hooks for the orchestrator, and the classic tag grammar.

private func element(_ id: String, _ role: String, _ frame: CGRect, label: String? = nil, enabled: Bool = true, subrole: String? = nil) -> ElementSnapshot {
    ElementSnapshot(id: id, role: role, subrole: subrole, title: label, frame: frame, isEnabled: enabled)
}

private func ring(_ center: CGPoint, label: String = "Save", hover: Bool = false, id: Int = 1) -> GuidedTarget {
    GuidedTarget(id: id, label: label, isHover: hover, requestedFrame: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40))
}

private func turns(_ effects: [GuidedEffect]) -> [GuidedTurnRequest] {
    effects.compactMap { if case .startTurn(let request) = $0 { request } else { nil } }
}

private func ended(_ effects: [GuidedEffect]) -> GuidedEndReason? {
    effects.compactMap { if case .ended(let reason) = $0 { reason } else { nil } }.first
}

@Suite struct GuidedSnappingTests {
    // A table cell holding a button, in AppKit global points.
    let cell = element("e1", "AXCell", CGRect(x: 100, y: 500, width: 300, height: 40), label: "Invoice 42")
    let button = element("e2", "AXButton", CGRect(x: 320, y: 505, width: 70, height: 30), label: "Open")

    @Test func aButtonInsideACellWinsWhenTheBoxIsAroundTheButton() throws {
        let snap = try #require(GuidedTargetSnapper.choose(for: CGRect(x: 325, y: 508, width: 60, height: 24), among: [cell, button]))
        #expect(snap.element.id == "e2")
        #expect(snap.reason == .containsCenter)
    }

    @Test func theCellWinsWhenTheBoxIsAroundTheWholeCell() throws {
        let snap = try #require(GuidedTargetSnapper.choose(for: CGRect(x: 102, y: 501, width: 296, height: 38), among: [cell, button]))
        #expect(snap.element.id == "e1")
    }

    @Test func containersHugeAndUnclickableElementsAreNeverTargets() {
        let group = element("e3", "AXGroup", CGRect(x: 0, y: 0, width: 400, height: 400))
        let web = element("e4", "AXWebArea", CGRect(x: 0, y: 0, width: 800, height: 600))
        let banner = element("e5", "AXButton", CGRect(x: 0, y: 0, width: 1200, height: 60))
        let text = element("e6", "AXStaticText", CGRect(x: 10, y: 10, width: 80, height: 20), label: "Hello")
        #expect(GuidedTargetSnapper.choose(for: CGRect(x: 20, y: 12, width: 40, height: 16), among: [group, web, banner, text]) == nil)
        // A toolbar button counts by its subrole.
        let tool = element("e7", "AXImage", CGRect(x: 10, y: 10, width: 28, height: 28), subrole: "AXToolbarButton")
        #expect(GuidedTargetSnapper.choose(for: CGRect(x: 14, y: 14, width: 20, height: 20), among: [tool])?.element.id == "e7")
    }

    @Test func anOffsetBoxSnapsByOverlapThenByDistance() throws {
        let save = element("e8", "AXButton", CGRect(x: 600, y: 300, width: 80, height: 30), label: "Save")
        // Centre just outside, but more than 30% overlap.
        let overlap = try #require(GuidedTargetSnapper.choose(for: CGRect(x: 640, y: 290, width: 60, height: 30), among: [save]))
        #expect(overlap.reason == .overlaps || overlap.reason == .containsCenter)
        // A small box 20 pt to the left: nearby.
        let near = try #require(GuidedTargetSnapper.choose(for: CGRect(x: 570, y: 310, width: 10, height: 10), among: [save]))
        #expect(near.reason == .nearby)
        #expect(abs(near.distance - 25) < 0.01)
        // Too far: keep the brain's own box.
        #expect(GuidedTargetSnapper.choose(for: CGRect(x: 500, y: 310, width: 10, height: 10), among: [save]) == nil)
    }

    @Test func anEnabledControlBeatsADisabledOneThatFitsBetter() throws {
        let disabled = element("e9", "AXButton", CGRect(x: 100, y: 100, width: 60, height: 30), label: "Delete", enabled: false)
        let enabled = element("e10", "AXButton", CGRect(x: 90, y: 95, width: 120, height: 40), label: "Options")
        let snap = try #require(GuidedTargetSnapper.choose(for: CGRect(x: 102, y: 102, width: 56, height: 26), among: [disabled, enabled]))
        #expect(snap.element.id == "e10")
    }

    @Test func requestsArePlacedFromScreenshotPixelsAndSnapped() throws {
        // A 1512×982 pt display shot at 1280×831 px, on the left of the main display.
        let geometry = CaptureGeometry(displayFrame: CGRect(x: -1512, y: 0, width: 1512, height: 982), pixelWidth: 1280, pixelHeight: 831)
        let save = element("e1", "AXButton", geometry.appKitRect(fromPixelRect: CGRect(x: 1100, y: 40, width: 80, height: 28)), label: "Save")
        let screen = GuidedScreen(geometry: geometry, elements: [save])
        // A ring the brain drew a little off the button's centre.
        let ringTarget = try #require(screen.target(for: GuidedTargetRequest(.pixelRing(center: CGPoint(x: 1130, y: 50), radius: 14), label: "Save"), id: 1))
        #expect(ringTarget.element?.id == "e1")
        #expect(ringTarget.snap == .containsCenter)
        #expect(ringTarget.isControlOutline)
        // By element id.
        let named = try #require(screen.target(for: GuidedTargetRequest(.element("e1")), id: 2))
        #expect(named.snap == .named && named.name == "Save")
        #expect(screen.target(for: GuidedTargetRequest(.element("e99")), id: 3) == nil)
        // Nothing near: the brain's box, converted to global points.
        let empty = try #require(screen.target(for: GuidedTargetRequest(.pixelRect(CGRect(x: 100, y: 700, width: 50, height: 20))), id: 4))
        #expect(empty.element == nil && empty.snap == .none)
        let expected = geometry.appKitRect(fromPixelRect: CGRect(x: 100, y: 700, width: 50, height: 20))
        #expect(abs(empty.frame.minX - expected.minX) < 0.01 && abs(empty.frame.minY - expected.minY) < 0.01)
        #expect(empty.frame.minX < 0)  // on the left display
    }

    @Test func theLiveHitTestIsTheLastResort() throws {
        struct Locator: GuidedElementLocating {
            func element(at point: CGPoint) -> ElementSnapshot? {
                ElementSnapshot(id: "hit", role: "AXButton", title: "Share", frame: CGRect(x: point.x - 30, y: point.y - 12, width: 60, height: 24))
            }
        }
        let screen = GuidedScreen(geometry: CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800))
        let target = try #require(screen.target(for: GuidedTargetRequest(.pixelRect(CGRect(x: 600, y: 300, width: 20, height: 20))), id: 1, locator: Locator()))
        #expect(target.snap == .hitTest && target.name == "Share")
    }

    @Test func hitsCountOnTheSnappedControlOrInsideTheRing() {
        let snapped = GuidedTarget(id: 1, label: "Save", requestedFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                   element: element("e1", "AXButton", CGRect(x: 100, y: 100, width: 80, height: 30)), snap: .containsCenter)
        #expect(snapped.contains(CGPoint(x: 178, y: 128)))
        #expect(snapped.contains(CGPoint(x: 184, y: 128)))       // within the 6 pt slop
        #expect(!snapped.contains(CGPoint(x: 5, y: 5)))          // the brain's box no longer counts
        let ringOnly = ring(CGPoint(x: 400, y: 400))
        #expect(ringOnly.radius == 28.284271247461902)
        #expect(ringOnly.contains(CGPoint(x: 430, y: 400)))
        #expect(!ringOnly.contains(CGPoint(x: 440, y: 400)))
    }
}

@Suite struct GuidedTriggerTests {
    @Test func aClickOnTheTargetStartsOneClickedTargetTurn() throws {
        var w = GuidedWalkthrough()
        w.setTask("Export a PDF")
        #expect(w.arm(ring(CGPoint(x: 100, y: 100), label: "File"), at: 0).first == .showTarget(ring(CGPoint(x: 100, y: 100), label: "File")))
        let effects = w.handle(.mouseDown(CGPoint(x: 104, y: 98)), at: 2)
        let request = try #require(turns(effects).first)
        #expect(effects.first == .clearTarget)
        #expect(request.trigger == .clickedTarget && request.step == 1 && request.remainingRounds == 11)
        #expect(request.targetLabel == "File")
        #expect(request.notes[0].contains("\"Export a PDF\"") && request.notes[0].contains("clicked \"File\""))
        #expect(w.phase == .followingUp)
        // A double click's second press, inside the grace period, is not a new step and not stale-screen activity.
        #expect(w.handle(.mouseDown(CGPoint(x: 104, y: 98)), at: 2.2).isEmpty)
    }

    @Test func stepsChainThroughFollowUpTurnsAndKeepAHistory() throws {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100), label: "File"), at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 100, y: 100)), at: 1)
        // The follow-up answer arms the next step.
        _ = w.arm(ring(CGPoint(x: 120, y: 60), label: "Export…", id: 2), at: 3)
        let second = try #require(turns(w.handle(.mouseDown(CGPoint(x: 121, y: 61)), at: 4)).first)
        #expect(second.step == 2 && second.remainingRounds == 10)
        #expect(second.notes.last?.contains("1. Clicked \"File\"") == true)
        #expect(second.notes.last?.contains("2. Clicked \"Export…\"") == true)
        // The next answer gives no further step: done.
        #expect(ended(w.answerFinished(at: 6)) == .completed)
        #expect(!w.isActive)
    }

    @Test func aClickElsewhereEndsTheGuideQuietly() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        let effects = w.handle(.mouseDown(CGPoint(x: 600, y: 600)), at: 1)
        #expect(turns(effects).isEmpty)
        #expect(effects == [.clearTarget, .ended(.offTarget)])
        // With off-target ending switched off, stray clicks are ignored.
        var lenient = GuidedWalkthrough(settings: { var s = GuidedWalkthrough.Settings(); s.offTargetEnds = false; return s }())
        _ = lenient.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        #expect(lenient.handle(.mouseDown(CGPoint(x: 600, y: 600)), at: 1).isEmpty)
        #expect(lenient.phase == .armed)
    }

    @Test func manualWorkAdvancesWithDidStepOnceTheUserPauses() throws {
        var w = GuidedWalkthrough()
        _ = w.expectManualStep("Type your name", at: 0)
        #expect(w.tick(at: 5).isEmpty)                       // nothing done yet
        _ = w.handle(.keyDown, at: 6)
        _ = w.handle(.keyDown, at: 6.5)
        #expect(w.tick(at: 7.0).isEmpty)                     // still typing (0.5 s since the last key)
        _ = w.handle(.scroll, at: 7.2)
        #expect(w.tick(at: 8.0).isEmpty)
        let request = try #require(turns(w.tick(at: 8.5)).first)   // 1.3 s of quiet
        #expect(request.trigger == .didStep && request.step == 1)
        #expect(request.notes[0].contains("can't watch"))
        #expect(w.tick(at: 20).isEmpty)                      // one turn only
    }

    @Test func aHoverTargetCompletesWhenThePointerRests() throws {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 300, y: 300), label: "Preview", hover: true), at: 0)
        _ = w.handle(.mouseMoved(CGPoint(x: 305, y: 300)), at: 1)
        _ = w.handle(.mouseMoved(CGPoint(x: 700, y: 300)), at: 1.3)    // passed over, didn't rest
        #expect(w.tick(at: 1.8).isEmpty)
        _ = w.handle(.mouseMoved(CGPoint(x: 300, y: 296)), at: 2)
        #expect(w.tick(at: 2.4).isEmpty)
        let request = try #require(turns(w.tick(at: 2.7)).first)
        #expect(request.trigger == .clickedTarget)
        #expect(request.notes[0].contains("rested the pointer on \"Preview\""))
    }

    @Test func targetsExpireAndSteppingAwayEndsTheGuide() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        #expect(ended(w.tick(at: 179)) == nil)
        #expect(ended(w.tick(at: 181)) == .expired)
        var other = GuidedWalkthrough()
        _ = other.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        #expect(ended(other.handle(.appChanged("com.apple.Safari"), at: 3)) == .steppedAway)
        var escaped = GuidedWalkthrough()
        _ = escaped.expectManualStep(at: 0)
        #expect(ended(escaped.handle(.escape, at: 1)) == .stopped)
    }

    @Test func theRoundLimitStopsAutomaticSteps() {
        var settings = GuidedWalkthrough.Settings()
        settings.maxRounds = 2
        var w = GuidedWalkthrough(settings: settings)
        _ = w.arm(ring(CGPoint(x: 10, y: 10)), at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 10, y: 10)), at: 1)
        _ = w.arm(ring(CGPoint(x: 10, y: 10), id: 2), at: 2)
        let last = turns(w.handle(.mouseDown(CGPoint(x: 10, y: 10)), at: 3))
        #expect(last.first?.remainingRounds == 0)
        #expect(last.first?.notes.contains { $0.contains("No automatic steps are left") } == true)
        // The next answer arms anyway: refused, the walkthrough ends.
        #expect(ended(w.arm(ring(CGPoint(x: 10, y: 10), id: 3), at: 4)) == .maxRounds)
    }

    @Test func theUsersOwnTurnDisarmsButKeepsTheWalkthrough() {
        var w = GuidedWalkthrough()
        w.setTask("Share a file")
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        #expect(w.userTurnStarted(at: 1) == [.clearTarget])
        #expect(w.isActive && w.task == "Share a file")
        // The answer to the user's question gives the next step: same walkthrough, same counter.
        _ = w.arm(ring(CGPoint(x: 200, y: 200), id: 2), at: 2)
        #expect(turns(w.handle(.mouseDown(CGPoint(x: 200, y: 200)), at: 3)).first?.step == 1)
    }

    @Test func actingWhileTheFollowUpIsPreparedAsksForOneFreshCapture() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 100, y: 100)), at: 1)
        #expect(w.handle(.scroll, at: 1.3).isEmpty)                 // grace
        #expect(w.handle(.scroll, at: 2) == [.refreshCapture])
        #expect(w.handle(.keyDown, at: 2.5).isEmpty)                // only once
    }

    @Test func aNewTaskAfterAFinishedOneStartsCountingAgain() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 1, y: 1)), at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 1, y: 1)), at: 1)
        _ = w.answerFinished(at: 2)
        w.setTask("Something else")
        _ = w.arm(ring(CGPoint(x: 1, y: 1), id: 2), at: 3)
        #expect(w.completedSteps == 0 && w.task == "Something else" && w.status.step == 1)
        #expect(w.status.caption == "Click Save")
    }

    @MainActor @Test func theControllerHandsTurnRequestsToTheOrchestrator() async throws {
        var now: TimeInterval = 0
        let controller = GuidedWalkthroughController(clock: { now })
        controller.ownBundleIdentifiers = ["app.openclicky"]
        var requested: [GuidedTurnRequest] = []
        var shown: [GuidedTarget] = []
        controller.onTurnRequest = { requested.append($0) }
        controller.onEffect = { if case .showTarget(let t) = $0 { shown.append(t) } }
        let stream = controller.turnRequests()
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        let export = ElementSnapshot(id: "e4", role: "AXButton", title: "Export", frame: geometry.appKitRect(fromPixelRect: CGRect(x: 1000, y: 20, width: 90, height: 30)))
        controller.screen = GuidedScreen(geometry: geometry, elements: [export])
        controller.apply(.task("Export the report"))
        let target = try #require(controller.arm(GuidedTargetRequest(.pixelRect(CGRect(x: 1010, y: 25, width: 40, height: 20)), label: "Export")))
        #expect(shown.count == 1 && target.element?.id == "e4")
        controller.handle(.appChanged("app.openclicky"))     // OpenClicky itself coming forward is not stepping away
        #expect(controller.walkthrough.phase == .armed)
        now = 2
        controller.handle(.mouseDown(CGPoint(x: export.frame.midX, y: export.frame.midY)))
        let request = try #require(requested.first)
        var input = TurnInput(words: "leftover", appNotes: ["[App] earlier note"])
        request.apply(to: &input)
        #expect(input.words.isEmpty && input.context.trigger == "clicked_target")
        #expect(input.appNotes.first?.contains("Export the report") == true && input.appNotes.last == "[App] earlier note")
        var iterator = stream.makeAsyncIterator()
        let streamed = await iterator.next()
        #expect(streamed == request)
        controller.stop()
        #expect(controller.walkthrough.phase == .ended(.stopped) || controller.walkthrough.phase == .followingUp)
    }
}

@Suite struct GuidedMarkerTests {
    private func released(_ program: String) throws -> [DrawingMark] {
        let host = try DrawingEngineHost()
        var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
        events += host.perform(.append(program))
        events += host.perform(.end)
        events += host.perform(.drain)
        return events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
    }

    @Test func drawingsNameTargetsHoversTasksAndManualSteps() throws {
        let marks = try released("""
        task("Export the report")
        step(1)
        say("Click Export at the top right.")
        target(1000, 20, 90, 30, "Export")
        """)
        let markers = marks.compactMap(GuidedMarker.init(mark:))
        #expect(markers == [.task("Export the report"),
                            .target(GuidedTargetRequest(.pixelRect(CGRect(x: 1000, y: 20, width: 90, height: 30)), label: "Export"))])
        let byID = try released(#"hover("e12", "Preview")"#).compactMap(GuidedMarker.init(mark:))
        #expect(byID == [.target(GuidedTargetRequest(.element("e12"), label: "Preview", isHover: true))])
        let ringForm = try released(#"target(640, 400, 18, "OK")"#).compactMap(GuidedMarker.init(mark:))
        #expect(ringForm == [.target(GuidedTargetRequest(.pixelRing(center: CGPoint(x: 640, y: 400), radius: 18), label: "OK"))])
        let manual = try released(#"waitForUser("Type your name")"#).compactMap(GuidedMarker.init(mark:))
        #expect(manual == [.wait("Type your name")])
    }

    @Test func oneTargetPerAnswerAndNeverWithManualWork() throws {
        let host = try DrawingEngineHost()
        var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
        events += host.perform(.append("target(10, 10, 40, 20, \"A\")\ntarget(100, 10, 40, 20, \"B\")\nwaitForUser()\ntarget(\"not an id!\")\n"))
        events += host.perform(.end)
        events += host.perform(.drain)
        let marks = events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
        #expect(marks.compactMap(GuidedMarker.init(mark:)).count == 2)   // the first target and the wait
        let warnings = events.compactMap { if case .warning(let m) = $0 { m } else { nil } }
        #expect(warnings.contains { $0.contains("one target() or hover() per answer") })
        #expect(warnings.contains { $0.contains("don't go together") })
        #expect(warnings.contains { $0.contains("element id") })
    }

    @MainActor @Test func aSessionArmsTheTargetWhenItsLineIsHeard() async throws {
        var now: TimeInterval = 0
        let controller = GuidedWalkthroughController(clock: { now })
        controller.screen = GuidedScreen(geometry: CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelWidth: 800, pixelHeight: 600))
        let session = try DrawingSession(canvas: .init(width: 800, height: 600))
        DrawingSnapshot.adopt(session.layer)
        session.onMarks = { controller.apply(marks: $0) }
        session.begin(DrawingBeginOptions(width: 800, height: 600, pace: .speech))
        session.append("step(1)\nsay(\"Open the File menu.\")\ntarget(20, 4, 40, 18, \"File\")\n")
        session.end()
        await session.settle()
        #expect(controller.walkthrough.phase == .idle)     // not before its line
        session.lineStarted(0, expectedDuration: 1.5)
        await session.settle()
        #expect(controller.walkthrough.phase == .armed)
        #expect(controller.target?.label == "File")
        now = 1
        controller.stop()
    }
}

@Suite struct PointingTagTests {
    @Test func tagFirstLinesBecomeBeats() {
        let beats = PointingTagParser.parse("""
        [POINT:812,96:Share] This is the Share button.
        It sends a link.
        [HIGHLIGHT:20,90,230,600:Files:screen2] Your files live here.
        [TARGET:640,410,18:Export] Click Export.
        [HOVER:300,40:Preview] Rest on Preview.
        [SHAPE:arrow:200,300;420,300:drag here] Drag it across.
        [POINT:none] That's all there is.
        """)
        #expect(beats.count == 6)
        #expect(beats[0] == PointingBeat(visual: .point(CGPoint(x: 812, y: 96), label: "Share", screen: nil), spoken: "This is the Share button. It sends a link."))
        #expect(beats[1].visual == .highlight(CGRect(x: 20, y: 90, width: 230, height: 600), label: "Files", screen: 2))
        #expect(beats[2].visual?.guidedRequest == GuidedTargetRequest(.pixelRing(center: CGPoint(x: 640, y: 410), radius: 18), label: "Export"))
        #expect(beats[3].visual == .target(center: CGPoint(x: 300, y: 40), radius: nil, label: "Preview", screen: nil, hover: true))
        #expect(beats[4].visual == .shape(kind: .arrow, points: [CGPoint(x: 200, y: 300), CGPoint(x: 420, y: 300)], label: "drag here", screen: nil))
        #expect(beats[5].visual == .pointNone)
    }

    @Test func typedTextSpansLinesAndBadTagsKeepTheirWords() {
        let beats = PointingTagParser.parse("""
        [TYPE:500,220:Name]<<<
        Jeff
        Nguyen
        >>> I typed your name.
        [POINT:12,abc:Oops] Still said.
        Inline [POINT:1,2] tags are removed from speech.
        """)
        #expect(beats[0].visual == .type(at: CGPoint(x: 500, y: 220), label: "Name", screen: nil, text: "Jeff\nNguyen"))
        #expect(beats[0].spoken == "I typed your name.")
        #expect(beats[1].visual == nil && beats[1].spoken == "Still said. Inline tags are removed from speech.")
        #expect(PointingTagParser.spokenText("[POINT:1,2:x] Hi there.\n[TARGET:5,5:y] Click.") == "Hi there. Click.")
    }
}

@Suite struct GuidedSimulatorTests {
    @MainActor @Test func aScriptedWalkthroughStartsTheRightTurnsInOrder() throws {
        let script = GuidedScript(
            screen: .init(width: 1280, height: 800),
            elements: [.init(id: "e1", role: "AXMenuBarItem", label: "File", box: [70, 2, 40, 22]),
                       .init(id: "e2", role: "AXMenuItem", label: "Export To", box: [64, 82, 220, 24]),
                       .init(id: "e3", role: "AXButton", label: "Save", box: [740, 360, 80, 30])],
            events: [
                .init(at: 0, answer: "task(\"Export\")\nsay(\"Open File.\")\ntarget(66, 0, 50, 26, \"File\")"),
                .init(at: 1, click: [88, 12]),
                .init(at: 1.2, click: [88, 12]),                                   // inside the grace period
                .init(at: 2, answer: "say(\"Choose Export To.\")\ntarget(\"e2\")"),
                .init(at: 3, click: [150, 94]),
                .init(at: 4, answer: "say(\"Name it.\")\nwaitForUser(\"Type a name\")"),
                .init(at: 5, key: true),
                .init(at: 5.4, key: true),
                .init(at: 8, answer: "say(\"Click Save.\")\ntarget(745, 362, 70, 26, \"Save\")"),
                .init(at: 9, click: [780, 375]),
                .init(at: 10, answer: "say(\"Done.\")"),
            ])
        let result = try GuidedSimulator.run(script)
        #expect(result.requests.map(\.trigger) == [.clickedTarget, .clickedTarget, .didStep, .clickedTarget])
        #expect(result.requests.map(\.step) == [1, 2, 3, 4])
        #expect(result.targets.map { $0.target.element?.id } == ["e1", "e2", "e3"])
        #expect(result.phase == .ended(.completed))
        #expect(result.log.contains { $0.contains("START TURN trigger=did_step step=3") })
        #expect(script.mockScreen()?.width == 1280)
    }
}

/// Review fixes: drags on manual steps, brushed talk keys, and follow-ups that never report back.
@Suite struct GuidedRobustnessTests {
    @Test func aLongDragIsStillWorkOnAManualStep() throws {
        var w = GuidedWalkthrough()
        _ = w.expectManualStep("Drag the slider to 50%", at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 400, y: 300)), at: 1)
        // Dragging for two seconds: no turn while the button is held and the pointer moves.
        for t in stride(from: 1.2, through: 3.0, by: 0.2) {
            _ = w.handle(.mouseDragged(CGPoint(x: 400 + t * 20, y: 300)), at: t)
            #expect(w.tick(at: t + 0.05).isEmpty, "a turn started mid-drag at \(t)")
        }
        #expect(w.tick(at: 4.0).isEmpty)                                  // 1.0 s after the drag ended
        let request = try #require(turns(w.tick(at: 4.3)).first)          // 1.3 s of quiet
        #expect(request.trigger == .didStep)
        // A drag while the follow-up is prepared is activity too: one fresh capture.
        #expect(w.handle(.mouseDragged(CGPoint(x: 10, y: 10)), at: 5.5) == [.refreshCapture])
    }

    @Test func aDragOverAHoverTargetCountsAsResting() throws {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 300, y: 300), label: "Preview", hover: true), at: 0)
        _ = w.handle(.mouseDragged(CGPoint(x: 302, y: 300)), at: 1)
        #expect(turns(w.tick(at: 1.7)).first?.trigger == .clickedTarget)
    }

    @Test func aBrushedTalkKeyPutsTheTargetBack() throws {
        var w = GuidedWalkthrough()
        w.setTask("Export a PDF")
        let file = ring(CGPoint(x: 100, y: 100), label: "File")
        _ = w.arm(file, at: 0)
        #expect(w.userTurnStarted(at: 10) == [.clearTarget])
        // The chord was only brushed (no turn): the same target is shown again and waits afresh.
        #expect(w.userTurnCancelled(at: 10.1) == [.showTarget(file)])
        #expect(w.phase == .armed && w.target == file)
        #expect(!w.log.contains { $0.line.contains("asked something") })
        #expect(ended(w.tick(at: 185)) == nil)                         // the 180 s lifetime restarted at 10.1
        let request = try #require(turns(w.handle(.mouseDown(CGPoint(x: 100, y: 100)), at: 186)).first)
        #expect(request.trigger == .clickedTarget && request.step == 1)
        // Nothing to restore: no effect.
        #expect(w.userTurnCancelled(at: 187).isEmpty)
    }

    @Test func aBrushedTalkKeyKeepsAManualStepWaiting() throws {
        var w = GuidedWalkthrough()
        _ = w.expectManualStep("Type a file name", at: 0)
        #expect(w.userTurnStarted(at: 1).isEmpty)
        #expect(w.phase == .followingUp)
        #expect(w.userTurnCancelled(at: 1.2).isEmpty)
        #expect(w.phase == .manual && w.manualNote == "Type a file name")
        _ = w.handle(.keyDown, at: 2)
        #expect(turns(w.tick(at: 3.4)).first?.trigger == .didStep)
    }

    @Test func aUserTurnThatWentAheadIsNotUndone() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        _ = w.userTurnStarted(at: 1)
        // The answer to the user's question armed the next step; a late cancel must not bring the old one back.
        let next = ring(CGPoint(x: 400, y: 400), label: "Export", id: 2)
        _ = w.arm(next, at: 3)
        #expect(w.userTurnCancelled(at: 4).isEmpty)
        #expect(w.target == next)
    }

    @Test func aFollowUpThatNeverReportsBackExpires() {
        var w = GuidedWalkthrough()
        _ = w.arm(ring(CGPoint(x: 100, y: 100)), at: 0)
        _ = w.handle(.mouseDown(CGPoint(x: 100, y: 100)), at: 1)
        #expect(w.phase == .followingUp)
        #expect(w.tick(at: 100).isEmpty)
        #expect(ended(w.tick(at: 121.5)) == .expired)
        #expect(!w.isActive && w.status.caption.isEmpty)
    }

    @MainActor @Test func theControllerKeepsTickingWhileAFollowUpIsPrepared() async throws {
        var settings = GuidedWalkthrough.Settings()
        settings.followUpLimit = 0.2
        let controller = GuidedWalkthroughController(settings: settings, tickInterval: 0.02)
        var endings: [GuidedEndReason] = []
        controller.onEffect = { if case .ended(let reason) = $0 { endings.append(reason) } }
        controller.arm(ring(CGPoint(x: 50, y: 50)))
        controller.handle(.mouseDown(CGPoint(x: 50, y: 50)))
        #expect(controller.walkthrough.phase == .followingUp)
        // Nobody answers: the controller's own ticks end it.
        let deadline = Date().addingTimeInterval(5)
        while endings.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(endings == [.expired])
    }
}

/// Review fix: a target released just before the user barged in must not arm during their new turn.
@Suite struct GuidedBargeInTests {
    @MainActor @Test func marksFromACancelledDrawingDoNotArmATarget() async throws {
        let controller = GuidedWalkthroughController(clock: { 0 })
        controller.screen = GuidedScreen(geometry: CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelWidth: 800, pixelHeight: 600))
        let session = try DrawingSession(canvas: .init(width: 800, height: 600))
        DrawingSnapshot.adopt(session.layer)
        var seen = 0
        session.onMarks = { seen += $0.count; controller.apply(marks: $0) }
        session.begin(DrawingBeginOptions(width: 800, height: 600, pace: .speech))
        session.append("step(1)\nsay(\"Open the File menu.\")\ntarget(20, 4, 40, 18, \"File\")\n")
        session.end()
        // The line starts and the user barges in before its marks reach the main actor.
        session.lineStarted(0, expectedDuration: 1.5)
        session.cancel()
        await session.settle()
        #expect(seen == 0)
        #expect(controller.walkthrough.phase == .idle)
        // The next drawing's target still arms when its line is heard.
        session.begin(DrawingBeginOptions(width: 800, height: 600, pace: .speech))
        session.append("step(1)\nsay(\"Click Share.\")\ntarget(700, 40, 60, 24, \"Share\")\n")
        session.end()
        await session.settle()
        session.lineStarted(0, expectedDuration: 1)
        await session.settle()
        #expect(controller.walkthrough.phase == .armed && controller.target?.label == "Share")
    }
}
