import Foundation

/// A brain that can be handed the earlier turns of a conversation it wasn't part of in this process: one picked up
/// from the history after a relaunch, or an older conversation chosen in Home. Without them a follow-up such as
/// "does it make my internet faster?" loses what "it" was.
public protocol ConversationSeeding: AnyObject, Sendable {
    /// Replaces the brain's thread with these turns (oldest first). Only completed turns with words and a reply count.
    func seedConversation(_ turns: [HistoryTurn]) async
    /// The same, with the brain's conversation taking `sessionID` (brains that name the history session, such as the
    /// brain runtime, then keep recording into the conversation that was picked).
    func seedConversation(_ turns: [HistoryTurn], sessionID: String) async
}

extension ConversationSeeding {
    public func seedConversation(_ turns: [HistoryTurn], sessionID: String) async { await seedConversation(turns) }
}

/// Sends typed questions through the brain and records each turn in the history. The Home chat and
/// `occtl history chat` use it; the brain is whatever implements `BrainTurnRunning`: in the app the voice loop's brain
/// runtime (through `BrainRelay`), so a typed question gets the same tools, drawing, lookups and jobs as a spoken one.
///
/// Which conversation a question goes into:
/// - a brain that names its session (`BrainSessionNaming`, the brain runtime) decides: typed turns are recorded in
///   the brain's own conversation, the one voice and always-on turns go into too;
/// - `resume(sessionID:)` picks a conversation from the history: before the next question the brain is switched to it
///   (seeded with its earlier turns and taking its id, `ConversationSeeding`);
/// - other brains (`StandInTextBrain`, tests) reuse the newest history conversation while it is fresh.
///
/// Actions the brain held until its answer was said (`deferredAction`: open a link, show a job's result) run once the
/// answer is in, through the brain when it can perform them.
public final class TypedChatController: @unchecked Sendable {
    public let brain: any BrainTurnRunning
    public let history: HistoryStore?
    /// A new conversation starts when the last one has been quiet this long (brains that don't name their session).
    public var idleLimit: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    /// The conversation picked with `resume(sessionID:)` or `startNewConversation`, until the brain holds it.
    private var sessionID: String?
    /// The conversation the brain's in-memory thread belongs to; nil until the first turn.
    private var brainSessionID: String?

    public init(brain: any BrainTurnRunning, history: HistoryStore?, idleLimit: TimeInterval = 6 * 3600,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.brain = brain
        self.history = history
        self.idleLimit = idleLimit
        self.clock = clock
    }

    private var naming: (any BrainSessionNaming)? { brain as? any BrainSessionNaming }

    /// The note the Home chat sends with every question to a brain that draws (the brain runtime): it isn't looking
    /// at the user's screen, and its lines are shown rather than spoken.
    public static let homeWindowNote = "[App] The user typed this in OpenClicky's Home window, not over another app, so there "
        + "is no screenshot and nothing to point at. Your say() lines show as chat text; a drawing shows as a small picture "
        + "beside the reply."

    /// The conversation typed turns go into: the one in use, the most recent if it is still fresh, or a new one. For a
    /// brain that names its session, `resolvedSessionID()` is the one that counts.
    public func currentSessionID() -> String {
        lock.withLock {
            if let sessionID { return sessionID }
            if let latest = history?.sessions(limit: 1).first, clock().timeIntervalSince(latest.updatedAt) < idleLimit {
                sessionID = latest.id
                return latest.id
            }
            let id = UUID().uuidString
            sessionID = id
            return id
        }
    }

    /// The conversation the next question goes into: a picked one, else the brain's own when it names it.
    public func resolvedSessionID() async -> String {
        if let picked = lock.withLock({ sessionID }) { return picked }
        if let naming {
            let id = await naming.currentSessionID()
            lock.withLock { brainSessionID = id }
            return id
        }
        return currentSessionID()
    }

    /// Continue an older conversation from the history. The brain is switched over at the next question.
    public func resume(sessionID id: String) {
        lock.withLock { sessionID = id }
    }

    /// Follow the brain's own conversation again (brains that name it); others keep the current one.
    public func followBrain() {
        guard naming != nil else { return }
        lock.withLock { sessionID = nil }
    }

