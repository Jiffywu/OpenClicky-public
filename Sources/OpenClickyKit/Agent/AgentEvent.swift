import Foundation

/// One step of a plan the agent keeps while it works.
public struct AgentPlanStep: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", completed }
    public var step: String
    public var status: Status

    public init(step: String, status: Status) {
        self.step = step
        self.status = status
    }
}

/// Something the agent needs the user to decide before it can continue.
public struct AgentApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Run a shell command outside what the harness allows by itself.
        case command
        /// Change files outside the job folder.
        case fileChange = "file-change"
        /// Use a tool (Claude Code permission prompt).
        case tool
        /// Extra sandbox permissions (network, folders).
        case permissions
        /// A question the agent asked; answered with text.
        case question
        /// The job needs the user's Chrome connected (raised by OpenClicky when a job calls the browser and none is
        /// connected). Approve opens Settings → Browser; the job hears back once Chrome connects, or that the user
        /// declined.
        case chromeSetup = "chrome_setup"
        /// A browser change that requires a decision from the app's user controls.
        case browserAction = "browser_action"
    }

    /// Opaque id, unique within the job's harness session.
    public var id: String
    public var kind: Kind
    /// One line the brain can read out: what the agent wants to do.
    public var summary: String
    /// Why, when the agent said.
    public var reason: String?
    /// Choices for a question, if the agent offered any.
    public var options: [String]?

    public init(id: String, kind: Kind, summary: String, reason: String? = nil, options: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.reason = reason
        self.options = options
    }
}

/// The user's answer to an approval request.
public enum AgentApprovalDecision: Sendable, Hashable {
    case approve(always: Bool)
    case decline
    /// Text for a question request.
    case answer(String)
}

/// How a turn ended.
public enum AgentTurnOutcome: String, Codable, Sendable, Hashable {
    case completed, failed, interrupted
}

