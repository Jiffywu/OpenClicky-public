import Foundation

// Value types the turn orchestrator publishes: where a turn is, what the notch and captions show, how long each step
// took, and what happened to the narration. See docs/turn-contract.md and docs/voice-loop.md.

/// Where the current turn is. A voice turn goes idle → listening → transcribing → capturing → requesting →
/// speaking (or drawing, when nothing is read aloud) → idle; typed, report and guided turns start at capturing.
public enum TurnPhase: String, Sendable, Hashable, Codable {
    case idle
    /// The talk keys are held; the mic is open.
    case listening
    /// The keys were let go; waiting for the final transcript.
    case transcribing
    /// Taking the screenshots and the context.
    case capturing
    /// The brain is working on the answer (before anything is heard).
    case requesting
    /// Lines are being spoken (and the drawing follows them).
    case speaking
    /// The answer is drawing without a voice (a typed turn whose answer isn't read aloud).
    case drawing

    public var isBusy: Bool { self != .idle }
}

/// How a turn started.
public enum TurnKind: String, Sendable, Hashable, Codable {
    /// Hold the talk keys and speak.
    case voice
    /// Typed into the text panel.
    case typed
    /// Background jobs came back; the brain tells the user (no words from the user).
    case report
    /// A guided walkthrough's next step: the user clicked the ringed control (`clicked_target`) or did a manual step
    /// (`did_step`), and the app asks for the next one by itself (docs/guided.md).
    case guided
}

/// A short message for the notch (and sometimes for the voice): nothing heard, connection dropped, a failure.
public struct TurnNotice: Sendable, Hashable {
    public enum Tone: String, Sendable, Hashable { case info, warning, error }

    public var tone: Tone
    public var title: String
    public var detail: String?

    public init(_ tone: Tone, _ title: String, detail: String? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
    }

    /// The press ended without any words heard.
    public static let nothingHeard = TurnNotice(.info, "I didn't hear anything that time.",
                                                detail: "Keep holding the keys while you speak, and let go when you're done.")

    /// Speech recognition failed during the press.
    public static func connectionDropped(_ detail: String? = nil) -> TurnNotice {
        TurnNotice(.warning, "I lost the speech connection, so I couldn't hear that.",
                   detail: detail ?? "Try again, or type your question instead.")
    }

    public static func microphoneUnavailable(_ detail: String) -> TurnNotice {
        TurnNotice(.warning, "I couldn't open the microphone.", detail: detail)
    }

    public static func listeningNotSetUp(_ detail: String) -> TurnNotice {
        TurnNotice(.warning, "Listening isn't set up yet.", detail: detail)
    }
}

/// Everything the notch, the cursor bubble and the captions show for the current turn.
public struct TurnDisplay: Sendable, Hashable {
    public var phase: TurnPhase = .idle
    public var kind: TurnKind?
    /// What the user is saying, live (finals plus the latest interim).
    public var liveTranscript = ""
    /// The words the turn was asked with (the final transcript or the typed text).
    public var words: String?
    /// The line being spoken right now and its number.
    public var caption: String?
    public var captionIndex: Int?
    /// The answer's lines so far, in order (the typed panel shows them).
    public var lines: [String] = []
    /// "Searching the web…" while tools run.
    public var status: String?
    public var notice: TurnNotice?
    /// True while the voice slot is down and the Apple voice speaks instead.
    public var usingFallbackVoice = false

    public init() {}
}

/// Per-turn timing marks. Voice turns start at key-up (`released`); typed and report turns when they are sent.
public struct TurnTimings: Sendable, Hashable {
    public var kind: TurnKind
    /// When a typed or report turn was sent.
    public var sentAt: Date?
    public var pressedAt: Date?
    public var releasedAt: Date?
    public var transcriptAt: Date?
    public var captureStartedAt: Date?
    public var captureFinishedAt: Date?
    public var requestStartedAt: Date?
    /// First program text or line from the brain.
    public var firstTokenAt: Date?
    /// The brain's first complete `say` line.
    public var firstLineAt: Date?
    /// The voice delivered the first audio of the first line.
    public var firstAudioAt: Date?
    /// The first line started reaching the listener.
    public var firstLineHeardAt: Date?
    public var brainFinishedAt: Date?
    public var narrationFinishedAt: Date?
    public var finishedAt: Date?
    /// Time to first program text the brain reported for itself (its own clock).
    public var modelFirstTokenSeconds: Double?
    public var model: String?
    /// How the press was heard, when the ears (`VoiceEars`) listened: warm or not, outcome, and their own steps.
    public var ears: EarsPressReport?
    /// The brain's tokens for the turn (all rounds): whether the prompt cache was hit, and how much was written.
    public var usage: TokenUsage?
    /// About how big the brain's first request body was (text, tool definitions, base64 screenshots), in bytes.
    public var requestBodyBytes: Int?

