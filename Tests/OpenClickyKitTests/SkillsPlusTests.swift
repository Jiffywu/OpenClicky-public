import CryptoKit
import Foundation
import Testing
@testable import OpenClickyKit

// MARK: - Front matter editing

@Test func editingFrontMatterKeepsUnknownKeysAndTheBody() {
    let source = """
    ---
    name: Pitch decks
    license: MIT
    # a comment the user wrote
    title: Old title spelling
    allowed-tools:
      - Read
      - Write
    summary: Old one-liner
    ---

    # Pitch decks

    One idea per slide.
    """
    let edited = SkillFile.applying(SkillMetadata(name: "Pitch decks: 2027", description: "Shapes Keynote slides. Use when building decks.",
                                                  oneLiner: "One idea per slide", category: "design", tags: ["Slides", "keynote", "slides", "a, b"],
                                                  builtFor: "Keynote"), to: source)
    let parsed = SkillFile.parse(edited)
    #expect(parsed.name == "Pitch decks: 2027")
    #expect(parsed.description == "Shapes Keynote slides. Use when building decks.")
    #expect(parsed.oneLiner == "One idea per slide")
    #expect(parsed.category == "Design", "known categories are spelled the canonical way")
    #expect(parsed.tags == ["slides", "keynote", "a", "b"])
    #expect(parsed.builtFor == "Keynote")
    #expect(parsed.body == "# Pitch decks\n\nOne idea per slide.")
    // Unknown keys, their continuation lines and comments survive; alias spellings collapse into one key.
    #expect(edited.contains("license: MIT\n# a comment the user wrote\n"))
    #expect(edited.contains("allowed-tools:\n  - Read\n  - Write\n"))
    #expect(!edited.contains("title:") && !edited.contains("summary:"))
    #expect(edited.hasPrefix("---\nname: \"Pitch decks: 2027\"\n"))

    // Clearing optional fields removes their keys.
    let cleared = SkillFile.applying(SkillMetadata(name: "Pitch decks", description: "Shapes slides."), to: edited)
    let again = SkillFile.parse(cleared)
    #expect(again.oneLiner == nil && again.category == nil && again.tags.isEmpty && again.builtFor == nil)
    #expect(cleared.contains("license: MIT"))
}

