import CryptoKit
import Foundation

/// Remembers the exact content of the assistant turns this adapter received, so later requests in the same
/// conversation can send their `thinking` blocks back unchanged.
///
/// Why: `ChatMessage` has no field for opaque provider blocks such as a thinking block's `signature`, but the docs
/// require them back. Per https://platform.claude.com/docs/en/build-with-claude/thinking#preserving-thinking-blocks
/// thinking blocks are *required* within a tool-use turn and recommended across turns. Per
/// https://platform.claude.com/docs/en/build-with-claude/preserved-thinking (Claude Opus 5.5, Sonnet 5.5, Haiku 5.5
/// and later) every replayed block is also checked against everything sent before it:
/// - A block stays valid only while the top-level `system`, the `tools` and every earlier message are unchanged.
/// - The blocks sent back must form an unbroken run of the original sequence. Dropping blocks from the start is
///   fine; dropping one from the middle invalidates every later block.
/// - Accounts created on or after 2026-08-31 get a 400 ("The block is bound to a different conversation") when
///   either rule is broken. Older accounts are not rejected.
///
/// How this store keeps both rules:
/// - Every completed turn is recorded, with or without thinking, under a SHA-256 of the exact `system`, `tools` and
///   earlier messages that were sent before it (thinking blocks excluded, as the API excludes them) plus the turn's
///   visible text and tool calls. A turn is replayed only when that key matches, i.e. nothing before it has changed
///   and the caller's message is what the model produced.
/// - An assistant turn whose key is unknown (edited, written by the app, produced before a restart or evicted) is a
///   possible gap in the run. Thinking is replayed only for the known turns after the last such gap; known turns
///   before it go back with their thinking removed, which drops a leading run, as the docs allow.
/// - Known turns always go back with their original blocks (minus thinking where required), never rebuilt, so the
///   prefix later blocks are bound to stays byte-identical across requests.
///
/// The store is in memory only. After a restart, turns from before it go back without thinking, which the API
/// accepts: the model just loses that reasoning. Turns produced after the restart are recorded and replayed again.
///
/// `ChatMessage.providerItems` carries the same thing with the message, so it survives restarts and eviction: the
/// adapter emits a turn's blocks plus a `replayKeyType` item holding the turn's key (the same SHA-256 this store files
/// it under). A message whose items hold the key the conversation computes at that point is a known turn exactly as
/// if this store had it; the key item itself is never sent. Messages without items fall back to this store.
public final class AnthropicThinkingReplay: @unchecked Sendable {
    /// `type` of the bookkeeping item appended to emitted provider items. Not an Anthropic block type.
    public static let replayKeyType = "openclicky_replay_key"

    /// Process-wide store, so turns survive when the engine factory builds a new client per request.
    public static let shared = AnthropicThinkingReplay()

    /// One request turn: `role` and its content blocks as encoded from `ChatMessage`s.
    struct Turn {
        var role: String
        var content: [JSONValue]
        /// The message's own provider items (blocks plus key item), for an assistant turn made of one message.
        var providerItems: [JSONValue] = []
    }

    /// Where a request's conversation ended, so the reply can be recorded under the right key.
    struct Prefix: Sendable, Hashable {
        /// SHA-256 over `system`, `tools` and every turn, as sent with thinking blocks removed.
        var digest: Data
        /// The reply continues the conversation only when the request ended with a user turn.
        var endsWithUserTurn: Bool
    }

    struct Plan: Sendable {
        /// The `messages` array to send.
        var messages: [JSONValue]
        var prefix: Prefix
    }

