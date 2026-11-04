import Foundation

/// Who made a `browser` call. Codex puts its thread and turn into the call's `_meta["x-codex-turn-metadata"]`;
/// every harness also sends the job's id as the `X-OpenClicky-Job` header on its OpenClicky MCP server (Claude Code
/// has no turn metadata of its own), which the MCP server forwards into `_meta` under the header's lowercase name.
public struct BrowserCallIdentity: Sendable, Hashable {
    public var jobID: String?
    public var threadID: String?
    public var turnID: String?

    public init(jobID: String? = nil, threadID: String? = nil, turnID: String? = nil) {
        self.jobID = jobID
        self.threadID = threadID
        self.turnID = turnID
    }

    /// The header harnesses send with the job's id (`AgentMCPServer.jobHeaderName`; the same one the job tools read).
    public static let jobHeader = AgentJobMCPTools.jobHeader
    public static let codexTurnMetadata = "x-codex-turn-metadata"

    public var isEmpty: Bool { jobID == nil && threadID == nil }

    public static func from(meta: JSONValue?) -> BrowserCallIdentity {
        var identity = BrowserCallIdentity()
        guard let meta, meta.objectValue != nil else { return identity }
        identity.jobID = clean(meta[jobHeader.lowercased()]?.stringValue)
        // Codex sends the metadata as an object; some builds send it JSON-encoded in a string.
        var turn = meta[codexTurnMetadata]
        if let text = turn?.stringValue { turn = try? JSONValue.parse(text) }
        if let turn {
            identity.threadID = clean(turn["thread_id"]?.stringValue ?? turn["threadId"]?.stringValue)
            identity.turnID = clean(turn["turn_id"]?.stringValue ?? turn["turnId"]?.stringValue)
        }
        return identity
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.count <= 200 else { return nil }
        return value
    }
}

/// What one agent turn did with the browser, kept on the job's run (`AgentRun.browser`).
public struct BrowserTurnUsage: Codable, Sendable, Hashable {
    public var turn: Int
    public var firstCallAt: Date
    public var endedAt: Date?
    public var operationCount = 0
    public var operationCounts: [String: Int] = [:]
    public var batchStepCount = 0
    public var errorCount = 0
    public var timeoutCount = 0
    public var tabsOpened = 0
    public var tabsKept = 0
    public var tabsClosed = 0
    public var screenshots = 0
    public var screenshotsSaved = 0
    public var stoppedByUser = false
    public var accessEndedByTimeout = false

    public init(turn: Int, firstCallAt: Date) {
        self.turn = turn
        self.firstCallAt = firstCallAt
    }

    /// One line for logs and the job's activity: "browser: 7 calls (3 click, 2 read…), 1 error, 2 tabs closed".
    public var summary: String {
        let ops = operationCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(4).map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        var parts = ["\(operationCount) call\(operationCount == 1 ? "" : "s")" + (ops.isEmpty ? "" : " (\(ops))")]
        if batchStepCount > 0 { parts.append("\(batchStepCount) batch steps") }
        if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
        if timeoutCount > 0 { parts.append("\(timeoutCount) timed out") }
        if tabsOpened > 0 { parts.append("\(tabsOpened) tab\(tabsOpened == 1 ? "" : "s") opened") }
        if tabsKept > 0 { parts.append("\(tabsKept) kept") }
        if tabsClosed > 0 { parts.append("\(tabsClosed) closed") }
        if screenshotsSaved > 0 { parts.append("\(screenshotsSaved) screenshot\(screenshotsSaved == 1 ? "" : "s") saved") }
        if stoppedByUser { parts.append("stopped by the user") }
        if accessEndedByTimeout { parts.append("access ended after a timeout") }
        return "browser: " + parts.joined(separator: ", ")
    }
}

/// Binds browser calls to agent turns. The app tells it when a job's turn starts and ends (from `AgentManager`'s
/// events); each call is then checked against its job's turn: refused once the turn has ended, refused when the
/// browser reconnected since the turn's first call, refused after an acting call timed out. It also remembers which
/// tabs each job opened (only those can be closed, and the unkept ones are closed when the turn ends) and counts what
/// each turn did.
///
/// Calls with no job identity (`occtl browser call`, tests, jobs of another OpenClicky process) are "unbound": they
/// share one pseudo-job for tab ownership and are never refused for turn reasons. Browser changes still require
/// the tool's explicit user approval.
public final class BrowserTurnRegistry: @unchecked Sendable {
    public enum Binding: Sendable, Equatable {
        case unbound
        case job(id: String, turn: Int)

