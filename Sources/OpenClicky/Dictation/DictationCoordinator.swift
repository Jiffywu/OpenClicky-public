import AppKit
import Observation
import OpenClickyKit

/// Dictation in the app: the chord monitor, the controller, the microphone and the HUD, wired together.
///
/// The app model owns one and calls `start()`. It needs engines from the app: the stt slot's client, a cleaner built
/// from the brain-fast slot (`DictationCleanupClientResolver.makeCleaner` with `AdapterModelClientFactory`), and
/// optionally a fallback recognizer (`Engines.onDeviceFallback`). Without a cleaner the transcript gets the local
/// tidy only.
@MainActor
@Observable
final class DictationCoordinator {
    struct Engines: Sendable {
        var speechToText: @Sendable () -> (any SpeechToTextClient)?
        var cleaner: @Sendable () -> DictationCleaner?
        /// Hears a press again when the streaming session loses it. `onDeviceFallback` suits network stt models.
        var fallbackSpeechToText: @Sendable () -> (any SpeechToTextClient)? = { nil }

        /// Nothing configured: the HUD explains that speech to text isn't set up.
        static let none = Engines(speechToText: { nil }, cleaner: { nil })

        /// Apple's on-device recognizer as the fallback. It never asks for Speech Recognition permission mid-dictation;
        /// where it would need that permission and doesn't have it, the fallback fails and the streamed words are kept.
        static let onDeviceFallback: @Sendable () -> (any SpeechToTextClient)? = {
            AppleSpeechClient(context: ProviderContext(provider: ProviderConfig(id: "apple-speech", dialect: .appleSpeech), apiKey: nil),
                              promptsForAuthorization: false)
        }
    }

    /// The dictionary every dictation press and Settings → Dictation share (one cached copy, so an added word counts
    /// from the next press).
    nonisolated static let vocabulary = DictationVocabularyStore()

    private(set) var status = DictationStatus()
    private(set) var settings: DictationSettings
    private(set) var isRunning = false

    @ObservationIgnored private let controller: DictationController
    @ObservationIgnored private let keys: DictationKeyMonitor
    @ObservationIgnored private let hud = DictationHUDPanelController()
    @ObservationIgnored private let microphone: any DictationAudioInput
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    /// Each finished dictation's report (the notch shows text left on the clipboard).
    @ObservationIgnored var onSessionFinished: ((DictationSessionReport) -> Void)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// False when the app's talk-key tap delivers the chord (`handleKey`, `escape()`) instead of the built-in monitor.
    @ObservationIgnored private let ownsKeys: Bool

    init(settings: DictationSettings = .load(), engines: Engines, microphone: (any DictationAudioInput)? = nil, ownsKeys: Bool = true) {
        self.settings = settings
        self.ownsKeys = ownsKeys
        let microphone = microphone ?? DictationMicrophone(deviceUID: MicrophoneSettings.load().deviceUID)
        self.microphone = microphone
        let chord = DictationKeyMonitor.flags(for: settings.holdChord)
        keys = DictationKeyMonitor(chord: chord)
        controller = DictationController(
            services: Self.services(settings: settings, engines: engines, microphone: microphone),
            allowsDoubleTapLock: settings.handsFreeDoubleTap)
        keys.onInput = { [weak self] input in self?.controller.handle(input) }
        keys.onEscape = { [weak self] in self?.controller.cancelActive() }
        keys.wantsOtherKeys = { [weak self] in self?.controller.isCapturing ?? false }
        controller.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        controller.onLearned = { [weak self] learned in self?.showLearned(learned) }
        controller.onSessionFinished = { [weak self] report in self?.onSessionFinished?(report) }
    }

    var chordLabel: String { DictationKeyMonitor.label(for: settings.holdChord) }

    func start() {
        if ownsKeys { keys.start() }
        isRunning = true
    }

    /// A chord press, release or other key from the app's talk-key tap. Other keys only matter while dictating.
    func handleKey(_ input: DictationEngagementMachine.Input) {
        guard isRunning else { return }
        if case .otherKey = input, !controller.isCapturing { return }
        controller.handle(input)
    }

    /// Escape from the talk-key tap: cancels dictation in progress. False when nothing was dictating.
    func escape() -> Bool {
        guard controller.isCapturing else { return false }
        controller.cancelActive()
        return true
    }

    var isDictating: Bool { controller.isCapturing }

    /// Settings → Microphone picked an input (nil = the system default); used from the next press.
    func selectMicrophone(uid: String?) {
        (microphone as? DictationMicrophone)?.deviceUID = uid
    }

    func stop() {
        keys.stop()
        controller.discard()
        hud.hide()
        isRunning = false
    }

    /// Applies new settings (chord, language, cleanup, archive, insertion table) and saves them.
    func update(_ newSettings: DictationSettings, engines: Engines) {
        settings = newSettings
        try? newSettings.save()
        keys.chord = DictationKeyMonitor.flags(for: newSettings.holdChord)
        controller.allowsDoubleTapLock = newSettings.handsFreeDoubleTap
        controller.services = Self.services(settings: newSettings, engines: engines, microphone: microphone)
    }

