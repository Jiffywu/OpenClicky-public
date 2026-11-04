import AppKit
import OpenClickyKit
import SwiftUI

/// Settings → Voice: the voice slot's voices, preview clips rendered through the slot, and speech speed.
@MainActor
@Observable
final class VoiceSettingsModel {
    enum PreviewState: Equatable {
        case rendering
        case playing
        case ready(seconds: Double)
        case failed(String)
    }

    private(set) var settings: VoiceSettings
    private(set) var voices: [VoiceOption] = []
    private(set) var loadingVoices = false
    private(set) var voiceListNote: String?
    private(set) var previews: [String: PreviewState] = [:]

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let settingsURL: URL?
    @ObservationIgnored private let previewCache: URL?
    @ObservationIgnored private var voicesKey: String?
    /// Set by `showVoices`: the list stays as given (no network) until a forced refresh.
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var player: SpeechPlayer?
    @ObservationIgnored private var playback: Task<Void, Never>?
    /// The app plays previews; evidence renders and tests leave it off and only write WAV files.
    @ObservationIgnored var playsAudio = true

    init(model: AppModel, settingsURL: URL?, previewCache: URL?) {
        self.model = model
        self.settingsURL = settingsURL
        self.previewCache = previewCache
        settings = settingsURL.map(VoiceSettings.load(from:)) ?? VoiceSettings()
    }

    var selection: SlotSelection? { model.config.slots[.voice] }
    var provider: ProviderConfig? { selection.flatMap { model.config.provider($0.provider) } }
    var selectedVoice: String? { selection?.voice }

    func setSpeed(_ speed: Double) {
        settings.speed = speed
        save()
        player?.rate = Float(speed)
    }

    func choose(_ voice: VoiceOption) {
        guard model.config.slots[.voice] != nil else { return }
        model.config.slots[.voice]?.voice = voice.id
        model.save()
    }

    private func save() {
        guard let settingsURL else { return }
        try? settings.save(to: settingsURL)
    }

    /// Loads the voice list for the slot's current model (once per model).
    func loadVoices(force: Bool = false) {
        guard let selection, let provider else {
            voices = []
            voiceListNote = "Pick a voice model on the Models page first."
            return
        }
        let key = "\(provider.id)|\(selection.model)"
        guard force || (!pinned && key != voicesKey) else { return }
        pinned = false
        voicesKey = key
        voiceListNote = nil
        let descriptor = model.mergedCatalog.model(selection.model, servedBy: provider.dialect)
        if let fixed = VoiceCatalog.fixedOptions(for: descriptor) {
            voices = fixed
            return
        }
        switch provider.dialect {
        case .appleSpeechSynthesis:
            voices = VoiceCatalog.installedVoices()
            voiceListNote = "Voices installed on this Mac. Add more in System Settings → Accessibility → Spoken Content."
        case .elevenLabsSpeech:
            loadingVoices = true
            let credentials = model.credentials
            Task { [weak self] in
                do {
                    let key = try provider.credential.flatMap { try credentials.secret(named: $0) }
                    let list = try await VoiceCatalog.elevenLabsVoices(context: ProviderContext(provider: provider, apiKey: key))
                    self?.voices = list
                    self?.voiceListNote = "Voices in your ElevenLabs account."
                } catch let error as ProviderError where error.status == 401 || error.status == 403 {
                    self?.voices = []
                    self?.voiceListNote = "ElevenLabs didn't accept the key (HTTP \(error.status ?? 0)). Check it on Providers & keys."
                } catch {
                    self?.voices = []
                    self?.voiceListNote = "Couldn't list your ElevenLabs voices: \(error.localizedDescription)"
                }
                self?.loadingVoices = false
            }
        default:
            voices = []
            voiceListNote = "This voice model has no fixed list; type a voice name on the Models page."
        }
    }

    /// Fixture voices for evidence renders.
    func showVoices(_ list: [VoiceOption], note: String?) {
        voices = list
        voiceListNote = note
        pinned = true
    }

    func setPreviewState(_ state: PreviewState, for voice: String) { previews[voice] = state }

