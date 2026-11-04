import AppKit
import os
import OpenClickyKit
import SwiftUI

/// Runs `OnboardingMachine` against the real app: polls permissions, validates the config, speaks the test line
/// through the voice slot, and hands the first question to Home's chat.
@MainActor
@Observable
final class OnboardingModel {
    private(set) var machine: OnboardingMachine
    var firstQuestion = ""
    /// Key drafts on the providers step, by credential name. Never saved anywhere but the credential store.
    var keyDrafts: [String: String] = [:]
    private(set) var storedKeys: Set<String> = []
    private(set) var keyMessage: String?
    /// The welcome chat's "type instead" field.
    var interviewDraft = ""
    /// The app plays the test line; evidence renders leave it off.
    @ObservationIgnored var playsAudio = true
    @ObservationIgnored var onClose: (() -> Void)?

    @ObservationIgnored let services: HomeServices
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var speaking: Task<Void, Never>?
    @ObservationIgnored private var testPlayer: SpeechPlayer?
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var keyMonitor: Any?
    /// Runs the welcome chat's realtime session and saves what was said.
    @ObservationIgnored let interview: OnboardingInterviewPerformer
    /// The "What should it be good at?" picker over OpenClicky's starter skills.
    @ObservationIgnored let skillPicker: SkillPicker
    @ObservationIgnored private static let log = Logger(subsystem: "app.openclicky", category: "onboarding")

