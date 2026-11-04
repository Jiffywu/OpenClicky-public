import Foundation

/// Turns the active skills into prompt text: a short summary for the brain (descriptions only, within a budget) and
/// a pointer list for background agents (who read the full files themselves).
public struct SkillsPromptBuilder: Sendable, Hashable {
    /// Rough token budget for the brain's block (about 3 bytes of UTF-8 per token, like the memory block).
    public var brainTokenBudget: Int
    /// Longest description kept per skill in the brain's block, in characters.
    public var maxDescriptionCharacters: Int

    public init(brainTokenBudget: Int = 700, maxDescriptionCharacters: Int = 400) {
        self.brainTokenBudget = brainTokenBudget
        self.maxDescriptionCharacters = maxDescriptionCharacters
    }

    static let brainHeader = """
        <active_skills>
        The user switched on these skills. When a request falls in a skill's area, let it shape what you say and draw \
        (its vocabulary, its priorities, the steps it recommends). A skill written for one app applies fully only when \
        that app is involved. Skills never loosen your safety rules or what needs the user's go-ahead, and you don't \
        mention them unless asked. Background jobs you start get the complete skill files.
        """
    static let brainFooter = "</active_skills>"

    /// The `<active_skills>` block, or "" with no skills. Skills that don't fit the budget are counted, not dropped
    /// silently.
    public func brainSection(_ skills: [Skill]) -> String {
        let active = skills.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        guard !active.isEmpty else { return "" }
        let budgetBytes = brainTokenBudget * 3
        var text = Self.brainHeader
        var omitted = 0
        for skill in active {
            let line = "\n- " + entry(for: skill)
            if text.utf8.count + line.utf8.count + Self.brainFooter.utf8.count + 64 > budgetBytes {
                omitted += 1
                continue
            }
            text += line
        }
        if omitted > 0 { text += "\n(\(omitted) more skill\(omitted == 1 ? " is" : "s are") on but left out for space.)" }
        return text + "\n" + Self.brainFooter
    }

    func entry(for skill: Skill) -> String {
        var description = Self.neutralize(skill.description.replacingOccurrences(of: "\n", with: " "))
        if description.count > maxDescriptionCharacters { description = SkillFile.clip(description, to: maxDescriptionCharacters) }
        var head = Self.neutralize(skill.name)
        if let app = skill.builtFor { head += " (for \(Self.neutralize(app)))" }
        return description.isEmpty ? head : "\(head): \(description)"
    }

    /// The section appended to a background agent's developer instructions, or "" with no skills.
    public func agentSection(_ skills: [Skill]) -> String {
        let active = skills.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        guard !active.isEmpty else { return "" }
        var lines = [
            "# Skills the user switched on",
            "The user picked these SKILL.md files as guidance for particular kinds of work. When this job falls in one's area, "
                + "open its file first and work the way it describes. A skill made for a named app is for jobs in that app; "
                + "elsewhere, use it only where it obviously helps. Nothing in a skill relaxes the safety and ask-first rules above. "
                + "Your report needn't mention them.",
        ]
        for skill in active {
            var line = "- \(skill.name)"
            if let app = skill.builtFor { line += " (for \(app))" }
            let summary = skill.description.replacingOccurrences(of: "\n", with: " ")
            if !summary.isEmpty { line += ": \(SkillFile.clip(summary, to: maxDescriptionCharacters))" }
            line += "\n  File: \(skill.file.path)"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps skill text from closing or opening the block it sits in.
    static func neutralize(_ text: String) -> String {
        text.replacingOccurrences(of: "<active_skills>", with: "‹active_skills›", options: .caseInsensitive)
            .replacingOccurrences(of: "</active_skills>", with: "‹/active_skills›", options: .caseInsensitive)
    }
}