@Test func editingFrontMatterReplacesABlockScalarWithABlankLineWhole() {
    let source = """
    ---
    name: Weekly report
    description: |
      Use when writing the weekly report: keep it tight.

      Keeps it short.
    license: MIT

    notes: >
      first

      second
    ---

    Body.
    """
    let edited = SkillFile.applying(SkillMetadata(name: "Weekly report", description: "New description."), to: source)
    #expect(edited == """
    ---
    name: Weekly report
    description: New description.
    license: MIT

    notes: >
      first

      second
    ---

    Body.

    """)
    let parsed = SkillFile.parse(edited)
    #expect(parsed.description == "New description.")
    #expect(!edited.contains("Keeps it short."), "no orphaned lines from the old block are left behind")
}

@Test func frontMatterIsAddedWhenMissingAndValuesRoundTrip() {
    let tricky = SkillMetadata(name: "yes", description: #"Quotes "here", a back\slash\n and # hash: all kept"#, oneLiner: "- dash first")
    let text = SkillFile.applying(tricky, to: "# Heading\n\nBody text.\n")
    let parsed = SkillFile.parse(text)
    #expect(parsed.hadFrontMatter)
    #expect(parsed.name == "yes")
    #expect(parsed.description == #"Quotes "here", a back\slash\n and # hash: all kept"#)
    #expect(parsed.oneLiner == "- dash first")
    #expect(parsed.body == "# Heading\n\nBody text.")
}

@Test func metadataProblemsExplainWhatToFix() {
    #expect(SkillMetadata(name: "Ok", description: "Fine.").problems.isEmpty)
    #expect(SkillMetadata(name: "  ", description: "").problems == ["Give the skill a name.", "Say when the skill applies and what it changes."])
    #expect(SkillMetadata(name: "x", description: String(repeating: "a", count: 1100)).problems.first?.contains("1024") == true)
}

// MARK: - Library: edit, deactivate all, search

@Test func editingASkillKeepsItsFolderAndSwitch() throws {
    let folder = HomeTemporaryFolder("skills-edit")
    let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
    try library.create(SkillMetadata(name: "Writing coach", description: "Tightens prose.", category: "Writing", tags: ["editing"]),
                       body: "Read it all first.", enable: true)
    let updated = try library.update("writing-coach", metadata: SkillMetadata(name: "Prose coach", description: "Tightens prose, keeps voice.",
                                                                              oneLiner: "Tighter writing", category: "Writing", tags: ["editing", "tone"]))
    #expect(updated.id == "writing-coach")
    #expect(updated.name == "Prose coach")
    #expect(updated.isEnabled)
    #expect(updated.tags == ["editing", "tone"])
    #expect(updated.body == "Read it all first.")
    let rebodied = try library.update("Prose coach", metadata: SkillMetadata(updated), body: "New guidance.\n")
    #expect(rebodied.body == "New guidance.")
    #expect(rebodied.oneLiner == "Tighter writing")
    #expect(throws: SkillsLibraryError.self) { try library.update("nope", metadata: SkillMetadata(name: "x", description: "y")) }
    #expect(throws: SkillsLibraryError.invalidName) { try library.update("writing-coach", metadata: SkillMetadata(name: " ", description: "y")) }
}

@Test func deactivateAllAndRemove() throws {
    let folder = HomeTemporaryFolder("skills-off")
    let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
    try library.create(name: "One", description: "1", body: "x", enable: true)
    try library.create(name: "Two", description: "2", body: "x", enable: true)
    try library.create(name: "Three", description: "3", body: "x")
    #expect(try library.disableAll() == 2)
    #expect(library.activeSkills().isEmpty)
    #expect(library.skills.count == 3)
    try library.remove("two")
    #expect(library.skills.map(\.id) == ["one", "three"])
}

@Test func searchMatchesEveryWordAndFiltersByCategory() {
    func skill(_ id: String, _ name: String, _ description: String, category: String? = nil, tags: [String] = []) -> Skill {
        Skill(id: id, name: name, description: description, tags: tags, category: category, folder: URL(fileURLWithPath: "/tmp/\(id)"))
    }
    let skills = [
        skill("notes", "Meeting notes", "Turns notes into decisions and owners.", category: "Productivity", tags: ["meetings"]),
        skill("email", "Status email", "Writes weekly meeting summaries as email.", category: "Writing"),
        skill("deck", "Slide decks", "One idea per slide.", category: "Design"),
        skill("loose", "Loose", "No category at all."),
    ]
    #expect(SkillSearch.filter(skills, query: "meeting").map(\.id) == ["notes", "email"], "name matches first")
    #expect(SkillSearch.filter(skills, query: "meeting email").map(\.id) == ["email"])
    #expect(SkillSearch.filter(skills, query: "", category: "design").map(\.id) == ["deck"])
    #expect(SkillSearch.filter(skills, query: "", category: "Other").map(\.id) == ["loose"])
    #expect(SkillSearch.categories(in: skills).map(\.name) == ["Writing", "Productivity", "Design", "Other"])
}

// MARK: - Catalog

@Test func theCatalogShipsCategorizedStarterSkills() throws {
    let catalog = SkillCatalog()
    let entries = catalog.entries()
    #expect(entries.count >= 8)
    let known = Set(SkillCategory.all.map(\.name))
    for entry in entries {
        #expect(entry.warnings.isEmpty, "\(entry.id): \(entry.warnings)")
        #expect(entry.id == SkillFile.slug(for: entry.name), "folder names follow the skill name")
        #expect(known.contains(entry.category ?? ""), "\(entry.id) has a known category")
        #expect(entry.description.hasPrefix("Use when"), "\(entry.id) says when it applies")
        #expect(entry.oneLiner != nil && !entry.tags.isEmpty)
        #expect(entry.description.count <= SkillMetadata.maxDescriptionLength)
    }
    #expect(catalog.search("keynote").map(\.id) == ["slide-decks"])
    #expect(catalog.search("", category: "Finance").map(\.id) == ["budget-check"])

    let folder = HomeTemporaryFolder("catalog")
    let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
    let entry = try #require(catalog.entry("Meeting notes"))
    #expect(!catalog.isInLibrary(entry, library: library))
    let added = try catalog.add("meeting-notes", to: library)
    #expect(added.id == "meeting-notes" && !added.isEnabled && added.category == "Productivity")
    #expect(catalog.isInLibrary(entry, library: library))
    #expect(throws: SkillsLibraryError.alreadyExists("meeting-notes")) { try catalog.add("meeting-notes", to: library) }
}

// MARK: - Shipped agent skills

@Test func bundledAndIntegrationSkillsAreValidForBothHarnesses() throws {
    let bundled = BundledAgentSkills.all()
    #expect(bundled.map(\.name) == ["openclicky-browser", "vercel-deploy"])
    let integrationFolders = SkillResources.skillFolders(in: SkillResources.integrationsFolder).map(\.lastPathComponent)
    #expect(integrationFolders == IntegrationSkills.all.map(\.name).sorted(), "every integration folder has a matcher entry and vice versa")
    for folder in SkillResources.skillFolders(in: SkillResources.agentFolder) + SkillResources.skillFolders(in: SkillResources.integrationsFolder) {
        let skill = try SkillFile.load(folder: folder)
        #expect(skill.warnings.isEmpty, "\(folder.lastPathComponent): \(skill.warnings)")
        // Both harnesses know a skill by a plain name; Codex reads it from the front matter, Claude Code from the folder.
        #expect(skill.name == folder.lastPathComponent)
        #expect(AgentSkillSource.installName(skill.name) == skill.name)
        #expect(!skill.description.isEmpty && skill.description.count <= SkillMetadata.maxDescriptionLength)
    }
    // The browser skill points at references that exist, and they all exist.
    let browser = try #require(bundled.first)
    let text = try String(contentsOf: browser.folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
    let references = try FileManager.default.contentsOfDirectory(atPath: browser.folder.appendingPathComponent("references").path).sorted()
    #expect(references == ["batching.md", "confirmations.md", "files.md", "reading-and-acting.md", "safety.md", "tabs.md", "troubleshooting.md"])
    for reference in references { #expect(text.contains("references/\(reference)"), "SKILL.md mentions \(reference)") }
    // Every operation the browser tool has is covered by the skill or its references.
    let all = try references.map { try String(contentsOf: browser.folder.appendingPathComponent("references/\($0)"), encoding: .utf8) }.joined() + text
    for operation in BrowserTool.Operation.allCases { #expect(all.contains("`\(operation.rawValue)"), "\(operation.rawValue) is described") }
}

@Test func vendoredVercelDeployMatchesItsPinnedUpstreamCommit() throws {
    let folder = try #require(BundledAgentSkills.all().first { $0.name == "vercel-deploy" }?.folder)
    let attribution = try String(contentsOf: folder.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
    #expect(attribution.contains("49f948faa9258a0c61caceaf225e179651397431"))
    #expect(try String(contentsOf: folder.appendingPathComponent("LICENSE.txt"), encoding: .utf8).hasPrefix("MIT License"))
    var checked = 0
    for line in attribution.split(separator: "\n") where line.hasPrefix("| ") && !line.hasPrefix("| File") {
        // `| file | upstream blob |`, or `| file | upstream blob | local blob |` for a file OpenClicky changed.
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count == 2 || cells.count == 3, cells.dropFirst().allSatisfy({ $0.count == 40 }) else { continue }
        let data = try Data(contentsOf: folder.appendingPathComponent(cells[0]))
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        let hash = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        #expect(hash == cells[cells.count - 1], "\(cells[0]) is byte-for-byte the upstream file, or the documented local change")
        checked += 1
    }
    #expect(checked == 6)
}

@Test func vercelDeployScriptLeavesSecretsOutOfTheUpload() async throws {
    let deploy = try #require(BundledAgentSkills.all().first { $0.name == "vercel-deploy" }?.folder).appendingPathComponent("scripts/deploy.sh")
    let temp = AgentTempDir()
    let manager = FileManager.default
    let project = temp.url.appendingPathComponent("site", isDirectory: true)
    for folder in ["assets", ".aws", ".ssh", ".git", "node_modules/x"] {
        try manager.createDirectory(at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let kept = ["index.html", "assets/app.js", "assets/notes.key.txt", "id_photo.jpg"]
    let secret = [".env", ".env.local", ".envrc", ".npmrc", ".yarnrc.yml", ".netrc", ".pypirc", ".aws/credentials", ".ssh/config",
                  ".git/config", "node_modules/x/index.js", "server.pem", "assets/tls.key", "cert.p12", "id_rsa", "id_ed25519.pub"]
    for file in kept + secret { try "x".write(to: project.appendingPathComponent(file), atomically: true, encoding: .utf8) }

    // A stand-in curl keeps the uploaded tarball and answers with an error, so nothing leaves the Mac.
    let bin = temp.url.appendingPathComponent("bin", isDirectory: true)
    try manager.createDirectory(at: bin, withIntermediateDirectories: true)
    let uploaded = temp.url.appendingPathComponent("uploaded.tgz")
    let curl = bin.appendingPathComponent("curl")
    try """
    #!/bin/sh
    for arg in "$@"; do case "$arg" in file=@*) /bin/cp -f "${arg#file=@}" "$UPLOADED" ;; esac; done
    echo '{"error":"stub"}'
    """.write(to: curl, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [deploy.path, project.path]
    process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": temp.url.path, "UPLOADED": uploaded.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deployed = await exits(process, within: 60)
    #expect(deployed, "deploy.sh didn't finish within 60 s")
    guard deployed else { return }
    #expect(process.terminationStatus == 1, "the stub's error stops the script")

    let list = Process()
    let pipe = Pipe()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    list.arguments = ["-tzf", uploaded.path]
    list.standardOutput = pipe
    try list.run()
    let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(await exits(list, within: 30), "tar didn't finish within 30 s")
    let files = Set(listing.split(separator: "\n").map { String($0.hasPrefix("./") ? $0.dropFirst(2) : $0[...]) }.filter { !$0.isEmpty && !$0.hasSuffix("/") })
    #expect(files == Set(kept))
}

// MARK: - Which integration skills a job gets

@Test func integrationSkillsFollowWhatIsConnected() {
    var registry = ConnectorRegistry()
    #expect(IntegrationSkills.matching(registry: registry).isEmpty)
    registry.connectors = [
        ConnectorPreset.named("linear")!.connector,
        ConnectorConfig(id: "work-github", name: "Work GitHub", transport: .remote(URL(string: "https://api.githubcopilot.com/mcp/")!)),
        ConnectorConfig(id: "notion", name: "Notion", transport: .remote(URL(string: "https://mcp.notion.com/mcp")!), enabled: false),
        ConnectorConfig(id: "tracker", name: "Tracker", transport: .remote(URL(string: "https://mcp.atlassian.com/v1/sse")!)),
        ConnectorConfig(id: "files", name: "Files", transport: .stdio(command: "npx", arguments: ["-y", "files-mcp"])),
    ]
    registry.composio = ComposioSettings(userID: "me", toolkits: ["gmail", "MICROSOFT_TEAMS", "spotify"])
    #expect(IntegrationSkills.matching(registry: registry).map(\.name) == ["gmail", "jira", "linear", "microsoft-teams", "github"])
    // Composio's own answer about connected accounts wins over the listed toolkits.
    #expect(IntegrationSkills.matching(registry: registry, composioToolkits: ["googledocs"]).map(\.name) == ["google-docs", "jira", "linear", "github"])
    registry.composio?.enabled = false
    #expect(!IntegrationSkills.matching(registry: registry).map(\.name).contains("gmail"))
    #expect(IntegrationSkills.named("Google Docs")?.name == "google-docs")
    #expect(IntegrationSkills.named("microsoft_teams")?.name == "microsoft-teams")
}

@Test func libraryMarkdownForAgentsHasAPlainNameAndNoCollisions() throws {
    let folder = HomeTemporaryFolder("skills-agent")
    let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
    try library.create(SkillMetadata(name: "Gmail", description: "How I like my email.", builtFor: "Mail"), body: "Short replies.", enable: true)
    try library.create(name: "Pitch decks", description: "Slides.", body: "x", enable: true)
    try FileManager.default.createDirectory(at: folder.path("Skills/loose"), withIntermediateDirectories: true)
    try "# Loose notes\n\nNo front matter here.\n".write(to: folder.path("Skills/loose/SKILL.md"), atomically: true, encoding: .utf8)
    try library.enable("loose")

    var registry = ConnectorRegistry()
    registry.composio = ComposioSettings(userID: "me", toolkits: ["gmail"])
    let sources = AgentSkillSources.current(library: library, registry: registry)
    #expect(sources.map(\.name) == ["openclicky-browser", "vercel-deploy", "gmail", "my-gmail", "loose", "pitch-decks"])
    #expect(sources.map(\.origin) == [.bundled, .bundled, .integration, .library, .library, .library])

    let mine = try #require(sources.first { $0.name == "my-gmail" })
    let parsed = SkillFile.parse(try #require(mine.markdown))
    #expect(parsed.name == "my-gmail")
    #expect(parsed.description == "How I like my email. Written for Mail: it applies fully to work in Mail.")
    #expect(parsed.body == "Short replies.")
    let loose = SkillFile.parse(try #require(sources.first { $0.name == "loose" }?.markdown))
    #expect(loose.name == "loose" && loose.description == "No front matter here.", "a skill without front matter gets one")

    let notes = AgentSkillNotes.section(for: sources, harness: .claudeCode)
    #expect(notes.hasPrefix("# Skills"))
    #expect(notes.contains("`openclicky:openclicky-browser`: before your first call to the browser tool"))
    #expect(notes.contains("`openclicky:gmail` for Gmail"))
    #expect(notes.contains("- `openclicky:my-gmail` (Gmail)"))
    #expect(AgentSkillNotes.section(for: sources, harness: .codex).contains("- `pitch-decks` (Pitch decks)"))
    #expect(AgentSkillNotes.appending(to: "Base.", skills: [], harness: .codex) == "Base.")
    #expect(library.skillsAgentInstructions() == "", "library skills reach agents installed, not appended twice")
    #expect(library.skillsAgentFallback().contains("File: /"))
}

@Test func libraryMarkdownForAgentsLeavesOutToolPermissions() throws {
    let folder = HomeTemporaryFolder("skills-agent-permissions")
    let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
    try FileManager.default.createDirectory(at: folder.path("Skills/shell"), withIntermediateDirectories: true)
    let original = """
    ---
    name: Shell helper
    description: Runs shell commands.
    allowed-tools: Bash
    Allowed_Tools:
      - Bash(rm:*)
    hooks:
      PreToolUse:
        - command: echo hi
    license: MIT
    ---

    Body.
    """
    try original.write(to: folder.path("Skills/shell/SKILL.md"), atomically: true, encoding: .utf8)
    try library.enable("shell")

    let markdown = try #require(AgentSkillSources.library(library.activeSkills(), taken: []).first?.markdown)
    #expect(!markdown.lowercased().contains("allowed"), "the agents' copy doesn't pre-approve tools")
    #expect(!markdown.contains("hooks:") && !markdown.contains("echo hi"))
    #expect(markdown.contains("license: MIT"), "other keys are kept")
    #expect(SkillFile.parse(markdown).body == "Body.")
    #expect(try String(contentsOf: folder.path("Skills/shell/SKILL.md"), encoding: .utf8) == original, "the user's file is untouched")
}

// MARK: - Installing

@Test func installingSyncsOnlyOpenClickysFolders() throws {
    let temp = AgentTempDir()
    let root = temp.url.appendingPathComponent("skills")
    let source = temp.url.appendingPathComponent("src/alpha")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try "---\nname: alpha\ndescription: A.\n---\nBody.\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho hi\n".write(to: source.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
    try "junk".write(to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    // Codex's own skills and a folder the user made are never touched.
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".system/x"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("beta"), withIntermediateDirectories: true)
    try "mine".write(to: root.appendingPathComponent("beta/SKILL.md"), atomically: true, encoding: .utf8)

    let alpha = AgentSkillSource(name: "alpha", origin: .bundled, folder: source, title: "Alpha", summary: "A.")
    let beta = AgentSkillSource(name: "beta", origin: .library, folder: source, markdown: "---\nname: beta\ndescription: B.\n---\n", title: "Beta", summary: "B.")
    let first = try AgentSkillInstaller.sync([alpha, beta], into: root)
    #expect(first.updated == ["alpha"])
    #expect(first.conflicts == ["beta"])
    #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("alpha/scripts/run.sh").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("alpha/.DS_Store").path))
    #expect(try String(contentsOf: root.appendingPathComponent("beta/SKILL.md"), encoding: .utf8) == "mine")

    let second = try AgentSkillInstaller.sync([alpha], into: root)
    #expect(second.updated.isEmpty && second.installed.map(\.name) == ["alpha"], "unchanged skills aren't rewritten")

    try "---\nname: alpha\ndescription: A2.\n---\nBody.\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    #expect(try AgentSkillInstaller.sync([alpha], into: root).updated == ["alpha"])
    #expect(try String(contentsOf: root.appendingPathComponent("alpha/SKILL.md"), encoding: .utf8).contains("A2."))

    let pruned = try AgentSkillInstaller.sync([], into: root)
    #expect(pruned.removed == ["alpha"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".system/x").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("beta/SKILL.md").path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".staging") }
    #expect(leftovers.isEmpty)
}

@Test func installingWaitsWhileAnotherProcessIsSyncingTheSameFolder() async throws {
    let temp = AgentTempDir()
    let root = temp.url.appendingPathComponent("skills")
    let source = temp.url.appendingPathComponent("src/alpha")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "---\nname: alpha\ndescription: A.\n---\nBody.\n".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let alpha = AgentSkillSource(name: "alpha", origin: .bundled, folder: source, title: "Alpha", summary: "A.")

    // Another process (standing in for occtl) holds the install lock until its stdin closes.
    let holder = Process()
    let input = Pipe()
    let output = Pipe()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    holder.arguments = ["-e", #"use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "locked\n"; <STDIN>;"#,
                        root.appendingPathComponent(AgentSkillInstaller.lockFileName).path]
    holder.standardInput = input
    holder.standardOutput = output
    try holder.run()
    #expect(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self) == "locked\n")

    let sync = Task.detached { try AgentSkillInstaller.sync([alpha], into: root) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("alpha").path), "the sync waits for the other process")
    try input.fileHandleForWriting.close()
    #expect(await exits(holder, within: 30), "the lock holder didn't exit within 30 s")
    #expect(try await sync.value.updated == ["alpha"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("alpha/SKILL.md").path))
}

@Test func claudeCodeGetsTheSkillsAsAPlugin() throws {
    let temp = AgentTempDir()
    let sources = BundledAgentSkills.all()
    let result = try AgentSkillInstaller.syncClaudePlugin(sources, at: temp.paths.claudeSkillsPlugin)
    #expect(result.installed.map(\.name) == ["openclicky-browser", "vercel-deploy"])
    let manifest = try JSONValue.parse(String(contentsOf: temp.paths.claudeSkillsPlugin.appendingPathComponent(".claude-plugin/plugin.json"), encoding: .utf8))
    #expect(manifest["name"]?.stringValue == "openclicky")
    #expect(FileManager.default.fileExists(atPath: temp.paths.claudeSkillsPlugin.appendingPathComponent("skills/openclicky-browser/references/tabs.md").path))
    #expect(FileManager.default.isExecutableFile(atPath: temp.paths.claudeSkillsPlugin.appendingPathComponent("skills/vercel-deploy/scripts/deploy.sh").path))
}

// MARK: - Waiting for helper processes

/// Waits for `process` to exit without blocking a thread. `waitUntilExit()` parks a cooperative thread on its run loop
/// with no time limit, and under a loaded full run it has hung the whole suite after the child was already gone.
/// Returns false, after terminating the process, if it is still running after `seconds`.
private func exits(_ process: Process, within seconds: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning {
        guard Date() < deadline else {
            process.terminate()
            return false
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}
