import Foundation
import Testing
@testable import OpenClickyKit

/// The session-end memory writer, with a scripted language model standing in for the brain-fast slot.
@Suite struct MemoryWriterTests {
    /// A short voice session: the user mentions a move, a preference, a standing request and (by accident) a key.
    static let thread: [ChatMessage] = [
        .system("You are OpenClicky… (the brain's own prompt, never sent to the writer)"),
        .user(.text("[App] The user cut the last answer off.")),
        .user(.text("I moved from Berlin to Lisbon last month, can you show me where the tram stop is?"),
              .image(data: Data([0xFF, 0xD8]), mimeType: "image/jpeg")),
        .assistant(#"step(() => { say("Sure, it's just past the bakery on your map."); point(412, 300) })"#),
        .user(.text("From now on answer in British English please. Oh and my key is sk-proj-AbCdEf0123456789GhIjKlMn")),
        .assistant("Got it.", toolCalls: [ToolCall(id: "c1", name: "save_memory", arguments: #"{"text":"Answers in British English"}"#)]),
        .tool(callID: "c1", result: #"{"status":"saved","id":"m-0000aaaa"}"#),
    ]

    static let reply = """
        Here is the update:
        ```json
        {
          "session_note": "Helped find the tram stop near the new flat in Lisbon; asked for British English.",
          "profile_add": [
            {"section": "Basics", "line": "Lives in Lisbon since 2026-09"},
            {"section": "Recent asks", "line": "Asked where the nearest tram stop is"},
            {"section": "Accounts", "line": "OpenAI key is sk-proj-AbCdEf0123456789GhIjKlMn"}
          ],
          "profile_remove": [{"section": "Basics", "line": "Lives in Berlin"}],
          "standing_add": ["Answer in British English"],
          "standing_remove": [],
          "how_tos": [{"title": "Find the nearest tram stop", "steps": ["Open Maps", "Search for tram stops", "Pick the closest one"]}],
          "memories": [
            {"text": "Moved from Berlin to Lisbon in 2026-09", "kind": "event"},
            {"text": "Wifi password is hunter22", "kind": "fact"},
            {"text": "Sneaky", "kind": "session"}
          ],
          "forget": ["m-oldberlin", "m-doesnotexist"]
        }
        ```
        """

    private func seededStore(_ folder: TemporaryMemoryFolder) throws -> MemoryStore {
        let store = folder.store()
        try store.addToProfile("Lives in Berlin", section: "Basics")
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let old = MemoryRecord(id: "m-oldberlin", text: "Favourite bar is in Kreuzberg, Berlin", createdAt: MemoryFixtures.daysAgo(200), source: .voice)
        try MemoryFileFormat.renderMemories(.init(records: [old])).write(to: store.memoriesURL, atomically: true, encoding: .utf8)
        return store
    }

    @Test func appliesTheModelsDiffToTheStore() async throws {
        let folder = TemporaryMemoryFolder()
        let store = try seededStore(folder)
        let model = ScriptedLanguageModel(reply: Self.reply)
        let writer = MemoryWriter(client: model, model: "fast-model")

        let report = try await writer.endSession(thread: Self.thread, store: store, sessionID: "session-1", now: MemoryFixtures.now)
        let snapshot = try store.snapshot()

        // Profile: Berlin replaced by Lisbon; the recent ask went to "Right now"; the key line was refused.
        let profileLines = snapshot.profile.bullets.map { "\($0.section): \($0.text)" }
        #expect(profileLines.contains("Basics: Lives in Lisbon since 2026-09"))
        #expect(profileLines.contains("Recent asks: Asked where the nearest tram stop is"))
        #expect(!profileLines.contains { $0.contains("Berlin") })
        #expect(snapshot.profile.section(named: "Accounts") == nil, "a line that is only a secret creates nothing")

        #expect(snapshot.standing == ["Answer in British English"])
        #expect(snapshot.howTos == [MemoryHowTo(title: "Find the nearest tram stop", steps: "1. Open Maps\n2. Search for tram stops\n3. Pick the closest one")])

        let memories = snapshot.memories.map { "\($0.kind.rawValue): \($0.text)" }.sorted()
        #expect(memories == [
            "event: Moved from Berlin to Lisbon in 2026-09",
            "fact: Sneaky",
            "session: Helped find the tram stop near the new flat in Lisbon; asked for British English.",
        ], "the old Berlin memory is forgotten, the wifi password refused, and a 'session' kind from the model is demoted")
        #expect(snapshot.memories.allSatisfy { $0.source == .session && $0.sessionID == "session-1" })

        #expect(report.removed.map(\.text).sorted() == ["Favourite bar is in Kreuzberg, Berlin", "Lives in Berlin"])
        #expect(report.skipped.contains { $0.text == "m-doesnotexist" && $0.reason == "no such id" })
        #expect(report.skipped.filter { $0.reason == MemoryStore.refusedSecret }.count == 2)

        // Nothing secret anywhere on disk.
        for url in [store.profileURL, store.standingURL, store.howTosURL, store.memoriesURL] {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("sk-proj") && !text.contains("hunter22"), "\(url.lastPathComponent)")
        }
    }

    @Test func sendsOpenClickysPromptAndAScrubbedTranscript() async throws {
        let folder = TemporaryMemoryFolder()
        let store = try seededStore(folder)
        let model = ScriptedLanguageModel(reply: "{}")
        let writer = MemoryWriter(client: model, model: "fast-model", maxOutputTokens: 900)

        let report = try await writer.endSession(thread: Self.thread, store: store, now: MemoryFixtures.now)
        #expect(!report.changedAnything, "an empty diff changes nothing")

        let request = try #require(model.requests.first)
        #expect(model.requests.count == 1)
        #expect(request.model == "fast-model")
        #expect(request.maxOutputTokens == 900)
        #expect(request.tools.isEmpty)
        #expect(request.messages.map(\.role) == [.system, .user])
        #expect(request.messages[0].text == MemoryWriter.instructions)

        let body = request.messages[1].text
        #expect(body.contains("Today is 2026-10-30."))
        #expect(body.contains("- Lives in Berlin"), "what is already remembered")
        #expect(body.contains("- m-oldberlin (2026-04-13, fact): Favourite bar is in Kreuzberg, Berlin"))
        #expect(body.contains("User: I moved from Berlin to Lisbon last month, can you show me where the tram stop is? [screenshot]"))
        #expect(body.contains("OpenClicky: Sure, it's just past the bakery on your map."), "spoken lines, not drawing code")
        #expect(!body.contains("point(412"))
        #expect(body.contains("(OpenClicky used save_memory:"))
        #expect(body.contains("my key is [redacted]"))
        #expect(!body.contains("sk-proj"))
        #expect(!body.contains("the brain's own prompt"), "system messages are left out")
    }

    @Test func aSessionWithoutUserWordsMakesNoCall() async throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let model = ScriptedLanguageModel(reply: Self.reply)
        let thread: [ChatMessage] = [.system("prompt"), .user(.text("[App] Job finished")), .assistant("Done.")]
        let report = try await MemoryWriter(client: model, model: "m").endSession(thread: thread, store: store)
        #expect(model.requests.isEmpty)
        #expect(!report.changedAnything)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func anUnreadableReplyThrowsAndChangesNothing() async throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let writer = MemoryWriter(client: ScriptedLanguageModel(reply: "Sorry, I can't help with that."), model: "m")
        await #expect(throws: MemoryWriterError.self) {
            try await writer.endSession(thread: Self.thread, store: store)
        }
        #expect(try store.snapshot().isEmpty)
    }

