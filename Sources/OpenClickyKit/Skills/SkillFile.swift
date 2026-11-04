import Foundation

/// A skill: a folder holding a SKILL.md whose front matter names it and says when it applies, and whose body is the
/// guidance itself. The same layout agent tools use, so a skill folder works in Claude Code or Codex unchanged.
public struct Skill: Sendable, Hashable, Identifiable {
    /// The folder name; stable, used by `occtl skills enable <id>`.
    public var id: String
    public var name: String
    /// When the skill applies and what it changes. This is what the brain sees.
    public var description: String
    public var oneLiner: String?
    /// An app the skill is written for ("Numbers", "Final Cut Pro"): it applies fully only when that app is involved.
    public var builtFor: String?
    public var tags: [String]
    /// A catalog category ("Writing", "Coding"); see `SkillCategory.all`.
    public var category: String?
    /// The markdown after the front matter.
    public var body: String
    public var folder: URL
    public var file: URL
    public var isEnabled: Bool
    /// Things the parser had to guess, shown next to the skill.
    public var warnings: [String]

    public init(id: String, name: String, description: String, oneLiner: String? = nil, builtFor: String? = nil, tags: [String] = [],
                category: String? = nil, body: String = "", folder: URL, file: URL? = nil, isEnabled: Bool = false, warnings: [String] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.oneLiner = oneLiner
        self.builtFor = builtFor
        self.tags = tags
        self.category = category
        self.body = body
        self.folder = folder
        self.file = file ?? folder.appendingPathComponent(SkillFile.fileName)
        self.isEnabled = isEnabled
        self.warnings = warnings
    }

    /// One line for lists: the one-liner, or the description's first sentence.
    public var summary: String {
        if let oneLiner, !oneLiner.isEmpty { return oneLiner }
        return SkillFile.firstSentence(of: description)
    }
}

public enum SkillFileError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case notMarkdown(String)
    case unreadable(String)
    case empty(String)
    case tooLarge(String, bytes: Int)

    public var description: String {
        switch self {
        case .missing(let path): "No \(SkillFile.fileName) in \(path)."
        case .notMarkdown(let path): "\(path) isn't a Markdown file."
        case .unreadable(let path): "\(path) couldn't be read as UTF-8 text."
        case .empty(let path): "\(path) is empty."
        case .tooLarge(let path, let bytes): "\(path) is \(bytes / 1024) KB; skills are limited to \(SkillFile.maxBytes / 1024) KB."
        }
    }
}

/// Reads SKILL.md: optional YAML-style front matter between `---` lines, then Markdown.
///
/// Only the small subset of YAML skill files use is understood: `key: value` pairs, quoted values, `|` and `>` block
/// values, and lists either inline (`[a, b]`) or as `- item` lines. Keys: `name`, `description`, `one_liner` (or
/// `one-liner`, `summary`), `built_for` (or `built-for`, `app`), `category`, `tags`. Anything else is ignored when
/// reading and kept as written when the form edits a skill (`SkillFile.applying`).
public enum SkillFile {
    public static let fileName = "SKILL.md"
    public static let maxBytes = 256 * 1024

    public struct Parsed: Sendable, Hashable {
        public var name: String?
        public var description: String?
        public var oneLiner: String?
        public var builtFor: String?
        public var tags: [String]
        public var category: String?
        public var body: String
        public var hadFrontMatter: Bool
    }

