import CoreGraphics
import Foundation

/// Bounds on one drive.
public struct TakeoverLimits: Sendable, Hashable {
    /// Model steps (screenshot → model → actions) before the drive gives up.
    public var maximumSteps: Int
    /// Actions run from one model reply; the rest are answered as skipped.
    public var maximumActionsPerStep: Int
    /// Refused actions before the drive stops on a safety rule.
    public var maximumRefusals: Int
    /// Wall-clock seconds for the whole drive.
    public var maximumDuration: Double
    /// The longest single `wait` the model may ask for.
    public var maximumWaitSeconds: Double
    /// Pause after input actions before the next screenshot, so the screen can react.
    public var settleSeconds: Double
    /// Long edge of zoomed images.
    public var zoomLongEdge: Int

    public init(maximumSteps: Int = 25, maximumActionsPerStep: Int = 10, maximumRefusals: Int = 3, maximumDuration: Double = 600,
                maximumWaitSeconds: Double = 10, settleSeconds: Double = 0.5, zoomLongEdge: Int = 1280) {
        self.maximumSteps = max(1, maximumSteps)
        self.maximumActionsPerStep = max(1, maximumActionsPerStep)
        self.maximumRefusals = max(1, maximumRefusals)
        self.maximumDuration = maximumDuration
        self.maximumWaitSeconds = maximumWaitSeconds
        self.settleSeconds = settleSeconds
        self.zoomLongEdge = zoomLongEdge
    }
}

