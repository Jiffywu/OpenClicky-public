import Foundation

/// `about-the-user.md`: what OpenClicky knows about the person, as a markdown document they can edit by hand.
///
/// The document is kept as its raw lines, so whatever the user writes survives a load/save round trip unchanged.
/// Structure is read from the headings: a `## ` heading starts a section, and a `# ` heading starts a group of
/// sections. Lines starting with `- `, `* ` or `+ ` inside a section are its items ("bullets"); other text is kept
/// and shown to the brain as written. Sections in the "Right now" group hold things that go stale, and are the first
/// trimmed when the profile outgrows its budget.
public struct MemoryProfile: Sendable, Hashable {
    public private(set) var lines: [String]

    public struct Section: Sendable, Hashable {
        public var title: String
        /// The `# ` heading above it, if any.
        public var group: String?
        /// Index of the `## ` heading line.
        public var headingLine: Int
        /// The lines after the heading up to the next heading.
        public var body: Range<Int>
    }

    public struct Bullet: Sendable, Hashable, Identifiable {
        public var id: String
        public var section: String
        public var text: String
        public var line: Int
    }

    public init(text: String) {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        self.lines = lines
    }

    /// The document as text, ending with one newline.
    public var text: String { lines.joined(separator: "\n") + "\n" }

    public var characterCount: Int { lines.reduce(0) { $0 + $1.count + 1 } }

    // MARK: - Template

    /// The group whose sections hold short-lived context.
    public static let volatileGroup = "Right now"

    /// Sections of a fresh profile, by group.
    public static let defaultLayout: [(group: String, sections: [String])] = [
        ("About the user", ["Basics", "Work and background", "Goals", "People", "Routines", "Tools and apps",
                            "How they like answers", "Writing style"]),
        (volatileGroup, ["Current projects", "Recent asks"]),
    ]

