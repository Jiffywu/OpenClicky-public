import Foundation

/// What the brain runtime and the agent launcher ask for: the active skills, ready to put in a prompt.
///
/// The brain runtime calls `skillsPromptSection()` when it builds its system prompt (the text only changes when the
/// user turns a skill on or off, so it can sit in the cached prefix). Background agents get the active skills
/// installed in their harness's skills folder at launch (`AgentManager.setSkillSources`, `AgentSkillSources`), and
/// the launch adds a skills section naming them (`AgentSkillNotes`).
public protocol ActiveSkillsProviding: Sendable {
    /// The `<active_skills>` block for the brain's prompt, or "" when no skill is on.
    func skillsPromptSection() -> String
    /// Extra text for a background agent's instructions. "" from `SkillsLibrary`: its skills reach agents installed,
    /// with the launch's skills section, so callers that still append this don't name them twice.
    func skillsAgentInstructions() -> String
}

/// A folder the library could not read as a skill.
public struct SkillLoadIssue: Sendable, Hashable {
    public var folder: URL
    public var message: String

    public init(folder: URL, message: String) {
        self.folder = folder
        self.message = message
    }
}

public enum SkillsLibraryError: Error, Equatable, CustomStringConvertible {
    case unknownSkill(String)
    case alreadyExists(String)
    case invalidName

    public var description: String {
        switch self {
        case .unknownSkill(let name): "There is no skill called \"\(name)\"."
        case .alreadyExists(let id): "A skill folder named \"\(id)\" already exists."
        case .invalidName: "A skill needs a name."
        }
    }
}

