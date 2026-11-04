import AppKit
import OpenClickyKit
import SwiftUI

// Settings → Microphone (input device and a mic test) and Settings → Dictation (language, automatic detection, the
// dictionary and the dictation switches).

/// Settings → Microphone.
@MainActor
@Observable
final class MicrophoneSettingsModel {
    enum TestState: Equatable {
        case idle
        case listening(level: Float)
        case finished(MicrophoneTestAnalyzer.Verdict, String)
        case failed(String)
    }

    private(set) var settings: MicrophoneSettings
    private(set) var inputs: [AudioDeviceInfo] = []
    private(set) var test: TestState = .idle

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var watcher: AudioDeviceWatcher?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var pinned = false

    init(url: URL?, model: AppModel) {
        self.url = url
        self.model = model
        settings = url.map { MicrophoneSettings.load(from: $0) } ?? MicrophoneSettings()
    }

    var choice: MicrophoneChoice { MicrophoneChoice.resolve(savedUID: settings.deviceUID, inputs: inputs) }

    /// Lists the inputs and follows changes while the page is open.
    func appear() {
        guard !pinned else { return }
        inputs = AudioDevices.inputs()
        if watcher == nil {
            watcher = AudioDeviceWatcher(queue: .main) { [weak self] _ in
                Task { @MainActor in self?.inputs = AudioDevices.inputs() }
            }
        }
    }

    func disappear() {
        watcher = nil
        stopTest()
    }

    func select(_ uid: String?) {
        settings.deviceUID = uid
        if let url { try? settings.save(to: url) }
        // The voice loop's mic and dictation's mic switch now; a choice also drops a failover pin to the built-in mic.
        model?.voiceLoop?.selectMicrophone(uid: uid)
        if case .finished = test { test = .idle }
    }

    /// Listens for three seconds on the chosen input and says what it heard. Needs Microphone permission.
    func runTest() {
        stopTest()
        let source = CaptureMicrophoneTestSource(deviceUID: settings.deviceUID)
        let name = choice.effective?.name
        test = .listening(level: 0)
        testTask = Task { [weak self] in
            let result = await MicrophoneTest.run(source: source, duration: 3) { level in
                Task { @MainActor in
                    if case .listening = self?.test { self?.test = .listening(level: level.normalized) }
                }
            }
            guard let self, !Task.isCancelled else { return }
            if let failure = result.failure {
                self.test = .failed(failure)
            } else {
                self.test = .finished(result.verdict, result.analyzer.message(deviceName: source.deviceName ?? name))
            }
        }
    }

    func stopTest() {
        testTask?.cancel()
        testTask = nil
        if case .listening = test { test = .idle }
    }

    /// Fixture inputs and test state (evidence renders).
    func show(inputs: [AudioDeviceInfo], test: TestState) {
        pinned = true
        self.inputs = inputs
        self.test = test
    }
}

struct MicrophoneSettingsPage: View {
    @Environment(HomeServices.self) private var services
    @Environment(AppModel.self) private var model

