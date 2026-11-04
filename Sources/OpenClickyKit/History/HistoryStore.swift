import Foundation

/// What changed in the history, for views that follow it.
public enum HistoryChange: Sendable, Hashable {
    case turnAppended(sessionID: String, turnID: String)
    /// A job started or came back in this conversation (`HistoryHandOff`).
    case handOffAppended(sessionID: String, handOffID: String)
    case sessionStarted(String)
    case sessionDeleted(String)
    case cleared
}

/// The conversation history on disk: one append-only JSON Lines file per session plus an index of session summaries.
///
/// ```
/// ~/Library/Application Support/OpenClicky/History/
///   index.json                 {"version":1,"sessions":[HistorySession…]}  (a cache; rebuilt from the files when stale)
///   sessions/<session-id>.jsonl
///     {"kind":"session","version":1,"id":"…","at":"2026-10-31T09:12:03.120Z"}
///     {"kind":"turn","turn":{HistoryTurn}}
///     {"kind":"narration","turn":"<turn-id>","note":"cut off by the user after line 2"}
///     {"kind":"handoff","handoff":{HistoryHandOff}}
/// ```
///
/// Appends never rewrite a session file, so a crash loses at most the line being written; unreadable lines are skipped
/// on read. Dates are ISO 8601 with milliseconds. See docs/history.md.
public final class HistoryStore: @unchecked Sendable {
    public static let formatVersion = 1

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    public let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<HistoryChange>.Continuation] = [:]

    public init(directory: URL = HistoryStore.defaultDirectory, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    var sessionsDirectory: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    var indexURL: URL { directory.appendingPathComponent("index.json") }

    func fileURL(for sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(Self.safeName(sessionID) + ".jsonl")
    }

    /// Session ids become file names; anything outside a conservative set is replaced.
    public static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "session" : String(trimmed.prefix(120))
    }

    // MARK: Writing

    /// Starts a new session file and returns its summary.
    @discardableResult
    public func startSession(id: String = UUID().uuidString) throws -> HistorySession {
        let started = now()
        try lock.withLock {
            try ensureHeader(sessionID: id, at: started)
            var index = try loadIndexLocked()
            if index[id] == nil { index[id] = HistorySession(id: id, startedAt: started, updatedAt: started) }
            try saveIndexLocked(index)
        }
        notify(.sessionStarted(id))
        return session(id) ?? HistorySession(id: id, startedAt: started, updatedAt: started)
    }

    /// Appends a finished turn to its session, creating the session if needed.
    public func append(_ turn: HistoryTurn) throws {
        try lock.withLock {
            // Read the index first: a rebuild after the line is written would count this turn twice.
            var index = try loadIndexLocked()
            try ensureHeader(sessionID: turn.sessionID, at: turn.startedAt)
            try appendLine(Line(kind: .turn, turn: turn), to: turn.sessionID)
            var summary = index[turn.sessionID] ?? HistorySession(id: turn.sessionID, startedAt: turn.startedAt, updatedAt: turn.startedAt)
            summary.absorb(turn)
            index[turn.sessionID] = summary
            try saveIndexLocked(index)
        }
        notify(.turnAppended(sessionID: turn.sessionID, turnID: turn.id))
    }

    /// Appends a job hand-off (started, came back) to its session, creating the session if needed. Hand-offs don't
    /// count as turns; the session's last activity moves to it.
    public func append(_ handOff: HistoryHandOff) throws {
        try lock.withLock {
            var index = try loadIndexLocked()
            try ensureHeader(sessionID: handOff.sessionID, at: handOff.at)
            try appendLine(Line(kind: .handoff, handOff: handOff), to: handOff.sessionID)
            var summary = index[handOff.sessionID] ?? HistorySession(id: handOff.sessionID, startedAt: handOff.at, updatedAt: handOff.at)
            summary.updatedAt = max(summary.updatedAt, handOff.at)
            index[handOff.sessionID] = summary
            try saveIndexLocked(index)
        }
        notify(.handOffAppended(sessionID: handOff.sessionID, handOffID: handOff.id))
    }

    /// A session's hand-offs in the order they were written (a repeated id keeps the later line).
    public func handOffs(in sessionID: String) throws -> [HistoryHandOff] {
        try lock.withLock { try readSessionLocked(sessionID).handOffs }
    }

    /// Records what happened to a turn's narration after it was stored (the brain runtime's `recordOutcome`).
    public func recordNarration(_ note: String, forTurn turnID: String, in sessionID: String) throws {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL(for: sessionID).path) else { return }
            try appendLine(Line(kind: .narration, turnID: turnID, note: note), to: sessionID)
        }
    }

    /// Forgets one conversation: its session file, the lessons its turns saved (screenshots included) and their
    /// screenshot thumbnails in this folder's `thumbnails/` cache.
    public func deleteSession(_ id: String) throws {
        try lock.withLock {
            let url = fileURL(for: id)
            // Read the turn ids before the file goes: they name the lesson folders.
            let turnIDs = (try? readSessionLocked(id).turns.map(\.id)) ?? []
            try deleteLessonsLocked(sessionID: id, turnIDs: turnIDs)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            var index = try loadIndexLocked()
            index[id] = nil
            try saveIndexLocked(index)
        }
        notify(.sessionDeleted(id))
    }

    /// Removes the lesson folders of a deleted session (by its turn ids, and any lesson.json naming the session) and the
    /// lesson thumbnails cached under `thumbnails/` (`DrawingThumbnailer` keys them `<hash>-lesson-<turn>`).
    private func deleteLessonsLocked(sessionID: String, turnIDs: [String]) throws {
        let lessons = DrawingLessonStore(historyDirectory: directory)
        let named = lessons.all().filter { $0.sessionID == sessionID }.map(\.turnID)
        let turns = Set(turnIDs + named)
        guard !turns.isEmpty else { return }
        for turn in turns { try lessons.delete(turn) }
        let thumbnails = directory.appendingPathComponent("thumbnails", isDirectory: true)
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)) ?? []
        let suffixes = Set(turns.map { "-lesson-" + Self.safeName($0) + ".png" })
        for name in cached where suffixes.contains(where: { name.hasSuffix($0) }) {
            try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(name))
        }
    }

    /// Forgets every conversation.
    public func deleteAll() throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        notify(.cleared)
    }

    // MARK: Reading

    /// Session summaries, most recently active first.
    public func sessions(limit: Int? = nil) -> [HistorySession] {
        let index = (try? lock.withLock { try loadIndexLocked() }) ?? [:]
        let sorted = index.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    public func session(_ id: String) -> HistorySession? {
        (try? lock.withLock { try loadIndexLocked() })?[id]
    }

    /// The turns of one session, oldest first, with narration notes folded in.
    public func turns(in sessionID: String) throws -> [HistoryTurn] {
        try lock.withLock { try readSessionLocked(sessionID).turns }
    }

    /// The newest turns across sessions, newest first.
    public func recentTurns(limit: Int) -> [HistoryTurn] {
        guard limit > 0 else { return [] }
        var collected: [HistoryTurn] = []
        for session in sessions() {
            // Sessions come newest-active first: once the top `limit` are all newer than this session's last turn,
            // nothing older can make the list.
            if collected.count >= limit, session.updatedAt < collected[limit - 1].startedAt { break }
            collected += (try? turns(in: session.id)) ?? []
            collected.sort { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        }
        return Array(collected.prefix(limit))
    }

    /// Replies that drew something, newest first. Identical programs asked again are shown once.
    public func recentDrawings(limit: Int) -> [HistoryDrawing] {
        var seen = Set<String>()
        var drawings: [HistoryDrawing] = []
        for session in sessions() where session.drawingCount > 0 {
            for turn in ((try? turns(in: session.id)) ?? []).reversed() where turn.hasDrawing {
                let key = turn.program!.trimmingCharacters(in: .whitespacesAndNewlines)
                if seen.insert(key).inserted { drawings.append(HistoryDrawing(turn: turn)) }
            }
        }
        let lessons = DrawingLessonStore(historyDirectory: directory)
        return drawings.sorted { ($0.createdAt, $0.turnID) > ($1.createdAt, $1.turnID) }.prefix(limit).map { drawing in
            var drawing = drawing
            if lessons.exists(drawing.turnID) { drawing.lessonFolder = lessons.folder(for: drawing.turnID) }
            return drawing
        }
    }

    /// Turns whose words or reply contain every word of `query` (case- and accent-insensitive), newest first.
    public func search(_ query: String, limit: Int = 50) -> [HistoryTurn] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var hits: [HistoryTurn] = []
        for session in sessions() {
            for turn in (try? turns(in: session.id)) ?? [] {
                let haystack = (turn.words + " " + turn.replyText).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if terms.allSatisfy({ haystack.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }) {
                    hits.append(turn)
                }
            }
        }
        return Array(hits.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// Lines in a session file that could not be read (a crash mid-write, a hand edit).
    public func damagedLineCount(in sessionID: String) -> Int {
        (try? lock.withLock { try readSessionLocked(sessionID).damaged }) ?? 0
    }

    /// Rebuilds `index.json` from the session files and returns the summaries.
    @discardableResult
    public func rebuildIndex() throws -> [HistorySession] {
        try lock.withLock {
            let index = try scanSessionsLocked()
            try saveIndexLocked(index)
        }
        return sessions()
    }

    // MARK: Changes

    /// Every change from now on. Ends when the consuming task is cancelled.
    public func changes() -> AsyncStream<HistoryChange> {
        let (stream, continuation) = AsyncStream<HistoryChange>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        lock.withLock { listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    private func notify(_ change: HistoryChange) {
        let targets = lock.withLock { Array(listeners.values) }
        for continuation in targets { continuation.yield(change) }
    }

    // MARK: File format

    struct Line: Codable {
        enum Kind: String, Codable { case session, turn, narration, handoff }
        var kind: Kind
        var version: Int?
        var id: String?
        var at: Date?
        var turn: HistoryTurn?
        var turnID: String?
        var note: String?
        var handOff: HistoryHandOff?

        init(kind: Kind, version: Int? = nil, id: String? = nil, at: Date? = nil, turn: HistoryTurn? = nil,
             turnID: String? = nil, note: String? = nil, handOff: HistoryHandOff? = nil) {
            self.kind = kind
            self.version = version
            self.id = id
            self.at = at
            self.turn = turn
            self.turnID = turnID
            self.note = note
            self.handOff = handOff
        }

        private enum CodingKeys: String, CodingKey { case kind, version, id, at, turn, turnID = "turnId", note, handOff = "handoff" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            version = try c.decodeIfPresent(Int.self, forKey: .version)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            at = try c.decodeIfPresent(Date.self, forKey: .at)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            handOff = kind == .handoff ? try c.decode(HistoryHandOff.self, forKey: .handOff) : nil
            // A narration line names its turn by id under "turn"; a turn line carries the whole record there.
            if kind == .turn {
                turn = try c.decode(HistoryTurn.self, forKey: .turn)
            } else {
                turnID = try c.decodeIfPresent(String.self, forKey: .turn) ?? c.decodeIfPresent(String.self, forKey: .turnID)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(version, forKey: .version)
            try c.encodeIfPresent(id, forKey: .id)
            try c.encodeIfPresent(at, forKey: .at)
            if let turn { try c.encode(turn, forKey: .turn) } else { try c.encodeIfPresent(turnID, forKey: .turn) }
            try c.encodeIfPresent(note, forKey: .note)
            try c.encodeIfPresent(handOff, forKey: .handOff)
        }
    }

    struct IndexFile: Codable {
        var version: Int
        var sessions: [HistorySession]
    }

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter().string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let text = try container.decode(String.self)
            if let date = Self.dateFormatter().date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        return decoder
    }

    static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func ensureHeader(sessionID: String, at date: Date) throws {
        let url = fileURL(for: sessionID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        var data = try Self.encoder().encode(Line(kind: .session, version: Self.formatVersion, id: sessionID, at: date))
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func appendLine(_ line: Line, to sessionID: String) throws {
        var data = try Self.encoder().encode(line)
        data.append(0x0A)
        let handle = try FileHandle(forUpdating: fileURL(for: sessionID))
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A crash can leave a partial last line; start on a fresh line so this one stays readable.
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
    }

    struct SessionContents {
        var header: Line?
        var turns: [HistoryTurn]
        var damaged: Int
        var handOffs: [HistoryHandOff] = []
    }

    private func readSessionLocked(_ sessionID: String) throws -> SessionContents {
        let url = fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return SessionContents(header: nil, turns: [], damaged: 0) }
        let data = try Data(contentsOf: url)
        let decoder = Self.decoder()
        var header: Line?
        var turns: [HistoryTurn] = []
        var position: [String: Int] = [:]
        var handOffs: [HistoryHandOff] = []
        var handOffPosition: [String: Int] = [:]
        var damaged = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)) else {
                damaged += 1
                continue
            }
            switch line.kind {
            case .session:
                if header == nil { header = line }
            case .turn:
                guard let turn = line.turn else { continue }
                if let existing = position[turn.id] {
                    turns[existing] = turn
                } else {
                    position[turn.id] = turns.count
                    turns.append(turn)
                }
            case .narration:
                if let id = line.turnID, let at = position[id], let note = line.note { turns[at].narration = note }
            case .handoff:
                guard let handOff = line.handOff else { continue }
                if let existing = handOffPosition[handOff.id] {
                    handOffs[existing] = handOff
                } else {
                    handOffPosition[handOff.id] = handOffs.count
                    handOffs.append(handOff)
                }
            }
        }
        return SessionContents(header: header, turns: turns, damaged: damaged, handOffs: handOffs)
    }

    private func scanSessionsLocked() throws -> [String: HistorySession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var index: [String: HistorySession] = [:]
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            let contents = try readSessionLocked(name)
            let id = contents.header?.id ?? contents.turns.first?.sessionID ?? name
            guard Self.safeName(id) == name else { continue }
            let started = contents.header?.at ?? contents.turns.first?.startedAt ?? Date(timeIntervalSince1970: 0)
            index[id] = HistorySession.summarize(id: id, startedAt: started, turns: contents.turns)
        }
        return index
    }

    /// Read from disk every time: other processes (occtl, a second store in the app) append too.
    private func loadIndexLocked() throws -> [String: HistorySession] {
        var index: [String: HistorySession]
        if let data = try? Data(contentsOf: indexURL), let file = try? Self.decoder().decode(IndexFile.self, from: data),
           file.version == Self.formatVersion, indexMatchesFiles(file.sessions) {
            index = Dictionary(file.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            // Missing, unreadable or out of step with the session files: rebuild from the files.
            index = try scanSessionsLocked()
            if !index.isEmpty || FileManager.default.fileExists(atPath: indexURL.path) { try saveIndexLocked(index) }
        }
        return index
    }

    private func indexMatchesFiles(_ sessions: [HistorySession]) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        let names = Set(files.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) })
        return names == Set(sessions.map { Self.safeName($0.id) })
    }

    private func saveIndexLocked(_ index: [String: HistorySession]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = IndexFile(version: Self.formatVersion, sessions: index.values.sorted { $0.updatedAt > $1.updatedAt })
        try Self.encoder(pretty: true).encode(file).write(to: indexURL, options: .atomic)
    }
}