    init(services: HomeServices) {
        self.services = services
        let saved = services.onboardingURL.flatMap { OnboardingProgress.load(from: $0) }
        machine = OnboardingMachine(state: saved?.completedAt == nil ? (saved ?? OnboardingState()) : OnboardingState())
        skillPicker = SkillPicker(stateURL: services.locations.skillsState.deletingLastPathComponent().appendingPathComponent("skill-picks.json"))
        let model = services.model
        // The chat runs in the realtime-voice slot, on speakers too (with the stricter echo gate): a first-run user
        // may not have headphones in. A missing slot fails the attempt, and the chat falls back to typing.
        interview = OnboardingInterviewPerformer(
            storage: .init(transcriptURL: services.onboardingURL.map {
                $0.deletingLastPathComponent().appendingPathComponent("onboarding-interview.json")
            }, memory: services.memoryStore),
            makeController: { @Sendable toolbox, instructions in
                let factory = await MainActor.run { EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials) }
                var environment = AlwaysOnVoiceController.Environment.live(client: try factory.realtimeVoice(), instructions: instructions,
                                                                           toolbox: toolbox, requireHeadphones: false)
                environment.maxReconnects = 0
                return AlwaysOnVoiceController(environment: environment)
            })
        interview.deliver = { [weak self] event in self?.send(event) }
        interview.acceptsSkip = { [weak self] in self?.machine.acceptsInterviewSkip ?? false }
        interview.onLog = { line in Self.log.info("\(line, privacy: .public)") }
    }

    var state: OnboardingState { machine.state }
    var model: AppModel { services.model }

    static let suggestedQuestions = [
        "What can you help me with?",
        "Explain what a VPN does, with a drawing.",
        "Give me three tips for writing clearer emails.",
    ]

    /// Re-runs the effects of the step the flow resumed on.
    func begin() {
        closing = false
        refreshKeys()
        switch machine.step {
        case .permissions: perform([.watchPermissions])
        case .providers: perform([.checkProviders])
        // Closing the window stopped the watcher; the step's onAppear may not run again when it reopens.
        case .talkKeys: watchTalkKeys(services.talkKeys.settings.voice)
        // A chat that was open when the window closed starts again.
        case .interview where machine.state.interview.phase == .notStarted: send(.startInterview)
        case .skills where machine.state.skillPicks == nil: perform([.loadSkillPicks])
        default: break
        }
    }

    func send(_ event: OnboardingEvent) {
        perform(machine.send(event))
    }

    func closedByUser() {
        guard !closing else { return }
        closing = true
        stopBackgroundWork()
        perform(machine.send(.dismiss).filter { $0 != .close })
    }

    /// Stops the permission poller, the test line (cancelling its task alone leaves the clip playing) and the
    /// talk-key watcher.
    private func stopBackgroundWork() {
        poller?.cancel()
        poller = nil
        speaking?.cancel()
        speaking = nil
        _ = testPlayer?.stop()
        testPlayer = nil
        stopWatchingTalkKeys()
        interview.shutDown()
    }

    // MARK: Effects

    private func perform(_ effects: [OnboardingEffect]) {
        for effect in effects {
            switch effect {
            case .requestPermission(let permission):
                guard let mapped = Self.map(permission) else { continue }
                Task { [weak self] in
                    await self?.model.permissions.request(mapped)
                    self?.pushPermissions()
                }
            case .watchPermissions:
                pushPermissions()
                poller?.cancel()
                poller = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let self, !Task.isCancelled else { return }
                        self.model.permissions.refresh()
                        self.pushPermissions()
                    }
                }
            case .stopWatchingPermissions:
                poller?.cancel()
                poller = nil
            case .checkProviders:
                checkProviders()
            case .speakTestLine(let line):
                speak(line)
            case .sendFirstQuestion(let question):
                services.chat.newConversation()
                services.chat.draft = question
                services.chat.send()
                services.openHome(section: .chat)
            case .openInterview, .sendInterviewText, .closeInterview, .saveInterview:
                interview.perform(effect)
            case .loadSkillPicks:
                let picks = skillPicker.loadPicks()
                perform(machine.send(.skillPicksLoaded(picks)))
            case .activateSkills(let picks):
                let result = skillPicker.activate(picks, library: services.skills.library)
                services.skills.reload()
                perform(machine.send(.skillsActivated(result.summary)))
            case .saveProgress:
                if let url = services.onboardingURL { try? OnboardingProgress.save(machine.state, to: url) }
            case .close:
                stopBackgroundWork()
                closing = true
                onClose?()
            }
        }
    }

    func pushPermissions() {
        var status: [OnboardingPermission: Bool] = [:]
        for permission in OnboardingPermission.allCases {
            guard let mapped = Self.map(permission) else { continue }
            status[permission] = model.permissions.states[mapped] == .granted
        }
        perform(machine.send(.permissionsChanged(status)))
    }

    /// The full state for one step permission (denied and restart-required as well as allowed).
    func permissionState(_ permission: OnboardingPermission) -> PermissionsCenter.State? {
        Self.map(permission).flatMap { model.permissions.states[$0] }
    }

    static func map(_ permission: OnboardingPermission) -> PermissionsCenter.Permission? {
        switch permission {
        case .microphone: .microphone
        case .screenRecording: .screenRecording
        case .accessibility: .accessibility
        case .speechRecognition: .speechRecognition
        }
    }

    func checkProviders() {
        model.revalidate()
        let split = OnboardingProviderCheck.split(model.issues, config: model.config)
        perform(machine.send(.providersChecked(blocking: split.blocking, warnings: split.warnings)))
    }

    private func speak(_ line: String) {
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        let plays = playsAudio
        speaking?.cancel()
        _ = testPlayer?.stop()
        speaking = Task { [weak self] in
            do {
                let renderer = try VoicePreviewRenderer.forVoiceSlot(factory, cacheDirectory: nil)
                let clip = try await renderer.render(voice: nil, text: line, useCache: false)
                try Task.checkCancellation()
                if plays, let self {
                    let player = SpeechPlayer(sampleRate: clip.format.sampleRate)
                    player.rate = Float(self.services.voice.settings.speed)
                    self.testPlayer = player
                    _ = player.play(clip.pcm, format: clip.format, line: 0)
                    await player.waitUntilDrained()
                    try Task.checkCancellation()
                }
                self?.send(.voiceTestFinished(seconds: clip.duration))
            } catch is CancellationError {
                self?.send(.voiceTestFailed("Stopped."))
            } catch {
                self?.send(.voiceTestFailed("\(error)"))
            }
        }
    }

    // MARK: Providers step

    func choose(_ plan: OnboardingSetupPlan) {
        model.config = plan.apply(to: model.config)
        model.save()
        refreshKeys()
        checkProviders()
    }

    var neededKeys: [(name: String, preset: ProviderPreset?)] { OnboardingSetupPlan.neededKeys(for: model.config) }

    func saveKey(_ name: String) {
        let key = (keyDrafts[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try model.credentials.setSecret(key, named: name)
            keyDrafts[name] = nil
            keyMessage = "Saved the \(name) key in your Keychain."
        } catch {
            keyMessage = "Couldn't save the \(name) key: \(error)"
        }
        refreshKeys()
        checkProviders()
    }

    func refreshKeys() {
        storedKeys = Set(neededKeys.map(\.name).filter { name in ((try? model.credentials.secret(named: name)) ?? nil)?.isEmpty == false })
    }

    /// Marks keys as stored without reading a credential store (evidence renders).
    func showStoredKeys(_ names: Set<String>) { storedKeys = names }

    /// Replaces the flow's state without running effects (evidence renders).
    func restoreMachine(_ machine: OnboardingMachine) { self.machine = machine }

    // MARK: Welcome chat step

    func sendTypedAnswer() {
        let text = interviewDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        interviewDraft = ""
        send(.interviewAnswered(text, typed: true))
    }

    // MARK: Talk keys step

    /// Notices the voice chord while the onboarding window is in front (a local monitor needs no permission).
    func watchTalkKeys(_ trigger: TalkKeyTrigger) {
        stopWatchingTalkKeys()
        let wanted = TalkKeysModel.flags(trigger.modifiers)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.modifierFlags.intersection(TalkKeyMonitor.relevantFlags) == wanted { self?.send(.talkKeyPracticed) }
            }
            return event
        }
    }

    func stopWatchingTalkKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
