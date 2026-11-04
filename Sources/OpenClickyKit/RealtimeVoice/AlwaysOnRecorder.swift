import Foundation

/// Folds an always-on conversation's updates into history turns: one per exchange, with what the user said (or typed
/// into the conversation), everything the voice said back, the tools it used, how the reply ended and the provider's
/// token use. Pure, so the boundaries are testable without a session.
///
/// An exchange opens when the user starts speaking (or types, or the voice speaks first) and closes when the next one
/// opens, when the voice is back to listening with no tool at work and no reply still due, or when the run ends.
public struct AlwaysOnTurnLog: Sendable {
    /// The realtime model, recorded on every turn.
    public var model: String?
    private let clock: @Sendable () -> Date
    private var open: Building?
    private var runningTools: Set<String> = []
    /// The last reply made tool calls, so another reply is coming once their results are in.
    private var replyDue = false
    /// Every turn closed in this run, oldest first (for the memory writer and the recent-conversation note).
    public private(set) var closed: [HistoryTurn] = []

    private struct Building: Sendable {
        var turn: HistoryTurn
        var typed: Bool
        var heardReply: Bool { !turn.spokenLines.isEmpty || !turn.tools.isEmpty }
    }

    public init(model: String? = nil, clock: @escaping @Sendable () -> Date = Date.init) {
        self.model = model
        self.clock = clock
    }

    /// What the user said in the open exchange so far, if anything.
    public var openWords: String? { open.map(\.turn.words).flatMap { $0.isEmpty ? nil : $0 } }

