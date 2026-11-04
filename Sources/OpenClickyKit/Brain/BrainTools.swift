import Foundation

// The tools the brain can call, behind one protocol, and the registry the turn loop reads them from.

/// How the turn loop treats a call.
public enum BrainToolKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Returns information the model needs: the result goes back to the model in another round.
    case read
    /// Does something right away and reports a status word; no extra round.
    case action
    /// Changes what the user sees or hears, so it waits until the narration has been spoken: the turn emits a
    /// `TurnEvent.deferredAction` and the model is told it is queued.
    case deferredAction = "deferred_action"
    /// Runs in the background without holding up the turn. The model is told it started; a failure becomes an
    /// `[App]` note for the next turn.
    case async
}

/// Groups of tools, so the prompt only mentions what is registered.
public enum BrainToolGroup: String, Sendable, Hashable, Codable, CaseIterable {
    case memory, appTools, lookups, connectedApps, agent, other
    /// offer_screen_takeover, start_screen_takeover and end_screen_takeover (docs/takeover.md).
    case takeover
    /// Web search the brain's provider runs itself (`ToolRegistry.hostedTools`).
    case hostedSearch
}

/// What a tool knows about the call it is running.
public struct BrainToolContext: Sendable, Hashable {
    public var sessionID: String
    public var turn: Int
    public var callID: String

    public init(sessionID: String, turn: Int, callID: String) {
        self.sessionID = sessionID
        self.turn = turn
        self.callID = callID
    }
}

/// One tool the brain can call.
public protocol BrainTool: Sendable {
    var spec: ToolSpec { get }
    var kind: BrainToolKind { get }
    var group: BrainToolGroup { get }
    /// What the notch shows while it runs ("Searching the web…"); nil shows nothing.
    var runningStatus: String? { get }
    /// The kind for one call. Defaults to `kind`; a tool whose "list" reads while its other actions act overrides it.
    func kind(for arguments: JSONValue) -> BrainToolKind
    /// Checks the arguments without side effects. A non-nil result is sent to the model instead of running or
    /// deferring the call.
    func validate(_ arguments: JSONValue) -> JSONValue?
    /// Runs the call. Never throws: every failure is a result with a `status` the model can read. Should return
    /// promptly once its task is cancelled.
    func run(_ arguments: JSONValue, context: BrainToolContext) async -> JSONValue
}

extension BrainTool {
    public var name: String { spec.name }
    public var group: BrainToolGroup { .other }
    public var runningStatus: String? { nil }
    public func kind(for arguments: JSONValue) -> BrainToolKind { kind }
    public func validate(_ arguments: JSONValue) -> JSONValue? { nil }
}

/// A tool made of closures, for adapters and tests.
public struct ClosureBrainTool: BrainTool {
    public let spec: ToolSpec
    public let kind: BrainToolKind
    public let group: BrainToolGroup
    public let runningStatus: String?
    private let kindForArguments: (@Sendable (JSONValue) -> BrainToolKind)?
    private let check: (@Sendable (JSONValue) -> JSONValue?)?
    private let perform: @Sendable (JSONValue, BrainToolContext) async -> JSONValue

    public init(spec: ToolSpec, kind: BrainToolKind, group: BrainToolGroup = .other, runningStatus: String? = nil,
                kindForArguments: (@Sendable (JSONValue) -> BrainToolKind)? = nil,
                validate: (@Sendable (JSONValue) -> JSONValue?)? = nil,
                run: @escaping @Sendable (JSONValue, BrainToolContext) async -> JSONValue) {
        self.spec = spec
        self.kind = kind
        self.group = group
        self.runningStatus = runningStatus
        self.kindForArguments = kindForArguments
        self.check = validate
        self.perform = run
    }

    public func kind(for arguments: JSONValue) -> BrainToolKind { kindForArguments?(arguments) ?? kind }
    public func validate(_ arguments: JSONValue) -> JSONValue? { check?(arguments) }
    public func run(_ arguments: JSONValue, context: BrainToolContext) async -> JSONValue { await perform(arguments, context) }
}

/// Standard results the runtime itself produces.
public enum BrainToolResults {
    /// Status words that mean the call did not do what was asked.
    public static let failureStatuses: Set<String> = [
        "error", "failed", "invalid_request", "invalid_arguments", "refused", "not_found", "permission_denied",
        "unavailable", "cancelled", "never_ran", "not_implemented", "tool_limit_reached", "not_running", "ambiguous",
    ]

    public static func succeeded(_ result: JSONValue) -> Bool {
        guard let status = result["status"]?.stringValue else { return true }
        return !failureStatuses.contains(status)
    }