    /// Ends the conversation: the brain writes its notes and the next question starts a new session.
    public func startNewConversation(id: String = UUID().uuidString) async {
        if naming != nil, let seeding = brain as? any ConversationSeeding {
            // Ends the brain's conversation (its notes are written) and starts an empty one under this id.
            await seeding.seedConversation([], sessionID: id)
        } else {
            await brain.endSession()
        }
        lock.withLock {
            sessionID = id
            brainSessionID = id
        }
    }

    /// Makes the brain's thread belong to `sessionID` before a question goes into it: a brain still holding another
    /// conversation ends that session first, and a brain that takes seeding gets this conversation's earlier turns
    /// from the history (and, when it names its session, takes this conversation's id).
    private func prepareBrain(for sessionID: String) async {
        let switching: (needed: Bool, previous: String?) = lock.withLock { (brainSessionID != sessionID, brainSessionID) }
        guard switching.needed else { return }
        if let naming, await naming.currentSessionID() == sessionID {
            lock.withLock { brainSessionID = sessionID }
            return
        }
        let earlier = (try? history?.turns(in: sessionID)) ?? []
        if let seeding = brain as? any ConversationSeeding {
            if naming != nil {
                // Seeding ends the brain's current conversation itself (its memory notes are still written).
                await seeding.seedConversation(earlier, sessionID: sessionID)
            } else {
                if switching.previous != nil { await brain.endSession() }
                await seeding.seedConversation(earlier)
            }
        } else if switching.previous != nil || naming != nil {
            await brain.endSession()
        }
        lock.withLock { brainSessionID = sessionID }
    }

    /// Sends one typed question. `onEvent` sees every brain event as it arrives (for a live reply bubble); the
    /// returned turn is already in the history. `appNotes` go to the brain ahead of the words (where the question was
    /// typed, for example).
    @discardableResult
    public func send(_ text: String, context: TurnContext = TurnContext(), appNotes: [String] = [],
                     onEvent: @escaping @Sendable (TurnEvent) -> Void = { _ in }) async -> HistoryTurn {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = TurnInput(words: words, isTyped: true, context: context, appNotes: appNotes)
        let picked = lock.withLock { sessionID }
        let sessionID: String
        if let picked { sessionID = picked } else if naming == nil { sessionID = currentSessionID() } else { sessionID = await resolvedSessionID() }
        await prepareBrain(for: sessionID)
        // Once the brain holds the picked conversation, follow the brain (it may move on after an idle end).
        if picked != nil, naming != nil { lock.withLock { if self.sessionID == picked { self.sessionID = nil } } }
        var log = TurnLogBuilder(input: input, sessionID: sessionID, source: .text, clock: clock)
        var held: [DeferredAction] = []
        do {
            for try await event in brain.run(input) {
                log.apply(event)
                if case .deferredAction(let action) = event { held.append(action) }
                onEvent(event)
            }
        } catch is CancellationError {
            // Recorded as cancelled below.
        } catch {
            let failure = TurnEvent.failed(spoken: "Something went wrong with that answer.", detail: "\(error)")
            log.apply(failure)
            onEvent(failure)
        }
        let turn = log.finish()
        try? history?.append(turn)
        if turn.outcome == .completed, !held.isEmpty, let performer = brain as? any DeferredActionPerforming {
            for action in held { _ = await performer.performDeferred(action) }
        }
        return turn
    }
}

/// A plain text brain for typed chat until the brain runtime lands: one model call on the brain slot per turn, a
/// short thread kept in memory, no screenshots, tools or drawing. Each finished sentence comes out as a `sayLine`.
public final class StandInTextBrain: BrainTurnRunning, ConversationSeeding, @unchecked Sendable {
    public let client: any LanguageModelClient
    public let model: String
    /// Extra system-prompt sections read at every turn (active skills, memory).
    public var extraSystemSections: @Sendable () -> [String]
    public var maxThreadMessages: Int
    public var maxOutputTokens: Int
    private let lock = NSLock()
    private var thread: [ChatMessage] = []
    private var pendingNotes: [String] = []

    public init(client: any LanguageModelClient, model: String, maxThreadMessages: Int = 24, maxOutputTokens: Int = 600,
                extraSystemSections: @escaping @Sendable () -> [String] = { [] }) {
        self.client = client
        self.model = model
        self.maxThreadMessages = maxThreadMessages
        self.maxOutputTokens = maxOutputTokens
        self.extraSystemSections = extraSystemSections
    }

