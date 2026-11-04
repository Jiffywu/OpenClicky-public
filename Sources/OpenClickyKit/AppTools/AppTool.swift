import Foundation

// Local app tools the brain can call: calendar, music, links, clipboard, Finder.
//
// Each tool is a `ToolSpec` for the model plus an async handler that returns a JSON result starting with a status
// word. The brain runtime asks the toolbox how to dispatch each call (`AppToolbox.prepare`): run it now, hold it until
// the narration has been spoken, or answer at once because the arguments are wrong. See docs/turn-contract.md.

/// The word at the front of every app-tool result. The brain's prompt teaches the model what each one means.
public enum AppToolStatus: String, Sendable, Hashable, CaseIterable, Codable {
    /// A lookup returned data (calendar events).
    case ok
    /// open_url: the page is open in the default browser.
    case opened
    /// copy_to_clipboard: the text is on the clipboard.
    case copied
    /// reveal_in_finder: Finder shows the item selected.
    case revealed
    /// play_on_spotify: playback started and the player confirmed it.
    case completed
    /// calendar_create_event: the event is saved.
    case created
    /// calendar_create_event: nothing is saved yet; read the draft back and ask the user.
    case needsConfirmation = "needs_confirmation"
    /// The app was asked to do it but could not confirm it happened (music that may not be playing).
    case unconfirmed
    /// The arguments were missing or malformed. Nothing ran.
    case invalidRequest = "invalid_request"
    /// The arguments were well formed but not allowed (a javascript: link, a path outside the home folder).
    case refused
    /// The thing asked for does not exist (no such file, no matching song, an expired draft).
    case notFound = "not_found"
    /// macOS permission is off for this (Calendars, Automation).
    case permissionDenied = "permission_denied"
    /// The app or service needed is missing on this Mac.
    case unavailable
    /// It was tried and went wrong.
    case failed
    /// A newer turn cancelled the call before it finished; whatever had not happened yet was skipped.
    case cancelled
    /// No tool by that name.
    case notImplemented = "not_implemented"

    /// The call did what it was asked to do (or, for drafts, the expected first step).
    public var isSuccess: Bool {
        switch self {
        case .ok, .opened, .copied, .revealed, .completed, .created, .needsConfirmation: true
        default: false
        }
    }
}

/// One tool's answer. Encoded for the model as a flat JSON object: `{"status": …, "message": …, …details}`.
public struct AppToolResult: Sendable, Hashable {
    public var status: AppToolStatus
    /// One or two plain sentences the model can act on or paraphrase.
    public var message: String?
    public var details: [String: JSONValue]

    public init(_ status: AppToolStatus, _ message: String? = nil, details: [String: JSONValue] = [:]) {
        self.status = status
        self.message = message
        self.details = details
    }

    public static func invalid(_ message: String) -> AppToolResult { AppToolResult(.invalidRequest, message) }

    public static let cancelledByNewerTurn = AppToolResult(.cancelled, "A newer turn cancelled this before it finished.")

    public var succeeded: Bool { status.isSuccess }

    public var json: JSONValue {
        var object = details
        object["status"] = .string(status.rawValue)
        if let message { object["message"] = .string(message) }
        return .object(object)
    }

    public var jsonString: String { json.jsonString() }

    /// The tool message answering `callID`, flagged as an error when the call did not succeed.
    public func toolMessage(callID: String) -> ChatMessage {
        .tool(callID: callID, result: jsonString, isError: !succeeded)
    }

    /// The `[App]` note for the next turn when an action that ran after the narration did not work; nil when it did.
    public func appNote(toolName: String) -> String? {
        guard !succeeded else { return nil }
        let reason = message.map { " \($0)" } ?? ""
        return "[App] \(toolName) did not work (\(status.rawValue)).\(reason)"
    }
}

/// How the brain runtime should handle one call.
public enum AppToolDispatch: Sendable {
    /// Run it now with `AppToolbox.run(_:)`.
    case runNow(AppTool)
    /// The arguments are valid. Hold the action until the narration has been spoken, then run it with
    /// `AppToolbox.run(_:)`; drop it if a new turn starts first. Send `queued` back to the model now.
    case deferUntilNarrationEnds(DeferredAction, queued: AppToolResult)
    /// Nothing runs: unknown tool or bad arguments. Send this result back to the model now.
    case finished(AppToolResult)
}

/// One app tool: what the model sees, how the runtime schedules it, and the handler.
public struct AppTool: Sendable {
    public let spec: ToolSpec
    /// The model needs to read the result before it can finish the turn (lookups, drafts to read back).
    public let needsFollowUpRound: Bool
    /// The action changes what is on screen or audible, so it waits until the narration has been spoken.
    public let defersUntilNarrationEnds: Bool
    /// The tool only reads. Lets policies such as "no actions after reading the user's apps" tell tools apart.
    public let isReadOnly: Bool
    /// Short status for the notch or cursor bubble while the tool runs.
    public let statusLabel: String
    /// The status word reported to the model when a deferred action has been queued.
    public let queuedStatus: AppToolStatus

    private let check: @Sendable (ToolArguments) throws -> Void
    private let perform: @Sendable (ToolArguments) async -> AppToolResult