    public static let cancelled: JSONValue = ["status": "cancelled", "message": "A newer turn cancelled this before it finished."]
    public static let neverRan: JSONValue = ["status": "never_ran", "message": "The call never ran."]
    public static let limitReached: JSONValue = [
        "status": "tool_limit_reached",
        "message": "Too many tool calls this turn. Answer now with what you have.",
    ]
    public static let queued: JSONValue = [
        "status": "queued", "deferred": true, "message": "This happens as soon as you finish speaking.",
    ]
    public static let started: JSONValue = [
        "status": "started", "message": "Running in the background; you'll hear if it fails.",
    ]
    public static func unknownTool(_ name: String) -> JSONValue {
        ["status": "not_implemented", "message": .string("There is no tool named \(name).")]
    }
    public static let badArguments: JSONValue = ["status": "invalid_arguments", "message": "The arguments were not a JSON object."]
}

/// The tools offered to the brain, in a fixed order (the tool list is part of the cached prompt prefix).
public struct ToolRegistry: Sendable {
    public private(set) var tools: [any BrainTool] = []
    /// Other names models reach for, mapped to registered names.
    public private(set) var aliases: [String: String] = [:]
    /// Tools the brain's provider runs itself, as raw `tools` entries (`ChatRequest.hostedTools`).
    public private(set) var hostedTools: [JSONValue] = []
    private var hostedGroups: Set<BrainToolGroup> = []

    public init(_ tools: [any BrainTool] = []) {
        for tool in tools { register(tool) }
    }

    /// Adds a tool, replacing any tool with the same name in place.
    public mutating func register(_ tool: any BrainTool) {
        if let index = tools.firstIndex(where: { $0.spec.name == tool.spec.name }) {
            tools[index] = tool
        } else {
            tools.append(tool)
        }
    }

    public mutating func register(contentsOf more: [any BrainTool]) {
        for tool in more { register(tool) }
    }

    /// Adds a provider-hosted tool entry.
    public mutating func registerHosted(_ entry: JSONValue, group: BrainToolGroup) {
        guard !hostedTools.contains(entry) else { return }
        hostedTools.append(entry)
        hostedGroups.insert(group)
    }

    public mutating func addAliases(_ more: [String: String]) {
        aliases.merge(more) { current, _ in current }
    }

    /// What to send in `ChatRequest.tools`.
    public var specs: [ToolSpec] { tools.map(\.spec) }
    public var names: [String] { tools.map(\.spec.name) }
    public var groups: Set<BrainToolGroup> { Set(tools.map(\.group)).union(hostedGroups) }
    public var isEmpty: Bool { tools.isEmpty && hostedTools.isEmpty }

    public func tool(named name: String) -> (any BrainTool)? {
        if let tool = tools.first(where: { $0.spec.name == name }) { return tool }
        guard let target = aliases[name] else { return nil }
        return tools.first { $0.spec.name == target }
    }

    /// Parses a call's argument text: an object, or nil when it isn't one. Empty text is an empty object.
    public static func arguments(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let value = try? JSONValue.parse(trimmed), value.objectValue != nil else { return nil }
        return value
    }

    /// Runs an action that was held until the narration finished (`TurnEvent.deferredAction`).
    public func runDeferred(_ action: DeferredAction, sessionID: String = "", turn: Int = 0) async -> JSONValue {
        guard let tool = tool(named: action.name) else { return BrainToolResults.unknownTool(action.name) }
        if let problem = tool.validate(action.arguments) { return problem }
        return await tool.run(action.arguments, context: BrainToolContext(sessionID: sessionID, turn: turn, callID: action.callID))
    }
}

// MARK: - Registrations for the tools on main

extension ToolRegistry {
    /// save_memory (in the background), recall_memory and forget_memory (reads).
    public static func memoryTools(_ memory: MemoryTools) -> [any BrainTool] {
        func tool(_ spec: ToolSpec, _ kind: BrainToolKind) -> any BrainTool {
            ClosureBrainTool(spec: spec, kind: kind, group: .memory, runningStatus: MemoryTools.runningStatus(for: spec.name)) { args, _ in
                guard let result = memory.handle(name: spec.name, arguments: args.jsonString()),
                      let output = try? JSONValue.parse(result.output) else { return BrainToolResults.unknownTool(spec.name) }
                return output
            }
        }
        return [tool(MemoryTools.saveSpec, .async), tool(MemoryTools.recallSpec, .read), tool(MemoryTools.forgetSpec, .read)]
    }

    /// The local app tools. Lookups that need their result are reads; actions that change the screen wait for the
    /// narration; the rest run at once.
    public static func appTools(_ toolbox: AppToolbox) -> [any BrainTool] {
        toolbox.tools.map { appTool in
            let kind: BrainToolKind = appTool.needsFollowUpRound ? .read : (appTool.defersUntilNarrationEnds ? .deferredAction : .action)
            return ClosureBrainTool(
                spec: appTool.spec, kind: kind, group: .appTools, runningStatus: appTool.statusLabel,
                validate: { args in
                    do {
                        return appTool.validate(try ToolArguments(json: args))?.json
                    } catch {
                        return AppTool.result(for: error).json
                    }
                },
                run: { args, _ in
                    do {
                        return await appTool.run(try ToolArguments(json: args)).json
                    } catch {
                        return AppTool.result(for: error).json
                    }
                })
        }
    }

