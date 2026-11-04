import Foundation
import Testing
@testable import OpenClickyKit

/// Recall ranking: keywords first, recency second, no embeddings.
@Suite struct MemoryRankingTests {
    let ranker = MemoryRanker()

    @Test func keywordsOutweighRecency() {
        let entries = [
            MemoryFixtures.memory("m-sister", "Sister Ana lives in Lisbon", daysAgo: 120),
            MemoryFixtures.memory("m-flight", "Flight to Lisbon on 2026-11-12", daysAgo: 1),
            MemoryFixtures.memory("m-dark", "Prefers dark mode everywhere", daysAgo: 0),
        ]
        let ids = ranker.rank(entries, query: "where does my sister live?", now: MemoryFixtures.now).map(\.entry.id)
        #expect(ids == ["m-sister"], "only entries that match a term come back")

        let both = ranker.rank(entries, query: "sister Lisbon", now: MemoryFixtures.now).map(\.entry.id)
        #expect(both == ["m-sister", "m-flight"], "covering more of the query beats being newer")
    }

    @Test func recencyBreaksEvenKeywordMatches() {
        let entries = [
            MemoryFixtures.memory("m-old", "Booked a dentist appointment", daysAgo: 90),
            MemoryFixtures.memory("m-new", "Moved the dentist appointment", daysAgo: 2),
            MemoryFixtures.memory("m-mid", "Dentist appointment confirmed", daysAgo: 30),
        ]
        let matches = ranker.rank(entries, query: "dentist appointment", now: MemoryFixtures.now)
        #expect(matches.map(\.entry.id) == ["m-new", "m-mid", "m-old"])
        #expect(matches.allSatisfy { $0.keyword == 1 })
        #expect(matches[0].recency > matches[1].recency && matches[1].recency > matches[2].recency)
        // 45-day half-life.
        #expect(abs(matches[2].recency - 0.25) < 0.001)
    }

    @Test func rareTermsCountForMore() {
        var entries = (0..<6).map { MemoryFixtures.memory("m-lisbon\($0)", "Lisbon note number \($0)", daysAgo: 1) }
        entries.append(MemoryFixtures.memory("m-dentist", "Dentist is near the office", daysAgo: 60))
        let first = ranker.rank(entries, query: "Lisbon dentist", now: MemoryFixtures.now).first
        #expect(first?.entry.id == "m-dentist", "the rare word decides, even against newer common-word matches")
    }

    @Test func prefixesAndPluralsMatch() {
        let entries = [
            MemoryFixtures.memory("m-photo", "Takes a photography class on Tuesdays", daysAgo: 5),
            MemoryFixtures.memory("m-flights", "Hates early flights", daysAgo: 5),
            MemoryFixtures.memory("m-other", "Drinks oat milk", daysAgo: 5),
        ]
        let photo = ranker.rank(entries, query: "photo", now: MemoryFixtures.now)
        #expect(photo.map(\.entry.id) == ["m-photo"])
        #expect(photo[0].keyword == 0.5, "a prefix is a half match")
        #expect(ranker.rank(entries, query: "flight", now: MemoryFixtures.now).first?.keyword == 1, "plural folds to singular")
        #expect(ranker.rank(entries, query: "Café crème", now: MemoryFixtures.now).isEmpty)
    }

    @Test func wordsNothingContainsDoNotLowerScores() {
        let entries = [
            MemoryFixtures.memory("m-pen", "Allergic to penicillin", daysAgo: 3),
            MemoryFixtures.memory("m-tea", "Drinks green tea", daysAgo: 3),
        ]
        let matches = ranker.rank(entries, query: "the penicillin allergy thing", now: MemoryFixtures.now)
        #expect(matches.map(\.entry.id) == ["m-pen"])
        #expect(matches[0].keyword == 1, "allergy and thing appear nowhere, so penicillin is the whole query")
        #expect(ranker.rank(entries, query: "giraffes", now: MemoryFixtures.now).isEmpty)
    }

    @Test func accentsAndCaseAreFolded() {
        let entries = [MemoryFixtures.memory("m-cafe", "Favourite café is Café Ölmühle", daysAgo: 3)]
        #expect(ranker.rank(entries, query: "CAFE olmuhle", now: MemoryFixtures.now).first?.keyword == 1)
    }

    @Test func emptyQueryReturnsNewestFirstAndUndatedLast() {
        let entries = [
            MemoryFixtures.memory("m-a", "Older", daysAgo: 20),
            MemoryEntry(id: "s-x", text: "Answer briefly", place: .standing),
            MemoryFixtures.memory("m-b", "Newer", daysAgo: 1),
        ]
        #expect(ranker.rank(entries, query: "  the  ", now: MemoryFixtures.now).map(\.entry.id) == ["m-b", "m-a", "s-x"])
        #expect(ranker.rank(entries, query: "", now: MemoryFixtures.now, limit: 1).map(\.entry.id) == ["m-b"])
    }

