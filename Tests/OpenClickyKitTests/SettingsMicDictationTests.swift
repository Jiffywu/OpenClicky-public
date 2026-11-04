import Foundation
import Testing
@testable import OpenClickyKit

// Settings → Microphone, Settings → Dictation and the fourth talk key (hands-free dictation), without a microphone or
// a keyboard.

private func device(_ uid: String, _ name: String, _ transport: AudioDeviceTransport = .builtIn, isDefault: Bool = false) -> AudioDeviceInfo {
    AudioDeviceInfo(id: 1, uid: uid, name: name, transport: transport, inputChannels: 1, outputChannels: 0, nominalSampleRate: 48_000,
                    isDefaultInput: isDefault, isDefaultOutput: false)
}

@Test func theMicrophoneChoiceFallsBackToTheDefaultWhenTheSavedOneIsGone() throws {
    let builtIn = device("built-in", "MacBook Air Microphone", isDefault: true)
    let airpods = device("airpods", "AirPods Pro", .bluetooth)
    let inputs = [builtIn, airpods]

    let followDefault = MicrophoneChoice.resolve(savedUID: nil, inputs: inputs)
    #expect(followDefault.effective?.uid == "built-in" && !followDefault.usesSavedDevice && followDefault.note == nil)

    let saved = MicrophoneChoice.resolve(savedUID: "airpods", inputs: inputs)
    #expect(saved.effective?.uid == "airpods" && saved.usesSavedDevice)
    #expect(saved.note?.contains("Bluetooth") == true)

    let gone = MicrophoneChoice.resolve(savedUID: "usb-mic", inputs: inputs)
    #expect(gone.effective?.uid == "built-in" && !gone.usesSavedDevice)
    #expect(gone.note?.contains("isn't connected") == true)

    #expect(MicrophoneChoice.resolve(savedUID: nil, inputs: []).note == "No microphone is connected.")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oc-mic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("microphone.json")
    #expect(MicrophoneSettings.load(from: url) == MicrophoneSettings())
    try MicrophoneSettings(deviceUID: "airpods").save(to: url)
    #expect(MicrophoneSettings.load(from: url).deviceUID == "airpods")
}

private final class LevelsSource: MicrophoneTestSource, @unchecked Sendable {
    let levels: [AudioLevel]
    let failure: Error?
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioLevel>.Continuation?
    private(set) var stops = 0
    let keepOpen: Bool

    init(_ levels: [AudioLevel], failure: Error? = nil, keepOpen: Bool = false) {
        self.levels = levels
        self.failure = failure
        self.keepOpen = keepOpen
    }

    func start() throws -> AsyncStream<AudioLevel> {
        if let failure { throw failure }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioLevel.self)
        levels.forEach { continuation.yield($0) }
        if keepOpen { lock.withLock { self.continuation = continuation } } else { continuation.finish() }
        return stream
    }

    func stop() {
        lock.withLock {
            stops += 1
            continuation?.finish()
            continuation = nil
        }
    }
}

@Test func theMicrophoneTestSaysWhatItHeard() async {
    let speech = (0..<20).map { AudioLevel(rms: $0 == 10 ? 0.1 : 0.004, peak: $0 == 10 ? 0.5 : 0.02) }
    let heard = await MicrophoneTest.run(source: LevelsSource(speech), duration: 0.2)
    #expect(heard.verdict == .heard && heard.failure == nil)
    #expect(heard.analyzer.message(deviceName: "AirPods Pro") == "Heard you clearly on AirPods Pro.")

    let faint = await MicrophoneTest.run(source: LevelsSource(Array(repeating: AudioLevel(rms: 0.003, peak: 0.01), count: 30)), duration: 0.2)
    #expect(faint.verdict == .quiet)
    #expect(faint.analyzer.message(deviceName: nil).contains("Only faint sound"))

    let zeros = await MicrophoneTest.run(source: LevelsSource(Array(repeating: AudioLevel(rms: 0, peak: 0), count: 30)), duration: 0.2)
    #expect(zeros.verdict == .silent)
    #expect(zeros.analyzer.message(deviceName: "USB Mic").contains("Microphone access"))

    let nothing = await MicrophoneTest.run(source: LevelsSource([]), duration: 0.2)
    #expect(nothing.verdict == .noAudio)

    let denied = await MicrophoneTest.run(source: LevelsSource([], failure: AudioIOError.microphonePermissionDenied), duration: 0.2)
    #expect(denied.failure != nil)

    // A source that never ends on its own is stopped when the time is up.
    let open = LevelsSource([AudioLevel(rms: 0.2, peak: 0.6)], keepOpen: true)
    let started = Date()
    let timed = await MicrophoneTest.run(source: open, duration: 0.3)
    #expect(timed.verdict == .heard && open.stops >= 1)
    #expect(Date().timeIntervalSince(started) < 3)
}

