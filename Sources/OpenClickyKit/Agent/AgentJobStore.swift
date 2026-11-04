import Foundation

/// Where the agent subsystem keeps its files, under `~/Library/Application Support/OpenClicky`.
public struct AgentPaths: Sendable, Hashable {
    public var root: URL
    /// A folder the user chose for job and kept-agent folders (Settings → Agents); nil keeps them under `root`.
    public var customProjects: URL?

    public init(root: URL) { self.root = root }

    public init(root: URL, customProjects: URL?) {
        self.root = root
        self.customProjects = customProjects
    }

    /// The default support folder. `OPENCLICKY_SUPPORT_DIR` relocates it (tests, dry runs).
    public static var `default`: AgentPaths {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_SUPPORT_DIR"], !override.isEmpty {
            return AgentPaths(root: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        return AgentPaths(root: OpenClickyConfig.defaultURL.deletingLastPathComponent())
    }

    public var projects: URL { customProjects ?? root.appendingPathComponent("projects", isDirectory: true) }
    /// One folder per one-off job: `jobs/<slug>-<10 hex>/`.
    public var jobs: URL { projects.appendingPathComponent("jobs", isDirectory: true) }
    /// One folder per kept agent: `agents/<slug>/`.
    public var agents: URL { projects.appendingPathComponent("agents", isDirectory: true) }
    /// The Codex home OpenClicky generates (config.toml only; never a key).
    public var codexHome: URL { root.appendingPathComponent("harness/codex-home", isDirectory: true) }
    /// Claude Code's config folder for bring-your-own-key runs.
    public var claudeConfig: URL { root.appendingPathComponent("harness/claude-config", isDirectory: true) }
    public var routines: URL { root.appendingPathComponent("routines.json") }
}

public enum AgentJobStatus: String, Codable, Sendable, CaseIterable {
    case queued, running
    /// Waiting on the user: an approval, or a question in its report.
    case needsYou = "needs-you"
    case done, failed
    /// Interrupted by the user (or by quitting mid-turn).
    case stopped

    public var isActive: Bool { self == .queued || self == .running || self == .needsYou }
}

/// One task given to a job: the first ask, or a follow-up / routine run.
public struct AgentRun: Codable, Sendable, Hashable {
    public var ask: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: AgentTurnOutcome?
    public var spoken: String?
    /// The routine that started this run, if any.
    public var routineID: String?
    /// What started the run when it wasn't the user: `assume` (their question went unanswered).
    public var trigger: String?
    /// Why OpenClicky stopped the run itself (a step or time limit).
    public var stopReason: String?
    /// What this run did in the user's browser, when it used it (`BrowserTurnUsage`).
    public var browser: BrowserTurnUsage?
    /// How the harness process ended each time it died mid-run ("Codex stopped (exit 9)"). The first exit is
    /// resumed once; the second fails the run.
    public var harnessExits: [String]?

    public static let assumeTrigger = "assume"

