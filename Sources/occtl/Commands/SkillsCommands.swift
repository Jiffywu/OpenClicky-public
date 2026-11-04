import Foundation
import OpenClickyKit

/// `occtl skills …`: the local skills library, the starter catalog, skills written from a brain dump, and the skills
/// background agents get.
enum SkillsCommands {
    static let usageText = """
        Usage:
          occtl skills list [--category C]          every skill, on or off, and folders that couldn't be read
          occtl skills search <words> [--category C]
          occtl skills show <skill>                 the parsed front matter and the start of the body
          occtl skills enable <skill>               turn a skill on (folder name or skill name)
          occtl skills disable <skill>              turn a skill off
          occtl skills deactivate-all               turn every skill off (also: occtl skills disable --all)
          occtl skills edit <skill> [--name N] [--one-liner T] [--description D] [--category C] [--tags a,b]
                                    [--built-for APP] [--body-file F]
                                                    the edit form: change the front matter (and the body from a file)
          occtl skills remove <skill>               move the skill's folder to the Trash
          occtl skills add <file.md|folder>         copy a SKILL.md (or a folder holding one) into the library
          occtl skills new <name> <description> [--category C] [--tags a,b] [--one-liner T] [--built-for APP]
                                                    write an empty skill to fill in
          occtl skills categories                   the catalog's categories
          occtl skills catalog [words] [--category C]   the starter skills that ship with OpenClicky
          occtl skills catalog add <skill> [--on]   copy a starter skill into the library
          occtl skills create <brain dump…> [--wait] [--harness codex|claude-code] [--login] [--model M] [--yes]
                                                    a background agent writes the skill; it lands in the library, off
          occtl skills creations                    skills being written, and finished ones (brings finished ones in)
          occtl skills agent [--install] [--harness codex|claude-code]
                                                    the skills a job gets now; --install copies them into the
                                                    harness folders (CODEX_HOME/skills and the Claude Code plugin)
          occtl skills prompt [--agent [--harness H]]   the block the brain gets (or the skills section agents get)
        Skills live in \(SkillsLibrary.defaultDirectory.path)
        (set OPENCLICKY_SKILLS_DIR to use another folder; its on/off state is then kept beside it).
        """