    /// The user typed into the conversation (the text panel while always-on runs). Returns turns that closed.
    public mutating func typed(_ text: String) -> [HistoryTurn] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        let done = closeOpen()
        open = Building(turn: newTurn(source: .text, words: words), typed: true)
        return done
    }

    /// Applies one update. Returns turns that closed because of it, in order.
    public mutating func apply(_ update: AlwaysOnUpdate) -> [HistoryTurn] {
        switch update {
        case .state(let state):
            return state.isActive ? [] : finish()
        case .reconnecting:
            runningTools = []
            replyDue = false
            return closeOpen()
        case .conversation(let update):
            return apply(update)
        }
    }

    /// Closes the open exchange (always-on ended).
    public mutating func finish() -> [HistoryTurn] {
        runningTools = []
        replyDue = false
        return closeOpen()
    }

    private mutating func apply(_ update: RealtimeConversationUpdate) -> [HistoryTurn] {
        switch update {
        case .state(let state):
            switch state {
            case .userSpeaking:
                // A new exchange, unless this one has no reply yet (the user is still going, or was cut short).
                if let open, open.heardReply || open.typed {
                    let done = closeOpen()
                    self.open = Building(turn: newTurn(source: .voice, words: ""), typed: false)
                    return done
                }
                if open == nil { open = Building(turn: newTurn(source: .voice, words: ""), typed: false) }
                return []
            case .listening:
                guard let open, open.heardReply, runningTools.isEmpty, !replyDue else { return [] }
                return closeOpen()
            case .ended:
                return finish()
            case .thinking, .speaking:
                return []
            }
        case .userCaption(let text, _):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return [] }
            if open == nil || open?.typed == true {
                let done = closeOpen()
                open = Building(turn: newTurn(source: .voice, words: words), typed: false)
                return done
            }
            // Transcripts can arrive after the reply has begun; they still belong to this exchange.
            open?.turn.words = words
            return []
        case .assistantCaption(let text):
            guard !text.isEmpty else { return [] }
            ensureOpen()
            mark(\.firstEventMs)
            mark(\.firstLineMs)
            return []
        case .status(let label):
            if let label, !label.isEmpty, open?.turn.statuses.last != label {
                ensureOpen()
                open?.turn.statuses.append(label)
            }
            return []
        case .tool(let activity):
            switch activity {
            case .started(let name, let callID, _):
                ensureOpen()
                mark(\.firstEventMs)
                runningTools.insert(callID)
                open?.turn.tools.append(name)
            case .finished(_, let callID, _), .superseded(_, let callID), .limitReached(_, let callID),
                 .refused(_, let callID, _), .withdrawn(_, let callID):
                runningTools.remove(callID)
            }
            return []
        case .bargeIn:
            open?.turn.narration = "cut off by the user"
            return []
        case .discardedTurn:
            // The committed turn was echo or silence: an exchange with nothing in it yet goes away.
            if let open, !open.heardReply, !open.typed { self.open = nil }
            return []
        case .responseFinished(let summary):
            ensureOpen()
            var splitter = SentenceSplitter()
            let lines = splitter.feed(summary.transcript) + splitter.finish()
            open?.turn.spokenLines += lines
            if let usage = summary.usage {
                var total = open?.turn.usage ?? HistoryUsage()
                total.input += usage.inputTokens
                total.output += usage.outputTokens
                open?.turn.usage = total
            }
            open?.turn.rounds += 1
            open?.turn.model = model
            let elapsed = elapsedMs
            open?.turn.timings.totalMs = elapsed
            switch summary.status {
            case .completed: break
            case .interrupted, .cancelled:
                let narration = open?.turn.narration ?? "cut off by the user"
                open?.turn.narration = narration
            case .failed, .incomplete:
                if lines.isEmpty { open?.turn.errorDetail = summary.detail ?? summary.status.rawValue }
            }
            replyDue = !summary.toolCalls.isEmpty && summary.status == .completed
            return []
        case .deferredActionFailed(let note):
            open?.turn.appNotes.append(note)
            return []
        case .ended:
            return finish()
        case .warning:
            return []
        }
    }

    private var elapsedMs: Int? {
        guard let open else { return nil }
        return max(0, Int((clock().timeIntervalSince(open.turn.startedAt) * 1000).rounded()))
    }

    private mutating func mark(_ key: WritableKeyPath<HistoryTimings, Int?>) {
        guard open != nil, open?.turn.timings[keyPath: key] == nil else { return }
        let elapsed = elapsedMs
        open?.turn.timings[keyPath: key] = elapsed
    }

    /// The voice spoke (or used a tool) with no user turn open: a reply to a note, a greeting.
    private mutating func ensureOpen() {
        guard open == nil else { return }
        var turn = newTurn(source: .app, words: "")
        turn.trigger = "always_on"
        open = Building(turn: turn, typed: false)
    }

    private func newTurn(source: HistoryTurnSource, words: String) -> HistoryTurn {
        var turn = HistoryTurn(sessionID: "", startedAt: clock(), source: source, words: words)
        turn.model = model
        return turn
    }

    private mutating func closeOpen() -> [HistoryTurn] {
        guard let building = open else { return [] }
        open = nil
        var turn = building.turn
        // Words with no reply at all (the session ended, or the user gave up) still count, as a cancelled turn.
        if !building.heardReply {
            guard !turn.words.isEmpty else { return [] }
            turn.outcome = .cancelled
        } else if turn.spokenLines.isEmpty, turn.errorDetail != nil {
            turn.outcome = .failed
        }
        if turn.timings.totalMs == nil { turn.timings.totalMs = elapsedMs(of: turn) }
        closed.append(turn)
        return [turn]
    }

    private func elapsedMs(of turn: HistoryTurn) -> Int {
        max(0, Int((clock().timeIntervalSince(turn.startedAt) * 1000).rounded()))
    }

    // MARK: - Reading the run

    /// The run as a conversation for the memory writer: the user's words and the voice's replies.
    public var conversation: [ChatMessage] {
        closed.flatMap { turn -> [ChatMessage] in
            var messages: [ChatMessage] = []
            if !turn.words.isEmpty { messages.append(.user(.text(turn.words))) }
            if !turn.spokenLines.isEmpty { messages.append(.assistant(turn.spokenLines.joined(separator: " "))) }
            return messages
        }
    }

    /// The last few exchanges as one note, for the brain (`send_to_higher_model`, and once the run ends). Nil before
    /// anything was said.
    public func recentNote(tag: String = "[Always-on so far]", exchanges: Int = 6, limit: Int = 1_500) -> String? {
        var lines: [String] = []
        for turn in closed.suffix(exchanges) {
            if !turn.words.isEmpty { lines.append("User: " + turn.words) }
            if !turn.spokenLines.isEmpty { lines.append("Voice: " + turn.spokenLines.joined(separator: " ")) }
        }
        if let words = openWords { lines.append("User (now): " + words) }
        guard !lines.isEmpty else { return nil }
        var text = lines.joined(separator: "\n")
        if text.count > limit { text = "…" + String(text.suffix(limit)) }
        return tag + " What the user and the always-on voice said, oldest first:\n" + text
    }
}

