// Which connector tools count as reads, and a one-line capability summary built from tool names.
//
// The brain's `read_connected_apps` may only call reads. MCP servers can hint `readOnlyHint` and
// `destructiveHint`, but hints come from the server and are untrusted, so they can only make OpenClicky more
// careful: a tool whose name says it writes is a write even if it claims to be read-only, and a tool with no
// recognizable verb is treated as a write.

import Foundation

public enum ToolAccess: String, Sendable, Hashable, Codable {
    case read
    case write
}

public enum ToolSafety {
    /// Verbs that only look things up.
    static let readVerbs: Set<String> = [
        "get", "list", "search", "find", "read", "fetch", "query", "view", "show", "describe", "retrieve", "lookup",
        "look", "count", "browse", "check", "inspect", "preview", "download", "whoami", "summarize", "explain",
        "discover",
    ]

    /// Words that change something wherever they appear in the name.
    static let writeVerbs: Set<String> = [
        "create", "add", "update", "edit", "delete", "remove", "send", "reply", "forward", "write", "set", "move", "rename",
        "archive", "unarchive", "trash", "untrash", "merge", "upload", "insert", "patch", "put", "append", "publish",
        "unpublish", "invite", "approve", "reject", "execute", "exec", "run", "pay", "transfer", "submit", "modify",
        "replace", "cancel", "close", "reopen", "complete", "assign", "unassign", "enable", "disable", "toggle", "start",
        "stop", "import", "sync", "mark", "upsert", "purge", "clear", "reset", "revoke", "grant", "accept", "decline",
        "subscribe", "unsubscribe", "follow", "unfollow", "like", "unlike", "react", "star", "unstar", "pin", "unpin",
        "book", "buy", "duplicate", "copy", "convert", "commit", "push", "deploy", "trigger", "launch", "notify", "mute",
        "unmute", "block", "unblock", "ban", "kick", "restore", "attach", "detach", "install", "uninstall", "apply",
        "save", "store", "change", "manage", "connect", "disconnect", "authorize", "login", "logout", "bash", "shell",
        "workbench", "rsvp", "respond", "snooze", "unsnooze", "dismiss", "transition", "link", "unlink",
    ]

    /// Words that are writes in verb position ("post_message") but nouns after a read verb ("get_post").
    static let ambiguousWords: Set<String> = [
        "post", "comment", "label", "tag", "schedule", "share", "message", "draft", "order", "reserve", "call",
    ]

    /// Read or write for a tool. `readOnlyHint` can only turn a tool with no recognizable verb into a read.
    public static func access(of tool: MCPToolDefinition) -> ToolAccess {
        if tool.annotations?.destructiveHint == true { return .write }
        let classified = access(ofName: tool.name)
        if classified == .write, tool.annotations?.readOnlyHint == true, !hasExplicitWriteWord(tool.name) {
            // No verb either way, and the server says it only reads: accept the hint.
            return .read
        }
        return classified
    }

    /// Read only when the name has a read verb and no write word. Unknown names are writes.
    public static func access(ofName name: String) -> ToolAccess {
        let words = tokens(name)
        if hasExplicitWriteWord(words) { return .write }
        return words.contains(where: readVerbs.contains) ? .read : .write
    }

    static func hasExplicitWriteWord(_ name: String) -> Bool { hasExplicitWriteWord(tokens(name)) }

    private static func hasExplicitWriteWord(_ words: [String]) -> Bool {
        if words.contains(where: writeVerbs.contains) { return true }
        // An ambiguous word counts when it comes before any read verb.
        for word in words {
            if readVerbs.contains(word) { return false }
            if ambiguousWords.contains(word) { return true }
        }
        return false
    }

