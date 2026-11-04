import Foundation
import Testing
@testable import OpenClickyKit

// Word-by-word captions (CaptionWords) and the caption and drawing settings of the voice loop.

@Test func captionWordsAppearInStepWithTheLine() {
    let words = CaptionWords("The Say hello button reads your name, then writes a greeting.")
    #expect(words.words.count == 11)
    #expect(words.revealed(elapsed: 0, duration: 4) == 0)
    #expect(words.revealed(elapsed: 0.2, duration: 4) == 1)
    var last = 0
    for step in 1...40 {
        let shown = words.revealed(elapsed: Double(step) * 0.1, duration: 4)
        #expect(shown >= last, "words never disappear")
        last = shown
    }
    #expect(words.revealed(elapsed: 4, duration: 4) == 11)
    // Half way through the audio, about half the words.
    let half = words.revealed(elapsed: 2, duration: 4)
    #expect((4...7).contains(half), "\(half)")
}

@Test func punctuationTakesItsPauseAndUnknownLengthsAreEstimated() {
    let paused = CaptionWords("Wait, then go.")
    let plain = CaptionWords("Wait then go.")
    // The comma makes "Wait," take longer: "then" shows later than without it.
    #expect(paused.ends[0] > plain.ends[0])
    // No duration yet (the audio is still arriving): 2.6 words a second.
    let estimate = CaptionWords("one two three four five six")
    #expect(estimate.revealed(elapsed: 1.2, duration: nil) == 3 || estimate.revealed(elapsed: 1.2, duration: nil) == 4)
    let parts = estimate.split(revealed: 2)
    #expect(parts.heard == "one two" && parts.coming == " three four five six")
    #expect(estimate.split(revealed: 0).coming == "one two three four five six")
    #expect(CaptionWords("").revealed(elapsed: 3, duration: 2) == 0)
}

@Test func captionAndDrawingSettingsHaveDefaultsAndLimits() throws {
    let old = try JSONDecoder().decode(VoiceLoopSettings.self, from: Data(#"{"showsCaptions": false}"#.utf8))
    #expect(!old.showsCaptions && old.captionsWordByWord && old.captionSize == 17 && !old.showsBeatChips && old.playsDrawingSounds)
    let big = try JSONDecoder().decode(VoiceLoopSettings.self, from: Data(#"{"captionSize": 90, "showsBeatChips": true}"#.utf8))
    #expect(big.captionSize == 28 && big.showsBeatChips)
    let encoded = try JSONEncoder().encode(VoiceLoopSettings(captionsWordByWord: false, captionSize: 22, playsDrawingSounds: false))
    let back = try JSONDecoder().decode(VoiceLoopSettings.self, from: encoded)
    #expect(!back.captionsWordByWord && back.captionSize == 22 && !back.playsDrawingSounds)
}
