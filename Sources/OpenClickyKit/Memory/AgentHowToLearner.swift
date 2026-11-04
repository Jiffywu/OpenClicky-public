import Foundation

/// Learns steps worth keeping from finished background jobs. When a job is done, the brain-fast model reads its report
/// and, only when the work was a procedure the user is likely to want again (export this kind of report, set up that
/// tool), writes it as a short how-to in `how-tos.md` (`MemoryStore.saveHowTo`). Most jobs teach nothing reusable and
/// the model says so. The brain then finds the how-to among its relevant memories, and agents can read the file.
public struct AgentHowToLearner: Sendable {
    public var client: any LanguageModelClient
    public var model: String
    public var reasoningEffort: String?
    public var maxOutputTokens: Int
    /// The report is cut to about this many characters.
    public var maxReportCharacters: Int
    /// Text deliverables the job listed (Markdown, plain text) are read too, up to this many characters in all: the
    /// steps often live in the file the job wrote, not in its report.
    public var maxDeliverableCharacters: Int

    /// - Parameter maxOutputTokens: reasoning models count their thinking against it (gpt-5-nano at its default effort
    ///   spent about 1,500 tokens thinking before answering), so it leaves room, like the memory writer's cap.
    public init(client: any LanguageModelClient, model: String, reasoningEffort: String? = nil, maxOutputTokens: Int = 4_000,
                maxReportCharacters: Int = 8_000, maxDeliverableCharacters: Int = 8_000) {
        self.client = client
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.maxReportCharacters = maxReportCharacters
        self.maxDeliverableCharacters = maxDeliverableCharacters
    }

    /// The job's text deliverables (local `.md`, `.markdown` and `.txt` files), each in a `<file>` block, within the budget.
    func deliverables(_ files: [String]) -> String {
        var budget = maxDeliverableCharacters
        var blocks: [String] = []
        for path in files where budget > 200 {
            let url = path.hasPrefix("file://") ? URL(string: path) : (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil)
            guard let url, url.isFileURL, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let clipped = String(MemorySecretScrubber.scrub(text).text.prefix(budget))
            budget -= clipped.count
            blocks.append("<file name=\"\(url.lastPathComponent.replacingOccurrences(of: "\"", with: "'"))\">\n"
                          + clipped.replacingOccurrences(of: "</file>", with: "‹/file›") + "\n</file>")
        }
        return blocks.joined(separator: "\n")
    }

    /// On the brain-fast slot (the brain slot when brain-fast is empty), with the same light effort as the memory
    /// writer.
    public init(factory: EngineFactory) throws {
        let writer = try MemoryWriter(factory: factory)
        self.init(client: writer.client, model: writer.model, reasoningEffort: writer.reasoningEffort)
    }

    static let instructions = """
    You keep a short list of how-tos for one person: steps for tasks they ask their assistant to do more than once. \
    You get what a background job was asked, its report, and the text files it wrote. Decide whether they show a \
    procedure worth keeping: a task the person is likely to ask for again (keep it when they say they do it \
    regularly), done in a way that would save time next time (which tool or site, which settings, which order, which \
    pitfall to avoid). One-off research, answers to questions, and anything that only makes sense once are not worth \
    keeping.

    Reply with JSON only, no prose and no code fence:
    {"howto": null}
    or
    {"howto": {"title": "Three to eight words naming the task", "steps": "1. …\\n2. …"}}

    Keep steps general (no one-time names, dates or numbers unless they are the point), at most eight short steps. \
    Never include passwords, tokens, keys or personal identifiers.
    """

    /// Asks the model about one report and saves what it proposes. Returns nil when the job taught nothing (or wasn't
    /// done), else what the store did with it.
    ///
    /// - Parameter task: what the job was asked (`AgentJobRecord.runs.last?.ask`), when known.
    @discardableResult
    public func learn(from report: AgentJobReport, task: String? = nil, store: MemoryStore) async throws -> MemorySaveOutcome? {
        guard report.outcome == .done else { return nil }
        var body = report.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = report.spoken }
        if body.count > maxReportCharacters { body = String(body.prefix(maxReportCharacters)) + "\n…" }
        let scrubbed = MemorySecretScrubber.scrub(body).text
        var message = ""
        if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
            message += "What the job was asked: " + MemorySecretScrubber.scrub(String(task.prefix(2_000))).text + "\n"
        }
        message += "<job title=\"\(report.title.replacingOccurrences(of: "\"", with: "'"))\">\n"
            + scrubbed.replacingOccurrences(of: "</job>", with: "‹/job›") + "\n</job>"
        let files = deliverables(report.files)
        if !files.isEmpty { message += "\nWhat the job wrote:\n" + files }
        let request = ChatRequest(model: model, messages: [.system(Self.instructions), .user(.text(message))],
                                  reasoningEffort: reasoningEffort, maxOutputTokens: maxOutputTokens)
        let reply = try await client.complete(request)
        guard let howTo = Self.parse(reply.text) else { return nil }
        return try store.saveHowTo(title: howTo.title, steps: howTo.steps)
    }

    /// Saves the how-tos a job wrote in its `<learned>` block, with no model pass ("Topic: what worked" becomes a how-to
    /// titled by the topic). Returns what the store did with each; refusals (secrets, junk) are skipped.
    @discardableResult
    public static func saveLearned(_ learned: [AgentLearnedHowTo], store: MemoryStore) -> [MemorySaveOutcome] {
        learned.prefix(AgentLearnedHowTo.maxPerReport).compactMap { item in
            try? store.saveHowTo(title: item.topic, steps: item.detail)
        }
    }

    /// The proposed how-to in a reply, or nil for `{"howto": null}`, an empty one or anything unreadable.
    static func parse(_ text: String) -> (title: String, steps: String)? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let end = body.range(of: "```", options: .backwards) { body = String(body[..<end.lowerBound]) }
        }
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") { body = String(body[start...end]) }
        guard let json = try? JSONValue.parse(body), let howTo = json["howto"]?.objectValue,
              let title = howTo["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        var steps: String
        if let list = howTo["steps"]?.arrayValue {
            // A list of steps: numbered, one per line.
            steps = list.compactMap(\.stringValue).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        } else {
            steps = howTo["steps"]?.stringValue ?? ""
            // Models sometimes escape their newlines twice ("\\n" in the JSON).
            if !steps.contains("\n") { steps = steps.replacingOccurrences(of: "\\n", with: "\n") }
        }
        steps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        return steps.isEmpty ? nil : (title, steps)
    }
}
