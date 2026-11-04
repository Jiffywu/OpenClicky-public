import Foundation

/// The fields of a skill the edit form changes: everything in the front matter OpenClicky reads. The body (the
/// guidance itself) is edited as Markdown in the file.
public struct SkillMetadata: Sendable, Hashable {
    public var name: String
    /// When the skill applies and what it changes. The brain sees this; agents see it in their skills list.
    public var description: String
    /// One short line for lists and cards.
    public var oneLiner: String?
    public var category: String?
    public var tags: [String]
    /// An app the skill is written for; it applies fully only when that app is involved.
    public var builtFor: String?

    public init(name: String, description: String, oneLiner: String? = nil, category: String? = nil, tags: [String] = [],
                builtFor: String? = nil) {
        self.name = name
        self.description = description
        self.oneLiner = oneLiner
        self.category = category
        self.tags = tags
        self.builtFor = builtFor
    }

    public init(_ skill: Skill) {
        self.init(name: skill.name, description: skill.description, oneLiner: skill.oneLiner, category: skill.category, tags: skill.tags,
                  builtFor: skill.builtFor)
    }

    /// Longest description agent harnesses accept (Codex and Claude Code both stop at 1,024 characters).
    public static let maxDescriptionLength = 1024
    public static let maxNameLength = 64
    public static let maxOneLinerLength = 120

    /// Trimmed, with empty optionals as nil and tags cleaned up (no commas, no duplicates, at most 12).
    public var normalized: SkillMetadata {
        func clean(_ text: String?) -> String? {
            guard let text = text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var seen = Set<String>()
        let tags = tags.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return SkillMetadata(name: clean(name) ?? "", description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                             oneLiner: clean(oneLiner), category: clean(category).map(SkillCategory.canonicalName), tags: Array(tags.prefix(12)),
                             builtFor: clean(builtFor))
    }

    /// What stops the form from saving, in plain words; empty when the skill can be saved.
    public var problems: [String] {
        let value = normalized
        var problems: [String] = []
        if value.name.isEmpty { problems.append("Give the skill a name.") }
        if value.name.count > Self.maxNameLength { problems.append("Keep the name under \(Self.maxNameLength) characters.") }
        if value.description.isEmpty { problems.append("Say when the skill applies and what it changes.") }
        if value.description.count > Self.maxDescriptionLength {
            problems.append("Keep the description under \(Self.maxDescriptionLength) characters (it's \(value.description.count)).")
        }
        if let line = value.oneLiner, line.count > Self.maxOneLinerLength { problems.append("Keep the one-liner under \(Self.maxOneLinerLength) characters.") }
        return problems
    }
}

// MARK: - Editing front matter in place

extension SkillFile {
    /// Front-matter keys OpenClicky owns, with the spellings it also reads. Editing replaces every spelling with the
    /// first one and leaves every other key (licence, allowed tools, metadata…) exactly as written.
    static let ownedKeys: [(key: String, aliases: [String])] = [
        ("name", ["name", "title"]),
        ("description", ["description"]),
        ("one_liner", ["one_liner", "one-liner", "oneliner", "summary"]),
        ("category", ["category"]),
        ("tags", ["tags"]),
        ("built_for", ["built_for", "built-for", "builtfor", "app"]),
    ]

    /// `source` with its front matter set to `metadata`: owned keys are rewritten in place (or added, or removed when
    /// empty), unknown keys and comments are kept, and the body is untouched. Adds front matter if there was none.
    /// Top-level keys in `removedKeys` (lower-case) are left out, with their continuation lines.
    public static func applying(_ metadata: SkillMetadata, to source: String, removingKeys removedKeys: Set<String> = []) -> String {
        let value = metadata.normalized
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        var frontMatter: [String] = []
        var body: [String] = lines
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            frontMatter = Array(lines[1..<end])
            body = Array(lines[(end + 1)...])
        }

        var entries = frontMatterEntries(frontMatter).filter { $0.key.map(removedKeys.contains) != true }
        let rendered: [String: [String]] = [
            "name": ["name: \(yamlScalar(value.name))"],
            "description": value.description.isEmpty ? [] : ["description: \(yamlScalar(value.description))"],
            "one_liner": value.oneLiner.map { ["one_liner: \(yamlScalar($0))"] } ?? [],
            "category": value.category.map { ["category: \(yamlScalar($0))"] } ?? [],
            "tags": value.tags.isEmpty ? [] : ["tags: [" + value.tags.map(yamlScalar).joined(separator: ", ") + "]"],
            "built_for": value.builtFor.map { ["built_for: \(yamlScalar($0))"] } ?? [],
        ]
        for (key, aliases) in ownedKeys {
            let matches = entries.indices.filter { entries[$0].key.map(aliases.contains) == true }
            let replacement = rendered[key] ?? []
            if let first = matches.first {
                entries[first] = FrontMatterEntry(key: replacement.isEmpty ? nil : key, lines: replacement)
                for index in matches.dropFirst().reversed() { entries.remove(at: index) }
            } else if !replacement.isEmpty {
                // New keys go after the last owned key (or at the top), so name and description stay first.
                let anchor = entries.lastIndex { entry in entry.key.map { k in ownedKeys.contains { $0.aliases.contains(k) } } == true }
                entries.insert(FrontMatterEntry(key: key, lines: replacement), at: anchor.map { $0 + 1 } ?? 0)
            }
        }
        let header = (["---"] + entries.flatMap(\.lines) + ["---"]).joined(separator: "\n")
        let bodyText = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return bodyText.isEmpty ? header + "\n" : header + "\n\n" + bodyText + "\n"
    }

