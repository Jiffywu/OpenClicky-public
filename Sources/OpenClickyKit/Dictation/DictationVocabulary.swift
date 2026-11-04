import Foundation

/// A fix the user made after dictation typed something: `original` was heard, `corrected` was meant.
public struct LearnedCorrection: Codable, Sendable, Hashable {
    public var original: String
    public var corrected: String
    /// How many times this fix was seen.
    public var count: Int
    public var lastLearnedAt: Date

    public init(original: String, corrected: String, count: Int = 1, lastLearnedAt: Date = Date()) {
        self.original = original
        self.corrected = corrected
        self.count = count
        self.lastLearnedAt = lastLearnedAt
    }
}

/// The user's dictation dictionary: words they added, plus corrections learned from edits after dictation.
/// Words become keyterms for the speech-to-text session and spelling hints for cleanup.
public struct DictationVocabulary: Codable, Sendable, Equatable {
    public var words: [String]
    public var corrections: [LearnedCorrection]

    public static let maxWords = 50
    public static let maxCorrections = 200
    public static let maxKeyterms = 100
    public static let maxTermLength = 60

    public init(words: [String] = [], corrections: [LearnedCorrection] = []) {
        self.words = words
        self.corrections = corrections
    }

    /// Adds a word. Returns false for blanks, duplicates (any case) and when the dictionary is full.
    @discardableResult
    public mutating func add(_ word: String) -> Bool {
        guard let clean = Self.clean(word), !words.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }),
              words.count < Self.maxWords else { return false }
        words.append(clean)
        return true
    }

    @discardableResult
    public mutating func remove(_ word: String) -> Bool {
        let before = words.count + corrections.count
        words.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        corrections.removeAll {
            $0.corrected.caseInsensitiveCompare(word) == .orderedSame || $0.original.caseInsensitiveCompare(word) == .orderedSame
        }
        return words.count + corrections.count != before
    }

    /// Records a learned correction, bumping its count if it was seen before.
    public mutating func learn(_ correction: LearnedCorrection) {
        guard let original = Self.clean(correction.original), let corrected = Self.clean(correction.corrected),
              original != corrected else { return }
        if let index = corrections.firstIndex(where: {
            $0.original.caseInsensitiveCompare(original) == .orderedSame && $0.corrected == corrected
        }) {
            corrections[index].count += correction.count
            corrections[index].lastLearnedAt = max(corrections[index].lastLearnedAt, correction.lastLearnedAt)
        } else {
            corrections.removeAll { $0.original.caseInsensitiveCompare(original) == .orderedSame }
            corrections.append(LearnedCorrection(original: original, corrected: corrected, count: correction.count,
                                                 lastLearnedAt: correction.lastLearnedAt))
        }
        if corrections.count > Self.maxCorrections {
            corrections.sort { ($0.count, $0.lastLearnedAt) > ($1.count, $1.lastLearnedAt) }
            corrections.removeLast(corrections.count - Self.maxCorrections)
        }
    }

    /// Keyterms for a speech-to-text session: the user's own words first, then seeds (the product name, the user's
    /// name), then learned terms by how often they were corrected. Case-insensitive duplicates keep the first spelling.
    public func keyterms(seeds: [String] = [], limit: Int = DictationVocabulary.maxKeyterms) -> [String] {
        let learned = corrections.sorted { ($0.count, $0.lastLearnedAt) > ($1.count, $1.lastLearnedAt) }.map(\.corrected)
        var seen = Set<String>()
        var result: [String] = []
        for term in words + seeds + learned {
            guard let clean = Self.clean(term) else { continue }
            let key = clean.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(clean)
            if result.count == limit { break }
        }
        return result
    }

    /// Corrections confident enough to rewrite a transcript before cleanup: merges of several heard words into one
    /// term, or a fix the user made at least twice. The rest only bias recognition as keyterms.
    public var replacementRules: [LearnedCorrection] {
        corrections.filter { $0.original.contains(" ") || $0.count >= 2 }
    }

    /// Replaces whole-word occurrences of confident learned originals (any case) with their corrections.
    public func applyCorrections(to text: String) -> String {
        var result = text
        for correction in replacementRules.sorted(by: { $0.original.count > $1.original.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: correction.original) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: correction.corrected))
        }
        return result
    }

    static func clean(_ term: String) -> String? {
        let collapsed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maxTermLength else { return nil }
        return collapsed
    }
}

/// Keeps the vocabulary in `~/Library/Application Support/OpenClicky/dictation-vocabulary.json`.
public actor DictationVocabularyStore {
    public let url: URL
    private var cached: DictationVocabulary?

    public init(url: URL = DictationVocabularyStore.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
            .appendingPathComponent("dictation-vocabulary.json")
    }

    public func load() -> DictationVocabulary {
        if let cached { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(DictationVocabulary.self, from: $0) } ?? DictationVocabulary()
        cached = loaded
        return loaded
    }

    public func save(_ vocabulary: DictationVocabulary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(vocabulary).write(to: url, options: .atomic)
        cached = vocabulary
    }

    /// Loads, changes and saves in one step.
    @discardableResult
    public func update<T: Sendable>(_ change: @Sendable (inout DictationVocabulary) -> T) throws -> T {
        var vocabulary = load()
        let result = change(&vocabulary)
        try save(vocabulary)
        return result
    }
}