    @Test func diffParsingIsLenientAndCapped() throws {
        var limits = MemoryDiff.Limits()
        limits.memories = 2
        let diff = try MemoryDiff.parse("""
            {"note": "  short   note ", "profile_additions": [{"text": "No section given"}, {"line": ""}],
             "standing_context_add": "Use metric units", "howtos": [{"title": "Export", "steps": "File > Export"}],
             "memories": ["one", {"text": "two", "kind": "preference"}, "three"], "forget_ids": [], "session_note_extra": 1}
            """, limits: limits)
        #expect(diff.sessionNote == "short note")
        #expect(diff.profileAdd == [MemoryDiff.ProfileLine(section: "Notes", text: "No section given")])
        #expect(diff.standingAdd == ["Use metric units"])
        #expect(diff.howTos == [MemoryDiff.HowTo(title: "Export", steps: "File > Export")])
        #expect(diff.memories == [MemoryDiff.NewMemory(text: "one"), MemoryDiff.NewMemory(text: "two", kind: .preference)])
        #expect(try MemoryDiff.parse(#"{"session_note": null, "memories": []}"#).isEmpty)
    }

    @Test func runsOnTheBrainFastSlotOrFallsBackToTheBrain() throws {
        let providers = [ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"),
                                        credential: "openai")]
        let catalog = try ModelCatalog.builtIn()
        func factory(_ slots: [SlotID: SlotSelection], keys: [String: String] = ["openai": "test-key"]) -> EngineFactory {
            EngineFactory(config: OpenClickyConfig(providers: providers, slots: slots), catalog: catalog,
                          credentials: InMemoryCredentialStore(keys), http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
        }
        let brain = SlotSelection(provider: "openai", model: "gpt-6.1-sol")
        let fast = SlotSelection(provider: "openai", model: "gpt-5.4-mini")
        #expect(try MemoryWriter(factory: factory([.brain: brain, .brainFast: fast])).model == "gpt-5.4-mini")
        #expect(try MemoryWriter(factory: factory([.brain: brain])).model == "gpt-6.1-sol", "falls back to the brain")
        #expect(throws: EngineFactoryError.self) { try MemoryWriter(factory: factory([:])) }
        #expect(throws: EngineFactoryError.self) { try MemoryWriter(factory: factory([.brain: brain], keys: [:])) }
    }

    @Test func longTranscriptsKeepTheStartAndTheEnd() {
        var thread: [ChatMessage] = [.user(.text("FIRST question about the budget"))]
        for index in 0..<400 { thread.append(.user(.text("filler line number \(index) with some words"))) }
        thread.append(.user(.text("LAST question about the slides")))
        let transcript = MemoryWriter.transcript(of: thread, limit: 2_000)
        #expect(transcript.count <= 2_000)
        #expect(transcript.hasPrefix("User: FIRST question"))
        #expect(transcript.hasSuffix("User: LAST question about the slides"))
        #expect(transcript.contains("(… the middle of the conversation is left out …)"))
    }
}
