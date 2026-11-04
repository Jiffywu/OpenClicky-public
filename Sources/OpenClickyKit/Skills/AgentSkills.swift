import Foundation

/// Where a background agent's skill comes from.
public enum AgentSkillOrigin: String, Sendable, Codable, Hashable {
    /// Shipped with OpenClicky: the browser skill and the vendored `vercel-deploy`.
    case bundled
    /// Shipped with OpenClicky for one app, installed while that app is connected.
    case integration
    /// The user's own skill from the library, installed while it is switched on.
    case library
}

/// One skill to install into a harness's skills folder for a job.
public struct AgentSkillSource: Sendable, Hashable {
    /// Folder name in the harness's skills folder: lower-case letters, digits and hyphens, at most 64. Codex and
    /// Claude Code both know the skill by it (Claude Code as `openclicky:<name>`).
    public var name: String
    public var origin: AgentSkillOrigin
    /// The folder holding SKILL.md and anything it refers to (references, scripts, assets).
    public var folder: URL
    /// Replacement text for the installed SKILL.md; nil installs the file as it is. Library skills get front matter
    /// both harnesses accept (a plain name, a description of at most 1,024 characters).
    public var markdown: String?
    /// For people and the instructions: "Gmail", "Writing coach".
    public var title: String
    /// One line on when it applies.
    public var summary: String
    /// Integration skills: the app it is for.
    public var app: String?

    public init(name: String, origin: AgentSkillOrigin, folder: URL, markdown: String? = nil, title: String, summary: String, app: String? = nil) {
        self.name = name
        self.origin = origin
        self.folder = folder
        self.markdown = markdown
        self.title = title
        self.summary = summary
        self.app = app
    }

    /// `[a-z0-9-]`, no leading, trailing or doubled hyphens, at most 64 characters.
    public static func installName(_ text: String) -> String {
        var name = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { name.unicodeScalars.append(scalar) }
            else if !name.isEmpty, !name.hasSuffix("-") { name += "-" }
        }
        while name.hasSuffix("-") { name.removeLast() }
        name = String(name.prefix(64))
        while name.hasSuffix("-") { name.removeLast() }
        return name.isEmpty ? "skill" : name
    }
}

// MARK: - Shipped skills

/// The skills folder in OpenClickyKit's resources: `agent/` (installed for every job), `integrations/` (one per app)
/// and `catalog/` (starter skills users can add to their library).
public enum SkillResources {
    /// `OPENCLICKY_SKILL_RESOURCES` points at another folder with the same layout (tests, trying out new skills).
    public static var root: URL? {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_SKILL_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        var bundles: [Bundle] = []
        if let url = Bundle.main.url(forResource: "OpenClicky_OpenClickyKit", withExtension: "bundle"), let bundle = Bundle(url: url) {
            bundles.append(bundle)
        }
        bundles.append(Bundle.module)
        for bundle in bundles {
            if let url = bundle.url(forResource: "skills", withExtension: nil) { return url }
        }
        return nil
    }

    public static var agentFolder: URL? { root?.appendingPathComponent("agent", isDirectory: true) }
    public static var integrationsFolder: URL? { root?.appendingPathComponent("integrations", isDirectory: true) }
    public static var catalogFolder: URL? { root?.appendingPathComponent("catalog", isDirectory: true) }

