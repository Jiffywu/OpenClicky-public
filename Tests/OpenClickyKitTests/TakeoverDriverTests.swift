import CoreGraphics
import os
import Testing
@testable import OpenClickyKit

@Suite("Take-over drive loop")
struct TakeoverDriverTests {
    static let brief = TakeoverBrief(task: "Title the document Quarterly plan and save it", steps: ["Click the title", "Type", "Save"])

    struct Rig {
        let driver: TakeoverDriver
        let actuator: DryRunActuator
        let screen: TakeoverCountingScreen
        let planner: ScriptedTakeoverPlanner
        let log: TakeoverEventLog
        let stop: TakeoverStopSwitch
    }

    static func rig(_ plans: [DrivePlan], screen: TakeoverCountingScreen = TakeoverCountingScreen(), limits: TakeoverLimits = TakeoverLimits(),
                    probe: StaticTakeoverProbe? = nil, beforeStep: (@Sendable (Int) async -> Void)? = nil,
                    stop: TakeoverStopSwitch = TakeoverStopSwitch()) -> Rig {
        let actuator = DryRunActuator()
        let planner = ScriptedTakeoverPlanner(plans, beforeStep: beforeStep)
        let log = TakeoverEventLog()
        let probe = probe ?? StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: screen.observation), cursor: CGPoint(x: 10, y: 10))
        let driver = TakeoverDriver(brief: brief, planner: planner, screen: screen, actuator: actuator,
                                    safety: TakeoverSafetyGuard(probe: probe), limits: limits, timing: VirtualTiming(), stop: stop,
                                    onEvent: { log.record($0) })
        return Rig(driver: driver, actuator: actuator, screen: screen, planner: planner, log: log, stop: stop)
    }

    @Test func runsActionsThenFinishesWithTheModelsReport() async throws {
        let rig = Self.rig([
            .acting("Clicking the title field.", [("left_click", ["element": "e2"]), ("type", ["text": "Quarterly plan"])]),
            .acting("Saving.", [("key", ["text": "super+s"])]),
            DrivePlan(narration: "I titled it Quarterly plan and saved it.", actions: []),
        ])
        let report = await rig.driver.run()
        #expect(report.outcome == .finished)
        #expect(report.summary == "I titled it Quarterly plan and saved it.")
        #expect(report.dryRun)
        #expect(report.steps.count == 3)
        #expect(report.actionsPerformed == 3)
        let performed = rig.actuator.performed
        #expect(performed.count == 3)
        guard case .click(let point, .left, 1, []) = performed[0] else { Issue.record("expected a click"); return }
        #expect(abs(point.x - 350) < 0.01 && abs(point.y - 170) < 0.01) // e2's center in Quartz
        #expect(performed[1] == .type("Quarterly plan"))
        // One screenshot to start, one after each step with input.
        #expect(rig.screen.count == 3)
        // Each step's last result carries the fresh screenshot.
        let results = rig.planner.receivedResults
        #expect(results.count == 2)
        #expect(results[0].map(\.status) == [.done, .done])
        #expect(results[0].last?.image != nil && results[0].first?.image == nil)
        #expect(rig.log.events.first == .started(brief: Self.brief, dryRun: true, planner: "scripted"))
        #expect(rig.log.events.last == .finished(.finished))
    }

    @Test func endsWhenTheStepLimitRunsOut() async {
        let looping = (0..<10).map { _ in DrivePlan.acting([("mouse_move", ["coordinate": [100, 100]])]) }
        let rig = Self.rig(looping, limits: TakeoverLimits(maximumSteps: 3))
        let report = await rig.driver.run()
        #expect(report.outcome == .outOfSteps)
        #expect(report.steps.count == 3)
        #expect(rig.actuator.performed.count == 3)
    }

    @Test func aFailedActionSkipsTheRestOfTheStep() async {
        let rig = Self.rig([
            .acting([("left_click", ["coordinate": [5000, 10]]), ("type", ["text": "never"]), ("key", ["text": "Return"])]),
            DrivePlan(narration: "Stopped.", actions: []),
        ])
        let report = await rig.driver.run()
        #expect(report.outcome == .finished)
        let results = rig.planner.receivedResults[0]
        #expect(results.map(\.status) == [.refused, .notExecuted, .notExecuted])
        #expect(results[1].text == DriveActionResult.notExecutedText)
        #expect(rig.actuator.performed.isEmpty)
        // No input happened, so no extra screenshot was taken.
        #expect(rig.screen.count == 1)
    }

    @Test func theFreshScreenshotGoesOnTheLastActionThatRanAndSkipsKeepTheirWording() async {
        let rig = Self.rig([
            .acting([("left_click", ["coordinate": [100, 100]]), ("left_click", ["element": "e3"]), ("type", ["text": "never"])]),
            DrivePlan(narration: "Stopped at the password field.", actions: []),
        ])
        _ = await rig.driver.run()
        let results = rig.planner.receivedResults[0]
        #expect(results.map(\.status) == [.done, .refused, .notExecuted])
        #expect(results[1].image != nil)
        #expect(results[2].image == nil)
        #expect(results[2].text == DriveActionResult.notExecutedText)
        #expect(rig.screen.count == 2)
    }

    @Test func unreadableActionsAreAnsweredNotPerformed() async {
        let rig = Self.rig([
            DrivePlan(narration: "", actions: [PlannedAction(callID: "x", name: "teleport", action: nil, problem: "Unknown action teleport.")]),
            DrivePlan(narration: "Done.", actions: []),
        ])
        _ = await rig.driver.run()
        let result = rig.planner.receivedResults[0][0]
        #expect(result.status == .failed)
        #expect(result.text.contains("teleport"))
    }

    @Test func repeatedRefusalsEndInASafetyStop() async {
        let password: [(String, JSONValue)] = [("left_click", ["element": "e3"])]
        let rig = Self.rig(Array(repeating: DrivePlan.acting(password), count: 5), limits: TakeoverLimits(maximumRefusals: 2))
        let report = await rig.driver.run()
        #expect(report.outcome == .safetyStop)
        #expect(report.refusals == 2)
        #expect(report.actions.allSatisfy { $0.refusalCode == "password_field" })
        #expect(rig.actuator.performed.isEmpty)
        #expect(rig.log.events.contains { if case .refused = $0 { true } else { false } })
    }

    @Test func aStopBetweenStepsEndsWithTheStopReason() async {
        let stop = TakeoverStopSwitch()
        let rig = Self.rig([
            .acting([("left_click", ["coordinate": [100, 100]])]),
            .acting([("left_click", ["coordinate": [200, 200]])]),
            DrivePlan(narration: "Done.", actions: []),
        ], beforeStep: { step in if step == 1 { stop.trip(.userPressedEscape) } }, stop: stop)
        let report = await rig.driver.run()
        #expect(report.outcome == .stoppedByUser)
        #expect(rig.actuator.performed.count == 1)
    }

    @Test func aStopMidStepSkipsTheRemainingActions() async {
        let stop = TakeoverStopSwitch()
        let probe = TakeoverTrippingProbe(stop: stop, afterChecks: 1)
        let actuator = DryRunActuator()
        let planner = ScriptedTakeoverPlanner([
            .acting([("left_click", ["coordinate": [100, 100]]), ("left_click", ["coordinate": [200, 200]]), ("type", ["text": "x"])]),
        ])
        let driver = TakeoverDriver(brief: Self.brief, planner: planner, screen: TakeoverCountingScreen(), actuator: actuator,
                                    safety: TakeoverSafetyGuard(probe: probe), timing: VirtualTiming(), stop: stop)
        let report = await driver.run()
        #expect(report.outcome == .userTookOver)
        #expect(actuator.performed.count == 1)
        #expect(report.steps[0].actions.map(\.status) == [.done, .stopped, .notExecuted])
    }

    @Test func userInputDuringTheModelCallEndsTheDrive() async {
        let stop = TakeoverStopSwitch()
        let rig = Self.rig([DrivePlan.acting([("left_click", ["coordinate": [100, 100]])])],
                           beforeStep: { _ in stop.trip(.userTookOver) }, stop: stop)
        let report = await rig.driver.run()
        #expect(report.outcome == .userTookOver)
        #expect(rig.actuator.performed.isEmpty)
    }

    @Test func aFailedScreenshotEndsWithCouldNotSee() async {
        let first = Self.rig([DrivePlan(narration: "never", actions: [])], screen: TakeoverCountingScreen(failOn: 1))
        let report = await first.driver.run()
        #expect(report.outcome == .couldNotSee)
        #expect(report.error?.contains("Screen Recording") == true)

        let later = Self.rig([.acting([("left_click", ["coordinate": [100, 100]])]), DrivePlan(narration: "x", actions: [])],
                             screen: TakeoverCountingScreen(failOn: 2))
        #expect(await later.driver.run().outcome == .couldNotSee)
    }

    @Test func plannerErrorsEndAsFailed() async {
        let planner = TakeoverFailingPlanner()
        let driver = TakeoverDriver(brief: Self.brief, planner: planner, screen: TakeoverCountingScreen(), actuator: DryRunActuator(),
                                    safety: TakeoverSafetyGuard(probe: StaticTakeoverProbe()), timing: VirtualTiming())
        let report = await driver.run()
        #expect(report.outcome == .failed)
        #expect(report.error?.contains("HTTP 529") == true)
    }

    @Test func observationActionsNeedNoInput() async {
        let rig = Self.rig([
            .acting([("screenshot", [:]), ("zoom", ["region": [0, 0, 320, 200]]), ("cursor_position", [:]), ("wait", ["duration": 30])]),
            DrivePlan(narration: "Looked around.", actions: []),
        ])
        let report = await rig.driver.run()
        #expect(report.outcome == .finished)
        #expect(rig.actuator.performed.isEmpty)
        let results = rig.planner.receivedResults[0]
        #expect(results.map(\.status) == [.done, .done, .done, .done])
        #expect(results[0].image != nil)
        #expect(results[1].image != nil && results[1].image!.pixelWidth > 320)
        // The cursor (Quartz 10, 10) in screenshot pixels.
        #expect(results[2].text.contains("(8, 8)"))
        #expect(report.actionsPerformed == 0)
    }

    @Test func tooManyActionsInOneStepAreCut() async {
        let many: [(String, JSONValue)] = (0..<5).map { index in
            ("mouse_move", .object(["coordinate": .array([.number(Double(index * 10)), .number(10)])]))
        }
        let rig = Self.rig([.acting(many), DrivePlan(narration: "ok", actions: [])], limits: TakeoverLimits(maximumActionsPerStep: 2))
        _ = await rig.driver.run()
        #expect(rig.actuator.performed.count == 2)
        #expect(rig.planner.receivedResults[0].map(\.status) == [.done, .done, .notExecuted, .notExecuted, .notExecuted])
    }
}

/// Trips the stop switch (as the input monitor would) once `afterChecks` pointer checks have passed.
final class TakeoverTrippingProbe: TakeoverEnvironmentProbe {
    private let stop: TakeoverStopSwitch
    private let afterChecks: Int
    private let checks = OSAllocatedUnfairLock(initialState: 0)

    init(stop: TakeoverStopSwitch, afterChecks: Int) {
        self.stop = stop
        self.afterChecks = afterChecks
    }

    func target(atQuartz point: CGPoint) async -> DriveTargetInfo? {
        let count = checks.withLock { value -> Int in
            value += 1
            return value
        }
        if count > afterChecks { stop.trip(.userTookOver) }
        return nil
    }
    func focusedTarget() async -> DriveTargetInfo? { nil }
    func isSecureInputEnabled() async -> Bool { false }
    func cursorLocation() async -> CGPoint { .zero }
}

struct TakeoverFailingPlanner: TakeoverPlanner {
    var label: String { "failing" }
    func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
        throw ProviderError(provider: "anthropic", status: 529, message: "overloaded_error: Overloaded")
    }
    func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
        throw ProviderError(provider: "anthropic", status: 529, message: "overloaded")
    }
}
