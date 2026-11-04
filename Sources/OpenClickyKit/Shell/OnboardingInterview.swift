import Foundation

// The onboarding welcome chat (docs/re/08-apps-memory-ui.md §6.2): a short spoken interview in the realtime voice,
// with a fixed opener, a counted turn budget, a skip tool and a typed fallback. The answers go into the memory profile
// so later turns know who they're talking to. `OnboardingMachine` holds the state; `OnboardingInterviewPerformer`
// carries out its effects against a realtime session (the app, `occtl realtime --interview` and the tests share it).

public enum OnboardingInterviewPhase: String, Codable, Sendable, Hashable {
    case notStarted
    /// Opening the realtime session.
    case preparing
    /// The voice chat is on.
    case live
    /// No voice session (it couldn't open, or dropped): OpenClicky's own questions, answered by typing.
    case scripted
    case finished
    case skipped
}

public struct OnboardingInterviewLine: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable { case user, assistant }
    public var role: Role
    public var text: String
    /// True for an answer typed instead of spoken.
    public var typed: Bool?

    public init(role: Role, text: String, typed: Bool? = nil) {
        self.role = role
        self.text = text
        self.typed = typed
    }
}

public struct OnboardingInterviewState: Codable, Sendable, Hashable {
    public var phase: OnboardingInterviewPhase = .notStarted
    /// The conversation so far, in order.
    public var lines: [OnboardingInterviewLine] = []
    /// Session openings tried for this chat (the first, then one retry).
    public var attempts = 0
    /// Why the voice chat isn't running, when it fell back to typing.
    public var failure: String?
    /// The "type instead" field is showing.
    public var typing = false
    /// The transcript and memory have been written for this chat.
    public var saved = false
    public var startedAt: Date?
    /// Answers the chat asks for, counting only the user's replies.
    public var total = OnboardingInterviewScript.answers

    public init() {}

    public var answers: [String] { lines.filter { $0.role == .user }.map(\.text) }
    /// What OpenClicky has said, in order (the questions it used).
    public var questions: [String] { lines.filter { $0.role == .assistant }.map(\.text) }
    /// A realtime session is opening or open.
    public var isRunning: Bool { phase == .preparing || phase == .live }
    public var isOver: Bool { phase == .finished || phase == .skipped }

    enum CodingKeys: String, CodingKey { case phase, lines, attempts, failure, typing, saved, startedAt, total }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(OnboardingInterviewPhase.self, forKey: .phase) ?? .notStarted
        lines = try container.decodeIfPresent([OnboardingInterviewLine].self, forKey: .lines) ?? []
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        typing = try container.decodeIfPresent(Bool.self, forKey: .typing) ?? false
        saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? OnboardingInterviewScript.answers
    }
}

/// OpenClicky's fixed lines for the welcome chat. Written fresh; only the shape (a two-part opener, a counted number
/// of questions, a fixed last question about AI agents) follows HeyClicky.
public enum OnboardingInterviewScript {
    /// Answers in one chat (HeyClicky's opener promises four quick questions).
    public static let answers = 4
    /// Session openings before falling back to typing: the first and one retry.
    public static let maxAttempts = 2

    /// The two-part opener: who OpenClicky is, then the first question. Shown as two bubbles.
    public static let opener = [
        "Hi, I'm OpenClicky. I can look at your screen with you, talk you through things and take bigger jobs off your hands.",
        "Four quick questions so I know where to start. What are you working on these days?",
    ]

    /// The note asking the model to say the opener word for word.
    public static var openerNote: String {
        "[Interview] The welcome chat starts now. Open with exactly these two sentences and nothing else, then wait for "
            + "the answer:\n" + opener.joined(separator: "\n")
    }

    /// Questions for the typed chat when there is no voice session, after the opener's first one.
    public static let typedQuestions = [
        "What does a normal working day look like for you, and which apps are open most of it?",
        "If OpenClicky could take one thing off your plate this month, what would it be?",
        "Last one: have you tried AI agents before? One that writes code, one that drives the computer, or mostly chat assistants?",
    ]

    /// The typed question after `answered` answers: the middle ones in order, and always the AI-agents one last.
    public static func question(after answered: Int, total: Int = answers) -> String {
        if answered >= total - 1 { return typedQuestions[typedQuestions.count - 1] }
        let middle = typedQuestions.dropLast()
        return middle[middle.startIndex + min(max(0, answered - 1), middle.count - 1)]
    }

    public static let typedWrapUp = "Thanks, that's a great picture of where to start. I'll keep it in mind from here on."

    /// The memory profile section the answers go in.
    public static let memorySection = "From the welcome chat"

