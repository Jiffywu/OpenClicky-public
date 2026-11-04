import AppKit
import OpenClickyKit
import SwiftUI

// Settings → Agents (where jobs work, how much they may do, effort, announcements) and Settings → Routines (run now,
// pause, delete, the last failure and each routine's runs).

@MainActor
@Observable
final class AgentSettingsModel {
    private(set) var preferences: AgentPreferences
    var message: String?

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let basePaths: AgentPaths
    @ObservationIgnored private let model: AppModel
    /// The folder jobs use in this run of the app (a changed folder applies from the next launch).
    @ObservationIgnored let activePaths: AgentPaths

    init(url: URL?, basePaths: AgentPaths, model: AppModel) {
        self.url = url
        self.basePaths = basePaths
        self.model = model
        let loaded = url.map { AgentPreferences.load(from: $0) } ?? AgentPreferences()
        preferences = loaded
        activePaths = loaded.paths(base: basePaths)
    }

    /// Where jobs go with the saved choice.
    var savedProjects: URL { preferences.paths(base: basePaths).projects }
    var folderChangePending: Bool { savedProjects.standardizedFileURL != activePaths.projects.standardizedFileURL }

    func setApprovalMode(_ mode: AgentApprovalMode) {
        preferences.approvalMode = mode
        save()
    }

    func set(_ key: WritableKeyPath<AgentPreferences, Bool>, _ value: Bool) {
        preferences[keyPath: key] = value
        save()
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Agents"
        panel.message = "Background jobs and kept agents will each get a folder inside the one you choose."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFolder(url.path)
    }

    func useFolder(_ path: String?) {
        if let path {
            switch AgentPreferences.validateFolder(path) {
            case .failure(let problem):
                message = problem.description
                return
            case .success(let url):
                preferences.customFolder = url.path
            }
        } else {
            preferences.customFolder = nil
        }
        message = folderChangePending ? "New jobs go to \(savedProjects.path) after OpenClicky restarts. Jobs already made stay where they are." : nil
        save()
    }