    public init(kind: TurnKind) { self.kind = kind }

    static func ms(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to else { return nil }
        return Int((to.timeIntervalSince(from) * 1000).rounded())
    }

    /// Where the clock starts: key-up for voice turns, sending for the others.
    public var origin: Date? { releasedAt ?? sentAt }

    public var heldMs: Int? { Self.ms(pressedAt, releasedAt) }
    public var releaseToTranscriptMs: Int? { Self.ms(releasedAt, transcriptAt) }
    public var captureMs: Int? { Self.ms(captureStartedAt, captureFinishedAt) }
    public var transcriptToRequestMs: Int? { Self.ms(transcriptAt ?? captureStartedAt, requestStartedAt) }
    public var requestToFirstTokenMs: Int? { Self.ms(requestStartedAt, firstTokenAt) }
    public var firstTokenToFirstLineMs: Int? { Self.ms(firstTokenAt, firstLineAt) }
    public var firstLineToFirstAudioMs: Int? { Self.ms(firstLineAt, firstAudioAt) }
    public var firstAudioToHeardMs: Int? { Self.ms(firstAudioAt, firstLineHeardAt) }
    public var originToFirstLineHeardMs: Int? { Self.ms(origin, firstLineHeardAt) }
    public var originToBrainFinishedMs: Int? { Self.ms(origin, brainFinishedAt) }
    public var totalMs: Int? { Self.ms(origin, finishedAt) }
    /// Key-up to the settled words, as the ears saw them.
    public var releaseToWordsMs: Int? { Self.ms(releasedAt, ears?.finalAt) }

    /// The steps as (label, milliseconds) in turn order; missing steps are left out.
    public var steps: [(String, Int)] {
        let all: [(String, Int?)] = [
            ("held", heldMs),
            ("release → transcript", releaseToTranscriptMs),
            ("screen capture", captureMs),
            ("transcript → request", transcriptToRequestMs),
            ("request → first token", requestToFirstTokenMs),
            ("first token → first line", firstTokenToFirstLineMs),
            ("first line → first audio", firstLineToFirstAudioMs),
            ("first audio → heard", firstAudioToHeardMs),
            (kind == .voice ? "release → first line heard" : "sent → first line heard", originToFirstLineHeardMs),
            ("brain finished", originToBrainFinishedMs),
            ("total", totalMs),
        ]
        return all.compactMap { label, value in value.map { (label, $0) } }
    }

    /// A small table for logs, `occtl turn` and the stats HUD.
    public func report() -> String {
        var lines = ["\(kind.rawValue) turn" + (model.map { " on \($0)" } ?? "")]
        for (label, ms) in steps { lines.append("  " + label.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: "%6d ms", ms)) }
        if let seconds = modelFirstTokenSeconds { lines.append(String(format: "  (the brain's own first-token time: %.0f ms)", seconds * 1000)) }
        if let usage {
            let cache = usage.cachedInputTokens > 0 ? "hit" : "miss"
            lines.append("  tokens: in \(usage.inputTokens) (cache \(cache): \(usage.cachedInputTokens) read, \(usage.cacheWriteTokens) written), "
                         + "out \(usage.outputTokens)")
        }
        if let ears { lines.append("  " + ears.logLine(heldMs: heldMs, releaseToWordsMs: releaseToWordsMs)) }
        if let requestBodyBytes { lines.append("  request body: about \(Self.kilobytes(requestBodyBytes))") }
        return lines.joined(separator: "\n")
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let model { object["model"] = .string(model) }
        let keys: [(String, Int?)] = [
            ("held_ms", heldMs), ("release_to_transcript_ms", releaseToTranscriptMs), ("capture_ms", captureMs),
            ("transcript_to_request_ms", transcriptToRequestMs), ("request_to_first_token_ms", requestToFirstTokenMs),
            ("first_token_to_first_line_ms", firstTokenToFirstLineMs), ("first_line_to_first_audio_ms", firstLineToFirstAudioMs),
            ("first_audio_to_heard_ms", firstAudioToHeardMs), ("origin_to_first_line_heard_ms", originToFirstLineHeardMs),
            ("origin_to_brain_finished_ms", originToBrainFinishedMs), ("total_ms", totalMs),
        ]
        for (key, value) in keys { if let value { object[key] = .number(Double(value)) } }
        if let seconds = modelFirstTokenSeconds { object["model_first_token_ms"] = .number((seconds * 1000).rounded()) }
        if let ears { object["ears"] = ears.json(releaseToWordsMs: releaseToWordsMs) }
        if let requestBodyBytes { object["request_body_bytes"] = .number(Double(requestBodyBytes)) }
        if let usage {
            object["usage"] = ["input": .number(Double(usage.inputTokens)), "cached": .number(Double(usage.cachedInputTokens)),
                               "cache_write": .number(Double(usage.cacheWriteTokens)), "output": .number(Double(usage.outputTokens))]
        }
        return .object(object)
    }
}

