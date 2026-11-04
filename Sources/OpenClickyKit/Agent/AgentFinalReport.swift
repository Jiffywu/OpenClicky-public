import Foundation

/// The agent's final message, split into what OpenClicky shows and what the voice says.
///
/// OpenClicky's job instructions ask the agent to end with a short block:
///
///     <report>
///     say: One or two plain sentences, result first.
///     title: Two To Five Words
///     files:
///     - output/summary.md
///     next:
///     - A follow-up the user might ask for
///     question: Only when stuck on a detail the user alone can give.
///     </report>
///
/// Everything before the block is the full report (markdown) for the result card. The parser is forgiving:
/// tags in any case, missing keys, a missing closing tag, or no block at all (then the first sentence is spoken).
public struct AgentFinalReport: Codable, Sendable, Hashable {
    /// The report body shown on the result card, without the block.
    public var markdown: String
    /// What the voice says about the result.
    public var spoken: String
    public var title: String?
    /// Deliverables as the agent named them (absolute, or relative to the job folder), most important first.
    public var files: [String]
    public var nextSteps: [String]
    /// Set when the agent stopped to ask the user something.
    public var question: String?
    /// The structured answer for the result card (`<answer>` block).
    public var answer: AgentAnswer?
    /// Routines the agent wants created or changed (`<routine>` blocks); applied only after the user says yes.
    public var routineRequests: [AgentRoutineRequest]?
    /// A step only the user can do before the job goes on (`<wait_for>` block).
    public var waitFor: AgentUserStep?
    /// How-tos about the user's own setup (`<learned>` block); saved without another model pass.
    public var learned: [AgentLearnedHowTo]?
    /// Blocks that were dropped and why (malformed JSON, missing fields).
    public var blockProblems: [String]?

    public init(markdown: String, spoken: String, title: String? = nil, files: [String] = [], nextSteps: [String] = [], question: String? = nil) {
        self.markdown = markdown
        self.spoken = spoken
        self.title = title
        self.files = files
        self.nextSteps = nextSteps
        self.question = question
    }

    public static func parse(_ raw: String, now: Date = Date()) -> AgentFinalReport {
        // Citation handles from the agent's web searches mean nothing to the user; they go before anything is shown.
        let blocks = AgentFinalBlocks.extract(AgentText.stripCitations(raw), now: now)
        var report = parseReport(blocks.remainder)
        report.answer = blocks.answer
        report.routineRequests = blocks.routines.isEmpty ? nil : blocks.routines
        report.waitFor = blocks.waitFor
        report.learned = blocks.learned.isEmpty ? nil : blocks.learned
        report.blockProblems = blocks.problems.isEmpty ? nil : blocks.problems
        // Without a say line, the answer's outcome is the best thing to say.
        if !report.hasSayLine, let outcome = blocks.answer?.outcome { report.spoken = AgentText.stripMarkdown(outcome) }
        report.hasSayLine = false
        return report
    }

    /// Set while parsing: the block had a say line. Never stored.
    private var hasSayLine = false

    private enum CodingKeys: String, CodingKey {
        case markdown, spoken, title, files, nextSteps, question, answer, routineRequests, waitFor, learned, blockProblems
    }

    /// The `<report>` block and the body around it.
    static func parseReport(_ text: String) -> AgentFinalReport {
        guard let open = text.range(of: "<report>", options: [.caseInsensitive, .backwards]) else {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentFinalReport(markdown: body, spoken: AgentText.firstSentence(body))
        }
        let close = text.range(of: "</report>", options: .caseInsensitive, range: open.upperBound..<text.endIndex)
        let block = text[open.upperBound..<(close?.lowerBound ?? text.endIndex)]
        var body = String(text[..<open.lowerBound])
        let trailing = close.map { text[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !trailing.isEmpty { body += "\n\n" + trailing }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentList: String?
        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                guard let key = currentList else { continue }
                let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { lists[key, default: []].append(item) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                // A continuation of the previous single-line field.
                if let key = currentList, lists[key] == nil, let previous = fields[key] { fields[key] = previous + " " + line }
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentList = key
            if !value.isEmpty { fields[key] = value }
        }

        let spoken = (fields["say"] ?? fields["spoken"] ?? fields["summary"]).map { AgentText.stripMarkdown($0) }
        let question = fields["question"].flatMap { $0.lowercased() == "none" ? nil : $0 }
        var report = AgentFinalReport(
            markdown: body,
            spoken: spoken ?? AgentText.firstSentence(body),
            title: fields["title"],
            files: (lists["files"] ?? []).map(cleanPath),
            nextSteps: lists["next"] ?? lists["next steps"] ?? [],
            question: question)
        report.hasSayLine = spoken != nil
        return report
    }

    private static func cleanPath(_ item: String) -> String {
        var path = item
        for wrapper in ["`", "\"", "'"] where path.hasPrefix(wrapper) && path.hasSuffix(wrapper) && path.count > 1 {
            path = String(path.dropFirst().dropLast())
        }
        return path
    }

    /// Absolute file URLs for the named files that exist, resolving relative names against the job folder and
    /// ignoring anything under tmp/. Web links are kept as URLs.
    public func resolvedFiles(in folder: URL) -> [URL] {
        files.compactMap { item -> URL? in
            if item.hasPrefix("http://") || item.hasPrefix("https://") { return URL(string: item) }
            let expanded = (item as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded)
            let standardized = url.standardizedFileURL
            if standardized.path.hasPrefix(folder.appendingPathComponent("tmp").standardizedFileURL.path + "/") { return nil }
            return FileManager.default.fileExists(atPath: standardized.path) ? standardized : nil
        }
    }
}
