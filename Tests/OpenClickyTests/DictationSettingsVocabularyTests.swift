import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct DictationSettingsVocabularyTests {
    @Test func pageEditsKeepCorrectionsDictationLearnedWhileThePageWasOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-page-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dictation-vocabulary.json")
        let store = DictationVocabularyStore(url: url)
        try await store.save(DictationVocabulary(words: ["Jiffy"], corrections: [LearnedCorrection(original: "jiffy wu", corrected: "Jiffywu")]))
        let model = AppModel(config: .heyClickyLike, credentials: InMemoryCredentialStore(), permissions: PermissionsCenter(fixed: [:]))
        let page = DictationSettingsModel(url: nil, store: store, model: model)
        page.appear()
        #expect(await eventually { page.vocabulary.words == ["Jiffy"] })

        // Dictation learns through the same store while the page is open: a new fix, and a repeat of a known one.
        try await store.update { vocabulary in
            vocabulary.learn(LearnedCorrection(original: "open clicky", corrected: "OpenClicky"))
            vocabulary.learn(LearnedCorrection(original: "jiffy wu", corrected: "Jiffywu"))
        }

        page.draftWord = "Clicky"
        page.addWord()
        #expect(await eventually { page.vocabulary.words == ["Jiffy", "Clicky"] })
        #expect(page.draftWord.isEmpty)
        var stored = await DictationVocabularyStore(url: url).load()
        #expect(stored.words == ["Jiffy", "Clicky"])
        #expect(stored.corrections.map(\.corrected).sorted() == ["Jiffywu", "OpenClicky"])
        #expect(stored.corrections.first { $0.corrected == "Jiffywu" }?.count == 2)
        #expect(page.vocabulary.corrections.map(\.count) == stored.corrections.map(\.count))

        // Removing a correction the page shows with an older count still removes it, and keeps the others.
        page.removeCorrection(LearnedCorrection(original: "jiffy wu", corrected: "Jiffywu", count: 1))
        #expect(await eventually { page.vocabulary.corrections.map(\.corrected) == ["OpenClicky"] })
        page.removeWord("Jiffy")
        #expect(await eventually { page.vocabulary.words == ["Clicky"] })
        stored = await DictationVocabularyStore(url: url).load()
        #expect(stored.words == ["Clicky"])
        #expect(stored.corrections.map(\.corrected) == ["OpenClicky"])
    }

    @Test func aWordAddedBeforeThePageLoadsIsAddedToTheStoredDictionary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-page-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("dictation-vocabulary.json")
        try await DictationVocabularyStore(url: url).save(DictationVocabulary(words: ["Jiffy"], corrections: [LearnedCorrection(original: "a", corrected: "B")]))
        let store = DictationVocabularyStore(url: url)
        let model = AppModel(config: .heyClickyLike, credentials: InMemoryCredentialStore(), permissions: PermissionsCenter(fixed: [:]))
        let page = DictationSettingsModel(url: nil, store: store, model: model)

        // No appear(): the page still holds its empty placeholder.
        page.draftWord = "Clicky"
        page.addWord()
        #expect(await eventually { page.vocabulary.words == ["Jiffy", "Clicky"] })
        let stored = await DictationVocabularyStore(url: url).load()
        #expect(stored.words == ["Jiffy", "Clicky"])
        #expect(stored.corrections.map(\.corrected) == ["B"])
    }

    private func eventually(_ check: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return check()
    }
}