    static let skills = OcctlCommand(name: "skills", usage: "skills <list|search|edit|remove|deactivate-all|catalog|create|agent|…>  the skills library") { args in
        let library = library()
        guard let verb = args.first else { fail(usageText) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "list", "ls":
            let options = Options(rest)
            list(library, category: options.value("--category"))
        case "search", "find":
            let options = Options(rest)
            guard !options.positional.isEmpty || options.value("--category") != nil else { fail("Usage: occtl skills search <words> [--category C]") }
            let found = SkillSearch.filter(library.skills, query: options.positional.joined(separator: " "), category: options.value("--category"))
            if found.isEmpty { print("No skills match.") }
            for skill in found { printRow(skill) }
        case "enable", "on":
            guard !rest.isEmpty else { fail("Usage: occtl skills enable <skill>") }
            let skill = try library.enable(rest.joined(separator: " "))
            print("On: \(skill.name) (\(skill.id))")
        case "disable", "off":
            if rest == ["--all"] {
                deactivateAll(library)
                return
            }
            guard !rest.isEmpty else { fail("Usage: occtl skills disable <skill> | --all") }
            let skill = try library.disable(rest.joined(separator: " "))
            print("Off: \(skill.name) (\(skill.id))")
        case "deactivate-all":
            deactivateAll(library)
        case "show":
            guard let skill = library.skill(rest.joined(separator: " ")) else { fail("No skill called \"\(rest.joined(separator: " "))\".") }
            show(skill)
        case "edit":
            try edit(library, rest)
        case "remove", "rm", "delete":
            guard !rest.isEmpty else { fail("Usage: occtl skills remove <skill>") }
            guard let skill = library.skill(rest.joined(separator: " ")) else { fail("No skill called \"\(rest.joined(separator: " "))\".") }
            try library.remove(skill.id)
            print("Removed \(skill.name) (\(skill.id)); its folder is in the Trash.")
        case "add", "import":
            guard rest.count == 1 else { fail("Usage: occtl skills add <file.md|folder>") }
            let skill = try library.importSkill(from: URL(fileURLWithPath: (rest[0] as NSString).expandingTildeInPath))
            print("Added \(skill.name) (\(skill.id)), off. Turn it on with: occtl skills enable \(skill.id)")
        case "new":
            let options = Options(rest)
            guard options.positional.count >= 2 else { fail("Usage: occtl skills new <name> <description> [--category C] [--tags a,b]") }
            let metadata = SkillMetadata(name: options.positional[0], description: options.positional.dropFirst().joined(separator: " "),
                                         oneLiner: options.value("--one-liner"), category: options.value("--category"),
                                         tags: options.value("--tags").map { [$0] } ?? [], builtFor: options.value("--built-for"))
            if let problem = metadata.problems.first { fail(problem) }
            let skill = try library.create(metadata, body: "Write the guidance here: when it applies, the steps, what to avoid.")
            print("Wrote \(skill.file.path)")
        case "categories":
            let counts = Dictionary(grouping: SkillCatalog().entries() + library.skills) { SkillCategory.named($0.category).name }.mapValues(\.count)
            for category in SkillCategory.all { print("\(category.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(counts[category.name] ?? 0)") }
        case "catalog":
            try catalog(library, rest)
        case "create":
            try await create(library, rest)
        case "creations":
            try await creations(library, rest)
        case "agent":
            agent(library, rest)
        case "prompt":
            if rest.contains("--agent") {
                let options = Options(rest.filter { $0 != "--agent" })
                let harness = options.value("--harness").flatMap(HarnessKind.init(rawValue:)) ?? .codex
                let text = AgentSkillNotes.section(for: agentSources(library), harness: harness)
                print(text.isEmpty ? "(no skills)" : text)
            } else {
                let text = library.skillsPromptSection()
                print(text.isEmpty ? "(no skills are on)" : text)
            }
        default:
            fail(usageText)
        }
    }