public struct AgentTokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var cachedInput: Int
    public var output: Int
    /// Input tokens written to the prompt cache (part of `input`); 0 when the harness doesn't say.
    public var cacheWrite: Int

    public init(input: Int = 0, cachedInput: Int = 0, output: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.cacheWrite = cacheWrite
    }

    private enum CodingKeys: String, CodingKey { case input, cachedInput, output, cacheWrite }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decodeIfPresent(Int.self, forKey: .input) ?? 0
        cachedInput = try container.decodeIfPresent(Int.self, forKey: .cachedInput) ?? 0
        output = try container.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheWrite = try container.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(cachedInput, forKey: .cachedInput)
        try container.encode(output, forKey: .output)
        if cacheWrite > 0 { try container.encode(cacheWrite, forKey: .cacheWrite) }
    }

    public var isZero: Bool { input == 0 && cachedInput == 0 && output == 0 && cacheWrite == 0 }

    public static func + (lhs: AgentTokenUsage, rhs: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput, output: lhs.output + rhs.output,
                        cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

/// What every harness's raw stream is normalized into. The job store logs these, the HUD shows them, and the
/// manager turns the last one of a turn into a report.
public enum AgentEvent: Sendable, Hashable {
    /// The harness opened (or resumed) its session; `threadID` resumes it later.
    case sessionStarted(threadID: String)
    case turnStarted
    /// One short line for the HUD and the voice brain's silent context ("Running: npm test").
    case progress(String)
    /// The bold heading of a reasoning summary.
    case thinking(String)
    /// Text the agent wrote along the way (not the final report).
    case commentary(String)
    case plan([AgentPlanStep])
    /// A file the agent created, changed or deleted (absolute path).
    case fileChanged(path: String, change: String)
    /// The agent is about to change a file (an edit started, or it asked to make one): the moment to keep a copy of
    /// the "before" for the file's diff. Absolute path.
    case fileWillChange(path: String)
    case approvalRequested(AgentApprovalRequest)
    case approvalResolved(id: String)
    case usage(AgentTokenUsage)
    /// Diagnostics worth keeping in the log but not showing (warnings, harness stderr).
    case log(String)
    /// A problem. Non-fatal errors are retried by the harness itself.
    case error(String, fatal: Bool)
    /// The harness compacted its conversation (folded older turns into a summary) to stay inside its context.
    case compacted
    /// The turn ended. `finalText` is the agent's last message, which carries its report.
    case turnFinished(AgentTurnOutcome, finalText: String?, error: String?)
}

extension AgentEvent {
    /// The line the HUD and `session_status` show for this event, if it has one.
    public var progressLine: String? {
        switch self {
        case .progress(let line): line
        case .thinking(let heading): heading
        case .commentary(let text): AgentText.firstLine(text, limit: 140)
        case .plan(let steps): steps.first { $0.status == .inProgress }.map { "Working on: \($0.step)" }
        case .fileChanged(let path, let change): "\(change.capitalized) \(URL(fileURLWithPath: path).lastPathComponent)"
        case .approvalRequested(let request): "Needs a yes: \(request.summary)"
        case .error(let message, let fatal): fatal ? "Error: \(message)" : "Retrying: \(message)"
        case .compacted: "Tidying up its notes to keep going"
        default: nil
        }
    }
}

// MARK: - Log encoding

/// One line of a job's `events.jsonl`.
public struct AgentLogEntry: Codable, Sendable, Hashable {
    public var t: Date
    public var kind: String
    public var text: String?
    public var path: String?
    public var change: String?
    public var fatal: Bool?
    public var outcome: AgentTurnOutcome?
    public var request: AgentApprovalRequest?
    public var plan: [AgentPlanStep]?
    public var usage: AgentTokenUsage?
    public var id: String?

    public init(_ event: AgentEvent, at time: Date) {
        t = time
        switch event {
        case .sessionStarted(let threadID): kind = "session"; id = threadID
        case .turnStarted: kind = "turn_started"
        case .progress(let line): kind = "progress"; text = line
        case .thinking(let heading): kind = "thinking"; text = heading
        case .commentary(let message): kind = "commentary"; text = message
        case .plan(let steps): kind = "plan"; plan = steps
        case .fileChanged(let path, let change): kind = "file"; self.path = path; self.change = change
        case .fileWillChange(let path): kind = "file_will_change"; self.path = path
        case .approvalRequested(let request): kind = "approval_requested"; self.request = request
        case .approvalResolved(let id): kind = "approval_resolved"; self.id = id
        case .usage(let usage): kind = "usage"; self.usage = usage
        case .log(let line): kind = "log"; text = line
        case .error(let message, let fatal): kind = "error"; text = message; self.fatal = fatal
        case .compacted: kind = "compacted"
        case .turnFinished(let outcome, let finalText, let error):
            kind = "turn_finished"; self.outcome = outcome; text = finalText; if let error { self.change = error }
        }
    }

    /// The event this entry was written from (nil for kinds this build doesn't know).
    public var event: AgentEvent? {
        switch kind {
        case "session": id.map { .sessionStarted(threadID: $0) }
        case "turn_started": .turnStarted
        case "progress": text.map { .progress($0) }
        case "thinking": text.map { .thinking($0) }
        case "commentary": text.map { .commentary($0) }
        case "plan": plan.map { .plan($0) }
        case "file": path.map { .fileChanged(path: $0, change: change ?? "changed") }
        case "file_will_change": path.map { .fileWillChange(path: $0) }
        case "approval_requested": request.map { .approvalRequested($0) }
        case "approval_resolved": id.map { .approvalResolved(id: $0) }
        case "usage": usage.map { .usage($0) }
        case "log": text.map { .log($0) }
        case "error": text.map { .error($0, fatal: fatal ?? true) }
        case "compacted": .compacted
        case "turn_finished": .turnFinished(outcome ?? .completed, finalText: text, error: change)
        default: nil
        }
    }
}

/// Small text helpers shared by normalizers and reports.
public enum AgentText {
    /// The first non-empty line, trimmed and shortened to `limit` characters with an ellipsis.
    public static func firstLine(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return shorten(line, limit: limit)
    }

    /// The text on one line: runs of whitespace and newlines become single spaces (multi-line shell commands).
    public static func oneLine(_ text: String, limit: Int) -> String {
        shorten(text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " "), limit: limit)
    }

    public static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first sentence of plain text (markdown emphasis and headings removed).
    public static func firstSentence(_ text: String, limit: Int = 220) -> String {
        let plain = stripMarkdown(text)
        var sentence = ""
        for character in plain {
            sentence.append(character)
            if ".!?".contains(character), sentence.count > 12 { break }
            if character == "\n", !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        return shorten(sentence.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
    }

    private static let markdownLink = try! NSRegularExpression(pattern: #"!?\[([^\]\n]*)\]\([^)\n]*\)"#)

    // Citation leftovers models put in text: links to search-result handles ("[BBC](turn0search3)"), bare handles
    // after a "cite" word ("cite turn0search3 turn1news2"), bracketed source markers ("【4:0†source】"), and spans
    // wrapped in private-use characters (U+E200 … U+E201) that some providers use to delimit them.
    private static let citationLink = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(\s*(?:turn\d+[a-z_]+\d+[^)\n]*)\)"#)
    private static let citationWord = try! NSRegularExpression(pattern: #"[ \t]*\bcite(?:[ \t:]*turn\d+[a-z_]+\d+)+"#, options: [.caseInsensitive])
    private static let bareHandle = try! NSRegularExpression(pattern: #"[ \t]*\(?\bturn\d+(?:search|news|view|fetch|image|file|open)\d+\b\)?"#)
    private static let bracketSource = try! NSRegularExpression(pattern: #"[ \t]*【[^】\n]{0,40}】"#)
    private static let privateSpan = try! NSRegularExpression(pattern: "[ \t]*\u{E200}[^\u{E201}\n]{0,200}\u{E201}")

    /// The text without citation markers, keeping link labels and real links. Each marker takes the spaces before it
    /// along, so no gap is left before the punctuation that follows.
    public static func stripCitations(_ text: String) -> String {
        var result = text
        func replace(_ expression: NSRegularExpression, _ template: String) {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        replace(privateSpan, "")
        result.unicodeScalars.removeAll { (0xE200...0xE2FF).contains($0.value) }
        replace(citationLink, "$1")
        replace(citationWord, "")
        replace(bracketSource, "")
        replace(bareHandle, "")
        return result
    }

    /// Removes the markdown that would be read aloud literally: emphasis, headings, inline code, link targets.
    public static func stripMarkdown(_ text: String) -> String {
        // [label](target) -> label; images too.
        var result = markdownLink.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        for token in ["**", "__", "`"] { result = result.replacingOccurrences(of: token, with: "") }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = Substring(line)
            while line.first == "#" { line = line.dropFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
