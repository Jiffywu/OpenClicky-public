import Foundation

/// What OpenClicky records about a job while it runs, outside the harness's own conversation: actions that reached
/// beyond the job folder, the user's answers, and the files the agent touched. Harnesses compact their
/// conversations when they get long, and a summary can drop exactly these things; the ledger can't. It is kept in
/// the job record, written to `state.md` in the job folder (the instructions tell the agent to read it after a
/// compaction or a restart), and sent to a harness that can be steered right after it compacts.
public struct AgentJobLedger: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var at: Date
        public var text: String

        public init(at: Date, text: String) {
            self.at = at
            self.text = text
        }
    }

    /// Done outside the job folder: approved actions and app tool calls that change something. Never to be repeated.
    public var sideEffects: [Entry]
    /// What the user answered or added: approvals, declines, answers and follow-ups.
    public var answers: [Entry]
    /// Absolute path → what happened to it last ("created", "changed", "deleted").
    public var files: [String: String]
    /// The paths in `files`, least recently touched first: the cap evicts from the front.
    public private(set) var fileOrder: [String]
    /// How many times the harness compacted the conversation.
    public var compactions: Int

    public init(sideEffects: [Entry] = [], answers: [Entry] = [], files: [String: String] = [:], compactions: Int = 0) {
        self.sideEffects = sideEffects
        self.answers = answers
        self.files = files
        self.fileOrder = files.keys.sorted()
        self.compactions = compactions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sideEffects = try container.decode([Entry].self, forKey: .sideEffects)
        answers = try container.decode([Entry].self, forKey: .answers)
        let files = try container.decode([String: String].self, forKey: .files)
        self.files = files
        compactions = try container.decode(Int.self, forKey: .compactions)
        // Records saved before the order was kept have no touch times; treat their files as equally old.
        let known = (try container.decodeIfPresent([String].self, forKey: .fileOrder) ?? []).filter { files[$0] != nil }
        fileOrder = files.keys.filter { !known.contains($0) }.sorted() + known
    }

    public var isEmpty: Bool { sideEffects.isEmpty && answers.isEmpty && files.isEmpty }

    static let maxEntries = 40
    static let maxFiles = 80

    public mutating func addSideEffect(_ text: String, at time: Date) {
        let line = AgentText.oneLine(text, limit: 200)
        guard !line.isEmpty, sideEffects.last?.text != line else { return }
        sideEffects.append(Entry(at: time, text: line))
        if sideEffects.count > Self.maxEntries { sideEffects.removeFirst(sideEffects.count - Self.maxEntries) }
    }

    public mutating func addAnswer(_ text: String, at time: Date) {
        let line = AgentText.oneLine(text, limit: 300)
        guard !line.isEmpty else { return }
        answers.append(Entry(at: time, text: line))
        if answers.count > Self.maxEntries { answers.removeFirst(answers.count - Self.maxEntries) }
    }

    public mutating func touch(_ path: String, change: String) {
        fileOrder.removeAll { $0 == path }
        fileOrder.append(path)
        if files[path] != "created" || change != "changed" { files[path] = change }
        // Over the cap: forget the least recently touched file, never the one just touched.
        while files.count > Self.maxFiles, let oldest = fileOrder.first {
            fileOrder.removeFirst()
            files[oldest] = nil
        }
    }

    /// Words in a tool's name that mean it changes something in the app (sends, books, deletes…), so calling it is a
    /// side effect worth remembering.
    static let writeVerbs = ["send", "create", "post", "update", "delete", "remove", "add", "write", "publish", "book", "buy",
                             "pay", "upload", "move", "archive", "reply", "comment", "invite", "schedule", "submit", "edit",
                             "set", "insert", "append", "share", "transfer", "order", "cancel", "merge", "close", "assign"]

    /// The side effect an event records, if it is one: an app tool whose name says it writes ("Using notion:
    /// create_page").
    static func sideEffect(of event: AgentEvent) -> String? {
        guard case .progress(let line) = event, line.hasPrefix("Using "), let colon = line.firstIndex(of: ":") else { return nil }
        let tool = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        let words = tool.split(whereSeparator: { !$0.isLetter })
        guard words.contains(where: { word in writeVerbs.contains(String(word)) }) else { return nil }
        return "Called " + line.dropFirst("Using ".count)
    }

    /// Whether an approved request changes something outside the job folder (so it must never be repeated): a file
    /// change or write outside the folder, or a command that sends, deletes, moves or pushes. Reads (listing,
    /// fetching, viewing) are only recorded as the user's yes.
    static func approvalIsSideEffect(_ request: AgentApprovalRequest) -> Bool {
        switch request.kind {
        case .fileChange, .browserAction: return true
        case .question, .permissions, .chromeSetup: return false
        case .command, .tool: break
        }
        let summary = request.summary
        if summary.hasPrefix("Write ") || summary.hasPrefix("Edit ") { return true }
        guard summary.hasPrefix("Run ") else { return false }
        let command = " " + summary.dropFirst(4).lowercased() + " "
        let markers = [" -x post", " -x put", " -x patch", " -x delete", " --data", " -d '", " -d \"", " -f ", "--form", " rm ",
                       " mv ", " git push", " git commit", " gh pr", " gh issue", " osascript", " sendmail", " mail ", " scp ", " rsync ",
                       " npm publish", " defaults write", " launchctl ", " kill "]
        return markers.contains { command.contains($0) }
    }

    // MARK: Text

    /// `state.md`: what the agent reads to pick the job up again.
    public func markdown(folder: URL, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var text = """
        # Job state (kept by OpenClicky)

        OpenClicky keeps this file up to date while you work. Read it again after your conversation is compacted or \
        when you pick the job up later: it is what already happened, whatever your memory of the conversation says.

        """
        text += "\n## Already done outside this folder (never repeat these)\n"
        text += sideEffects.isEmpty ? "- Nothing yet.\n" : sideEffects.map { "- \(formatter.string(from: $0.at)) · \($0.text)\n" }.joined()
        text += "\n## What the user said\n"
        text += answers.isEmpty ? "- Nothing yet.\n" : answers.map { "- \(formatter.string(from: $0.at)) · \($0.text)\n" }.joined()
        text += "\n## Files you made or changed\n"
        if files.isEmpty {
            text += "- None yet.\n"
        } else {
            let base = folder.standardizedFileURL.path + "/"
            for (path, change) in files.sorted(by: { $0.key < $1.key }) {
                let shown = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
                text += "- \(shown) (\(change))\n"
            }
        }
        return text
    }

    /// The message a steerable harness gets right after it compacted.
    public func compactionNote(folder: URL) -> String {
        "Your conversation was just compacted. Before you go on, here is what OpenClicky recorded for this job (also in state.md):\n\n"
            + markdown(folder: folder)
            + "\nDon't redo anything listed under \"Already done\". Carry on with the task."
    }
}

