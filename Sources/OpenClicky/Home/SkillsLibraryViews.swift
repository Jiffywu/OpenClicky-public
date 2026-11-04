import AppKit
import OpenClickyKit
import SwiftUI

// MARK: - Model

/// The edit form's fields as the user types them (tags as one comma-separated line).
struct SkillDraft: Equatable {
    /// The skill being edited; nil for a new one.
    var editingID: String?
    var name = ""
    var oneLiner = ""
    var description = ""
    var category = ""
    var tags = ""
    var builtFor = ""

    init(editingID: String? = nil) { self.editingID = editingID }

    init(_ skill: Skill) {
        editingID = skill.id
        name = skill.name
        oneLiner = skill.oneLiner ?? ""
        description = skill.description
        category = skill.category ?? ""
        tags = skill.tags.joined(separator: ", ")
        builtFor = skill.builtFor ?? ""
    }

    var metadata: SkillMetadata {
        SkillMetadata(name: name, description: description, oneLiner: oneLiner, category: category, tags: [tags], builtFor: builtFor)
    }

    var problems: [String] { metadata.problems }
}

/// The skills page (Home → Skills and Settings → Skills): the library with search and categories, the starter
/// catalog, the edit form, and skills written from a brain dump by a background agent.
@MainActor
@Observable
final class SkillsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case mine = "My Skills"
        case catalog = "Catalog"
        var id: String { rawValue }
    }

    enum Panel: Equatable {
        case none
        /// The edit form, for a new skill or an existing one (`draft.editingID`).
        case editor
        /// Creating a skill from notes: write them, confirm, then wait while an agent writes it.
        case brainDump(BrainDumpStep)
    }

    enum BrainDumpStep: Equatable {
        case write
        case confirm
        case creating(jobID: String)
    }

    private(set) var skills: [Skill] = []
    private(set) var issues: [SkillLoadIssue] = []
    private(set) var catalogEntries: [Skill] = []
    /// Skills being written, and ones that finished or failed recently.
    private(set) var creations: [SkillCreationRecord] = []
    var tab: Tab = .mine
    var query = ""
    /// A category name to filter by; nil shows all.
    var category: String?
    var message: String?
    var panel: Panel = .none
    var draft = SkillDraft()
    var brainDump = ""
    /// The skill whose Remove button was pressed, waiting for the inline confirmation.
    var confirmingRemoval: String?
    var confirmingDeactivateAll = false
    @ObservationIgnored let library: SkillsLibrary
    @ObservationIgnored let catalog: SkillCatalog
    @ObservationIgnored let creator: SkillCreator
    @ObservationIgnored private var manager: AgentManager?
    @ObservationIgnored private var listener: Task<Void, Never>?

    @ObservationIgnored var onActiveSkillsChange: (() -> Void)?
    @ObservationIgnored private var activeSignature = ""

    init(library: SkillsLibrary, catalog: SkillCatalog = SkillCatalog()) {
        self.library = library
        self.catalog = catalog
        creator = SkillCreator(library: library)
        reload()
    }

    var activeCount: Int { skills.filter(\.isEnabled).count }
    /// Creating from notes needs the agent subsystem (the live app); fixtures have none.
    var canCreateFromNotes: Bool { manager != nil }

    var visibleSkills: [Skill] { SkillSearch.filter(skills, query: query, category: category) }
    var visibleCatalog: [Skill] { SkillSearch.filter(catalogEntries, query: query, category: category) }
    /// Categories to filter by: every known one plus any the current list uses.
    var categoryChoices: [SkillCategory] {
        let used = SkillSearch.categories(in: tab == .mine ? skills : catalogEntries)
        return SkillCategory.all + used.filter { used in !SkillCategory.all.contains { $0.name == used.name } }
    }
    var pendingCreations: [SkillCreationRecord] { creations.filter { $0.status == .creating } }

    func reload() {
        let listing = library.list()
        skills = listing.skills
        issues = listing.issues
        let signature = library.skillsPromptSection()
        if signature != activeSignature {
            activeSignature = signature
            onActiveSkillsChange?()
        }
        catalogEntries = catalog.entries()
        creations = creator.store.all()
    }

    func isInLibrary(_ entry: Skill) -> Bool { skills.contains { $0.id == entry.id } }

    // MARK: Switching on and off

    func setEnabled(_ skill: Skill, _ on: Bool) {
        do {
            try library.setEnabled(skill.id, on)
            message = nil
        } catch {
            message = "\(error)"
        }
        reload()
    }

    func deactivateAll() {
        confirmingDeactivateAll = false
        do {
            let count = try library.disableAll()
            message = count == 0 ? "No skills were on." : "Turned off \(count) skill\(count == 1 ? "" : "s")."
        } catch {
            message = "\(error)"
        }
        reload()
    }

    // MARK: Removing

    func remove(_ skill: Skill) {
        confirmingRemoval = nil
        do {
            try library.remove(skill.id)
            message = "Removed \(skill.name). Its folder is in the Trash."
            if draft.editingID == skill.id { panel = .none }
        } catch {
            message = "\(error)"
        }
        reload()
    }

    // MARK: The edit form

    func beginNew() {
        draft = SkillDraft()
        panel = .editor
        message = nil
    }

    func beginEdit(_ skill: Skill) {
        draft = SkillDraft(skill)
        panel = .editor
        message = nil
    }

    func closePanel() {
        if case .brainDump(.creating) = panel {
            message = "Still writing your skill in the background; it will show up here switched off."
        }
        panel = .none
    }

    /// Saves the form. A new skill gets a short body to fill in and opens in the editor app.
    func saveDraft(openFile: Bool = true) {
        guard draft.problems.isEmpty else { return }
        do {
            if let id = draft.editingID {
                let skill = try library.update(id, metadata: draft.metadata)
                message = "Saved \(skill.name)."
            } else {
                let skill = try library.create(draft.metadata, body: "# \(draft.metadata.normalized.name)\n\nWrite the guidance here: when it applies, the steps, what to avoid.")
                message = "Created \(skill.name). Write its guidance in SKILL.md, then switch it on."
                if openFile { NSWorkspace.shared.open(skill.file) }
            }
            panel = .none
        } catch {
            message = "\(error)"
        }
        reload()
    }

    // MARK: Catalog

    func addFromCatalog(_ entry: Skill) {
        do {
            let skill = try catalog.add(entry.id, to: library)
            message = "Added \(skill.name) to your skills. Switch it on in My Skills."
        } catch {
            message = "\(error)"
        }
        reload()
    }

    // MARK: Creating from notes

    func beginBrainDump() {
        brainDump = ""
        panel = .brainDump(.write)
        message = nil
    }

    func confirmBrainDump() {
        guard !brainDump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        panel = .brainDump(.confirm)
    }

    /// Starts the agent job that writes the skill.
    func createFromBrainDump() {
        guard let manager else {
            message = "Background agents aren't running, so OpenClicky can't write the skill now."
            return
        }
        let notes = brainDump
        Task {
            do {
                let record = try await creator.start(brainDump: notes, manager: manager)
                panel = .brainDump(.creating(jobID: record.jobID))
                reload()
            } catch {
                message = "\(error)"
                panel = .brainDump(.write)
            }
        }
    }

    /// Follows the agent jobs, so a finished skill appears (and opens in the form) as soon as its job is done.
    func attach(manager: AgentManager) {
        self.manager = manager
        listener?.cancel()
        listener = Task { [weak self] in
            let updates = await manager.subscribe()
            await self?.collect()
            for await update in updates {
                guard case .report(let report) = update, let self else { continue }
                if self.creations.contains(where: { $0.jobID == report.jobID && $0.status == .creating }) { await self.collect() }
            }
        }
    }

    /// Brings finished skills into the library.
    func collect() async {
        guard let manager else { return }
        let changed = await creator.collect(manager: manager)
        reload()
        for record in changed {
            switch record.status {
            case .ready:
                if let id = record.skillID, let skill = skills.first(where: { $0.id == id }) {
                    message = "Your new skill \"\(skill.name)\" is ready and off. Check the details, then switch it on."
                    if case .brainDump(.creating(let jobID)) = panel, jobID == record.jobID { beginEdit(skill) }
                }
            case .failed:
                message = "Couldn't write the skill: \(record.message ?? "the job ended without one")."
                if case .brainDump(.creating(let jobID)) = panel, jobID == record.jobID {
                    brainDump = record.brainDump
                    panel = .brainDump(.write)
                }
            case .creating:
                break
            }
        }
    }

    func dismissCreation(_ record: SkillCreationRecord) {
        try? creator.store.remove(record.id)
        reload()
    }

    // MARK: Files

    func importFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SKILL.md, any Markdown file, or a folder that holds a SKILL.md."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let skill = try library.importSkill(from: url)
            message = "Added \(skill.name). Switch it on to use it."
        } catch {
            message = "\(error)"
        }
        reload()
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(library.directory)
    }

    func open(_ skill: Skill) { NSWorkspace.shared.open(skill.file) }
}