        public var jobID: String? { if case .job(let id, _) = self { id } else { nil } }
    }

    /// A finished turn: what it did and which of its job's tabs to close now.
    public struct Ending: Sendable, Equatable {
        public var jobID: String
        public var usage: BrowserTurnUsage?
        /// Tabs the job opened that this turn didn't keep (empty after the user pressed Stop: those tabs are theirs).
        public var tabsToClose: [Int]
        /// The browser profile each of those tabs is in (a tab id means nothing in another browser).
        public var tabProfiles: [Int: String] = [:]
    }

    struct Job {
        var title: String?
        var folder: URL?
        var threadID: String?
        var turn = 0
        var active = false
        var ownedTabs: Set<Int> = []
        /// Tabs kept past the current turn, with the reason (`result` or `waiting`).
        var kept: [Int: String] = [:]
        /// The browser connection this turn's first call went to, and its profile.
        var generation: Int?
        var profile: String?
        /// The profile each owned tab was opened in.
        var tabProfiles: [Int: String] = [:]
        var usage: BrowserTurnUsage?
        var accessEnded: String?
        var askedForSetup = false
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var unbound = Job()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    // MARK: Turn lifecycle (from the app)

    /// A job's turn started. Kept tabs from the previous turn stay owned (and are closed at this turn's end unless
    /// kept again).
    public func beginTurn(jobID: String, title: String? = nil, folder: URL? = nil) {
        lock.withLock {
            var job = jobs[jobID] ?? Job()
            if let title { job.title = title }
            if let folder { job.folder = folder }
            job.turn += 1
            job.active = true
            job.kept = [:]
            job.generation = nil
            job.profile = nil
            job.usage = nil
            job.accessEnded = nil
            jobs[jobID] = job
        }
    }

    /// Codex's thread id for a job, so calls that carry only `x-codex-turn-metadata` find it.
    public func noteThread(jobID: String, threadID: String) {
        lock.withLock {
            var job = jobs[jobID] ?? Job()
            job.threadID = threadID
            jobs[jobID] = job
        }
    }

    /// The job's turn ended: later calls are refused until its next turn. Nil when the job never had a turn here or
    /// its turn already ended.
    public func endTurn(jobID: String) -> Ending? {
        lock.withLock { () -> Ending? in
            guard var job = jobs[jobID], job.active else { return nil }
            job.active = false
            var usage = job.usage
            usage?.endedAt = now()
            var close: [Int] = []
            var profiles: [Int: String] = [:]
            if usage?.stoppedByUser == true {
                // After Stop the tabs are the user's: nothing is closed and the job no longer owns them.
                job.ownedTabs = []
                job.tabProfiles = [:]
            } else {
                close = job.ownedTabs.filter { job.kept[$0] == nil }.sorted()
                job.ownedTabs.subtract(close)
                for tab in close { profiles[tab] = job.tabProfiles.removeValue(forKey: tab) }
            }
            job.usage = nil
            jobs[jobID] = job
            return Ending(jobID: jobID, usage: usage, tabsToClose: close, tabProfiles: profiles)
        }
    }

    /// The user pressed Stop in a browser: every tab a job opened there is theirs now (never closed by a tidy-up),
    /// and a turn using that browser counts as stopped by the user.
    public func userStopped(profile: String) {
        lock.withLock {
            for (id, var job) in jobs {
                let released = job.ownedTabs.filter { job.tabProfiles[$0] == nil || job.tabProfiles[$0] == profile }
                job.ownedTabs.subtract(released)
                for tab in released {
                    job.tabProfiles[tab] = nil
                    job.kept[tab] = nil
                }
                if job.active, job.profile == profile { job.usage?.stoppedByUser = true }
                jobs[id] = job
            }
            unbound.ownedTabs = []
            unbound.kept = [:]
        }
    }

    /// Drops a job entirely (deleted).
    public func forget(jobID: String) { lock.withLock { _ = jobs.removeValue(forKey: jobID) } }

