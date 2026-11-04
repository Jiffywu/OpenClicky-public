// The Obsidian vault as a connected app: a handful of MCP-shaped tools served in-process, so the brain's
// `read_connected_apps`, `occtl apps tools obsidian` and the settings window treat it like any other connector.
// Agents get the vault differently: its path in `OBSIDIAN_VAULT_PATH` and plain file access (see AgentExport).

import Foundation

public struct ObsidianToolSource: ConnectedAppSource {
    public let vault: ObsidianVault

    public init(vault: ObsidianVault) { self.vault = vault }

    public static let tools: [MCPToolDefinition] = [
        MCPToolDefinition(name: "search_notes", title: "Search notes",
                description: "Find notes whose title or text contains the given words. Returns paths and matching lines (the best match whole when it is short).",
                inputSchema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Words to look for."],
                    "limit": ["type": "integer", "description": "Most notes to return (default 8)."],
                ], "required": ["query"]],
                annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: false)),
        MCPToolDefinition(name: "read_note", title: "Read a note",
                description: "The full Markdown of one note, by its path inside the vault (\".md\" optional).",
                inputSchema: ["type": "object", "properties": [
                    "path": ["type": "string", "description": "Path inside the vault, e.g. Projects/Plan.md"],
                ], "required": ["path"]],
                annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: false)),
        MCPToolDefinition(name: "list_recent_notes", title: "Recent notes",
                description: "The most recently edited notes, newest first.",
                inputSchema: ["type": "object", "properties": [
                    "limit": ["type": "integer", "description": "How many (default 10)."],
                ]],
                annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: false)),
        MCPToolDefinition(name: "find_backlinks", title: "Find backlinks",
                description: "Notes that link to the given note with [[wiki links]], with the linking lines.",
                inputSchema: ["type": "object", "properties": [
                    "note": ["type": "string", "description": "The linked note's title or path."],
                ], "required": ["note"]],
                annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: false)),
        MCPToolDefinition(name: "create_note", title: "Create a note",
                description: "Write a new Markdown note. Fails if the note exists unless overwrite is true.",
                inputSchema: ["type": "object", "properties": [
                    "path": ["type": "string", "description": "Path inside the vault for the new note."],
                    "content": ["type": "string", "description": "Markdown text."],
                    "overwrite": ["type": "boolean", "description": "Replace an existing note (default false)."],
                ], "required": ["path", "content"]],
                annotations: MCPToolAnnotations(readOnlyHint: false, destructiveHint: false)),
        MCPToolDefinition(name: "append_to_note", title: "Append to a note",
                description: "Add Markdown to the end of a note, creating it if needed.",
                inputSchema: ["type": "object", "properties": [
                    "path": ["type": "string", "description": "Path inside the vault."],
                    "text": ["type": "string", "description": "Markdown to add."],
                ], "required": ["path", "text"]],
                annotations: MCPToolAnnotations(readOnlyHint: false, destructiveHint: false)),
    ]

    /// The best search match is returned whole when it is at most this long.
    static let wholeNoteCharacters = 1_500

    public func listTools() async throws -> [MCPToolDefinition] { Self.tools }

    public func serverDescription() async throws -> MCPServerDescription? { nil }

    public func close() async {}

    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        guard Self.tools.contains(where: { $0.name == name }) else {
            throw MCPClientError.rpc(JSONRPCError(code: JSONRPCError.invalidParams, message: "Unknown tool: \(name)"))
        }
        do {
            return MCPToolResult(content: [.text(try run(name, arguments))])
        } catch let error as ObsidianError {
            return MCPToolResult(content: [.text(error.description)], isError: true)
        } catch let error as MissingArgument {
            return MCPToolResult(content: [.text("Missing \"\(error.name)\".")], isError: true)
        } catch {
            return MCPToolResult(content: [.text("Couldn't use the vault: \(error.localizedDescription)")], isError: true)
        }
    }

    private struct MissingArgument: Error { var name: String }

    private func run(_ name: String, _ arguments: JSONValue) throws -> String {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key]?.stringValue, !value.isEmpty else { throw MissingArgument(name: key) }
            return value
        }
        let limit = arguments["limit"]?.intValue
        switch name {
        case "search_notes":
            let hits = try vault.search(try string("query"), limit: min(max(limit ?? 8, 1), 50))
            guard !hits.isEmpty else { return "No notes matched." }
            return hits.enumerated().map { index, hit in
                let header = "\(hit.note.path) (edited \(Self.day(hit.note.modified)))"
                // The best match comes whole when it is short, so one quick look answers "what's on my list".
                if index == 0, let text = try? vault.read(hit.note.path), text.count <= Self.wholeNoteCharacters {
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { "  \($0)" }
                    return ([header + ", whole note:"] + lines).joined(separator: "\n")
                }
                return ([header] + hit.excerpts.map { "  \($0)" }).joined(separator: "\n")
            }.joined(separator: "\n")
        case "read_note":
            let path = try string("path")
            return "# \(path)\n\n" + (try vault.read(path))
        case "list_recent_notes":
            let notes = try vault.recentNotes(limit: min(max(limit ?? 10, 1), 100))
            return notes.isEmpty ? "The vault has no notes." : notes.map { "\($0.path) (edited \(Self.day($0.modified)))" }.joined(separator: "\n")
        case "find_backlinks":
            let hits = try vault.backlinks(to: try string("note"))
            guard !hits.isEmpty else { return "No notes link to it." }
            return hits.map { hit in ([hit.note.path] + hit.excerpts.map { "  \($0)" }).joined(separator: "\n") }.joined(separator: "\n")
        case "create_note":
            let note = try vault.write(try string("path"), content: arguments["content"]?.stringValue ?? "",
                                       overwrite: arguments["overwrite"]?.boolValue ?? false)
            return "Saved \(note.path)."
        case "append_to_note":
            let note = try vault.append(try string("path"), text: try string("text"))
            return "Added to \(note.path)."
        default:
            throw MissingArgument(name: "tool")
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