    static func library() -> SkillsLibrary {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_SKILLS_DIR"], !override.isEmpty {
            let directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            return SkillsLibrary(directory: directory,
                                 stateURL: directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + "-state.json"))
        }
        return SkillsLibrary()
    }

    /// The skills a job gets now: bundled, one per connected app, and the library's switched-on ones.
    static func agentSources(_ library: SkillsLibrary) -> [AgentSkillSource] {
        AgentSkillSources.current(library: library, registry: try? ConnectorRegistry.load())
    }

    /// Gives an occtl-made manager the same skills the app's jobs get.
    static func useSkills(_ manager: AgentManager, includesConnectedApps: Bool = true) async {
        let library = library()
        await manager.setSkillSources {
            guard includesConnectedApps else { return AgentSkillSources.current(library: library, registry: nil) }
            // Only what is really connected: ready connectors and the toolkits Composio reports as active.
            return await AgentSkillSources.connected(library: library, registry: try? ConnectorRegistry.load(), credentials: KeychainCredentialStore())
        }
    }

    // MARK: Small option parser

    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        static let valued: Set<String> = ["--category", "--name", "--one-liner", "--description", "--tags", "--built-for", "--body-file",
                                          "--harness", "--model"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.valued.contains(arg) {
                    guard index + 1 < args.count else { fail("\(arg) needs a value.") }
                    values[arg] = args[index + 1]
                    index += 2
                    continue
                }
                if arg.hasPrefix("--") { flags.insert(arg) } else { positional.append(arg) }
                index += 1
            }
        }

        func value(_ key: String) -> String? { values[key] }
    }

    // MARK: Listing

    static func list(_ library: SkillsLibrary, category: String?) {
        let listing = library.list()
        if listing.skills.isEmpty && listing.issues.isEmpty {
            print("No skills yet. Put a folder with a SKILL.md in \(library.directory.path), run occtl skills add <file.md>, or pick one from occtl skills catalog.")
            return
        }
        let skills = category.map { SkillSearch.filter(listing.skills, query: "", category: $0) } ?? listing.skills
        for skill in skills { printRow(skill) }
        if category == nil {
            for issue in listing.issues { print("[??]  \(issue.folder.lastPathComponent)  \(issue.message)") }
        }
        let on = listing.skills.filter(\.isEnabled).count
        print("\(listing.skills.count) skill\(listing.skills.count == 1 ? "" : "s"), \(on) on.")
    }

    static func printRow(_ skill: Skill, mark: String? = nil) {
        let mark = mark ?? (skill.isEnabled ? "[on] " : "[off]")
        var line = "\(mark) \(skill.id)  \(skill.name)"
        if let app = skill.builtFor { line += " (for \(app))" }
        line += "  · \(SkillCategory.named(skill.category).name)"
        print(line)
        if !skill.summary.isEmpty { print("        \(skill.summary)") }
        if !skill.tags.isEmpty { print("        tags: \(skill.tags.joined(separator: ", "))") }
        for warning in skill.warnings { print("        note: \(warning)") }
    }

    static func show(_ skill: Skill) {
        print("\(skill.name)  [\(skill.id)]  \(skill.isEnabled ? "on" : "off")")
        print("description: \(skill.description)")
        if let line = skill.oneLiner { print("one-liner: \(line)") }
        print("category: \(skill.category ?? "(none)")")
        if !skill.tags.isEmpty { print("tags: \(skill.tags.joined(separator: ", "))") }
        if let app = skill.builtFor { print("built for: \(app)") }
        for warning in skill.warnings { print("note: \(warning)") }
        print("file: \(skill.file.path)")
        print("---")
        print(String(skill.body.prefix(800)) + (skill.body.count > 800 ? "\n…" : ""))
    }

    static func deactivateAll(_ library: SkillsLibrary) {
        do {
            let count = try library.disableAll()
            print(count == 0 ? "No skills were on." : "Turned off \(count) skill\(count == 1 ? "" : "s").")
        } catch {
            fail("Couldn't turn the skills off: \(error)")
        }
    }

    // MARK: Edit

    static func edit(_ library: SkillsLibrary, _ args: [String]) throws {
        let options = Options(args)
        guard !options.positional.isEmpty else { fail("Usage: occtl skills edit <skill> [--name N] [--one-liner T] [--description D] [--category C] [--tags a,b] [--built-for APP] [--body-file F]") }
        guard let skill = library.skill(options.positional.joined(separator: " ")) else { fail("No skill called \"\(options.positional.joined(separator: " "))\".") }
        var metadata = SkillMetadata(skill)
        if let value = options.value("--name") { metadata.name = value }
        if let value = options.value("--description") { metadata.description = value }
        if let value = options.value("--one-liner") { metadata.oneLiner = value }
        if let value = options.value("--category") { metadata.category = value }
        if let value = options.value("--tags") { metadata.tags = [value] }
        if let value = options.value("--built-for") { metadata.builtFor = value }
        if let problem = metadata.problems.first { fail(problem) }
        var body: String?
        if let path = options.value("--body-file") {
            body = try String(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), encoding: .utf8)
        }
        let updated = try library.update(skill.id, metadata: metadata, body: body)
        print("Saved \(updated.file.path)")
        show(updated)
    }

    // MARK: Catalog

    static func catalog(_ library: SkillsLibrary, _ args: [String]) throws {
        let catalog = SkillCatalog()
        if args.first == "add" {
            let options = Options(Array(args.dropFirst()))
            guard !options.positional.isEmpty else { fail("Usage: occtl skills catalog add <skill> [--on]") }
            let skill = try catalog.add(options.positional.joined(separator: " "), to: library, enable: options.flags.contains("--on"))
            print("Added \(skill.name) (\(skill.id)) to your skills, \(skill.isEnabled ? "on" : "off").")
            return
        }
        let options = Options(args)
        let entries = catalog.search(options.positional.joined(separator: " "), category: options.value("--category"))
        if entries.isEmpty { print("No starter skills match.") }
        for entry in entries { printRow(entry, mark: catalog.isInLibrary(entry, library: library) ? "[added]" : "[ ]    ") }
        print("\(entries.count) of \(catalog.entries().count) starter skills. Add one with: occtl skills catalog add <skill>")
    }

    // MARK: Creating from a brain dump

    static func create(_ library: SkillsLibrary, _ args: [String]) async throws {
        let wait = args.contains("--wait")
        let agentArgs = args.filter { $0 != "--wait" }
        let options = AgentCommands.parse(agentArgs)
        let notes = options.positional.joined(separator: " ")
        guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("Usage: occtl skills create <brain dump…> [--wait]") }
        let manager = await AgentCommands.makeManager(options)
        let creator = SkillCreator(library: library)
        let updates = await manager.subscribe()
        let record = try await creator.start(brainDump: notes, manager: manager,
                                             preference: AgentLaunchPreference(harness: options.harness, login: options.login), waitForStart: true)
        print("Writing the skill in job \(record.jobID).")
        guard wait else {
            print("Check on it with: occtl skills creations")
            return
        }
        _ = await AgentCommands.follow(record.jobID, manager: manager, updates: updates, autoApprove: options.yes)
        let changed = await creator.collect(manager: manager)
        report(changed.first { $0.id == record.id } ?? creator.store.record(record.id), library: library)
    }

    static func creations(_ library: SkillsLibrary, _ args: [String]) async throws {
        let manager = AgentManager(store: AgentJobStore()) { _ in throw AgentManagerError.configuration("occtl skills creations doesn't start jobs.") }
        let creator = SkillCreator(library: library)
        _ = await creator.collect(manager: manager)
        let all = creator.store.all()
        if all.isEmpty { print("No skills are being written. Start one with: occtl skills create <brain dump…>") }
        for record in all { report(record, library: library) }
    }

    static func report(_ record: SkillCreationRecord?, library: SkillsLibrary) {
        guard let record else { return }
        let notes = record.brainDump.replacingOccurrences(of: "\n", with: " ")
        print("\(record.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) job \(record.jobID)  \"\(String(notes.prefix(60)))\(notes.count > 60 ? "…" : "")\"")
        if let id = record.skillID, let skill = library.skill(id) {
            print("          → \(skill.name) (\(skill.id)), off. Review it with: occtl skills show \(skill.id); turn it on with: occtl skills enable \(skill.id)")
        }
        if let message = record.message { print("          \(message)") }
    }

    // MARK: What agents get

    static func agent(_ library: SkillsLibrary, _ args: [String]) {
        let options = Options(args)
        let sources = agentSources(library)
        for source in sources {
            print("\(source.origin.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(source.name)  \(source.title)")
        }
        guard options.flags.contains("--install") else {
            print("\(sources.count) skill\(sources.count == 1 ? "" : "s"). Copy them into the harness folders with --install.")
            return
        }
        let paths = AgentPaths.default
        let harnesses: [HarnessKind] = options.value("--harness").flatMap(HarnessKind.init(rawValue:)).map { [$0] } ?? [.codex, .claudeCode]
        for harness in harnesses {
            do {
                let result = harness == .codex
                    ? try AgentSkillInstaller.sync(sources, into: paths.codexSkills)
                    : try AgentSkillInstaller.syncClaudePlugin(sources, at: paths.claudeSkillsPlugin)
                let folder = harness == .codex ? paths.codexSkills : paths.claudeSkillsPlugin
                print("\(harness.rawValue): \(result.installed.count) installed in \(folder.path)"
                      + (result.updated.isEmpty ? "" : "; updated \(result.updated.joined(separator: ", "))")
                      + (result.removed.isEmpty ? "" : "; removed \(result.removed.joined(separator: ", "))"))
                for name in result.conflicts { print("  skipped \(name): a folder OpenClicky didn't make is already there") }
                for (name, reason) in result.failures.sorted(by: { $0.key < $1.key }) { print("  couldn't install \(name): \(reason)") }
            } catch {
                print("\(harness.rawValue): \(error)")
            }
        }
    }
}
