import Foundation

/// Pulls spoken lines out of a drawing program while it is still streaming in.
///
/// The brain answers with a small JavaScript program (drawing calls plus `say("…")` lines). The voice must start
/// speaking the first line long before the program is complete, so this scans the text incrementally and emits
/// each `say(<string literal>…)` argument as soon as its closing quote arrives. It understands JS string literals
/// ("…", '…', and backtick strings without `${}`), escapes, and skips `say` inside comments, other strings, and
/// member calls like `obj.say(`. Code fences around the program are ignored.
public struct SayLineExtractor: Sendable {
    public struct Line: Sendable, Hashable {
        /// 0-based order of the line in the program.
        public var index: Int
        /// The text to speak, with links and URLs removed.
        public var text: String
        /// The line exactly as written in the program (decoded escapes, links kept).
        public var raw: String
    }

    private enum Mode: Sendable {
        case code
        /// One or two backticks at the start of a line: a ``` fence or a template string.
        case maybeFence(count: Int)
        /// The rest of a ``` fence line.
        case fenceLine
        case lineComment
        case blockComment
        /// Inside a string that is not a say() argument.
        case otherString(quote: Character, escaped: Bool)
        /// Saw `say`, now expecting whitespace then `(`.
        case afterSay
        /// Saw `say(`, expecting whitespace then a string literal.
        case afterParen
        /// Inside the say() string literal.
        case sayString(quote: Character, buffer: String, escaped: Bool, unicode: String?)
    }

    private var mode: Mode = .code
    /// Only whitespace since the last newline (in code).
    private var atLineStart = true
    /// The last few code characters, to tell `say(` from `obj.say(` / `essay(` and to spot comment starts.
    private var recent: [Character] = []
    private var emitted = 0

    public init() {}

    /// Feed the next chunk of program text; returns lines completed by this chunk.
    public mutating func feed(_ chunk: String) -> [Line] {
        var lines: [Line] = []
        for character in chunk {
            if let line = step(character) { lines.append(line) }
        }
        return lines
    }

    /// Lines spoken so far.
    public var count: Int { emitted }

    private mutating func step(_ c: Character) -> Line? {
        switch mode {
        case .code:
            if atLineStart && c == "`" { mode = .maybeFence(count: 1); return nil }
            if c == "\n" { atLineStart = true } else if !c.isWhitespace { atLineStart = false }
            let previous = recent.last
            remember(c)
            if previous == "/" && c == "/" { mode = .lineComment; return nil }
            if previous == "/" && c == "*" { mode = .blockComment; return nil }
            if c == "\"" || c == "'" || c == "`" { mode = .otherString(quote: c, escaped: false); return nil }
            if c == "y", endsWithSayToken() { mode = .afterSay }
            return nil

        case .maybeFence(let count):
            if c == "`" {
                if count == 2 { mode = .fenceLine } else { mode = .maybeFence(count: count + 1) }
                return nil
            }
            atLineStart = false
            if count == 1 {
                // A template string that happens to start a line.
                mode = .otherString(quote: "`", escaped: false)
                return step(c)
            }
            mode = .code // an empty template literal
            return step(c)

        case .fenceLine:
            if c == "\n" { mode = .code; atLineStart = true; recent.removeAll() }
            return nil

        case .lineComment:
            if c == "\n" { mode = .code; atLineStart = true; recent.removeAll() }
            return nil

        case .blockComment:
            if recent.last == "*" && c == "/" { mode = .code; recent.removeAll() } else { remember(c) }
            return nil

        case .otherString(let quote, let escaped):
            if escaped { mode = .otherString(quote: quote, escaped: false) }
            else if c == "\\" { mode = .otherString(quote: quote, escaped: true) }
            else if c == quote { mode = .code; recent.removeAll() }
            return nil

        case .afterSay:
            if c.isWhitespace { return nil }
            if c == "(" { mode = .afterParen } else { mode = .code; return step(c) }
            return nil

        case .afterParen:
            if c.isWhitespace { return nil }
            if c == "\"" || c == "'" || c == "`" {
                mode = .sayString(quote: c, buffer: "", escaped: false, unicode: nil)
            } else {
                // say(variable) or say(`…${x}`): not a literal line we can speak ahead of time.
                mode = .code
                recent.removeAll()
                return step(c)
            }
            return nil

        case .sayString(let quote, var buffer, let escaped, let unicode):
            if var hex = unicode {
                if hex.isEmpty && c == "{" { mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: "{"); return nil }
                let braced = hex.hasPrefix("{")
                if braced && c == "}" {
                    buffer.append(Self.scalar(String(hex.dropFirst())))
                    mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: nil)
                    return nil
                }
                hex.append(c)
                if !braced && hex.count == 4 {
                    buffer.append(Self.scalar(hex))
                    mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: nil)
                } else {
                    mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: hex)
                }
                return nil
            }
            if escaped {
                switch c {
                case "n": buffer.append("\n")
                case "t": buffer.append("\t")
                case "r": break
                case "u":
                    mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: "")
                    return nil
                case "\n": break // line continuation
                default: buffer.append(c)
                }
                mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: nil)
                return nil
            }
            if c == "\\" { mode = .sayString(quote: quote, buffer: buffer, escaped: true, unicode: nil); return nil }
            if quote == "`" && c == "{" && buffer.last == "$" {
                // A template with interpolation: its text isn't known yet. Treat the rest as an ordinary string.
                mode = .otherString(quote: "`", escaped: false)
                return nil
            }
            if c == quote {
                mode = .code
                recent.removeAll()
                let raw = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return nil }
                defer { emitted += 1 }
                return Line(index: emitted, text: Self.speakable(raw), raw: raw)
            }
            buffer.append(c)
            mode = .sayString(quote: quote, buffer: buffer, escaped: false, unicode: nil)
            return nil
        }
    }

    private mutating func remember(_ c: Character) {
        recent.append(c)
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
    }

    /// True when the code just written ends with a standalone `say` identifier.
    private func endsWithSayToken() -> Bool {
        guard recent.count >= 3, String(recent.suffix(3)) == "say" else { return false }
        guard recent.count >= 4 else { return true }
        let before = recent[recent.count - 4]
        return !(before.isLetter || before.isNumber || before == "_" || before == "$" || before == ".")
    }

    private static func scalar(_ hex: String) -> String {
        guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }

    // MARK: Speakable text

    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\((?:[^)\s]+)\)"#)
    private static let bareURL = try! NSRegularExpression(pattern: #"\b(?:https?://|www\.)[^\s)>\]]*[^\s)>\].,;:!?'"]"#, options: [.caseInsensitive])
    private static let spaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)

    /// What the voice should actually say: markdown links become their label, bare URLs are dropped (nobody wants
    /// a URL read aloud), and leftover double spaces collapse.
    public static func speakable(_ text: String) -> String {
        var result = text
        result = markdownLink.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        result = bareURL.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        result = spaces.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        result = result.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