    @Test func storeRecallSearchesEveryPlace() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        try store.save("Ana's birthday is on 2026-12-03", kind: .event, source: .voice)
        try store.addToProfile("Sister Ana lives in Lisbon", section: "People")
        try store.addStanding("Call Ana by her nickname, Nani")
        try store.saveHowTo(title: "Send Ana a postcard", steps: "Open Postcards app; pick the Lisbon address")
        let places = try store.recall("Ana", limit: 10).map(\.entry.place.label)
        #expect(Set(places) == ["event", "profile: People", "standing", "how-to"])
        #expect(places.first == "event", "the dated memory is the freshest")
    }
}

/// The size budget, enforced on disk and in the prompt.
@Suite struct MemoryBudgetTests {
    @Test func oldestMemoriesGoFirstAndSessionNotesBeforeFacts() throws {
        let folder = TemporaryMemoryFolder()
        let clock = TestClock()
        let store = folder.store(budget: MemoryBudget(maxMemories: 3), now: clock.function)
        try store.save("First fact about tea", source: .voice)
        clock.advance(days: 1)
        try store.save("Session about the tax return", kind: .session, source: .session)
        clock.advance(days: 1)
        try store.save("Second fact about coffee", source: .voice)
        clock.advance(days: 1)
        try store.save("Third fact about juice", source: .voice)
        #expect(try store.snapshot().memories.map(\.text) == ["First fact about tea", "Second fact about coffee", "Third fact about juice"],
                "the session note went first even though a fact was older")
        clock.advance(days: 1)
        try store.save("Fourth fact about water", source: .voice)
        #expect(try store.snapshot().memories.map(\.text) == ["Second fact about coffee", "Third fact about juice", "Fourth fact about water"])
    }

    @Test func longMemoriesAreClippedAtAWord() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store(budget: MemoryBudget(maxMemoryCharacters: 40))
        let outcome = try store.save("Prefers walking meetings in the park whenever the weather allows it", source: .voice)
        let text = try #require(outcome.entry?.text)
        #expect(text == "Prefers walking meetings in the park…")
        #expect(text.count <= 40)
    }

    @Test func standingContextRefusesPastItsLimit() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store(budget: MemoryBudget(maxStandingLines: 2))
        #expect(try store.addStanding("Answer in Spanish") == .saved(MemoryEntry(id: MemoryID.standing("Answer in Spanish"), text: "Answer in Spanish", place: .standing)))
        #expect(try store.addStanding("answer in spanish.").entry?.text == "Answer in Spanish", "duplicate")
        _ = try store.addStanding("Use metric units")
        guard case .refused = try store.addStanding("Never use emoji") else { Issue.record("expected a refusal"); return }
        #expect(try store.snapshot().standing == ["Answer in Spanish", "Use metric units"])
    }

    @Test func howTosDropTheOldest() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store(budget: MemoryBudget(maxHowTos: 2))
        try store.saveHowTo(title: "Alpha", steps: "a")
        try store.saveHowTo(title: "Beta", steps: "b")
        try store.saveHowTo(title: "Alpha", steps: "a2")
        try store.saveHowTo(title: "Gamma", steps: "c")
        #expect(try store.snapshot().howTos == [MemoryHowTo(title: "Beta", steps: "b"), MemoryHowTo(title: "Gamma", steps: "c")],
                "replacing Alpha kept its place; Gamma pushed out the oldest, Alpha")
    }

    @Test func profileTrimsRightNowFirstThenRefuses() throws {
        let folder = TemporaryMemoryFolder()
        let limit = MemoryProfile.template.characterCount + 120
        let store = folder.store(budget: MemoryBudget(maxProfileCharacters: limit))
        try store.addToProfile("Asked about train times", section: "Recent asks")
        try store.addToProfile("Asked about the weather in Porto", section: "Recent asks")
        try store.addToProfile("Works on the Atlas redesign", section: "Current projects")
        #expect(try store.snapshot().profile.characterCount <= limit)
        // A lasting line pushes out the oldest "Right now" line.
        try store.addToProfile("Product designer at a small studio in Porto", section: "Work and background")
        var profile = try store.snapshot().profile
        #expect(profile.characterCount <= limit)
        #expect(!profile.bullets.map(\.text).contains("Asked about train times"))
        #expect(profile.bullets.map(\.text).contains("Product designer at a small studio in Porto"))
        // Once "Right now" is empty, lasting lines are refused rather than dropped.
        try store.addToProfile("Has two kids, Leo and Mia, and a dog named Pixel who sleeps all day", section: "People")
        try store.addToProfile("Plays five-a-side football every Thursday evening with friends from work", section: "Routines")
        let outcome = try store.addToProfile("Learning Portuguese with a tutor on Monday and Wednesday mornings", section: "Goals")
        guard case .refused(let reason) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(reason.contains("full"))
        profile = try store.snapshot().profile
        #expect(profile.characterCount <= limit)
        #expect(profile.bullets.map(\.text).contains("Product designer at a small studio in Porto"))
    }

    @Test func aNewRightNowLineMakesRoomInsteadOfDroppingItself() throws {
        let folder = TemporaryMemoryFolder()
        let limit = MemoryProfile.template.characterCount + 60
        let store = folder.store(budget: MemoryBudget(maxProfileCharacters: limit))
        try store.addToProfile("Redesigning the Atlas booking flow", section: "Current projects")
        let outcome = try store.addToProfile("Asked how to export frames as a PDF", section: "Recent asks")
        #expect(outcome.entry?.text == "Asked how to export frames as a PDF")
        #expect(try store.snapshot().profile.bullets.map(\.text) == ["Asked how to export frames as a PDF"])
    }

    @Test func promptStaysWithinItsTokenBudget() throws {
        var snapshot = MemorySnapshot()
        snapshot.standing = (1...12).map { "Standing request number \($0): keep answers short and friendly" }
        for index in 1...40 { snapshot.profile.add("Profile line \(index) about their work on the Atlas project", to: "Work and background") }
        snapshot.memories = (1...60).map {
            MemoryRecord(id: "m-\($0)", text: "Memory \($0) about Lisbon trips and dentist visits", createdAt: MemoryFixtures.daysAgo(Double($0)), source: .voice)
        }
        for budget in [60, 120, 300, 900, 2_000, 10_000] {
            let section = MemoryPromptBuilder(tokenBudget: budget).build(from: snapshot, query: "Lisbon", now: MemoryFixtures.now)
            #expect(section.estimatedTokens <= budget, "budget \(budget)")
            #expect(MemoryPromptBuilder.estimateTokens(section.text) == section.estimatedTokens)
            if !section.stableText.isEmpty {
                #expect(section.stableText.hasPrefix("<user_memory>") && section.stableText.hasSuffix("</user_memory>"))
                #expect(section.text.hasPrefix(section.stableText))
            }
            if !section.turnText.isEmpty {
                #expect(section.turnText.hasPrefix("<relevant_memories>") && section.turnText.hasSuffix("</relevant_memories>"))
                #expect(section.text.hasSuffix(section.turnText))
            }
        }
        let small = MemoryPromptBuilder(tokenBudget: 300).build(from: snapshot, query: "Lisbon", now: MemoryFixtures.now)
        #expect(small.omitted > 0)
        #expect(small.text.contains("Standing request number 1:"), "standing context comes first")
        let large = MemoryPromptBuilder(tokenBudget: 10_000).build(from: snapshot, query: "Lisbon", now: MemoryFixtures.now)
        #expect(large.text.contains("Profile line 40"))
        #expect(large.includedIDs.filter { $0.hasPrefix("m-") }.count == 8, "at most maxRelevant memories")
        #expect(MemoryPromptBuilder(tokenBudget: 20).build(from: snapshot, query: "", now: MemoryFixtures.now).text.isEmpty)
    }

    @Test func promptPicksRelevantMemoriesAndOrdersStableThingsFirst() {
        var snapshot = MemorySnapshot()
        snapshot.standing = ["Answer in British English"]
        snapshot.profile.add("Product designer", to: "Work and background")
        snapshot.memories = [
            MemoryRecord(id: "m-lisbon", text: "Sister Ana lives in Lisbon", createdAt: MemoryFixtures.daysAgo(100), source: .voice),
            MemoryRecord(id: "m-tea", text: "Drinks green tea", createdAt: MemoryFixtures.daysAgo(1), source: .voice),
            MemoryRecord(id: "m-chat", text: "Planned the Lisbon trip itinerary", kind: .session, createdAt: MemoryFixtures.daysAgo(3), source: .session),
        ]
        snapshot.howTos = [MemoryHowTo(title: "Book Lisbon trains", steps: "Use the CP app")]
        let section = MemoryPromptBuilder().build(from: snapshot, query: "When am I seeing my sister in Lisbon?", now: MemoryFixtures.now)
        let text = section.text
        #expect(text.contains("- Answer in British English"))
        #expect(text.contains("Work and background:\n- Product designer"))
        #expect(text.contains("2026-07-22: Sister Ana lives in Lisbon"))
        #expect(text.contains("2026-10-27, earlier conversation: Planned the Lisbon trip itinerary"))
        #expect(text.contains("(how-to) Book Lisbon trains: Use the CP app"))
        #expect(!text.contains("green tea"), "irrelevant memories stay out")
        let standing = text.range(of: "Standing context")!.lowerBound
        let profile = text.range(of: "About them:")!.lowerBound
        let relevant = text.range(of: "<relevant_memories>")!.lowerBound
        #expect(standing < profile && profile < relevant)
        // The stable part holds no per-turn items, so it can sit in a cached system prompt.
        #expect(section.stableText.contains("Product designer") && !section.stableText.contains("Lisbon"))
        #expect(section.turnText.contains("Sister Ana lives in Lisbon [m-lisbon]"))
        let otherTurn = MemoryPromptBuilder().build(from: snapshot, query: "green tea", now: MemoryFixtures.now)
        #expect(otherTurn.stableText == section.stableText)
        #expect(otherTurn.turnText != section.turnText)

        // Without a match the newest memories stand in.
        let idle = MemoryPromptBuilder().build(from: snapshot, query: "", now: MemoryFixtures.now)
        #expect(idle.text.contains("Drinks green tea"))
        #expect(MemoryPromptBuilder().build(from: MemorySnapshot(), query: "x", now: MemoryFixtures.now).text.isEmpty)
    }
}