    /// Sub-folders of `folder` that hold a SKILL.md, sorted by name.
    static func skillFolders(in folder: URL?) -> [URL] {
        guard let folder, let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(SkillFile.fileName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum BundledAgentSkills {
    /// Every skill under `agent/`: `openclicky-browser` and `vercel-deploy`.
    public static func all() -> [AgentSkillSource] {
        SkillResources.skillFolders(in: SkillResources.agentFolder).compactMap { folder in
            guard let skill = try? SkillFile.load(folder: folder) else { return nil }
            return AgentSkillSource(name: folder.lastPathComponent, origin: .bundled, folder: folder,
                                    title: humanTitle(folder.lastPathComponent), summary: SkillFile.firstSentence(of: skill.description))
        }
    }

    static func humanTitle(_ name: String) -> String {
        switch name {
        case "openclicky-browser": "Browser"
        case "vercel-deploy": "Vercel deploys"
        default: SkillFile.humanize(name)
        }
    }
}

// MARK: - Integration skills

/// A shipped skill for one app, installed for jobs while that app is connected.
public struct IntegrationSkill: Sendable, Hashable, Identifiable {
    /// Folder under `integrations/` and the installed skill's name.
    public var name: String
    public var app: String
    /// Composio toolkit slugs for the app.
    public var toolkits: [String]
    /// Words that identify the app in a connector's preset, id, name or server address (letters and digits only).
    public var aliases: [String]
    public var id: String { name }

    public init(name: String, app: String, toolkits: [String], aliases: [String]) {
        self.name = name
        self.app = app
        self.toolkits = toolkits
        self.aliases = aliases
    }

    public var folder: URL? {
        SkillResources.integrationsFolder?.appendingPathComponent(name, isDirectory: true)
    }

    public var source: AgentSkillSource? {
        guard let folder, let skill = try? SkillFile.load(folder: folder) else { return nil }
        return AgentSkillSource(name: name, origin: .integration, folder: folder, title: app,
                                summary: SkillFile.firstSentence(of: skill.description), app: app)
    }
}

public enum IntegrationSkills {
    public static let all: [IntegrationSkill] = [
        IntegrationSkill(name: "gmail", app: "Gmail", toolkits: ["gmail"], aliases: ["gmail", "googlemail"]),
        IntegrationSkill(name: "outlook", app: "Outlook", toolkits: ["outlook"], aliases: ["outlook", "office365", "microsoft365", "m365"]),
        IntegrationSkill(name: "google-docs", app: "Google Docs", toolkits: ["googledocs"], aliases: ["googledocs"]),
        IntegrationSkill(name: "google-tasks", app: "Google Tasks", toolkits: ["googletasks"], aliases: ["googletasks"]),
        IntegrationSkill(name: "clickup", app: "ClickUp", toolkits: ["clickup"], aliases: ["clickup"]),
        IntegrationSkill(name: "jira", app: "Jira", toolkits: ["jira"], aliases: ["jira", "atlassian"]),
        IntegrationSkill(name: "linear", app: "Linear", toolkits: ["linear"], aliases: ["linear"]),
        IntegrationSkill(name: "hubspot", app: "HubSpot", toolkits: ["hubspot"], aliases: ["hubspot"]),
        IntegrationSkill(name: "salesforce", app: "Salesforce", toolkits: ["salesforce"], aliases: ["salesforce"]),
        IntegrationSkill(name: "dropbox", app: "Dropbox", toolkits: ["dropbox"], aliases: ["dropbox"]),
        IntegrationSkill(name: "microsoft-teams", app: "Microsoft Teams", toolkits: ["microsoft_teams", "microsoftteams"],
                         aliases: ["microsoftteams", "msteams", "teams"]),
        IntegrationSkill(name: "notion", app: "Notion", toolkits: ["notion"], aliases: ["notion"]),
        IntegrationSkill(name: "github", app: "GitHub", toolkits: ["github"], aliases: ["github", "githubcopilot"]),
    ]

    public static func named(_ name: String) -> IntegrationSkill? {
        let key = normalize(name)
        return all.first { normalize($0.name) == key || normalize($0.app) == key || $0.toolkits.map(normalize).contains(key) }
    }

    /// The integration skills for what is connected now: enabled connectors whose preset, id, name or server
    /// address names a known app, and Composio toolkits (`composioToolkits` when OpenClicky asked Composio which
    /// accounts are connected, else the toolkits the user listed for the session).
    ///
    /// With `credentials`, only connections that are ready count: a connector that needs sign-in or is missing a
    /// token, header or environment value gets no skill, and neither does Composio without its key.
    public static func matching(registry: ConnectorRegistry, composioToolkits: [String]? = nil,
                                credentials: (any CredentialStore)? = nil) -> [IntegrationSkill] {
        var found = Set<String>()
        for connector in registry.connectors where connector.enabled {
            if let credentials, ConnectedAppsHub.status(of: connector, credentials: credentials) != .ready { continue }
            var words = Set<String>()
            for text in [connector.preset, connector.id, connector.name].compactMap({ $0 }) { words.formUnion(tokens(text)) }
            if let host = connector.transport.remoteURL?.host { words.formUnion(host.split(separator: ".").map { normalize(String($0)) }) }
            for skill in all where !Set(skill.aliases).isDisjoint(with: words) { found.insert(skill.name) }
        }
        let composioReady = credentials.map { (try? $0.secret(named: ComposioClient.credentialName))?.isEmpty == false } ?? true
        if let composio = registry.composio, composio.enabled, composioReady {
            let toolkits = Set((composioToolkits ?? composio.toolkits).map(normalize))
            for skill in all where !Set(skill.toolkits.map(normalize)).isDisjoint(with: toolkits) { found.insert(skill.name) }
        }
        return all.filter { found.contains($0.name) }
    }

    /// Lower-case letters and digits only.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The words of a name, and each pair of neighbours run together ("Google Docs" → google, docs, googledocs).
    static func tokens(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        var result = Set(words)
        result.insert(normalize(text))
        for index in words.indices.dropLast() { result.insert(words[index] + words[index + 1]) }
        return result
    }
}

// MARK: - A launch's skills

public enum AgentSkillSources {
    /// Every skill for a job right now: the bundled ones, an integration skill for each connected app that has one,
    /// and the user's switched-on library skills.
    public static func current(library: SkillsLibrary?, registry: ConnectorRegistry?, composioToolkits: [String]? = nil,
                               credentials: (any CredentialStore)? = nil) -> [AgentSkillSource] {
        var sources = BundledAgentSkills.all()
        if let registry {
            sources += IntegrationSkills.matching(registry: registry, composioToolkits: composioToolkits, credentials: credentials)
                .compactMap(\.source)
        }
        if let library {
            sources += self.library(library.activeSkills(), taken: Set(sources.map(\.name)))
        }
        return sources
    }

    /// The skills for a launch from what is really connected: ready connectors only, and the toolkits Composio says have
    /// an active account (asked through `directory`, which caches the answer; the listed toolkits when it can't say).
    public static func connected(library: SkillsLibrary?, registry: ConnectorRegistry?, credentials: any CredentialStore,
                                 directory: ComposioToolkitDirectory = .shared, composioBaseURL: URL = ComposioClient.defaultBaseURL,
                                 http: any HTTPTransport = URLSessionTransport()) async -> [AgentSkillSource] {
        let toolkits = await directory.activeToolkits(settings: registry?.composio, credentials: credentials, baseURL: composioBaseURL, http: http)
        return current(library: library, registry: registry, composioToolkits: toolkits, credentials: credentials)
    }

    /// The live set for the app and occtl: the library and connected apps at their usual places (or the folders
    /// `OPENCLICKY_SKILLS_DIR` and `OPENCLICKY_CONNECTORS_FILE` name).
    public static func standard(skillsDirectory: URL? = nil, skillsState: URL? = nil, connectorsFile: URL = ConnectorRegistry.defaultURL) -> [AgentSkillSource] {
        let library = SkillsLibrary(directory: skillsDirectory ?? SkillsLibrary.defaultDirectory, stateURL: skillsState ?? SkillsLibrary.defaultStateURL)
        return current(library: library, registry: try? ConnectorRegistry.load(from: connectorsFile))
    }

    /// Front-matter keys left out of the agents' copy of a library skill: Claude Code would treat `allowed-tools` as
    /// pre-approved and run skill `hooks` itself, both outside OpenClicky's ask-first approvals. The user's own file
    /// keeps them.
    static let permissionKeys: Set<String> = ["allowed-tools", "allowed_tools", "allowedtools", "hooks"]

    /// Library skills as agent skills, each with front matter both harnesses accept. Names already `taken` by
    /// shipped skills get a `my-` prefix.
    public static func library(_ skills: [Skill], taken: Set<String>) -> [AgentSkillSource] {
        var used = taken
        return skills.sorted { $0.id < $1.id }.map { skill in
            var name = AgentSkillSource.installName(skill.id)
            if used.contains(name) { name = AgentSkillSource.installName("my-" + name) }
            var counter = 2
            let base = name
            while used.contains(name) {
                name = AgentSkillSource.installName("\(base)-\(counter)")
                counter += 1
            }
            used.insert(name)
            var description = skill.description.isEmpty ? (skill.oneLiner ?? skill.name) : skill.description
            if let app = skill.builtFor { description += " Written for \(app): it applies fully to work in \(app)." }
            if description.count > SkillMetadata.maxDescriptionLength {
                description = SkillFile.clip(description, to: SkillMetadata.maxDescriptionLength - 1)
            }
            let original = (try? String(contentsOf: skill.file, encoding: .utf8)) ?? skill.body
            var metadata = SkillMetadata(skill)
            metadata.name = name
            metadata.description = description
            return AgentSkillSource(name: name, origin: .library, folder: skill.folder, markdown: SkillFile.applying(metadata, to: original, removingKeys: permissionKeys),
                                    title: skill.name, summary: skill.summary, app: skill.builtFor)
        }
    }
}

// MARK: - The instructions' skills section

public enum AgentSkillNotes {
    /// The name the harness shows for an installed skill.
    public static func displayName(_ name: String, harness: HarnessKind) -> String {
        harness == .claudeCode ? "\(AgentSkillInstaller.claudePluginName):\(name)" : name
    }

    /// The "Skills" section of a job's instructions: which installed skill to open before which kind of work, and
    /// the user's own skills. "" with no skills.
    public static func section(for skills: [AgentSkillSource], harness: HarnessKind) -> String {
        guard !skills.isEmpty else { return "" }
        func name(_ skill: AgentSkillSource) -> String { "`\(displayName(skill.name, harness: harness))`" }
        var lines = [
            "# Skills",
            "These skills are installed for this job and appear in your skills list. Open a skill's SKILL.md before the work it covers, and follow it.",
        ]
        for skill in skills where skill.origin == .bundled {
            switch skill.name {
            case "openclicky-browser": lines.append("- \(name(skill)): before your first call to the browser tool, and when choosing between the browser, a connected app and a plain fetch.")
            case "vercel-deploy": lines.append("- \(name(skill)): when the user asks to deploy, publish or share a site or web app on Vercel.")
            default: lines.append("- \(name(skill)): \(skill.summary)")
            }
        }
        let apps = skills.filter { $0.origin == .integration }
        if !apps.isEmpty {
            lines.append("- Connected apps, before your first call to each: " + apps.map { "\(name($0)) for \($0.app ?? $0.title)" }.joined(separator: ", ") + ".")
        }
        let mine = skills.filter { $0.origin == .library }
        if !mine.isEmpty {
            lines.append("The user switched on these skills of their own. When the job falls in one's area, work the way it describes; one written for a named app applies fully only to work in that app:")
            for skill in mine {
                var line = "- \(name(skill)) (\(skill.title))"
                if !skill.summary.isEmpty { line += ": \(SkillFile.clip(skill.summary, to: 200))" }
                lines.append(line)
            }
        }
        lines.append("Skills never relax the safety and ask-first rules above. Your report needn't mention them.")
        return lines.joined(separator: "\n")
    }

    /// `instructions` with the skills section appended (unchanged with no skills).
    public static func appending(to instructions: String, skills: [AgentSkillSource], harness: HarnessKind) -> String {
        let section = section(for: skills, harness: harness)
        return section.isEmpty ? instructions : instructions + "\n\n" + section
    }
}

extension AgentManager {
    /// Where every launch's skills come from, asked at each launch so a newly connected app or a skill switched on
    /// a moment ago is there for the next job. nil (the default) installs none and leaves the folders alone.
    public func setSkillSources(_ provider: (@Sendable () async -> [AgentSkillSource])?) {
        skillSources = provider
    }
}
