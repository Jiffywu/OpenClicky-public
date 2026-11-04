import Foundation
import Testing
@testable import OpenClickyKit

// The talk-key gestures the app's event tap recognizes, fed with timestamps instead of a keyboard.

private func machine(_ keys: TalkKeySettings = .defaults) -> TalkKeyGestureMachine { TalkKeyGestureMachine(keys: keys) }

@Test func holdingTheVoiceChordPressesAndLettingGoReleases() {
    var keys = machine()
    #expect(keys.modifiersChanged([.control], at: 0).isEmpty)
    #expect(keys.modifiersChanged([.control, .option], at: 0.25) == [.voicePressed])
    #expect(keys.isVoiceHeld)
    // Keys are let go one at a time; the first release ends the hold, and the trailing ⌃ alone is no tap.
    #expect(keys.modifiersChanged([.control], at: 2.25) == [.voiceReleased(held: 2.0)])
    #expect(keys.modifiersChanged([], at: 2.3).isEmpty)
    #expect(keys.tick(at: 5).isEmpty)
}

@Test func aBrushOfTheVoiceChordOrAShortcutCancels() {
    var keys = machine()
    _ = keys.modifiersChanged([.control, .option], at: 0)
    #expect(keys.modifiersChanged([.option], at: 0.1) == [.voiceCancelled])

    // ⌃⌥→ to move a window: the arrow arrives within the minimum hold.
    _ = keys.modifiersChanged([.control, .option], at: 1)
    #expect(keys.keyDown(isEscape: false, at: 1.05) == [.voiceCancelled, .dictation(.otherKey(at: 1.05))])
    #expect(keys.modifiersChanged([], at: 1.2).isEmpty)

    // A key pressed well into a hold doesn't cancel it.
    _ = keys.modifiersChanged([.control, .option], at: 3)
    #expect(keys.keyDown(isEscape: false, at: 3.5) == [.dictation(.otherKey(at: 3.5))])
    #expect(keys.modifiersChanged([], at: 4) == [.voiceReleased(held: 1)])

    // Adding a third modifier changes the chord: that's a release.
    _ = keys.modifiersChanged([.control, .option], at: 6)
    #expect(keys.modifiersChanged([.control, .option, .command], at: 6.5) == [.voiceReleased(held: 0.5)])
}

@Test func doubleTapControlOpensTheTextPanelAfterTheTripleTapWindow() {
    var keys = machine()
    _ = keys.modifiersChanged([.control], at: 0)
    #expect(keys.modifiersChanged([], at: 0.08).isEmpty)
    _ = keys.modifiersChanged([.control], at: 0.2)
    #expect(keys.modifiersChanged([], at: 0.28).isEmpty)
    let deadline = keys.pendingDeadline
    #expect(deadline != nil)
    #expect(keys.tick(at: 0.4).isEmpty)
    #expect(keys.tick(at: deadline ?? 0) == [.textTrigger])
    #expect(keys.pendingDeadline == nil)
}

@Test func tripleTapControlIsReservedForAlwaysOn() {
    var keys = machine()
    for (index, start) in [0.0, 0.2, 0.4].enumerated() {
        _ = keys.modifiersChanged([.control], at: start)
        let out = keys.modifiersChanged([], at: start + 0.07)
        #expect(out == (index == 2 ? [.alwaysOnToggle] : []))
    }
    #expect(keys.pendingDeadline == nil)
    #expect(keys.tick(at: 2).isEmpty)
}

@Test func tapsThatOverlapTypingOrAreTooSlowDontCount() {
    var keys = machine()
    // Slow presses.
    _ = keys.modifiersChanged([.control], at: 0)
    _ = keys.modifiersChanged([], at: 0.6)
    _ = keys.modifiersChanged([.control], at: 0.7)
    _ = keys.modifiersChanged([], at: 0.75)
    #expect(keys.pendingDeadline == nil)
    // ⌃C between taps.
    _ = keys.modifiersChanged([.control], at: 2)
    _ = keys.keyDown(isEscape: false, at: 2.05)
    _ = keys.modifiersChanged([], at: 2.1)
    _ = keys.modifiersChanged([.control], at: 2.2)
    _ = keys.modifiersChanged([], at: 2.25)
    #expect(keys.pendingDeadline == nil)
    // Taps too far apart.
    _ = keys.modifiersChanged([.control], at: 4)
    _ = keys.modifiersChanged([], at: 4.05)
    _ = keys.modifiersChanged([.control], at: 5)
    _ = keys.modifiersChanged([], at: 5.05)
    #expect(keys.pendingDeadline == nil)
    // A click between taps.
    _ = keys.modifiersChanged([.control], at: 7)
    _ = keys.modifiersChanged([], at: 7.05)
    _ = keys.otherActivity(at: 7.1)
    _ = keys.modifiersChanged([.control], at: 7.2)
    _ = keys.modifiersChanged([], at: 7.25)
    #expect(keys.pendingDeadline == nil)
}

@Test func aDoubleTapFollowedByOtherInputFiresAtOnce() {
    var keys = machine()
    _ = keys.modifiersChanged([.control], at: 0)
    _ = keys.modifiersChanged([], at: 0.05)
    _ = keys.modifiersChanged([.control], at: 0.15)
    _ = keys.modifiersChanged([], at: 0.2)
    #expect(keys.keyDown(isEscape: false, at: 0.3).first == .textTrigger)
}

@Test func theDictationChordIsPassedToDictation() {
    var keys = machine()
    #expect(keys.modifiersChanged([.function], at: 0).isEmpty)
    #expect(keys.modifiersChanged([.function, .control], at: 0.02) == [.dictation(.chordDown(at: 0.02))])
    #expect(keys.isDictationHeld)
    #expect(keys.keyDown(isEscape: false, at: 0.5) == [.dictation(.otherKey(at: 0.5))])
    #expect(keys.modifiersChanged([.function], at: 1.5) == [.dictation(.chordUp(at: 1.5))])
    #expect(!keys.isVoiceHeld)
}

@Test func escapeIsReportedAndCustomKeysAreHonoured() {
    var keys = machine(TalkKeySettings(voice: .hold(.command, .shift), text: .doubleTap(.option), dictation: .hold(.control, .function)))
    #expect(keys.keyDown(isEscape: true, at: 0) == [.escape])
    #expect(keys.modifiersChanged([.control, .option], at: 1).isEmpty)
    _ = keys.modifiersChanged([], at: 1.1)
    #expect(keys.modifiersChanged([.shift, .command], at: 2) == [.voicePressed])
    _ = keys.modifiersChanged([], at: 3)
    _ = keys.modifiersChanged([.option], at: 4)
    _ = keys.modifiersChanged([], at: 4.05)
    _ = keys.modifiersChanged([.option], at: 4.15)
    _ = keys.modifiersChanged([], at: 4.2)
    #expect(keys.tick(at: 10) == [.textTrigger])
}

@Test func voiceLoopSettingsKeepDefaultsForMissingKeys() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-loop-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("voice-loop.json")
    #expect(VoiceLoopSettings.load(from: url) == VoiceLoopSettings())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"speaksTypedAnswers": true}"#.utf8).write(to: url)
    let loaded = VoiceLoopSettings.load(from: url)
    #expect(loaded.speaksTypedAnswers)
    #expect(loaded.showsCaptions && loaded.playsCues && !loaded.showsTimings)
    var changed = loaded
    changed.playsCues = false
    try changed.save(to: url)
    #expect(VoiceLoopSettings.load(from: url) == changed)
}