/// Finds corrections by comparing what dictation typed with what the field says a little later.
public enum CorrectionLearner {
    /// The stretch of `now` that replaced the inserted text, located by the text that was around the caret.
    /// Returns nil when the surroundings changed too much to tell.
    public static func editedRegion(now: String, beforeText: String, afterText: String, insertedLength: Int) -> String? {
        let anchorLength = 24
        let beforeAnchor = String(beforeText.suffix(anchorLength))
        let afterAnchor = String(afterText.prefix(anchorLength))
        var start = now.startIndex
        if !beforeAnchor.isEmpty {
            guard let found = now.range(of: beforeAnchor) else { return nil }
            start = found.upperBound
        }
        var end = now.endIndex
        if !afterAnchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let found = now.range(of: afterAnchor, range: start..<now.endIndex) else { return nil }
            end = found.lowerBound
        }
        let region = String(now[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard region.count <= insertedLength * 3 + 40 else { return nil }
        return region
    }

    /// Word substitutions between the inserted text and the edited text that look like vocabulary fixes: a term with
    /// capitals or digits (a name, a product), or several heard words merged into one. Ordinary rewording is ignored.
    public static func corrections(inserted: String, edited: String, now: Date = Date()) -> [LearnedCorrection] {
        let a = tokens(inserted)
        let b = tokens(edited)
        guard !a.isEmpty, !b.isEmpty, a != b else { return [] }
        guard let script = alignment(a.map { $0.lowercased() }, b.map { $0.lowercased() }) else { return [] }
        var results: [LearnedCorrection] = []
        var changedTokens = 0
        var i = 0, j = 0
        var pendingA: [String] = [], pendingB: [String] = []
        func flush() {
            defer { pendingA.removeAll(); pendingB.removeAll() }
            guard !pendingA.isEmpty || !pendingB.isEmpty else { return }
            changedTokens += max(pendingA.count, pendingB.count)
            guard pendingB.count == 1, (1...3).contains(pendingA.count) else { return }
            let original = pendingA.joined(separator: " ")
            let corrected = pendingB[0]
            if looksLikeVocabulary(original: original, corrected: corrected, merged: pendingA.count > 1) {
                results.append(LearnedCorrection(original: original, corrected: corrected, lastLearnedAt: now))
            }
        }
        for step in script {
            switch step {
            case .keep:
                flush()
                // Same letters, different capitals ("openclicky" → "OpenClicky") still counts as a fix.
                if a[i] != b[j], looksLikeVocabulary(original: a[i], corrected: b[j], merged: false) {
                    results.append(LearnedCorrection(original: a[i], corrected: b[j], lastLearnedAt: now))
                    changedTokens += 1
                }
                i += 1; j += 1
            case .delete: pendingA.append(a[i]); i += 1
            case .insert: pendingB.append(b[j]); j += 1
            }
        }
        flush()
        // A rewrite of most of the text is an edit, not a correction.
        guard Double(changedTokens) <= Double(max(a.count, b.count)) * 0.5 else { return [] }
        return Array(results.prefix(3))
    }

    static func looksLikeVocabulary(original: String, corrected: String, merged: Bool) -> Bool {
        guard corrected.contains(where: \.isLetter), corrected.count >= 2, original != corrected,
              !commonWords.contains(corrected.lowercased()) else { return false }
        if merged { return true }
        guard !commonWords.contains(original.lowercased()) else { return false }
        let internalCapital = corrected.dropFirst().contains(where: { $0.isUppercase })
        if original.lowercased() == corrected.lowercased() {
            // Only internal capitals ("Github" → "GitHub"), not sentence case ("the" → "The").
            return internalCapital
        }
        if internalCapital || corrected.contains(where: \.isNumber) { return true }
        // A lowercase word respelled as a similar capitalized name ("clicky" → "Klicky").
        return corrected.first?.isUppercase == true && original.first?.isUppercase == false
            && similarity(original.lowercased(), corrected.lowercased()) >= 0.5
    }

    /// 1 for identical strings, 0 for nothing in common (normalized edit distance).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Words too common to ever be treated as a misheard term.
    static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in", "on", "at", "by", "for", "with", "from",
        "as", "is", "are", "was", "were", "be", "been", "it", "its", "it's", "this", "that", "these", "those", "there",
        "their", "they're", "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "our",
        "his", "not", "no", "yes", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "should",
        "what", "which", "who", "when", "where", "why", "how", "all", "any", "some", "just", "also", "very", "too", "up",
        "out", "about", "into", "over", "than", "here", "now", "one", "two", "new", "get", "got", "like", "know", "okay",
    ]

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_.@#+")))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        }.filter { !$0.isEmpty }
    }

    enum Step { case keep, delete, insert }

    /// The largest middle section (tokens before × tokens after) worth aligning; anything bigger is a rewrite.
    static let maxAlignmentCells = 250_000

    /// Edit script: the shared opening and closing runs are kept as they are, and only the part in between goes
    /// through a longest-common-subsequence table, so a long dictation with one fix costs little. Nil when the
    /// changed middle is too large to be a correction.
    static func alignment(_ a: [String], _ b: [String]) -> [Step]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let middleA = Array(a[prefix..<(a.count - suffix)]), middleB = Array(b[prefix..<(b.count - suffix)])
        guard middleA.count * middleB.count <= maxAlignmentCells else { return nil }
        return Array(repeating: .keep, count: prefix) + lcsAlignment(middleA, middleB) + Array(repeating: .keep, count: suffix)
    }

    /// Edit script from a longest-common-subsequence table.
    static func lcsAlignment(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { steps.append(.keep); i += 1; j += 1 }
            else if j < m, i == n || table[i][j + 1] > table[i + 1][j] { steps.append(.insert); j += 1 }
            else { steps.append(.delete); i += 1 }
        }
        return steps
    }
}
