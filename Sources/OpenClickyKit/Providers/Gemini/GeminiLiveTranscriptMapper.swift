import Foundation

/// Turns Gemini Live server messages into transcript events. Pure state, no I/O.
///
/// - `interimInputTranscription.text` is the current guess for the speech segment in progress. Google's sample
///   redraws it in place, so each one replaces the last (`.interim`).
/// - `inputTranscription.text` is settled text (`.final`); finals append. How a final relates to the one before
///   depends on the model, so the joining rule is a setting:
///   - `.segments` (the transcription model): each final is a whole speech segment with no surrounding whitespace, so
///     every final after the first carries the space that separates it from the one before, unless the boundary is
///     in a script written without spaces (Chinese, Japanese, Thai, ...) or the segment opens with closing
///     punctuation. A segment final also marks the end of an utterance ("emitted when the speaker pauses").
///   - `.fragments` (Live agent models): finals arrive as chunks of one running transcript that carry their own
///     spacing (`"Hel"`, `"lo"`, `" there"`), so they are appended exactly as sent. Only leading whitespace on the
///     very first chunk is dropped.
/// - An interim that follows final text carries the same separator its final would, so `transcript + interim` reads
///   right on screen. A final replaces the interim it settles; a final that settles to nothing clears the interim
///   with an empty `.interim("")`.
/// - `.speechStarted` comes at the first sign of speech in an utterance: a `voiceActivity` ACTIVITY_START, or the
///   first interim or final text. `.utteranceEnd` comes on a segment final, an ACTIVITY_END or a `turnComplete`, but
///   never while an interim is still waiting to be settled; then it follows the final that settles it.
/// - `<speaker …>` tags are dropped from transcription text.
struct GeminiLiveTranscriptMapper: Sendable {
    enum Joining: Sendable, Equatable { case segments, fragments }

    let joining: Joining
    /// Every final so far, joined: the transcript.
    private(set) var transcript = ""
    /// The interim currently shown, as reported (separator included); empty when none.
    private var shownInterim = ""
    /// Speech has started and its utterance has not been reported as ended.
    private var inUtterance = false
    /// An utterance end arrived while an interim was still unsettled.
    private var endDeferred = false
    /// A whitespace-only fragment arrived; the next fragment gets one space in front.
    private var carrySpace = false
    /// Any interim or final text has arrived.
    private(set) var heardText = false

    init(joining: Joining) { self.joining = joining }

    /// An interim is on screen that no final has settled yet.
    var hasPendingInterim: Bool { !shownInterim.isEmpty }

