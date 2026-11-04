import Foundation

/// A spoken line split into words, with when each word is heard: for captions that appear word by word in step with
/// the audio actually played (`SpeechPlayer.position()` gives the seconds of the line played so far).
///
/// Without word timings from the voice, a word's share of the line is its length in letters plus a pause after
/// punctuation (a comma a little, the end of a sentence more), which follows natural speech closely enough that the
/// caption never runs ahead of the voice by more than a word.
public struct CaptionWords: Sendable, Hashable {
    public let words: [String]
    /// Fraction of the line (0…1) by the end of each word.
    public let ends: [Double]

    public init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var weights: [Double] = []
        for word in words {
            let letters = Double(word.filter { $0.isLetter || $0.isNumber }.count)
            var weight = max(1.5, letters + 1)
            if let last = word.last {
                if ",;:".contains(last) { weight += 2 } else if ".!?…".contains(last) { weight += 3.5 }
            }
            weights.append(weight)
        }
        let total = max(1, weights.reduce(0, +))
        var run = 0.0
        ends = weights.map { run += $0; return run / total }
    }

    /// How many words have been heard `elapsed` seconds into the line. `duration` is the line's audio length when
    /// known; otherwise it is estimated at `wordsPerSecond`. A word shows once its first part has been heard.
    public func revealed(elapsed: TimeInterval, duration: TimeInterval?, wordsPerSecond: Double = 2.6) -> Int {
        guard !words.isEmpty else { return 0 }
        let length = duration.flatMap { $0 > 0 ? $0 : nil } ?? Double(words.count) / max(0.5, wordsPerSecond)
        // A little lead-in silence at the start of each line.
        let progress = max(0, elapsed - 0.05) / max(0.1, length - 0.05)
        guard progress > 0 else { return 0 }
        var count = 0
        for (index, end) in ends.enumerated() {
            let start = index == 0 ? 0 : ends[index - 1]
            if progress >= start + (end - start) * 0.25 { count = index + 1 }
        }
        return min(words.count, max(1, count))
    }

    /// The words heard so far and the words still to come, as two strings (the second starts with a space).
    public func split(revealed count: Int) -> (heard: String, coming: String) {
        let n = max(0, min(words.count, count))
        let heard = words.prefix(n).joined(separator: " ")
        let rest = words.dropFirst(n).joined(separator: " ")
        return (heard, rest.isEmpty ? "" : (heard.isEmpty ? rest : " " + rest))
    }
}