    /// Renders (or loads) the voice's preview clip through the voice slot and plays it at the chosen speed.
    func preview(_ voice: VoiceOption) {
        guard previews[voice.id] != .rendering else { return }
        previews[voice.id] = .rendering
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        let cache = previewCache
        let speed = Float(settings.speed)
        // Cancelling the old task only ends its wait; the old clip would keep playing under the new one.
        stopPreview()
        previews[voice.id] = .rendering
        playback = Task { [weak self] in
            do {
                let renderer = try VoicePreviewRenderer.forVoiceSlot(factory, cacheDirectory: cache)
                let clip = try await renderer.render(voice: voice.id)
                guard let self else { return }
                guard self.playsAudio else {
                    self.previews[voice.id] = .ready(seconds: clip.duration)
                    return
                }
                self.previews[voice.id] = .playing
                let player = SpeechPlayer(sampleRate: clip.format.sampleRate)
                player.rate = speed
                self.player = player
                _ = player.play(clip.pcm, format: clip.format, line: 0)
                await player.waitUntilDrained()
                if self.previews[voice.id] == .playing { self.previews[voice.id] = .ready(seconds: clip.duration) }
            } catch is CancellationError {
                self?.previews[voice.id] = nil
            } catch {
                self?.previews[voice.id] = .failed("\(error)")
            }
        }
    }

    func stopPreview() {
        playback?.cancel()
        playback = nil
        _ = player?.stop()
        player = nil
        for (id, state) in previews where state == .playing || state == .rendering { previews[id] = nil }
    }
}

/// Settings → Talk keys: the four modifier shortcuts and the recorder. Recording uses a local key monitor, so it
/// works while the Settings window is in front without Accessibility or Input Monitoring.
@MainActor
@Observable
final class TalkKeysModel {
    private(set) var settings: TalkKeySettings
    private(set) var recorder: TalkKeyRecorder?
    var message: String?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let dictationURL: URL?
    @ObservationIgnored private var monitor: Any?

    init(model: AppModel, url: URL?, dictationURL: URL?) {
        self.model = model
        self.url = url
        self.dictationURL = dictationURL
        settings = url.map { TalkKeySettings.load(from: $0, dictationURL: dictationURL) } ?? .defaults
    }

    /// Points the running talk-key monitor at the saved keys.
    func apply() {
        model.talkKeyMonitor.keys = settings
    }

    func isRecording(_ action: TalkKeyAction) -> Bool { recorder?.action == action && recorder?.isRecording == true }

    /// Records a key for `action`: a held chord or a double tap (nil keeps the slot's current kind).
    func startRecording(_ action: TalkKeyAction, kind: TalkKeyTrigger.Kind? = nil) {
        stopMonitor()
        var recorder = TalkKeyRecorder(action: action, settings: settings, kind: kind)
        recorder.start()
        self.recorder = recorder
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let type = event.type, keyCode = event.keyCode, flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                self?.handle(type: type, keyCode: keyCode, flags: flags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func cancelRecording() {
        recorder?.cancel()
        finish()
    }

    /// Feeds the recorder (also used by evidence renders to show a recording in progress).
    func feed(_ held: Set<DictationModifier>) {
        recorder?.modifiersChanged(held)
        if recorder?.isRecording == false { finish() }
    }

    /// True when the recorder used the key (so the window doesn't also act on it).
    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard recorder?.isRecording == true else { return false }
        if type == .keyDown {
            recorder?.keyPressed(isEscape: keyCode == 53)
            finish()
            return true
        }
        feed(Self.modifiers(flags))
        return true
    }

    private func finish() {
        stopMonitor()
        guard let recorder else { return }
        defer { self.recorder = nil }
        if let updated = recorder.applied() {
            settings = updated
            save()
            apply()
            if case .captured(let trigger, let warnings) = recorder.state {
                message = ([trigger.phrase + " now does: " + recorder.action.title.lowercased() + "."] + warnings.map(\.message)).joined(separator: " ")
            }
        } else if case .rejected(_, let reason) = recorder.state {
            message = reason
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Empties an optional slot (the hands-free key).
    func clear(_ action: TalkKeyAction) {
        guard action.isOptional else { return }
        cancelRecording()
        settings[action] = nil
        save()
        apply()
        message = "\(action.title) has no key now."
    }

    func resetToDefaults() {
        settings = .defaults
        save()
        apply()
        message = "Back to the defaults."
    }

    private func save() {
        guard let url else { return }
        do { try settings.save(to: url, dictationURL: dictationURL) } catch { message = "Couldn't save: \(error)" }
    }

    static func flags(_ modifiers: Set<DictationModifier>) -> NSEvent.ModifierFlags {
        DictationKeyMonitor.flags(for: Array(modifiers))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<DictationModifier> {
        var set = Set<DictationModifier>()
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.command) { set.insert(.command) }
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.function) { set.insert(.function) }
        return set
    }
}
