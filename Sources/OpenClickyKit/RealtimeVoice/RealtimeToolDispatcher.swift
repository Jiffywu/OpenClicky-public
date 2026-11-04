import Foundation

// Runs the tools the realtime model calls (docs/re/02-voice-pipeline.md §6.2): each call runs in its own task, its
// answer goes back to the session, and a short status shows while it runs. Rules:
// - A per-turn cap: past it, calls are answered `tool_limit_reached` and the model is told to answer with what it has.
// - Results that finish after a newer user turn are answered `superseded` without asking the model to speak, and work
//   that is only worth having for the old turn (lookups, the higher model) is cancelled.
// - Unknown tools are answered `not_implemented`; malformed arguments `invalid_request`.
// - Actions that change what the user sees or hears (opening a link, playing music) wait until the reply about them has
//   been spoken; `takeDeferredWork()` hands them to the conversation when its audio drains.

/// A picture a tool attaches to the conversation before its result, so the model can look at it.
public struct RealtimeImage: Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public var caption: String?

    public init(data: Data, mimeType: String = "image/jpeg", caption: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.caption = caption
    }
}

/// An action held until the reply has been spoken. `run` returns an `[App]` note when it did not work.
public struct RealtimeDeferredWork: Sendable {
    public var name: String
    public var callID: String
    public var run: @Sendable () async -> String?

    public init(name: String, callID: String, run: @escaping @Sendable () async -> String?) {
        self.name = name
        self.callID = callID
        self.run = run
    }
}

/// What one tool produced.
public struct RealtimeToolOutcome: Sendable {
    /// What the model reads: a JSON object with a `status` word first.
    public var output: JSONValue
    public var succeeded: Bool
    public var images: [RealtimeImage]
    public var deferred: RealtimeDeferredWork?

    public init(output: JSONValue, succeeded: Bool, images: [RealtimeImage] = [], deferred: RealtimeDeferredWork? = nil) {
        self.output = output
        self.succeeded = succeeded
        self.images = images
        self.deferred = deferred
    }

    /// `{"status": status, "message": message, …details}`.
    public static func status(_ status: String, _ message: String? = nil, details: [String: JSONValue] = [:],
                              succeeded: Bool) -> RealtimeToolOutcome {
        var object = details
        object["status"] = .string(status)
        if let message { object["message"] = .string(message) }
        return RealtimeToolOutcome(output: .object(object), succeeded: succeeded)
    }

    /// A JSON tool output produced elsewhere (memory, lookups), parsed back into JSON when it is JSON.
    public static func text(_ output: String, succeeded: Bool) -> RealtimeToolOutcome {
        let parsed = (try? JSONValue.parse(output)).flatMap { $0.objectValue == nil ? nil : $0 }
        return RealtimeToolOutcome(output: parsed ?? ["status": succeeded ? "ok" : "error", "result": .string(output)],
                                   succeeded: succeeded)
    }
}

/// One call as a tool sees it.
public struct RealtimeToolInvocation: Sendable {
    public var callID: String
    public var name: String
    /// The parsed arguments object (empty when the model sent none).
    public var arguments: [String: JSONValue]
    /// What the user said in the turn that led to this call, as far as it has been transcribed.
    public var userWords: String

    public init(callID: String, name: String, arguments: [String: JSONValue], userWords: String = "") {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.userWords = userWords
    }

    public func string(_ key: String) -> String? { realtimeTrimmed(arguments[key]?.stringValue) }
    public func bool(_ key: String) -> Bool? { arguments[key]?.boolValue }
}

/// A tool the realtime model can call.
public struct RealtimeTool: Sendable {
    public var spec: ToolSpec
    /// Shown while it runs ("Looking at your screen…").
    public var statusLabel: String?
    /// Stop the work when a newer user turn makes it moot. Actions the user asked for (saving a memory) finish anyway.
    public var cancelsWhenSuperseded: Bool
    /// Longest the tool may run before it is answered `timed_out`.
    public var timeout: Duration
    public var run: @Sendable (RealtimeToolInvocation) async -> RealtimeToolOutcome

