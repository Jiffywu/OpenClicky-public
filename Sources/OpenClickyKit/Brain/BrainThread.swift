import Foundation

// The brain's conversation thread: the messages sent to the brain slot each turn (provider items included), the
// session they belong to, how they are kept on disk, and how bulky old parts (screenshots, document text) are pruned.

/// One message of the thread, with the bookkeeping the runtime needs around it.
public struct BrainThreadItem: Sendable, Hashable {
    /// Increases by one for every message added in the session; never reused, so a compaction that finishes late can
    /// tell whether the messages it folded are still there.
    public var seq: Int
    /// The turn the message belongs to (1-based). 0 for a compaction note.
    public var turn: Int
    public var at: Date
    public var message: ChatMessage
    /// User-turn messages: what the user said or typed, without the turn notes (for memory and compaction).
    public var words: String?
    /// User-turn messages: one line on where the user was ("14:05 · Safari · Pricing page").
    public var whereLine: String?
    /// A compaction note standing in for earlier messages.
    public var isSummary: Bool

    public init(seq: Int, turn: Int, at: Date, message: ChatMessage, words: String? = nil, whereLine: String? = nil,
                isSummary: Bool = false) {
        self.seq = seq
        self.turn = turn
        self.at = at
        self.message = message
        self.words = words
        self.whereLine = whereLine
        self.isSummary = isSummary
    }
}

/// One conversation with the brain: its thread and bookkeeping. A session ends after a quiet spell, on request, or
/// when the app starts a fresh one; its memory notes are written then.
public struct BrainSessionState: Sendable {
    public var id: String
    public var startedAt: Date
    public var lastTurnAt: Date?
    public var turnCount: Int
    public var items: [BrainThreadItem]
    public var nextSeq: Int
    /// Input tokens of the most recent model request (the thread's size as the provider counts it).
    public var lastInputTokens: Int
    /// Compaction is considered once `lastInputTokens` reaches this.
    public var nextCompactionCheck: Int
    public var compactions: Int
    /// "[App] …" notes waiting for the next turn.
    public var pendingAppNotes: [String]
    /// The session's memory notes were written (or it was ended without any).
    public var ended: Bool

    public init(id: String = UUID().uuidString, startedAt: Date = Date(), compactionThreshold: Int) {
        self.id = id
        self.startedAt = startedAt
        self.turnCount = 0
        self.items = []
        self.nextSeq = 1
        self.lastInputTokens = 0
        self.nextCompactionCheck = compactionThreshold
        self.compactions = 0
        self.pendingAppNotes = []
        self.ended = false
    }

    public var messages: [ChatMessage] { items.map(\.message) }

    /// Adds a message to the thread and returns its sequence number.
    @discardableResult
    public mutating func append(_ message: ChatMessage, at date: Date, words: String? = nil, whereLine: String? = nil) -> Int {
        let seq = nextSeq
        nextSeq += 1
        items.append(BrainThreadItem(seq: seq, turn: turnCount, at: date, message: message, words: words, whereLine: whereLine))
        return seq
    }

    /// Screenshots and other images currently in the thread.
    public var imageCount: Int {
        items.reduce(0) { total, item in total + item.message.content.filter(\.isImage).count }
    }

    /// The thread as memory should read it: user turns as their words alone (no turn notes or screenshots),
    /// everything else as is. Messages from before the session started (a conversation seeded from the history) were
    /// noted when they happened and are left out.
    public var conversationForMemory: [ChatMessage] {
        items.filter { $0.at >= startedAt || $0.isSummary }.compactMap { item in
            guard item.message.role == .user else { return item.message }
            if item.isSummary { return item.message }
            guard let words = item.words?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
            return .user(.text(words))
        }
    }

