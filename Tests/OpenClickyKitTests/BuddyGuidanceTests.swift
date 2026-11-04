import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// The buddy pointer during guided walkthroughs and pointing answers (BuddyGuidance through TurnPointingGuide): it flies
// to an armed target once, parks, flies back after the step, and vanishes when the user starts a turn or stops.

@MainActor
private final class Clock {
    var now: TimeInterval = 100
}

@MainActor
private struct Rig {
    let clock = Clock()
    let pointer = RecordingBuddyPointer()
    let guide: TurnPointingGuide
    let screen: GuidedScreen

    init(settings: GuidedWalkthrough.Settings = .init()) {
        let clock = self.clock
        let controller = GuidedWalkthroughController(settings: settings, clock: { clock.now })
        guide = TurnPointingGuide(guided: controller, clock: { clock.now })
        guide.buddy.pointer = pointer
        // A 1280 × 800 screenshot of a display twice as dense (640 × 400 points), placed right of the primary display.
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 1512, y: 0, width: 640, height: 400), pixelWidth: 1280, pixelHeight: 800)
        screen = GuidedScreen(geometry: geometry, elements: [
            ElementSnapshot(id: "e1", role: "AXButton", title: "Export", frame: geometry.appKitRect(fromPixelRect: CGRect(x: 200, y: 100, width: 120, height: 40))),
            ElementSnapshot(id: "e2", role: "AXButton", title: "Save", frame: geometry.appKitRect(fromPixelRect: CGRect(x: 600, y: 300, width: 100, height: 40))),
        ])
    }

    /// Runs a drawing program through the real engine and feeds its marks to the answer's handler, as the voice loop does.
    func answer(_ program: String) throws {
        let engine = try DrawingEngineHost(prewarmShape: nil)
        var events = engine.perform(.begin(DrawingBeginOptions(width: 1280, height: 800, pace: .now)))
        events += engine.perform(.append(program))
        events += engine.perform(.end)
        events += engine.perform(.drain)
        let marks = events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
        let handler = guide.answerStarted(on: TurnScreenLook(guidedScreen: screen))
        handler?(marks)
    }
}

