import Foundation

// The onboarding "What should it be good at?" picker (docs/re/08-apps-memory-ui.md §4.2). HeyClicky's picker lists
// vendored third-party skills; OpenClicky's lists only its own starter catalog (`Resources/skills/catalog`), grouped by
// the catalog's categories. One entry can bundle several skills. Picking switches those skills on in the library;
// background agents get them from the library's existing install sync.

/// One choice in the picker.
public struct SkillPickerEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    /// Catalog skill ids (folder names) this entry switches on.
    public var skillIDs: [String]
    /// The catalog category it is listed under (its first skill's).
    public var category: String

    public init(id: String, title: String, subtitle: String, symbol: String, skillIDs: [String], category: String = "") {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.skillIDs = skillIDs
        self.category = category
    }
}

public struct SkillPickerCategory: Sendable, Hashable, Identifiable {
    public var category: SkillCategory
    public var entries: [SkillPickerEntry]
    public var id: String { category.name }
}

/// What has been picked, saved at `skill-picks.json` beside `config.json`.
public struct SkillPickerSelection: Codable, Sendable, Hashable {
    public var picks: [String] = []
    /// The first-launch defaults were put in once; after that an empty selection stays empty.
    public var firstLaunchDefaultsApplied = false
    /// Skills the picker switched on, so unpicking an entry switches off only what the picker turned on.
    public var activatedSkillIDs: [String] = []

    public init(picks: [String] = [], firstLaunchDefaultsApplied: Bool = false, activatedSkillIDs: [String] = []) {
        self.picks = picks
        self.firstLaunchDefaultsApplied = firstLaunchDefaultsApplied
        self.activatedSkillIDs = activatedSkillIDs
    }
}

/// What `SkillPicker.activate` did.
public struct SkillPickerActivation: Sendable, Hashable {
    /// Copied from the catalog into the library (switched on).
    public var added: [String] = []
    /// Already in the library, switched on now.
    public var enabled: [String] = []
    /// Switched off because their entry was unpicked.
    public var disabled: [String] = []
    /// Skills that couldn't be switched on, with why.
    public var problems: [String] = []

    /// One line for the onboarding step list.
    public var summary: String {
        let on = added.count + enabled.count
        var parts: [String] = []
        if on > 0 { parts.append("Switched on \(on) skill\(on == 1 ? "" : "s")") }
        if !disabled.isEmpty { parts.append("switched off \(disabled.count)") }
        if parts.isEmpty { parts.append(problems.isEmpty ? "No skill changes" : "Skills weren't switched on") }
        return parts.joined(separator: ", ") + (problems.isEmpty ? "." : " (\(problems.count) problem\(problems.count == 1 ? "" : "s")).")
    }
}

public struct SkillPicker: Sendable {
    public var catalog: SkillCatalog
    public var stateURL: URL