    /// Jobs whose turn is running now (sent to the extension as `sweep`'s `running` list).
    public var activeJobs: [String] { lock.withLock { jobs.filter { $0.value.active }.map(\.key).sorted() } }

    // MARK: Calls

    /// Finds the call's job and checks it may use the browser now.
    public func bind(_ identity: BrowserCallIdentity) -> Result<Binding, BrowserBridgeError> {
        lock.withLock {
            let id = identity.jobID ?? identity.threadID.flatMap { thread in jobs.first { $0.value.threadID == thread }?.key }
            // A job this process never heard of (a job of `occtl agent run` using the app's bridge) works unbound.
            guard let id, let job = jobs[id] else { return .success(.unbound) }
            guard job.active else { return .failure(BrowserBridgeError(.turnEnded, "The agent turn ended.")) }
            if let reason = job.accessEnded { return .failure(BrowserBridgeError(.accessEnded, reason)) }
            return .success(.job(id: id, turn: job.turn))
        }
    }

    /// The connection this turn is tied to, if its first call already went out.
    public func generation(for binding: Binding) -> Int? {
        lock.withLock { binding.jobID.flatMap { jobs[$0]?.generation } }
    }

    public func setGeneration(_ generation: Int, profile: String? = nil, for binding: Binding) {
        lock.withLock {
            guard let id = binding.jobID, jobs[id]?.generation == nil else { return }
            jobs[id]?.generation = generation
            jobs[id]?.profile = profile
        }
    }

    public func title(for binding: Binding) -> String? { lock.withLock { binding.jobID.flatMap { jobs[$0]?.title } } }
    public func folder(for binding: Binding) -> URL? { lock.withLock { binding.jobID.flatMap { jobs[$0]?.folder } } }

    public func owns(_ tabID: Int, _ binding: Binding) -> Bool {
        lock.withLock { withJob(binding) { $0.ownedTabs.contains(tabID) } ?? false }
    }

    public func ownedTabs(_ binding: Binding) -> [Int] {
        lock.withLock { withJob(binding) { $0.ownedTabs.sorted() } ?? [] }
    }

    public func keptTabs(_ binding: Binding) -> [Int: String] {
        lock.withLock { withJob(binding) { $0.kept } ?? [:] }
    }

    /// Asks for Chrome setup at most once per job; true the first time.
    public func shouldAskForSetup(_ binding: Binding) -> Bool {
        lock.withLock {
            guard let id = binding.jobID, var job = jobs[id], !job.askedForSetup else { return false }
            job.askedForSetup = true
            jobs[id] = job
            return true
        }
    }

    /// Tab bookkeeping after a successful call.
    public func opened(_ tabIDs: [Int], _ binding: Binding) {
        guard !tabIDs.isEmpty else { return }
        lock.withLock {
            withJob(binding) { job in
                let new = Set(tabIDs).subtracting(job.ownedTabs)
                job.ownedTabs.formUnion(new)
                if let profile = job.profile { for tab in new { job.tabProfiles[tab] = profile } }
                job.usage?.tabsOpened += new.count
            }
        }
    }

    public func closed(_ tabIDs: [Int], _ binding: Binding) {
        lock.withLock {
            withJob(binding) { job in
                job.ownedTabs.subtract(tabIDs)
                for id in tabIDs {
                    job.kept[id] = nil
                    job.tabProfiles[id] = nil
                }
                job.usage?.tabsClosed += tabIDs.count
            }
        }
    }

    public func kept(_ tabID: Int, why: String, _ binding: Binding) {
        lock.withLock {
            withJob(binding) { job in
                if job.kept[tabID] == nil { job.usage?.tabsKept += 1 }
                job.kept[tabID] = why
            }
        }
    }

    /// Counts one call (a batch counts its steps too).
    public func record(_ operation: String, batchSteps: Int = 0, _ binding: Binding) {
        lock.withLock {
            withJob(binding) { job in
                if job.usage == nil, case .job = binding { job.usage = BrowserTurnUsage(turn: job.turn, firstCallAt: now()) }
                job.usage?.operationCount += 1
                job.usage?.operationCounts[operation, default: 0] += 1
                job.usage?.batchStepCount += batchSteps
            }
        }
    }