    /// The brain slot's model from a config.
    public static func forBrainSlot(_ factory: EngineFactory, extraSystemSections: @escaping @Sendable () -> [String] = { [] }) throws -> StandInTextBrain {
        let client = try factory.languageModel(for: .brain)
        let model = try factory.resolve(.brain).selection.model
        return StandInTextBrain(client: client, model: model, extraSystemSections: extraSystemSections)
    }

    static let systemPrompt = """
        You are OpenClicky, an assistant that lives on the user's Mac. Right now the user is typing to you in the Home \
        window, so you can't see their screen and can't point or draw in this chat. Answer the way you would speak: \
        plain sentences, no markdown, no lists unless they ask, usually two to four sentences. If they need you to look \
        at something or show them where to click, tell them to hold their talk keys and ask out loud.
        """

    public func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let task = Task { [self] in
            let started = Date()
            var firstToken: Double?
            var reply = ""
            var splitter = SentenceSplitter()
            var lines: [String] = []
            var usage: TokenUsage?
            func emit(_ sentences: [String]) {
                for sentence in sentences {
                    continuation.yield(.sayLine(index: lines.count, text: sentence))
                    lines.append(sentence)
                }
            }
            do {
                let request = ChatRequest(model: model, messages: messages(for: input), maxOutputTokens: maxOutputTokens)
                for try await event in client.stream(request) {
                    switch event {
                    case .textDelta(let text):
                        if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                        reply += text
                        emit(splitter.feed(text))
                    case .usage(let reported):
                        usage = reported
                    default:
                        break
                    }
                }
                emit(splitter.finish())
                remember(input: input, reply: reply)
                continuation.yield(.roundFinished(1))
                continuation.yield(.finished(TurnSummary(program: "", spokenLines: lines, rounds: 1, usage: usage, model: model,
                                                         firstTokenSeconds: firstToken, totalSeconds: Date().timeIntervalSince(started))))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.yield(.failed(spoken: "I couldn't reach the brain model just now.", detail: "\(error)"))
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func messages(for input: TurnInput) -> [ChatMessage] {
        let sections = [Self.systemPrompt] + extraSystemSections().filter { !$0.isEmpty }
        var messages = [ChatMessage.system(sections.joined(separator: "\n\n"))]
        let notes = lock.withLock { () -> [String] in
            defer { pendingNotes = [] }
            messages += thread
            return pendingNotes
        }
        var text = (notes + input.appNotes).joined(separator: "\n")
        if !text.isEmpty { text += "\n\n" }
        text += input.words
        messages.append(.user(.text(text)))
        return messages
    }

    private func remember(input: TurnInput, reply: String) {
        lock.withLock {
            thread.append(.user(.text(input.words)))
            thread.append(.assistant(reply))
            if thread.count > maxThreadMessages { thread.removeFirst(thread.count - maxThreadMessages) }
        }
    }

    public func prewarm() async {}

    public func seedConversation(_ turns: [HistoryTurn]) async {
        let messages = turns
            .filter { $0.outcome == .completed && !$0.words.isEmpty && !$0.spokenLines.isEmpty }
            .flatMap { [ChatMessage.user(.text($0.words)), ChatMessage.assistant($0.replyText)] }
        lock.withLock {
            // Whole question-and-answer pairs only.
            thread = Array(messages.suffix(maxThreadMessages - maxThreadMessages % 2))
            pendingNotes = []
        }
    }

    public func recordOutcome(_ note: String) async {
        lock.withLock { pendingNotes.append(note) }
    }

    public func endSession() async {
        lock.withLock {
            thread = []
            pendingNotes = []
        }
    }
}

/// Cuts streamed text into sentences as soon as each one ends.
struct SentenceSplitter: Sendable {
    private var buffer = ""

    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let end = Self.sentenceEnd(in: buffer) {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences
    }

    mutating func finish() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    /// The index just past a sentence end followed by whitespace (so "3.5" and "e.g." mid-stream don't split early),
    /// or past a newline.
    static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" { return next }
            if ".!?".contains(character), next < text.endIndex, text[next].isWhitespace {
                // Skip common abbreviations.
                let before = text[..<index].split(whereSeparator: \.isWhitespace).last.map(String.init)?.lowercased() ?? ""
                if !["e.g", "i.e", "mr", "mrs", "ms", "dr", "vs", "etc"].contains(before) { return next }
            }
            index = next
        }
        return nil
    }
}