    public static let template: MemoryProfile = {
        var lines: [String] = []
        for (index, group) in defaultLayout.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("# \(group.group)")
            lines.append("")
            if index == 0 {
                lines.append("What OpenClicky has learned about the person it helps. It stays on this Mac.")
                lines.append("Edit anything here; delete a line and OpenClicky forgets it.")
                lines.append("")
            }
            for (sectionIndex, section) in group.sections.enumerated() {
                if sectionIndex > 0 { lines.append("") }
                lines.append("## \(section)")
            }
        }
        return MemoryProfile(text: lines.joined(separator: "\n"))
    }()

    // MARK: - Reading

    public var sections: [Section] {
        var result: [Section] = []
        var group: String?
        var open: (title: String, group: String?, heading: Int)?
        func close(at end: Int) {
            if let current = open { result.append(Section(title: current.title, group: current.group, headingLine: current.heading, body: (current.heading + 1)..<end)) }
            open = nil
        }
        for (index, line) in lines.enumerated() {
            if let title = Self.heading(line, level: 1) {
                close(at: index)
                group = title
            } else if let title = Self.heading(line, level: 2) {
                close(at: index)
                open = (title, group, index)
            }
        }
        close(at: lines.count)
        return result
    }

    public func section(named title: String) -> Section? {
        let wanted = Self.sectionKey(title)
        return sections.first { Self.sectionKey($0.title) == wanted }
    }

    public var bullets: [Bullet] {
        sections.flatMap { section in
            section.body.compactMap { index -> Bullet? in
                guard let text = Self.bulletText(lines[index]) else { return nil }
                return Bullet(id: MemoryID.profile(section: section.title, text: text), section: section.title, text: text, line: index)
            }
        }
    }

    /// The non-blank lines of a section, bullets without their markers. Comment lines (`<!-- … -->`) are skipped.
    public func content(of section: Section) -> [String] {
        section.body.compactMap { index in
            let line = lines[index]
            if let bullet = Self.bulletText(line) { return bullet }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("<!--") || Self.bulletMarker(trimmed) { return nil }
            return trimmed
        }
    }

    public func isVolatile(_ section: Section) -> Bool {
        section.group.map { Self.sectionKey($0) == Self.sectionKey(Self.volatileGroup) } ?? false
    }

    // MARK: - Editing

    /// Adds `text` as an item of the section, creating the section when the document has none by that name.
    /// Returns false (and changes nothing) when the section already has an item saying the same thing.
    @discardableResult
    public mutating func add(_ text: String, to sectionTitle: String) -> Bool {
        let item = MemoryText.oneLine(text)
        guard !item.isEmpty else { return false }
        if let section = section(named: sectionTitle) {
            if content(of: section).contains(where: { MemoryText.isDuplicate($0, item) }) { return false }
            // After the section's last non-blank line, or right under the heading.
            var insertAt = section.headingLine + 1
            for index in section.body where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { insertAt = index + 1 }
            lines.insert("- \(item)", at: insertAt)
            // Keep a blank line before the next heading.
            if insertAt + 1 < lines.count, Self.heading(lines[insertAt + 1], level: 1) != nil || Self.heading(lines[insertAt + 1], level: 2) != nil {
                lines.insert("", at: insertAt + 1)
            }
            return true
        }
        // A new section goes at the end of the first group (before the next `# ` heading), else at the end.
        let firstGroupEnd = lines.indices.dropFirst().first { index in
            Self.heading(lines[index], level: 1) != nil && lines[..<index].contains { Self.heading($0, level: 1) != nil }
        } ?? lines.count
        var block = ["## \(MemoryText.oneLine(sectionTitle))", "- \(item)"]
        var insertAt = firstGroupEnd
        while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        if insertAt > 0 { block.insert("", at: 0) }
        // Whatever follows was either a blank line (walked back over above) or a heading that needs one.
        if insertAt < lines.count, !lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty { block.append("") }
        lines.insert(contentsOf: block, at: insertAt)
        return true
    }

    /// Removes the item with this id. Returns it, or nil when there is none.
    @discardableResult
    public mutating func removeBullet(id: String) -> Bullet? {
        guard let bullet = bullets.first(where: { $0.id == id }) else { return nil }
        lines.remove(at: bullet.line)
        return bullet
    }

    /// Removes the item that best matches `text` (in `sectionTitle` when given and present, else anywhere).
    @discardableResult
    public mutating func removeBullet(matching text: String, in sectionTitle: String? = nil, threshold: Double = 0.6) -> Bullet? {
        var candidates = bullets
        if let title = sectionTitle, let section = section(named: title) {
            let inSection = candidates.filter { $0.section == section.title }
            if !inSection.isEmpty { candidates = inSection }
        }
        let wanted = MemoryText.normalized(text)
        let best = candidates.first { MemoryText.normalized($0.text) == wanted }
            ?? candidates.map { ($0, MemoryText.similarity($0.text, text)) }.filter { $0.1 >= threshold }.max { $0.1 < $1.1 }?.0
        guard let match = best else { return nil }
        lines.remove(at: match.line)
        return match
    }

    /// Drops the oldest (topmost) item of the fullest "Right now" section; on a tie, of the later section ("Recent
    /// asks" goes stale before "Current projects"). The item with id `keep` is never chosen. Returns the dropped
    /// item, or nil when there is none to drop.
    @discardableResult
    public mutating func dropOldestVolatileBullet(keeping keep: String? = nil) -> Bullet? {
        let all = bullets.filter { $0.id != keep }
        var fullest: [Bullet] = []
        for section in sections where isVolatile(section) {
            let items = all.filter { section.body.contains($0.line) }
            if !items.isEmpty, items.count >= fullest.count { fullest = items }
        }
        guard let oldest = fullest.first else { return nil }
        lines.remove(at: oldest.line)
        return oldest
    }

    // MARK: - Line syntax

    static func heading(_ line: String, level: Int) -> String? {
        let marker = String(repeating: "#", count: level) + " "
        guard line.hasPrefix(marker) else { return nil }
        let title = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    static func bulletText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func bulletMarker(_ trimmed: String) -> Bool { trimmed == "-" || trimmed == "*" || trimmed == "+" }

    /// Section names compare without case, punctuation or "&"/"and" differences.
    static func sectionKey(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