    public func recordError(_ kind: BrowserBridgeError.Kind?, _ binding: Binding) {
        lock.withLock {
            withJob(binding) { job in
                job.usage?.errorCount += 1
                if kind == .timeout { job.usage?.timeoutCount += 1 }
                if kind == .stopped { job.usage?.stoppedByUser = true }
            }
        }
    }

    public func recordScreenshot(saved: Bool, _ binding: Binding) {
        lock.withLock {
            withJob(binding) { job in
                job.usage?.screenshots += 1
                if saved { job.usage?.screenshotsSaved += 1 }
            }
        }
    }

    /// An acting call timed out: its outcome is unknown, so the rest of the turn may not act in the browser.
    public func endAccess(_ binding: Binding, reason: String) {
        lock.withLock {
            guard let id = binding.jobID else { return }
            jobs[id]?.accessEnded = reason
            jobs[id]?.usage?.accessEndedByTimeout = true
        }
    }

    /// The running turn's counters so far (tests, `occtl`).
    public func usage(jobID: String) -> BrowserTurnUsage? { lock.withLock { jobs[jobID]?.usage } }

    /// Runs `body` on the bound job (or the unbound pseudo-job). Call with the lock held.
    @discardableResult
    private func withJob<T>(_ binding: Binding, _ body: (inout Job) -> T) -> T? {
        switch binding {
        case .unbound:
            return body(&unbound)
        case .job(let id, let turn):
            guard var job = jobs[id], job.turn == turn else { return nil }
            defer { jobs[id] = job }
            return body(&job)
        }
    }
}

/// Tab-group titles: an emoji that hints at the task, then the job's title ("🛒 Weekly groceries").
public enum BrowserGroupTitle {
    static let themes: [(emoji: String, words: [String])] = [
        ("🛒", ["shop", "buy", "cart", "order", "grocer", "amazon", "purchase"]),
        ("✈️", ["flight", "trip", "travel", "hotel", "airbnb", "booking"]),
        ("🎟️", ["ticket", "concert", "show", "event"]),
        ("📧", ["mail", "inbox", "gmail", "outlook"]),
        ("📅", ["calendar", "meeting", "schedule", "appointment"]),
        ("💰", ["price", "bill", "invoice", "refund", "bank", "budget", "pay"]),
        ("💬", ["slack", "discord", "message", "chat", "post", "tweet", "linkedin"]),
        ("🎵", ["music", "spotify", "playlist", "song"]),
        ("🎬", ["video", "youtube", "movie", "tiktok", "netflix"]),
        ("💻", ["code", "github", "deploy", "website", "repo", "pull request"]),
        ("📰", ["news", "article", "blog", "read"]),
        ("📄", ["doc", "form", "sheet", "report", "application", "pdf"]),
        ("🍽️", ["restaurant", "recipe", "reservation", "dinner", "food"]),
        ("🏠", ["apartment", "rent", "listing", "house", "home"]),
    ]

    public static let fallbackEmoji = "🔎"

    public static func make(title: String?) -> String {
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "\(fallbackEmoji) OpenClicky" }
        let lower = name.lowercased()
        let emoji = themes.first { $0.words.contains { lower.contains($0) } }?.emoji ?? fallbackEmoji
        return "\(emoji) \(String(name.prefix(40)))"
    }
}

/// Saved screenshots: `<job folder>/output/<site>-<yyyy-MM-dd-HHmmss>.jpg`.
public enum BrowserScreenshotFile {
    public static let notSavedNote = "Not saved: only a job's screenshots are kept in its folder."

    /// "news.example.com" → "news-example-com"; "www." is dropped; anything odd becomes "page".
    public static func slug(for url: String?) -> String {
        guard let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }), !host.isEmpty else { return "page" }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let slug = trimmed.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return slug.isEmpty ? "page" : String(slug.prefix(60))
    }

    /// Writes the JPEG into `folder/output/` and returns its URL (a free name: `-2`, `-3` … on a clash).
    public static func save(_ data: Data, url: String?, inJobFolder folder: URL, at date: Date = Date()) throws -> URL {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "\(slug(for: url))-\(formatter.string(from: date))"
        var candidate = output.appendingPathComponent(base + ".jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = output.appendingPathComponent("\(base)-\(n).jpg")
            n += 1
        }
        try data.write(to: candidate, options: .withoutOverwriting)
        return candidate
    }
}
