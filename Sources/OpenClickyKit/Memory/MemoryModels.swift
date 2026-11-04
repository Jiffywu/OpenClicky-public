import Foundation

// OpenClicky's memory of the user. Everything lives on this Mac under
// `~/Library/Application Support/OpenClicky/Memory/` in files a person can read and edit:
//
//   about-the-user.md      the profile, in markdown sections            (MemoryProfile)
//   standing-context.md    standing requests that apply to every chat   (one "- " line each)
//   how-tos.md             things learned about doing tasks for them    ("## title" + steps)
//   memories.jsonl         individual dated memories and session notes  (MemoryRecord, one per line)

/// What an individual memory is.
public enum MemoryKind: String, Codable, Sendable, CaseIterable {
    /// Something true about the user or their world ("their sister Ana lives in Lisbon").
    case fact
    /// How they like things done ("prefers short answers").
    case preference
    /// Something that happened or will happen, worth its date ("starts the new job on 2026-11-03").
    case event
    /// A short note written at the end of a voice session.
    case session
}

/// Who wrote a memory.
public enum MemorySource: String, Codable, Sendable, CaseIterable {
    /// The brain's `save_memory` tool during a conversation.
    case voice
    /// Typed in OpenClicky's Memory settings.
    case user
    /// `occtl memory add`.
    case cli
    /// The memory writer at the end of a session.
    case session
    /// Learned while a background agent did a job.
    case agent
}

/// One line of `memories.jsonl`.
public struct MemoryRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var kind: MemoryKind
    public var createdAt: Date
    public var updatedAt: Date?
    public var source: MemorySource
    public var tags: [String]?
    /// The voice session that produced it, when there was one.
    public var sessionID: String?

    public init(id: String, text: String, kind: MemoryKind = .fact, createdAt: Date, updatedAt: Date? = nil,
                source: MemorySource, tags: [String]? = nil, sessionID: String? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.tags = tags
        self.sessionID = sessionID
    }

    /// The date ranking uses: the last time the memory was written.
    public var date: Date { updatedAt ?? createdAt }

    enum CodingKeys: String, CodingKey {
        case id, text, kind, source, tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sessionID = "session"
    }

    // Lenient decoding: the file is user-editable, so an unknown kind or source falls back instead of failing the line.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(MemoryKind.init(rawValue:)) } ?? .fact
        source = (try? container.decodeIfPresent(String.self, forKey: .source)).flatMap { $0.flatMap(MemorySource.init(rawValue:)) } ?? .user
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
    }
}

/// A learned how-to: a titled set of steps.
public struct MemoryHowTo: Sendable, Hashable, Identifiable {
    public var title: String
    public var steps: String

    public init(title: String, steps: String) {
        self.title = title
        self.steps = steps
    }

    public var id: String { MemoryID.make(prefix: "h", MemoryText.normalized(title)) }
}

/// Where an item lives.
public enum MemoryPlace: Sendable, Hashable {
    case memory(MemoryKind)
    case standing
    case howTo
    case profile(section: String)

    /// Short wording for lists and tool results: "fact", "standing", "how-to", "profile: Goals".
    public var label: String {
        switch self {
        case .memory(let kind): kind.rawValue
        case .standing: "standing"
        case .howTo: "how-to"
        case .profile(let section): "profile: \(section)"
        }
    }
}

/// Any one thing OpenClicky remembers, whatever file it lives in. Ids are stable: memories keep the id they were
/// saved with, and the rest are derived from their text (so editing a line by hand gives it a new id).
public struct MemoryEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var place: MemoryPlace
    /// Memories carry dates; profile lines, standing context and how-tos do not.
    public var date: Date?

    public init(id: String, text: String, place: MemoryPlace, date: Date? = nil) {
        self.id = id
        self.text = text
        self.place = place
        self.date = date
    }
}

/// Size limits that keep memory small enough to read, to send with every turn, and to keep on disk.
public struct MemoryBudget: Sendable, Hashable {
    /// Individual memories kept. Past this, the oldest session notes go first, then the oldest of the rest.
    public var maxMemories: Int
    /// Longer memories are cut at a word boundary.
    public var maxMemoryCharacters: Int
    public var maxStandingLines: Int
    public var maxStandingCharacters: Int
    /// Past this, the oldest how-to (the first in the file) goes.
    public var maxHowTos: Int
    public var maxHowToCharacters: Int
    /// The whole profile file. Past this, the oldest lines of the "Right now" sections go; other lines are kept and
    /// further additions are refused.
    public var maxProfileCharacters: Int
    public var maxProfileLineCharacters: Int