    /// Whether the user said or typed anything this session.
    public var userSpoke: Bool {
        items.contains { $0.at >= startedAt && !($0.words ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension ContentPart {
    var isImage: Bool { if case .image = self { true } else { false } }
}

// MARK: - Pruning

/// Keeps the newest few screenshots (and documents) in the thread and replaces older ones with short text, so the
/// thread stays small.
///
/// Every replacement changes the conversation's prefix, which costs a prompt-cache rewrite from that point on, so
/// pruning waits until `slack` extra parts have piled up and then prunes them all at once, instead of nibbling one
/// part per turn.
public struct BrainPruningPolicy: Sendable, Hashable {
    public var keepImages: Int
    public var imageSlack: Int
    /// Document texts (the open page or file the turn notes carried) to keep in full.
    public var keepDocuments: Int
    public var documentSlack: Int

    public init(keepImages: Int = 3, imageSlack: Int = 3, keepDocuments: Int = 1, documentSlack: Int = 2) {
        self.keepImages = max(0, keepImages)
        self.imageSlack = max(0, imageSlack)
        self.keepDocuments = max(0, keepDocuments)
        self.documentSlack = max(0, documentSlack)
    }

    /// What replaces a pruned screenshot.
    public static let imageStandIn = "[Screenshot removed to save room; the newest screenshots are further down.]"
    /// What replaces a pruned document text.
    public static let documentStandIn = BrainTurnNotes.documentMarker + " removed to save room.]"

    /// Prunes `items` in place; returns how many parts were replaced.
    @discardableResult
    public func prune(_ items: inout [BrainThreadItem]) -> Int {
        var images: [(item: Int, part: Int)] = []
        var documents: [(item: Int, part: Int)] = []
        for (itemIndex, item) in items.enumerated() where item.message.role == .user || item.message.role == .tool {
            for (partIndex, part) in item.message.content.enumerated() {
                switch part {
                case .image: images.append((itemIndex, partIndex))
                case .text(let text):
                    if text.hasPrefix(BrainTurnNotes.documentMarker), text != Self.documentStandIn { documents.append((itemIndex, partIndex)) }
                }
            }
        }
        var replaced = 0
        if images.count > keepImages + imageSlack {
            for location in images.dropLast(keepImages) {
                items[location.item].message.content[location.part] = .text(Self.imageStandIn)
                replaced += 1
            }
        }
        if documents.count > keepDocuments + documentSlack {
            for location in documents.dropLast(keepDocuments) {
                items[location.item].message.content[location.part] = .text(Self.documentStandIn)
                replaced += 1
            }
        }
        return replaced
    }
}

// MARK: - Persistence

/// Keeps sessions under `~/Library/Application Support/OpenClicky/Brain/<session>/`: `thread.json` (the thread and
/// bookkeeping, rewritten after every turn) and `turns.jsonl` (one line per model round, interruption, compaction…).
///
/// Screenshots are never written to disk: saved threads hold a short stand-in where each image was. A session picked
/// up after a restart therefore has no old screenshots, which costs one prompt-cache rewrite and nothing else.
public struct BrainSessionStore: Sendable {
    public let root: URL

    public init(root: URL = BrainSessionStore.defaultRoot) { self.root = root }

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("OpenClicky/Brain", isDirectory: true)
    }

    public static let savedImageStandIn = "[Screenshot not kept on disk.]"

    public func directory(for sessionID: String) -> URL { root.appendingPathComponent(Self.safeName(sessionID), isDirectory: true) }
    public func threadURL(for sessionID: String) -> URL { directory(for: sessionID).appendingPathComponent("thread.json") }
    public func logURL(for sessionID: String) -> URL { directory(for: sessionID).appendingPathComponent("turns.jsonl") }

    public func save(_ state: BrainSessionState) throws {
        try makeDirectory(directory(for: state.id))
        let data = try Self.encode(state).jsonData()
        try data.write(to: threadURL(for: state.id), options: [.atomic])
    }

    public func load(_ sessionID: String) throws -> BrainSessionState {
        let data = try Data(contentsOf: threadURL(for: sessionID))
        return try Self.decode(JSONValue.parse(String(decoding: data, as: UTF8.self)))
    }

    /// The session with the newest activity, if any can be read. Every turn, ending and seeding rewrites
    /// `thread.json`, so the newest file is the newest activity: only it is decoded (or the next newest when it can't
    /// be read), not every session ever kept.
    public func latest() -> BrainSessionState? {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: root.path) else { return nil }
        let dated: [(name: String, modified: Date)] = names.compactMap { name in
            guard let modified = (try? files.attributesOfItem(atPath: threadURL(for: name).path))?[.modificationDate] as? Date else {
                return nil
            }
            return (name, modified)
        }
        for entry in dated.sorted(by: { $0.modified > $1.modified }) {
            if let state = try? load(entry.name) { return state }
        }
        return nil
    }

    /// Appends one JSON line to the session's turn log. Failures are ignored: the log is for people, not the runtime.
    public func appendLog(_ entry: JSONValue, sessionID: String) {
        let url = logURL(for: sessionID)
        guard (try? makeDirectory(directory(for: sessionID))) != nil else { return }
        var line = (try? entry.jsonData()) ?? Data()
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func safeName(_ id: String) -> String {
        let allowed = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        let name = String(String.UnicodeScalarView(allowed))
        return name.isEmpty ? "session" : String(name.prefix(80))
    }

    // MARK: Encoding

    static func encode(_ state: BrainSessionState) -> JSONValue {
        var object: [String: JSONValue] = [
            "version": 1,
            "session_id": .string(state.id),
            "started_at": .number(state.startedAt.timeIntervalSince1970),
            "turn_count": .number(Double(state.turnCount)),
            "next_seq": .number(Double(state.nextSeq)),
            "last_input_tokens": .number(Double(state.lastInputTokens)),
            "next_compaction_check": .number(Double(state.nextCompactionCheck)),
            "compactions": .number(Double(state.compactions)),
            "pending_app_notes": .array(state.pendingAppNotes.map { .string($0) }),
            "ended": .bool(state.ended),
            "items": .array(state.items.map(encode)),
        ]
        if let last = state.lastTurnAt { object["last_turn_at"] = .number(last.timeIntervalSince1970) }
        return .object(object)
    }

    static func encode(_ item: BrainThreadItem) -> JSONValue {
        let message = item.message
        var object: [String: JSONValue] = [
            "seq": .number(Double(item.seq)),
            "turn": .number(Double(item.turn)),
            "at": .number(item.at.timeIntervalSince1970),
            "role": .string(message.role.rawValue),
            "content": .array(message.content.map { part in
                switch part {
                case .text(let text): return ["type": "text", "text": .string(text)]
                case .image(_, let mime): return ["type": "image", "mime": .string(mime)]
                }
            }),
        ]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = .array(message.toolCalls.map { ["id": .string($0.id), "name": .string($0.name), "arguments": .string($0.arguments)] })
        }
        if let id = message.toolCallID { object["tool_call_id"] = .string(id) }
        if !message.providerItems.isEmpty { object["provider_items"] = .array(message.providerItems) }
        if let dialect = message.providerDialect { object["provider_dialect"] = .string(dialect) }
        if let phase = message.phase { object["phase"] = .string(phase) }
        if message.isError { object["is_error"] = true }
        if let words = item.words { object["words"] = .string(words) }
        if let line = item.whereLine { object["where"] = .string(line) }
        if item.isSummary { object["summary"] = true }
        return .object(object)
    }

    static func decode(_ json: JSONValue) throws -> BrainSessionState {
        guard let id = json["session_id"]?.stringValue, let started = json["started_at"]?.doubleValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var state = BrainSessionState(id: id, startedAt: Date(timeIntervalSince1970: started),
                                      compactionThreshold: json["next_compaction_check"]?.intValue ?? 0)
        state.lastTurnAt = json["last_turn_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        state.turnCount = json["turn_count"]?.intValue ?? 0
        state.lastInputTokens = json["last_input_tokens"]?.intValue ?? 0
        state.compactions = json["compactions"]?.intValue ?? 0
        state.pendingAppNotes = json["pending_app_notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        state.ended = json["ended"]?.boolValue ?? false
        state.items = (json["items"]?.arrayValue ?? []).compactMap(decodeItem)
        state.nextSeq = max(json["next_seq"]?.intValue ?? 1, (state.items.map(\.seq).max() ?? 0) + 1)
        return state
    }

    static func decodeItem(_ json: JSONValue) -> BrainThreadItem? {
        guard let roleText = json["role"]?.stringValue, let role = ChatMessage.Role(rawValue: roleText),
              let seq = json["seq"]?.intValue else { return nil }
        let content: [ContentPart] = (json["content"]?.arrayValue ?? []).compactMap { part in
            switch part["type"]?.stringValue {
            case "text": return part["text"]?.stringValue.map(ContentPart.text)
            case "image": return .text(savedImageStandIn)
            default: return nil
            }
        }
        let calls: [ToolCall] = (json["tool_calls"]?.arrayValue ?? []).compactMap { call in
            guard let id = call["id"]?.stringValue, let name = call["name"]?.stringValue else { return nil }
            return ToolCall(id: id, name: name, arguments: call["arguments"]?.stringValue ?? "{}")
        }
        let message = ChatMessage(role: role, content: content, toolCalls: calls, toolCallID: json["tool_call_id"]?.stringValue,
                                  providerItems: json["provider_items"]?.arrayValue ?? [],
                                  providerDialect: json["provider_dialect"]?.stringValue, phase: json["phase"]?.stringValue,
                                  isError: json["is_error"]?.boolValue ?? false)
        return BrainThreadItem(seq: seq, turn: json["turn"]?.intValue ?? 0,
                               at: Date(timeIntervalSince1970: json["at"]?.doubleValue ?? 0), message: message,
                               words: json["words"]?.stringValue, whereLine: json["where"]?.stringValue,
                               isSummary: json["summary"]?.boolValue ?? false)
    }
}
