import Foundation
import Testing
@testable import OpenClickyKit

// Per-slot trigger kinds: every talk-key slot works as a held chord or as a double tap of one modifier, the recorder
// records either kind, and saved keys migrate.

private func tap(_ machine: inout TalkKeyGestureMachine, _ key: DictationModifier, at start: TimeInterval) -> [TalkKeyGestureMachine.Output] {
    machine.modifiersChanged([key], at: start) + machine.modifiersChanged([], at: start + 0.06)
}

private func doubleTap(_ machine: inout TalkKeyGestureMachine, _ key: DictationModifier, at start: TimeInterval) -> [TalkKeyGestureMachine.Output] {
    tap(&machine, key, at: start) + tap(&machine, key, at: start + 0.15)
}

@Suite struct TalkKeyKindTests {
    // MARK: Voice

    @Test func voiceAsAHeldChord() {
        var keys = TalkKeyGestureMachine(keys: .defaults)
        #expect(keys.modifiersChanged([.control, .option], at: 0) == [.voicePressed])
        #expect(keys.modifiersChanged([], at: 1) == [.voiceReleased(held: 1)])
    }

    @Test func voiceAsADoubleTapStartsAndAnotherTapEnds() {
        var settings = TalkKeySettings.defaults
        settings.voice = .doubleTap(.option)
        #expect(settings.problems.isEmpty)
        var keys = TalkKeyGestureMachine(keys: settings)
        #expect(tap(&keys, .option, at: 0).isEmpty)
        #expect(tap(&keys, .option, at: 0.15) == [.voicePressed])
        #expect(keys.isVoiceHeld)
        // Talking for a while with the key up; the next clean tap ends the question.
        let ended = tap(&keys, .option, at: 3.0)
        guard case .voiceReleased(let held)? = ended.first, ended.count == 1 else { Issue.record("expected a release, got \(ended)"); return }
        #expect(abs(held - 2.85) < 0.001)
        #expect(!keys.isVoiceHeld)
        // Holding ⌃⌥ (the old voice chord) does nothing now.
        #expect(keys.modifiersChanged([.control, .option], at: 5).isEmpty)
        _ = keys.modifiersChanged([], at: 6)
        // Escape drops a tapped-on question; the next double tap starts a new one.
        _ = doubleTap(&keys, .option, at: 8)
        #expect(keys.keyDown(isEscape: true, at: 9).contains(.escape))
        #expect(!keys.isVoiceHeld)
        #expect(doubleTap(&keys, .option, at: 10) == [.voicePressed])
    }

    @Test func aDoubleTappedQuestionTheAppIgnoredOrEndedDoesNotSwallowTheNextDoubleTap() {
        var settings = TalkKeySettings.defaults
        settings.voice = .doubleTap(.option)
        var keys = TalkKeyGestureMachine(keys: settings)
        // Always-on (or dictation, or held turns) has the mic: the app drops this press, and says so.
        #expect(doubleTap(&keys, .option, at: 0) == [.voicePressed])
        keys.voicePressEnded()
        #expect(!keys.isVoiceHeld)
        // The next double tap starts a question at once, rather than its first tap ending one that isn't there.
        #expect(doubleTap(&keys, .option, at: 2) == [.voicePressed])
        #expect(keys.isVoiceHeld)
        // The same after a question that was stopped another way (a typed question cut it off).
        keys.voicePressEnded()
        #expect(doubleTap(&keys, .option, at: 4) == [.voicePressed])

        // A held chord resyncs on its own release: the call doesn't touch it.
        var held = TalkKeyGestureMachine(keys: .defaults)
        #expect(held.modifiersChanged([.control, .option], at: 0) == [.voicePressed])
        held.voicePressEnded()
        #expect(held.isVoiceHeld)
        #expect(held.modifiersChanged([], at: 1) == [.voiceReleased(held: 1)])
    }

    // MARK: Text

    @Test func textAsADoubleTapAndAsAHeldChord() {
        var keys = TalkKeyGestureMachine(keys: .defaults)
        _ = doubleTap(&keys, .control, at: 0)
        #expect(keys.tick(at: 1) == [.textTrigger])

        var settings = TalkKeySettings.defaults
        settings.text = .hold(.shift, .command)
        #expect(settings.problems.isEmpty)
        keys = TalkKeyGestureMachine(keys: settings)
        #expect(keys.modifiersChanged([.command], at: 0).isEmpty)
        #expect(keys.modifiersChanged([.command, .shift], at: 0.05).isEmpty, "fires when let go, so held keys don't reach the panel")
        #expect(keys.modifiersChanged([.shift], at: 0.3) == [.textTrigger])
        #expect(keys.modifiersChanged([], at: 0.35).isEmpty)
        // ⇧⌘4 (a screenshot) isn't a press of the chord.
        _ = keys.modifiersChanged([.command, .shift], at: 2)
        _ = keys.keyDown(isEscape: false, at: 2.1)
        #expect(keys.modifiersChanged([], at: 2.3).isEmpty)
        // A double tap of Control means nothing now, and there is no triple tap.
        #expect(doubleTap(&keys, .control, at: 4).isEmpty)
        #expect(keys.pendingDeadline == nil)
    }

    // MARK: Dictation