    public static var defaultStateURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("skill-picks.json")
    }

    public init(catalog: SkillCatalog = SkillCatalog(), stateURL: URL = SkillPicker.defaultStateURL) {
        self.catalog = catalog
        self.stateURL = stateURL
    }

    /// The hand-made entries. Ids refer to OpenClicky's own catalog; an entry whose skills aren't all there is left out.
    public static let curated: [SkillPickerEntry] = [
        SkillPickerEntry(id: "meetings", title: "Meetings and follow-ups", subtitle: "Clean notes with owners and dates, then the follow-up email.",
                         symbol: "person.2.wave.2", skillIDs: ["meeting-notes", "writing-coach"]),
        SkillPickerEntry(id: "writing", title: "Writing", subtitle: "Tighter drafts that still sound like you.",
                         symbol: "pencil.line", skillIDs: ["writing-coach"]),
        SkillPickerEntry(id: "code-review", title: "Code review", subtitle: "Bugs first, then tests, then style.",
                         symbol: "chevron.left.forwardslash.chevron.right", skillIDs: ["code-review"]),
        SkillPickerEntry(id: "presentations", title: "Presentations", subtitle: "One message per slide, with words that land.",
                         symbol: "rectangle.on.rectangle", skillIDs: ["slide-decks", "writing-coach"]),
        SkillPickerEntry(id: "research", title: "Research", subtitle: "Sourced, dated answers with the gaps marked.",
                         symbol: "magnifyingglass", skillIDs: ["research-brief"]),
        SkillPickerEntry(id: "learning", title: "Learning something new", subtitle: "Explanations from where you are, then practice.",
                         symbol: "graduationcap", skillIDs: ["study-buddy", "research-brief"]),
        SkillPickerEntry(id: "money", title: "Money", subtitle: "Where it went and what keeps charging you.",
                         symbol: "chart.line.uptrend.xyaxis", skillIDs: ["budget-check"]),
        SkillPickerEntry(id: "trips", title: "Trips", subtitle: "Day-by-day plans with the bookings that matter.",
                         symbol: "airplane", skillIDs: ["trip-planner", "research-brief"]),
    ]

    /// Picked on first launch, before the user changes anything.
    public static let firstLaunchDefaults = ["research", "writing"]

    /// The picker's entries: the curated ones whose skills the catalog has, then one entry for any catalog skill no
    /// curated entry covers (so a new starter skill shows up without code changes).
    public func entries() -> [SkillPickerEntry] {
        let skills = catalog.entries()
        let byID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
        var result: [SkillPickerEntry] = []
        var covered = Set<String>()
        for var entry in Self.curated where entry.skillIDs.allSatisfy({ byID[$0] != nil }) {
            entry.category = SkillCategory.named(byID[entry.skillIDs[0]]?.category).name
            covered.formUnion(entry.skillIDs)
            result.append(entry)
        }
        for skill in skills where !covered.contains(skill.id) {
            let category = SkillCategory.named(skill.category)
            result.append(SkillPickerEntry(id: "skill-" + skill.id, title: skill.name, subtitle: skill.oneLiner ?? skill.description,
                                           symbol: category.symbol, skillIDs: [skill.id], category: category.name))
        }
        return result
    }

    /// Entries grouped by catalog category, in the catalog's category order.
    public func categories() -> [SkillPickerCategory] {
        let all = entries()
        var order = SkillCategory.all.map(\.name)
        for entry in all where !order.contains(entry.category) { order.append(entry.category) }
        return order.compactMap { name in
            let inCategory = all.filter { $0.category == name }
            return inCategory.isEmpty ? nil : SkillPickerCategory(category: SkillCategory.named(name), entries: inCategory)
        }
    }

    /// The catalog skills the picks bundle, each once, in pick order.
    public func skillIDs(for picks: [String]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: entries().map { ($0.id, $0) })
        var seen = Set<String>()
        return picks.compactMap { byID[$0] }.flatMap(\.skillIDs).filter { seen.insert($0).inserted }
    }

    // MARK: Saved selection

    public func load() -> SkillPickerSelection {
        guard let data = try? Data(contentsOf: stateURL),
              let selection = try? JSONDecoder().decode(SkillPickerSelection.self, from: data) else { return SkillPickerSelection() }
        return selection
    }

    public func save(_ selection: SkillPickerSelection) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(selection).write(to: stateURL, options: .atomic)
    }

    /// The saved picks, with the first-launch defaults put in (and saved) the first time only.
    public func loadPicks() -> [String] {
        var selection = load()
        if !selection.firstLaunchDefaultsApplied {
            let known = Set(entries().map(\.id))
            selection.picks = Self.firstLaunchDefaults.filter(known.contains)
            selection.firstLaunchDefaultsApplied = true
            try? save(selection)
        }
        return selection.picks
    }

    /// Saves the picks and switches their skills on in the library (copying them in from the catalog when needed).
    /// Skills the picker switched on earlier whose entries are no longer picked are switched off; skills the user turned
    /// on themselves are left alone.
    @discardableResult
    public func activate(_ picks: [String], library: SkillsLibrary) -> SkillPickerActivation {
        var selection = load()
        selection.firstLaunchDefaultsApplied = true
        let known = Set(entries().map(\.id))
        selection.picks = picks.filter(known.contains)
        let wanted = skillIDs(for: selection.picks)
        var result = SkillPickerActivation()
        let present = Dictionary(library.skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var activated: [String] = []
        for id in wanted {
            do {
                if let skill = present[id] {
                    if !skill.isEnabled {
                        try library.enable(id)
                        result.enabled.append(id)
                        activated.append(id)
                    } else if selection.activatedSkillIDs.contains(id) {
                        activated.append(id)
                    }
                } else {
                    try catalog.add(id, to: library, enable: true)
                    result.added.append(id)
                    activated.append(id)
                }
            } catch {
                result.problems.append("\(id): \(error)")
            }
        }
        for id in selection.activatedSkillIDs where !wanted.contains(id) {
            guard present[id]?.isEnabled == true else { continue }
            if (try? library.disable(id)) != nil { result.disabled.append(id) }
        }
        selection.activatedSkillIDs = activated
        do { try save(selection) } catch { result.problems.append("picks not saved: \(error)") }
        return result
    }
}