    public init(maxMemories: Int = 400, maxMemoryCharacters: Int = 500, maxStandingLines: Int = 30,
                maxStandingCharacters: Int = 300, maxHowTos: Int = 40, maxHowToCharacters: Int = 1_500,
                maxProfileCharacters: Int = 12_000, maxProfileLineCharacters: Int = 300) {
        self.maxMemories = maxMemories
        self.maxMemoryCharacters = maxMemoryCharacters
        self.maxStandingLines = maxStandingLines
        self.maxStandingCharacters = maxStandingCharacters
        self.maxHowTos = maxHowTos
        self.maxHowToCharacters = maxHowToCharacters
        self.maxProfileCharacters = maxProfileCharacters
        self.maxProfileLineCharacters = maxProfileLineCharacters
    }
}

/// Everything in the memory folder, read at one moment.
public struct MemorySnapshot: Sendable, Hashable {
    public var profile: MemoryProfile
    public var standing: [String]
    public var howTos: [MemoryHowTo]
    public var memories: [MemoryRecord]

    public init(profile: MemoryProfile = .template, standing: [String] = [], howTos: [MemoryHowTo] = [], memories: [MemoryRecord] = []) {
        self.profile = profile
        self.standing = standing
        self.howTos = howTos
        self.memories = memories
    }

    /// True when nothing is remembered: the profile has no items or text under its sections, and the rest is empty.
    public var isEmpty: Bool {
        standing.isEmpty && howTos.isEmpty && memories.isEmpty
            && profile.sections.allSatisfy { profile.content(of: $0).isEmpty }
    }

    /// Every item: standing context, profile lines, how-tos, then memories newest first.
    public var entries: [MemoryEntry] {
        standingEntries + profileEntries + howToEntries + memoryEntries
    }

    public var standingEntries: [MemoryEntry] {
        standing.map { MemoryEntry(id: MemoryID.standing($0), text: $0, place: .standing) }
    }

    public var profileEntries: [MemoryEntry] {
        profile.bullets.map { MemoryEntry(id: $0.id, text: $0.text, place: .profile(section: $0.section)) }
    }

    public var howToEntries: [MemoryEntry] {
        howTos.map { MemoryEntry(id: $0.id, text: $0.steps.isEmpty ? $0.title : "\($0.title): \($0.steps)", place: .howTo) }
    }

    public var memoryEntries: [MemoryEntry] {
        memoriesNewestFirst.map { MemoryEntry(id: $0.id, text: $0.text, place: .memory($0.kind), date: $0.date) }
    }

    /// Memories by date, newest first. Saves within the same second keep file order reversed (the later line is newer).
    public var memoriesNewestFirst: [MemoryRecord] {
        memories.enumerated().sorted { lhs, rhs in
            lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset > rhs.offset
        }.map(\.element)
    }

    public func entry(id: String) -> MemoryEntry? { entries.first { $0.id == id } }
}

/// Stable short ids.
public enum MemoryID {
    /// `prefix-` and 8 hex digits of a 64-bit FNV-1a hash of `text`.
    public static func make(prefix: String, _ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "\(prefix)-\(String(format: "%08x", UInt32(truncatingIfNeeded: hash ^ (hash >> 32))))"
    }

    public static func standing(_ line: String) -> String { make(prefix: "s", MemoryText.normalized(line)) }

    public static func profile(section: String, text: String) -> String {
        make(prefix: "p", MemoryText.normalized(section) + "\n" + MemoryText.normalized(text))
    }

    /// A fresh random id for a new memory: `m-` and 8 hex digits.
    public static func newMemoryID(avoiding taken: Set<String>) -> String {
        while true {
            let id = "m-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            if !taken.contains(id) { return id }
        }
    }
}

/// Text helpers shared by the store, the ranker and the writer.
public enum MemoryText {
    /// Lowercased, whitespace collapsed, trailing sentence punctuation dropped: for duplicate checks and ids.
    public static func normalized(_ text: String) -> String {
        var collapsed = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = collapsed.last, ".!;,".contains(last) { collapsed.removeLast() }
        return collapsed
    }

    /// One line, trimmed: newlines and runs of spaces become single spaces.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts `text` to at most `limit` characters at a word boundary, ending with "…" when it cut.
    public static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let head = text.prefix(limit - 1)
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return String(head) + "…"
    }

    /// Word-set similarity (Jaccard over ranking terms), 0…1. Used to spot near-duplicates.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = Set(MemoryRanker.terms(a)), right = Set(MemoryRanker.terms(b))
        guard !left.isEmpty || !right.isEmpty else { return normalized(a) == normalized(b) ? 1 : 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// True when two lines say the same thing (equal after normalizing, or nearly the same words).
    public static func isDuplicate(_ a: String, _ b: String, threshold: Double = 0.8) -> Bool {
        normalized(a) == normalized(b) || similarity(a, b) >= threshold
    }
}
