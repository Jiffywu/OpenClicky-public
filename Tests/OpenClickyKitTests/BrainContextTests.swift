import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// One brain with the app's context: skills, connected apps, job notes and figures reach push-to-talk turns; Home's
// typed chat runs on the same runtime and records into its conversation; always-on gets the same context and records
// into that conversation too; memory reaches agents and recall searches earlier chats.

/// Active skills a test can change.
final class TestSkills: ActiveSkillsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String) { self.text = text }

    func set(_ new: String) { lock.withLock { text = new } }
    func skillsPromptSection() -> String { lock.withLock { text } }
    func skillsAgentInstructions() -> String { "" }
}

/// Turn notes a test can change.
final class TestNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String]

    init(_ notes: [String]) { self.notes = notes }

    func set(_ new: [String]) { lock.withLock { notes = new } }
    var current: [String] { lock.withLock { notes } }
}

enum BrainContextFixtures {
    static let pitchDecks = "<active_skills>\n- Pitch decks (for Keynote): One idea per slide.\n</active_skills>"
    static let physics = "<active_skills>\n- Physics tutor: Explain with diagrams.\n</active_skills>"

    static func runtime(_ model: BrainScriptModel, tools: [any BrainTool] = [], promptOptions: BrainPromptOptions = BrainPromptOptions(),
                        sources: BrainContextSources = BrainContextSources(), store: BrainSessionStore? = nil,
                        memory: BrainMemory? = nil) -> BrainRuntime {
        BrainRuntime(client: model, configuration: BrainRuntimeConfiguration(model: "test-brain", dialect: .anthropicMessages),
                     tools: ToolRegistry(tools), assembler: BrainFixtures.assembler, promptOptions: promptOptions, store: store,
                     memory: memory, sources: sources,
                     sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    static func folder(_ name: String = "brain-context") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real JPEG of a plain colour, `width`×`height`.
    static func jpeg(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ImageCoding.jpegData(context.makeImage()!, quality: 0.8)
    }

    static func lastUserText(_ request: ChatRequest) -> String {
        request.messages.last(where: { $0.role == .user })?.content.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n") ?? ""
    }
}

/// A brain that records its inputs and answers with one line.
final class RecordingBrain: BrainTurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [TurnInput] = []
    var inputs: [TurnInput] { lock.withLock { seen } }

    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        lock.withLock { seen.append(input) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.sayLine(index: 0, text: "The save button is at the top right."))
            continuation.yield(.finished(TurnSummary(program: "say(\"The save button is at the top right.\")", spokenLines: [],
                                                     rounds: 1, usage: nil, model: "m", firstTokenSeconds: nil, totalSeconds: 0.1)))
            continuation.finish()
        }
    }

    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
}

@Suite struct BrainContextPromptTests {
    @Test func systemPromptListsConnectedAppsAndSkills() {
        let options = BrainPromptOptions(toolGroups: [.connectedApps],
                                         connectedApps: ["Obsidian: Search, read and write Markdown notes in a local vault", "Linear (Work)"],
                                         skills: BrainContextFixtures.pitchDecks)
        let prompt = BrainFixtures.assembler.systemPrompt(options)
        #expect(prompt.contains("# Connected apps\nThe user connected these apps, and read_connected_apps can look in them:\n"
                                + "- Obsidian: Search, read and write Markdown notes in a local vault\n- Linear (Work)"))
        #expect(prompt.contains("# Skills\n<active_skills>\n- Pitch decks (for Keynote)"))
        #expect(prompt.contains("[Your jobs] lists your background jobs"))
        // No skills, no section; apps without the tool aren't listed.
        let bare = BrainFixtures.assembler.systemPrompt(BrainPromptOptions(connectedApps: ["Obsidian"]))
        #expect(!bare.contains("# Skills") && !bare.contains("# Connected apps"))
    }

    @Test func taggedNotesKeepTheirTagOthersBecomeAppNotes() {
        let input = TurnInput(words: "hi", appNotes: ["[Your jobs] One job.", "plain note", "[App] already tagged", "[lowercase] x"])
        let notes = BrainTurnNotes.notes(for: input)
        #expect(notes.contains("\n[Your jobs] One job."))
        #expect(notes.contains("\n[App] plain note"))
        #expect(notes.contains("\n[App] already tagged"))
        #expect(notes.contains("\n[App] [lowercase] x"))
        #expect(!notes.contains("[App] [Your jobs]"))
    }
}

