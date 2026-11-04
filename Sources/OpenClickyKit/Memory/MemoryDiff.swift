import Foundation

/// The changes the session-end memory writer proposes. `MemoryStore.apply(_:)` checks each one like a direct save:
/// secrets are scrubbed, near-duplicates skipped and the budget enforced.
public struct MemoryDiff: Sendable, Hashable {
    public struct ProfileLine: Sendable, Hashable {
        public var section: String
        public var text: String

        public init(section: String, text: String) {
            self.section = section
            self.text = text
        }
    }

    public struct HowTo: Sendable, Hashable {
        public var title: String
        public var steps: String

        public init(title: String, steps: String) {
            self.title = title
            self.steps = steps
        }
    }

    public struct NewMemory: Sendable, Hashable {
        public var text: String
        public var kind: MemoryKind

        public init(text: String, kind: MemoryKind = .fact) {
            self.text = text
            self.kind = kind
        }
    }

    /// One to three sentences on what the session was about; saved as a `.session` memory.
    public var sessionNote: String?
    public var profileAdd: [ProfileLine]
    public var profileRemove: [ProfileLine]
    public var standingAdd: [String]
    public var standingRemove: [String]
    public var howTos: [HowTo]
    public var memories: [NewMemory]
    /// Ids of memories that are now wrong or that the user asked to drop.
    public var forget: [String]

    public init(sessionNote: String? = nil, profileAdd: [ProfileLine] = [], profileRemove: [ProfileLine] = [],
                standingAdd: [String] = [], standingRemove: [String] = [], howTos: [HowTo] = [],
                memories: [NewMemory] = [], forget: [String] = []) {
        self.sessionNote = sessionNote
        self.profileAdd = profileAdd
        self.profileRemove = profileRemove
        self.standingAdd = standingAdd
        self.standingRemove = standingRemove
        self.howTos = howTos
        self.memories = memories
        self.forget = forget
    }

    public var isEmpty: Bool {
        sessionNote == nil && profileAdd.isEmpty && profileRemove.isEmpty && standingAdd.isEmpty && standingRemove.isEmpty
            && howTos.isEmpty && memories.isEmpty && forget.isEmpty
    }

    /// Caps on how much one session may change, so a confused reply can't flood memory.
    public struct Limits: Sendable, Hashable {
        public var profileAdd = 8
        public var profileRemove = 8
        public var standing = 3
        public var howTos = 2
        public var memories = 6
        public var forget = 6

        public init() {}
    }

    /// Reads the writer's JSON reply. Tolerates code fences and text around the object, missing fields, and a few
    /// spellings of each key. Throws when there is no JSON object at all.
    public static func parse(_ reply: String, limits: Limits = Limits()) throws -> MemoryDiff {
        guard let object = jsonObject(in: reply) else { throw MemoryWriterError.unreadableReply(MemorySecretScrubber.scrub(String(reply.prefix(120))).text) }
        func strings(_ keys: String...) -> [String] {
            for key in keys {
                if let array = object[key]?.arrayValue { return array.compactMap { $0.stringValue ?? $0["text"]?.stringValue }.compactMap(clean) }
                if let single = object[key]?.stringValue, let text = clean(single) { return [text] }
            }
            return []
        }
        func profileLines(_ keys: String...) -> [ProfileLine] {
            for key in keys {
                guard let array = object[key]?.arrayValue else { continue }
                return array.compactMap { item in
                    guard let text = clean(item["line"]?.stringValue ?? item["text"]?.stringValue ?? "") else { return nil }
                    let section = clean(item["section"]?.stringValue ?? "") ?? "Notes"
                    return ProfileLine(section: section, text: text)
                }
            }
            return []
        }
        var diff = MemoryDiff()
        diff.sessionNote = (object["session_note"] ?? object["note"])?.stringValue.flatMap(clean)
        diff.profileAdd = Array(profileLines("profile_add", "profile_additions").prefix(limits.profileAdd))
        diff.profileRemove = Array(profileLines("profile_remove", "profile_removals").prefix(limits.profileRemove))
        diff.standingAdd = Array(strings("standing_add", "standing_context_add").prefix(limits.standing))
        diff.standingRemove = Array(strings("standing_remove", "standing_context_remove").prefix(limits.standing))
        diff.howTos = Array((object["how_tos"] ?? object["howtos"])?.arrayValue?.compactMap { item -> HowTo? in
            guard let title = clean(item["title"]?.stringValue ?? "") else { return nil }
            let steps: String
            if let list = item["steps"]?.arrayValue {
                steps = list.compactMap(\.stringValue).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            } else {
                steps = item["steps"]?.stringValue ?? ""
            }
            return HowTo(title: title, steps: steps.trimmingCharacters(in: .whitespacesAndNewlines))
        }.prefix(limits.howTos) ?? [])
        diff.memories = Array((object["memories"]?.arrayValue ?? []).compactMap { item -> NewMemory? in
            guard let text = clean(item.stringValue ?? item["text"]?.stringValue ?? "") else { return nil }
            let kind = item["kind"]?.stringValue.flatMap(MemoryKind.init(rawValue:)).flatMap { $0 == .session ? nil : $0 } ?? .fact
            return NewMemory(text: text, kind: kind)
        }.prefix(limits.memories))
        diff.forget = Array(strings("forget", "forget_ids").prefix(limits.forget))
        return diff
    }

    private static func clean(_ text: String) -> String? {
        let line = MemoryText.oneLine(text)
        return line.isEmpty || line.lowercased() == "null" || line.lowercased() == "none" ? nil : line
    }

    /// The outermost `{…}` in the reply, parsed.
    static func jsonObject(in reply: String) -> JSONValue? {
        if let whole = try? JSONValue.parse(reply.trimmingCharacters(in: .whitespacesAndNewlines)), whole.objectValue != nil { return whole }
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        guard let value = try? JSONValue.parse(String(reply[start...end])), value.objectValue != nil else { return nil }
        return value
    }
}

/// What applying a diff did.
public struct MemoryApplyReport: Sendable, Hashable {
    public struct Skip: Sendable, Hashable {
        public var text: String
        public var reason: String
    }

    public var added: [MemoryEntry] = []
    public var removed: [MemoryEntry] = []
    public var skipped: [Skip] = []

    public init() {}

    public var changedAnything: Bool { !added.isEmpty || !removed.isEmpty }
}

public enum MemoryWriterError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadableReply(String)
    /// The model hit the token cap before finishing the diff.
    case truncatedReply(maxOutputTokens: Int)

    public var description: String {
        switch self {
        case .unreadableReply(let start): "The memory writer's reply had no JSON object (it began: \(start))"
        case .truncatedReply(let cap): "The memory writer's reply was cut off at its \(cap)-token limit"
        }
    }
}
