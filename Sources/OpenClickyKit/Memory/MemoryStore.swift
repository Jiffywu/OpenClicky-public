import Foundation

/// The result of asking memory to keep something.
public enum MemorySaveOutcome: Sendable, Hashable {
    case saved(MemoryEntry)
    /// Something saying the same thing is already there.
    case alreadyKnown(MemoryEntry)
    /// Not kept, with a short reason that can be shown or spoken ("that looked like a password").
    case refused(String)

    public var entry: MemoryEntry? {
        switch self {
        case .saved(let entry), .alreadyKnown(let entry): entry
        case .refused: nil
        }
    }
}

/// OpenClicky's memory of the user, in `~/Library/Application Support/OpenClicky/Memory/`.
///
/// Every call reads the files fresh, so edits made by hand in a text editor, in Settings or with `occtl` are seen
/// at once. Writes are atomic and private to the user (0600 files in a 0700 folder). Everything written passes
/// through `MemorySecretScrubber`; an item that is mostly a secret is refused outright. One lock per folder, shared
/// by every `MemoryStore` in the process, serializes reads and writes (Settings and the brain runtime may each hold
/// their own store); two processes writing at the same instant resolve as last-writer-wins on each file.
public final class MemoryStore: @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
    }

    public static let refusedSecret = "that looked like a password, key or other secret, and OpenClicky never keeps those"
    /// Why a session-end diff was dropped: the user chose "forget everything" during the session or while its
    /// memory was being written.
    public static let erasedDuringWrite = "memory was erased during this session"

    public let directory: URL
    public let budget: MemoryBudget
    private let now: @Sendable () -> Date
    private let lock: NSRecursiveLock

    public init(directory: URL = MemoryStore.defaultDirectory, budget: MemoryBudget = MemoryBudget(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.budget = budget
        self.now = now
        self.lock = MemoryFolderRegistry.shared.lock(for: directory)
    }

    public var profileURL: URL { directory.appendingPathComponent("about-the-user.md") }
    public var standingURL: URL { directory.appendingPathComponent("standing-context.md") }
    public var howTosURL: URL { directory.appendingPathComponent("how-tos.md") }
    public var memoriesURL: URL { directory.appendingPathComponent("memories.jsonl") }

    // MARK: - Reading

    public func snapshot() throws -> MemorySnapshot {
        try lock.withLock {
            MemorySnapshot(profile: try readProfile(), standing: try readStanding(), howTos: try readHowTos(),
                           memories: try readMemories().records)
        }
    }

    public func list() throws -> [MemoryEntry] { try snapshot().entries }

    /// The best matches for `query` across memories, profile lines, standing context and how-tos.
    public func recall(_ query: String, limit: Int = 5, ranker: MemoryRanker = MemoryRanker()) throws -> [MemoryRanker.Match] {
        ranker.rank(try snapshot().entries, query: query, now: now(), limit: limit)
    }

    /// The profile's text: the file as it is, or the empty template when there is none yet.
    public func profileText() throws -> String { try lock.withLock { try readProfile().text } }

    // MARK: - Writing

    /// Replaces the whole profile (the Settings editor). Secrets are scrubbed; returns how many were.
    @discardableResult
    public func replaceProfile(with text: String) throws -> Int {
        try lock.withLock {
            let scrubbed = MemorySecretScrubber.scrub(text)
            try write(MemoryProfile(text: scrubbed.text).text, to: profileURL)
            return scrubbed.redactions
        }
    }

    /// Keeps one individual memory.
    @discardableResult
    public func save(_ text: String, kind: MemoryKind = .fact, source: MemorySource, tags: [String]? = nil,
                     sessionID: String? = nil) throws -> MemorySaveOutcome {
        try lock.withLock {
            guard case .keep(let clean) = prepare(text, limit: budget.maxMemoryCharacters) else { return refusal(for: text) }
            var file = try readMemories()
            if let existing = file.records.first(where: { $0.kind == kind && MemoryText.isDuplicate($0.text, clean) }) {
                return .alreadyKnown(Self.entry(existing))
            }
            // Tags and the session id are one-line and scrubbed like the text: the file is one record per line.
            let cleanTags = (tags ?? []).map { MemoryText.oneLine(MemorySecretScrubber.scrub($0).text) }.filter { !$0.isEmpty }
            // Session ids are OpenClicky's own UUIDs, which the scrubber would take for a token; anything else is scrubbed.
            let cleanSession = sessionID.map { id in
                UUID(uuidString: id) != nil ? id : MemoryText.oneLine(MemorySecretScrubber.scrub(id).text)
            }.flatMap { $0.isEmpty ? nil : $0 }
            let record = MemoryRecord(id: MemoryID.newMemoryID(avoiding: Set(file.records.map(\.id))), text: clean, kind: kind,
                                      createdAt: wholeSecond(now()), source: source,
                                      tags: cleanTags.isEmpty ? nil : cleanTags, sessionID: cleanSession)
            file.records.append(record)
            enforceMemoryBudget(&file)
            try writeMemories(file)
            return file.records.contains(record) ? .saved(Self.entry(record)) : .refused("memory is full")
        }
    }

    /// Adds a standing-context line: a request that applies to every conversation.
    @discardableResult
    public func addStanding(_ text: String) throws -> MemorySaveOutcome {
        try lock.withLock {
            guard case .keep(let clean) = prepare(text, limit: budget.maxStandingCharacters) else { return refusal(for: text) }
            var lines = try readStanding()
            if let existing = lines.first(where: { MemoryText.isDuplicate($0, clean) }) {
                return .alreadyKnown(MemoryEntry(id: MemoryID.standing(existing), text: existing, place: .standing))
            }
            guard lines.count < budget.maxStandingLines else { return .refused("standing context is full; remove a line first") }
            lines.append(clean)
            try write(MemoryFileFormat.renderStanding(lines), to: standingURL)
            return .saved(MemoryEntry(id: MemoryID.standing(clean), text: clean, place: .standing))
        }
    }

    /// Adds or replaces (same title) a learned how-to. Past the budget the oldest how-to goes.
    @discardableResult
    public func saveHowTo(title: String, steps: String) throws -> MemorySaveOutcome {
        try lock.withLock {
            guard case .keep(let cleanTitle) = prepare(title, limit: 120) else { return refusal(for: title) }
            let scrubbedSteps = MemorySecretScrubber.scrub(steps.trimmingCharacters(in: .whitespacesAndNewlines)).text
            let cleanSteps = MemoryText.clipped(scrubbedSteps, to: budget.maxHowToCharacters)
            var howTos = try readHowTos()
            let howTo = MemoryHowTo(title: cleanTitle, steps: cleanSteps)
            if let index = howTos.firstIndex(where: { MemoryText.normalized($0.title) == MemoryText.normalized(cleanTitle) }) {
                if howTos[index].steps == cleanSteps { return .alreadyKnown(Self.entry(howTos[index])) }
                howTos[index] = howTo
            } else {
                howTos.append(howTo)
                while howTos.count > max(1, budget.maxHowTos) { howTos.removeFirst() }
            }
            try write(MemoryFileFormat.renderHowTos(howTos), to: howTosURL)
            return .saved(Self.entry(howTo))
        }
    }

    /// Adds a line to a profile section (created if missing). Past the budget the oldest "Right now" lines go; if the
    /// profile is still too big the line is refused.
    @discardableResult
    public func addToProfile(_ text: String, section: String) throws -> MemorySaveOutcome {
        try lock.withLock {
            guard case .keep(let clean) = prepare(text, limit: budget.maxProfileLineCharacters) else { return refusal(for: text) }
            let sectionTitle = MemoryText.oneLine(MemorySecretScrubber.scrub(section).text)
            guard !sectionTitle.isEmpty else { return .refused("no profile section given") }
            var profile = try readProfile()
            let resolvedTitle = profile.section(named: sectionTitle)?.title ?? sectionTitle
            if let section = profile.section(named: sectionTitle),
               let existing = profile.bullets.first(where: { $0.section == section.title && MemoryText.isDuplicate($0.text, clean) }) {
                return .alreadyKnown(MemoryEntry(id: existing.id, text: existing.text, place: .profile(section: existing.section)))
            }
            let id = MemoryID.profile(section: resolvedTitle, text: clean)
            guard profile.add(clean, to: resolvedTitle) else {
                return .alreadyKnown(MemoryEntry(id: id, text: clean, place: .profile(section: resolvedTitle)))
            }
            while profile.characterCount > budget.maxProfileCharacters {
                guard profile.dropOldestVolatileBullet(keeping: id) != nil else {
                    return .refused("the profile is full; remove something from it first")
                }
            }
            try write(profile.text, to: profileURL)
            return .saved(MemoryEntry(id: id, text: clean, place: .profile(section: resolvedTitle)))
        }
    }

    /// Forgets the item with this id, wherever it lives. Returns what was forgotten, or nil when nothing has the id.
    @discardableResult
    public func forget(id: String) throws -> MemoryEntry? {
        try lock.withLock {
            let id = id.trimmingCharacters(in: .whitespaces).lowercased()
            var file = try readMemories()
            if let index = file.records.firstIndex(where: { $0.id.lowercased() == id }) {
                let record = file.records.remove(at: index)
                try writeMemories(file)
                return Self.entry(record)
            }
            var standing = try readStanding()
            if let index = standing.firstIndex(where: { MemoryID.standing($0) == id }) {
                let line = standing.remove(at: index)
                try write(MemoryFileFormat.renderStanding(standing), to: standingURL)
                return MemoryEntry(id: id, text: line, place: .standing)
            }
            var howTos = try readHowTos()
            if let index = howTos.firstIndex(where: { $0.id == id }) {
                let howTo = howTos.remove(at: index)
                try write(MemoryFileFormat.renderHowTos(howTos), to: howTosURL)
                return Self.entry(howTo)
            }
            var profile = try readProfile()
            if let bullet = profile.removeBullet(id: id) {
                try write(profile.text, to: profileURL)
                return MemoryEntry(id: bullet.id, text: bullet.text, place: .profile(section: bullet.section))
            }
            return nil
        }
    }

    /// Deletes every memory file. The next read starts from the empty profile template.
    ///
    /// Also counts as an erasure for this folder, so a session-end write that read memory before this call (see
    /// `erasures` and `apply(_:source:sessionID:unlessErasedSince:)`) is dropped instead of writing things back.
    public func forgetEverything() throws {
        try lock.withLock {
            MemoryFolderRegistry.shared.recordErasure(of: directory)
            for url in [profileURL, standingURL, howTosURL, memoriesURL] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            // Remembered across launches: recall_memory leaves out earlier chats from before this moment.
            try write(ISO8601DateFormatter().string(from: now()) + "\n", to: forgottenAtURL)
        }
    }

    /// Where the time of the last "forget everything" is kept.
    public var forgottenAtURL: URL { directory.appendingPathComponent("forgotten-at") }

    /// When the user last had OpenClicky forget everything, or nil. Chats in the history from before then are not
    /// brought back by `recall_memory` (the history itself is cleared separately, in Settings).
    public var forgottenAt: Date? {
        guard let text = try? String(contentsOf: forgottenAtURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How many times "forget everything" has run on this folder in this process, by any `MemoryStore`. Read it
    /// before a long job that will write memory later, and pass it to `apply(_:source:sessionID:unlessErasedSince:)`.
    public var erasures: Int { MemoryFolderRegistry.shared.erasures(of: directory) }

    /// Applies a session-end diff from `MemoryWriter`. Every part is checked the same way direct saves are.
    ///
    /// - Parameter erasures: the value of `erasures` when the diff's job read memory. If the user has forgotten
    ///   everything since, nothing is applied: the diff was built from memory they asked to have deleted.
    @discardableResult
    public func apply(_ diff: MemoryDiff, source: MemorySource = .session, sessionID: String? = nil,
                      unlessErasedSince erasures: Int? = nil) throws -> MemoryApplyReport {
        try lock.withLock {
            var report = MemoryApplyReport()
            if let erasures, erasures != self.erasures {
                report.skipped.append(.init(text: "the whole session", reason: MemoryStore.erasedDuringWrite))
                return report
            }
            func record(_ outcome: MemorySaveOutcome, _ text: String) {
                switch outcome {
                case .saved(let entry): report.added.append(entry)
                case .alreadyKnown: report.skipped.append(.init(text: text, reason: "already known"))
                case .refused(let reason): report.skipped.append(.init(text: text, reason: reason))
                }
            }

            // Removals first, so "moved from Berlin to Lisbon" can replace a line in one diff.
            for id in diff.forget {
                if let entry = try forget(id: id) { report.removed.append(entry) }
                else { report.skipped.append(.init(text: id, reason: "no such id")) }
            }
            for line in diff.profileRemove {
                var profile = try readProfile()
                if let bullet = profile.removeBullet(matching: line.text, in: line.section) {
                    try write(profile.text, to: profileURL)
                    report.removed.append(MemoryEntry(id: bullet.id, text: bullet.text, place: .profile(section: bullet.section)))
                } else {
                    report.skipped.append(.init(text: line.text, reason: "not in the profile"))
                }
            }
            for text in diff.standingRemove {
                var standing = try readStanding()
                let match = standing.firstIndex { MemoryText.normalized($0) == MemoryText.normalized(text) }
                    ?? standing.indices.filter { MemoryText.similarity(standing[$0], text) >= 0.6 }
                        .max { MemoryText.similarity(standing[$0], text) < MemoryText.similarity(standing[$1], text) }
                if let index = match {
                    let line = standing.remove(at: index)
                    try write(MemoryFileFormat.renderStanding(standing), to: standingURL)
                    report.removed.append(MemoryEntry(id: MemoryID.standing(line), text: line, place: .standing))
                } else {
                    report.skipped.append(.init(text: text, reason: "not in standing context"))
                }
            }

            for line in diff.profileAdd { record(try addToProfile(line.text, section: line.section), line.text) }
            for text in diff.standingAdd { record(try addStanding(text), text) }
            for howTo in diff.howTos { record(try saveHowTo(title: howTo.title, steps: howTo.steps), howTo.title) }
            for memory in diff.memories { record(try save(memory.text, kind: memory.kind, source: source, sessionID: sessionID), memory.text) }
            if let note = diff.sessionNote { record(try save(note, kind: .session, source: source, sessionID: sessionID), note) }
            return report
        }
    }

    // MARK: - Checks

    private enum Prepared { case keep(String), refuse }

    /// One line, secrets scrubbed, clipped to `limit`. Refused when empty or mostly a secret.
    private func prepare(_ text: String, limit: Int) -> Prepared {
        let line = MemoryText.oneLine(text)
        guard !line.isEmpty, !MemorySecretScrubber.isMostlySecret(line) else { return .refuse }
        let clean = MemoryText.clipped(MemorySecretScrubber.scrub(line).text, to: limit)
        return clean.isEmpty ? .refuse : .keep(clean)
    }

    private func refusal(for text: String) -> MemorySaveOutcome {
        MemoryText.oneLine(text).isEmpty ? .refused("nothing to remember") : .refused(Self.refusedSecret)
    }

    /// Oldest session notes go first, then the oldest of the rest.
    private func enforceMemoryBudget(_ file: inout MemoryFileFormat.MemoriesFile) {
        let limit = max(1, budget.maxMemories)
        while file.records.count > limit {
            let sessions = file.records.indices.filter { file.records[$0].kind == .session }
            let pool = sessions.isEmpty ? Array(file.records.indices) : sessions
            guard let oldest = pool.min(by: { file.records[$0].date < file.records[$1].date }) else { return }
            file.records.remove(at: oldest)
        }
    }

    private func wholeSecond(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    static func entry(_ record: MemoryRecord) -> MemoryEntry {
        MemoryEntry(id: record.id, text: record.text, place: .memory(record.kind), date: record.date)
    }

    static func entry(_ howTo: MemoryHowTo) -> MemoryEntry {
        MemoryEntry(id: howTo.id, text: howTo.steps.isEmpty ? howTo.title : "\(howTo.title): \(howTo.steps)", place: .howTo)
    }

    // MARK: - Files

    private func readText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func readProfile() throws -> MemoryProfile { try readText(profileURL).map(MemoryProfile.init(text:)) ?? .template }
    private func readStanding() throws -> [String] { try readText(standingURL).map(MemoryFileFormat.parseStanding) ?? [] }
    private func readHowTos() throws -> [MemoryHowTo] { try readText(howTosURL).map(MemoryFileFormat.parseHowTos) ?? [] }
    private func readMemories() throws -> MemoryFileFormat.MemoriesFile {
        try readText(memoriesURL).map(MemoryFileFormat.parseMemories) ?? MemoryFileFormat.MemoriesFile()
    }

    private func writeMemories(_ file: MemoryFileFormat.MemoriesFile) throws {
        try write(MemoryFileFormat.renderMemories(file), to: memoriesURL)
    }

    private func write(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Per-folder state shared by every `MemoryStore` in the process (Settings and the brain runtime may each hold their
/// own store for the same folder): the lock that serializes its reads and writes, and how many times "forget
/// everything" ran on it.
final class MemoryFolderRegistry: @unchecked Sendable {
    static let shared = MemoryFolderRegistry()

    private let lock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]
    private var erasureCounts: [String: Int] = [:]

    func lock(for directory: URL) -> NSRecursiveLock {
        let key = Self.key(directory)
        return lock.withLock {
            if let existing = locks[key] { return existing }
            let created = NSRecursiveLock()
            locks[key] = created
            return created
        }
    }

    func recordErasure(of directory: URL) {
        let key = Self.key(directory)
        lock.withLock { erasureCounts[key, default: 0] += 1 }
    }

    func erasures(of directory: URL) -> Int {
        let key = Self.key(directory)
        return lock.withLock { erasureCounts[key] ?? 0 }
    }

    private static func key(_ directory: URL) -> String { directory.standardizedFileURL.path }
}