@Suite struct BrainContextRuntimeTests {
    @Test func skillsAreInTheSessionPromptAndAChangeArrivesAsANote() async throws {
        let skills = TestSkills(BrainContextFixtures.pitchDecks)
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model, sources: BrainContextSources(skills: BrainContextSources.skills(skills)))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("make my slides better"))
        let system = model.requests[0].messages[0].text
        #expect(system.contains("Pitch decks (for Keynote)"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[0]).contains("[Skill update]"))

        skills.set(BrainContextFixtures.physics)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("why do gears turn"))
        // The cached prefix stays the same; the change rides with the turn.
        #expect(model.requests[1].messages[0].text == system)
        let second = BrainContextFixtures.lastUserText(model.requests[1])
        #expect(second.contains("[Skill update] The active skills changed"))
        #expect(second.contains("Physics tutor"))

        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("thanks"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[2]).contains("[Skill update]"))

        skills.set("")
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and now?"))
        #expect(BrainContextFixtures.lastUserText(model.requests[3]).contains("[Skill update] No skills are active now"))

        // A new session builds its prompt with the current skills (none) and owes no note.
        await runtime.endSession()
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("hello again"))
        #expect(!model.requests[4].messages[0].text.contains("# Skills"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[4]).contains("[Skill update]"))
    }

    @Test func jobNotesReachTheBrainOnlyWhenTheyChange() async throws {
        let notes = TestNotes(["[Your jobs] Background work.\n- job-1 \"Find flights\": WORKING NOW"])
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model, sources: BrainContextSources(turnNotes: { notes.current }))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("how's it going"))
        let first = BrainContextFixtures.lastUserText(model.requests[0])
        #expect(first.contains("\n[Your jobs] Background work.\n- job-1 \"Find flights\": WORKING NOW"))
        #expect(!first.contains("[App] [Your jobs]"))

        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("anything else"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[1]).contains("[Your jobs]"))

        notes.set(["[Your jobs] Background work.\n- job-1 \"Find flights\": done, said: Three options under 400 euros."])
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and now"))
        #expect(BrainContextFixtures.lastUserText(model.requests[2]).contains("done, said: Three options under 400 euros."))

        // A new session hears the current note again.
        await runtime.endSession()
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("new chat"))
        #expect(BrainContextFixtures.lastUserText(model.requests[3]).contains("[Your jobs]"))
    }

    @Test func theBrowserNoteReachesTheBrainOnlyWhenTheConnectionChanges() async throws {
        let peer = BrowserPeer(id: "p", session: "s", profileId: "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50", origin: "o",
                               browser: "com.google.Chrome", connectedAt: Date(), lastSeen: Date())
        let waiting = BrowserBrainNote.make(state: .waitingForExtension, chromiumInstalled: true)
        #expect(waiting.hasPrefix("[Browser] Not connected.") && waiting.contains("chrome_setup") && waiting.contains("openclicky://settings/browser"))
        let notes = TestNotes(["[Your jobs] Nothing running.", waiting])
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model, sources: BrainContextSources(turnNotes: { notes.current }))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("hi"))
        #expect(BrainContextFixtures.lastUserText(model.requests[0]).contains("[Browser] Not connected."))

        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("anything new"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[1]).contains("[Browser]"), "unchanged: not sent again")

        // A later peer with a new lastSeen gives the same text, so the brain isn't told twice.
        let connected = BrowserBrainNote.make(state: .connected([peer]), chromiumInstalled: true)
        notes.set(["[Your jobs] Nothing running.", connected])
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and now"))
        let told = BrainContextFixtures.lastUserText(model.requests[2])
        #expect(told.contains("[Browser] Connected: Chrome (1 profile)."))
        #expect(!told.contains("[Your jobs]"))
        var later = peer
        later.lastSeen = Date().addingTimeInterval(60)
        notes.set(["[Your jobs] Nothing running.", BrowserBrainNote.make(state: .connected([later]), chromiumInstalled: true)])
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("again"))
        #expect(!BrainContextFixtures.lastUserText(model.requests[3]).contains("[Browser]"))

        #expect(BrowserBrainNote.make(state: .waitingForExtension, chromiumInstalled: false).contains("no Chromium browser"))
    }

    @Test func aNoteForATurnThatWasCancelledGoesWithTheNextOne() async throws {
        // The first turn is cancelled while its notes are being read; they are already counted as told, so they
        // must ride with the next turn instead of being lost.
        let entered = BrainGate()
        let calls = TestNotes([])
        let sources = BrainContextSources(turnNotes: {
            let first = calls.current.isEmpty
            calls.set(calls.current + ["called"])
            if first {
                entered.open()
                try? await Task.sleep(for: .seconds(30))
            }
            return ["[Your jobs] Background work.\n- job-1 \"Find flights\": WORKING NOW"]
        })
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model, sources: sources)
        let first = Task { try await BrainFixtures.events(runtime, BrainFixtures.input("how are my jobs")) }
        await entered.wait(timeout: .seconds(20))
        first.cancel()
        _ = try? await first.value
        #expect(model.requests.isEmpty)

        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("how are my jobs"))
        #expect(model.requests.count == 1)
        #expect(BrainContextFixtures.lastUserText(try #require(model.requests.first)).contains("job-1 \"Find flights\": WORKING NOW"))
    }

    @Test func figuresFollowWhatThisMacCanShow() async throws {
        let none = FigureAvailability(hasDevice: { false })
        #expect(!none.isAvailable && none.problem == "3D renderer: no Metal device")
        let model = BrainScriptModel([])
        let blind = BrainContextFixtures.runtime(model, sources: BrainContextSources(figuresAvailable: { none.isAvailable }))
        _ = try await BrainFixtures.events(blind, BrainFixtures.input("show me an engine"))
        #expect(model.requests[0].messages[0].text.contains(BrainInstructions.noFigures))

        let available = FigureAvailability(hasDevice: { true })
        let second = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(second, sources: BrainContextSources(figuresAvailable: { available.isAvailable }))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("show me an engine"))
        #expect(second.requests[0].messages[0].text.contains("(3D language here)"))
        available.markUnavailable("3D shaders failed to compile: test")
        #expect(available.problem == "3D shaders failed to compile: test")
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and a gearbox"))
        #expect(BrainContextFixtures.lastUserText(second.requests[1]).contains("3D figures stopped working on this Mac"))
        available.reset()
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("try again"))
        #expect(BrainContextFixtures.lastUserText(second.requests[2]).contains("3D figures work again"))
    }

    @Test func theBrainReadsTheObsidianVaultThroughReadConnectedApps() async throws {
        let vault = BrainContextFixtures.folder("vault")
        defer { try? FileManager.default.removeItem(at: vault) }
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "# Groceries\n- oat milk\n- sourdough\n".write(to: vault.appendingPathComponent("Groceries.md"), atomically: true, encoding: .utf8)
        let registry = ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: vault.path))
        let apps = ConnectedAppsWiring.make(registry: registry, credentials: InMemoryCredentialStore())
        #expect(apps.promptLines == ["Obsidian: Search, read and write Markdown notes in a local vault"])
        let wiring = BrainWiring(connectedApps: apps)
        let tools = wiring.tools()
        #expect(tools.names == ["read_connected_apps"])
        #expect(tools.groups.contains(.connectedApps))

        let model = BrainScriptModel([
            [.text("```js\nsay(\"Let me look.\")\n"), .call("c1", "read_connected_apps", #"{"request":"oat milk","app":"Obsidian"}"#),
             .finish(.toolCalls)],
            [.text("say(\"Your list has oat milk and sourdough.\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainRuntime(client: model, configuration: BrainRuntimeConfiguration(model: "m", dialect: .anthropicMessages),
                                   tools: tools, assembler: BrainFixtures.assembler, promptOptions: wiring.promptOptions())
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("is oat milk on my grocery list"))
        let system = model.requests[0].messages[0].text
        #expect(system.contains("- Obsidian: Search, read and write Markdown notes in a local vault"))
        #expect(system.contains("read_connected_apps takes a quick, read-only look"))
        let toolMessage = try #require(model.requests[1].messages.first { $0.role == .tool })
        #expect(toolMessage.text.contains("From Obsidian (search_notes)") && toolMessage.text.contains("Groceries.md"))
        #expect(toolMessage.text.contains("oat milk"), "\(toolMessage.text)")
        #expect(toolMessage.text.contains("\"status\":\"ok\""))
        #expect(BrainFixtures.summary(events)?.spokenLines == ["Let me look.", "Your list has oat milk and sourdough."])
        await apps.reader.hub.shutdown()
    }

    @Test func vaultSearchToleratesPluralsAndWordyRequests() async throws {
        let root = BrainContextFixtures.folder("vault-search")
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Groceries for the weekend\n- oat milk\n- two lemons\n".write(to: root.appendingPathComponent("Groceries.md"), atomically: true, encoding: .utf8)
        try "# Trip\nTram 28 from Martim Moniz.\n".write(to: root.appendingPathComponent("Trip.md"), atomically: true, encoding: .utf8)
        let vault = try ObsidianVault(root: root)
        #expect(try vault.search("grocery").map(\.note.path) == ["Groceries.md"])
        #expect(try vault.search("lemon").first?.excerpts == ["- two lemons"])
        // No note has every word: the ones with the most of them.
        let wordy = try vault.search("grocery list oat milk")
        #expect(wordy.map(\.note.path) == ["Groceries.md"])
        #expect(wordy.first?.excerpts.contains("- oat milk") == true)
        #expect(try vault.search("zebra").isEmpty)
        let tool = try await ObsidianToolSource(vault: vault).callTool("search_notes", arguments: ["query": "grocery"])
        #expect(tool.text.contains("Groceries.md") && tool.text.contains("whole note:") && tool.text.contains("  - oat milk"))
        #expect(ObsidianVault.searchRoot("stories") == "stor" && ObsidianVault.searchRoot("class") == "class")
    }

    @Test func wiringRegistersEveryToolGroupAndRecallSearchesEarlierChats() throws {
        let memoryFolder = TemporaryMemoryFolder()
        let historyFolder = BrainContextFixtures.folder("history")
        defer { try? FileManager.default.removeItem(at: historyFolder) }
        let history = HistoryStore(directory: historyFolder)
        var turn = HistoryTurn(sessionID: "s1", startedAt: MemoryFixtures.daysAgo(2), source: .voice, words: "what's a good sourdough starter ratio")
        turn.spokenLines = ["Start with equal parts flour and water by weight."]
        try history.append(turn)
        var other = HistoryTurn(sessionID: "s1", startedAt: MemoryFixtures.daysAgo(1), source: .text, words: "open my calendar")
        other.spokenLines = ["Opening it."]
        try history.append(other)

        let wiring = BrainWiring(memory: memoryFolder.store(), history: history, skills: TestSkills(""))
        #expect(wiring.tools().names == ["save_memory", "recall_memory", "forget_memory"])
        let recall = try #require(wiring.memoryTools?.handle(name: "recall_memory", arguments: #"{"query":"sourdough starter"}"#))
        let output = try JSONValue.parse(recall.output)
        let chats = try #require(output["earlier_chats"]?.arrayValue)
        #expect(chats.count == 1)
        #expect(chats[0]["user"] == "what's a good sourdough starter ratio")
        #expect(chats[0]["reply"] == "Start with equal parts flour and water by weight.")
        #expect(chats[0]["how"] == "voice")
        #expect(output["note"] == nil)
        // Without the history, recall finds nothing.
        let alone = MemoryTools(store: memoryFolder.store()).handle(name: "recall_memory", arguments: #"{"query":"sourdough starter"}"#)
        #expect(try JSONValue.parse(alone!.output)["note"] == "nothing remembered matches that")

        // "Forget everything" also keeps recall from bringing back what was said before it (and survives a relaunch:
        // a new store on the same folder reads the time back).
        try memoryFolder.store().forgetEverything()
        #expect(memoryFolder.store().forgottenAt != nil)
        let after = try #require(BrainWiring(memory: memoryFolder.store(), history: history).memoryTools?
            .handle(name: "recall_memory", arguments: #"{"query":"sourdough starter"}"#))
        let afterOutput = try JSONValue.parse(after.output)
        #expect(afterOutput["earlier_chats"] == nil)
        #expect(afterOutput["note"] == "nothing remembered matches that")
        // Chats after it are found again.
        var later = HistoryTurn(sessionID: "s2", startedAt: MemoryFixtures.now.addingTimeInterval(60), source: .text, words: "sourdough starter again")
        later.spokenLines = ["One to one, still."]
        try history.append(later)
        let again = try #require(BrainWiring(memory: memoryFolder.store(), history: history).memoryTools?
            .handle(name: "recall_memory", arguments: #"{"query":"sourdough starter"}"#))
        #expect(try JSONValue.parse(again.output)["earlier_chats"]?.arrayValue?.count == 1)
    }
}

@Test func theConnectorsFingerprintOnlyChangesWhenTheConnectorsDo() throws {
    // The app reads connectors.json before every turn and rebuilds the brain when the fingerprint changes. Each read
    // makes new dictionaries, which Swift iterates in different orders: the fingerprint must not follow that order.
    let environment = Dictionary(uniqueKeysWithValues: (0..<16).map { ("VAR_\($0)", "cred-\($0)") })
    let registry = ConnectorRegistry(connectors: [
        ConnectorConfig(id: "notes", name: "Notes", transport: .stdio(command: "/usr/bin/true", arguments: []),
                        secretHeaders: ["X-One": "a", "X-Two": "b", "X-Three": "c"], environment: environment),
    ])
    let data = try JSONEncoder().encode(registry)
    let prints = try (0..<12).map { _ in ConnectedAppsWiring.fingerprint(try JSONDecoder().decode(ConnectorRegistry.self, from: data)) }
    #expect(Set(prints).count == 1)
    var changed = registry
    changed.connectors[0].enabled = false
    #expect(ConnectedAppsWiring.fingerprint(changed) != prints[0])
}

@Test func onlySpokenProgramsAreNotDrawings() {
    #expect(!HistoryTurn.programDraws("step(1)\nsay(\"Take the red line.\")\nstep(2)\nsay('Then the green one.') // done"))
    #expect(HistoryTurn.programDraws("step(1)\nsay(\"Here.\")\ncircle(100, 100, 40)"))
    // A link in a spoken line is not a comment, and a comment that mentions a call draws nothing.
    #expect(!HistoryTurn.programDraws("say(\"The timetable is at https://www.carris.pt/en/ if you want it.\")"))
    #expect(!HistoryTurn.programDraws("// circle(1, 2, 3) later\nsay('Done.')"))
    var turn = HistoryTurn(sessionID: "s", startedAt: Date(), source: .text, words: "how do I get there")
    turn.program = "step(1)\nsay(\"Take the red line.\")"
    #expect(!turn.hasDrawing)
}

@Suite struct HomeChatOnTheBrainRuntimeTests {
    static func history() -> (HistoryStore, URL) {
        let url = BrainContextFixtures.folder("home-history")
        return (HistoryStore(directory: url), url)
    }

    @Test func typedQuestionsGoIntoTheBrainsConversation() async throws {
        let (history, folder) = Self.history()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model)
        let chat = TypedChatController(brain: runtime, history: history)
        let turn = await chat.send("what's the capital of Peru", appNotes: [TypedChatController.homeWindowNote])
        #expect(turn.sessionID == (await runtime.currentSessionID()))
        #expect(turn.outcome == .completed && turn.spokenLines == ["Done."] && turn.source == .text)
        #expect(BrainContextFixtures.lastUserText(model.requests[0]).contains("OpenClicky's Home window"))
        #expect(BrainContextFixtures.lastUserText(model.requests[0]).contains("The user typed: what's the capital of Peru"))
        // A voice turn after it lands in the same conversation (the orchestrator names it after the brain).
        let second = await chat.send("and of Chile")
        #expect(second.sessionID == turn.sessionID)
        #expect(model.requests[1].messages.count == 4) // system + one thread, not seeded again
        #expect(try history.turns(in: turn.sessionID).count == 2)
    }

    @Test func pickingAnOlderConversationMovesTheBrainThere() async throws {
        let (history, folder) = Self.history()
        defer { try? FileManager.default.removeItem(at: folder) }
        var old = HistoryTurn(sessionID: "older-chat", startedAt: Date().addingTimeInterval(-86_400), source: .voice, words: "what is a gear ratio")
        old.spokenLines = ["How many turns one gear makes per turn of the other."]
        try history.append(old)
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model)
        let chat = TypedChatController(brain: runtime, history: history)
        chat.resume(sessionID: "older-chat")
        let turn = await chat.send("and a bigger one?")
        #expect(turn.sessionID == "older-chat")
        #expect(await runtime.currentSessionID() == "older-chat")
        #expect(model.requests[0].messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(model.requests[0].messages[1].text == "The user said: what is a gear ratio")
        // Then the chat follows the brain again: the next question goes where the brain is.
        let next = await chat.send("thanks")
        #expect(next.sessionID == "older-chat")

        // A new conversation takes the id Home picked.
        await chat.startNewConversation(id: "fresh-chat")
        #expect(await runtime.currentSessionID() == "fresh-chat")
        let fresh = await chat.send("hello")
        #expect(fresh.sessionID == "fresh-chat")
        #expect(model.requests.last?.messages.count == 2)
    }

    @Test func actionsHeldForAfterTheAnswerRunOnceItIsIn() async throws {
        let (history, folder) = Self.history()
        defer { try? FileManager.default.removeItem(at: folder) }
        let opener = BrainProbeTool("open_url", kind: .deferredAction)
        let model = BrainScriptModel([[
            .text("```js\nsay(\"Opening it.\")\n```"), .call("c1", "open_url", #"{"url":"https://example.com"}"#), .finish(.stop),
        ]])
        let runtime = BrainContextFixtures.runtime(model, tools: [opener])
        let chat = TypedChatController(brain: runtime, history: history)
        let turn = await chat.send("open example.com")
        #expect(turn.deferredActions == ["open_url"])
        #expect(opener.runs.count == 1)
    }

    @Test func theRelayBuildsTheBrainFirstAndForwardsEverything() async throws {
        let relay = BrainRelay()
        let unset = try await BrainFixtures.collect(relay.run(TurnInput(words: "hi")))
        guard case .failed(let spoken, _) = unset.first else { Issue.record("\(unset)"); return }
        #expect(spoken.contains("brain model isn't set up"))

        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model)
        let prepared = TestNotes([])
        relay.setPrepare {
            prepared.set(prepared.current + ["prepared"])
            relay.brain = runtime
        }
        let events = try await BrainFixtures.collect(relay.run(TurnInput(words: "hello")))
        #expect(BrainFixtures.summary(events)?.spokenLines == ["Done."])
        #expect(prepared.current == ["prepared"])
        #expect(await relay.currentSessionID() == (await runtime.currentSessionID()))
        await relay.seedConversation([], sessionID: "picked")
        #expect(await runtime.currentSessionID() == "picked")
        let result = await relay.performDeferred(DeferredAction(callID: "x", name: "nothing", arguments: [:]))
        #expect(result["status"] != nil)
    }

    @Test func theRelaySaysWhileATurnRunsSoTheAppDoesNotSwapTheBrainUnderIt() async throws {
        let model = BrainScriptModel([[.hang]])
        let relay = BrainRelay(BrainContextFixtures.runtime(model))
        #expect(!relay.isRunning)
        let turn = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "what's this"))) }
        for _ in 0..<1_000 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.requests.isEmpty && relay.isRunning)
        turn.cancel()
        _ = await turn.value
        for _ in 0..<1_000 where relay.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!relay.isRunning)
    }
}