extension AgentServices {
    /// Every job gets OpenClicky's bundled skills, a skill for each connected app that has one, and the user's
    /// switched-on skills, read at each launch; the skills page follows jobs that write new skills.
    func useSkills(_ model: SkillsModel, connectors: URL) {
        let library = model.library
        let manager = coordinator.manager
        model.attach(manager: manager)
        Task {
            await manager.setSkillSources {
                // Only what is really connected: ready connectors and the toolkits Composio reports as active.
                await AgentSkillSources.connected(library: library, registry: try? ConnectorRegistry.load(from: connectors),
                                                  credentials: KeychainCredentialStore())
            }
        }
    }
}

// MARK: - The page

/// The skills library: Home → Skills and Settings → Skills.
struct SkillsLibraryView: View {
    @Bindable var model: SkillsModel
    /// Settings shows it in a narrower form.
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                Text("Skills").font(.title2.weight(.semibold))
            }
            Text("A skill is a folder with a SKILL.md that teaches OpenClicky a kind of work. Switched-on skills shape how it answers you, and background agents get them installed along with OpenClicky's own browser, deploy and connected-app skills.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Picker("", selection: $model.tab) {
                    ForEach(SkillsModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                TextField("Search skills", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Picker("Category", selection: $model.category) {
                    Text("All categories").tag(String?.none)
                    Divider()
                    ForEach(model.categoryChoices) { category in
                        Label(category.name, systemImage: category.symbol).tag(Optional(category.name))
                    }
                }
                .frame(width: 190)
                Spacer()
            }
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            switch model.panel {
            case .editor:
                SkillEditorForm(model: model)
            case .brainDump(let step):
                SkillBrainDumpPanel(model: model, step: step)
            case .none:
                if model.tab == .mine { MySkillsList(model: model) } else { SkillCatalogList(model: model) }
            }
        }
        .padding(compact ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MySkillsList: View {
    @Bindable var model: SkillsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("New Skill…") { model.beginNew() }
                Button("Create from Notes…") { model.beginBrainDump() }
                    .disabled(!model.canCreateFromNotes)
                    .help(model.canCreateFromNotes ? "A background agent writes the skill from what you jot down." : "Needs the background agents, which run in the app.")
                Button("Add Skill File…") { model.importFromPanel() }
                Button("Show Folder") { model.revealFolder() }
                Spacer()
                Text("\(model.activeCount) of \(model.skills.count) on").font(.callout).foregroundStyle(.secondary)
                if model.confirmingDeactivateAll {
                    Button("Turn All Off", role: .destructive) { model.deactivateAll() }
                    Button("Cancel") { model.confirmingDeactivateAll = false }
                } else {
                    Button("Deactivate All") { model.confirmingDeactivateAll = true }.disabled(model.activeCount == 0)
                }
            }
            ForEach(model.pendingCreations) { record in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing a skill from your notes: “\(String(record.brainDump.prefix(70)))\(record.brainDump.count > 70 ? "…" : "")”")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Text(record.jobID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            }
            let visible = model.visibleSkills
            if model.skills.isEmpty && model.issues.isEmpty {
                ContentUnavailableView("No skills yet", systemImage: "sparkles",
                                       description: Text("Pick one from the Catalog, write one with New Skill, or describe it in Create from Notes."))
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(visible) { skill in SkillRow(skill: skill, model: model) }
                        if model.query.isEmpty && model.category == nil {
                            ForEach(model.issues, id: \.folder) { issue in IssueRow(issue: issue) }
                        }
                    }
                }
            }
        }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let model: SkillsModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            let category = SkillCategory.named(skill.category)
            Image(systemName: category.symbol)
                .font(.title3)
                .foregroundStyle(skill.isEnabled ? Color(hex: category.color) : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.callout.weight(.semibold))
                    Chip(text: category.name)
                    if let app = skill.builtFor { Chip(text: "for \(app)") }
                }
                Text(skill.oneLiner ?? (skill.description.isEmpty ? "No description yet." : skill.description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !skill.tags.isEmpty {
                    Text(skill.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary)
                }
                if !skill.warnings.isEmpty {
                    Text(skill.warnings.joined(separator: " ")).font(.caption2).foregroundStyle(.orange)
                }
                if model.confirmingRemoval == skill.id {
                    HStack(spacing: 8) {
                        Text("Remove \(skill.name)? Its folder goes to the Trash.").font(.caption)
                        Button("Remove", role: .destructive) { model.remove(skill) }.controlSize(.small)
                        Button("Cancel") { model.confirmingRemoval = nil }.controlSize(.small)
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Edit") { model.beginEdit(skill) }.buttonStyle(.link)
                        Button("Open SKILL.md") { model.open(skill) }.buttonStyle(.link)
                        Button("Remove") { model.confirmingRemoval = skill.id }.buttonStyle(.link)
                        Text(skill.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { skill.isEnabled }, set: { model.setEnabled(skill, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(skill.isEnabled ? 0.1 : 0.05)))
    }
}

private struct IssueRow: View {
    let issue: SkillLoadIssue

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text(issue.folder.lastPathComponent).font(.callout.weight(.semibold))
                Text(issue.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Catalog

private struct SkillCatalogList: View {
    let model: SkillsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Starter skills written for OpenClicky. Adding one copies it into your skills, switched off, so you can read it and make it yours.")
                .font(.caption).foregroundStyle(.secondary)
            let entries = model.visibleCatalog
            if entries.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(entries) { entry in CatalogCard(entry: entry, model: model) }
                    }
                }
            }
        }
    }
}