    /// Parses the text of a SKILL.md.
    public static func parse(_ source: String) -> Parsed {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        var fields: [String: FieldValue] = [:]
        var bodyStart = 0
        var hadFrontMatter = false
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            fields = parseFrontMatter(Array(lines[1..<end]))
            bodyStart = end + 1
            hadFrontMatter = true
        }
        let body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        func field(_ keys: String...) -> String? {
            for key in keys {
                if case .text(let value)? = fields[key] {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        var tags: [String] = []
        switch fields["tags"] {
        case .list(let items)?: tags = items
        case .text(let value)?: tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case nil: break
        }
        return Parsed(name: field("name", "title"), description: field("description"),
                      oneLiner: field("one_liner", "one-liner", "oneliner", "summary"),
                      builtFor: field("built_for", "built-for", "builtfor", "app"), tags: tags,
                      category: field("category"), body: body, hadFrontMatter: hadFrontMatter)
    }

    /// Loads the skill in `folder` (which must hold a SKILL.md).
    public static func load(folder: URL, isEnabled: Bool = false) throws -> Skill {
        let file = folder.appendingPathComponent(fileName)
        let text = try readText(file)
        let parsed = parse(text)
        var warnings: [String] = []
        let id = folder.lastPathComponent
        var name = parsed.name
        if name == nil {
            name = firstHeading(in: parsed.body) ?? humanize(id)
            warnings.append(parsed.hadFrontMatter ? "No name in the front matter; using \"\(name!)\"." : "No front matter; using \"\(name!)\" as the name.")
        }
        var description = parsed.description
        if description == nil {
            description = firstParagraph(of: parsed.body).map { clip($0, to: 300) } ?? ""
            warnings.append(description!.isEmpty ? "No description, so OpenClicky can't tell when it applies." : "No description; using the first paragraph.")
        }
        return Skill(id: id, name: name!, description: description!, oneLiner: parsed.oneLiner, builtFor: parsed.builtFor,
                     tags: parsed.tags, category: parsed.category, body: parsed.body, folder: folder, file: file, isEnabled: isEnabled,
                     warnings: warnings)
    }

    /// Reads a SKILL.md or an imported .md file as text, with the import errors HeyClicky distinguishes.
    public static func readText(_ file: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: file.path) else { throw SkillFileError.missing(file.deletingLastPathComponent().path) }
        let ext = file.pathExtension.lowercased()
        guard ["md", "markdown", "mdown"].contains(ext) else { throw SkillFileError.notMarkdown(file.lastPathComponent) }
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw SkillFileError.unreadable(file.lastPathComponent) }
        guard data.count <= maxBytes else { throw SkillFileError.tooLarge(file.lastPathComponent, bytes: data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw SkillFileError.unreadable(file.lastPathComponent) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillFileError.empty(file.lastPathComponent) }
        return text
    }

    /// A SKILL.md for a new skill.
    public static func render(name: String, description: String, builtFor: String? = nil, body: String) -> String {
        render(SkillMetadata(name: name, description: description, builtFor: builtFor), body: body)
    }

    /// A SKILL.md for a new skill, with every field the edit form has.
    public static func render(_ metadata: SkillMetadata, body: String) -> String {
        applying(metadata, to: "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
    }

    /// A folder name from a skill name: lowercase ASCII words joined by hyphens.
    public static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-"), !slug.isEmpty {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "skill" : String(slug.prefix(64))
    }

    // MARK: Helpers

    enum FieldValue: Equatable {
        case text(String)
        case list([String])
    }

    static func parseFrontMatter(_ lines: [String]) -> [String: FieldValue] {
        var fields: [String: FieldValue] = [:]
        var index = 0
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent(line) == 0, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[index]) > 0 {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                fields[key] = .text(folded ? foldBlock(block) : block.joined(separator: "\n"))
                continue
            }
            if value.isEmpty {
                // A list of "- item" lines, or a plain value continued on indented lines.
                var items: [String] = []
                var continued: [String] = []
                while index < lines.count, indent(lines[index]) > 0 || lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    if item.hasPrefix("- ") { items.append(unquote(String(item.dropFirst(2)))) } else if !item.isEmpty { continued.append(item) }
                    index += 1
                }
                fields[key] = items.isEmpty ? .text(continued.joined(separator: " ")) : .list(items)
                continue
            }
            if value.hasPrefix("["), value.hasSuffix("]") {
                let inner = value.dropFirst().dropLast()
                fields[key] = .list(inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
                continue
            }
            // Plain scalars may continue on more-indented lines.
            while index < lines.count, indent(lines[index]) > 0, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                value += " " + lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }
            fields[key] = .text(unquote(value))
        }
        return fields
    }

    static func foldBlock(_ lines: [String]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n")
    }

    static func unquote(_ value: String) -> String {
        var value = value
        // A trailing comment after a space ends a plain scalar.
        if !(value.hasPrefix("\"") || value.hasPrefix("'")), let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" {
            let inner = String(value.dropFirst().dropLast())
            if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
            // Double-quoted: one left-to-right pass, so an escaped backslash before an "n" stays a backslash.
            var out = ""
            var escaped = false
            for character in inner {
                if escaped {
                    switch character {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"", "\\", "/": out.append(character)
                    default: out.append("\\"); out.append(character)
                    }
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else {
                    out.append(character)
                }
            }
            if escaped { out.append("\\") }
            return out
        }
        return value
    }

    static func yamlScalar(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let leading: Set<Character> = ["[", "]", "{", "}", "-", "\"", "'", ">", "|", "*", "&", "!", "%", "@", "`", "?", ",", "#"]
        let keywords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]
        let needsQuotes = flat.isEmpty || flat.contains(":") || flat.contains("#") || flat.contains("\\")
            || flat.first.map(leading.contains) == true || keywords.contains(flat.lowercased()) || Double(flat) != nil
        guard needsQuotes else { return flat }
        return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func firstHeading(in body: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
            }
        }
        return nil
    }

    static func firstParagraph(of body: String) -> String? {
        var paragraph: [String] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(trimmed)
        }
        return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
    }

    static func firstSentence(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if let end = flat.range(of: ". ") { return String(flat[..<end.lowerBound]) + "." }
        return clip(flat, to: 140)
    }

    static func humanize(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}
