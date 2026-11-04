import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import OpenClickyKit

/// The CGEvent actuator is exercised only with `RecordingEventPoster`: events are built and described, never posted.
@Suite("Take-over actuator (recorded, never posted)")
struct TakeoverActuatorTests {
    static func actuator() -> (CGEventActuator, RecordingEventPoster, VirtualTiming) {
        let poster = RecordingEventPoster()
        let timing = VirtualTiming()
        return (CGEventActuator(poster: poster, timing: timing), poster, timing)
    }

    @Test func clickMovesThenPressesAndReleasesWithClickState() async throws {
        let (actuator, poster, _) = Self.actuator()
        let point = CGPoint(x: 300, y: 200)
        try await actuator.perform(.click(at: point, button: .left, count: 2, modifiers: .command), stop: TakeoverStopSwitch())
        let events = poster.events
        #expect(events.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(events.dropFirst().map(\.clickState) == [1, 1, 2, 2])
        #expect(events.allSatisfy { $0.location == point })
        #expect(events.dropFirst().allSatisfy { $0.flags.contains(.maskCommand) })
        #expect(events.allSatisfy { $0.marker == CGEventActuator.syntheticEventMarker })
    }

    @Test func rightAndMiddleClicksUseTheirButtons() async throws {
        let (actuator, poster, _) = Self.actuator()
        try await actuator.perform(.click(at: .zero, button: .right, count: 1, modifiers: []), stop: TakeoverStopSwitch())
        try await actuator.perform(.click(at: .zero, button: .middle, count: 1, modifiers: []), stop: TakeoverStopSwitch())
        #expect(poster.events.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp, .mouseMoved, .otherMouseDown, .otherMouseUp])
    }

    @Test func dragInterpolatesAndEndsWithARelease() async throws {
        let (actuator, poster, _) = Self.actuator()
        try await actuator.perform(.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 120, y: 60), modifiers: []), stop: TakeoverStopSwitch())
        let types = poster.events.map(\.type)
        #expect(types.first == .mouseMoved)
        #expect(types[1] == .leftMouseDown)
        #expect(types.last == .leftMouseUp)
        #expect(types.filter { $0 == .leftMouseDragged }.count == actuator.pacing.dragSteps)
        #expect(poster.events.last?.location == CGPoint(x: 120, y: 60))
    }

    @Test func scrollSendsOneLinePerClickInTheRightDirection() async throws {
        let (actuator, poster, _) = Self.actuator()
        try await actuator.perform(.scroll(at: CGPoint(x: 5, y: 5), direction: .down, amount: 3, modifiers: []), stop: TakeoverStopSwitch())
        let wheel = poster.events.filter { $0.type == .scrollWheel }
        #expect(wheel.count == 3)
        #expect(wheel.allSatisfy { $0.scrollVertical == -1 && $0.scrollHorizontal == 0 })
        try await actuator.perform(.scroll(at: CGPoint(x: 5, y: 5), direction: .left, amount: 1, modifiers: []), stop: TakeoverStopSwitch())
        #expect(poster.events.last?.scrollHorizontal == 1)
    }

    @Test func typingSendsUnicodeChunksAndReturnForNewlines() async throws {
        let (actuator, poster, _) = Self.actuator()
        let text = "Quarterly plan for Q3 2026 ✓\nnext"
        try await actuator.perform(.type(text), stop: TakeoverStopSwitch())
        let downs = poster.events.filter { $0.type == .keyDown }
        let typed = downs.filter { $0.keyCode != Int64(kVK_Return) }.compactMap(\.text).joined()
        #expect(typed == "Quarterly plan for Q3 2026 ✓next")
        #expect(downs.filter { $0.keyCode == Int64(kVK_Return) }.count == 1)
        #expect(downs.allSatisfy { ($0.text?.utf16.count ?? 0) <= 16 })
        #expect(poster.events.filter { $0.type == .keyUp }.count == downs.count)
    }

    @Test func emojiSurrogatePairsAreNeverSplit() async throws {
        let (actuator, poster, _) = Self.actuator()
        let text = String(repeating: "a", count: 15) + "😀" + "b"
        try await actuator.perform(.type(text), stop: TakeoverStopSwitch())
        let chunks = poster.events.filter { $0.type == .keyDown }.compactMap(\.text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.unicodeScalars.isEmpty })
    }

    @Test func keyCombosCarryFlagsAndRepeat() async throws {
        let (actuator, poster, _) = Self.actuator()
        try await actuator.perform(.key(KeyCombo.parse("super+shift+s")!, repeatCount: 2), stop: TakeoverStopSwitch())
        let events = poster.events
        #expect(events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(events.allSatisfy { $0.keyCode == Int64(kVK_ANSI_S) && $0.flags.contains([.maskCommand, .maskShift]) })
    }

    @Test func aTrippedSwitchPostsNothing() async {
        let (actuator, poster, _) = Self.actuator()
        let stop = TakeoverStopSwitch()
        stop.trip(.userPressedEscape)
        await #expect(throws: TakeoverStopped.self) {
            try await actuator.perform(.click(at: .zero, button: .left, count: 1, modifiers: []), stop: stop)
        }
        #expect(poster.events.isEmpty)
    }

    @Test func stoppingMidDragStillReleasesTheButton() async {
        let poster = RecordingEventPoster()
        let stop = TakeoverStopSwitch()
        // Trip the switch after a few drag steps.
        let timing = TakeoverTrippingTiming(stop: stop, after: 3)
        let actuator = CGEventActuator(poster: poster, timing: timing)
        await #expect(throws: TakeoverStopped.self) {
            try await actuator.perform(.drag(from: .zero, to: CGPoint(x: 100, y: 100), modifiers: []), stop: stop)
        }
        let types = poster.events.map(\.type)
        #expect(types.contains(.leftMouseDown))
        #expect(types.last == .leftMouseUp)
        #expect(types.filter { $0 == .leftMouseDragged }.count < actuator.pacing.dragSteps)
    }

    @Test func holdKeyAlwaysLetsGo() async {
        let poster = RecordingEventPoster()
        let stop = TakeoverStopSwitch()
        let actuator = CGEventActuator(poster: poster, timing: TakeoverTrippingTiming(stop: stop, after: 2))
        await #expect(throws: TakeoverStopped.self) {
            try await actuator.perform(.holdKey(KeyCombo.parse("Down")!, seconds: 3), stop: stop)
        }
        #expect(poster.events.map(\.type) == [.keyDown, .keyUp])
    }

    @Test func aLoneModifierIsAFlagsChangePairWithItsFlagWhileDown() async throws {
        let (actuator, poster, _) = Self.actuator()
        try await actuator.perform(.key(KeyCombo.parse("shift")!, repeatCount: 1), stop: TakeoverStopSwitch())
        let events = poster.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.keyCode == Int64(kVK_Shift) })
        #expect(events[0].flags.contains(.maskShift))
        #expect(!events[1].flags.contains(.maskShift))
    }

    @Test func dryRunRecordsAndHonorsTheSwitch() async throws {
        let dry = DryRunActuator()
        #expect(dry.isDryRun)
        try await dry.perform(.type("x"), stop: TakeoverStopSwitch())
        let stop = TakeoverStopSwitch()
        stop.trip(.cancelled)
        await #expect(throws: TakeoverStopped.self) { try await dry.perform(.type("y"), stop: stop) }
        #expect(dry.performed == [.type("x")])
    }
}