@Suite struct AlwaysOnContextTests {
    static func summary(_ text: String, tools: [RealtimeToolCall] = [], status: RealtimeResponseStatus = .completed,
                        input: Int = 100, output: Int = 20) -> AlwaysOnUpdate {
        .conversation(.responseFinished(RealtimeResponseSummary(responseID: UUID().uuidString, status: status, itemIDs: ["i"],
                                                                transcript: text, toolCalls: tools,
                                                                usage: RealtimeUsage(inputTokens: input, outputTokens: output))))
    }

    @Test func theTurnLogMakesOneTurnPerExchange() {
        var log = AlwaysOnTurnLog(model: "gemini-live")
        var closed: [HistoryTurn] = []
        func feed(_ update: AlwaysOnUpdate) { closed += log.apply(update) }
        feed(.state(.on))
        feed(.conversation(.state(.userSpeaking)))
        feed(.conversation(.userCaption("can you look at my screen", isFinal: false)))
        feed(.conversation(.state(.thinking)))
        feed(.conversation(.assistantCaption("One moment.")))
        feed(Self.summary("One moment.", tools: [RealtimeToolCall(callID: "t1", name: "send_to_higher_model", arguments: "{}")]))
        feed(.conversation(.tool(.started(name: "send_to_higher_model", callID: "t1", label: "Thinking deeper…"))))
        feed(.conversation(.status("Thinking deeper…")))
        // Back to listening while the tool runs: the exchange isn't over.
        feed(.conversation(.state(.listening)))
        #expect(closed.isEmpty)
        // A late final transcript still belongs to it.
        feed(.conversation(.userCaption("can you look at my screen and tell me what to bring", isFinal: true)))
        feed(.conversation(.tool(.finished(name: "send_to_higher_model", callID: "t1", succeeded: true))))
        feed(Self.summary("Bring the blue folder. It's on the note."))
        feed(.conversation(.state(.listening)))
        #expect(closed.count == 1)
        let turn = closed[0]
        #expect(turn.source == .voice && turn.words == "can you look at my screen and tell me what to bring")
        #expect(turn.spokenLines == ["One moment.", "Bring the blue folder.", "It's on the note."])
        #expect(turn.tools == ["send_to_higher_model"] && turn.statuses == ["Thinking deeper…"])
        #expect(turn.usage == HistoryUsage(input: 200, cached: 0, output: 40))
        #expect(turn.model == "gemini-live" && turn.rounds == 2 && turn.outcome == .completed)

        // Typed into the conversation; cut off; then an echo that was dropped; then always-on ends.
        closed += log.typed("what's the weather")
        feed(Self.summary("It's sunny and", status: .interrupted))
        feed(.conversation(.state(.userSpeaking)))
        feed(.conversation(.discardedTurn(reason: "echo")))
        feed(.state(.off))
        #expect(closed.count == 2)
        #expect(closed[1].source == .text && closed[1].words == "what's the weather")
        #expect(closed[1].narration == "cut off by the user")
        #expect(log.recentNote()?.contains("User: can you look at my screen and tell me what to bring\nVoice: One moment.") == true)
        #expect(log.conversation.map(\.role) == [.user, .assistant, .user, .assistant])

        // The voice speaking first (a reply to a note) is an app turn.
        var greeting = AlwaysOnTurnLog()
        _ = greeting.apply(Self.summary("Hi there."))
        let app = greeting.finish()
        #expect(app.first?.source == .app && app.first?.trigger == "always_on" && app.first?.words == "")
    }