    mutating func map(_ message: JSONValue) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        switch message["voiceActivity"]?["type"]?.stringValue {
        case "ACTIVITY_START"?:
            if !inUtterance {
                inUtterance = true
                events.append(.speechStarted)
            }
        case "ACTIVITY_END"?:
            events += boundary()
        default:
            break
        }
        guard let content = message["serverContent"] else { return events }
        // A final settles the segment it belongs to; an interim in the same message is about the next one.
        if let text = content["inputTranscription"]?["text"]?.stringValue { events += final(text) }
        if let text = content["interimInputTranscription"]?["text"]?.stringValue { events += interim(text) }
        if content["turnComplete"]?.boolValue == true { events += boundary() }
        return events
    }

    /// Settles the interim on screen as final text: for when the session has to end before Gemini settles it.
    mutating func promotePendingInterim() -> [TranscriptEvent] {
        guard !shownInterim.isEmpty else { return [] }
        let text = shownInterim
        shownInterim = ""
        transcript += text
        var events: [TranscriptEvent] = [.final(text)]
        if inUtterance {
            inUtterance = false
            endDeferred = false
            events.append(.utteranceEnd)
        }
        return events
    }

    // MARK: - Pieces

    private mutating func interim(_ raw: String) -> [TranscriptEvent] {
        let text = Self.stripSpeakerTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = text.isEmpty ? "" : separator(before: text) + text
        guard shown != shownInterim else { return [] }
        var events: [TranscriptEvent] = []
        if !shown.isEmpty { events += speechBegan() }
        shownInterim = shown
        events.append(.interim(shown))
        return events
    }

    private mutating func final(_ raw: String) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        let piece: String
        switch joining {
        case .segments:
            let text = Self.stripSpeakerTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            piece = text.isEmpty ? "" : separator(before: text) + text
        case .fragments:
            var text = Self.stripSpeakerTags(raw)
            if text.allSatisfy(\.isWhitespace) {
                if !text.isEmpty, !transcript.isEmpty { carrySpace = true }
                text = ""
            } else {
                if transcript.isEmpty { text = String(text.drop(while: \.isWhitespace)) }
                if carrySpace, let first = text.first, !first.isWhitespace { text = " " + text }
                carrySpace = false
            }
            piece = text
        }

        if piece.isEmpty {
            // Settled to nothing: clear whatever guess is on screen.
            if !shownInterim.isEmpty {
                shownInterim = ""
                events.append(.interim(""))
            }
        } else {
            events += speechBegan()
            shownInterim = ""
            transcript += piece
            events.append(.final(piece))
        }
        if joining == .segments, !piece.isEmpty {
            events += boundary()
        } else if endDeferred, shownInterim.isEmpty {
            events += boundary()
        }
        return events
    }

    private mutating func speechBegan() -> [TranscriptEvent] {
        heardText = true
        guard !inUtterance else { return [] }
        inUtterance = true
        return [.speechStarted]
    }

    /// The utterance ended, unless an unsettled interim says otherwise; then it ends after that interim's final.
    private mutating func boundary() -> [TranscriptEvent] {
        guard inUtterance else { return [] }
        guard shownInterim.isEmpty else {
            endDeferred = true
            return []
        }
        inUtterance = false
        endDeferred = false
        return [.utteranceEnd]
    }

    // MARK: - Text

    /// A space before trimmed text (a segment final, or any interim) that follows earlier final text, except where
    /// none belongs.
    private func separator(before next: String) -> String {
        guard let previous = transcript.last, let first = next.first else { return "" }
        if previous.isWhitespace || first.isWhitespace { return "" }
        if Self.closingPunctuation.contains(first) { return "" }
        if Self.writtenWithoutSpaces(previous) || Self.writtenWithoutSpaces(first) { return "" }
        return " "
    }

    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "…", "%", "”",
        "。", "，", "、", "！", "？", "；", "：", "）", "」", "』", "】",
    ]

    /// Characters of scripts that do not separate words with spaces: CJK ideographs and punctuation, kana,
    /// fullwidth forms, Thai, Lao, Khmer and Myanmar.
    static func writtenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0EFF,  // Thai, Lao
             0x1000...0x109F,  // Myanmar
             0x1780...0x17FF,  // Khmer
             0x2E80...0x2FDF,  // CJK radicals
             0x3000...0x30FF,  // CJK symbols and punctuation, Hiragana, Katakana
             0x3100...0x31FF,  // Bopomofo, Katakana extensions
             0x3400...0x4DBF,  // CJK extension A
             0x4E00...0x9FFF,  // CJK unified ideographs
             0xF900...0xFAFF,  // CJK compatibility ideographs
             0xFF00...0xFFEF,  // Halfwidth and fullwidth forms
             0x20000...0x3134F:  // CJK extensions B and later
            return true
        default:
            return false
        }
    }

    /// Removes `<speaker…>` and `</speaker>` tags.
    static func stripSpeakerTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            let afterOpen = rest[rest.index(after: open)...]
            let name = afterOpen.hasPrefix("/") ? afterOpen.dropFirst() : afterOpen
            if name.lowercased().hasPrefix("speaker"), let close = afterOpen.firstIndex(of: ">") {
                result += rest[..<open]
                rest = rest[rest.index(after: close)...]
            } else {
                result += rest[...open]
                rest = afterOpen
            }
        }
        result += rest
        return result
    }
}
