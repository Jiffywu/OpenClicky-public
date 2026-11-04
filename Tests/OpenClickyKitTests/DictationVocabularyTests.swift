import Foundation
import Testing
@testable import OpenClickyKit

@Test func vocabularyMergesUserWordsSeedsAndLearnedTermsWithoutDuplicates() {
    let old = Date(timeIntervalSince1970: 1_000)
    let new = Date(timeIntervalSince1970: 2_000)
    var vocabulary = DictationVocabulary(words: ["Kubernetes", "  Jiffy   Wu "])
    vocabulary.learn(LearnedCorrection(original: "open clicky", corrected: "OpenClicky", lastLearnedAt: old))
    vocabulary.learn(LearnedCorrection(original: "tail scale", corrected: "Tailscale", count: 3, lastLearnedAt: old))
    vocabulary.learn(LearnedCorrection(original: "super base", corrected: "Supabase", lastLearnedAt: new))

    let terms = vocabulary.keyterms(seeds: ["OpenClicky", "kubernetes", "Jeffrey Nguyen", ""])
    // User words first (whitespace collapsed), then seeds, then learned by count and recency.
    #expect(terms == ["Kubernetes", "Jiffy Wu", "OpenClicky", "Jeffrey Nguyen", "Tailscale", "Supabase"])
    #expect(vocabulary.keyterms(seeds: ["OpenClicky"], limit: 2) == ["Kubernetes", "Jiffy Wu"])
}

@Test func vocabularyAddRemoveAndLimits() {
    var vocabulary = DictationVocabulary()
    let added = [vocabulary.add("Figma"), vocabulary.add("figma"), vocabulary.add("   "), vocabulary.add(String(repeating: "x", count: 61))]
    #expect(added == [true, false, false, false])
    for i in 0..<60 { vocabulary.add("word\(i)") }
    #expect(vocabulary.words.count == DictationVocabulary.maxWords)
    vocabulary.learn(LearnedCorrection(original: "fig ma", corrected: "Figma"))
    let removed = vocabulary.remove("FIGMA")
    #expect(removed)
    #expect(!vocabulary.words.contains("Figma"))
    #expect(vocabulary.corrections.isEmpty)
}

@Test func learningTheSameFixTwiceCountsItAndALaterFixReplacesIt() {
    var vocabulary = DictationVocabulary()
    vocabulary.learn(LearnedCorrection(original: "clicky", corrected: "Klicky"))
    vocabulary.learn(LearnedCorrection(original: "Clicky", corrected: "Klicky"))
    #expect(vocabulary.corrections.count == 1)
    #expect(vocabulary.corrections[0].count == 2)
    vocabulary.learn(LearnedCorrection(original: "clicky", corrected: "Clickie"))
    #expect(vocabulary.corrections.map(\.corrected) == ["Clickie"])
}

@Test func confidentCorrectionsRewriteTranscriptsAsWholeWords() {
    var vocabulary = DictationVocabulary()
    vocabulary.learn(LearnedCorrection(original: "open clicky", corrected: "OpenClicky"))
    vocabulary.learn(LearnedCorrection(original: "jiffy", corrected: "Jiffywu", count: 2))
    vocabulary.learn(LearnedCorrection(original: "post gres", corrected: "Postgres"))
    vocabulary.learn(LearnedCorrection(original: "kube", corrected: "Kube$1"))  // seen once: keyterm only
    let text = "Open Clicky and jiffy's jiffy talk to post gres, not kube or reopen clickyness"
    #expect(vocabulary.applyCorrections(to: text)
        == "OpenClicky and Jiffywu's Jiffywu talk to Postgres, not kube or reopen clickyness")
    #expect(vocabulary.replacementRules.map(\.corrected).sorted() == ["Jiffywu", "OpenClicky", "Postgres"])
}

@Test func learnerFindsVocabularyFixesAndIgnoresRewording() {
    // Two heard words merged into one term.
    #expect(CorrectionLearner.corrections(inserted: "I pushed it to git hub today", edited: "I pushed it to GitHub today")
        .map { "\($0.original)→\($0.corrected)" } == ["git hub→GitHub"])
    // Internal capitals.
    #expect(CorrectionLearner.corrections(inserted: "Ask openclicky about it", edited: "Ask OpenClicky about it")
        .map(\.corrected) == ["OpenClicky"])
    // A similar-sounding name.
    #expect(CorrectionLearner.corrections(inserted: "Say hi to clicky for me", edited: "Say hi to Klicky for me")
        .map(\.corrected) == ["Klicky"])
    // Sentence case, common words and real rewording are not vocabulary.
    #expect(CorrectionLearner.corrections(inserted: "the plan is good", edited: "The plan is good").isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "send it there today", edited: "send it their today").isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "we could meet on monday morning", edited: "Let's skip the meeting entirely").isEmpty)
    #expect(CorrectionLearner.corrections(inserted: "same text", edited: "same text").isEmpty)
}

@Test func learnerLocatesTheEditedRegionByItsSurroundings() {
    let region = CorrectionLearner.editedRegion(now: "Dear team, I pushed it to GitHub today. Thanks!",
                                                beforeText: "Dear team,", afterText: " Thanks!", insertedLength: 28)
    #expect(region == "I pushed it to GitHub today.")
    #expect(CorrectionLearner.editedRegion(now: "completely different", beforeText: "Dear team,", afterText: "", insertedLength: 10) == nil)
    #expect(CorrectionLearner.editedRegion(now: "just this", beforeText: "", afterText: "", insertedLength: 9) == "just this")
}

@Test func vocabularyStorePersists() async throws {
    let url = temporaryDirectory().appendingPathComponent("vocab.json")
    let store = DictationVocabularyStore(url: url)
    try await store.update { $0.add("Figma") }
    try await store.update { $0.learn(LearnedCorrection(original: "git hub", corrected: "GitHub", lastLearnedAt: Date(timeIntervalSince1970: 0))) }
    let reloaded = await DictationVocabularyStore(url: url).load()
    #expect(reloaded.words == ["Figma"])
    #expect(reloaded.corrections.first?.corrected == "GitHub")
    let json = try String(contentsOf: url, encoding: .utf8)
    #expect(json.contains("\"lastLearnedAt\" : \"1970-01-01T00:00:00Z\""))
}