    @Test func dictationAsAHeldChordAndAsADoubleTap() {
        var keys = TalkKeyGestureMachine(keys: .defaults)
        #expect(keys.modifiersChanged([.control, .function], at: 0) == [.dictation(.chordDown(at: 0))])
        #expect(keys.modifiersChanged([], at: 1) == [.dictation(.chordUp(at: 1))])

        var settings = TalkKeySettings.defaults
        settings.dictation = .doubleTap(.command)
        #expect(settings.problems.values.flatMap { $0 }.allSatisfy { $0.severity == .warning })
        keys = TalkKeyGestureMachine(keys: settings)
        #expect(doubleTap(&keys, .command, at: 0) == [.dictation(.handsFreeToggle)])
        #expect(doubleTap(&keys, .command, at: 2) == [.dictation(.handsFreeToggle)])
        #expect(keys.modifiersChanged([.control, .function], at: 4).isEmpty, "the old chord is free")
        #expect(!keys.isDictationHeld)
    }

    // MARK: Hands-free

    @Test func handsFreeAsADoubleTapAndAsAHeldChord() {
        var settings = TalkKeySettings.defaults
        settings.handsFreeDictation = .doubleTap(.option)
        var keys = TalkKeyGestureMachine(keys: settings)
        #expect(doubleTap(&keys, .option, at: 0) == [.dictation(.handsFreeToggle)])

        settings.handsFreeDictation = .hold(.shift, .option)
        #expect(settings.problems.isEmpty)
        keys = TalkKeyGestureMachine(keys: settings)
        _ = keys.modifiersChanged([.shift, .option], at: 0)
        #expect(keys.modifiersChanged([], at: 0.2) == [.dictation(.handsFreeToggle)])
        // Adding a key to the chord isn't a press of it.
        _ = keys.modifiersChanged([.shift, .option], at: 1)
        #expect(keys.modifiersChanged([.shift, .option, .command], at: 1.1).isEmpty)
        #expect(keys.modifiersChanged([], at: 1.2).isEmpty)
    }

    // MARK: Recorder and rules

    @Test func theRecorderRecordsEitherKindForAnySlot() {
        var voiceTap = TalkKeyRecorder(action: .voice, settings: .defaults, kind: .doubleTap)
        voiceTap.start()
        #expect(voiceTap.prompt.contains("double-tap"))
        voiceTap.modifiersChanged([.option])
        voiceTap.modifiersChanged([])
        #expect(voiceTap.state == .captured(.doubleTap(.option), warnings: []))
        #expect(voiceTap.applied()?.voice == .doubleTap(.option))

        var textHold = TalkKeyRecorder(action: .text, settings: .defaults, kind: .hold)
        textHold.start()
        textHold.modifiersChanged([.shift, .command])
        textHold.modifiersChanged([])
        #expect(textHold.applied()?.text == .hold(.shift, .command))

        // A held chord inside the voice chord still clashes, whatever the slot.
        var clash = TalkKeyRecorder(action: .text, settings: .defaults, kind: .hold)
        clash.start()
        clash.modifiersChanged([.control, .option, .shift])
        clash.modifiersChanged([])
        guard case .rejected(_, let reason) = clash.state else { Issue.record("expected the overlap to be refused"); return }
        #expect(reason.contains("overlaps"))

        // With no kind given the recorder uses the slot's current kind.
        var settings = TalkKeySettings.defaults
        settings.voice = .doubleTap(.option)
        #expect(TalkKeyRecorder(action: .voice, settings: settings).kind == .doubleTap)
        #expect(TalkKeyRecorder(action: .text, settings: .defaults).kind == .doubleTap)
    }

    // MARK: Migration

    @Test func savedKeysMigrate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("talkkeys-kind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("talk-keys.json")
        let dictationURL = folder.appendingPathComponent("dictation.json")

        // A file from before per-slot kinds (each key in its slot's fixed kind) loads unchanged.
        try #"{"voice":{"kind":"hold","modifiers":["shift","command"]},"text":{"kind":"doubleTap","modifiers":["option"]},"dictation":{"kind":"hold","modifiers":["control","function"]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let old = TalkKeySettings.load(from: url, dictationURL: nil)
        #expect(old.voice == .hold(.shift, .command) && old.text == .doubleTap(.option) && old.dictation == .hold(.control, .function))

        // Keys without a kind take the slot's default; HeyClicky's kind names are read.
        try #"{"voice":{"modifiers":["control","option"]},"text":{"modifiers":["command"]},"handsFreeDictation":{"kind":"doubleTapModifier","modifiers":["option"]},"dictation":{"kind":"holdCombo","modifiers":["control","shift"]}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let mixed = TalkKeySettings.load(from: url, dictationURL: nil)
        #expect(mixed.voice == .hold(.control, .option))
        #expect(mixed.text == .doubleTap(.command))
        #expect(mixed.handsFreeDictation == .doubleTap(.option))
        #expect(mixed.dictation == .hold(.control, .shift))

        // A slot in the other kind round-trips, and a double-tap dictation key isn't overridden by dictation.json's
        // held chord (which it leaves alone).
        var settings = TalkKeySettings.defaults
        settings.voice = .doubleTap(.option)
        settings.text = .hold(.shift, .command)
        settings.dictation = .doubleTap(.function)
        try settings.save(to: url, dictationURL: dictationURL)
        #expect(Set(DictationSettings.load(from: dictationURL).holdChord) == [.control, .function])
        #expect(TalkKeySettings.load(from: url, dictationURL: dictationURL) == settings)
        let stored = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        #expect(stored["voice"]?["kind"]?.stringValue == "doubleTap")
        #expect(stored["text"]?["kind"]?.stringValue == "hold")
    }
}