    public init(ask: String, startedAt: Date, routineID: String? = nil) {
        self.ask = ask
        self.startedAt = startedAt
        self.routineID = routineID
    }
}

/// A job's metadata, stored as `job.json` in its folder.
public struct AgentJobRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case job, kept }

    public var id: String
    public var kind: Kind
    public var title: String
    /// The first task, as asked.
    public var task: String
    /// Kept agents only: display name and role.
    public var agentName: String?
    public var agentRole: String?
    public var harness: HarnessKind
    /// Model id passed to the harness; nil = the harness's default.
    public var model: String?
    /// Agent-slot provider id, or "harness-login".
    public var provider: String
    public var status: AgentJobStatus
    public var createdAt: Date
    public var updatedAt: Date
    /// The harness's own conversation id, for resuming.
    public var threadID: String?
    public var runs: [AgentRun]
    public var lastProgress: String?
    public var report: AgentFinalReport?
    public var pendingRequest: AgentApprovalRequest?
    public var error: String?
    /// Tokens the job used over all its runs.
    public var usage: AgentTokenUsage
    /// The harness's last running total (Codex), so a repeated report isn't counted twice.
    public var usageCursor: AgentTokenUsage?
    /// The folder this record lives in (refreshed on load).
    public var folderPath: String
    /// The line shown (or said) as the job started, from the launch labeler.
    public var startCue: String?
    /// The agent's latest message along the way (not its report), for the brain's progress context.
    public var lastSaid: String?
    /// Side effects, the user's answers and touched files, kept outside the harness's conversation (`state.md`).
    public var ledger: AgentJobLedger?
    /// What the latest finished run mainly produced.
    public var deliverableKind: AgentDeliverableKind?
    /// When the cleanup removed this job's scratch files, event log and task screenshots.
    public var cleanedAt: Date?
    /// false once a run finished that the user hasn't looked at yet (nil on records from before the flag: seen).
    public var isSeen: Bool?
    /// The user closed it in the jobs panel; a new result brings it back.
    public var isDismissed: Bool?
    /// When the user archived it (`isArchived`). Any job leaves the job list (Home → Agents shows it under Archived)
    /// and a new run brings it back; a kept agent also leaves the [Your Clickys] note until work is routed to it (its
    /// routines' runs keep it archived).
    public var archivedAt: Date?
    /// A step only the user can do; the job waits in needs-you until they say it's done (`<wait_for>`).
    public var waitingStep: AgentUserStep?
    /// Routines the agent proposed in its report, waiting for the user's yes (`<routine>`).
    public var pendingRoutines: [AgentRoutineRequest]?
    /// One-off jobs only: the kept agent the organizer filed this job under (its folder is linked there, not moved).
    public var filedUnder: String?
    /// Before-and-after diffs of the files the agent changed (developer preview; `AgentFileDiffs`).
    public var fileDiffs: [AgentFileDiffItem]?

    public init(id: String, kind: Kind, title: String, task: String, agentName: String? = nil, agentRole: String? = nil,
                harness: HarnessKind, model: String?, provider: String, status: AgentJobStatus, createdAt: Date, updatedAt: Date,
                threadID: String? = nil, runs: [AgentRun] = [], lastProgress: String? = nil, report: AgentFinalReport? = nil,
                pendingRequest: AgentApprovalRequest? = nil, error: String? = nil, usage: AgentTokenUsage = .init(), folderPath: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.task = task
        self.agentName = agentName
        self.agentRole = agentRole
        self.harness = harness
        self.model = model
        self.provider = provider
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.threadID = threadID
        self.runs = runs
        self.lastProgress = lastProgress
        self.report = report
        self.pendingRequest = pendingRequest
        self.error = error
        self.usage = usage
        self.folderPath = folderPath
    }

    public var folder: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    /// A finished result the user hasn't opened yet.
    public var isUnseen: Bool { isSeen == false }
    /// In the default job list (not archived).
    public var isListed: Bool { !isArchived }
    public var outputFolder: URL { folder.appendingPathComponent("output", isDirectory: true) }
    public var isKept: Bool { kind == .kept }
    public var isArchived: Bool { archivedAt != nil }

    /// Seconds the latest run took (or has taken so far).
    public func lastRunDuration(now: Date = Date()) -> TimeInterval? {
        guard let run = runs.last else { return nil }
        return (run.finishedAt ?? now).timeIntervalSince(run.startedAt)
    }
}

/// Job folders on disk:
///
///     projects/
///       WORK.md                      index of every job, newest first
///       jobs/<slug>-<10 hex>/        one-off jobs
///       agents/<slug>/               kept agents (persist across tasks)
///         AGENTS.md                  persona and notes the harness reads
///         job.json                   metadata (AgentJobRecord)
///         events.jsonl               normalized event log
///         report.md                  latest report and the run list
///         output/                    deliverables
///         tmp/                       scratch
///
/// Stateless: every call reads or writes the files. The manager serializes writes per job.
public struct AgentJobStore: Sendable {
    public var paths: AgentPaths

    public init(paths: AgentPaths = .default) { self.paths = paths }

    static let jobFileName = "job.json"
    static let eventsFileName = "events.jsonl"

    // MARK: Creating