    struct FrontMatterEntry {
        /// Lower-cased key, or nil for comments and blank lines.
        var key: String?
        var lines: [String]
    }

    /// Splits front matter into top-level entries, each with its continuation lines (indented lines, `- item` lines).
    /// Blank lines followed by more continuation lines stay with their entry, so a block scalar (`description: |`)
    /// with a blank line inside is kept whole.
    static func frontMatterEntries(_ lines: [String]) -> [FrontMatterEntry] {
        var entries: [FrontMatterEntry] = []
        var blanks: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blanks.append(line)
                continue
            }
            let indented = line.first == " " || line.first == "\t"
            let continues = indented || trimmed.hasPrefix("- ") || trimmed == "-"
            if continues, !entries.isEmpty, entries[entries.count - 1].key != nil {
                entries[entries.count - 1].lines += blanks + [line]
                blanks = []
                continue
            }
            entries += blanks.map { FrontMatterEntry(key: nil, lines: [$0]) }
            blanks = []
            if !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                entries.append(FrontMatterEntry(key: key.isEmpty ? nil : key, lines: [line]))
            } else {
                entries.append(FrontMatterEntry(key: nil, lines: [line]))
            }
        }
        return entries + blanks.map { FrontMatterEntry(key: nil, lines: [$0]) }
    }
}

// MARK: - Categories

/// Catalog categories, with an SF Symbol and a colour each. Skills may name any category; these are the ones the
/// filters offer.
public struct SkillCategory: Sendable, Hashable, Identifiable {
    public var name: String
    public var symbol: String
    /// `#RRGGBB`.
    public var color: String
    public var id: String { name }

    public init(name: String, symbol: String, color: String) {
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    public static let all: [SkillCategory] = [
        SkillCategory(name: "Writing", symbol: "pencil.line", color: "#C2410C"),
        SkillCategory(name: "Productivity", symbol: "checklist", color: "#2563EB"),
        SkillCategory(name: "Coding", symbol: "chevron.left.forwardslash.chevron.right", color: "#7C3AED"),
        SkillCategory(name: "Design", symbol: "paintpalette", color: "#DB2777"),
        SkillCategory(name: "Research", symbol: "magnifyingglass", color: "#0891B2"),
        SkillCategory(name: "Learning", symbol: "graduationcap", color: "#16A34A"),
        SkillCategory(name: "Finance", symbol: "chart.line.uptrend.xyaxis", color: "#059669"),
        SkillCategory(name: "Travel", symbol: "airplane", color: "#0EA5E9"),
        SkillCategory(name: "Video", symbol: "film", color: "#DC2626"),
        SkillCategory(name: "Music", symbol: "music.note", color: "#9333EA"),
        SkillCategory(name: "Marketing", symbol: "megaphone", color: "#EA580C"),
        SkillCategory(name: "Other", symbol: "square.grid.2x2", color: "#6B7280"),
    ]

    /// The known category whose name matches (ignoring case), else the name as given.
    public static func canonicalName(_ name: String) -> String {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name ?? name
    }

    /// The category for a skill's `category` field; unknown and missing ones fall under Other.
    public static func named(_ name: String?) -> SkillCategory {
        guard let name else { return all.last! }
        return all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? SkillCategory(name: name, symbol: "square.grid.2x2", color: "#6B7280")
    }
}

// MARK: - Search

public enum SkillSearch {
    /// Skills matching every word of `query` (in the name, one-liner, description, tags, category or app) and, when
    /// given, in `category`. Name matches sort first; otherwise the input order is kept.
    public static func filter(_ skills: [Skill], query: String, category: String? = nil) -> [Skill] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let inCategory = skills.filter { skill in
            guard let category, !category.isEmpty else { return true }
            return SkillCategory.named(skill.category).name.caseInsensitiveCompare(category) == .orderedSame
        }
        guard !words.isEmpty else { return inCategory }
        let scored: [(skill: Skill, score: Int, index: Int)] = inCategory.enumerated().compactMap { index, skill in
            let name = skill.name.lowercased() + " " + skill.id
            let haystack = [name, skill.oneLiner ?? "", skill.description, skill.tags.joined(separator: " "), skill.category ?? "",
                            skill.builtFor ?? ""].joined(separator: " ").lowercased()
            guard words.allSatisfy(haystack.contains) else { return nil }
            return (skill, words.filter(name.contains).count, index)
        }
        return scored.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.map(\.skill)
    }

    /// The categories present in `skills`, in `SkillCategory.all` order, with unknown ones after.
    public static func categories(in skills: [Skill]) -> [SkillCategory] {
        let present = Set(skills.map { SkillCategory.named($0.category).name })
        let known = SkillCategory.all.filter { present.contains($0.name) }
        let unknown = present.subtracting(known.map(\.name)).sorted().map { SkillCategory.named($0) }
        return known + unknown
    }
}

// MARK: - Copying skill folders

enum SkillFolder {
    /// Copies a skill folder, leaving out hidden files and folders (install markers, `.DS_Store`, `.git`) and
    /// symbolic links (a link could point anywhere on the Mac). Keeps the executable bit of scripts.
    static func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        for entry in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: keys) {
            let name = entry.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let target = destination.appendingPathComponent(name)
            if values.isDirectory == true {
                try copy(entry, to: target)
            } else if values.isRegularFile == true {
                try manager.copyItem(at: entry, to: target)
            }
        }
    }

    /// Every regular file under `folder` as (relative path, bytes), sorted by path; hidden entries skipped.
    static func files(in folder: URL) -> [(path: String, data: Data)] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [(String, Data)] = []
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let data = try? Data(contentsOf: file) else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            files.append((path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent, data))
        }
        return files.sorted { $0.0 < $1.0 }
    }
}
