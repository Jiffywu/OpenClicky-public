import Foundation

/// Turns Deepgram `/v1/listen` server messages into transcript events. Pure state, no I/O.
///
/// - `Results` with `is_final: false` is an interim for the words since the last final; `is_final: true` settles them.
///   The reference describes `speech_final: true` results as finalized, but the endpointing doc's sample shows
///   `speech_final: true` with `is_final: false`. Both are documented, so either flag settles the text.
///   The endpointing doc's sample also omits `type`, so an untyped message with `channel.alternatives` counts as Results.
/// - Finals concatenate into the transcript ("finals append"). Deepgram segments have no surrounding whitespace, so every
///   final after the first carries the leading space that separates it from the one before, and so does an interim
///   that follows a final. A final replaces the interim it settles; if Deepgram settles to an empty transcript after
///   showing an interim, an empty interim clears it.
/// - End of utterance follows Deepgram's documented rule (understanding-end-of-speech-detection): report it on a
///   `speech_final: true` result, and on an `UtteranceEnd` message only when no `speech_final` already ended that
///   speech. `UtteranceEnd` with `last_word_end: -1` means the speech was already finalized; the docs say to ignore it.
struct DeepgramTranscriptMapper: Sendable {
    /// Some final text has been reported, so later text needs a separating space.
    private var hasFinalText = false
    /// The interim currently on screen, as reported.
    private var shownInterim = ""
    /// Words were heard since the last reported end of utterance.
    private var speechPending = false

    mutating func map(_ message: JSONValue) -> [TranscriptEvent] {
        switch message["type"]?.stringValue {
        case "Results": return results(message)
        case nil where message["channel"]?["alternatives"] != nil: return results(message)
        case "SpeechStarted": return [.speechStarted]
        case "UtteranceEnd": return utteranceEnd(message)
        default: return []
        }
    }

    private mutating func results(_ message: JSONValue) -> [TranscriptEvent] {
        let transcript = message["channel"]?["alternatives"]?.arrayValue?.first?["transcript"]?.stringValue ?? ""
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFinal = message["is_final"]?.boolValue ?? false
        let speechFinal = message["speech_final"]?.boolValue ?? false
        let separated = (hasFinalText && !text.isEmpty) ? " " + text : text

        var events: [TranscriptEvent] = []
        if isFinal || speechFinal {
            if !text.isEmpty {
                events.append(.final(separated))
                hasFinalText = true
                speechPending = true
            } else if !shownInterim.isEmpty {
                events.append(.interim(""))
            }
            shownInterim = ""
        } else if separated != shownInterim {
            events.append(.interim(separated))
            shownInterim = separated
            if !text.isEmpty { speechPending = true }
        }
        if speechFinal && speechPending {
            events.append(.utteranceEnd)
            speechPending = false
        }
        return events
    }

    private mutating func utteranceEnd(_ message: JSONValue) -> [TranscriptEvent] {
        if let lastWordEnd = message["last_word_end"]?.doubleValue, lastWordEnd < 0 { return [] }
        guard speechPending else { return [] }
        speechPending = false
        return [.utteranceEnd]
    }
}
