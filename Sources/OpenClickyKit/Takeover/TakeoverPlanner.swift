import Foundation
import os

/// The job the user agreed to: what the drive should do, and the short plan shown on the consent card.
public struct TakeoverBrief: Sendable, Hashable, Codable {
    public var task: String
    public var steps: [String]
    /// The app the task happens in, when the brain named one.
    public var app: String?

    public init(task: String, steps: [String] = [], app: String? = nil) {
        self.task = task
        self.steps = steps
        self.app = app
    }
}

/// An image handed back to the model: a fresh screenshot or a zoomed-in region.
public struct DriveImage: Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, mimeType: String = "image/jpeg", pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public init(_ observation: DriveObservation) {
        self.init(data: observation.imageData, mimeType: observation.mimeType, pixelWidth: observation.pixelWidth,
                  pixelHeight: observation.pixelHeight)
    }

    public var contentPart: ContentPart { .image(data: data, mimeType: mimeType) }
}

/// One action the model asked for, as read from its reply.
public struct PlannedAction: Sendable, Hashable {
    /// The provider's id for the call this action answers (Anthropic tool_use id, or `<call id>#<index>` when one
    /// function call carries several actions).
    public var callID: String
    /// The action name the model used ("left_click").
    public var name: String
    /// The parsed action; nil when it could not be read.
    public var action: DriveAction?
    /// Why it could not be read. Such an action is answered with this and never performed.
    public var problem: String?

    public init(callID: String, name: String, action: DriveAction?, problem: String? = nil) {
        self.callID = callID
        self.name = name
        self.action = action
        self.problem = problem
    }

    /// Parses `name` and `input` with `DriveActionParser`.
    public static func parsing(callID: String, name: String, input: JSONValue) -> PlannedAction {
        do {
            return PlannedAction(callID: callID, name: name, action: try DriveActionParser.parse(name: name, input: input))
        } catch {
            return PlannedAction(callID: callID, name: name, action: nil, problem: String(describing: error))
        }
    }
}

/// One model step: what it said and the actions it wants, in order.
public struct DrivePlan: Sendable {
    public var narration: String
    public var actions: [PlannedAction]
    /// The model says it is finished: it asked for nothing more, or called the finish tool.
    public var isFinal: Bool
    /// From the finish tool, when the model reported whether the task succeeded.
    public var succeeded: Bool?
    public var usage: TokenUsage?
    /// The provider's stop reason, for logs.
    public var stopReason: String?

    public init(narration: String, actions: [PlannedAction], isFinal: Bool? = nil, succeeded: Bool? = nil, usage: TokenUsage? = nil,
                stopReason: String? = nil) {
        self.narration = narration
        self.actions = actions
        self.isFinal = isFinal ?? actions.isEmpty
        self.succeeded = succeeded
        self.usage = usage
        self.stopReason = stopReason
    }
}

/// What happened to one planned action, sent back to the model.
public struct DriveActionResult: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable, Codable {
        /// It ran (or, in a dry run, would have run).
        case done
        /// The safety check refused it.
        case refused
        /// It could not be read, placed or performed.
        case failed
        /// An earlier action in the same step failed, so this one was skipped.
        case notExecuted = "not_executed"
        /// The drive was stopped before it ran.
        case stopped
    }

    /// Anthropic's wording for actions skipped after a failure earlier in the same batch.
    public static let notExecutedText = "Not executed: an earlier computer action in this turn failed."

    public var callID: String
    public var status: Status
    public var text: String
    public var image: DriveImage?

    public init(callID: String, status: Status, text: String, image: DriveImage? = nil) {
        self.callID = callID
        self.status = status
        self.text = text
        self.image = image
    }

    public var isError: Bool { status != .done }
}

/// Decides the drive's actions from screenshots. Planners keep their own conversation.
public protocol TakeoverPlanner: Sendable {
    /// For logs and the report: which provider, tool and model plan the drive.
    var label: String { get }
    /// The first step: the task and the screen as it is now.
    func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan
    /// The next step: what happened to every action of the last one (in order), and the screen now.
    func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan
}

/// Plays back a fixed list of plans: for tests, `occtl takeover simulate` and demos. Records what it was sent.
public final class ScriptedTakeoverPlanner: TakeoverPlanner {
    private struct State: Sendable {
        var plans: [DrivePlan]
        var briefs: [TakeoverBrief] = []
        var results: [[DriveActionResult]] = []
        var observations = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    public let label: String
    /// Runs before each plan is returned (tests use it to stop a drive mid-way or to delay like a model).
    private let beforeStep: (@Sendable (Int) async -> Void)?

    public init(_ plans: [DrivePlan], label: String = "scripted", beforeStep: (@Sendable (Int) async -> Void)? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(plans: plans))
        self.label = label
        self.beforeStep = beforeStep
    }

    public func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
        state.withLock {
            $0.briefs.append(brief)
            $0.observations += 1
        }
        return try await pop()
    }

    public func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
        state.withLock {
            $0.results.append(results)
            $0.observations += 1
        }
        return try await pop()
    }

    private func pop() async throws -> DrivePlan {
        let index = state.withLock { $0.observations - 1 }
        await beforeStep?(index)
        try Task.checkCancellation()
        return state.withLock { state in
            guard !state.plans.isEmpty else { return DrivePlan(narration: "Nothing left in the script.", actions: []) }
            return state.plans.removeFirst()
        }
    }

    /// The results the drive sent back after each step.
    public var receivedResults: [[DriveActionResult]] { state.withLock { $0.results } }
    public var receivedBriefs: [TakeoverBrief] { state.withLock { $0.briefs } }

    /// Reads a script: `[{"say": "…", "actions": [{"action": "left_click", "coordinate": [x, y]}, …]}, …]`. A step
    /// with no actions (or with `"done": true`, whose actions are then ignored) ends the drive, and its `say` is the
    /// final report.
    public static func plans(fromJSON text: String) throws -> [DrivePlan] {
        guard let steps = try JSONValue.parse(text).arrayValue else { throw DriveActionParseError("A script is a JSON array of steps.") }
        return steps.enumerated().map { stepIndex, step in
            let actions = (step["actions"]?.arrayValue ?? []).enumerated().map { index, item -> PlannedAction in
                let name = item["action"]?.stringValue ?? ""
                return PlannedAction.parsing(callID: "s\(stepIndex + 1)a\(index + 1)", name: name, input: item)
            }
            let done = step["done"]?.boolValue ?? false
            return DrivePlan(narration: step["say"]?.stringValue ?? "", actions: done ? [] : actions,
                             succeeded: step["succeeded"]?.boolValue)
        }
    }
}
