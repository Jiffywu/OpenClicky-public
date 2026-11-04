import Foundation

/// Strips Markdown code fences from a drawing program while it streams in, passing code through as soon as it is
/// known not to be part of a fence line.
///
/// The brain is asked for one ```js block. Lines that are fences (three or more backticks at the start of a line,
/// with an optional language tag) are dropped. Prose after a closing fence is dropped too, until another opening
/// fence. Text before the first fence is treated as code, since some models leave the fence out altogether.
public struct ProgramFenceStripper: Sendable {
    private enum Place: Sendable {
        /// No fence seen yet.
        case beforeAnyFence
        case insideFence
        case afterFence
    }

    private var place = Place.beforeAnyFence
    /// Characters of the current line held back because it might be a fence (only backticks and indentation so far).
    private var pending = ""
    /// The current line is decided: code passes through, or (outside a fence) is dropped.
    private var lineDecided = false
    /// Inside a fence line (after its backticks): drop until the newline.
    private var inFenceLine = false

    public init() {}

    /// Feed the next chunk; returns the code it completes or passes through.
    public mutating func feed(_ chunk: String) -> String {
        var out = ""
        for character in chunk { out += step(character) }
        return out
    }

    /// The stream ended: release a held-back line that never became a fence.
    public mutating func finish() -> String {
        defer { pending = ""; lineDecided = false; inFenceLine = false }
        guard !inFenceLine, !pending.isEmpty, emitsCode else { return "" }
        return pending.allSatisfy({ $0 == "`" }) && pending.count >= 3 ? "" : pending
    }

    private var emitsCode: Bool { place != .afterFence }

    private mutating func step(_ c: Character) -> String {
        if inFenceLine {
            if c == "\n" { inFenceLine = false; lineDecided = false; pending = "" }
            return ""
        }
        if lineDecided {
            if c == "\n" { lineDecided = false }
            return emitsCode ? String(c) : ""
        }
        // Undecided: the line so far is only indentation and backticks.
        if c == "\n" {
            let line = pending
            pending = ""
            return emitsCode ? line + "\n" : ""
        }
        if c == " " || c == "\t" {
            if pending.contains("`") { return decide(with: c) }
            pending.append(c)
            return ""
        }
        if c == "`" {
            pending.append(c)
            if pending.filter({ $0 == "`" }).count >= 3 {
                // A fence: an opening one moves inside, a closing one moves outside.
                place = place == .insideFence ? .afterFence : .insideFence
                inFenceLine = true
                pending = ""
            }
            return ""
        }
        return decide(with: c)
    }

    /// The held-back characters plus `c` are ordinary text.
    private mutating func decide(with c: Character) -> String {
        lineDecided = true
        let text = pending + String(c)
        pending = ""
        return emitsCode ? text : ""
    }
}

/// Finds plain sentences a model wrote into its program instead of `say()` lines (some models fall back to prose,
/// for example after a provider-hosted search). Such lines are never spoken and are syntax errors to the engine.
public enum ProgramProse {
    private static let codeStarts = ["//", "/*", "*", "const ", "let ", "var ", "function ", "for ", "for(", "if ", "if(", "else",
                                     "return", "while", "}", "{", ")", "]", "[", "say(", "step("]

    /// The lines of `program` that read as prose, not code (as `ProgramLineFilter` would drop them). Lines inside
    /// block comments, template strings and open calls, objects or arrays are not looked at.
    public static func sentences(in program: String) -> [String] {
        var filter = ProgramLineFilter()
        _ = filter.feed(program)
        _ = filter.finish()
        return filter.dropped
    }

    static func isProse(_ line: String) -> Bool {
        guard line.count >= 12, let first = line.first, first.isLetter else { return false }
        if codeStarts.contains(where: { line.hasPrefix($0) }) { return false }
        // Code has calls, assignments, blocks or statement ends; a sentence has several words and none of those.
        if line.contains(where: { "(){}=;[]`".contains($0) }) { return false }
        return line.split(separator: " ").count >= 4
    }
}

/// Holds program text line by line and drops lines that are plain sentences (`ProgramProse`), so prose never reaches
/// the drawing engine or the say-line extractor (an apostrophe in a sentence would read as an unclosed string and
/// swallow the code after it). Lines inside block comments, template strings and open brackets (the properties of a
/// call or object written over several lines, the items of an array) always pass.
public struct ProgramLineFilter: Sendable {
    private var line = ""
    private var inComment = false
    private var inTemplate = false
    /// Brackets opened and not yet closed, outside strings and comments.
    private var depth = 0
    /// Sentences dropped so far.
    public private(set) var dropped: [String] = []

    public init() {}

    /// Feed program text; returns the complete lines that pass.
    public mutating func feed(_ text: String) -> String {
        var out = ""
        for character in text {
            line.append(character)
            if character == "\n" { out += take() }
        }
        return out
    }

    /// The stream ended: the last, unterminated line.
    public mutating func finish() -> String { line.isEmpty ? "" : take() }

    private mutating func take() -> String {
        let current = line
        line = ""
        let multiline = inComment || inTemplate || depth > 0
        track(current)
        if !multiline, ProgramProse.isProse(current.trimmingCharacters(in: .whitespacesAndNewlines)) {
            dropped.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            return ""
        }
        return current
    }

    /// Follows block comments, template strings and bracket depth across lines. A quote left open at the end of a
    /// line (an apostrophe in a sentence) ends there.
    private mutating func track(_ text: String) {
        var previous: Character = " "
        var quote: Character?
        for character in text {
            if inComment {
                if previous == "*" && character == "/" { inComment = false }
            } else if inTemplate {
                if character == "`" && previous != "\\" { inTemplate = false }
            } else if let open = quote {
                if character == open && previous != "\\" { quote = nil }
            } else if previous == "/" && character == "/" {
                break
            } else if previous == "/" && character == "*" {
                inComment = true
            } else if character == "`" {
                inTemplate = true
            } else if character == "\"" || character == "'" {
                quote = character
            } else if "([{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) {
                depth = max(0, depth - 1)
            }
            previous = character
        }
    }
}
