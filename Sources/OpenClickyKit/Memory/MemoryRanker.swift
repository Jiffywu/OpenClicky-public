import Foundation

/// Finds the memories that matter for a query, by keywords and recency. No embeddings: memory is small, and this
/// runs on every turn.
///
/// Keyword score: the share of the query's terms (weighted by how rare each term is among the entries) that an entry
/// contains, with a half match when one word is a prefix of the other ("photo" / "photography"). Query terms that no
/// entry contains are ignored. Recency halves
/// every `halfLifeDays`. An entry must match at least one term to be returned; an empty query returns the newest.
public struct MemoryRanker: Sendable {
    public struct Match: Sendable, Hashable {
        public var entry: MemoryEntry
        public var score: Double
        /// 0…1: how much of the query the entry covers.
        public var keyword: Double
        /// 0…1: how recent it is.
        public var recency: Double
    }

    public var halfLifeDays: Double
    /// How much recency counts against keywords, 0…1.
    public var recencyWeight: Double
    /// The recency an undated entry (profile line, standing context, how-to) gets.
    public var undatedRecency: Double

    public init(halfLifeDays: Double = 45, recencyWeight: Double = 0.25, undatedRecency: Double = 0.3) {
        self.halfLifeDays = halfLifeDays
        self.recencyWeight = recencyWeight
        self.undatedRecency = undatedRecency
    }

    public func rank(_ entries: [MemoryEntry], query: String, now: Date, limit: Int? = nil) -> [Match] {
        let queryTerms = Array(Set(Self.terms(query)))
        let documents = entries.map { Set(Self.terms($0.text)) }
        var matches: [Match] = []

        if queryTerms.isEmpty {
            for entry in entries {
                let recency = recency(of: entry, now: now)
                matches.append(Match(entry: entry, score: recency, keyword: 0, recency: recency))
            }
        } else {
            // Rarer terms count for more: log(1 + N / (1 + document frequency)). A term no entry contains says
            // nothing about which entry is meant ("forget the penicillin allergy" vs "Allergic to penicillin"), so it
            // is left out instead of lowering every score.
            let count = Double(entries.count)
            var weights: [String: Double] = [:]
            for term in queryTerms {
                let frequency = documents.reduce(0) { $0 + (Self.matchStrength(term, in: $1) > 0 ? 1 : 0) }
                if frequency > 0 { weights[term] = log(1 + count / (1 + Double(frequency))) }
            }
            let total = weights.values.reduce(0, +)
            let phrase = MemoryText.normalized(query)
            for (entry, document) in zip(entries, documents) {
                var covered = 0.0
                for term in queryTerms { covered += (weights[term] ?? 0) * Self.matchStrength(term, in: document) }
                guard covered > 0, total > 0 else { continue }
                var keyword = covered / total
                if phrase.count >= 6, MemoryText.normalized(entry.text).contains(phrase) { keyword = min(1, keyword + 0.1) }
                let recency = recency(of: entry, now: now)
                let score = keyword * (1 - recencyWeight) + recency * recencyWeight
                matches.append(Match(entry: entry, score: score, keyword: keyword, recency: recency))
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.entry.date ?? .distantPast) > (rhs.entry.date ?? .distantPast)
        }
        if let limit { return Array(matches.prefix(max(0, limit))) }
        return matches
    }

    func recency(of entry: MemoryEntry, now: Date) -> Double {
        guard let date = entry.date else { return undatedRecency }
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return pow(0.5, days / max(halfLifeDays, 0.001))
    }

    /// 1 for the term itself, 0.5 for a prefix match either way (both at least 3 characters), else 0.
    static func matchStrength(_ term: String, in document: Set<String>) -> Double {
        if document.contains(term) { return 1 }
        guard term.count >= 3 else { return 0 }
        for word in document where word.count >= 3 && (word.hasPrefix(term) || term.hasPrefix(word)) { return 0.5 }
        return 0
    }

    // MARK: - Terms

    /// Lowercased, accent-folded words without stop words, lightly stemmed ("running" → "runn", "flies" → "fly").
    public static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { word in
            guard !word.isEmpty, !stopWords.contains(word) else { return nil }
            guard word.count > 1 || word.allSatisfy(\.isNumber) else { return nil }
            return stem(word)
        }
    }

    static func stem(_ word: String) -> String {
        guard word.count > 3, !word.allSatisfy(\.isNumber) else { return word }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ing"), word.count > 5 { return String(word.dropLast(3)) }
        if word.hasSuffix("ed"), word.count > 4 { return String(word.dropLast(2)) }
        if word.hasSuffix("es"), word.count > 4, ["sses", "ches", "shes", "xes"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return String(word.dropLast()) }
        return word
    }

    static let stopWords: Set<String> = [
        "a", "about", "after", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be", "been", "but", "by",
        "can", "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her", "his", "how", "i", "if",
        "in", "into", "is", "it", "its", "just", "know", "me", "my", "of", "on", "or", "our", "remember", "she", "so",
        "that", "the", "their", "them", "then", "there", "they", "this", "to", "user", "user's", "users", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your", "s",
    ]
}
