import AppKit
import OpenClickyKit
import SwiftUI

extension EvidenceSnapshots.Fixture {
    /// The skills page's other states: search and category filter, the catalog, the edit form, Remove and
    /// Deactivate all confirmations, and each step of creating a skill from notes (with a creation in progress).
    func renderSkillStates<V: View>(size: NSSize, view: () -> V, out: (String) -> URL) throws {
        let skills = services.skills
        services.chat.section = .skills
        // The shared fixture's skills predate categories; give them one each, as the edit form would.
        for (id, category, tags) in [("pitch-decks", "Design", ["slides", "keynote"]), ("writing-coach", "Writing", ["editing", "tone"]),
                                     ("spreadsheet-tidy-up", "Productivity", ["spreadsheets"])] {
            guard let skill = skills.library.skill(id) else { continue }
            var metadata = SkillMetadata(skill)
            metadata.category = category
            metadata.tags = tags
            _ = try? skills.library.update(id, metadata: metadata)
        }
        skills.reload()
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-library"))
        try EvidenceSnapshots.render(view(), size: size, dark: true, to: out("skills-library-dark"))

        skills.query = "keynote slides"
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-search"))
        skills.query = ""
        skills.category = "Productivity"
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-category"))
        skills.category = nil

        skills.tab = .catalog
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-catalog"))
        try EvidenceSnapshots.render(view(), size: size, dark: true, to: out("skills-catalog-dark"))
        if let entry = skills.catalogEntries.first(where: { $0.id == "trip-planner" }) { skills.addFromCatalog(entry) }
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-catalog-added"))
        skills.tab = .mine

        if let deck = skills.skills.first(where: { $0.id == "pitch-decks" }) {
            skills.beginEdit(deck)
            skills.draft.oneLiner = "One idea per slide, a clear ask"
            skills.draft.tags = "slides, keynote, storytelling"
            try EvidenceSnapshots.render(view(), size: size, to: out("skills-edit"))
            skills.saveDraft(openFile: false)
        }
        skills.beginNew()
        skills.draft.name = "Weekly status email"
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-new-incomplete"))
        skills.closePanel()

        skills.confirmingRemoval = "spreadsheet-tidy-up"
        skills.confirmingDeactivateAll = true
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-confirmations"))
        skills.confirmingRemoval = nil
        skills.confirmingDeactivateAll = false

        skills.beginBrainDump()
        skills.brainDump = """
        every friday I send my manager a status email. three headings: wins, risks, next week. \
        bullets, max 5 each, no fluff. link the PRs. sign off with just "J".
        """
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-notes-write"))
        skills.confirmBrainDump()
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-notes-confirm"))
        try skills.creator.store.save(SkillCreationRecord(id: "write-a-new-skill-3f9a1c2b7e", brainDump: skills.brainDump, createdAt: now))
        skills.reload()
        skills.panel = .brainDump(.creating(jobID: "write-a-new-skill-3f9a1c2b7e"))
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-notes-creating"))
        skills.closePanel()
        try EvidenceSnapshots.render(view(), size: size, to: out("skills-notes-pending"))
        skills.dismissCreation(skills.creations[0])
        skills.message = nil
    }
}