    var body: some View {
        let mic = services.microphone
        let choice = mic.choice
        Form {
            Section {
                Picker("Input", selection: Binding(get: { mic.settings.deviceUID }, set: { mic.select($0) })) {
                    Text(systemDefaultLabel(mic)).tag(String?.none)
                    ForEach(mic.inputs) { device in
                        Text("\(device.name)  ·  \(device.transport.description)").tag(Optional(device.uid))
                    }
                    if let saved = mic.settings.deviceUID, !mic.inputs.contains(where: { $0.uid == saved }) {
                        Text("Disconnected microphone").tag(Optional(saved))
                    }
                }
                if let device = choice.effective {
                    LabeledContent("Listening on") {
                        Text("\(device.name), \(Int(device.nominalSampleRate)) Hz").foregroundStyle(.secondary)
                    }
                }
                if let note = choice.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Microphone")
            } footer: {
                Text("Talking to OpenClicky, always-on voice and dictation all use this input. If it goes silent mid-question, OpenClicky rebuilds it and then falls back to the Mac's built-in microphone; picking an input here clears that fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Test") {
                HStack(spacing: 12) {
                    switch mic.test {
                    case .listening(let level):
                        Button("Stop") { mic.stopTest() }
                        LevelMeter(level: level)
                        Text("Say something…").foregroundStyle(.secondary)
                    default:
                        Button("Test Microphone") { mic.runTest() }
                            .disabled(model.permissions.states[.microphone] == .denied)
                        Spacer()
                    }
                }
                switch mic.test {
                case .finished(let verdict, let message):
                    Label(message, systemImage: verdict == .heard ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(verdict == .heard ? .green : .orange)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                default:
                    EmptyView()
                }
                if model.permissions.states[.microphone] != .granted {
                    Text("The test needs Microphone access (Settings → Permissions).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { mic.appear() }
        .onDisappear { mic.disappear() }
    }

    private func systemDefaultLabel(_ mic: MicrophoneSettingsModel) -> String {
        let name = mic.inputs.first(where: \.isDefaultInput)?.name
        return name.map { "System default (\($0))" } ?? "System default"
    }
}

/// A small horizontal level bar.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(level > 0.55 ? Color.green : Color.accentColor)
                    .frame(width: max(4, proxy.size.width * CGFloat(min(1, max(0, level)))))
            }
        }
        .frame(width: 160, height: 8)
    }
}

// MARK: - Dictation

/// Settings → Dictation: the language hint, automatic detection, the dictionary, and dictation's switches.
@MainActor
@Observable
final class DictationSettingsModel {
    private(set) var settings: DictationSettings
    private(set) var vocabulary = DictationVocabulary()
    var draftWord = ""
    var message: String?

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let store: DictationVocabularyStore?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var pinned = false
    /// Dictionary edits started, so a page load that lands after one doesn't put an older copy back on screen.
    @ObservationIgnored private var edits = 0

    init(url: URL?, store: DictationVocabularyStore?, model: AppModel) {
        self.url = url
        self.store = store
        self.model = model
        settings = url.map { DictationSettings.load(from: $0) } ?? DictationSettings()
    }

    func appear() {
        guard !pinned else { return }
        if let url { settings = DictationSettings.load(from: url) }
        guard let store else { return }
        let editsBefore = edits
        Task { [weak self] in
            let loaded = await store.load()
            // An edit that finished first already shows what the store holds, which is newer than this load.
            guard let self, edits == editsBefore else { return }
            vocabulary = loaded
        }
    }

    var autoDetect: Bool { settings.language == nil }

    func setAutoDetect(_ on: Bool) {
        DictationLanguages.apply(autoDetect: on, language: settings.language, to: &settings)
        save()
    }

    func setLanguage(_ code: String) {
        DictationLanguages.apply(autoDetect: false, language: code, to: &settings)
        save()
    }

    func set(_ key: WritableKeyPath<DictationSettings, Bool>, _ value: Bool) {
        settings[keyPath: key] = value
        save()
    }

    func setCleanup(_ on: Bool) {
        settings.cleanup.enabled = on
        save()
    }

    private func save() {
        guard !pinned else { return }
        if let url {
            do { try settings.save(to: url) } catch { message = "Couldn't save: \(error.localizedDescription)" }
        }
        // The running dictation picks the new settings up (language, hands-free, cleanup, archive).
        model?.voiceLoop?.reloadDictationSettings()
    }

    func addWord() {
        let word = draftWord
        edit({ DictionaryEdit.add(word, to: &$0) }) { [weak self] outcome in
            guard let self else { return }
            guard case .added = outcome else {
                message = outcome.message
                return
            }
            if draftWord == word { draftWord = "" }
            message = nil
        }
    }

    func removeWord(_ word: String) {
        edit({ $0.remove(word) }) { _ in }
    }

    func removeCorrection(_ correction: LearnedCorrection) {
        // By what it maps, not by value: dictation may have raised its count since the page loaded it.
        edit({ vocabulary in
            vocabulary.corrections.removeAll {
                $0.original.caseInsensitiveCompare(correction.original) == .orderedSame && $0.corrected == correction.corrected
            }
        }) { _ in }
    }

    /// Changes the dictionary in one read-modify-write on the store and shows what the store then holds. Dictation
    /// learns corrections through the same store while this page is open, so saving the page's own copy would erase them.
    private func edit<T: Sendable>(_ change: @escaping @Sendable (inout DictationVocabulary) -> T, then done: @escaping @MainActor (T) -> Void) {
        edits += 1
        guard !pinned, let store else {
            var copy = vocabulary
            let result = change(&copy)
            vocabulary = copy
            done(result)
            return
        }
        Task { [weak self] in
            do {
                let (result, stored) = try await store.update { vocabulary -> (T, DictationVocabulary) in
                    let result = change(&vocabulary)
                    return (result, vocabulary)
                }
                self?.vocabulary = stored
                done(result)
            } catch {
                self?.message = "Couldn't save the dictionary: \(error.localizedDescription)"
            }
        }
    }

    /// Fixture settings and words (evidence renders).
    func show(settings: DictationSettings, vocabulary: DictationVocabulary) {
        pinned = true
        self.settings = settings
        self.vocabulary = vocabulary
    }
}

struct DictationSettingsPage: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        let dictation = services.dictation
        let keys = services.talkKeys.settings
        Form {
            Section {
                Toggle("Detect the language automatically", isOn: Binding(get: { dictation.autoDetect }, set: { dictation.setAutoDetect($0) }))
                if !dictation.autoDetect {
                    Picker("Language", selection: Binding(get: { dictation.settings.language ?? "" }, set: { dictation.setLanguage($0) })) {
                        ForEach(DictationLanguages.options(including: dictation.settings.language), id: \.self) { code in
                            Text(DictationLanguages.displayName(code)).tag(code)
                        }
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text(dictation.autoDetect
                     ? "Speech to text works out the language as you speak. Pick one if it guesses wrong, or for short phrases."
                     : "Dictation listens for \(DictationLanguages.displayName(dictation.settings.language ?? "")) only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    TextField("Add a word or name", text: Binding(get: { dictation.draftWord }, set: { dictation.draftWord = $0 }))
                        .onSubmit { dictation.addWord() }
                    Button("Add") { dictation.addWord() }
                        .disabled(dictation.draftWord.trimmingCharacters(in: .whitespaces).isEmpty
                                  || dictation.vocabulary.words.count >= DictationVocabulary.maxWords)
                }
                if let message = dictation.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                if dictation.vocabulary.words.isEmpty {
                    Text("No words yet. Add names, products and jargon dictation should spell your way.").foregroundStyle(.secondary)
                }
                WordFlow(words: dictation.vocabulary.words) { dictation.removeWord($0) }
                if !dictation.vocabulary.corrections.isEmpty {
                    DisclosureGroup("Learned from your corrections (\(dictation.vocabulary.corrections.count))") {
                        ForEach(dictation.vocabulary.corrections, id: \.self) { correction in
                            HStack {
                                Text("\(correction.original) → \(correction.corrected)")
                                Text("×\(correction.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { dictation.removeCorrection(correction) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Dictionary")
                    Spacer()
                    Text("\(dictation.vocabulary.words.count) of \(DictationVocabulary.maxWords)").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("These words are sent to speech to text as hints and to the cleanup model as spellings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dictating") {
                LabeledContent("Hold to dictate") { Text(keys.dictation.phrase).foregroundStyle(.secondary) }
                LabeledContent("Hands-free on and off") {
                    Text(keys.handsFreeDictation?.phrase ?? "No key (set one on Talk keys)").foregroundStyle(.secondary)
                }
                Toggle("Double-tap the dictation keys to keep dictating hands-free",
                       isOn: Binding(get: { dictation.settings.handsFreeDoubleTap }, set: { dictation.set(\.handsFreeDoubleTap, $0) }))
                Toggle("Tidy up what I said (punctuation, filler words, self-corrections)",
                       isOn: Binding(get: { dictation.settings.cleanup.enabled }, set: { dictation.setCleanup($0) }))
                Toggle("Learn spellings from my corrections",
                       isOn: Binding(get: { dictation.settings.learnCorrections }, set: { dictation.set(\.learnCorrections, $0) }))
                Toggle("Keep a daily transcript on this Mac",
                       isOn: Binding(get: { dictation.settings.archiveTranscripts }, set: { dictation.set(\.archiveTranscripts, $0) }))
                Button("Change the dictation keys…") { services.settingsPage = .talkKeys }.buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .onAppear { dictation.appear() }
    }
}

/// Words as removable chips, wrapped onto lines.
private struct WordFlow: View {
    let words: [String]
    let remove: (String) -> Void

    var body: some View {
        if !words.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(words, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                        Button { remove(word) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
        }
    }
}

/// A simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
