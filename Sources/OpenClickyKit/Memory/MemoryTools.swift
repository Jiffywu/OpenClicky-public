import Foundation

/// What a memory tool call produced, for the brain runtime's tool runner.
public struct MemoryToolResult: Sendable, Hashable {
    /// JSON text for the model (the tool message content).
    public var output: String
    public var succeeded: Bool
    /// A short word for the notch once done: "remembered", "forgot", "checked".
    public var status: String
    /// Reads (`recall_memory`) need another model round with their output; actions don't.
    public var needsModelRound: Bool
}

/// The brain's memory tools: `save_memory`, `recall_memory` and `forget_memory`, backed by the local `MemoryStore`.
/// (`clicky_memory` is a kept agent's memory, in `AgentTools`.)
///
/// Usage from a tool runner: offer `MemoryTools.specs` with the turn's other tools; for each call, `handle(call)`
/// returns a result for memory tools and nil for anything else.
public struct MemoryTools: Sendable {
    public static let save = "save_memory"
    public static let recall = "recall_memory"
    public static let forget = "forget_memory"
    /// Other names models trained on HeyClicky-like tools may use.
    public static let aliases: [String: String] = ["recall": recall, "remember": save]

    public let store: MemoryStore
    public var ranker: MemoryRanker
    /// Earlier chats `recall_memory` also looks through (the conversation history: what the user asked and what was
    /// said back); nil searches memory only.
    public var history: HistoryStore?
    /// How many recent turns of the history a recall scans.
    public var historyScanLimit: Int

    public init(store: MemoryStore, ranker: MemoryRanker = MemoryRanker(), history: HistoryStore? = nil, historyScanLimit: Int = 600) {
        self.store = store
        self.ranker = ranker
        self.history = history
        self.historyScanLimit = historyScanLimit
    }

    /// The canonical tool name for `name`, or nil when it isn't a memory tool.
    public static func canonicalName(_ name: String) -> String? {
        if [save, recall, forget].contains(name) { return name }
        return aliases[name]
    }

    /// What the notch shows while a memory tool runs.
    public static func runningStatus(for name: String) -> String? {
        switch canonicalName(name) {
        case save: "Saving to memory…"
        case recall: "Checking what I remember…"
        case forget: "Forgetting…"
        default: nil
        }
    }

    // MARK: - Specs

    public static var specs: [ToolSpec] { [saveSpec, recallSpec, forgetSpec] }