    /// offer_screen_takeover, start_screen_takeover and end_screen_takeover. They run at once (the consent card and
    /// the drive are their own UI) and need no follow-up round; none of them can approve a drive, only the user can.
    public static func takeoverTools(_ takeover: TakeoverTools) -> [any BrainTool] {
        takeover.appTools.map { appTool in
            ClosureBrainTool(
                spec: appTool.spec, kind: .action, group: .takeover, runningStatus: appTool.statusLabel,
                validate: { args in
                    do {
                        return appTool.validate(try ToolArguments(json: args))?.json
                    } catch {
                        return AppTool.result(for: error).json
                    }
                },
                run: { args, _ in
                    do {
                        return await appTool.run(try ToolArguments(json: args)).json
                    } catch {
                        return AppTool.result(for: error).json
                    }
                })
        }
    }

    /// web_search, image_search, place_search and stock_quote: reads, for the services that can answer.
    public static func lookupTools(_ lookups: LookupTools) -> [any BrainTool] {
        lookups.specs.map { spec in
            ClosureBrainTool(spec: spec, kind: .read, group: .lookups, runningStatus: LookupTools.runningStatus(for: spec.name)) { args, _ in
                guard let result = await lookups.handle(name: spec.name, arguments: args.jsonString()) else {
                    return BrainToolResults.unknownTool(spec.name)
                }
                return (try? JSONValue.parse(result.output)) ?? ["status": "error", "message": "The lookup returned nothing readable."]
            }
        }
    }

    /// The provider-hosted web search entry, when the user chose the brain's own search (`brain-hosted`), the brain's
    /// dialect has one and `enabled` (default: `HostedWebSearch.brainPassesHostedTools`, off for now). Register it with
    /// `registerHosted(_:group: .hostedSearch)`.
    public static func hostedWebSearch(_ lookups: LookupTools, dialect: ProviderDialect?, enabled: Bool = HostedWebSearch.brainPassesHostedTools,
                                       countryCode: String? = Locale.current.region?.identifier,
                                       timeZone: String? = TimeZone.current.identifier) -> JSONValue? {
        guard enabled, let dialect else { return nil }
        return lookups.hostedSearchTool(for: dialect, countryCode: countryCode, timeZone: timeZone)
    }

    /// read_connected_apps: a read. `apps` are the connected apps the tool may name.
    public static func connectedAppsTool(_ reader: ReadConnectedApps, apps: [ConnectedAppSummary]) -> any BrainTool {
        ClosureBrainTool(spec: ReadConnectedApps.toolSpec(apps: apps), kind: .read, group: .connectedApps,
                         runningStatus: "Reading your apps…") { args, _ in
            let outcome = await reader.run(arguments: args.jsonString())
            return ["status": outcome.didRead ? "ok" : "error", "text": .string(outcome.text)]
        }
    }

    /// The background-job tools. Starting and steering jobs are actions, looking at them is a read, showing a result
    /// card waits for the narration, and `routines` reads when it lists and acts otherwise.
    public static func agentTools(_ agent: AgentTools) -> [any BrainTool] {
        let kinds: [String: BrainToolKind] = [
            "sessions_spawn": .action, "sessions_send": .action, "sessions_interrupt": .action, "session_status": .read,
            "sessions_answer_request": .action, "find_jobs": .read, "show_result": .deferredAction, "routines": .action,
            "read_job": .read, "clicky_memory": .read, "clicky_artifacts": .read, "clicky_archive": .action,
            "open_artifact": .deferredAction, "open_agent_dashboard": .deferredAction,
        ]
        let statuses: [String: String] = [
            "sessions_spawn": "Starting a job…", "sessions_send": "Sending to the job…", "sessions_interrupt": "Stopping the job…",
            "session_status": "Checking your jobs…", "find_jobs": "Looking through your jobs…", "routines": "Updating routines…",
            "read_job": "Reading the job…", "clicky_memory": "Checking its notes…", "clicky_artifacts": "Looking at its files…",
            "clicky_archive": "Updating your agents…",
        ]
        let routinesKind: @Sendable (JSONValue) -> BrainToolKind = { args in
            args["action"]?.stringValue == "list" ? .read : .action
        }
        return agent.specs.map { spec -> any BrainTool in
            let perCall: (@Sendable (JSONValue) -> BrainToolKind)? = spec.name == "routines" ? routinesKind : nil
            return ClosureBrainTool(spec: spec, kind: kinds[spec.name] ?? .action, group: .agent, runningStatus: statuses[spec.name],
                                    kindForArguments: perCall) { args, _ in
                await agent.callJSON(name: spec.name, arguments: args.jsonString())
            }
        }
    }
}