    private let lock = NSLock()
    private let capacity: Int
    private var turns: [Data: [JSONValue]] = [:]
    private var order: [Data] = []

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    /// The `messages` to send for `turns`, with recorded assistant turns swapped back in where that is valid.
    func plan(turns requestTurns: [Turn], system: JSONValue?, tools: JSONValue?) -> Plan {
        var chain = Self.seed(system: system, tools: tools)
        var recorded: [[JSONValue]?] = []
        for turn in requestTurns {
            var sent = turn.content
            var known: [JSONValue]?
            if turn.role == "assistant" {
                let key = Self.key(after: chain, visible: turn.content)
                known = Self.blocks(turn.providerItems, matching: key) ?? lock.withLock { turns[key] }
                if let known {
                    let stripped = Self.withoutThinking(known)
                    if !stripped.isEmpty { sent = stripped }
                }
            }
            recorded.append(known)
            chain = Self.extend(chain, role: turn.role, content: sent)
        }

        // The last assistant turn whose thinking is unknown. Thinking before it must go, thinking after it may stay.
        let lastGap = requestTurns.indices.last { requestTurns[$0].role == "assistant" && recorded[$0] == nil } ?? -1
        let messages: [JSONValue] = requestTurns.indices.map { index in
            var content = requestTurns[index].content
            if let known = recorded[index] {
                let stripped = Self.withoutThinking(known)
                content = index > lastGap ? known : (stripped.isEmpty ? content : stripped)
            }
            return ["role": .string(requestTurns[index].role), "content": .array(content)]
        }
        return Plan(messages: messages,
                    prefix: Prefix(digest: chain, endsWithUserTurn: requestTurns.last?.role == "user"))
    }

    /// Records a complete reply. `visible` is how the caller's `ChatMessage` for this reply encodes (its text and
    /// tool calls); `content` is every block exactly as received, thinking included.
    func record(content: [JSONValue], visible: [JSONValue], after prefix: Prefix) {
        guard prefix.endsWithUserTurn, !visible.isEmpty else { return }
        let key = Self.key(after: prefix.digest, visible: visible)
        lock.withLock {
            if turns[key] == nil { order.append(key) }
            turns[key] = content
            while order.count > capacity { turns.removeValue(forKey: order.removeFirst()) }
        }
    }

    /// Number of turns held (for tests).
    var count: Int { lock.withLock { turns.count } }

    // MARK: - Provider items

    /// The provider items for a complete reply: its blocks exactly as received plus a key item, or nil when the
    /// reply could not be replayed (it did not follow a user turn, or has no visible content).
    static func providerItems(content: [JSONValue], visible: [JSONValue], after prefix: Prefix) -> [JSONValue]? {
        guard prefix.endsWithUserTurn, !visible.isEmpty else { return nil }
        let key = key(after: prefix.digest, visible: visible)
        return content + [["type": .string(replayKeyType), "sha256": .string(key.base64EncodedString())]]
    }

    /// The blocks in `items` when their key item matches `key`; nil when there is no key item or it differs (the
    /// conversation before the turn, or the turn's visible content, has changed since).
    static func blocks(_ items: [JSONValue], matching key: Data) -> [JSONValue]? {
        guard let keyItem = items.last(where: { $0["type"]?.stringValue == replayKeyType }),
              keyItem["sha256"]?.stringValue == key.base64EncodedString() else { return nil }
        let blocks = items.filter { $0["type"]?.stringValue != replayKeyType }
        return blocks.isEmpty ? nil : blocks
    }

    // MARK: - Hashing

    static func withoutThinking(_ content: [JSONValue]) -> [JSONValue] {
        content.filter {
            let type = $0["type"]?.stringValue
            return type != "thinking" && type != "redacted_thinking"
        }
    }

    private static func seed(system: JSONValue?, tools: JSONValue?) -> Data {
        digest(Data(), tag: 0, ["system": system ?? .null, "tools": tools ?? .null])
    }

    private static func extend(_ chain: Data, role: String, content: [JSONValue]) -> Data {
        digest(chain, tag: 1, ["role": .string(role), "content": .array(content)])
    }

    private static func key(after chain: Data, visible: [JSONValue]) -> Data {
        digest(chain, tag: 2, .array(visible))
    }

    /// `jsonString()` sorts keys, so equal values always hash the same.
    private static func digest(_ previous: Data, tag: UInt8, _ value: JSONValue) -> Data {
        var hasher = SHA256()
        hasher.update(data: previous)
        hasher.update(data: Data([tag]))
        hasher.update(data: Data(value.jsonString().utf8))
        return Data(hasher.finalize())
    }
}
