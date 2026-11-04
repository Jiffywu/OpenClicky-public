import Foundation
import Testing
@testable import OpenClickyKit

@Test func recorderCapturesTheLargestChordHeldTogether() {
    var recorder = TalkKeyRecorder(action: .voice, settings: .defaults)
    recorder.start()
    recorder.modifiersChanged([.control])
    recorder.modifiersChanged([.control, .shift])
    recorder.modifiersChanged([.control, .shift, .command])
    // Letting go one key at a time keeps the full chord.
    recorder.modifiersChanged([.shift, .command])
    recorder.modifiersChanged([.command])
    #expect(recorder.isRecording)
    recorder.modifiersChanged([])
    #expect(recorder.state == .captured(.hold(.control, .shift, .command), warnings: []))
    #expect(recorder.applied()?.voice == .hold(.control, .shift, .command))
    #expect(recorder.prompt == "Hold Control, Shift and Command")
}

@Test func recorderRejectsSingleKeysOrdinaryKeysAndClashes() {
    var single = TalkKeyRecorder(action: .voice, settings: .defaults)
    single.start()
    single.modifiersChanged([.option])
    single.modifiersChanged([])
    guard case .rejected(let trigger, let reason) = single.state else { Issue.record("expected a rejection"); return }
    #expect(trigger == .hold(.option))
    #expect(reason.contains("at least two"))
    #expect(single.applied() == nil)

    var letter = TalkKeyRecorder(action: .voice, settings: .defaults)
    letter.start()
    letter.modifiersChanged([.command])
    letter.keyPressed(isEscape: false)
    guard case .rejected(nil, let why) = letter.state else { Issue.record("expected a rejection"); return }
    #expect(why.contains("only modifier keys"))

    var escape = TalkKeyRecorder(action: .dictation, settings: .defaults)
    escape.start()
    escape.keyPressed(isEscape: true)
    #expect(escape.state == .cancelled)

    // Dictation already holds Control+Fn.
    var clash = TalkKeyRecorder(action: .voice, settings: .defaults)
    clash.start()
    clash.modifiersChanged([.function, .control])
    clash.modifiersChanged([])
    guard case .rejected(_, let clashReason) = clash.state else { Issue.record("expected a clash"); return }
    #expect(clashReason == "fn ⌃ is already used for dictation.")
}

@Test func recorderTakesOneModifierForADoubleTap() {
    var recorder = TalkKeyRecorder(action: .text, settings: .defaults)
    recorder.start()
    recorder.modifiersChanged([.option])
    recorder.modifiersChanged([])
    #expect(recorder.state == .captured(.doubleTap(.option), warnings: []))
    #expect(recorder.applied()?.text.symbol == "⌥ ⌥")

    var two = TalkKeyRecorder(action: .text, settings: .defaults)
    two.start()
    two.modifiersChanged([.option, .shift])
    two.modifiersChanged([])
    guard case .rejected = two.state else { Issue.record("two keys can't be a double tap"); return }

    var fn = TalkKeyRecorder(action: .text, settings: .defaults)
    fn.start()
    fn.modifiersChanged([.function])
    fn.modifiersChanged([])
    guard case .captured(_, let warnings) = fn.state else { Issue.record("fn double tap is allowed with a warning"); return }
    #expect(warnings.first?.severity == .warning)
    #expect(warnings.first?.message.contains("macOS Dictation") == true)
}

@Test func overlappingHoldChordsClash() {
    var settings = TalkKeySettings.defaults
    // Control+Option+Shift contains the voice chord, so pressing it would start talking first.
    let problems = TalkKeyRules.problems(.hold(.control, .option, .shift), for: .dictation, in: settings)
    #expect(problems.first?.severity == .blocking)
    #expect(problems.first?.other == .voice)
    #expect(problems.first?.message == "⌃⌥⇧ overlaps ⌃⌥, which is used for talking to OpenClicky: pressing one would start the other.")

    // A double tap of Control next to a held Control+Option is fine (that's HeyClicky's own default pair).
    #expect(TalkKeyRules.problems(.doubleTap(.control), for: .text, in: settings).isEmpty)
    #expect(settings.problems.isEmpty)

    settings.dictation = .hold(.control, .option)
    #expect(settings.problems[.voice]?.first?.other == .dictation)
    #expect(settings.problems[.dictation]?.first?.other == .voice)
    // Any slot may be a double tap now; a double tap of Control for voice clashes with the text key's.
    #expect(TalkKeyRules.problems(.doubleTap(.control), for: .voice, in: .defaults).first?.other == .text)
    #expect(TalkKeyRules.problems(.doubleTap(.option), for: .voice, in: .defaults).isEmpty)
}

@Test func talkKeysSaveAndLoadAndShareTheDictationChord() throws {
    let folder = HomeTemporaryFolder("talkkeys")
    let url = folder.path("talk-keys.json")
    let dictationURL = folder.path("dictation.json")
    #expect(TalkKeySettings.load(from: url, dictationURL: dictationURL) == .defaults)

    var settings = TalkKeySettings.defaults
    settings.voice = .hold(.shift, .command)
    settings.dictation = .hold(.function, .option)
    try settings.save(to: url, dictationURL: dictationURL)
    #expect(TalkKeySettings.load(from: url, dictationURL: dictationURL) == settings)
    #expect(Set(DictationSettings.load(from: dictationURL).holdChord) == [.function, .option])

    let stored = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
    #expect(stored["voice"]?["modifiers"] == ["shift", "command"])
    #expect(stored["text"]?["kind"]?.stringValue == "doubleTap")

    // Dictation's own file wins for its chord (the dictation settings may have been edited there).
    var dictation = DictationSettings.load(from: dictationURL)
    dictation.holdChord = [.control, .shift]
    try dictation.save(to: dictationURL)
    #expect(TalkKeySettings.load(from: url, dictationURL: dictationURL).dictation == .hold(.control, .shift))

    // A hand-edited file with an impossible key falls back to the default for that key only.
    try #"{"voice":{"kind":"hold","modifiers":["shift"]},"text":{"kind":"doubleTap","modifiers":["option"]}}"#
        .write(to: url, atomically: true, encoding: .utf8)
    let loaded = TalkKeySettings.load(from: url, dictationURL: nil)
    #expect(loaded.voice == TalkKeySettings.defaults.voice)
    #expect(loaded.text == .doubleTap(.option))
}

@Test func talkKeyLabelsReadLikeMenus() {
    #expect(TalkKeyTrigger.hold(.option, .control).symbol == "⌃⌥")
    #expect(TalkKeyTrigger.hold(.control, .function).symbol == "fn ⌃")
    #expect(TalkKeyTrigger.hold(.control, .function).phrase == "Hold Fn and Control")
    #expect(TalkKeyTrigger.doubleTap(.control).phrase == "Double-tap Control")
}