/// What happened to a turn's narration, reported to the brain as an `[App]` note when it wasn't heard in full.
public enum NarrationOutcome: Sendable, Hashable {
    /// Every line was heard.
    case completed
    /// The user cut the answer off (a new press, Escape or a typed question). `heard` lines finished; `cutLine` was
    /// playing when it stopped.
    case cutOff(by: Interruption, heard: Int, cutLine: Int?, total: Int)
    /// The turn was dropped before anything was said.
    case droppedBeforeFirstLine(Interruption)
    /// The brain failed; its spoken sentence was said instead.
    case failed(String)
    /// Nothing reached the brain (nothing heard, no microphone…).
    case notStarted

    public enum Interruption: String, Sendable, Hashable {
        case newPress = "pressed the talk keys again"
        case escape = "pressed Escape"
        case typed = "typed a new question"
        case appTurn = "started something else"
        /// The user did the walkthrough's step (clicked the target) while the answer was still being prepared or said.
        case steppedAhead = "went ahead with the step"
        /// The user stopped the walkthrough (the menu's Stop walkthrough) while its next step was being prepared or said.
        case stoppedWalkthrough = "stopped the walkthrough"
    }

    /// The `[App]` note for the next turn, or nil when there is nothing worth telling the brain.
    public func note(lines: [String]) -> String? {
        func quoted(_ text: String) -> String { "\"\(text)\"" }
        switch self {
        case .completed, .notStarted, .failed:
            return nil
        case .droppedBeforeFirstLine(let by):
            return "[App] The user \(by.rawValue) before your last answer started, so none of it was heard."
        case .cutOff(let by, let heard, let cutLine, let total):
            var note = "[App] The user \(by.rawValue) and cut your last answer off"
            let count = max(total, lines.count)
            if let cutLine, cutLine < lines.count {
                note += " during line \(cutLine + 1) of \(count) (\(quoted(lines[cutLine])))."
            } else {
                note += " after \(heard) of \(count) line\(count == 1 ? "" : "s")."
            }
            let firstUnheard = cutLine.map { $0 + 1 } ?? heard
            let unheard = firstUnheard < lines.count ? Array(lines[firstUnheard...]) : []
            if !unheard.isEmpty {
                note += " Not heard: " + unheard.prefix(3).map(quoted).joined(separator: " ") + (unheard.count > 3 ? " …" : "")
            }
            note += " Don't repeat what they already heard unless they ask."
            return note
        }
    }

    public var label: String {
        switch self {
        case .completed: "completed"
        case .cutOff(let by, _, _, _): "cut off (\(by.rawValue))"
        case .droppedBeforeFirstLine(let by): "dropped before the first line (\(by.rawValue))"
        case .failed: "failed"
        case .notStarted: "not started"
        }
    }
}

/// An action the brain deferred and what came of it.
public struct DeferredActionResult: Sendable, Hashable {
    public var action: DeferredAction
    /// False when it failed; nil when it was dropped (a new turn started first).
    public var succeeded: Bool?

    public init(action: DeferredAction, succeeded: Bool?) {
        self.action = action
        self.succeeded = succeeded
    }
}

/// One finished turn, for the history, logs and `occtl turn`.
public struct TurnRecord: Sendable {
    public var kind: TurnKind
    public var words: String
    /// The history entry, when the turn reached the brain.
    public var history: HistoryTurn?
    public var timings: TurnTimings
    public var narration: NarrationReport?
    public var outcome: NarrationOutcome
    public var deferred: [DeferredActionResult]
    public var notice: TurnNotice?
    /// The brain's failure, if any: what was said and the detail for logs.
    public var failure: (spoken: String, detail: String)?
    /// The answer wasn't spoken because the output was muted or at zero (the app copies it and offers the fix).
    public var unheardReply: UnheardReply?
    /// The drawing's screenshot and line times, when the turn drew (saved as a lesson when `drawing.saves-lessons` is on).
    public var lesson: DrawingLessonDraft?

    public init(kind: TurnKind, words: String, history: HistoryTurn? = nil, timings: TurnTimings, narration: NarrationReport? = nil,
                outcome: NarrationOutcome, deferred: [DeferredActionResult] = [], notice: TurnNotice? = nil,
                failure: (spoken: String, detail: String)? = nil, unheardReply: UnheardReply? = nil) {
        self.kind = kind
        self.words = words
        self.history = history
        self.timings = timings
        self.narration = narration
        self.outcome = outcome
        self.deferred = deferred
        self.notice = notice
        self.failure = failure
        self.unheardReply = unheardReply
    }
}
