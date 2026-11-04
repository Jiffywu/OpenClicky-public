import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

@Suite("Brain runtime: prompt, thread, caching, compaction")
struct BrainSessionTests {
    // MARK: Prompt

    @Test func theDrawingLanguageCopiesMatchTheDocs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (doc, resource) in [("docs/dsl.md", "draw-2d"), ("docs/dsl-3d.md", "draw-3d"), ("docs/dsl-guided.md", "draw-guided"),
                                ("docs/dsl-media.md", "draw-media")] {
            let text = try String(contentsOf: root.appendingPathComponent(doc), encoding: .utf8)
            let start = try #require(text.range(of: "<!-- prompt:start -->"), "\(doc) lost its prompt:start marker")
            let end = try #require(text.range(of: "<!-- prompt:end -->"), "\(doc) lost its prompt:end marker")
            let section = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let copy = try KitResources.text(resource, "md", in: "prompts").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(section == copy, "Resources/prompts/\(resource).md differs from \(doc); run scripts/sync-prompts.sh")
        }
    }

    @Test func theSystemPromptHasTheLanguagesAndNothingThatChangesPerTurn() throws {
        let assembler = try BrainPromptAssembler()
        let prompt = assembler.systemPrompt(BrainPromptOptions(toolGroups: [.lookups, .memory]))
        #expect(prompt.contains("# Who you are"))
        #expect(prompt.contains("callout(x, y, \"words\""))      // 2D language
        #expect(prompt.contains("f.cylinder"))                   // 3D language
        #expect(prompt.contains("waitForUser("))                 // guided steps
        #expect(prompt.contains("photo(x, y, w, h"))             // media cards
        let plain = assembler.systemPrompt(BrainPromptOptions(toolGroups: [.lookups, .memory], guidedSteps: false, mediaCards: false))
        #expect(!plain.contains("waitForUser(") && !plain.contains("photo(x, y, w, h"))
        #expect(prompt.contains("web_search"))
        #expect(!prompt.contains("read_connected_apps"))
        let noFigures = assembler.systemPrompt(BrainPromptOptions(figuresAvailable: false))
        #expect(!noFigures.contains("f.cylinder") && noFigures.contains("Don't call figure()"))
        // Equal options give byte-identical prompts.
        #expect(assembler.systemPrompt(BrainPromptOptions(toolGroups: [.memory, .lookups])) == prompt)
    }

    @Test func turnNotesCarryTheContextAndElementsInCanvasPixels() {
        let shot = TurnScreenshot(jpeg: Data([0xFF, 0xD8]), label: "main display", isCursorScreen: true,
                                  pixelSize: CGSize(width: 1200, height: 750), displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let other = TurnScreenshot(jpeg: Data([0xFF, 0xD9]), label: "display 2 (left)", isCursorScreen: false,
                                   pixelSize: CGSize(width: 1280, height: 720), displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let context = TurnContext(localTime: Date(timeIntervalSince1970: 1_793_361_600), timeZone: TimeZone(identifier: "UTC")!,
                                  frontApp: "Safari", frontAppBundleID: "com.apple.Safari", windowTitle: "Pricing",
                                  documentTitle: "Pricing", documentURL: "https://example.com/pricing", documentText: "Plans and prices",
                                  selectedText: "Pro plan",
                                  elements: [TurnElement(id: "e7", role: "button", label: "Buy \"Pro\"", frame: CGRect(x: 144, y: 90, width: 120, height: 36)),
                                             TurnElement(id: "e8", role: "link", label: "Elsewhere", frame: CGRect(x: -500, y: 10, width: 50, height: 20))])
        let input = TurnInput(words: "Which plan?", screenshots: [other, shot], context: context, appNotes: ["The drawing was cut off."])
        let message = BrainFixtures.assembler.turnMessage(for: input, appNotes: ["[App] open_url did not work."])
        let notes = message.text
        #expect(notes.hasPrefix("[Turn] 12:00, Friday, October 30, 2026 ("))
        #expect(notes.contains("Canvas: W = 1200, H = 750"))
        #expect(notes.contains("screenshot 2, the main display, where the pointer is."))
        #expect(notes.contains("onScreen(n) to draw on one of them instead): 1: display 2 (left) 1280×720"))
        #expect(notes.contains("Front app: Safari (com.apple.Safari)"))
        #expect(notes.contains("Selected text: \"Pro plan\""))
        #expect(notes.contains("e7: button \"Buy 'Pro'\" [120, 75, 100, 30]"))
        #expect(!notes.contains("e8"))
        #expect(notes.contains("[App] open_url did not work.") && notes.contains("[App] The drawing was cut off."))
        #expect(notes.contains(BrainTurnNotes.documentMarker + "]\nPlans and prices"))
        #expect(notes.hasSuffix("The user said: Which plan?"))
        // The canvas screenshot is labelled as such; the other one is for reference.
        #expect(notes.contains("Screenshot 2: main display, 1200×750 pixels (the canvas you draw on)."))
        #expect(message.content.filter { $0.isImage }.count == 2)
    }

    // MARK: Cache-friendly prefix

    @Test func eachRequestExtendsThePreviousOneSoProviderCachesKeepMatching() async throws {
        let model = BrainScriptModel([
            [.text(BrainFixtures.program("say(\"One.\")")), .finish(.stop)],
            [.text(BrainFixtures.program("say(\"Two.\")")), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [BrainProbeTool("web_search", kind: .read)])
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("first", app: "Safari"))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("second", app: "Notes", at: Date(timeIntervalSince1970: 1_793_365_000)))
        let (first, second) = (model.requests[0], model.requests[1])
        #expect(first.tools == second.tools)
        #expect(second.messages.count == first.messages.count + 2)
        #expect(Array(second.messages.prefix(first.messages.count)) == first.messages)
        let system = first.messages[0].text
        #expect(!system.contains("Safari") && !system.contains("12:00"))
        #expect(first.promptCache == .conversation)
    }

    @Test func anthropicRequestsMarkTheSystemPromptAndTheConversationForCaching() throws {
        let client = AnthropicMessagesClient(context: ProviderContext(provider: ProviderConfig(id: "a", dialect: .anthropicMessages), apiKey: "k"),
                                             thinkingReplay: AnthropicThinkingReplay())
        let messages: [ChatMessage] = [.system("Stable."), .user(.text("hello")), .assistant("hi"), .user(.text("again"))]
        let body = client.requestBody(ChatRequest(model: "m", messages: messages, promptCache: .conversation))
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(body["system"] == [["type": "text", "text": "Stable.", "cache_control": ["type": "ephemeral"]]])
        let plain = client.requestBody(ChatRequest(model: "m", messages: messages))
        #expect(plain["cache_control"] == nil && plain["system"] == "Stable.")

        // Prewarm shape: a placeholder after the thread; the breakpoint stays on the thread's last block even when
        // the placeholder merges into the same user turn.
        let warm = messages + [.user(.text("placeholder"))]
        let warmBody = client.requestBody(ChatRequest(model: "m", messages: warm, promptCache: PromptCacheHint(system: true, throughMessage: 3)))
        let turns = try #require(warmBody["messages"]?.arrayValue)
        let last = try #require(turns.last?["content"]?.arrayValue)
        #expect(last.count == 2)
        #expect(last[0]["cache_control"] == ["type": "ephemeral"] && last[0]["text"] == "again")
        #expect(last[1]["cache_control"] == nil)
        #expect(warmBody["cache_control"] == nil)
    }

    @Test func prewarmSendsACheapRequestThatCachesThroughTheThread() async throws {
        let model = BrainScriptModel([
            [.text(BrainFixtures.program("say(\"One.\")")), .finish(.stop)],
            [.text("ok"), .usage(input: 5000, cached: 0, output: 1), .finish(.length)],
        ])
        let clock = BrainClock()
        let runtime = BrainFixtures.runtime(model, clock: clock)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("first"))
        await runtime.prewarm()                      // right after a request: the cache is warm, nothing sent
        #expect(model.requests.count == 1)
        clock.advance(300)
        await runtime.prewarm()
        let warm = try #require(model.requests.last)
        #expect(model.requests.count == 2)
        #expect(warm.maxOutputTokens == 1)
        let threadCount = await runtime.currentSession.messages.count
        #expect(warm.promptCache == PromptCacheHint(system: true, throughMessage: threadCount, automatic: false))
        #expect(warm.messages.count == threadCount + 2)
        #expect(await runtime.currentSession.messages.count == threadCount) // the placeholder is not kept

        // Providers that cache by themselves get no prewarm.
        let openAI = BrainFixtures.runtime(BrainScriptModel([])) { $0.dialect = .openAIResponses }
        await openAI.prewarm()
    }

    // MARK: Pruning

    @Test func oldScreenshotsAreReplacedInBatchesAndTheNewestKept() async throws {
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model) { $0.pruning = BrainPruningPolicy(keepImages: 2, imageSlack: 2) }
        var counts: [Int] = []
        for turn in 1...6 {
            _ = try await BrainFixtures.events(runtime, BrainFixtures.input("turn \(turn)"))
            counts.append(await runtime.currentSession.imageCount)
        }
        #expect(counts == [1, 2, 3, 4, 2, 3])
        let session = await runtime.currentSession
        let standIns = session.messages.flatMap(\.content).filter { $0 == .text(BrainPruningPolicy.imageStandIn) }
        #expect(standIns.count == 3)
        // The newest screenshots are the ones kept.
        let withImages = session.items.filter { $0.message.content.contains { $0.isImage } }.compactMap(\.words)
        #expect(withImages == ["turn 4", "turn 5", "turn 6"])
    }

    @Test func oldDocumentTextIsPrunedToo() {
        var items: [BrainThreadItem] = (1...4).map { n in
            BrainThreadItem(seq: n, turn: n, at: Date(), message: .user(.text("[Turn]"), .text(BrainTurnNotes.documentMarker + "]\nbody \(n)")))
        }
        let replaced = BrainPruningPolicy(keepDocuments: 1, documentSlack: 2).prune(&items)
        #expect(replaced == 3)
        #expect(items[3].message.content[1] == .text(BrainTurnNotes.documentMarker + "]\nbody 4"))
        #expect(items[0].message.content[1] == .text(BrainPruningPolicy.documentStandIn))
    }

    // MARK: Compaction

    @Test func aLongThreadIsFoldedIntoANoteOnTheFastSlot() async throws {
        // The thread grows a little each turn, then jumps.
        let sizes = [61_000, 62_000, 63_000, 100_000]
        let model = BrainScriptModel((1...4).map { n in
            [.text(BrainFixtures.program("say(\"Answer \(n).\")")), .usage(input: sizes[n - 1], cached: 50_000, output: 50), .finish(.stop)]
        })
        let fast = BrainScriptModel([[.text("Goals:\n- Learn about gears"), .finish(.stop)]])
        let compactor = BrainCompactor(client: fast, model: "fast-model")
        let runtime = BrainFixtures.runtime(model, compactor: compactor) {
            $0.compactionThreshold = 60_000
            $0.compactionStep = 1_000
            $0.compactionKeepTurns = 2
        }
        for n in 1...4 { _ = try await BrainFixtures.events(runtime, BrainFixtures.input("question \(n)")) }
        await runtime.waitForBackgroundWork()

        // Turns 1 to 3 had too little to fold (two turns are kept, at least two must fold); turn 4 folds turns 1 and 2.
        #expect(fast.requests.count == 1)
        let request = try #require(fast.requests.first)
        #expect(request.model == "fast-model")
        #expect(request.messages.last?.text.contains("question 1") == true)
        #expect(request.messages.last?.text.contains("Answer 1.") == true)
        let session = await runtime.currentSession
        #expect(session.compactions == 1)
        #expect(session.items.first?.isSummary == true)
        #expect(session.items.first?.message.text.contains("Learn about gears") == true)
        let words = session.items.compactMap(\.words)
        #expect(words == ["question 3", "question 4"])
        #expect(session.nextCompactionCheck == 60_000)
    }

    @Test func compactionWaitsUntilThereIsEnoughToFold() async throws {
        let model = BrainScriptModel([[.text(BrainFixtures.program("say(\"Hi.\")")), .usage(input: 90_000, cached: 0, output: 5), .finish(.stop)]])
        let fast = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model, compactor: BrainCompactor(client: fast, model: "f")) {
            $0.compactionThreshold = 60_000
            $0.compactionStep = 10_000
        }
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("only turn"))
        await runtime.waitForBackgroundWork()
        #expect(fast.requests.isEmpty)
        #expect(await runtime.currentSession.nextCompactionCheck == 100_000)
    }

    @Test func foldBoundaryKeepsWholeTurns() {
        func item(_ seq: Int, _ message: ChatMessage, words: String? = nil) -> BrainThreadItem {
            BrainThreadItem(seq: seq, turn: 0, at: Date(), message: message, words: words)
        }
        let items = [
            item(1, .user(.text("a")), words: "a"), item(2, .assistant("x", toolCalls: [ToolCall(id: "t", name: "n", arguments: "{}")])),
            item(3, .tool(callID: "t", result: "{}")), item(4, .assistant("y")),
            item(5, .user(.text("b")), words: "b"), item(6, .assistant("z")),
            item(7, .user(.text("c")), words: "c"), item(8, .assistant("w")),
        ]
        #expect(BrainCompactor.foldBoundary(items, keepTurns: 1) == 6)
        #expect(BrainCompactor.foldBoundary(items, keepTurns: 2) == nil) // only one turn would be folded
        #expect(BrainCompactor.foldBoundary(items, keepTurns: 2, minimumFoldedTurns: 1) == 4)
    }

    // MARK: Sessions

    @Test func sessionsArePersistedWithoutScreenshotsAndPickedUpAgain() async throws {
        let folder = BrainTemporaryFolder()
        let clock = BrainClock()
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model, store: folder.store, clock: clock)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("remember the blue one"))
        let id = await runtime.currentSession.id
        let saved = try String(contentsOf: folder.store.threadURL(for: id), encoding: .utf8)
        #expect(!saved.contains("/9j/") && saved.contains("remember the blue one"))
        let log = try String(contentsOf: folder.store.logURL(for: id), encoding: .utf8)
        #expect(log.contains("\"kind\":\"round\""))

        clock.advance(60)
        let again = BrainFixtures.runtime(model, store: folder.store, clock: clock)
        let resumed = await again.currentSession
        #expect(resumed.id == id)
        #expect(resumed.items.count == 2)
        #expect(resumed.items[0].message.content.contains(.text(BrainSessionStore.savedImageStandIn)))
        #expect(resumed.items[0].words == "remember the blue one")
    }

    @Test func aQuietSessionEndsWithAMemoryNoteAndTheNextTurnStartsFresh() async throws {
        let folder = BrainTemporaryFolder()
        let memoryFolder = TemporaryMemoryFolder()
        let memoryStore = memoryFolder.store()
        let writerModel = BrainScriptModel([[.text("{\"session_note\": \"Asked which plan to buy and chose Pro.\"}"), .finish(.stop)]])
        let memory = BrainMemory(store: memoryStore, writer: MemoryWriter(client: writerModel, model: "fast"))
        let clock = BrainClock()
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model, store: folder.store, memory: memory, clock: clock) { $0.idleTimeout = 600 }
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("which plan should I buy"))
        let firstID = await runtime.currentSession.id

        clock.advance(601)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("hello again"))
        let session = await runtime.currentSession
        #expect(session.id != firstID)
        #expect(session.items.compactMap(\.words) == ["hello again"])
        // The notes are written in the background, so the new turn never waits for them.
        await runtime.waitForBackgroundWork()
        #expect(writerModel.requests.count == 1)
        #expect(writerModel.requests[0].messages.last?.text.contains("which plan should I buy") == true)
        #expect(writerModel.requests[0].messages.last?.text.contains("[Turn]") == false)
        let ended = try folder.store.load(firstID)
        #expect(ended.ended)
        #expect(try memoryStore.list().contains { $0.text.contains("chose Pro") })
    }

    @Test func endingTheSessionStopsARunningTurnFirst() async throws {
        let model = BrainScriptModel([[.text("```js\nsay(\"Working on it.\")\n"), .hang]])
        let runtime = BrainFixtures.runtime(model)
        let consumer = Task { try await BrainFixtures.events(runtime, BrainFixtures.input("long one")) }
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let before = await runtime.currentSession.id
        await runtime.endSession()
        _ = try? await consumer.value
        let after = await runtime.currentSession
        #expect(after.id != before)
        #expect(after.items.isEmpty)
        #expect(model.cancelledStreams == 1)
    }

    @Test func historyTurnsSeedTheThreadForTheHomeChat() async throws {
        func turn(_ words: String, lines: [String], program: String? = nil, outcome: HistoryTurnOutcome = .completed) -> HistoryTurn {
            var turn = HistoryTurn(id: UUID().uuidString, sessionID: "h1", startedAt: Date(timeIntervalSince1970: 1_793_361_600),
                                   source: .text, words: words)
            turn.spokenLines = lines
            turn.program = program
            turn.outcome = outcome
            return turn
        }
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model)
        await runtime.seedConversation([
            turn("what is a gear ratio", lines: ["It's how many times one gear turns per turn of the other."]),
            turn("draw one", lines: ["Here."], program: "say(\"Here.\")\ncircle(100, 100, 40)"),
            turn("this one failed", lines: [], outcome: .failed),
        ])
        let session = await runtime.currentSession
        #expect(session.turnCount == 2)
        #expect(session.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(session.messages[1].text == "```js\nsay(\"It's how many times one gear turns per turn of the other.\")\n```")
        #expect(session.messages[3].text.contains("circle(100, 100, 40)"))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and a bigger one?"))
        #expect(model.requests[0].messages.count == 1 + 4 + 1) // not ended as idle
        // Only the new turn is the session's own, for memory.
        let memory = await runtime.currentSession.conversationForMemory
        #expect(memory.first?.text == "and a bigger one?")

        // TypedChatController hands history to brains that take it.
        let seeding: any ConversationSeeding = runtime
        _ = seeding
    }

    @Test func recordOutcomeReachesTheNextTurn() async throws {
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model)
        await runtime.recordOutcome("The user cut this answer off after line 2.")
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("go on"))
        #expect(model.requests[0].messages.last?.text.contains("[App] The user cut this answer off after line 2.") == true)
        #expect(await runtime.currentSession.pendingAppNotes.isEmpty)
    }

    // MARK: Fences

    @Test func fenceStripperPassesCodeThroughAsItStreams() {
        var stripper = ProgramFenceStripper()
        var out = ""
        for piece in ["``", "`js\nsay(\"a\")", "\n`templ", "ate`\n``", "`\nTrailing prose."] { out += stripper.feed(piece) }
        out += stripper.finish()
        #expect(out == "say(\"a\")\n`template`\n")

        var bare = ProgramFenceStripper()
        #expect(bare.feed("say(\"no fence\")\n") == "say(\"no fence\")\n")
        var indented = ProgramFenceStripper()
        #expect(indented.feed("  ```javascript\n  box(1, 2, 3, 4)\n  ```\n") == "  box(1, 2, 3, 4)\n")
    }

    // MARK: Hosted search

    @Test func hostedWebSearchGoesToTheProviderAfterTheFunctionTools() async throws {
        let lookups = LookupTools(services: LookupServices(hostedWebSearch: true))
        #expect(ToolRegistry.hostedWebSearch(lookups, dialect: .anthropicMessages) == nil) // switched off for now
        let entry = try #require(ToolRegistry.hostedWebSearch(lookups, dialect: .anthropicMessages, enabled: true, countryCode: "US",
                                                              timeZone: "America/Los_Angeles"))
        #expect(ToolRegistry.hostedWebSearch(lookups, dialect: .openAIChat, enabled: true) == nil)
        #expect(ToolRegistry.hostedWebSearch(LookupTools(services: LookupServices()), dialect: .anthropicMessages, enabled: true) == nil)
        var registry = ToolRegistry([BrainProbeTool("recall_memory", kind: .read)])
        registry.registerHosted(entry, group: .hostedSearch)
        #expect(registry.groups.contains(.hostedSearch))

        let model = BrainScriptModel([])
        let runtime = BrainRuntime(client: model, configuration: BrainRuntimeConfiguration(model: "m", dialect: .anthropicMessages),
                                   tools: registry, assembler: BrainFixtures.assembler)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("news?"))
        let request = try #require(model.requests.first)
        #expect(request.hostedTools == [entry])
        #expect(request.messages[0].text.contains("web_search is run by your provider"))

        let client = AnthropicMessagesClient(context: ProviderContext(provider: ProviderConfig(id: "a", dialect: .anthropicMessages), apiKey: "k"),
                                             thinkingReplay: AnthropicThinkingReplay())
        let tools = try #require(client.requestBody(request)["tools"]?.arrayValue)
        #expect(tools.map { $0["name"]?.stringValue } == ["recall_memory", "web_search"])
        #expect(tools.last?["type"] == "web_search_20250305")
    }

    // MARK: Registry

    @Test func registryKeepsOrderReplacesByNameAndResolvesAliases() async {
        var registry = ToolRegistry([BrainProbeTool("a", kind: .read), BrainProbeTool("b", kind: .action)])
        registry.register(BrainProbeTool("a", kind: .action))
        registry.addAliases(["search": "a"])
        #expect(registry.names == ["a", "b"])
        #expect(registry.tool(named: "a")?.kind == .action)
        #expect(registry.tool(named: "search")?.spec.name == "a")
        #expect(ToolRegistry.arguments("") == [:])
        #expect(ToolRegistry.arguments("[1]") == nil)
    }

    @Test func memoryAndAppToolsMapToTheRightKinds() async throws {
        let folder = TemporaryMemoryFolder()
        let memory = ToolRegistry.memoryTools(MemoryTools(store: folder.store()))
        #expect(memory.map(\.kind) == [.async, .read, .read])
        let saved = await memory[0].run(["text": "Likes green tea"], context: BrainToolContext(sessionID: "s", turn: 1, callID: "c"))
        #expect(saved["status"] == "saved")

        let toolbox = AppToolbox.standard(AppToolEnvironment(workspace: RecordingWorkspace(), pasteboard: RecordingPasteboard(),
                                                             appleScript: ScriptedAppleScriptRunner(), calendar: InMemoryCalendarStore()))
        let app = ToolRegistry.appTools(toolbox)
        let kinds = Dictionary(uniqueKeysWithValues: app.map { ($0.spec.name, $0.kind) })
        #expect(kinds["open_url"] == .deferredAction)
        #expect(kinds["copy_to_clipboard"] == .action)
        #expect(kinds["calendar_find_events"] == .read)
        let openURL = try #require(app.first { $0.spec.name == "open_url" })
        #expect(openURL.validate(["url": "javascript:alert(1)"])?["status"] == "refused")
        #expect(openURL.validate(["url": "https://example.com"]) == nil)
    }
}
