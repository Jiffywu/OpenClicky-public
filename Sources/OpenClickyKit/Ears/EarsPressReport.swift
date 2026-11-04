import Foundation

/// What happened to one press's listening, and when (HeyClicky logs one such line per press: warm socket or not, the
/// outcome, how long the key was held, key-down to token / ready / first text, finish to final, release to words).
public struct EarsPressReport: Sendable, Hashable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// The stt slot's stream heard the press.
        case streamed
        /// The stt slot refused for billing or quota a little earlier, so the alternate recognizer heard it.
        case switched
        /// The stream failed (or never settled); the press's audio was transcribed again in one pass.
        case fallback
        /// The stream failed and so did every fallback; the words the stream had by then are used.
        case partial
        /// Nothing was said (or nothing was heard).
        case silent
        /// No words: the stream and every fallback failed.
        case failed
        /// The press was dropped (a tap, Escape, a new press).
        case cancelled
    }

    /// The recognizer the press streamed to ("gemini-live / gemini-3.5-transcribe-live"), or "batch only".
    public var recognizer: String
    /// The press took a connection opened before key-down.
    public var warm = false
    public var outcome: Outcome = .cancelled
    /// Key-down: the ears' session started.
    public var startedAt: Date
    /// The stream's session opened (the socket connected, or the recognizer started).
    public var connectedAt: Date?
    /// The provider accepted audio (Gemini's `setupComplete`); the same as `connectedAt` for adapters that don't say.
    public var readyAt: Date?
    public var firstTextAt: Date?
    /// Key-up reached the ears (the last audio was handed over).
    public var finishAt: Date?
    /// The words were settled (streamed final, fallback text, or the decision that there were none).
    public var finalAt: Date?
    /// Seconds of audio kept from the press.
    public var audioSeconds = 0.0
    /// The fallback that heard the press, when one did.
    public var fallback: String?
    public var fallbackMs: Int?
    /// Why the stream didn't deliver, when it didn't.
    public var streamError: String?
    /// This press found the stt account refusing (billing, quota) and switched the ears to the alternate for a while.
    public var startedRefusalSwitch = false

    public init(recognizer: String, startedAt: Date) {
        self.recognizer = recognizer
        self.startedAt = startedAt
    }

    static func ms(_ from: Date?, _ to: Date?) -> Int? {
        guard let from, let to else { return nil }
        return Int((to.timeIntervalSince(from) * 1000).rounded())
    }

    public var keyDownToConnectedMs: Int? { Self.ms(startedAt, connectedAt) }
    public var keyDownToReadyMs: Int? { Self.ms(startedAt, readyAt) }
    public var keyDownToFirstTextMs: Int? { Self.ms(startedAt, firstTextAt) }
    public var finishToFinalMs: Int? { Self.ms(finishAt, finalAt) }

    /// One line for logs: `ears: warm=yes outcome=streamed …_ms=…` (missing steps are left out).
    public func logLine(heldMs: Int? = nil, releaseToWordsMs: Int? = nil) -> String {
        var parts = ["warm=\(warm ? "yes" : "no")", "outcome=\(outcome.rawValue)", "stt=\"\(recognizer)\""]
        let marks: [(String, Int?)] = [("held_ms", heldMs), ("keydown_to_connected_ms", keyDownToConnectedMs),
                                       ("keydown_to_ready_ms", keyDownToReadyMs), ("keydown_to_first_text_ms", keyDownToFirstTextMs),
                                       ("finish_to_final_ms", finishToFinalMs), ("release_to_words_ms", releaseToWordsMs),
                                       ("fallback_ms", fallbackMs)]
        for (name, value) in marks { if let value { parts.append("\(name)=\(value)") } }
        parts.append(String(format: "audio_s=%.2f", audioSeconds))
        if let fallback { parts.append("fallback=\"\(fallback)\"") }
        if startedRefusalSwitch { parts.append("switched_for_refusal=yes") }
        if let streamError { parts.append("stream_error=\"\(streamError.prefix(160))\"") }
        return "ears: " + parts.joined(separator: " ")
    }

    public func json(releaseToWordsMs: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["recognizer": .string(recognizer), "warm": .bool(warm), "outcome": .string(outcome.rawValue),
                                           "audio_s": .number((audioSeconds * 100).rounded() / 100)]
        let marks: [(String, Int?)] = [("keydown_to_connected_ms", keyDownToConnectedMs), ("keydown_to_ready_ms", keyDownToReadyMs),
                                       ("keydown_to_first_text_ms", keyDownToFirstTextMs), ("finish_to_final_ms", finishToFinalMs),
                                       ("release_to_words_ms", releaseToWordsMs), ("fallback_ms", fallbackMs)]
        for (name, value) in marks { if let value { object[name] = .number(Double(value)) } }
        if let fallback { object["fallback"] = .string(fallback) }
        if let streamError { object["stream_error"] = .string(streamError) }
        if startedRefusalSwitch { object["switched_for_refusal"] = true }
        return .object(object)
    }
}

/// A speech session that can report its press (`VoiceEars`' sessions do). The turn orchestrator adds the report to
/// the turn's timings.
public protocol EarsPressReporting: Sendable {
    /// The press so far (complete once the session's events have ended).
    func pressReport() async -> EarsPressReport
}