    public var name: String { spec.name }

    /// Builds a tool from a parse step (pure: validates and normalizes the arguments, no side effects) and a
    /// handler that receives the parsed value. Parse errors become `invalid_request` or `refused` results.
    public static func make<Parsed: Sendable>(
        spec: ToolSpec, needsFollowUpRound: Bool, defersUntilNarrationEnds: Bool, isReadOnly: Bool,
        statusLabel: String, queuedStatus: AppToolStatus = .ok,
        parse: @escaping @Sendable (ToolArguments) throws -> Parsed,
        perform: @escaping @Sendable (Parsed) async -> AppToolResult
    ) -> AppTool {
        AppTool(spec: spec, needsFollowUpRound: needsFollowUpRound, defersUntilNarrationEnds: defersUntilNarrationEnds,
                isReadOnly: isReadOnly, statusLabel: statusLabel, queuedStatus: queuedStatus,
                check: { _ = try parse($0) },
                perform: { arguments in
                    do {
                        let parsed = try parse(arguments)
                        return await perform(parsed)
                    } catch {
                        return AppTool.result(for: error)
                    }
                })
    }

    private init(spec: ToolSpec, needsFollowUpRound: Bool, defersUntilNarrationEnds: Bool, isReadOnly: Bool, statusLabel: String,
                 queuedStatus: AppToolStatus, check: @escaping @Sendable (ToolArguments) throws -> Void,
                 perform: @escaping @Sendable (ToolArguments) async -> AppToolResult) {
        self.spec = spec
        self.needsFollowUpRound = needsFollowUpRound
        self.defersUntilNarrationEnds = defersUntilNarrationEnds
        self.isReadOnly = isReadOnly
        self.statusLabel = statusLabel
        self.queuedStatus = queuedStatus
        self.check = check
        self.perform = perform
    }

    /// Validates the arguments without side effects. Nil when they are fine.
    public func validate(_ arguments: ToolArguments) -> AppToolResult? {
        do {
            try check(arguments)
            return nil
        } catch {
            return Self.result(for: error)
        }
    }

    /// Runs the tool. Never throws: every failure is a result the model can read. A task that is already cancelled
    /// (a newer turn started) runs nothing.
    public func run(_ arguments: ToolArguments) async -> AppToolResult {
        if Task.isCancelled { return .cancelledByNewerTurn }
        return await perform(arguments)
    }

    static func result(for error: Error) -> AppToolResult {
        switch error {
        case let error as ToolArgumentError: AppToolResult(error.status, error.message)
        default: AppToolResult(.failed, String(describing: error))
        }
    }
}

/// A set of app tools with unique names, and the dispatch rules the brain runtime follows.
public struct AppToolbox: Sendable {
    public let tools: [AppTool]

    public init(_ tools: [AppTool]) {
        var seen = Set<String>()
        for tool in tools { precondition(seen.insert(tool.name).inserted, "Duplicate app tool \(tool.name)") }
        self.tools = tools
    }

    /// What to send the model in `ChatRequest.tools`.
    public var specs: [ToolSpec] { tools.map(\.spec) }

    /// Names of the actions that wait until the narration has been spoken.
    public var deferredToolNames: Set<String> { Set(tools.filter(\.defersUntilNarrationEnds).map(\.name)) }

    public subscript(name: String) -> AppTool? { tools.first { $0.name == name } }

    /// Decides how to handle a call the model made. Pure: nothing runs here.
    public func prepare(_ call: ToolCall) -> AppToolDispatch {
        guard let tool = self[call.name] else { return .finished(Self.unknownTool(call.name)) }
        let arguments: ToolArguments
        do {
            arguments = try ToolArguments.parse(call.arguments)
        } catch {
            return .finished(AppTool.result(for: error))
        }
        if let problem = tool.validate(arguments) { return .finished(problem) }
        guard tool.defersUntilNarrationEnds else { return .runNow(tool) }
        let action = DeferredAction(callID: call.id, name: call.name, arguments: .object(arguments.values))
        let queued = AppToolResult(tool.queuedStatus, "This happens as soon as you finish speaking.", details: ["deferred": true])
        return .deferUntilNarrationEnds(action, queued: queued)
    }

    /// Runs a call now, whatever its deferral flag (the runtime already decided when).
    public func run(_ call: ToolCall) async -> AppToolResult {
        await self.call(name: call.name, arguments: call.arguments)
    }

    /// Runs an action that was held until the narration finished.
    public func run(_ action: DeferredAction) async -> AppToolResult {
        guard let tool = self[action.name] else { return Self.unknownTool(action.name) }
        do {
            return await tool.run(try ToolArguments(json: action.arguments))
        } catch {
            return AppTool.result(for: error)
        }
    }

    /// Runs a tool by name with JSON argument text (what `occtl tools call` uses).
    public func call(name: String, arguments: String) async -> AppToolResult {
        guard let tool = self[name] else { return Self.unknownTool(name) }
        do {
            return await tool.run(try ToolArguments.parse(arguments))
        } catch {
            return AppTool.result(for: error)
        }
    }

    static func unknownTool(_ name: String) -> AppToolResult {
        AppToolResult(.notImplemented, "There is no app tool named \(name).")
    }
}
