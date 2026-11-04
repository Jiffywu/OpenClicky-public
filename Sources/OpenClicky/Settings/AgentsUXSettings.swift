import AppKit
import OpenClickyKit
import SwiftUI

// Settings → Agents, continued: grouping old one-off jobs into kept agents (the organizer), and the developer preview
// of before-and-after file diffs with its viewer window.

struct AgentsUXSettingsSections: View {
    @Environment(HomeServices.self) private var services
    @Environment(AppModel.self) private var model
    @ViewState private var organizing = false
    @ViewState private var organizerMessage: String?
    @ViewState private var stateVersion = 0

    var body: some View {
        let agents = services.agentSettings
        let paths = agents.activePaths
        let state = AgentOrganizerState.load(paths)
        Section {
            LabeledContent("Last grouped") {
                Text(stateLine(state)).foregroundStyle(.secondary).id(stateVersion)
            }
            HStack {
                Button(state.completedAt == nil ? "Group Old Jobs Now" : "Group Newer Jobs") { organize(paths: paths) }
                    .disabled(organizing || services.agents == nil)
                if organizing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let organizerMessage {
                Text(organizerMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Kept agents")
        } footer: {
            Text("Looks at finished one-off jobs with the fast model and files the ones that belong together under a kept agent you can hand that kind of work to. Job folders stay where they are; the kept agent's folder links to them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Keep before-and-after diffs of files jobs change",
                   isOn: Binding(get: { agents.preferences.developerFileDiffs }, set: { agents.set(\.developerFileDiffs, $0) }))
            if agents.preferences.developerFileDiffs {
                Button("Show File Changes…") { AgentFileDiffsWindow.shared.show(store: AgentJobStore(paths: paths)) }
            }
        } header: {
            Text("Developer preview")
        } footer: {
            Text("Text files up to 256 KB are copied the first time a job starts changing them and compared when its turn ends. Diffs are kept in each job's diffs folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stateLine(_ state: AgentOrganizerState) -> String {
        guard let done = state.completedAt else { return "Not yet" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: done)): \(state.groups) group\(state.groups == 1 ? "" : "s"), \(state.filedJobs) job\(state.filedJobs == 1 ? "" : "s") filed"
    }

    private func organize(paths: AgentPaths) {
        guard let manager = services.agents?.coordinator.manager else { return }
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        organizing = true
        organizerMessage = nil
        Task { @MainActor in
            defer {
                organizing = false
                stateVersion += 1
            }
            do {
                let organizer = try AgentOrganizer(store: AgentJobStore(paths: paths), factory: factory, manager: manager)
                let (proposal, result) = try await organizer.runOnce(force: true)
                organizerMessage = AgentOrganizerSummary.text(proposal: proposal, result: result)
            } catch {
                organizerMessage = "\(error)"
            }
        }
    }
}

/// One line about what the organizer did, for Settings and occtl.
enum AgentOrganizerSummary {
    static func text(proposal: AgentOrganizerProposal, result: AgentOrganizerResult) -> String {
        guard !proposal.groups.isEmpty else { return "Nothing belonged together; every job stays on its own." }
        let names = proposal.groups.map(\.name).joined(separator: ", ")
        return "Filed \(result.filed.count) job\(result.filed.count == 1 ? "" : "s") under \(names)."
    }
}

// MARK: - Diff viewer

@MainActor
@Observable
final class AgentFileDiffsModel {
    struct Entry: Identifiable, Hashable {
        var job: AgentJobRecord
        var item: AgentFileDiffItem
        var id: String { "\(job.id)/\(item.id)" }
    }

    private(set) var entries: [Entry] = []
    var selectedID: String?
    @ObservationIgnored private var store: AgentJobStore?

    init(store: AgentJobStore? = nil) {
        self.store = store
        reload()
    }

    func use(_ store: AgentJobStore) {
        self.store = store
        reload()
    }

    /// Jobs with diffs, newest first; each job's items newest run first, in the order the run touched them.
    func reload() {
        let jobs = store?.all() ?? []
        show(jobs)
    }

    /// Fixture jobs (evidence renders).
    func show(_ jobs: [AgentJobRecord]) {
        entries = jobs.filter { !($0.fileDiffs ?? []).isEmpty }.flatMap { job in
            (job.fileDiffs ?? []).enumerated().sorted { ($0.element.run, -$0.offset) > ($1.element.run, -$1.offset) }
                .map { Entry(job: job, item: $0.element) }
        }
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id }
    }

    var selected: Entry? { entries.first { $0.id == selectedID } }

    var groups: [(job: AgentJobRecord, entries: [Entry])] {
        var order: [String] = []
        var byJob: [String: [Entry]] = [:]
        for entry in entries {
            if byJob[entry.job.id] == nil { order.append(entry.job.id) }
            byJob[entry.job.id, default: []].append(entry)
        }
        return order.compactMap { id in byJob[id].flatMap { list in list.first.map { ($0.job, list) } } }
    }

    func text(of entry: Entry) -> String? { AgentFileDiffs.text(of: entry.item, in: entry.job) }
}

struct AgentFileDiffsView: View {
    @Bindable var model: AgentFileDiffsModel

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selectedID) {
                ForEach(model.groups, id: \.job.id) { group in
                    Section(group.job.agentName ?? group.job.title) {
                        ForEach(group.entries) { entry in
                            DiffRow(item: entry.item).tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 260)
            Divider()
            Group {
                if let entry = model.selected {
                    DiffDetail(entry: entry, text: model.text(of: entry))
                } else {
                    ContentUnavailableView("No file changes yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Turn on diffs in Settings → Agents; files jobs change after that show up here."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct DiffRow: View {
        let item: AgentFileDiffItem

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                    Text("Run \(item.run) · \(item.kind.rawValue)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if item.skipped == nil {
                    Text("+\(item.added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("−\(item.removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                } else {
                    Text(item.summary).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }

        private var symbol: String {
            switch item.kind {
            case .created: "plus.square"
            case .changed: "pencil"
            case .deleted: "minus.square"
            }
        }

        private var color: Color {
            switch item.kind {
            case .created: .green
            case .changed: .accentColor
            case .deleted: .red
            }
        }
    }

    private struct DiffDetail: View {
        let entry: AgentFileDiffsModel.Entry
        let text: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.fileName).font(.headline)
                    Text(entry.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Text("\(entry.job.title) · run \(entry.item.run) · \(entry.item.kind.rawValue) · \(entry.item.summary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                Divider()
                if let text {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                DiffLine(line: String(line))
                            }
                        }
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
                    }
                } else {
                    Text(reason).foregroundStyle(.secondary).padding(12)
                    Spacer()
                }
            }
        }

        private var reason: String {
            switch entry.item.skipped {
            case .binary: "Not a text file, so no copy was kept."
            case .tooLarge: "Over 256 KB, so no copy was kept."
            case .beforeMissed: "The change landed before OpenClicky could read the file, so there is nothing to compare with."
            case nil: "The diff file is missing."
            }
        }
    }

    private struct DiffLine: View {
        let line: String

        var body: some View {
            Text(line.isEmpty ? " " : line)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .background(background)
        }

        private var kind: Character? {
            if line.hasPrefix("+++") || line.hasPrefix("---") { return "h" }
            return line.first
        }

        private var foreground: Color {
            switch kind {
            case "h": .secondary
            case "@": .blue
            default: .primary
            }
        }

        private var background: Color {
            switch kind {
            case "+": Color.green.opacity(0.16)
            case "-": Color.red.opacity(0.16)
            case "@": Color.blue.opacity(0.08)
            default: .clear
            }
        }
    }
}

/// The diff viewer window (Settings → Agents → Show File Changes…).
@MainActor
final class AgentFileDiffsWindow {
    static let shared = AgentFileDiffsWindow()
    private var window: NSWindow?
    private let model = AgentFileDiffsModel()

    func show(store: AgentJobStore) {
        model.use(store)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "File Changes"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AgentFileDiffsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