    public init(spec: ToolSpec, statusLabel: String?, cancelsWhenSuperseded: Bool = true, timeout: Duration = .seconds(30),
                run: @escaping @Sendable (RealtimeToolInvocation) async -> RealtimeToolOutcome) {
        self.spec = spec
        self.statusLabel = statusLabel
        self.cancelsWhenSuperseded = cancelsWhenSuperseded
        self.timeout = timeout
        self.run = run
    }

    public var name: String { spec.name }
}

/// What the dispatcher is doing, for the notch status and logs.
public enum RealtimeToolActivity: Sendable, Hashable {
    case started(name: String, callID: String, label: String?)
    case finished(name: String, callID: String, succeeded: Bool)
    /// Answered `superseded`: a newer user turn arrived first.
    case superseded(name: String, callID: String)
    /// Answered `tool_limit_reached`.
    case limitReached(name: String, callID: String)
    /// Answered at once without running (unknown tool, bad arguments).
    case refused(name: String, callID: String, status: String)
    /// The provider withdrew the call; no answer was sent.
    case withdrawn(name: String, callID: String)
}

public actor RealtimeToolDispatcher {
    public nonisolated let specs: [ToolSpec]
    public nonisolated let activity: AsyncStream<RealtimeToolActivity>
    private let activityContinuation: AsyncStream<RealtimeToolActivity>.Continuation
    private let tools: [String: RealtimeTool]
    public let maxCallsPerTurn: Int

    private struct Running {
        var name: String
        var generation: Int
        var cancels: Bool
        var task: Task<Void, Never>
    }

    private var generation = 0
    private var callsThisTurn = 0
    private var running: [String: Running] = [:]
    private var deferred: [RealtimeDeferredWork] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(tools: [RealtimeTool], maxCallsPerTurn: Int = 6) {
        var byName: [String: RealtimeTool] = [:]
        var ordered: [ToolSpec] = []
        for tool in tools where byName[tool.name] == nil {
            byName[tool.name] = tool
            ordered.append(tool.spec)
        }
        self.tools = byName
        self.specs = ordered
        self.maxCallsPerTurn = max(1, maxCallsPerTurn)
        (activity, activityContinuation) = AsyncStream<RealtimeToolActivity>.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        activityContinuation.finish()
        for entry in running.values { entry.task.cancel() }
    }

    public nonisolated func statusLabel(for name: String) -> String? { tools[name]?.statusLabel }

    /// Starts a call. Returns at once; the answer goes to `session` when the tool finishes.
    public func handle(_ call: RealtimeToolCall, session: any RealtimeVoiceSession, userWords: String = "") async {
        callsThisTurn += 1
        if callsThisTurn > maxCallsPerTurn {
            activityContinuation.yield(.limitReached(name: call.name, callID: call.callID))
            await session.sendToolResult(RealtimeToolResult(callID: call.callID, name: call.name, output: [
                "status": "tool_limit_reached",
                "message": .string("No more tools this turn. Reply to the user now using the results you have."),
            ]))
            return
        }
        guard let tool = tools[call.name] else {
            activityContinuation.yield(.refused(name: call.name, callID: call.callID, status: "not_implemented"))
            await session.sendToolResult(RealtimeToolResult(callID: call.callID, name: call.name, output: [
                "status": "not_implemented", "message": .string("There is no tool named \(call.name)."),
            ]))
            return
        }
        guard let arguments = Self.arguments(call.arguments) else {
            activityContinuation.yield(.refused(name: call.name, callID: call.callID, status: "invalid_request"))
            await session.sendToolResult(RealtimeToolResult(callID: call.callID, name: call.name, output: [
                "status": "invalid_request", "message": "The arguments were not a JSON object.",
            ]))
            return
        }
        let invocation = RealtimeToolInvocation(callID: call.callID, name: call.name, arguments: arguments, userWords: userWords)
        let generation = self.generation
        activityContinuation.yield(.started(name: call.name, callID: call.callID, label: tool.statusLabel))
        let task = Task { [weak self] in
            let outcome = await Self.run(tool, invocation)
            await self?.finish(callID: call.callID, outcome: outcome, session: session)
        }
        running[call.callID] = Running(name: call.name, generation: generation, cancels: tool.cancelsWhenSuperseded, task: task)
    }

    /// A newer user turn began: results still running become `superseded`, cancellable work stops, held actions are
    /// dropped and the per-turn cap starts over.
    public func userTurnStarted() {
        generation += 1
        callsThisTurn = 0
        deferred.removeAll()
        for entry in running.values where entry.cancels { entry.task.cancel() }
    }

    /// The provider withdrew these calls: stop them and send nothing.
    public func withdraw(_ callIDs: [String]) {
        for id in callIDs {
            guard let entry = running.removeValue(forKey: id) else { continue }
            entry.task.cancel()
            activityContinuation.yield(.withdrawn(name: entry.name, callID: id))
        }
        resumeIdleWaitersIfIdle()
    }

    /// Actions held until the reply has been spoken, in the order they were asked for. The caller runs them.
    public func takeDeferredWork() -> [RealtimeDeferredWork] {
        defer { deferred.removeAll() }
        return deferred
    }

    public var runningCount: Int { running.count }
    public var pendingDeferredCount: Int { deferred.count }

    /// Waits until no call is running (tests, and the simulator before it ends).
    public func waitUntilIdle() async {
        if running.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Stops every running call without answering (the session is closing).
    public func cancelAll() {
        for entry in running.values { entry.task.cancel() }
        running.removeAll()
        deferred.removeAll()
        resumeIdleWaitersIfIdle()
    }

    // MARK: - Internals

    private func finish(callID: String, outcome: RealtimeToolOutcome, session: any RealtimeVoiceSession) async {
        guard let entry = running.removeValue(forKey: callID) else { return }  // withdrawn
        defer { resumeIdleWaitersIfIdle() }
        if entry.generation != generation {
            activityContinuation.yield(.superseded(name: entry.name, callID: callID))
            await session.sendToolResult(RealtimeToolResult(callID: callID, name: entry.name, output: [
                "status": "superseded",
                "message": "Outdated: the user started a new request before this came back. Ignore it unless they ask for it again.",
            ], respond: false))
            return
        }
        for image in outcome.images {
            await session.addImage(image.data, mimeType: image.mimeType, caption: image.caption)
        }
        if let work = outcome.deferred { deferred.append(work) }
        activityContinuation.yield(.finished(name: entry.name, callID: callID, succeeded: outcome.succeeded))
        await session.sendToolResult(RealtimeToolResult(callID: callID, name: entry.name, output: outcome.output))
    }

    private func resumeIdleWaitersIfIdle() {
        guard running.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Runs a tool under its timeout. A cancelled run (superseded) still returns an outcome, which `finish` replaces.
    ///
    /// The tool runs in its own task rather than a task group: a group waits for every child before it returns, so a
    /// tool that ignores cancellation (a blocking AppleScript, a stuck socket) would hold its `timed_out` answer back
    /// until it finished. Here the first of result, deadline or cancellation answers, and the tool is cancelled and
    /// left to wind down on its own.
    private static func run(_ tool: RealtimeTool, _ invocation: RealtimeToolInvocation) async -> RealtimeToolOutcome {
        let race = RealtimeOutcomeRace()
        let work = Task { race.settle(await tool.run(invocation)) }
        let timer = Task {
            try? await Task.sleep(for: tool.timeout)
            if !Task.isCancelled {
                race.settle(.status("timed_out", "No result in time. Let the user know this one didn't work out.", succeeded: false))
            }
        }
        let outcome = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            race.settle(.status("cancelled", "This was called off before it was done.", succeeded: false))
        }
        work.cancel()
        timer.cancel()
        return outcome
    }

    static func arguments(_ text: String) -> [String: JSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        return (try? JSONValue.parse(trimmed))?.objectValue
    }
}

/// The first outcome settled wins; `value()` waits for it (or returns it at once if it is already in).
final class RealtimeOutcomeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: RealtimeToolOutcome?
    private var waiter: CheckedContinuation<RealtimeToolOutcome, Never>?

    func settle(_ value: RealtimeToolOutcome) {
        let resume: CheckedContinuation<RealtimeToolOutcome, Never>? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = value
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(returning: value)
    }

    func value() async -> RealtimeToolOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<RealtimeToolOutcome, Never>) in
            let ready: RealtimeToolOutcome? = lock.withLock {
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