/// Always-on voice's record keeping in the app: every exchange goes into the history, in the conversation the brain
/// runtime holds (`BrainSessionNaming`), so typed Home chat, push-to-talk and always-on share one conversation; when a
/// run ends its transcript goes through the memory writer (the session note and profile changes), and a short note
/// of what was said reaches the brain's next turn.
@MainActor
public final class AlwaysOnRecorder {
    public let history: HistoryStore?
    public let sessions: (any BrainSessionNaming)?
    /// The session-end writer (brain-fast) and the store it writes to; nil skips memory.
    public let memory: (writer: MemoryWriter, store: MemoryStore)?
    /// Receives the run's closing note for the brain (`BrainTurnRunning.recordOutcome`).
    public var onRunNote: (@Sendable (String) async -> Void)?
    public var onLog: ((String) -> Void)?
    public private(set) var log: AlwaysOnTurnLog
    private let clock: @Sendable () -> Date
    private var appending: Task<Void, Never>?
    private var erasuresAtStart: Int?
    private let fallbackSessionID = UUID().uuidString

    public init(history: HistoryStore?, sessions: (any BrainSessionNaming)?, memory: (writer: MemoryWriter, store: MemoryStore)? = nil,
                model: String? = nil, clock: @escaping @Sendable () -> Date = Date.init) {
        self.history = history
        self.sessions = sessions
        self.memory = memory
        self.clock = clock
        log = AlwaysOnTurnLog(model: model, clock: clock)
        erasuresAtStart = memory?.store.erasures
    }

    public func apply(_ update: AlwaysOnUpdate) {
        store(log.apply(update))
        if case .state(let state) = update, !state.isActive { runEnded() }
    }

    public func typed(_ text: String) { store(log.typed(text)) }

    /// The recent exchanges, for `send_to_higher_model`.
    public func recentNote() -> String? { log.recentNote() }

    /// Waits until every closed turn is in the history (tests, shutdown).
    public func flush() async { await appending?.value }

    /// The memory and brain work a finished run started; tests wait for it.
    public private(set) var ending: Task<Void, Never>?

    private func store(_ turns: [HistoryTurn]) {
        guard !turns.isEmpty, let history else { return }
        let previous = appending
        let sessions = sessions, fallback = fallbackSessionID
        let report = onLog
        appending = Task { @MainActor in
            await previous?.value
            let id = await sessions?.currentSessionID() ?? fallback
            for var turn in turns {
                turn.sessionID = id
                do { try history.append(turn) } catch { report?("always-on turn not saved: \(error)") }
            }
        }
    }

    /// The run is over: the memory writer reads its conversation, and the brain hears what was said.
    private func runEnded() {
        let conversation = log.conversation
        let note = log.recentNote(tag: "[Always-on]")
        let memory = memory, erasures = erasuresAtStart
        let onRunNote = onRunNote, report = onLog
        let previous = appending
        let sessions = sessions, fallback = fallbackSessionID
        let model = log.model
        log = AlwaysOnTurnLog(model: model, clock: clock)
        erasuresAtStart = memory?.store.erasures
        guard !conversation.isEmpty else { return }
        ending = Task { @MainActor in
            await previous?.value
            if let note, let onRunNote { await onRunNote(note) }
            guard let memory else { return }
            let id = await sessions?.currentSessionID() ?? fallback
            do {
                let result = try await memory.writer.endSession(thread: conversation, store: memory.store, sessionID: id,
                                                                erasuresAtStart: erasures)
                report?("always-on memory: \(result.added.count) added, \(result.removed.count) removed")
            } catch {
                report?("always-on memory not written: \(error)")
            }
        }
    }
}
