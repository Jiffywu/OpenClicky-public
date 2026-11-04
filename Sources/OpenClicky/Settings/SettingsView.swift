import OpenClickyKit
import SwiftUI

/// The Settings window: a sidebar of pages covering every slot, the voice, talk keys, keys, permissions, memory,
/// connected apps, lookup services and skills. `HomeServices.settingsPage` picks the page, so Home and the menu can
/// open Settings on the right one.
struct SettingsView: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(HomeServices.SettingsPage.allCases) { page in
                    SettingsSidebarRow(page: page, selected: services.settingsPage == page) { services.settingsPage = page }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .frame(width: 190)
            .background(Color.secondary.opacity(0.06))
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 860, height: 620)
        .environment(\.openURL, services.router.openURLAction)
    }

    @ViewBuilder private var page: some View {
        switch services.settingsPage {
        case .general: GeneralSettingsPage()
        case .models: SlotsSettings()
        case .voice: VoiceSettingsPage()
        case .microphone: MicrophoneSettingsPage()
        case .dictation: DictationSettingsPage()
        case .talkKeys: TalkKeysSettingsPage()
        case .providers: ProvidersSettings()
        case .permissions: PermissionsSettings()
        case .agents: AgentsSettingsPage()
        case .routines: RoutinesSettingsPage()
        case .memory: MemorySettingsView(store: services.memoryStore)
        case .connectedApps: ConnectedAppsSettings(model: services.connectedApps)
        case .browser: BrowserSettingsPage()
        case .services: ServicesSettingsView(model: services.services)
        case .skills: SkillsSettingsPage()
        case .usage: UsageSettingsPage()
        case .developer: DeveloperSettingsPage()
        }
    }
}