    public static let saveSpec = ToolSpec(
        name: save,
        description: """
            Keep something about the user for future conversations. Use it when they ask you to remember something, \
            or share a lasting fact or preference that will clearly matter later. One short third-person line per \
            call ("Prefers metric units"). Use kind "standing" only for an instruction they want followed in every \
            conversation from now on. Never save passwords, keys, codes or other secrets; they are refused.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "What to remember, one short line."],
                "kind": [
                    "type": "string", "enum": ["fact", "preference", "event", "standing"],
                    "description": "fact (default), preference, event (dated happening), or standing (an always-on instruction).",
                ],
            ],
            "required": ["text"],
            "additionalProperties": false,
        ])

    public static let recallSpec = ToolSpec(
        name: recall,
        description: """
            Look through what you remember about the user: saved memories, notes from earlier conversations, their \
            profile, standing context and learned how-tos, and what was said in earlier chats. Use it when they refer \
            to something from before ("like last time", "what did you tell me about…", "my sister") and it isn't \
            already in your memory section. Returns the best matches, memories with ids.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Keywords to look for. Empty returns the most recent memories."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 10, "description": "How many results, 5 by default."],
            ],
            "required": ["query"],
            "additionalProperties": false,
        ])

    public static let forgetSpec = ToolSpec(
        name: forget,
        description: """
            Forget something you remember about the user, when they ask you to or it is plainly wrong. Pass the id \
            from your memory section or from recall_memory; or pass a query, and if several things match you get them \
            back to choose from.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The id of the item to forget, such as m-1a2b3c4d."],
                "query": ["type": "string", "description": "What to forget, in words, when you don't have the id."],
            ],
            "additionalProperties": false,
        ])

    // MARK: - Handling

    /// Runs a memory tool call. Returns nil when the call is not for a memory tool.
    public func handle(_ call: ToolCall) -> MemoryToolResult? { handle(name: call.name, arguments: call.arguments) }

    public func handle(name: String, arguments: String) -> MemoryToolResult? {
        guard let tool = Self.canonicalName(name) else { return nil }
        let parsed = arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? JSONValue.object([:]) : try? JSONValue.parse(arguments)
        guard let args = parsed, args.objectValue != nil else {
            return failure("the arguments were not a JSON object", tool: tool)
        }
        do {
            switch tool {
            case Self.save: return try runSave(args)
            case Self.recall: return try runRecall(args)
            default: return try runForget(args)
            }
        } catch {
            return failure("memory could not be read or written: \(error.localizedDescription)", tool: tool)
        }
    }

    private func runSave(_ args: JSONValue) throws -> MemoryToolResult {
        guard let text = args["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("text is required", tool: Self.save)
        }
        let kindName = args["kind"]?.stringValue ?? "fact"
        let outcome: MemorySaveOutcome
        if kindName == "standing" {
            outcome = try store.addStanding(text)
        } else {
            let kind = MemoryKind(rawValue: kindName).flatMap { $0 == .session ? nil : $0 } ?? .fact
            outcome = try store.save(text, kind: kind, source: .voice)
        }
        switch outcome {
        case .saved(let entry):
            return result(["status": "saved", "id": .string(entry.id), "text": .string(entry.text), "where": .string(entry.place.label)],
                          status: "remembered")
        case .alreadyKnown(let entry):
            return result(["status": "already_known", "id": .string(entry.id), "text": .string(entry.text)], status: "remembered")
        case .refused(let reason):
            return result(["status": "refused", "message": .string(reason)], succeeded: false, status: "not saved")
        }
    }

    private func runRecall(_ args: JSONValue) throws -> MemoryToolResult {
        let query = args["query"]?.stringValue ?? ""
        let limit = min(10, max(1, args["limit"]?.intValue ?? 5))
        let matches = try store.recall(query, limit: limit, ranker: ranker)
        let results: [JSONValue] = matches.map { match in
            var item: [String: JSONValue] = [
                "id": .string(match.entry.id),
                "text": .string(MemoryPromptBuilder.safe(match.entry.text)),
                "where": .string(match.entry.place.label),
            ]
            if let date = match.entry.date { item["date"] = .string(MemoryWriter.day(date)) }
            return .object(item)
        }
        var output: [String: JSONValue] = ["status": "ok", "results": .array(results)]
        let chats = earlierChats(query, limit: 3)
        if !chats.isEmpty { output["earlier_chats"] = .array(chats) }
        if results.isEmpty, chats.isEmpty { output["note"] = "nothing remembered matches that" }
        return MemoryToolResult(output: JSONValue.object(output).jsonString(), succeeded: true, status: "checked", needsModelRound: true)
    }

    /// Turns from the history whose words or reply share the most keywords with `query` (at least half of them),
    /// best first, then newest: when it was, what the user said and what was said back.
    func earlierChats(_ query: String, limit: Int) -> [JSONValue] {
        guard let history, limit > 0 else { return [] }
        let terms = Set(MemoryRanker.terms(query))
        guard !terms.isEmpty else { return [] }
        let needed = max(1, (terms.count + 1) / 2)
        // "Forget everything" covers what was said before it too, though the history keeps it until cleared.
        let forgottenAt = store.forgottenAt ?? .distantPast
        var scored: [(turn: HistoryTurn, score: Int)] = []
        for turn in history.recentTurns(limit: historyScanLimit) where turn.outcome == .completed && turn.startedAt > forgottenAt {
            let reply = turn.replyText
            guard !turn.words.isEmpty || !reply.isEmpty else { continue }
            let score = terms.intersection(MemoryRanker.terms(turn.words + " " + reply)).count
            if score >= needed { scored.append((turn, score)) }
        }
        scored.sort { ($0.score, $0.turn.startedAt) > ($1.score, $1.turn.startedAt) }
        return scored.prefix(limit).map { entry in
            var item: [String: JSONValue] = ["date": .string(MemoryWriter.day(entry.turn.startedAt)),
                                             "how": .string(entry.turn.source.rawValue)]
            if !entry.turn.words.isEmpty { item["user"] = .string(MemoryText.clipped(MemoryPromptBuilder.safe(entry.turn.words), to: 240)) }
            if !entry.turn.replyText.isEmpty { item["reply"] = .string(MemoryText.clipped(MemoryPromptBuilder.safe(entry.turn.replyText), to: 360)) }
            return .object(item)
        }
    }

    private func runForget(_ args: JSONValue) throws -> MemoryToolResult {
        if let id = args["id"]?.stringValue, !id.isEmpty {
            guard let entry = try store.forget(id: id) else {
                return result(["status": "not_found", "message": "nothing has that id"], succeeded: false, status: "not found")
            }
            return forgotten(entry)
        }
        guard let query = args["query"]?.stringValue, !MemoryRanker.terms(query).isEmpty else {
            return failure("give the id of what to forget, or a query", tool: Self.forget)
        }
        let matches = try store.recall(query, limit: 5, ranker: ranker)
        guard let best = matches.first, best.keyword >= 0.5 else {
            return result(["status": "not_found", "message": "nothing remembered matches that"], succeeded: false, status: "not found")
        }
        // Forget on a query only when one item clearly stands out; otherwise let the model pick by id.
        let close = matches.dropFirst().filter { $0.keyword >= best.keyword - 0.15 }
        if !close.isEmpty {
            let candidates: [JSONValue] = ([best] + close).map {
                ["id": .string($0.entry.id), "text": .string(MemoryPromptBuilder.safe($0.entry.text)), "where": .string($0.entry.place.label)]
            }
            return MemoryToolResult(
                output: JSONValue.object(["status": "ambiguous", "message": "several things match; call again with one id",
                                          "candidates": .array(candidates)]).jsonString(),
                succeeded: false, status: "checked", needsModelRound: true)
        }
        guard let entry = try store.forget(id: best.entry.id) else {
            return result(["status": "not_found", "message": "nothing remembered matches that"], succeeded: false, status: "not found")
        }
        return forgotten(entry)
    }

    private func forgotten(_ entry: MemoryEntry) -> MemoryToolResult {
        result(["status": "forgotten", "id": .string(entry.id), "text": .string(MemoryPromptBuilder.safe(entry.text))], status: "forgot")
    }

    private func result(_ object: [String: JSONValue], succeeded: Bool = true, status: String) -> MemoryToolResult {
        MemoryToolResult(output: JSONValue.object(object).jsonString(), succeeded: succeeded, status: status, needsModelRound: false)
    }

    private func failure(_ message: String, tool: String) -> MemoryToolResult {
        MemoryToolResult(output: JSONValue.object(["status": "error", "message": .string(message)]).jsonString(),
                         succeeded: false, status: "failed", needsModelRound: tool == Self.recall)
    }
}