    /// Lower-case words of a tool name: split on `_ - . / :` and space, and between camelCase humps.
    public static func tokens(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            if character.isLetter || character.isNumber {
                if character.isUppercase, previousWasLower, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(Character(character.lowercased()))
                previousWasLower = character.isLowercase || character.isNumber
            } else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previousWasLower = false
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: Composio

    /// Composio's tool router runs app actions through one meta tool whose arguments list the action slugs. Such a
    /// call is a read only when every listed slug is a read; anything else (an unknown argument shape included)
    /// is a write. The argument check applies only to the built-in Composio app (`appID` "composio"): any other
    /// server could name a tool "…execute_tool" and do whatever it likes with those arguments.
    public static func access(ofCall tool: MCPToolDefinition, arguments: JSONValue, appID: String) -> ToolAccess {
        guard isArgumentGated(tool, appID: appID) else { return access(of: tool) }
        if tool.annotations?.destructiveHint == true { return .write }
        let items = arguments["tools"]?.arrayValue ?? arguments["actions"]?.arrayValue ?? []
        let slugs = items.compactMap { $0["tool_slug"]?.stringValue ?? $0["slug"]?.stringValue ?? $0["tool"]?.stringValue }
        guard !slugs.isEmpty, slugs.count == items.count else { return .write }
        return slugs.allSatisfy { access(ofName: $0) == .read } ? .read : .write
    }

    /// True for Composio's meta tool that runs other tools (its read status depends on the arguments). Only the
    /// built-in Composio app has one; for every other app this is false.
    public static func isArgumentGated(_ tool: MCPToolDefinition, appID: String) -> Bool {
        guard appID == ComposioClient.connectorID else { return false }
        let lowered = tool.name.lowercased()
        return lowered.hasSuffix("multi_execute_tool") || lowered.hasSuffix("execute_tool")
    }
}

/// Builds a short "what it can do" line from tool names, such as "search, read and create pages, issues".
public enum CapabilityDeriver {
    /// Verbs worth naming, in the order they read best.
    static let verbOrder = ["search", "find", "read", "list", "get", "create", "update", "edit", "comment", "send", "reply",
                            "draft", "schedule", "move", "archive", "delete", "upload", "download", "run"]
    static let verbAliases: [String: String] = [
        "fetch": "read", "retrieve": "read", "view": "read", "show": "read", "query": "search", "lookup": "find",
        "look": "find", "add": "create", "insert": "create", "post": "send", "modify": "update", "patch": "update",
        "remove": "delete", "trash": "delete", "execute": "run", "exec": "run", "describe": "read", "browse": "list",
    ]
    static let ignoredNouns: Set<String> = ["by", "id", "ids", "for", "the", "a", "an", "to", "of", "in", "and", "or", "with",
                                            "all", "my", "new", "v1", "v2", "info", "details", "data", "item", "items",
                                            "mcp", "tool", "tools", "api", "multi", "batch", "bulk", "current", "user", "me"]

    public static func describe(_ tools: [MCPToolDefinition], appName: String? = nil, maxNouns: Int = 4) -> String? {
        guard !tools.isEmpty else { return nil }
        var verbs = Set<String>()
        var nounCounts: [String: Int] = [:]
        let appWords = Set(appName.map(ToolSafety.tokens) ?? [])
        for tool in tools {
            let words = ToolSafety.tokens(tool.name)
            var sawVerb = false
            for word in words {
                let verb = verbAliases[word] ?? word
                if verbOrder.contains(verb) {
                    verbs.insert(verb)
                    sawVerb = true
                } else if sawVerb, word.count > 2, !ignoredNouns.contains(word), !appWords.contains(word),
                          !ToolSafety.readVerbs.contains(word), !ToolSafety.writeVerbs.contains(word) {
                    nounCounts[plural(word), default: 0] += 1
                }
            }
        }
        // "get" and "list" add nothing next to "read".
        if verbs.contains("read") { verbs.remove("get") }
        if verbs.contains("search") { verbs.remove("find") }
        let orderedVerbs = verbOrder.filter(verbs.contains)
        guard !orderedVerbs.isEmpty else { return "\(tools.count) tool\(tools.count == 1 ? "" : "s")" }
        let nouns = nounCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(maxNouns).map(\.key)
        let verbText = list(orderedVerbs.map { $0 == "get" ? "read" : $0 }.uniqued())
        return nouns.isEmpty ? verbText.capitalizedFirst : "\(verbText) \(nouns.joined(separator: ", "))".capitalizedFirst
    }

    static func plural(_ word: String) -> String {
        if word.hasSuffix("s") { return word }
        if word.hasSuffix("y"), word.count > 3, !"aeiou".contains(word.dropLast().last!) { return word.dropLast() + "ies" }
        return word + "s"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
