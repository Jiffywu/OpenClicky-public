import CoreGraphics
import Foundation

/// How a drive ended.
public enum TakeoverOutcome: String, Sendable, Hashable, Codable, CaseIterable {
    /// The model said it was done (whether or not the task fully worked; see `TakeoverReport.succeeded`).
    case finished
    /// The user pressed Escape or Stop.
    case stoppedByUser = "stopped_by_user"
    /// The user moved the mouse or typed.
    case userTookOver = "user_took_over"
    /// The brain called end_screen_takeover.
    case endedByBrain = "ended_by_brain"
    /// Too many refused actions, or a safety rule stopped it.
    case safetyStop = "safety_stop"
    /// A screenshot failed (Screen Recording off, display gone).
    case couldNotSee = "could_not_see"
    /// The step limit ran out.
    case outOfSteps = "out_of_steps"
    /// The time limit ran out.
    case timedOut = "timed_out"
    /// The model call or the actuator failed.
    case failed
    /// Cancelled by the app (quit, a newer drive).
    case cancelled

    public init(_ reason: TakeoverStopReason) {
        switch reason {
        case .userPressedEscape: self = .stoppedByUser
        case .userTookOver: self = .userTookOver
        case .endedByBrain: self = .endedByBrain
        case .safety: self = .safetyStop
        case .cancelled: self = .cancelled
        }
    }

    /// One sentence about the ending, for the report and the brain's next turn.
    public var sentence: String {
        switch self {
        case .finished: "The drive finished."
        case .stoppedByUser: "The user pressed Escape, so the drive stopped."
        case .userTookOver: "The user moved the mouse or typed, so the drive stopped and handed control back."
        case .endedByBrain: "The drive was ended on request."
        case .safetyStop: "The drive stopped on a safety rule."
        case .couldNotSee: "The drive stopped because it could not take a screenshot."
        case .outOfSteps: "The drive used all its steps before finishing."
        case .timedOut: "The drive ran out of time before finishing."
        case .failed: "The drive stopped on an error."
        case .cancelled: "The drive was cancelled."
        }
    }
}

/// One action as it went.
public struct TakeoverActionRecord: Sendable, Hashable {
    public var callID: String
    public var name: String
    /// In the model's terms: "click (412, 300)", "press super+s".
    public var summary: String
    /// Placed on the screen (Quartz global points), for input actions that got that far.
    public var placed: String?
    public var status: DriveActionResult.Status
    /// The refusal or failure text the model was given.
    public var detail: String?
    public var refusalCode: String?

    public init(callID: String, name: String, summary: String, placed: String? = nil, status: DriveActionResult.Status,
                detail: String? = nil, refusalCode: String? = nil) {
        self.callID = callID
        self.name = name
        self.summary = summary
        self.placed = placed
        self.status = status
        self.detail = detail
        self.refusalCode = refusalCode
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["call_id": .string(callID), "name": .string(name), "summary": .string(summary),
                                           "status": .string(status.rawValue)]
        if let placed { object["placed"] = .string(placed) }
        if let detail { object["detail"] = .string(detail) }
        if let refusalCode { object["refusal"] = .string(refusalCode) }
        return .object(object)
    }
}

/// One model step and what came of its actions.
public struct TakeoverStepRecord: Sendable, Hashable {
    public var index: Int
    public var narration: String
    public var actions: [TakeoverActionRecord]
    public var usage: TokenUsage?

    public init(index: Int, narration: String, actions: [TakeoverActionRecord] = [], usage: TokenUsage? = nil) {
        self.index = index
        self.narration = narration
        self.actions = actions
        self.usage = usage
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["step": .number(Double(index)), "narration": .string(narration),
                                           "actions": .array(actions.map(\.json))]
        if let usage {
            object["usage"] = ["input_tokens": .number(Double(usage.inputTokens)), "output_tokens": .number(Double(usage.outputTokens))]
        }
        return .object(object)
    }
}

/// What a drive did, for the user, the brain's next turn and logs.
public struct TakeoverReport: Sendable, Hashable {
    public var brief: TakeoverBrief
    public var outcome: TakeoverOutcome
    /// The model's last words when it finished; otherwise what stopped the drive.
    public var summary: String
    /// Whether the model said the task worked, when it said.
    public var succeeded: Bool?
    public var steps: [TakeoverStepRecord]
    /// No event reached the Mac.
    public var dryRun: Bool
    public var planner: String
    public var error: String?
    public var startedAt: Date
    public var durationSeconds: Double