// MARK: - Folder ownership

/// Marks a folder as one OpenClicky made for a job, so cleanup never touches a folder it doesn't own (a kept agent
/// pointed at the user's own project, a folder copied in by hand).
public enum AgentFolderOwnership {
    static let folderName = ".openclicky"
    static let fileName = "owner"
    static let prefix = "openclicky-job-owner:"

    public static func markerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Writes the marker (`openclicky-job-owner:<job id>:<created>`) unless one is there already.
    public static func mark(_ folder: URL, jobID: String, at time: Date = Date()) throws {
        let url = markerURL(in: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: time)
        try (prefix + jobID + ":" + stamp + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// True when the folder's marker names this job.
    public static func owns(_ folder: URL, jobID: String) -> Bool {
        guard let text = try? String(contentsOf: markerURL(in: folder), encoding: .utf8) else { return false }
        return text.hasPrefix(prefix + jobID + ":")
    }
}

// MARK: - Deliverable kind

/// What a job mainly produced, from its deliverables: the icon on its card and how the brain describes it.
public enum AgentDeliverableKind: String, Codable, Sendable, CaseIterable {
    case pdf, document, sheet, slides, image, video, page, code, message, research

    /// The kind of the first deliverable that has one; `research` for a written report with no files, `message`
    /// for a short reply.
    public static func classify(files: [String], reportLength: Int) -> AgentDeliverableKind {
        for file in files {
            if let kind = kind(of: file) { return kind }
        }
        return reportLength > 400 ? .research : .message
    }

    static func kind(of file: String) -> AgentDeliverableKind? {
        if file.hasPrefix("http://") || file.hasPrefix("https://") { return .page }
        switch URL(fileURLWithPath: file).pathExtension.lowercased() {
        case "pdf": return .pdf
        case "md", "markdown", "txt", "rtf", "doc", "docx", "pages", "odt", "tex": return .document
        case "csv", "tsv", "xls", "xlsx", "numbers", "ods": return .sheet
        case "ppt", "pptx", "key", "odp": return .slides
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp": return .image
        case "mp4", "mov", "m4v", "webm", "avi": return .video
        case "html", "htm", "webloc": return .page
        case "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "sh", "zsh", "json",
             "yaml", "yml", "toml", "sql", "ipynb", "css": return .code
        default: return nil
        }
    }
}