    /// Apps OpenClicky can connect, for the chat's instructions (its own integration skills).
    public static let connectableApps = ["Gmail", "Outlook", "Google Docs", "Notion", "Linear", "GitHub", "Jira", "Dropbox"]
}

// MARK: - Transcript and memory

/// One finished (or skipped) welcome chat, as saved to `onboarding-interview.json`.
public struct OnboardingInterviewRecord: Codable, Sendable, Hashable {
    public var startedAt: Date?
    public var savedAt: Date
    public var outcome: OnboardingInterviewPhase
    public var lines: [OnboardingInterviewLine]

    public init(state: OnboardingInterviewState, savedAt: Date = Date()) {
        startedAt = state.startedAt
        self.savedAt = savedAt
        outcome = state.phase
        lines = state.lines
    }

    public var answers: [String] { lines.filter { $0.role == .user }.map(\.text) }
}

/// Where the welcome chat is kept, and how its answers reach later turns.
public enum OnboardingInterviewArchive {
    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("onboarding-interview.json")
    }

    public static func save(_ record: OnboardingInterviewRecord, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public static func load(from url: URL = defaultURL) -> OnboardingInterviewRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnboardingInterviewRecord.self, from: data)
    }

    /// The profile with the chat's answers in their own section (replacing an earlier chat's), each with the question
    /// it answered. The memory prompt shows profile sections to every later turn, which is HeyClicky's
    /// `[About the user]` note.
    public static func profile(_ profile: MemoryProfile, with record: OnboardingInterviewRecord) -> MemoryProfile {
        // Drop an earlier chat's section first.
        var lines = profile.lines
        if let old = profile.section(named: OnboardingInterviewScript.memorySection) {
            var end = old.body.upperBound
            while end > old.headingLine + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.removeSubrange(old.headingLine..<end)
            while old.headingLine < lines.count, old.headingLine > 0,
                  lines[old.headingLine].trimmingCharacters(in: .whitespaces).isEmpty,
                  lines[old.headingLine - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: old.headingLine)
            }
        }
        var updated = MemoryProfile(text: lines.joined(separator: "\n"))
        var question: String?
        for line in record.lines {
            switch line.role {
            case .assistant:
                question = line.text
            case .user:
                let answer = MemoryText.clipped(MemoryText.oneLine(line.text), to: 200)
                let asked = question.map { "Asked \u{201C}\(MemoryText.clipped(MemoryText.oneLine(lastSentence($0)), to: 80))\u{201D}: " } ?? ""
                updated.add(asked + answer, to: OnboardingInterviewScript.memorySection)
                question = nil
            }
        }
        return updated
    }

    /// Writes the answers into the store's profile. Returns how many answers went in.
    @discardableResult
    public static func writeMemory(_ record: OnboardingInterviewRecord, to store: MemoryStore) throws -> Int {
        guard !record.answers.isEmpty else { return 0 }
        let current = MemoryProfile(text: try store.profileText())
        try store.replaceProfile(with: profile(current, with: record).text)
        return record.answers.count
    }

    /// The question in a reply: its last sentence, which is where the question sits.
    static func lastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append(sentence) }
        }
        return sentences.last { $0.hasSuffix("?") } ?? sentences.last ?? trimmed
    }
}

// MARK: - The realtime session