    public init(brief: TakeoverBrief, outcome: TakeoverOutcome, summary: String, succeeded: Bool? = nil, steps: [TakeoverStepRecord],
                dryRun: Bool, planner: String, error: String? = nil, startedAt: Date, durationSeconds: Double) {
        self.brief = brief
        self.outcome = outcome
        self.summary = summary
        self.succeeded = succeeded
        self.steps = steps
        self.dryRun = dryRun
        self.planner = planner
        self.error = error
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }

    public var actions: [TakeoverActionRecord] { steps.flatMap(\.actions) }
    /// Input actions that ran (or would have, in a dry run).
    public var actionsPerformed: Int { actions.filter { $0.status == .done && $0.placed != nil }.count }
    public var refusals: Int { actions.filter { $0.status == .refused }.count }

    public var usage: TokenUsage {
        steps.compactMap(\.usage).reduce(TokenUsage()) {
            TokenUsage(inputTokens: $0.inputTokens + $1.inputTokens, cachedInputTokens: $0.cachedInputTokens + $1.cachedInputTokens,
                       outputTokens: $0.outputTokens + $1.outputTokens)
        }
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "task": .string(brief.task),
            "outcome": .string(outcome.rawValue),
            "summary": .string(summary),
            "dry_run": .bool(dryRun),
            "planner": .string(planner),
            "steps": .array(steps.map(\.json)),
            "actions_performed": .number(Double(actionsPerformed)),
            "refusals": .number(Double(refusals)),
            "duration_ms": .number((durationSeconds * 1000).rounded()),
            "usage": ["input_tokens": .number(Double(usage.inputTokens)), "output_tokens": .number(Double(usage.outputTokens))],
        ]
        if let succeeded { object["succeeded"] = .bool(succeeded) }
        if let error { object["error"] = .string(error) }
        return .object(object)
    }

    /// The `[App]` note the brain reads on its next turn.
    public var appNote: String {
        var note = "[App] Take-over \"\(brief.task)\" ended: \(outcome.rawValue). \(outcome.sentence)"
        note += " \(actionsPerformed) action\(actionsPerformed == 1 ? "" : "s") performed"
        if refusals > 0 { note += ", \(refusals) refused" }
        note += "."
        if dryRun { note += " (Dry run: nothing reached the Mac.)" }
        if !summary.isEmpty, summary != outcome.sentence { note += " Report: \(summary)" }
        if let error, !error.isEmpty {
            let line = error.replacingOccurrences(of: "\n", with: " ")
            note += " Error: \(line.count > 240 ? String(line.prefix(239)) + "…" : line)"
        }
        return note
    }
}

/// What the drive is doing, for the overlay, the HUD and logs. Points are Quartz global.
public enum TakeoverEvent: Sendable, Hashable {
    case started(brief: TakeoverBrief, dryRun: Bool, planner: String)
    case looking(step: Int)
    case planning(step: Int)
    case narration(step: Int, text: String)
    case acting(step: Int, summary: String, point: CGPoint?)
    case acted(step: Int, summary: String)
    case refused(step: Int, summary: String, reason: String)
    case failed(step: Int, summary: String, reason: String)
    case finished(TakeoverOutcome)

    /// One log line.
    public var logLine: String {
        switch self {
        case .started(let brief, let dryRun, let planner): "started \(dryRun ? "(dry run) " : "")with \(planner): \(brief.task)"
        case .looking(let step): "step \(step): screenshot"
        case .planning(let step): "step \(step): asking the model"
        case .narration(let step, let text): "step \(step): model says \"\(text)\""
        case .acting(let step, let summary, let point):
            "step \(step): \(summary)" + (point.map { " → (\(Int($0.x.rounded())), \(Int($0.y.rounded())))" } ?? "")
        case .acted(let step, let summary): "step \(step): done \(summary)"
        case .refused(let step, let summary, let reason): "step \(step): REFUSED \(summary): \(reason)"
        case .failed(let step, let summary, let reason): "step \(step): failed \(summary): \(reason)"
        case .finished(let outcome): "finished: \(outcome.rawValue)"
        }
    }
}
