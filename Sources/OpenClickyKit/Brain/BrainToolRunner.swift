import Foundation

/// Runs one turn's tool calls.
///
/// - A call starts as soon as the model finishes writing it, while the reply may still be streaming.
/// - Calls run concurrently, but results go back in the order the calls started.
/// - Deferred actions are not run here: the turn reports them (`TurnEvent.deferredAction`) and the model hears that
///   they are queued. Background (`async`) calls are handed to `background` and the model hears that they started.
/// - At most `cap` calls run per turn; later ones get a "tool_limit_reached" result without running. Reads in the
///   last allowed round get it too, since no round is left to read their results.
/// - When the turn is cancelled (a newer turn, the user let go of the reply), running calls are cancelled and get a
///   "cancelled" result; calls that had not started get "never ran". Nothing waits for a tool that ignores
///   cancellation.
final class BrainToolRunner {
    struct Entry {
        let call: ToolCall
        let kind: BrainToolKind?
        /// A result decided without running (deferred, background, refused, over the cap).
        var immediate: JSONValue?
        var task: Task<Void, Never>?
        /// The runtime reported `toolStarted` for it (so `toolFinished` follows).
        var announced: Bool
    }

    struct Outcome {
        let call: ToolCall
        let result: JSONValue
        let announced: Bool
        var succeeded: Bool { BrainToolResults.succeeded(result) }
    }

    private(set) var entries: [Entry] = []
    private let box = ToolResultBox()
    private let cap: Int
    private var counted = 0
    private(set) var abandoned = false

    init(cap: Int) { self.cap = max(0, cap) }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var deferredCount: Int { entries.filter { $0.kind == .deferredAction && $0.immediate?["status"]?.stringValue == "queued" }.count }

    /// Starts (or defers, or refuses) a call and returns the events to report now.
    func start(_ call: ToolCall, registry: ToolRegistry, context: BrainToolContext, lastRound: Bool,
               background: (String, any BrainTool, JSONValue, BrainToolContext) -> Void) -> [TurnEvent] {
        guard !abandoned else {
            entries.append(Entry(call: call, kind: nil, immediate: BrainToolResults.neverRan, task: nil, announced: false))
            return []
        }
        guard let tool = registry.tool(named: call.name) else {
            entries.append(Entry(call: call, kind: nil, immediate: BrainToolResults.unknownTool(call.name), task: nil, announced: false))
            return []
        }
        guard let arguments = ToolRegistry.arguments(call.arguments) else {
            entries.append(Entry(call: call, kind: tool.kind, immediate: BrainToolResults.badArguments, task: nil, announced: false))
            return []
        }
        let kind = tool.kind(for: arguments)
        counted += 1
        if counted > cap || (lastRound && kind == .read) {
            entries.append(Entry(call: call, kind: kind, immediate: BrainToolResults.limitReached, task: nil, announced: false))
            return []
        }
        if let problem = tool.validate(arguments) {
            entries.append(Entry(call: call, kind: kind, immediate: problem, task: nil, announced: false))
            return []
        }
        switch kind {
        case .deferredAction:
            entries.append(Entry(call: call, kind: kind, immediate: BrainToolResults.queued, task: nil, announced: false))
            return [.deferredAction(DeferredAction(callID: call.id, name: tool.spec.name, arguments: arguments))]
        case .async:
            background(call.id, tool, arguments, context)
            entries.append(Entry(call: call, kind: kind, immediate: BrainToolResults.started, task: nil, announced: false))
            return [.toolStarted(name: tool.spec.name, callID: call.id)]
        case .read, .action:
            let box = self.box
            let id = call.id
            let task = Task {
                let result = await tool.run(arguments, context: context)
                box.set(id, result)
            }
            entries.append(Entry(call: call, kind: kind, immediate: nil, task: task, announced: true))
            var events: [TurnEvent] = []
            if let status = tool.runningStatus { events.append(.status(status)) }
            events.append(.toolStarted(name: tool.spec.name, callID: call.id))
            return events
        }
    }

    /// Whether the calls from `index` on need the model to read their results in another round.
    func needsRound(from index: Int) -> Bool {
        entries[index...].contains { $0.kind == .read && $0.immediate == nil }
    }

    /// Stops running calls; their results become "cancelled".
    func abandon() {
        abandoned = true
        for entry in entries { entry.task?.cancel() }
        box.abandon()
    }

    /// The results of the calls from `index` on, in start order, waiting for running calls unless abandoned.
    func collect(from index: Int) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for entry in entries[index...] {
            if let immediate = entry.immediate {
                outcomes.append(Outcome(call: entry.call, result: immediate, announced: entry.announced))
                continue
            }
            let result = abandoned ? box.result(entry.call.id) : await box.wait(entry.call.id)
            outcomes.append(Outcome(call: entry.call, result: result ?? BrainToolResults.cancelled, announced: entry.announced))
        }
        return outcomes
    }
}

/// Results of running calls, with waits that give up when the turn is cancelled.
final class ToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: JSONValue] = [:]
    private var waiters: [String: [CheckedContinuation<JSONValue?, Never>]] = [:]
    private var abandoned = false

    func set(_ id: String, _ value: JSONValue) {
        lock.lock()
        results[id] = value
        let ready = waiters.removeValue(forKey: id) ?? []
        lock.unlock()
        for waiter in ready { waiter.resume(returning: value) }
    }

    func result(_ id: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return results[id]
    }

    /// The call's result once it is set; nil when the box is abandoned (or the waiting task cancelled) first.
    func wait(_ id: String) async -> JSONValue? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<JSONValue?, Never>) in
                lock.lock()
                if let value = results[id] {
                    lock.unlock()
                    continuation.resume(returning: value)
                } else if abandoned {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiters[id, default: []].append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            abandon()
        }
    }

    func abandon() {
        lock.lock()
        abandoned = true
        let all = waiters.values.flatMap { $0 }
        waiters = [:]
        lock.unlock()
        for waiter in all { waiter.resume(returning: nil) }
    }
}