/// Runs one approved drive: screenshot → model → checked actions → screenshot …, until the model finishes, a limit
/// is hit, the user takes over, or the stop switch trips. Never throws: every ending is a `TakeoverReport`.
///
/// For each action the model asks for, in order:
/// 1. stop if the switch tripped; skip the rest of the step after any failure (Anthropic's batch rule);
/// 2. place it on the screen with the observation's `DriveCoordinateMapper` (refused when off the screenshot);
/// 3. check it with `TakeoverSafetyGuard` (password fields, system windows, own windows, dangerous shortcuts);
/// 4. wait for the rate limiter, then hand it to the actuator (which checks the switch before every event).
/// After a step with input actions it waits for the screen to settle and attaches a fresh screenshot to the last
/// action that ran.
public actor TakeoverDriver {
    public let brief: TakeoverBrief
    private let planner: any TakeoverPlanner
    private let screen: any TakeoverScreenSource
    private let actuator: any DriveActuating
    private let safety: TakeoverSafetyGuard
    public let limits: TakeoverLimits
    private let rateLimiter: DriveRateLimiter
    private let timing: any DriveTiming
    public nonisolated let stop: TakeoverStopSwitch
    private let onEvent: @Sendable (TakeoverEvent) -> Void

    public init(brief: TakeoverBrief, planner: any TakeoverPlanner, screen: any TakeoverScreenSource, actuator: any DriveActuating,
                safety: TakeoverSafetyGuard, limits: TakeoverLimits = TakeoverLimits(), rateLimits: DriveRateLimits = DriveRateLimits(),
                timing: any DriveTiming = ContinuousTiming(), stop: TakeoverStopSwitch = TakeoverStopSwitch(),
                onEvent: @escaping @Sendable (TakeoverEvent) -> Void = { _ in }) {
        self.brief = brief
        self.planner = planner
        self.screen = screen
        self.actuator = actuator
        self.safety = safety
        self.limits = limits
        self.rateLimiter = DriveRateLimiter(limits: rateLimits, timing: timing)
        self.timing = timing
        self.stop = stop
        self.onEvent = onEvent
    }

    private enum Ending: Error {
        case outcome(TakeoverOutcome, error: String?)
    }

    public func run() async -> TakeoverReport {
        let startedAt = Date()
        let startTime = timing.now()
        var steps: [TakeoverStepRecord] = []
        onEvent(.started(brief: brief, dryRun: actuator.isDryRun, planner: planner.label))

        func report(_ outcome: TakeoverOutcome, summary: String? = nil, succeeded: Bool? = nil, error: String? = nil) async -> TakeoverReport {
            await actuator.releaseAll()
            onEvent(.finished(outcome))
            return TakeoverReport(brief: brief, outcome: outcome, summary: summary ?? outcome.sentence, succeeded: succeeded, steps: steps,
                                  dryRun: actuator.isDryRun, planner: planner.label, error: error, startedAt: startedAt,
                                  durationSeconds: timing.now() - startTime)
        }

        var cursor = await safety.probe.cursorLocation()
        var observation: DriveObservation
        var plan: DrivePlan
        do {
            observation = try await look(step: 1)
            onEvent(.planning(step: 1))
            let first = observation
            plan = try await ask { try await planner.start(brief: brief, observation: first) }
        } catch Ending.outcome(let outcome, let error) {
            return await report(outcome, error: error)
        } catch {
            return await report(.failed, error: String(describing: error))
        }

        var stepIndex = 1
        var refusals = 0
        while true {
            var record = TakeoverStepRecord(index: stepIndex, narration: plan.narration, usage: plan.usage)
            if !plan.narration.isEmpty { onEvent(.narration(step: stepIndex, text: plan.narration)) }
            if let reason = stop.reason {
                steps.append(record)
                return await report(TakeoverOutcome(reason))
            }
            if plan.isFinal {
                steps.append(record)
                let words = plan.narration.trimmingCharacters(in: .whitespacesAndNewlines)
                return await report(.finished, summary: words.isEmpty ? nil : words, succeeded: plan.succeeded)
            }

            var results: [DriveActionResult] = []
            var halted = false
            var actedOnInput = false
            for (index, planned) in plan.actions.enumerated() {
                let summary = planned.action?.summary ?? planned.name
                func answer(_ status: DriveActionResult.Status, _ text: String, image: DriveImage? = nil, placed: String? = nil,
                            refusal: DriveRefusal? = nil) {
                    results.append(DriveActionResult(callID: planned.callID, status: status, text: text, image: image))
                    record.actions.append(TakeoverActionRecord(callID: planned.callID, name: planned.name, summary: summary, placed: placed,
                                                               status: status, detail: status == .done ? nil : text,
                                                               refusalCode: refusal?.code))
                    if status != .done { halted = true }
                }
                if halted {
                    answer(.notExecuted, DriveActionResult.notExecutedText)
                    continue
                }
                if stop.isTripped {
                    answer(.stopped, "Not executed: the user stopped the drive.")
                    continue
                }
                if index >= limits.maximumActionsPerStep {
                    answer(.notExecuted, "Not executed: at most \(limits.maximumActionsPerStep) actions run per step. Check the next screenshot, then go on.")
                    continue
                }
                guard let action = planned.action else {
                    answer(.failed, "Could not read this action: \(planned.problem ?? "unknown problem").")
                    onEvent(.failed(step: stepIndex, summary: planned.name, reason: planned.problem ?? "unreadable"))
                    continue
                }
                do {
                    switch action {
                    case .screenshot:
                        observation = try await look(step: stepIndex)
                        answer(.done, "Screenshot taken.", image: DriveImage(observation))
                    case .zoom(let region):
                        let image = try await screen.zoom(pixelRegion: region, of: observation, longEdge: limits.zoomLongEdge)
                        answer(.done, "Zoomed in on the region.", image: image)
                    case .cursorPosition:
                        if let pixel = observation.mapper.modelPixel(fromQuartz: cursor) {
                            answer(.done, "The pointer is at (\(Int(pixel.x.rounded())), \(Int(pixel.y.rounded()))).")
                        } else {
                            answer(.done, "The pointer is not on the screen being driven.")
                        }
                    case .wait(let seconds):
                        try await timing.sleep(seconds: min(seconds, limits.maximumWaitSeconds), stop: stop)
                        answer(.done, "Waited.")
                    default:
                        let resolved: ResolvedDriveAction
                        do {
                            guard let placed = try observation.mapper.resolve(action, cursor: cursor) else {
                                answer(.failed, "Nothing to do for \(planned.name).")
                                continue
                            }
                            resolved = placed
                        } catch {
                            let refusal = DriveRefusal.offScreen(String(describing: error))
                            refusals += 1
                            answer(.refused, refusal.description, refusal: refusal)
                            onEvent(.refused(step: stepIndex, summary: summary, reason: refusal.description))
                            continue
                        }
                        if let refusal = await safety.check(resolved) {
                            refusals += 1
                            answer(.refused, refusal.description, placed: resolved.summary, refusal: refusal)
                            onEvent(.refused(step: stepIndex, summary: summary, reason: refusal.description))
                            continue
                        }
                        try await rateLimiter.waitTurn(stop: stop)
                        onEvent(.acting(step: stepIndex, summary: summary, point: resolved.finalPoint))
                        try await actuator.perform(resolved, stop: stop)
                        if let point = resolved.finalPoint { cursor = point }
                        actedOnInput = true
                        answer(.done, actuator.isDryRun ? "Done (dry run: shown, not performed)." : "Done.", placed: resolved.summary)
                        onEvent(.acted(step: stepIndex, summary: summary))
                    }
                } catch Ending.outcome(let outcome, let error) {
                    steps.append(record)
                    return await report(outcome, error: error)
                } catch is TakeoverStopped {
                    answer(.stopped, "Not executed: the user stopped the drive.")
                } catch is CancellationError {
                    stop.trip(.cancelled)
                    answer(.stopped, "Not executed: the drive was cancelled.")
                } catch {
                    answer(.failed, "Failed: \(error)")
                    onEvent(.failed(step: stepIndex, summary: summary, reason: String(describing: error)))
                }
            }
            steps.append(record)

            if let reason = stop.reason { return await report(TakeoverOutcome(reason)) }
            if refusals >= limits.maximumRefusals {
                return await report(.safetyStop, summary: "I stopped after \(refusals) refused actions; this part needs you.")
            }
            if stepIndex >= limits.maximumSteps { return await report(.outOfSteps) }
            if timing.now() - startTime > limits.maximumDuration { return await report(.timedOut) }

            do {
                if actedOnInput {
                    try await timing.sleep(seconds: limits.settleSeconds, stop: stop)
                    observation = try await look(step: stepIndex + 1)
                    // On the last action that ran, so skipped actions keep the exact batch wording.
                    if let last = results.lastIndex(where: { $0.status != .notExecuted }), results[last].image == nil {
                        results[last].image = DriveImage(observation)
                        results[last].text += " Screen after this step attached."
                    }
                }
                stepIndex += 1
                onEvent(.planning(step: stepIndex))
                let answered = results
                let seen = observation
                plan = try await ask { try await planner.next(results: answered, observation: seen) }
            } catch Ending.outcome(let outcome, let error) {
                return await report(outcome, error: error)
            } catch is TakeoverStopped {
                return await report(TakeoverOutcome(stop.reason ?? .cancelled))
            } catch {
                return await report(.failed, error: String(describing: error))
            }
        }
    }

    /// A screenshot, with failures turned into endings: a stop, a cancellation, or "could not see".
    private func look(step: Int) async throws -> DriveObservation {
        try stopCheck()
        onEvent(.looking(step: step))
        do {
            return try await screen.observe()
        } catch {
            try stopCheck()
            if error is CancellationError { throw Ending.outcome(.cancelled, error: nil) }
            throw Ending.outcome(.couldNotSee, error: String(describing: error))
        }
    }

    /// A model call, with a stop or cancellation during the call turned into the stop's ending.
    private func ask(_ call: () async throws -> DrivePlan) async throws -> DrivePlan {
        try stopCheck()
        do {
            let plan = try await call()
            try stopCheck()
            return plan
        } catch let ending as Ending {
            throw ending
        } catch {
            try stopCheck()
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw Ending.outcome(.cancelled, error: nil)
            }
            throw Ending.outcome(.failed, error: String(describing: error))
        }
    }

    private func stopCheck() throws {
        if let reason = stop.reason { throw Ending.outcome(TakeoverOutcome(reason), error: nil) }
    }
}
