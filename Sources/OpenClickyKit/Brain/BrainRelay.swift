import Foundation

/// Waits for cancellation cleanup to save the interrupted turn before the relay releases its runtime.
public protocol BrainTurnSettling: Sendable {
    func waitUntilIdle() async
}

/// Home, push-to-talk and always-on share one runtime and conversation. Preparation can build the first runtime;
/// selection then reserves it under the same lock that excludes replacement until each operation finishes.
public final class BrainRelay: BrainTurnRunning, ConversationSeeding, BrainSessionNaming, DeferredActionPerforming,
    @unchecked Sendable {
    private let lock = NSLock()
    private var current: (any BrainTurnRunning)?
    private var preparer: (@Sendable () async -> Void)?
    private var preparation: (id: UUID, task: Task<Void, Never>)?
    private var running = 0
    private let fallbackID = UUID().uuidString

    public init(_ brain: (any BrainTurnRunning)? = nil) { current = brain }

    /// Setting it is ignored while an operation holds the runtime (see `replaceIfIdle`, which says whether it happened).
    public var brain: (any BrainTurnRunning)? {
        get { lock.withLock { current } }
        set { _ = replaceIfIdle { newValue } }
    }

    public var isRunning: Bool { lock.withLock { running > 0 } }

    /// The builder runs synchronously while replacement and selection are excluded. It may also replace the app's
    /// related engines, so those and the selected brain always belong to the same configuration.
    @discardableResult
    public func replaceIfIdle(_ build: () -> (any BrainTurnRunning)?) -> Bool {
        lock.withLock {
            guard running == 0 else { return false }
            current = build()
            return true
        }
    }

    public func setPrepare(_ prepare: (@Sendable () async -> Void)?) {
        lock.withLock { preparer = prepare }
    }

    /// `always`: a turn or prewarm, which may pick up changed settings. `ifMissing`: bookkeeping (outcomes, session ids,
    /// seeding, deferred actions), which builds the first runtime but otherwise uses the one that is there.
    private enum Preparation { case always, ifMissing }

    private func reserve(_ when: Preparation = .ifMissing) async -> (any BrainTurnRunning)? {
        let pending = lock.withLock { () -> (id: UUID, task: Task<Void, Never>)? in
            guard let preparer else { return nil }
            // Join a preparation already under way, so a bookkeeping call never pins the runtime it is replacing.
            if let preparation { return preparation }
            if when == .ifMissing, current != nil { return nil }
            let made = (id: UUID(), task: Task { await preparer() })
            preparation = made
            return made
        }
        // A cancelled caller must not cancel preparation shared by another caller.
        if let pending { await pending.task.value }
        return lock.withLock {
            if let pending, preparation?.id == pending.id { preparation = nil }
            guard !Task.isCancelled, let current else { return nil }
            running += 1
            return current
        }
    }

    private func release() { lock.withLock { running -= 1 } }

    public func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let brain = await self.reserve(.always) else {
                    if !Task.isCancelled {
                        continuation.yield(.failed(spoken: "I can't answer yet, because my brain model isn't set up. Choose one in Settings, under Models.",
                                                   detail: "No brain is connected to the relay."))
                    }
                    continuation.finish()
                    return
                }
                defer { self.release() }
                var failure: (any Error)?
                do {
                    for try await event in brain.run(input) { continuation.yield(event) }
                } catch { failure = error }
                // Cancelling a stream can return before its runtime has saved the interrupted turn.
                await (brain as? any BrainTurnSettling)?.waitUntilIdle()
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prewarm() async {
        guard let brain = await reserve(.always) else { return }
        defer { release() }
        await brain.prewarm()
    }

    public func recordOutcome(_ note: String) async {
        guard let brain = await reserve() else { return }
        defer { release() }
        await brain.recordOutcome(note)
    }

    public func endSession() async {
        guard let brain = await reserve() else { return }
        defer { release() }
        await brain.endSession()
    }

    public func currentSessionID() async -> String {
        guard let brain = await reserve() else { return fallbackID }
        defer { release() }
        return await (brain as? any BrainSessionNaming)?.currentSessionID() ?? fallbackID
    }

    public func seedConversation(_ turns: [HistoryTurn]) async {
        guard let brain = await reserve() else { return }
        defer { release() }
        await (brain as? any ConversationSeeding)?.seedConversation(turns)
    }

    public func seedConversation(_ turns: [HistoryTurn], sessionID: String) async {
        guard let brain = await reserve() else { return }
        defer { release() }
        await (brain as? any ConversationSeeding)?.seedConversation(turns, sessionID: sessionID)
    }

    public func performDeferred(_ action: DeferredAction) async -> JSONValue {
        guard let brain = await reserve() else {
            return ["status": "unavailable", "message": .string("No brain can run \(action.name) right now.")]
        }
        defer { release() }
        guard let performer = brain as? any DeferredActionPerforming else {
            return ["status": "unavailable", "message": .string("No brain can run \(action.name) right now.")]
        }
        return await performer.performDeferred(action)
    }
}