@Test func dictationLanguageAndAutomaticDetection() {
    var settings = DictationSettings()
    #expect(settings.language == nil)
    DictationLanguages.apply(autoDetect: false, language: "fr-CA", to: &settings)
    #expect(settings.language == "fr-CA")
    DictationLanguages.apply(autoDetect: true, language: settings.language, to: &settings)
    #expect(settings.language == nil)
    // Turning detection off without a language picks the Mac's own.
    #expect(DictationLanguages.suggested(preferred: ["de-AT", "en-US"]) == "de-DE")
    #expect(DictationLanguages.suggested(preferred: ["en-GB"]) == "en-GB")
    #expect(DictationLanguages.suggested(preferred: ["xx"]) == "en-US")
    #expect(DictationLanguages.options(including: "gsw-CH").first == "gsw-CH")
    #expect(DictationLanguages.options(including: "en-US") == DictationLanguages.common)
    #expect(DictationLanguages.displayName("en-GB", locale: Locale(identifier: "en_US")) == "English (United Kingdom)")
}

@Test func theDictionaryHoldsFiftyWordsAndSaysWhyAnAddFailed() {
    var vocabulary = DictationVocabulary()
    #expect(DictionaryEdit.add("  Open   Clicky ", to: &vocabulary) == .added("Open Clicky"))
    #expect(DictionaryEdit.add("open clicky", to: &vocabulary) == .duplicate)
    #expect(DictionaryEdit.add("   ", to: &vocabulary) == .blank)
    #expect(DictionaryEdit.add(String(repeating: "x", count: 61), to: &vocabulary) == .tooLong)
    for index in 1..<DictationVocabulary.maxWords { _ = DictionaryEdit.add("word\(index)", to: &vocabulary) }
    #expect(vocabulary.words.count == 50)
    let full = DictionaryEdit.add("one more", to: &vocabulary)
    #expect(full == .full && full.message?.contains("50") == true)
}

// MARK: - The hands-free talk key

@Test func theHandsFreeSlotIsOptionalAndChecksClashes() throws {
    var keys = TalkKeySettings.defaults
    #expect(keys.handsFreeDictation == nil && keys[.handsFreeDictation] == nil)
    #expect(TalkKeyAction.allCases.count == 4 && TalkKeyAction.handsFreeDictation.isOptional)
    #expect(TalkKeyAction.handsFreeDictation.triggerKind == .doubleTap)
    #expect(keys.problems.isEmpty)

    // The text key's double tap can't also be the hands-free key; Fn gets macOS's dictation warning.
    let sameAsText = TalkKeyRules.problems(.doubleTap(.control), for: .handsFreeDictation, in: keys)
    #expect(sameAsText.first?.severity == .blocking && sameAsText.first?.other == .text)
    #expect(TalkKeyRules.problems(.doubleTap(.function), for: .handsFreeDictation, in: keys).first?.severity == .warning)
    // A held chord is allowed for the hands-free slot too, unless it overlaps another chord.
    #expect(TalkKeyRules.problems(.hold(.shift, .option), for: .handsFreeDictation, in: keys).isEmpty)
    #expect(TalkKeyRules.problems(.hold(.control, .option, .shift), for: .handsFreeDictation, in: keys).first?.other == .voice)
    #expect(TalkKeyRules.problems(.doubleTap(.option), for: .handsFreeDictation, in: keys).isEmpty)

    // Recorded like the text key: one modifier, pressed and released.
    var recorder = TalkKeyRecorder(action: .handsFreeDictation, settings: keys)
    recorder.start()
    recorder.modifiersChanged([.option])
    recorder.modifiersChanged([])
    keys = try #require(recorder.applied())
    #expect(keys.handsFreeDictation == .doubleTap(.option))
    // ...and an existing hands-free key blocks the text key from taking it.
    #expect(TalkKeyRules.problems(.doubleTap(.option), for: .text, in: keys).first?.other == .handsFreeDictation)

    // Saved and loaded with the rest; a bad shape in the file is ignored; clearing it removes it.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oc-keys-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("talk-keys.json"), dictation = folder.appendingPathComponent("dictation.json")
    try keys.save(to: url, dictationURL: dictation)
    #expect(TalkKeySettings.load(from: url, dictationURL: dictation).handsFreeDictation == .doubleTap(.option))
    try #"{"handsFreeDictation":{"kind":"hold","modifiers":["option"]}}"#.write(to: url, atomically: true, encoding: .utf8)
    #expect(TalkKeySettings.load(from: url, dictationURL: nil).handsFreeDictation == nil)
    keys[.handsFreeDictation] = nil
    try keys.save(to: url, dictationURL: nil)
    #expect(TalkKeySettings.load(from: url, dictationURL: nil) == TalkKeySettings.defaults)
    // Setting a required slot to nil is ignored.
    keys[.voice] = nil
    #expect(keys.voice == TalkKeySettings.defaults.voice)
}