    @MainActor
    @Test func typedHomeChatAndAlwaysOnShareOneConversationAndMemoryIsWritten() async throws {
        let folder = BrainContextFixtures.folder("shared-history")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = HistoryStore(directory: folder)
        let memoryFolder = TemporaryMemoryFolder()
        let memory = memoryFolder.store(now: { Date() })
        let model = BrainScriptModel([])
        let runtime = BrainContextFixtures.runtime(model)
        let relay = BrainRelay(runtime)

        // Home: a typed question through the shared brain.
        let typed = await TypedChatController(brain: relay, history: history).send("remind me what we said about Lisbon")

        // Always-on: one spoken exchange, recorded through the same brain's conversation.
        let writer = MemoryWriter(client: ScriptedLanguageModel(reply: #"{"session_note": "Talked about tram stops in Lisbon by voice."}"#),
                                  model: "fast")
        let recorder = AlwaysOnRecorder(history: history, sessions: relay, memory: (writer, memory), model: "gemini-live")
        recorder.onRunNote = { note in await relay.recordOutcome(note) }
        recorder.apply(.state(.on))
        recorder.apply(.conversation(.state(.userSpeaking)))
        recorder.apply(.conversation(.userCaption("where is the nearest tram stop", isFinal: true)))
        recorder.apply(Self.summary("It's two streets down, by the bakery."))
        recorder.apply(.conversation(.state(.listening)))
        #expect(recorder.recentNote()?.contains("where is the nearest tram stop") == true)
        recorder.apply(.state(.off))
        await recorder.flush()
        await recorder.ending?.value

        let turns = try history.turns(in: typed.sessionID)
        #expect(turns.map(\.source) == [.text, .voice])
        #expect(turns[1].words == "where is the nearest tram stop" && turns[1].model == "gemini-live")
        #expect(history.sessions().count == 1)
        // The session-end writer ran on the run's conversation.
        #expect(try memory.snapshot().memories.contains { $0.kind == .session && $0.text.contains("tram stops in Lisbon") })
        // The brain hears what was said by voice at its next turn.
        _ = try await BrainFixtures.collect(relay.run(TurnInput(words: "and the bus?")))
        #expect(BrainContextFixtures.lastUserText(model.requests[1]).contains("[Always-on] What the user and the always-on voice said"))
    }

    @Test func captureScreenSendsTheVoiceSizedPicture() async throws {
        let shot = TurnScreenshot(jpeg: try BrainContextFixtures.jpeg(width: 1280, height: 800), label: "main display", isCursorScreen: true,
                                  pixelSize: CGSize(width: 1280, height: 800), displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let one = await RealtimeTools.captureScreen(StaticRealtimeScreenSource(screenshot: shot))
            .run(RealtimeToolInvocation(callID: "c1", name: "capture_screen", arguments: [:]))
        #expect(one.output["width"] == 768 && one.output["height"] == 480)
        let image = try #require(one.images.first)
        #expect(ImageCoding.pixelSize(of: image.data)?.width == 768)
        #expect(image.data.count < shot.jpeg.count)

        struct TwoDisplays: RealtimeScreenSource {
            let shot: TurnScreenshot
            func captureCursorScreen() async throws -> TurnScreenshot { shot }
            var displayCount: Int { 2 }
        }
        let two = await RealtimeTools.captureScreen(TwoDisplays(shot: shot))
            .run(RealtimeToolInvocation(callID: "c2", name: "capture_screen", arguments: [:]))
        #expect(two.output["width"] == 640)
        #expect(ImageCoding.pixelSize(of: two.images[0].data)?.width == 640)
    }

    @Test func sendToHigherModelGetsThePushToTalkContext() async throws {
        let brain = RecordingBrain()
        let shot = BrainFixtures.screenshot()
        let context = TurnContext(frontApp: "Pages", windowTitle: "Report.pages", documentText: "Quarterly report draft",
                                  elements: [TurnElement(id: "e3", role: "button", label: "Save", frame: CGRect(x: 600, y: 10, width: 40, height: 20))])
        let look = StaticRealtimeBrainLook(screenshots: [shot], context: context, notes: { ["[Always-on so far] User: hi"] })
        let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: nil, look: look)
        let outcome = await tool.run(RealtimeToolInvocation(callID: "c1", name: "send_to_higher_model", arguments: ["question": "where's save"]))
        #expect(outcome.succeeded)
        let input = try #require(brain.inputs.first)
        #expect(input.screenshots == [shot])
        #expect(input.context.frontApp == "Pages" && input.context.windowTitle == "Report.pages")
        #expect(input.context.elements.map(\.id) == ["e3"] && input.context.documentText == "Quarterly report draft")
        #expect(input.context.trigger == "realtime_voice")
        #expect(input.appNotes.contains("[Always-on so far] User: hi"))
        _ = await tool.run(RealtimeToolInvocation(callID: "c2", name: "send_to_higher_model",
                                                  arguments: ["question": "what app is this", "include_screen": false]))
        #expect(brain.inputs[1].screenshots.isEmpty && brain.inputs[1].context.frontApp == "Pages")
    }

    @Test func instructionsCarryMemorySkillsAndTheAgentTools() {
        let text = RealtimeInstructions.alwaysOn(memory: "<user_memory>\n- Lives in Lisbon\n</user_memory>",
                                                 skills: BrainContextFixtures.pitchDecks,
                                                 toolNames: ["sessions_spawn", ReadConnectedApps.toolName])
        #expect(text.contains("Lives in Lisbon"))
        #expect(text.contains("Active skills. When a request is in one of these areas") && text.contains("Pitch decks (for Keynote)"))
        #expect(text.contains("call sessions_spawn with a complete brief"))
        #expect(text.contains("read_connected_apps takes a quick, read-only look"))
        #expect(RealtimeInstructions.skillUpdate(BrainContextFixtures.physics).hasPrefix("[Skill update] The active skills are now the ones below"))
        #expect(RealtimeInstructions.skillUpdate("").hasPrefix("[Skill update] No skills are active now"))
    }

    @Test func theToolboxOffersJobsAndConnectedApps() async throws {
        let temp = AgentTempDir()
        let manager = AgentManager(store: AgentJobStore(paths: temp.paths)) { _ in throw AgentManagerError.emptyTask }
        let agents = AgentTools(manager: manager)
        let vault = BrainContextFixtures.folder("rt-vault")
        defer { try? FileManager.default.removeItem(at: vault) }
        let apps = ConnectedAppsWiring.make(registry: ConnectorRegistry(obsidian: ObsidianSettings(vaultPath: vault.path)),
                                            credentials: InMemoryCredentialStore())
        let toolbox = RealtimeToolbox.standard(screen: nil, brain: nil, agents: agents, connectedApps: (apps.reader, apps.apps))
        let names = toolbox.specs.map(\.name)
        #expect(names.contains("sessions_spawn") && names.contains("find_jobs") && names.contains("show_result"))
        #expect(names.contains(ReadConnectedApps.toolName))
        let find = try #require(toolbox.tools.first { $0.name == "find_jobs" })
        let found = await find.run(RealtimeToolInvocation(callID: "f1", name: "find_jobs", arguments: [:]))
        #expect(found.output["status"] != nil)
        let show = try #require(toolbox.tools.first { $0.name == "show_result" })
        let held = await show.run(RealtimeToolInvocation(callID: "s1", name: "show_result", arguments: ["job_id": "nope"]))
        #expect(held.deferred != nil && held.output["status"] == "queued")
        await apps.reader.hub.shutdown()
    }
}

@Suite struct MemoryReachesAgentsTests {
    @Test func agentsGetTheProfileAsBackgroundAndItsPath() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        #expect(MemoryAgentBrief.section(store: store) == "")
        _ = try store.addToProfile("Product designer at a small studio", section: "Role & work")
        _ = try store.addStanding("Use metric units")
        _ = try store.saveHowTo(title: "Export the weekly report", steps: "1. Open Numbers\n2. Export as PDF")
        let section = MemoryAgentBrief.section(store: store)
        #expect(section.hasPrefix("# About the user\n"))
        #expect(section.contains("background only") && section.contains("Follow the standing context") && section.contains("<user_memory>"))
        #expect(section.contains("Product designer at a small studio") && section.contains("Use metric units"))
        #expect(section.contains("The full profile: \(store.profileURL.path)"))
        #expect(section.contains(store.howTosURL.path))
    }