private struct CatalogCard: View {
    let entry: Skill
    let model: SkillsModel

    var body: some View {
        let category = SkillCategory.named(entry.category)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: category.symbol).foregroundStyle(Color(hex: category.color))
                Text(entry.name).font(.callout.weight(.semibold))
                Spacer()
                if model.isInLibrary(entry) {
                    Label("Added", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Add") { model.addFromCatalog(entry) }.controlSize(.small)
                }
            }
            Text(entry.oneLiner ?? entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Chip(text: category.name)
                if let app = entry.builtFor { Chip(text: "for \(app)") }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - Edit form

struct SkillEditorForm: View {
    @Bindable var model: SkillsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.draft.editingID == nil ? "New skill" : "Edit skill").font(.headline)
            Form {
                TextField("Name", text: $model.draft.name, prompt: Text("Weekly status email"))
                TextField("One-liner", text: $model.draft.oneLiner, prompt: Text("Shown in lists, under 120 characters"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.callout)
                    TextEditor(text: $model.draft.description)
                        .font(.callout)
                        .frame(minHeight: 70, maxHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    Text("When the skill applies and what it changes. OpenClicky and its agents decide from this whether to use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Category", selection: $model.draft.category) {
                    Text("None").tag("")
                    ForEach(SkillCategory.all) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    if !model.draft.category.isEmpty, !SkillCategory.all.contains(where: { $0.name == model.draft.category }) {
                        Text(model.draft.category).tag(model.draft.category)
                    }
                }
                TextField("Tags", text: $model.draft.tags, prompt: Text("email, weekly, status"))
                TextField("Built for app", text: $model.draft.builtFor, prompt: Text("Optional, for example Keynote"))
            }
            .formStyle(.grouped)
            .frame(maxHeight: 380)
            let problems = model.draft.problems
            if !problems.isEmpty {
                Text(problems.joined(separator: " ")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if let id = model.draft.editingID, let skill = model.skills.first(where: { $0.id == id }) {
                    Button("Open SKILL.md") { model.open(skill) }
                    Text("The guidance itself is the Markdown in SKILL.md.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.closePanel() }.keyboardShortcut(.cancelAction)
                Button(model.draft.editingID == nil ? "Create" : "Save") { model.saveDraft() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }
}

// MARK: - Creating from notes

struct SkillBrainDumpPanel: View {
    @Bindable var model: SkillsModel
    let step: SkillsModel.BrainDumpStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create a skill from notes").font(.headline)
            switch step {
            case .write:
                Text("Jot down how you like this kind of work done: when it comes up, the steps, the format, examples, what to avoid. Rough notes are fine.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $model.brainDump)
                    .font(.callout)
                    .frame(minHeight: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("\(model.brainDump.count) of \(SkillCreator.maxBrainDump) characters").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.closePanel() }.keyboardShortcut(.cancelAction)
                    Button("Continue") { model.confirmBrainDump() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.brainDump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .confirm:
                Text("A background agent will turn these notes into a SKILL.md, using the agent model from Settings → Models. It usually takes a minute or two. The new skill arrives switched off, with the form open so you can check the name, description and category.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(model.brainDump).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                HStack {
                    Spacer()
                    Button("Back") { model.panel = .brainDump(.write) }
                    Button("Create Skill") { model.createFromBrainDump() }.keyboardShortcut(.defaultAction)
                }
            case .creating(let jobID):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Writing your skill…").font(.callout.weight(.semibold))
                        Text("Job \(jobID). You can close this; the skill shows up in My Skills when it's done.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close") { model.closePanel() }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }
}

extension Color {
    /// `#RRGGBB`; grey when it can't be read.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