@Test func doubleTappingTheHandsFreeKeyTogglesDictationThroughTheEngagementMachine() {
    var keys = TalkKeySettings.defaults
    keys.handsFreeDictation = .doubleTap(.option)
    var gestures = TalkKeyGestureMachine(keys: keys)
    var dictation = DictationEngagementMachine()
    var effects: [DictationEngagementMachine.Effect] = []
    func feed(_ outputs: [TalkKeyGestureMachine.Output]) {
        for case .dictation(let input) in outputs { effects += dictation.handle(input) }
    }

    // Two clean taps of Option: on at once (no wait for a third tap).
    feed(gestures.modifiersChanged([.option], at: 0))
    #expect(gestures.modifiersChanged([], at: 0.08).isEmpty)
    feed(gestures.modifiersChanged([.option], at: 0.2))
    let second = gestures.modifiersChanged([], at: 0.27)
    #expect(second == [.dictation(.handsFreeToggle)])
    feed(second)
    #expect(gestures.pendingDeadline == nil)
    #expect(effects == [.startCapture, .engagementChanged(.handsFreeLocked)])
    #expect(dictation.engagement == .handsFreeLocked)

    // Typing while dictating doesn't stop it; two more taps finish and type.
    feed(gestures.keyDown(isEscape: false, at: 2))
    #expect(dictation.engagement == .handsFreeLocked)
    effects = []
    feed(gestures.modifiersChanged([.option], at: 5))
    feed(gestures.modifiersChanged([], at: 5.1))
    feed(gestures.modifiersChanged([.option], at: 5.25))
    feed(gestures.modifiersChanged([], at: 5.3))
    #expect(effects == [.commit, .engagementChanged(.idle)])
}

@Test func theHandsFreeKeyIgnoresSlowTapsChordsAndTheTextKey() {
    var keys = TalkKeySettings.defaults
    keys.handsFreeDictation = .doubleTap(.option)
    var machine = TalkKeyGestureMachine(keys: keys)
    // Taps too far apart.
    _ = machine.modifiersChanged([.option], at: 0)
    _ = machine.modifiersChanged([], at: 0.05)
    _ = machine.modifiersChanged([.option], at: 1.0)
    #expect(machine.modifiersChanged([], at: 1.05).isEmpty)
    // A held Option isn't a tap.
    _ = machine.modifiersChanged([.option], at: 3)
    #expect(machine.modifiersChanged([], at: 3.6).isEmpty)
    _ = machine.modifiersChanged([.option], at: 3.7)
    #expect(machine.modifiersChanged([], at: 3.75).isEmpty)
    // Option pressed then Control joins: the voice chord, not a tap.
    _ = machine.modifiersChanged([.option], at: 6)
    #expect(machine.modifiersChanged([.option, .control], at: 6.05) == [.voicePressed])
    _ = machine.modifiersChanged([], at: 7)
    _ = machine.modifiersChanged([.option], at: 7.1)
    #expect(!machine.modifiersChanged([], at: 7.15).contains(.dictation(.handsFreeToggle)))
    // A click between taps resets them.
    _ = machine.modifiersChanged([.option], at: 9)
    _ = machine.modifiersChanged([], at: 9.05)
    _ = machine.otherActivity(at: 9.1)
    _ = machine.modifiersChanged([.option], at: 9.15)
    #expect(machine.modifiersChanged([], at: 9.2).isEmpty)
    // The text key's double tap still opens the text panel.
    _ = machine.modifiersChanged([.control], at: 12)
    _ = machine.modifiersChanged([], at: 12.05)
    _ = machine.modifiersChanged([.control], at: 12.2)
    _ = machine.modifiersChanged([], at: 12.25)
    #expect(machine.tick(at: 13) == [.textTrigger])

    // With no hands-free key, double-tapping Option does nothing.
    var plain = TalkKeyGestureMachine(keys: .defaults)
    _ = plain.modifiersChanged([.option], at: 0)
    _ = plain.modifiersChanged([], at: 0.05)
    _ = plain.modifiersChanged([.option], at: 0.2)
    #expect(plain.modifiersChanged([], at: 0.25).isEmpty)
}