@MainActor
@Suite struct BuddyGuidanceTests {
    @Test func armingAGuidedTargetFliesTheBuddyThereOnceAndParks() throws {
        let rig = Rig()
        try rig.answer(#"task("Export the report"); say("Click Export."); target("e1", "Export")"#)
        let target = try #require(rig.guide.guided.target)
        #expect(rig.pointer.calls == [.fly(.rect(target.frame), label: "Export", hold: nil)])
        // The resolved frame is the snapped control's, in AppKit points on the secondary, Retina-sized display.
        #expect(target.frame == rig.screen.elements[0].frame)
        #expect(target.frame == CGRect(x: 1612, y: 330, width: 60, height: 20))
        // Ticking while it waits doesn't fly again.
        rig.clock.now += 5
        rig.guide.guided.tick()
        #expect(rig.pointer.flights.count == 1)
    }

    @Test func aTargetByBoxFliesToTheSnappedControl() throws {
        let rig = Rig()
        try rig.answer(#"say("Press Save."); target(605, 305, 90, 30, "Save")"#)
        let flight = try #require(rig.pointer.flights.first)
        #expect(flight.destination == .rect(rig.screen.elements[1].frame))
        #expect(flight.hold == nil)
    }

    @Test func clickingTheTargetSendsTheBuddyBack() throws {
        let rig = Rig()
        try rig.answer(#"target("e1", "Export")"#)
        let frame = rig.screen.elements[0].frame
        rig.clock.now += 1
        rig.guide.guided.handle(.mouseDown(CGPoint(x: frame.midX, y: frame.midY)))
        #expect(rig.pointer.calls.last == .release)
        #expect(rig.guide.buddy.current == nil)
    }

    @Test func aNewTurnCancelsTheFlightAndACancelledPressBringsItBack() throws {
        let rig = Rig()
        try rig.answer(#"target("e1", "Export")"#)
        rig.guide.userTurnStarted(voice: true)
        #expect(rig.pointer.calls.count == 2)
        #expect(rig.pointer.calls.last == .cancel)
        // The press came to nothing: the step comes back, and so does the buddy.
        rig.guide.userTurnCancelled()
        #expect(rig.pointer.flights.count == 2)
        #expect(rig.pointer.calls.last == .fly(.rect(rig.screen.elements[0].frame), label: "Export", hold: nil))
    }

    @Test func anOffTargetClickReturnsThePointer() throws {
        let rig = Rig()
        try rig.answer(#"target("e1", "Export")"#)
        rig.clock.now += 1
        rig.guide.guided.handle(.mouseDown(CGPoint(x: 1520, y: 10)))
        #expect(rig.guide.guided.walkthrough.phase == .ended(.offTarget))
        #expect(rig.pointer.calls.last == .release)
        #expect(!rig.pointer.calls.contains(.cancel))
    }

    @Test func anExpiredTargetReturnsThePointer() throws {
        var settings = GuidedWalkthrough.Settings()
        settings.targetLifetime = 10
        let rig = Rig(settings: settings)
        try rig.answer(#"target("e1", "Export")"#)
        rig.clock.now += 11
        rig.guide.guided.tick()
        #expect(rig.guide.guided.walkthrough.phase == .ended(.expired))
        #expect(rig.pointer.calls.last == .release)
        #expect(rig.pointer.calls.filter { $0 == .release }.count == 1)
    }

    @Test func escapeAndSteppingAwayMakeTheBuddyVanish() throws {
        let rig = Rig()
        try rig.answer(#"target("e1", "Export")"#)
        rig.guide.guided.handle(.escape)
        #expect(rig.pointer.calls.last == .cancel)

        let other = Rig()
        try other.answer(#"target("e1", "Export")"#)
        other.guide.guided.handle(.spaceChanged)
        #expect(other.guide.guided.walkthrough.phase == .ended(.steppedAway))
        #expect(other.pointer.calls.last == .cancel)

        // Stop (the menu or Escape through the orchestrator) also sends away a buddy pointing at a control.
        let third = Rig()
        try third.answer(#"point(650, 320, "Save")"#)
        #expect(third.guide.stopWalkthrough() == false)
        #expect(third.pointer.calls.last == .cancel)
    }

    @Test func aPointAtAControlFliesThereAtItsBeat() throws {
        let rig = Rig()
        try rig.answer(#"say("Your file saves here."); point(650, 320, "Save")"#)
        let flight = try #require(rig.pointer.flights.first)
        #expect(flight.destination == .rect(rig.screen.elements[1].frame))
        #expect(flight.label == "Save")
        #expect(flight.hold == rig.guide.buddy.pointHold)
    }

    @Test func aPointNamingAnElementByIDFliesToThatElement() throws {
        let rig = Rig()
        // The ring is drawn where the brain guessed; the element id is what the buddy trusts.
        try rig.answer(#"point(40, 40, "Export", { element: "e1" })"#)
        let flight = try #require(rig.pointer.flights.first)
        #expect(flight.destination == .rect(rig.screen.elements[0].frame))
    }

    @Test func aPointOnEmptyScreenDoesNotFly() throws {
        let rig = Rig()
        try rig.answer(#"point(1000, 700, "the corner")"#)
        #expect(rig.pointer.calls.isEmpty)
    }

    @Test func aParkedTargetIsNotReplacedByAPointInTheSameAnswer() throws {
        let rig = Rig()
        try rig.answer(#"target("e1", "Export"); point(650, 320, "Save")"#)
        #expect(rig.pointer.flights.count == 1)
        #expect(rig.pointer.flights[0].destination == .rect(rig.screen.elements[0].frame))
    }

    @Test func theSimulatorLogsTheFlights() throws {
        let script = try JSONDecoder().decode(GuidedScript.self, from: Data(#"""
        {"screen": {"width": 1280, "height": 800},
         "elements": [{"id": "e1", "role": "AXMenuBarItem", "label": "File", "box": [60, 0, 40, 24]},
                      {"id": "e2", "role": "AXMenuItem", "label": "Export…", "box": [60, 120, 200, 22]}],
         "events": [{"at": 0, "answer": "task(\"Export\")\nsay(\"Open File.\"); target(\"e1\", \"File\")"},
                    {"at": 1.5, "click": [80, 12]},
                    {"at": 3, "answer": "say(\"Now Export.\"); target(\"e2\", \"Export…\")"},
                    {"at": 4, "userTurn": true},
                    {"at": 5, "click": [900, 600]}]}
        """#.utf8))
        let result = try GuidedSimulator.run(script)
        let lines = result.log.joined(separator: "; ")
        #expect(lines.contains("buddy flies to target 1 \"File\" and parks → pixels [60, 0, 40, 24], parked"))
        #expect(lines.contains("buddy flies back"))
        #expect(lines.contains("buddy flies to target 2 \"Export…\""))
        #expect(lines.contains("buddy vanishes (the user started a turn)"))
        let flights = result.buddy.filter { if case .fly = $0.call { true } else { false } }
        #expect(flights.count == 2)
    }
}