    public func createJob(task: String, title: String?, harness: HarnessKind, model: String?, provider: String, now: Date = Date()) throws -> AgentJobRecord {
        let title = Self.title(title, from: task)
        let id = "\(Self.slug(title))-\(Self.randomHex(10))"
        let folder = paths.jobs.appendingPathComponent(id, isDirectory: true)
        try makeFolder(folder)
        try AgentFolderOwnership.mark(folder, jobID: id, at: now)
        try Self.jobNotes(title: title).write(to: folder.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let record = AgentJobRecord(
            id: id, kind: .job, title: title, task: task, harness: harness, model: model, provider: provider,
            status: .queued, createdAt: now, updatedAt: now, runs: [], usage: .init(), folderPath: folder.path)
        try save(record)
        return record
    }

    /// The kept agent with this slug (the name's slug unless `slug` is given), created (with its AGENTS.md persona) if
    /// it doesn't exist yet.
    public func keptAgent(named name: String, slug given: String? = nil, role: String?, harness: HarnessKind, model: String?,
                          provider: String, now: Date = Date()) throws -> AgentJobRecord {
        let slug = given ?? Self.slug(name)
        if let existing = load(id: slug), existing.isKept { return existing }
        let folder = paths.agents.appendingPathComponent(slug, isDirectory: true)
        try makeFolder(folder)
        try AgentFolderOwnership.mark(folder, jobID: slug, at: now)
        let notes = folder.appendingPathComponent("AGENTS.md")
        if !FileManager.default.fileExists(atPath: notes.path) {
            try Self.agentPersona(name: name, role: role).write(to: notes, atomically: true, encoding: .utf8)
        }
        let record = AgentJobRecord(
            id: slug, kind: .kept, title: name, task: role ?? "", agentName: name, agentRole: role, harness: harness,
            model: model, provider: provider, status: .done, createdAt: now, updatedAt: now, runs: [], usage: .init(),
            folderPath: folder.path)
        try save(record)
        return record
    }

    private func makeFolder(_ folder: URL) throws {
        for sub in ["output", "tmp"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    // MARK: Reading and writing

    public func save(_ record: AgentJobRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: record.folder.appendingPathComponent(Self.jobFileName), options: .atomic)
    }

    public func load(id: String) -> AgentJobRecord? {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        for base in [paths.agents, paths.jobs] {
            // The Mac's volume is usually case-insensitive, so "Scribe" opens agents/scribe/. Only the exact id
            // counts; otherwise the record would carry (and save) a folder path that differs from its real one.
            if let record = load(folder: base.appendingPathComponent(id, isDirectory: true)), record.id == id { return record }
        }
        return nil
    }

    func load(folder: URL) -> AgentJobRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.jobFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var record = try? decoder.decode(AgentJobRecord.self, from: data) else { return nil }
        record.folderPath = folder.path
        return record
    }

    /// The job list: every job and kept agent but the archived ones (all of them with `includeArchived`).
    public func listed(includeArchived: Bool = false) -> [AgentJobRecord] {
        includeArchived ? all() : all().filter(\.isListed)
    }

    /// Every job and kept agent, most recently updated first.
    public func all() -> [AgentJobRecord] {
        var records: [AgentJobRecord] = []
        for base in [paths.jobs, paths.agents] {
            let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            records += folders.compactMap(load(folder:))
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func append(_ event: AgentEvent, to record: AgentJobRecord, at time: Date = Date()) {
        appendEntry(AgentLogEntry(event, at: time), to: record)
    }

    func appendEntry(_ entry: AgentLogEntry, to record: AgentJobRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        let url = record.folder.appendingPathComponent(Self.eventsFileName)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// The last `limit` log entries of a job.
    public func events(of record: AgentJobRecord, limit: Int = 200) -> [AgentLogEntry] {
        guard let text = try? String(contentsOf: record.folder.appendingPathComponent(Self.eventsFileName), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).compactMap { try? decoder.decode(AgentLogEntry.self, from: Data($0.utf8)) }
    }

    /// Files in the job's output folder, newest first (relative paths).
    public func outputs(of record: AgentJobRecord) -> [String] {
        let base = record.outputFolder.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { return [] }
        var found: [(String, Date)] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            found.append(("output/" + relative, values?.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Jobs whose title, task, report or agent name mention every word of `query`, best matches first.
    public func find(_ query: String, limit: Int = 8) -> [AgentJobRecord] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        let records = all()
        guard !words.isEmpty else { return Array(records.prefix(limit)) }
        let scored = records.compactMap { record -> (AgentJobRecord, Int)? in
            let title = record.title.lowercased()
            let rest = [record.task, record.agentName ?? "", record.agentRole ?? "", record.report?.markdown ?? "", record.runs.map(\.ask).joined(separator: " ")]
                .joined(separator: " ").lowercased()
            var score = 0
            for word in words {
                if title.contains(word) { score += 3 } else if rest.contains(word) { score += 1 } else { return nil }
            }
            return (record, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }.prefix(limit).map(\.0)
    }

    // MARK: Reports and the index

    /// Writes `report.md`: the latest report, then every run (newest last).
    public func writeReport(for record: AgentJobRecord) throws {
        var text = "# \(record.report?.title ?? record.title)\n\n"
        if let report = record.report {
            text += report.markdown.isEmpty ? report.spoken : report.markdown
            text += "\n"
        }
        text += "\n## Runs\n\n"
        let formatter = Self.minuteFormatter
        for run in record.runs {
            text += "- \(formatter.string(from: run.startedAt)) · \(run.outcome?.rawValue ?? "working") · asked: \(AgentText.shorten(run.ask.replacingOccurrences(of: "\n", with: " "), limit: 160))"
            if let spoken = run.spoken { text += "\n  - \(spoken)" }
            text += "\n"
        }
        try text.write(to: record.folder.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    /// Writes `state.md` from the job's ledger (nothing when it has none yet).
    public func writeState(for record: AgentJobRecord) throws {
        guard let ledger = record.ledger else { return }
        try ledger.markdown(folder: record.folder).write(to: record.folder.appendingPathComponent("state.md"), atomically: true, encoding: .utf8)
    }

    /// Removes what a job no longer needs once it has been idle for good: the scratch in `tmp/` and the event log of a
    /// one-off job (only in a folder whose ownership marker names it), and its task screenshots. A kept agent keeps
    /// its folder (its `tmp/` holds helpers it reuses) and loses only task screenshots older than `cutoff`.
    /// Deliverables, reports, notes, `state.md` and the record stay. Returns the paths removed.
    @discardableResult
    public func cleanUp(_ record: AgentJobRecord, olderThan cutoff: Date) -> [String] {
        let manager = FileManager.default
        var removed: [String] = []
        func remove(_ url: URL) {
            guard manager.fileExists(atPath: url.path) else { return }
            if (try? manager.removeItem(at: url)) != nil { removed.append(url.path) }
        }
        let assets = paths.taskAssets.appendingPathComponent(record.id, isDirectory: true)
        if record.isKept {
            let runs = (try? manager.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for run in runs {
                let modified = (try? run.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { remove(run) }
            }
            return removed
        }
        remove(assets)
        guard AgentFolderOwnership.owns(record.folder, jobID: record.id) else { return removed }
        let scratch = record.folder.appendingPathComponent("tmp", isDirectory: true)
        for item in (try? manager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)) ?? [] { remove(item) }
        remove(record.folder.appendingPathComponent(Self.eventsFileName))
        return removed
    }

    /// Rewrites `projects/WORK.md`, the index agents read to find earlier work.
    public func writeIndex() throws {
        try FileManager.default.createDirectory(at: paths.projects, withIntermediateDirectories: true)
        var text = "# Work OpenClicky has done\n\nNewest first. Each line: when · title · folder · status.\n\n"
        let formatter = Self.minuteFormatter
        for record in all().prefix(200) {
            let folder = record.isKept ? "agents/\(record.id)/" : "jobs/\(record.id)/"
            let state = record.status.isActive ? "working now" : (record.report?.spoken.isEmpty == false ? record.report!.spoken : record.status.rawValue)
            text += "- \(formatter.string(from: record.createdAt)) · \(record.title) · \(folder) · \(AgentText.shorten(state, limit: 140))\n"
        }
        try text.write(to: paths.projects.appendingPathComponent("WORK.md"), atomically: true, encoding: .utf8)
    }

    static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: Naming and templates

    /// A short title from the task when none was given: its first line, up to eight words.
    static func title(_ given: String?, from task: String) -> String {
        if let given = given?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty { return AgentText.shorten(given, limit: 80) }
        let words = AgentText.firstLine(task, limit: 400).split(separator: " ").prefix(8).joined(separator: " ")
        return words.isEmpty ? "Job" : AgentText.shorten(words, limit: 80)
    }

    /// Lowercase ASCII letters, digits and single dashes; at most 40 characters. A name with no Latin letters or
    /// digits at all ("旅行プランナー") is transliterated first, so different names in other scripts get different slugs
    /// instead of all becoming "job".
    public static func slug(_ text: String) -> String {
        let plain = asciiSlug(text)
        if !plain.isEmpty { return plain }
        let latin = asciiSlug(text.applyingTransform(.toLatin, reverse: false) ?? "")
        return latin.isEmpty ? "job" : latin
    }

    private static func asciiSlug(_ text: String) -> String {
        var slug = ""
        for scalar in text.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
            if slug.count >= 40 { break }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    static func randomHex(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in "0123456789abcdef".randomElement(using: &generator)! })
    }

    static func jobNotes(title: String) -> String {
        """
        # Job notes

        This folder belongs to one OpenClicky job: "\(title)".
        Deliverables go in output/. Scratch files, downloads and installed helpers go in tmp/.
        Keep the Notes below short and current so the job can be picked up again later.
        Never write passwords, API keys or other secrets in this folder.

        ## Notes

        """
    }

    static func agentPersona(name: String, role: String?) -> String {
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "general helper"
        return """
        # \(name)

        You are \(name), a helper the user keeps in OpenClicky for ongoing work as their \(role).
        This folder is yours across tasks: what you made before is still here, and this file is your memory.
        Read it at the start of every task and keep it up to date before you finish.

        ## Identity
        - Name: \(name)
        - Role: \(role)

        ## Standing preferences
        One line each: what the user has told you they want, or never want.

        ## Notes
        Dated, short and current. Remove what no longer holds. Never store secrets.

        """
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