/// Trips the stop switch after `after` sleeps; never really sleeps.
final class TakeoverTrippingTiming: DriveTiming {
    private let virtual = VirtualTiming()
    private let stop: TakeoverStopSwitch
    private let after: Int

    init(stop: TakeoverStopSwitch, after: Int) {
        self.stop = stop
        self.after = after
    }

    func now() -> Double { virtual.now() }

    func sleep(seconds: Double) async throws {
        try await virtual.sleep(seconds: seconds)
        if virtual.sleeps.count >= after { stop.trip(.userPressedEscape) }
    }
}

@Suite("Take-over pacing")
struct TakeoverRateLimitTests {
    @Test func spacesActionsByTheMinimumInterval() async throws {
        let timing = VirtualTiming()
        let limiter = DriveRateLimiter(limits: DriveRateLimits(minimumInterval: 0.2, maximumPerMinute: 100), timing: timing)
        let stop = TakeoverStopSwitch()
        try await limiter.waitTurn(stop: stop)
        try await limiter.waitTurn(stop: stop)
        try await limiter.waitTurn(stop: stop)
        #expect(abs(timing.now() - 0.4) < 1e-9)
        // A slow model call in between means no wait at all.
        timing.advance(5)
        let before = timing.sleeps.count
        try await limiter.waitTurn(stop: stop)
        #expect(timing.sleeps.count == before)
    }

    @Test func capsActionsPerMinute() async throws {
        let timing = VirtualTiming()
        let limiter = DriveRateLimiter(limits: DriveRateLimits(minimumInterval: 0, maximumPerMinute: 3), timing: timing)
        let stop = TakeoverStopSwitch()
        for _ in 0..<3 { try await limiter.waitTurn(stop: stop) }
        #expect(timing.now() == 0)
        try await limiter.waitTurn(stop: stop)
        #expect(timing.now() >= 60)
        #expect(await limiter.recentCount <= 3)
    }

    @Test func aStopEndsTheWait() async {
        let timing = VirtualTiming()
        let limiter = DriveRateLimiter(limits: DriveRateLimits(minimumInterval: 0, maximumPerMinute: 1), timing: timing)
        let stop = TakeoverStopSwitch()
        try? await limiter.waitTurn(stop: stop)
        stop.trip(.userTookOver)
        await #expect(throws: TakeoverStopped.self) { try await limiter.waitTurn(stop: stop) }
        #expect(timing.now() < 1)
    }
}