/// One welcome chat's realtime session: an always-on controller opened with the interview instructions and the skip
/// tool, whose conversation updates become onboarding events (final user captions are answers, finished replies are
/// what OpenClicky said). It never reconnects: a dropped chat carries on typed.
public actor OnboardingInterviewSession {
    /// Builds the always-on controller for the chat from its toolbox and instructions.
    public typealias MakeController = @Sendable (_ toolbox: RealtimeToolbox, _ instructions: @escaping @Sendable () -> String) async throws
        -> AlwaysOnVoiceController

    public nonisolated let events: AsyncStream<OnboardingEvent>
    private let continuation: AsyncStream<OnboardingEvent>.Continuation
    private let makeController: MakeController
    private let connectableApps: [String]
    private let skip: @Sendable () async -> Bool
    private var controller: AlwaysOnVoiceController?
    private var relay: Task<Void, Never>?
    private var ready = false
    private var closing = false
    /// The user's words for a spoken answer whose final caption hasn't come yet.
    private var openCaption: String?
    /// The last answer reported, to tell a trailing longer transcript of it from a new answer.
    private var lastAnswer: String?
    /// Replies that finished while the answer before them was still being transcribed; they're reported after it.
    private var heldReplies: [String] = []
    private var flushTask: Task<Void, Never>?
    /// How long a reply waits for its answer's final caption before the partial one is used.
    private let captionGrace: Duration

    /// - Parameter skip: called when the model uses `skip_onboarding_interview`; returns whether a chat was running.
    public init(connectableApps: [String] = [], captionGrace: Duration = .seconds(2), skip: @escaping @Sendable () async -> Bool,
                makeController: @escaping MakeController) {
        self.captionGrace = captionGrace
        self.connectableApps = connectableApps
        self.skip = skip
        self.makeController = makeController
        (events, continuation) = AsyncStream<OnboardingEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// The chat's tools: only the skip tool. Task requests are put off by the instructions, not run.
    public static func toolbox(skip: @escaping @Sendable () async -> Bool) -> RealtimeToolbox {
        RealtimeToolbox([RealtimeTools.skipInterview(skip)])
    }

    /// Opens the session; reports `interviewReady` or `interviewPreparationFailed`.
    public func open() async {
        let instructions = RealtimeInstructions.interview(answers: OnboardingInterviewScript.answers, connectableApps: connectableApps)
        let controller: AlwaysOnVoiceController
        do {
            controller = try await makeController(Self.toolbox(skip: skip), { instructions })
        } catch {
            continuation.yield(.interviewPreparationFailed(Self.describe(error)))
            return
        }
        // Closed while the controller was being made (the step was left, or the window closed): don't start it.
        guard !closing else { return }
        self.controller = controller
        relay = Task { [weak self] in
            for await update in controller.updates { await self?.handle(update) }
        }
        let state = await controller.start()
        switch state {
        case .on:
            ready = true
            continuation.yield(.interviewReady)
        case .failed(let why), .refused(let why):
            await controller.stop()
            continuation.yield(.interviewPreparationFailed(why))
        case .off, .starting:
            continuation.yield(.interviewPreparationFailed("The voice chat didn't start."))
        }
    }

    public func send(_ text: String, respond: Bool) async {
        guard let controller else { return }
        await controller.addText(text, respond: respond)
    }

    /// Closes the session once the voice has finished what it is saying (at most `drain`), then ends `events`.
    public func close(drain: Duration = .seconds(8)) async {
        guard !closing else { return }
        closing = true
        if let conversation = await controller?.currentConversation {
            let clock = ContinuousClock()
            let deadline = clock.now + drain
            while conversation.output.isPlaying, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await controller?.stop()
        controller = nil
        relay?.cancel()
        continuation.finish()
    }

    /// Turns conversation updates into chat events, in the order they happened: providers can finish the reply to an
    /// answer before the answer's final caption arrives (Gemini settles input transcription at the end of the turn), so
    /// a reply that finishes while the user's words are still open waits for them, briefly.
    private func handle(_ update: AlwaysOnUpdate) {
        guard !closing else { return }
        switch update {
        case .conversation(.userCaption(let text, let isFinal)):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            guard isFinal else {
                openCaption = text
                return
            }
            if openCaption == nil, let last = lastAnswer {
                // No new words began: a duplicate or a longer transcript of the answer already counted.
                if text != last, text.count > last.count, text.contains(last) {
                    lastAnswer = text
                    continuation.yield(.interviewAnswerRevised(text))
                    return
                }
                if text == last { return }
            }
            answer(text)
        case .conversation(.responseFinished(let summary)):
            let text = summary.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if openCaption != nil {
                heldReplies.append(text)
                scheduleFlush()
            } else {
                continuation.yield(.interviewSaid(text))
            }
        case .conversation(.state(.userSpeaking)):
            // The user started a new turn: whatever comes next is a new answer, even if it says the same thing.
            lastAnswer = nil
        case .state(.failed(let why)), .state(.refused(let why)):
            if ready { continuation.yield(.interviewEnded(why)) }
        default:
            break
        }
    }

    private func answer(_ text: String) {
        openCaption = nil
        lastAnswer = text
        continuation.yield(.interviewAnswered(text, typed: false))
        let held = heldReplies
        heldReplies = []
        flushTask?.cancel()
        for reply in held { continuation.yield(.interviewSaid(reply)) }
    }

    /// Reports held replies after the grace period, counting the partial caption as the answer.
    private func scheduleFlush() {
        flushTask?.cancel()
        let grace = captionGrace
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.flushHeld()
        }
    }

    private func flushHeld() {
        guard !heldReplies.isEmpty, !closing else { return }
        if let partial = openCaption { answer(partial) }
    }

    static func describe(_ error: Error) -> String { String(describing: error) }
}

/// Carries out the welcome chat's effects for whoever owns the `OnboardingMachine` (the onboarding window,
/// `occtl realtime --interview`, tests): opens the session (a fresh one per attempt), sends notes, closes it, and saves
/// the transcript and the memory. Events from the session come back through `deliver`.
@MainActor
public final class OnboardingInterviewPerformer {
    public struct Storage: Sendable {
        /// Where the transcript goes; nil keeps none.
        public var transcriptURL: URL?
        /// The memory the answers are written into; nil writes none.
        public var memory: MemoryStore?

        public init(transcriptURL: URL? = OnboardingInterviewArchive.defaultURL, memory: MemoryStore? = nil) {
            self.transcriptURL = transcriptURL
            self.memory = memory
        }
    }

    /// Hands an event to the machine's owner.
    public var deliver: (OnboardingEvent) -> Void = { _ in }
    /// Whether the machine would take a skip now (`OnboardingMachine.acceptsInterviewSkip`).
    public var acceptsSkip: () -> Bool = { false }
    /// What happened, for `occtl` and logs.
    public var onLog: ((String) -> Void)?
    public private(set) var savedRecords: [OnboardingInterviewRecord] = []

    private let makeController: OnboardingInterviewSession.MakeController
    private let connectableApps: @MainActor () -> [String]
    private let storage: Storage
    private let now: @Sendable () -> Date
    private let captionGrace: Duration
    private var session: OnboardingInterviewSession?
    private var listener: Task<Void, Never>?
    private var generation = 0

    public init(storage: Storage, connectableApps: @escaping @MainActor () -> [String] = { OnboardingInterviewScript.connectableApps }, now: @escaping @Sendable () -> Date = Date.init,
                captionGrace: Duration = .seconds(2), makeController: @escaping OnboardingInterviewSession.MakeController) {
        self.storage = storage
        self.captionGrace = captionGrace
        self.connectableApps = connectableApps
        self.now = now
        self.makeController = makeController
    }

    /// Performs an interview effect; false for effects that aren't the chat's.
    @discardableResult
    public func perform(_ effect: OnboardingEffect) -> Bool {
        switch effect {
        case .openInterview(let attempt):
            open(attempt: attempt)
        case .sendInterviewText(let text, let respond):
            guard let session else { return true }
            Task { await session.send(text, respond: respond) }
        case .closeInterview:
            closeSession()
        case .saveInterview(let state):
            save(state)
        default:
            return false
        }
        return true
    }

    /// Closes any open session (the window closed).
    public func shutDown() {
        closeSession()
    }

    /// The session in use, for tests that wait on it.
    public var currentSession: OnboardingInterviewSession? { session }

    private func open(attempt: Int) {
        closeSession()
        generation += 1
        let generation = generation
        onLog?("opening the welcome chat (attempt \(attempt))")
        let skip: @Sendable () async -> Bool = { [weak self] in
            await MainActor.run {
                guard let self, self.generation == generation, self.acceptsSkip() else { return false }
                self.onLog?("skip_onboarding_interview: the model ended the chat")
                self.deliver(.skipInterview)
                return true
            }
        }
        let session = OnboardingInterviewSession(connectableApps: connectableApps(), captionGrace: captionGrace, skip: skip,
                                                 makeController: makeController)
        self.session = session
        listener = Task { [weak self] in
            for await event in session.events {
                guard let self, self.generation == generation else { return }
                self.onLog?("event: \(Self.describe(event))")
                self.deliver(event)
            }
        }
        Task { await session.open() }
    }

    private func closeSession() {
        guard let session else { return }
        self.session = nil
        generation += 1
        let listener = listener
        self.listener = nil
        Task {
            await session.close()
            listener?.cancel()
        }
    }

    private func save(_ state: OnboardingInterviewState) {
        let record = OnboardingInterviewRecord(state: state, savedAt: now())
        savedRecords.append(record)
        if let url = storage.transcriptURL {
            do { try OnboardingInterviewArchive.save(record, to: url) } catch { onLog?("transcript not saved: \(error)") }
        }
        if let memory = storage.memory {
            do {
                let count = try OnboardingInterviewArchive.writeMemory(record, to: memory)
                onLog?("wrote \(count) answer(s) to the memory profile")
            } catch {
                onLog?("memory not written: \(error)")
            }
        }
    }

    static func describe(_ event: OnboardingEvent) -> String {
        switch event {
        case .interviewReady: "session ready"
        case .interviewPreparationFailed(let why): "session failed: \(why)"
        case .interviewAnswered(let text, let typed): "answer\(typed ? " (typed)" : ""): \(text)"
        case .interviewSaid(let text): "said: \(text)"
        case .interviewEnded(let why): "session ended: \(why)"
        case .skipInterview: "skip"
        default: "\(event)"
        }
    }
}