    @Test func sessionNotesKeepTheirConversationID() throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let id = "40A56F59-B6B4-43D0-8A57-AFEAB3E397F4"
        _ = try store.save("Talked about Lisbon trams.", kind: .session, source: .session, sessionID: id)
        _ = try store.save("Another note.", kind: .session, source: .session, sessionID: "token sk-proj-AbCdEf0123456789GhIjKlMn")
        let memories = try store.snapshot().memories
        #expect(memories.first { $0.text.hasPrefix("Talked") }?.sessionID == id)
        #expect(memories.first { $0.text.hasPrefix("Another") }?.sessionID?.contains("sk-proj") == false)
    }

    @Test func finishedJobsCanLeaveAHowTo() async throws {
        let folder = TemporaryMemoryFolder()
        let store = folder.store()
        let report = AgentJobReport(jobID: "job-1", run: 1, title: "Weekly report", outcome: .done, spoken: "Your report is ready.",
                                    markdown: "Exported the sheet as PDF from Numbers and saved it to Reports.",
                                    startedAt: MemoryFixtures.now, finishedAt: MemoryFixtures.now)
        let model = ScriptedLanguageModel(reply: #"{"howto": {"title": "Export the weekly report", "steps": "1. Open the sheet in Numbers\n2. File > Export To > PDF"}}"#)
        let learner = AgentHowToLearner(client: model, model: "fast")
        let outcome = try await learner.learn(from: report, store: store)
        #expect(outcome?.entry?.text.contains("Export the weekly report") == true)
        #expect(try store.snapshot().howTos.map(\.title) == ["Export the weekly report"])
        #expect(model.requests.first?.messages.last?.text.contains("Exported the sheet as PDF") == true)

        // The steps often live in the file the job wrote: text deliverables ride along.
        let folder2 = BrainContextFixtures.folder("deliverable")
        defer { try? FileManager.default.removeItem(at: folder2) }
        let steps = folder2.appendingPathComponent("word-to-pdf.md")
        try "1. textutil -convert html file.docx\n2. cupsfilter file.html > file.pdf\n".write(to: steps, atomically: true, encoding: .utf8)
        var withFile = report
        withFile.files = [steps.path, folder2.appendingPathComponent("chart.png").path, "https://example.com/page"]
        let reader = ScriptedLanguageModel(reply: #"{"howto": null}"#)
        _ = try await AgentHowToLearner(client: reader, model: "fast").learn(from: withFile, task: "I do this every week", store: store)
        let sent = reader.requests.first?.messages.last?.text ?? ""
        #expect(sent.hasPrefix("What the job was asked: I do this every week\n<job title="))
        #expect(sent.contains("<file name=\"word-to-pdf.md\">") && sent.contains("cupsfilter file.html"))
        #expect(!sent.contains("chart.png") && !sent.contains("example.com"))

        let nothing = AgentHowToLearner(client: ScriptedLanguageModel(reply: #"{"howto": null}"#), model: "fast")
        #expect(try await nothing.learn(from: report, store: store) == nil)
        var failed = report
        failed.outcome = .failed
        #expect(try await learner.learn(from: failed, store: store) == nil)
        #expect(AgentHowToLearner.parse("```json\n{\"howto\": {\"title\": \"T\", \"steps\": \"1. a\"}}\n```")?.title == "T")
        #expect(AgentHowToLearner.parse("no json here") == nil)
        #expect(AgentHowToLearner.parse(#"{"howto": {"title": "T", "steps": "1. a\\n2. b"}}"#)?.steps == "1. a\n2. b")
        #expect(AgentHowToLearner.parse(#"{"howto": {"title": "T", "steps": ["Open it", "Export"]}}"#)?.steps == "1. Open it\n2. Export")
    }

    @Test func jobsStartingAndComingBackAreKeptInTheConversation() throws {
        let folder = BrainContextFixtures.folder("handoffs")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = HistoryStore(directory: folder)
        var spoken = HistoryTurn(sessionID: "s1", startedAt: MemoryFixtures.now, source: .voice, words: "find me flights to Lisbon")
        spoken.spokenLines = ["I've started a job for that."]
        try history.append(spoken)

        var tracker = HistoryHandOffTracker()
        let start = MemoryFixtures.now.addingTimeInterval(2)
        let record = AgentJobRecord(id: "job-1", kind: .job, title: "Find flights", task: "Find flights to Lisbon in May",
                                    harness: .claudeCode, model: nil, provider: "anthropic", status: .running, createdAt: start,
                                    updatedAt: start, runs: [AgentRun(ask: "Find flights to Lisbon in May", startedAt: start)],
                                    folderPath: folder.appendingPathComponent("job-1").path)
        let firstSeen = tracker.observe(.job(record))
        var started = try #require(firstSeen)
        let again = tracker.observe(.job(record))
        #expect(again == nil) // the same run once
        started.sessionID = "s1"
        try history.append(started)
        let report = AgentJobReport(jobID: "job-1", run: 1, title: "Find flights", outcome: .done, spoken: "Three options under 400 euros.",
                                    files: ["/tmp/flights.md"], startedAt: start, finishedAt: start.addingTimeInterval(60))
        let cameBack = tracker.observe(.report(report))
        var back = try #require(cameBack)
        let twice = tracker.observe(.report(report))
        #expect(twice == nil)
        back.sessionID = "s1"
        try history.append(back)

        let handOffs = try history.handOffs(in: "s1")
        #expect(handOffs.map(\.kind) == [.started, .cameBack])
        #expect(handOffs[0].task == "Find flights to Lisbon in May" && handOffs[0].summary == "Started: Find flights")
        #expect(handOffs[1].summary == "Came back (done): Find flights: Three options under 400 euros.")
        #expect(handOffs[1].files == ["/tmp/flights.md"])
        // Hand-offs don't count as turns, and the turns read as before.
        #expect(try history.turns(in: "s1").count == 1)
        #expect(history.sessions().first?.turnCount == 1)
        #expect(history.sessions().first?.updatedAt == start.addingTimeInterval(60))
    }
}

extension BrainFixtures {
    static func collect(_ stream: AsyncThrowingStream<TurnEvent, Error>) async throws -> [TurnEvent] {
        var events: [TurnEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

/// The `[Your routines]` note reaches the brain with the jobs note, and again only when the routines change.
@Test func routinesNoteReachesTheBrainWhenRoutinesChange() async throws {
    let temp = AgentTempDir()
    let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: []) { _ in
        AgentLaunchSettings(harness: .codex, model: nil, providerID: AgentLaunchSettings.loginProviderID, auth: .harnessLogin)
    }
    let coordinator = AgentCoordinator(manager: manager, routineStore: RoutineStore(url: temp.paths.routines), onReports: { _ in })
    let model = BrainScriptModel([])
    let runtime = BrainContextFixtures.runtime(model, sources: BrainContextSources(turnNotes: BrainWiring.jobNotes(coordinator)))

    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("hi"))
    #expect(BrainContextFixtures.lastUserText(model.requests[0]).contains("[Your routines] None set up."))

    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("anything new"))
    #expect(!BrainContextFixtures.lastUserText(model.requests[1]).contains("[Your routines]"))

    let routine = try await coordinator.routines.create(title: "Inbox digest", task: "Summarize unread mail", schedule: .every(minutes: 60))
    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("and now"))
    let third = BrainContextFixtures.lastUserText(model.requests[2])
    #expect(third.contains("[Your routines] Tasks that run on this Mac on a schedule"))
    #expect(third.contains("\"Inbox digest\" [\(routine.id)]: every hour"))

    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("ok"))
    #expect(!BrainContextFixtures.lastUserText(model.requests[3]).contains("[Your routines]"))

    try await coordinator.routines.setPaused(routine.id, true)
    _ = try await BrainFixtures.events(runtime, BrainFixtures.input("paused?"))
    #expect(BrainContextFixtures.lastUserText(model.requests[4]).contains("every hour, paused"))
}

/// The brain is only ever told about `figure()`: there is no `scene3d()` API, so no prompt section or app note names it.
@Test func noPromptOrNoteMentionsScene3D() throws {
    let assembler = try BrainPromptAssembler()
    var texts = [BrainContextSources.figuresStoppedNote, BrainContextSources.figuresBackNote, BrainInstructions.noFigures, BrainInstructions.figuresIntro]
    for available in [true, false] {
        let options = BrainPromptOptions(figuresAvailable: available, toolGroups: Set(BrainToolGroup.allCases), connectedApps: ["Notion"])
        texts += assembler.systemSections(options).map(\.text)
    }
    for text in texts {
        #expect(!text.lowercased().contains("scene3d"), "\(text.prefix(120))")
    }
    #expect(BrainContextSources.figuresBackNote.contains("figure()"))
    #expect(BrainContextSources.figuresStoppedNote.contains("figure()"))
}
