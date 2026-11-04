import Foundation
import Testing
@testable import OpenClickyKit

// The Obsidian vault read and written directly in a temporary folder.

private func makeVault(_ name: String = #function) throws -> ObsidianVault {
    let root = try scratchFolder(name)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try "{\"theme\":\"dark\"}".write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    try "# OpenClicky\nA voice buddy that points at the screen.\nSee [[Roadmap|the plan]] and [[Meeting notes#Monday]].\n"
        .write(to: root.appendingPathComponent("Projects/OpenClicky.md"), atomically: true, encoding: .utf8)
    try "# Roadmap\n- connected apps\n- budget review in March\n".write(to: root.appendingPathComponent("Roadmap.md"), atomically: true, encoding: .utf8)
    try "Monday: talked about the budget and [[Roadmap]].\n".write(to: root.appendingPathComponent("Meeting notes.md"), atomically: true, encoding: .utf8)
    try "not a note".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
    return try ObsidianVault(root: root)
}

@Test func vaultListsMarkdownNotesAndSkipsSettings() throws {
    let vault = try makeVault()
    #expect(ObsidianVault.looksLikeVault(vault.root))
    #expect(try vault.notes().map(\.path) == ["Meeting notes.md", "Projects/OpenClicky.md", "Roadmap.md"])
    #expect(try vault.notes().first?.title == "Meeting notes")
}

@Test func vaultReadsNotesWithOrWithoutExtension() throws {
    let vault = try makeVault()
    #expect(try vault.read("Roadmap").hasPrefix("# Roadmap"))
    #expect(try vault.read("Projects/OpenClicky.md").contains("voice buddy"))
    #expect(throws: ObsidianError.notFound("Nope")) { _ = try vault.read("Nope") }
}

@Test func vaultSearchRanksTitleMatchesFirstAndNeedsEveryWord() throws {
    let vault = try makeVault()
    let hits = try vault.search("roadmap")
    #expect(hits.first?.note.path == "Roadmap.md")
    #expect(hits.map(\.note.path).contains("Meeting notes.md"))
    let budget = try vault.search("budget review")
    #expect(budget.map(\.note.path) == ["Roadmap.md"])
    #expect(budget.first?.excerpts.contains { $0.contains("budget review") } == true)
    #expect(try vault.search("the").isEmpty) // stop words only
}

@Test func vaultFindsBacklinksThroughAliasesAndHeadings() throws {
    let vault = try makeVault()
    let roadmap = try vault.backlinks(to: "Roadmap")
    #expect(Set(roadmap.map(\.note.path)) == ["Projects/OpenClicky.md", "Meeting notes.md"])
    #expect(try vault.backlinks(to: "Meeting notes.md").map(\.note.path) == ["Projects/OpenClicky.md"])
    #expect(ObsidianVault.wikiLinks(in: "a [[One|alias]] b [[Folder/Two#H]] [[ ]]") == ["One", "Folder/Two"])
}

@Test func vaultWritesAppendsAndRefusesToOverwriteByDefault() throws {
    let vault = try makeVault()
    let note = try vault.write("Inbox/Idea", content: "first line")
    #expect(note.path == "Inbox/Idea.md")
    #expect(try vault.read("Inbox/Idea") == "first line")
    #expect(throws: ObsidianError.alreadyExists("Inbox/Idea")) { try vault.write("Inbox/Idea", content: "x") }
    try vault.append("Inbox/Idea", text: "second line")
    #expect(try vault.read("Inbox/Idea") == "first line\nsecond line")
    try vault.write("Inbox/Idea", content: "replaced", overwrite: true)
    #expect(try vault.read("Inbox/Idea.md") == "replaced")
    try vault.append("Daily/2026-10-31", text: "new day")
    #expect(try vault.read("Daily/2026-10-31") == "new day")
    #expect(try vault.recentNotes(limit: 1).first?.path == "Daily/2026-10-31.md")
}

@Test func vaultPathsCannotEscapeOrTouchHiddenFolders() throws {
    let vault = try makeVault()
    #expect(throws: ObsidianError.outsideVault("../escape")) { try vault.write("../escape", content: "x") }
    #expect(throws: ObsidianError.outsideVault("Projects/../../escape.md")) { _ = try vault.read("Projects/../../escape.md") }
    #expect(throws: ObsidianError.invalidPath("/etc/hosts")) { _ = try vault.read("/etc/hosts") }
    #expect(throws: ObsidianError.invalidPath("~/secrets")) { _ = try vault.read("~/secrets") }
    #expect(throws: ObsidianError.protectedPath(".obsidian/app.json")) { _ = try vault.read(".obsidian/app.json") }
    #expect(throws: ObsidianError.protectedPath(".trash/old")) { try vault.write(".trash/old", content: "x") }
    #expect(throws: ObsidianError.invalidPath("image.png")) { _ = try vault.read("image.png") }

    // A symlink inside the vault that points outside it is refused for reads and writes.
    let outside = try scratchFolder("outside")
    try "secret".write(to: outside.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: vault.root.appendingPathComponent("Linked"), withDestinationURL: outside)
    #expect(throws: ObsidianError.outsideVault("Linked/secret")) { _ = try vault.read("Linked/secret") }
    #expect(throws: ObsidianError.outsideVault("Linked/new")) { try vault.write("Linked/new", content: "x") }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.md").path))
}

@Test func vaultMustBeAnExistingFolder() throws {
    #expect(throws: ObsidianError.self) { _ = try ObsidianVault(path: "/nonexistent/vault-\(UUID().uuidString)") }
}

@Test func obsidianToolsAnswerLikeAnMCPServer() async throws {
    let vault = try makeVault()
    let source = ObsidianToolSource(vault: vault)
    let tools = try await source.listTools()
    #expect(tools.filter { ToolSafety.access(of: $0) == .read }.map(\.name) == ["search_notes", "read_note", "list_recent_notes", "find_backlinks"])
    #expect(tools.filter { ToolSafety.access(of: $0) == .write }.map(\.name) == ["create_note", "append_to_note"])

    let search = try await source.callTool("search_notes", arguments: ["query": "budget"])
    #expect(!search.isError)
    #expect(search.text.contains("Roadmap.md"))
    let read = try await source.callTool("read_note", arguments: ["path": "Roadmap"])
    #expect(read.text.contains("connected apps"))
    let missing = try await source.callTool("read_note", arguments: [:])
    #expect(missing.isError)
    let refused = try await source.callTool("read_note", arguments: ["path": "../x"])
    #expect(refused.isError)
    #expect(refused.text.contains("outside the vault"))
    let created = try await source.callTool("create_note", arguments: ["path": "From OpenClicky", "content": "hello"])
    #expect(created.text == "Saved From OpenClicky.md.")
    await #expect(throws: MCPClientError.self) { _ = try await source.callTool("delete_note", arguments: ["path": "Roadmap"]) }
}