/// Local skills: one folder per skill under `~/Library/Application Support/OpenClicky/Skills/`, each with a SKILL.md.
/// Which skills are on lives in `skills.json` beside `config.json`, so the skill folders stay exactly as the user (or
/// another tool) wrote them. A skill found on disk starts off; the user turns it on.
public final class SkillsLibrary: @unchecked Sendable, ActiveSkillsProviding {
    public static var defaultDirectory: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("Skills", isDirectory: true)
    }

    public static var defaultStateURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("skills.json")
    }

    public let directory: URL
    public let stateURL: URL
    public var promptBuilder: SkillsPromptBuilder
    private let lock = NSLock()
    private let trash: @Sendable (URL) throws -> Void

    public init(directory: URL = SkillsLibrary.defaultDirectory, stateURL: URL = SkillsLibrary.defaultStateURL,
                promptBuilder: SkillsPromptBuilder = SkillsPromptBuilder(),
                trash: @escaping @Sendable (URL) throws -> Void = { url in
                    var destination: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                }) {
        self.trash = trash
        self.directory = directory
        self.stateURL = stateURL
        self.promptBuilder = promptBuilder
    }

    struct State: Codable, Equatable {
        var version = 1
        var enabled: [String] = []
    }

    // MARK: Listing

    /// Every skill folder, sorted by name, and the folders that couldn't be read.
    public func list() -> (skills: [Skill], issues: [SkillLoadIssue]) {
        lock.withLock { listLocked() }
    }

    public var skills: [Skill] { list().skills }

    /// The skills that are on, sorted by name.
    public func activeSkills() -> [Skill] { skills.filter(\.isEnabled) }

    /// A skill by folder name, or by its name ignoring case.
    public func skill(_ reference: String) -> Skill? {
        let all = skills
        return Self.resolve(reference, in: all)
    }

    static func resolve(_ reference: String, in skills: [Skill]) -> Skill? {
        let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = skills.first(where: { $0.id == wanted }) { return exact }
        let folded = wanted.lowercased()
        return skills.first { $0.id.lowercased() == folded || $0.name.lowercased() == folded }
            ?? skills.first { $0.id == SkillFile.slug(for: wanted) }
    }

    private func listLocked() -> (skills: [Skill], issues: [SkillLoadIssue]) {
        let enabled = Set(loadStateLocked().enabled)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return ([], []) }
        var skills: [Skill] = []
        var issues: [SkillLoadIssue] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            do {
                skills.append(try SkillFile.load(folder: entry, isEnabled: enabled.contains(entry.lastPathComponent)))
            } catch {
                issues.append(SkillLoadIssue(folder: entry, message: "\(error)"))
            }
        }
        skills.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        issues.sort { $0.folder.lastPathComponent < $1.folder.lastPathComponent }
        return (skills, issues)
    }

    // MARK: Turning skills on and off

    @discardableResult
    public func enable(_ reference: String) throws -> Skill { try setEnabled(reference, true) }

    @discardableResult
    public func disable(_ reference: String) throws -> Skill { try setEnabled(reference, false) }

    @discardableResult
    public func setEnabled(_ reference: String, _ on: Bool) throws -> Skill {
        try lock.withLock {
            guard var skill = Self.resolve(reference, in: listLocked().skills) else { throw SkillsLibraryError.unknownSkill(reference) }
            var state = loadStateLocked()
            state.enabled.removeAll { $0 == skill.id }
            if on { state.enabled.append(skill.id) }
            state.enabled.sort()
            try saveStateLocked(state)
            skill.isEnabled = on
            return skill
        }
    }

    /// Turns every skill off ("Deactivate all"). Returns how many were on.
    @discardableResult
    public func disableAll() throws -> Int {
        try lock.withLock {
            let wasOn = listLocked().skills.filter(\.isEnabled).count
            try saveStateLocked(State())
            return wasOn
        }
    }

    // MARK: Adding and removing

    /// Writes a new skill folder.
    @discardableResult
    public func create(name: String, description: String, builtFor: String? = nil, body: String, enable: Bool = false) throws -> Skill {
        try create(SkillMetadata(name: name, description: description, builtFor: builtFor), body: body, enable: enable)
    }

    /// Writes a new skill folder with every field the form has. The folder is named after the skill.
    @discardableResult
    public func create(_ metadata: SkillMetadata, body: String, enable: Bool = false) throws -> Skill {
        let metadata = metadata.normalized
        guard !metadata.name.isEmpty else { throw SkillsLibraryError.invalidName }
        let id = SkillFile.slug(for: metadata.name)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw SkillsLibraryError.alreadyExists(id) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SkillFile.render(metadata, body: body)
            .write(to: folder.appendingPathComponent(SkillFile.fileName), atomically: true, encoding: .utf8)
        return enable ? try self.enable(id) : try SkillFile.load(folder: folder)
    }

    /// Saves the edit form: rewrites the skill's front matter (keeping keys OpenClicky doesn't own) and, when given,
    /// its body. The folder keeps its name, so the skill's id and on/off state don't change with a rename.
    @discardableResult
    public func update(_ reference: String, metadata: SkillMetadata, body: String? = nil) throws -> Skill {
        try lock.withLock {
            guard let skill = Self.resolve(reference, in: listLocked().skills) else { throw SkillsLibraryError.unknownSkill(reference) }
            guard !metadata.normalized.name.isEmpty else { throw SkillsLibraryError.invalidName }
            var source = (try? String(contentsOf: skill.file, encoding: .utf8)) ?? ""
            if let body {
                let parsed = SkillFile.parse(source)
                // Keep the front matter block, swap the body.
                source = parsed.hadFrontMatter ? Self.frontMatterBlock(of: source) + "\n" + body : body
            }
            try SkillFile.applying(metadata, to: source).write(to: skill.file, atomically: true, encoding: .utf8)
            return try SkillFile.load(folder: skill.folder, isEnabled: skill.isEnabled)
        }
    }

    /// The `---` … `---` block at the top of a SKILL.md, or "".
    static func frontMatterBlock(of source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) })
        else { return "" }
        return lines[...end].joined(separator: "\n")
    }

    /// Copies a skill in: a folder holding SKILL.md, or a single Markdown file (which becomes the folder's SKILL.md).
    /// Hidden files (OpenClicky's install markers, `.DS_Store`) are left behind.
    @discardableResult
    public func importSkill(from source: URL) throws -> Skill {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw SkillFileError.missing(source.path)
        }
        let markdown = isDirectory.boolValue ? source.appendingPathComponent(SkillFile.fileName) : source
        let text = try SkillFile.readText(markdown)
        let parsed = SkillFile.parse(text)
        let base = isDirectory.boolValue ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let id = SkillFile.slug(for: parsed.name ?? base)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw SkillsLibraryError.alreadyExists(id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            if isDirectory.boolValue {
                try SkillFolder.copy(source, to: folder)
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // The text already read: the copy leaves out a SKILL.md that is a symbolic link.
            try text.write(to: folder.appendingPathComponent(SkillFile.fileName), atomically: true, encoding: .utf8)
            return try SkillFile.load(folder: folder)
        } catch {
            // A half-made folder would show up as a broken skill and block a retry with alreadyExists.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Moves a skill folder to the Trash and forgets that it was on.
    public func remove(_ reference: String) throws {
        try lock.withLock {
            guard let skill = Self.resolve(reference, in: listLocked().skills) else { throw SkillsLibraryError.unknownSkill(reference) }
            try trash(skill.folder)
            var state = loadStateLocked()
            state.enabled.removeAll { $0 == skill.id }
            try saveStateLocked(state)
        }
    }

    // MARK: Prompts

    public func skillsPromptSection() -> String { promptBuilder.brainSection(activeSkills()) }

    /// "" (see `ActiveSkillsProviding`). The old pointer list, for a harness that can't install skills, is
    /// `skillsAgentFallback()`.
    public func skillsAgentInstructions() -> String { "" }

    /// The active skills as a list of SKILL.md paths for an agent to open itself.
    public func skillsAgentFallback() -> String { promptBuilder.agentSection(activeSkills()) }

    // MARK: State file

    private func loadStateLocked() -> State {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private func saveStateLocked(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