private struct SettingsSidebarRow: View {
    let page: HomeServices.SettingsPage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(page.title).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Slots

private struct SlotsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(SlotID.allCases, id: \.self) { slot in
                Section(SlotCopy.title(slot)) {
                    SlotEditor(slot: slot)
                    ForEach(Array(model.issues(for: slot).enumerated()), id: \.offset) { _, issue in
                        IssueRow(issue: issue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private enum SlotCopy {
    static func title(_ slot: SlotID) -> String {
        switch slot {
        case .stt: "Listening (speech to text)"
        case .voice: "Voice (speaks answers)"
        case .brain: "Brain (sees your screen and answers)"
        case .agent: "Background agent"
        case .brainFast: "Quick text work (cleanup, summaries; optional)"
        case .realtimeVoice: "Always-on voice (realtime; optional)"
        }
    }
}

private struct SlotEditor: View {
    let slot: SlotID
    @Environment(AppModel.self) private var model

    private var selection: SlotSelection? { model.config.slots[slot] }

    /// Providers whose dialect can serve this slot's kind of model and that OpenClicky has an adapter for here.
    private var providers: [ProviderConfig] {
        model.config.providers.filter { !$0.dialect.servableKinds.isDisjoint(with: slot.requirement.kinds) && $0.dialect.canFill(slot) }
    }

    private var models: [ModelDescriptor] {
        guard let provider = selection.flatMap({ model.config.provider($0.provider) }) else { return [] }
        return model.mergedCatalog.candidates(for: slot, dialect: provider.dialect)
    }

    var body: some View {
        Picker("Provider", selection: binding(\.provider, default: providers.first?.id ?? "")) {
            ForEach(providers) { Text($0.id).tag($0.id) }
        }
        Picker("Model", selection: binding(\.model, default: "")) {
            if let current = selection?.model, !models.contains(where: { $0.id == current }) {
                Text("\(current) (not available here)").tag(current)
            }
            ForEach(models) { Text($0.displayName ?? $0.id).tag($0.id) }
        }
        if slot == .voice, let chosen = models.first(where: { $0.id == selection?.model }) {
            if let voices = chosen.voices {
                Picker("Voice", selection: binding(\.voice, default: voices.first)) {
                    ForEach(voices, id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                // No fixed list (ElevenLabs voices belong to each account; macOS voices depend on what is installed).
                VoiceIDField(slot: slot, dialect: selection.flatMap { model.config.provider($0.provider) }?.dialect)
            }
        }
        if slot == .agent {
            Picker("Harness", selection: binding(\.harness, default: .codex)) {
                ForEach(HarnessKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SlotSelection, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.config.slots[slot]?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                var current = model.config.slots[slot] ?? SlotSelection(provider: providers.first?.id ?? "", model: "")
                let previousDialect = model.config.provider(current.provider)?.dialect
                current[keyPath: keyPath] = newValue
                // A voice belongs to one kind of provider (an ElevenLabs voice ID means nothing to macOS voices).
                if keyPath == \SlotSelection.provider, model.config.provider(current.provider)?.dialect != previousDialect {
                    current.voice = nil
                }
                if keyPath == \SlotSelection.provider,
                   let provider = model.config.provider(current.provider),
                   !model.mergedCatalog.candidates(for: slot, dialect: provider.dialect).contains(where: { $0.id == current.model }) {
                    current.model = model.mergedCatalog.candidates(for: slot, dialect: provider.dialect).first?.id ?? ""
                }
                model.config.slots[slot] = current
                model.save()
            })
    }
}

/// A free-text voice for models without a fixed voice list. Saved on Return or with the button, not per keystroke.
private struct VoiceIDField: View {
    let slot: SlotID
    let dialect: ProviderDialect?
    @Environment(AppModel.self) private var model
    @ViewState private var draft = ""

    private var stored: String { model.config.slots[slot]?.voice ?? "" }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack {
            TextField(dialect == .elevenLabsSpeech ? "Voice ID" : "Voice", text: $draft, prompt: Text(prompt))
                .onSubmit(commit)
            Button("Use", action: commit).disabled(trimmedDraft == stored)
        }
        // Follows the stored voice when it changes underneath the field (another provider chosen, config reloaded).
        .onChange(of: stored, initial: true) { draft = stored }
    }

    private var prompt: String {
        dialect == .elevenLabsSpeech
            ? "Voice ID from your ElevenLabs voice library"
            : "Voice name, identifier or language; blank uses the default"
    }

    private func commit() {
        guard model.config.slots[slot] != nil, trimmedDraft != stored else { return }
        model.config.slots[slot]?.voice = trimmedDraft.isEmpty ? nil : trimmedDraft
        draft = trimmedDraft
        model.save()
    }
}

private struct IssueRow: View {
    let issue: ConfigIssue

    var body: some View {
        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(issue.severity == .error ? .red : .orange)
            .font(.callout)
    }
}

// MARK: - Providers and keys

private struct ProvidersSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Configured providers") {
                ForEach(model.config.providers) { provider in
                    ProviderRow(provider: provider)
                }
            }
            SavedKeysSection()
            Section("Add a provider") {
                ForEach(ProviderPreset.all.filter { preset in !model.config.providers.contains { $0.id == preset.config.id } }) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Add") {
                            model.config.providers.append(preset.config)
                            model.save()
                        }
                    }
                }
            }
            if !model.globalIssues.isEmpty {
                Section("Problems") {
                    ForEach(Array(model.globalIssues.enumerated()), id: \.offset) { _, issue in IssueRow(issue: issue) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Every key OpenClicky has saved in the Keychain (providers, lookup services, connected apps), with a Delete for each.
private struct SavedKeysSection: View {
    @Environment(AppModel.self) private var model
    @ViewState private var keys: [SavedKey] = []
    @ViewState private var problem: String?
    @ViewState private var confirming: SavedKey?

    var body: some View {
        Section {
            if keys.isEmpty {
                Text("No keys saved yet.").foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.name).font(.body.monospaced())
                        Text(key.usedBy.isEmpty ? "Not used by any provider" : "Used by \(key.usedBy.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if key.fromEnvironment {
                        Text("From the environment").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Delete…", role: .destructive) { confirming = key }
                    }
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Saved keys")
        } footer: {
            Text("Keys live in your login Keychain under com.openclicky.credentials. Deleting one signs that provider out; nothing else changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Delete the key \"\(confirming?.name ?? "")\"?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Delete Key", role: .destructive) {
                if let key = confirming { delete(key) }
                confirming = nil
            }
        } message: {
            Text("Anything that uses it stops working until you paste a key again.")
        }
    }

    private func refresh() {
        guard let listing = model.credentials as? any CredentialListing else { return }
        do {
            let stored = try listing.storedNames()
            let environment = model.credentials is KeychainCredentialStore ? KeychainCredentialStore.environmentNames() : []
            keys = SavedKey.inventory(stored: stored, config: model.config, environmentNames: environment)
            problem = nil
        } catch {
            problem = "Couldn't list the saved keys: \(error)"
        }
    }

    private func delete(_ key: SavedKey) {
        do {
            try model.credentials.removeSecret(named: key.name)
            problem = nil
        } catch {
            problem = "Couldn't delete \(key.name): \(error)"
        }
        refresh()
        model.revalidate()
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfig
    @Environment(AppModel.self) private var model
    @ViewState private var keyDraft = ""
    @ViewState private var hasKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.id).font(.headline)
                Text(provider.dialect.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !isInUse {
                    Button("Remove", role: .destructive) {
                        model.config.providers.removeAll { $0.id == provider.id }
                        model.save()
                    }
                }
            }
            if let url = provider.baseURL { Text(url.absoluteString).font(.caption).foregroundStyle(.secondary) }
            if let name = provider.credential {
                HStack {
                    SecureField(hasKey ? "Key stored in Keychain (\(name))" : "Paste API key for \(name)", text: $keyDraft)
                    Button(hasKey ? "Replace" : "Save") {
                        try? model.credentials.setSecret(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), named: name)
                        keyDraft = ""
                        refresh()
                        model.revalidate()
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("Delete", role: .destructive) {
                            try? model.credentials.removeSecret(named: name)
                            refresh()
                            model.revalidate()
                        }
                        .help("Removes the saved key for \(name) from the Keychain")
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var isInUse: Bool { model.config.slots.values.contains { $0.provider == provider.id } }

    private func refresh() {
        hasKey = provider.credential.flatMap { try? model.credentials.secret(named: $0) } != nil
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(PermissionsCenter.Permission.allCases) { permission in
                    PermissionRow(permission: permission, state: model.permissions.states[permission], center: model.permissions)
                }
                Button("Check again") {
                    model.permissions.refresh()
                    model.permissions.refreshAgentReach()
                }
            }
            if let reach = model.permissions.agentReach {
                AgentReachSections(reach: reach)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.permissions.pageAppeared() }
        .onDisappear { model.permissions.pageDisappeared() }
    }
}

/// One permission: what it is for, and its state with the action that fits (ask, open System Settings, or quit and
/// reopen after a grant this copy can't use yet).
struct PermissionRow: View {
    let permission: PermissionsCenter.Permission
    let state: PermissionsCenter.State?
    let center: PermissionsCenter

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(permission.title).font(.headline)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .restartRequired:
                Button("Quit & Reopen") { center.quitAndReopen() }.buttonStyle(.borderedProminent)
            case .denied:
                Button("Open System Settings") { NSWorkspace.shared.open(permission.settingsURL) }
            default:
                Button("Allow…") { Task { await center.request(permission) } }
            }
        }
    }

    private var note: String {
        switch state {
        case .denied: "Not allowed. Turn on OpenClicky in System Settings → Privacy & Security → \(permission.title)."
        case .restartRequired: "Allowed in System Settings. OpenClicky has to quit and open again to use it."
        default: permission.why
        }
    }
}

/// "What agents can reach": Automation for each browser OpenClicky scripts, and the protected folders read before.
private struct AgentReachSections: View {
    let reach: AgentReach

    /// "cloud storage" → "Cloud storage"; "iCloud Drive" stays as it is.
    static func title(_ folder: GuardedFolder) -> String {
        let name = folder.displayName
        return name.hasPrefix("iCloud") ? name : name.prefix(1).uppercased() + name.dropFirst()
    }

    var body: some View {
        Section {
            if reach.browsers.isEmpty {
                Text("No browser OpenClicky can script is installed.").foregroundStyle(.secondary)
            }
            ForEach(reach.browsers) { row in
                LabeledContent(row.browser.displayName) {
                    Text(row.permission.label).foregroundStyle(row.permission == .granted ? Color.green : Color.secondary)
                }
            }
            Button("Open Automation Settings") { NSWorkspace.shared.open(AutomationPermission.settingsURL) }
        } header: {
            Text("What agents can reach: browsers")
        } footer: {
            Text("OpenClicky reads the open tab through each browser's scripting. macOS asks once per browser; change it under Privacy & Security → Automation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(reach.folders) { row in
                LabeledContent(Self.title(row.folder)) {
                    Text(row.readBefore ? "Read before" : "Not read yet")
                        .foregroundStyle(row.readBefore ? Color.green : Color.secondary)
                }
            }
            Button("Open Files & Folders Settings") { NSWorkspace.shared.open(GuardedFolder.settingsURL) }
        } header: {
            Text("What agents can reach: folders")
        } footer: {
            Text("macOS asks the first time OpenClicky reads from each of these. Folders not read yet will ask then.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Voice: how answers are delivered around the voice (the voice loop's own settings).
struct VoiceLoopSettingsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let loop = model.voiceLoop {
            Section {
                Toggle("Read answers to typed questions aloud", isOn: binding(loop, \.speaksTypedAnswers))
                Toggle("Show the line being spoken as a caption", isOn: binding(loop, \.showsCaptions))
                Toggle("Play a sound when listening starts and stops", isOn: binding(loop, \.playsCues))
                Toggle("Show the last answer's timings in the notch", isOn: binding(loop, \.showsTimings))
            } header: {
                Text("Answers")
            } footer: {
                Text("If the voice model stops answering, OpenClicky reopens it once, then speaks with the Mac's own voice for ten minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Reveal captions word by word as they are spoken", isOn: binding(loop, \.captionsWordByWord))
                    .disabled(!loop.settings.showsCaptions)
                Picker("Caption size", selection: binding(loop, \.captionSize)) {
                    Text("Small").tag(14.0)
                    Text("Medium").tag(17.0)
                    Text("Large").tag(22.0)
                    Text("Extra large").tag(28.0)
                }
                .disabled(!loop.settings.showsCaptions)
                Toggle("Play drawing sounds", isOn: binding(loop, \.playsDrawingSounds))
                Toggle("Show the drawing's beats under the caption", isOn: binding(loop, \.showsBeatChips))
            } header: {
                Text("Captions and drawing")
            } footer: {
                Text("Beats show each statement of the line being heard as waiting, drawing or done (late ones are marked), for tuning drawings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Let OpenClicky click and type when you approve a take-over", isOn: binding(loop, \.takeoverPostsInput))
            } header: {
                Text("Take-over")
            } footer: {
                Text("Off: a take-over you approve is a rehearsal that shows each step it would take and touches nothing. On: it really moves the pointer, clicks and types, and still asks first every time. Escape or any input of yours stops it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem = loop.engineProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let timings = loop.lastTimings {
                Section("Last answer") {
                    Text(timings.report())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func binding<Value>(_ loop: VoiceLoopController, _ key: WritableKeyPath<VoiceLoopSettings, Value>) -> Binding<Value> {
        Binding(get: { loop.settings[keyPath: key] }, set: { value in
            var settings = loop.settings
            settings[keyPath: key] = value
            loop.update(settings)
        })
    }
}

/// Settings → Talk keys: whether OpenClicky can see the keys in other apps, and the keys that aren't configurable.
struct TalkKeysStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Watching the keys") {
            switch model.voiceLoop?.keyMode ?? .off {
            case .activeTap:
                Label("Watching your talk keys in every app.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .listenOnlyTap:
                Label("Watching your talk keys, but Escape also reaches the app in front. Allow Accessibility to let Escape stop OpenClicky alone.",
                      systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .eventMonitors, .off:
                Label("OpenClicky can't see keys pressed in other apps yet. Allow Accessibility (Settings → Permissions); it starts watching within a few seconds.",
                      systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text("Escape stops OpenClicky while it listens, thinks or speaks, and a second Escape clears its drawing; otherwise Escape goes to your app as usual. A triple tap of the text key is kept for always-on voice.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
