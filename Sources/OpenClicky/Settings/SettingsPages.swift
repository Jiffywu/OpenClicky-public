import AppKit
import OpenClickyKit
import SwiftUI

// Settings pages added for Home: General, Voice and Talk keys. The rest live in SettingsView.swift and the feature
// folders (Memory, Integrations, Lookups).

struct VoiceSettingsPage: View {
    @Environment(HomeServices.self) private var services
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = services.voice
        Form {
            Section("Voice") {
                LabeledContent("Speaks with") {
                    Text("\(voice.provider?.id ?? "no provider") · \(voice.selection?.model ?? "no model")")
                        .foregroundStyle(.secondary)
                }
                Button("Change the voice model…") { services.settingsPage = .models }
                    .buttonStyle(.link)
            }
            VoiceLoopSettingsSections()
            MicrophoneSettingsSections()
            Section {
                Picker("Speed", selection: Binding(get: { voice.settings.speed }, set: { voice.setSpeed($0) })) {
                    ForEach(VoiceSettings.speeds, id: \.self) { Text(VoiceSettings.label(forSpeed: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Applies to everything OpenClicky says, previews included. The pitch stays the same.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if voice.loadingVoices {
                    HStack { ProgressView().controlSize(.small); Text("Loading voices…").foregroundStyle(.secondary) }
                }
                ForEach(voice.voices) { option in
                    VoiceRow(option: option, voice: voice)
                }
                if let note = voice.voiceListNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Voices")
                    Spacer()
                    Button("Refresh") { voice.loadVoices(force: true) }.buttonStyle(.borderless).font(.caption)
                }
            } footer: {
                Text("Previews are spoken by the voice model you picked, so each one costs a short request the first time. They're kept in Application Support/OpenClicky/VoicePreviews.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { voice.loadVoices() }
        .onChange(of: model.config.slots[.voice]) { _, _ in voice.loadVoices() }
    }
}

private struct VoiceRow: View {
    let option: VoiceOption
    let voice: VoiceSettingsModel

    var body: some View {
        let chosen = option.id == voice.selectedVoice
        HStack(spacing: 10) {
            Button {
                voice.choose(option)
            } label: {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(option.name).fontWeight(chosen ? .semibold : .regular)
                if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            switch voice.previews[option.id] {
            case .rendering:
                ProgressView().controlSize(.small)
            case .playing:
                Button { voice.stopPreview() } label: { Image(systemName: "stop.circle.fill") }.buttonStyle(.borderless)
            case .ready(let seconds):
                Text(String(format: "%.1f s", seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                previewButton
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
                previewButton
            case nil:
                previewButton
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { voice.choose(option) }
    }

    private var previewButton: some View {
        Button { voice.preview(option) } label: { Label("Preview", systemImage: "play.circle") }
            .buttonStyle(.borderless)
    }
}

struct TalkKeysSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let keys = services.talkKeys
        Form {
            Section {
                Text("Talk keys are modifier keys you hold or double-tap in any app. Each one can be either: pick Hold keys or Double-tap, then press the keys and let go.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(TalkKeyAction.allCases) { action in
                Section(action.title) {
                    TalkKeyRow(action: action, keys: keys)
                }
            }
            if let message = keys.message {
                Section { Label(message, systemImage: "info.circle").font(.callout) }
            }
            TalkKeysStatusSection()
            Section {
                Button("Restore Defaults") { keys.resetToDefaults() }
                Text("Defaults: hold Control and Option to talk, double-tap Control to type, hold Fn and Control to dictate, and no hands-free key. Watching keys in other apps needs Accessibility (Settings → Permissions).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { keys.cancelRecording() }
    }
}

private struct TalkKeyRow: View {
    let action: TalkKeyAction
    let keys: TalkKeysModel

    var body: some View {
        let trigger = keys.settings[action]
        let recording = keys.isRecording(action)
        let kind = trigger?.kind ?? action.defaultTriggerKind
        HStack(spacing: 12) {
            Text(recording ? (keys.recorder?.prompt ?? "") : (trigger?.symbol ?? "Off"))
                .font(.system(size: recording ? 13 : 18, weight: .medium, design: .rounded))
                .frame(minWidth: 120, minHeight: 30)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(recording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger?.phrase ?? "No key: double-tap the dictation keys instead, if that's on in Dictation")
                Text(action.explain(recording ? (keys.recorder?.kind ?? kind) : kind))
                    .font(.caption).foregroundStyle(.secondary)
                if let trigger {
                    ForEach(TalkKeyRules.problems(trigger, for: action, in: keys.settings), id: \.self) { problem in
                        Text(problem.message).font(.caption).foregroundStyle(problem.severity == .blocking ? .red : .orange)
                    }
                }
            }
            Spacer()
            // Either kind works for every slot; picking the other kind records a key of that kind.
            Picker("Kind", selection: Binding(get: { recording ? (keys.recorder?.kind ?? kind) : kind },
                                              set: { keys.startRecording(action, kind: $0) })) {
                ForEach(TalkKeyTrigger.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            if recording {
                Button("Cancel") { keys.cancelRecording() }
            } else {
                Button("Record") { keys.startRecording(action, kind: kind) }
                if action.isOptional, trigger != nil {
                    Button("Clear") { keys.clear(action) }
                }
            }
        }
    }
}

struct GeneralSettingsPage: View {
    @Environment(HomeServices.self) private var services
    @ViewState private var confirmingClear = false
    @ViewState private var confirmingReset = false
    @ViewState private var resetReport: String?

    var body: some View {
        let behavior = services.behavior
        Form {
            if let warning = behavior.installWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    Button("Don't Show Again") { behavior.dismissInstallWarning() }.buttonStyle(.link)
                }
            }
            Section {
                Toggle("Open OpenClicky when you log in", isOn: Binding(get: { behavior.launchesAtLogin }, set: { behavior.setLaunchAtLogin($0) }))
                    .disabled(!behavior.location.allowsLoginItem || behavior.loginStatus == .notFound)
                LabeledContent("Login item") { Text(behavior.loginStatus.label).foregroundStyle(.secondary) }
                if behavior.loginStatus == .requiresApproval {
                    Button("Open Login Items Settings…") { behavior.openLoginItemsSettings() }.buttonStyle(.link)
                }
                Toggle("Show in Dock", isOn: Binding(get: { behavior.preferences.showInDock }, set: { behavior.setShowInDock($0) }))
                Toggle("Show in screen recordings", isOn: Binding(get: { behavior.preferences.showInScreenRecordings },
                                                                  set: { behavior.setShowInScreenRecordings($0) }))
                if let message = behavior.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Behavior")
            } footer: {
                Text("Off, screen recordings and screen sharing in other apps leave out OpenClicky's pointer, captions, drawings and panels where macOS allows it. OpenClicky's own screenshots always leave them out.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Home") {
                Button("Open Home") { services.openHome() }
                LabeledContent("Conversations") { Text("\(services.chat.sessions.count)").foregroundStyle(.secondary) }
                Button("Clear Conversation History…", role: .destructive) { confirmingClear = true }
                Text("History is kept on this Mac in \(services.history.directory.path).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Welcome tour") {
                Button("Replay the Welcome Tour") { services.openOnboarding(restart: true) }
                Text("Walks through permissions, models and keys, the voice and the talk keys again. Nothing you set up is lost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Skills") {
                LabeledContent("Switched on") { Text("\(services.skills.activeCount) of \(services.skills.skills.count)").foregroundStyle(.secondary) }
                Button("Manage Skills…") { services.settingsPage = .skills }.buttonStyle(.link)
            }
            Section {
                Button("Reset Local Data…", role: .destructive) {
                    // Only folders the user chose are kept; the default job folders live in the support folder and go.
                    let standard = AgentPaths.default.projects.standardizedFileURL
                    let chosen = [services.agentSettings.savedProjects, services.agentSettings.activePaths.projects]
                    behavior.prepareReset(keep: chosen.filter { $0.standardizedFileURL != standard })
                    confirmingReset = true
                }
                if let resetReport { Text(resetReport).font(.caption).foregroundStyle(.red) }
                Text("Deletes everything OpenClicky keeps on this Mac (settings, keys, history, memory, skills, routines and jobs) and quits, so it starts like a new install. A custom agent folder is left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Reset")
            }
            ReportBugSection()
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset OpenClicky?", isPresented: $confirmingReset) {
            Button("Delete Everything and Quit", role: .destructive) {
                Task { @MainActor in
                    await services.stop()
                    guard let report = behavior.performReset() else { return }
                    if report.succeeded {
                        NSApp.terminate(nil)
                    } else {
                        resetReport = report.failures.joined(separator: "\n")
                    }
                }
            }
        } message: {
            Text("This deletes \(behavior.resetPlan?.summary ?? "OpenClicky's data") and can't be undone.")
        }
        .confirmationDialog("Forget every conversation?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                try? services.history.deleteAll()
                services.chat.reload()
                services.drawings.reload()
            }
        } message: {
            Text("Home's chat and recent drawings start empty. Memory and background jobs are kept.")
        }
    }
}

struct SkillsSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        SkillsLibraryView(model: services.skills, compact: true)
            .padding(20)
            .onAppear { services.skills.reload() }
    }
}