    static func services(settings: DictationSettings, engines: Engines, microphone: any DictationAudioInput) -> DictationController.Services {
        let seeds = keytermSeeds(settings)
        let chord = DictationKeyMonitor.flags(for: settings.holdChord).rawValue
        let none: @Sendable () -> (any SpeechToTextClient)? = { nil }
        let fallback = settings.fallbackTranscription ? engines.fallbackSpeechToText : none
        return DictationController.Services(
            focus: AccessibilityFocusReader(),
            audio: microphone,
            speechToText: engines.speechToText,
            cleaner: engines.cleaner,
            inserter: TextInserter(system: SystemTextInsertion(), table: settings.strategyTable),
            vocabulary: vocabulary,
            archive: settings.archiveTranscripts ? DictationTranscriptArchive() : nil,
            language: settings.language,
            keytermSeeds: seeds,
            learnCorrections: settings.learnCorrections,
            fallbackSpeechToText: fallback,
            waitForKeysReleased: { await Self.waitForRelease(of: chord) })
    }

    /// The words every press's keyterms start from (the dictation ears open their warm socket for the same ones).
    nonisolated static func keytermSeeds(_ settings: DictationSettings) -> [String] {
        var seeds = DictationController.Services.defaultKeytermSeeds
        if settings.seedUserName, !NSFullUserName().isEmpty { seeds.append(NSFullUserName()) }
        return seeds
    }

    /// Synthesized shortcuts must not pick up the dictation keys, so insertion waits (briefly) until they are up.
    nonisolated static func waitForRelease(of chord: UInt) async {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let held = await MainActor.run { NSEvent.modifierFlags.rawValue }
            if held & chord == 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: HUD

    private func statusChanged(_ newStatus: DictationStatus) {
        status = newStatus
        if newStatus.phase == .listening {
            startLevelUpdates()
        } else {
            levelTask?.cancel()
            levelTask = nil
        }
        render()
    }

    private func render(level: Double = 0) {
        guard let content = Self.hudContent(for: status, level: level, chordLabel: chordLabel) else {
            if noticeTask == nil { hud.hide() }
            return
        }
        noticeTask?.cancel()
        noticeTask = nil
        hud.show(content, near: status.fieldFrame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    }

    private func startLevelUpdates() {
        guard levelTask == nil else { return }
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.render(level: Double(self.microphone.level()))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func showLearned(_ learned: [LearnedCorrection]) {
        guard status.phase == .idle, !learned.isEmpty else { return }
        let words = learned.map { "“\($0.corrected)”" }.joined(separator: ", ")
        hud.show(DictationHUDContent(tone: .notice, symbol: "character.book.closed.fill", title: "Learned \(words)",
                                     detail: "Dictation will spell \(learned.count == 1 ? "it" : "them") this way"),
                 near: nil)
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.noticeTask = nil
            if self.status.phase == .idle { self.hud.hide() }
        }
    }

    /// The HUD for a status, in OpenClicky's own words; nil hides it.
    static func hudContent(for status: DictationStatus, level: Double, chordLabel: String) -> DictationHUDContent? {
        let heard = status.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.phase {
        case .idle:
            return nil
        case .listening where status.engagement == .handsFreeLocked:
            return DictationHUDContent(tone: .handsFree, symbol: "lock.fill", title: heard.isEmpty ? "Hands-free dictation" : heard,
                                       detail: "Tap \(chordLabel) to finish", level: level)
        case .listening:
            return DictationHUDContent(tone: .listening, symbol: "mic.fill", title: heard.isEmpty ? "Listening…" : heard,
                                       detail: "Let go to type", level: level)
        case .finishing:
            return DictationHUDContent(tone: .working, symbol: "waveform", title: heard.isEmpty ? "Finishing…" : heard, detail: "Finishing…")
        case .cleaning:
            return DictationHUDContent(tone: .working, symbol: "sparkles", title: "Tidying up…")
        case .inserting:
            return DictationHUDContent(tone: .working, symbol: "keyboard", title: "Typing…")
        case .done(let result):
            switch result {
            case .typed(let app):
                return DictationHUDContent(tone: .success, symbol: "checkmark", title: app.map { "Typed into \($0)" } ?? "Typed")
            case .copiedToClipboard(let reason):
                let why = reason == .focusLost ? "The field lost focus" : "Couldn't type here"
                return DictationHUDContent(tone: .notice, symbol: "doc.on.clipboard.fill", title: "Copied to the clipboard",
                                           detail: "\(why) · press ⌘V to paste")
            case .refused(.secureField):
                return DictationHUDContent(tone: .warning, symbol: "lock.shield.fill", title: "Not typed into a password field")
            case .refused(.secureEventInput):
                return DictationHUDContent(tone: .warning, symbol: "lock.shield.fill", title: "Keyboard input is protected right now",
                                           detail: "Nothing was typed")
            case .refused(.accessibilityPermission):
                return DictationHUDContent(tone: .warning, symbol: "hand.raised.fill", title: "Allow Accessibility to type for you",
                                           detail: "Copied to the clipboard instead")
            case .nothingHeard:
                return DictationHUDContent(tone: .notice, symbol: "ear", title: "Didn't catch that")
            case .cancelled:
                return nil
            }
        case .failed(let message):
            return DictationHUDContent(tone: .warning, symbol: "exclamationmark.triangle.fill", title: message)
        }
    }
}