    func revealFolder() {
        let folder = activePaths.projects
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Model and effort (the config's agent slot)

    var agentSelection: SlotSelection? { model.config.slots[.agent] }
    var effortChoices: [String] { AgentEffortOptions.choices(config: model.config, catalog: model.catalog) }

    var reasoningEffort: String { agentSelection?.reasoningEffort ?? "" }

    func setReasoningEffort(_ effort: String) {
        guard model.config.slots[.agent] != nil else { return }
        model.config.slots[.agent]?.reasoningEffort = effort.isEmpty ? nil : effort
        model.save()
    }

    private func save() {
        guard let url else { return }
        do { try preferences.save(to: url) } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }

    /// Fixture preferences (evidence renders).
    func show(_ preferences: AgentPreferences) { self.preferences = preferences }
}

struct AgentsSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let agents = services.agentSettings
        Form {
            Section {
                LabeledContent("Jobs work in") {
                    Text(agents.activePaths.projects.path).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Choose Folder…") { agents.chooseFolder() }
                    if agents.preferences.customFolder != nil {
                        Button("Use the Default Folder") { agents.useFolder(nil) }
                    }
                    Button("Show in Finder") { agents.revealFolder() }
                    Spacer()
                }
                if let message = agents.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                } else if agents.folderChangePending {
                    Text("After a restart, new jobs go to \(agents.savedProjects.path).").font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Agent folder")
            } footer: {
                Text("Each job gets its own folder with its notes, files it made (output) and a report. Kept agents keep theirs between tasks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Agents may", selection: Binding(get: { agents.preferences.approvalMode }, set: { agents.setApprovalMode($0) })) {
                    Text("Work in their folder and ask before anything else").tag(AgentApprovalMode.ask)
                    Text("Use the whole Mac without asking").tag(AgentApprovalMode.fullAccess)
                }
                .pickerStyle(.radioGroup)
                if agents.preferences.approvalMode == .fullAccess {
                    Label("Jobs can read, change and delete anything your account can, and run any command, without asking first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Autonomy")
            } footer: {
                Text("Applies to the next job or follow-up. When a job asks, OpenClicky shows the request in the jobs panel and says so.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Runs with") {
                    Text(agentLine(agents.agentSelection)).foregroundStyle(.secondary)
                }
                Picker("Reasoning effort", selection: Binding(get: { agents.reasoningEffort }, set: { agents.setReasoningEffort($0) })) {
                    Text("Harness default").tag("")
                    ForEach(agents.effortChoices, id: \.self) { Text($0.capitalized).tag($0) }
                    if !agents.reasoningEffort.isEmpty, !agents.effortChoices.contains(agents.reasoningEffort) {
                        Text("\(agents.reasoningEffort) (not offered for this model)").tag(agents.reasoningEffort)
                    }
                }
                Button("Change the agent model…") { services.settingsPage = .models }.buttonStyle(.link)
            } header: {
                Text("Model")
            } footer: {
                Text("More effort thinks longer before acting: slower and costlier, better on hard tasks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Announcements") {
                Toggle("Tell me out loud when a job finishes",
                       isOn: Binding(get: { agents.preferences.voiceAnnouncements }, set: { agents.set(\.voiceAnnouncements, $0) }))
                Toggle("Show a notification when a job finishes",
                       isOn: Binding(get: { agents.preferences.textAnnouncements }, set: { agents.set(\.textAnnouncements, $0) }))
                Text("A job that needs your answer always shows its panel and a notification.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Suggestions") {
                Toggle("Suggest background jobs when one would help",
                       isOn: Binding(get: { agents.preferences.suggestTasks }, set: { agents.set(\.suggestTasks, $0) }))
            }
            AgentsUXSettingsSections()
        }
        .formStyle(.grouped)
    }

    private func agentLine(_ selection: SlotSelection?) -> String {
        guard let selection else { return "No agent model set" }
        let harness = (selection.harness ?? .codex) == .claudeCode ? "Claude Code" : "Codex"
        return "\(harness) · \(selection.model) · \(selection.provider)"
    }
}

// MARK: - Routines

@MainActor
@Observable
final class RoutinesSettingsModel {
    private(set) var summaries: [RoutineSummary] = []
    var selectedID: String?
    var message: String?
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let scheduler: RoutineScheduler?
    @ObservationIgnored private let manager: AgentManager?
    @ObservationIgnored private var follower: Task<Void, Never>?
    @ObservationIgnored private var pinned = false

    init(scheduler: RoutineScheduler?, manager: AgentManager?) {
        self.scheduler = scheduler
        self.manager = manager
    }

    func appear() {
        guard !pinned, follower == nil, let scheduler else { return }
        follower = Task { [weak self] in
            for await _ in await scheduler.changes() {
                await self?.reload()
            }
        }
    }

    func disappear() {
        follower?.cancel()
        follower = nil
    }

    func reload() async {
        guard !pinned, let scheduler else { return }
        let routines = await scheduler.list()
        let jobs = await manager?.jobs() ?? []
        summaries = RoutineSummary.make(routines: routines, jobs: jobs)
    }

    func runNow(_ id: String) { act(id, "Started") { scheduler in _ = try await scheduler.runNow(id) } }
    func setPaused(_ id: String, _ paused: Bool) { act(id, paused ? "Paused" : "Resumed") { try await $0.setPaused(id, paused) } }
    func delete(_ id: String) { act(id, "Deleted") { try await $0.delete(id) } }

    private func act(_ id: String, _ done: String, _ work: @escaping @Sendable (RoutineScheduler) async throws -> Void) {
        guard let scheduler, !busy.contains(id) else { return }
        busy.insert(id)
        Task { [weak self] in
            do {
                try await work(scheduler)
                self?.message = "\(done)."
            } catch {
                self?.message = "\(error)"
            }
            self?.busy.remove(id)
            await self?.reload()
        }
    }

    /// Fixture routines (evidence renders).
    func show(_ summaries: [RoutineSummary], selected: String?) {
        pinned = true
        self.summaries = summaries
        selectedID = selected
    }
}

struct RoutinesSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let routines = services.routines
        Form {
            Section {
                Text("Routines re-run a task on a schedule while your Mac is awake and OpenClicky is open. Ask OpenClicky to set one up (\"every weekday at 9, summarize my new email\"), or use `occtl routines add`.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if routines.summaries.isEmpty {
                Section { Text("No routines yet.").foregroundStyle(.secondary) }
            }
            ForEach(routines.summaries) { summary in
                Section {
                    RoutineRow(summary: summary, routines: routines)
                }
            }
            if let message = routines.message {
                Section { Label(message, systemImage: "info.circle").font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            routines.appear()
            Task { await routines.reload() }
        }
        .onDisappear { routines.disappear() }
    }
}

private struct RoutineRow: View {
    let summary: RoutineSummary
    let routines: RoutinesSettingsModel
    @ViewState private var confirmingDelete = false

    var body: some View {
        let routine = summary.routine
        let expanded = routines.selectedID == routine.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.headline)
                    Text("\(routine.schedule.phrase.prefix(1).uppercased() + routine.schedule.phrase.dropFirst()) · \(summary.statusLine())")
                        .font(.caption).foregroundStyle(routine.isPaused ? .orange : .secondary)
                }
                Spacer()
                if routines.busy.contains(routine.id) { ProgressView().controlSize(.small) }
                Button("Run Now") { routines.runNow(routine.id) }
                Button(routine.isPaused ? "Resume" : "Pause") { routines.setPaused(routine.id, !routine.isPaused) }
                Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            Text(routine.task).font(.callout).lineLimit(expanded ? nil : 2)
            Text(summary.lastRunLine()).font(.caption).foregroundStyle(.secondary)
            if let failure = summary.lastFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { routines.selectedID = $0 ? routine.id : nil })) {
                if summary.runs.isEmpty {
                    Text("No runs yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(summary.runs) { run in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: icon(run)).foregroundStyle(color(run))
                        Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption.monospacedDigit())
                        Text(run.statusText).font(.caption).foregroundStyle(color(run))
                        if let spoken = run.spoken { Text(spoken).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(run.jobID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
            } label: {
                Text("Runs (\(summary.runs.count))").font(.caption)
            }
        }
        .confirmationDialog("Delete \"\(routine.title)\"?", isPresented: $confirmingDelete) {
            Button("Delete Routine", role: .destructive) { routines.delete(routine.id) }
        } message: {
            Text("It stops running. Its job folder and past reports are kept.")
        }
    }

    private func icon(_ run: RoutineRunEntry) -> String {
        switch run.outcome {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "stop.circle.fill"
        case nil: "clock"
        }
    }

    private func color(_ run: RoutineRunEntry) -> Color {
        switch run.outcome {
        case .completed: .green
        case .failed: .red
        case .interrupted: .orange
        case nil: .secondary
        }
    }
}
