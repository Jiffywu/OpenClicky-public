import Foundation
import Testing
@testable import OpenClickyKit

/// Cases found in review: valid programs the prose filter must leave alone, background work that must not change the
/// thread under a running turn, and session-end work that must not hold up the next turn.
@Suite("Brain runtime: review fixes")
struct BrainReviewTests {
    // MARK: Prose filter

    @Test func propertiesOfMultiLineCallsAreCodeNotProse() {
        var filter = ProgramLineFilter()
        let program = """
        const card = paper(260, 120, 800, 580, {
          title: "Linear vs exponential growth",
          board: "grid"
        })
        callout(400, 300, {
          text: "Click here to save your work",
        })
        const steps = [
          "Open the File menu first",
          "Then choose Save As here",
        ]
        The newest version is Swift six point four.
        say("ok")
        """
        let kept = filter.feed(program) + filter.finish()
        #expect(kept.contains("title: \"Linear vs exponential growth\""))
        #expect(kept.contains("text: \"Click here to save your work\""))
        #expect(kept.contains("\"Then choose Save As here\","))
        #expect(!kept.contains("The newest version"))
        #expect(filter.dropped == ["The newest version is Swift six point four."])
    }

    @Test func bracketsInsideStringsAndCommentsDoNotHideProse() {
        var filter = ProgramLineFilter()
        let program = """
        say("Press ( to open a group, it's easy")
        label(10, 10, "a { b") // an open ( in a comment
        Swift 6.4 is the newest release of the language.
        """
        let kept = filter.feed(program) + filter.finish()
        #expect(filter.dropped == ["Swift 6.4 is the newest release of the language."])
        #expect(kept.contains("say("))
    }

    // MARK: Compaction timing

    @Test func aCompactionThatFinishesDuringATurnWaitsForTheTurnToEnd() async throws {
        let sizes = [61_000, 62_000, 63_000]
        let toolGate = BrainGate()
        let compactionGate = BrainGate()
        var scripts: [[BrainScriptModel.Step]] = (1...3).map { n in
            [.text(BrainFixtures.program("say(\"Answer \(n).\")")), .usage(input: sizes[n - 1], cached: 0, output: 5), .finish(.stop)]
        }
        // Turn 4 calls a slow read; the compaction scheduled after turn 3 lands while it runs.
        scripts.append([.text("```js\nsay(\"Let me check.\")\n```"), .call("c1", "slow_read", "{}"), .finish(.toolCalls)])
        scripts.append([.text("```js\nstep(2)\nsay(\"Found it.\")\n```"), .finish(.stop)])
        let model = BrainScriptModel(scripts)
        let fast = BrainScriptModel([[.wait(compactionGate), .text("Goals:\n- Gears"), .finish(.stop)]])
        let read = ClosureBrainTool(spec: ToolSpec(name: "slow_read", description: "Slow.", parameters: ["type": "object", "properties": [:]]),
                                    kind: .read) { _, _ in
            await toolGate.wait()
            return ["status": "ok", "value": 1]
        }
        let runtime = BrainFixtures.runtime(model, tools: [read], compactor: BrainCompactor(client: fast, model: "fast")) {
            $0.compactionThreshold = 60_000
            $0.compactionStep = 1_000
            $0.compactionKeepTurns = 1
        }
        for n in 1...3 { _ = try await BrainFixtures.events(runtime, BrainFixtures.input("question \(n)")) }

        let turn = Task { try await BrainFixtures.events(runtime, BrainFixtures.input("question 4")) }
        // Wait until the read is running (round 0 sent, round 1 not yet), then let the compaction finish.
        for _ in 0..<300 where model.requests.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        compactionGate.open()
        for _ in 0..<300 where fast.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        let during = await runtime.currentSession
        #expect(during.compactions == 0, "the thread changed under a running turn")
        toolGate.open()
        let events = try await turn.value
        #expect(BrainFixtures.summary(events)?.spokenLines == ["Let me check.", "Found it."])

        // Round 1 of turn 4 extends round 0's request byte for byte: nothing before it was rewritten mid-turn.
        let round0 = model.requests[3].messages, round1 = model.requests[4].messages
        #expect(Array(round1.prefix(round0.count)) == round0)

        await runtime.waitForBackgroundWork()
        let after = await runtime.currentSession
        #expect(after.compactions == 1)
        #expect(after.items.first?.isSummary == true)
        // The fold was chosen after turn 3 (keep one turn), so turns 3 and 4 follow the note.
        #expect(after.items.compactMap(\.words) == ["question 3", "question 4"])
    }

    @Test func anAppNoteInsideATurnIsNotAFoldBoundary() {
        func item(_ seq: Int, _ message: ChatMessage, words: String? = nil) -> BrainThreadItem {
            BrainThreadItem(seq: seq, turn: 0, at: Date(), message: message, words: words)
        }
        let items = [
            item(1, .user(.text("a")), words: "a"), item(2, .assistant("x")),
            item(3, .user(.text("b")), words: "b"), item(4, .assistant("prose")),
            item(5, .user(.text(BrainRuntime.proseNote))), item(6, .assistant("y")),
            item(7, .user(.text("c")), words: "c"), item(8, .assistant("z")),
        ]
        // Keeping one turn folds a and b; the [App] note stays with the reply it is about, inside turn b.
        #expect(BrainCompactor.foldBoundary(items, keepTurns: 1) == 6)
        #expect(BrainCompactor.foldBoundary(items, keepTurns: 2, minimumFoldedTurns: 1) == 2)
    }

    // MARK: Session end off the turn's path

    @Test func theFirstTurnAfterAQuietSpellDoesNotWaitForMemoryNotes() async throws {
        let folder = BrainTemporaryFolder()
        let memoryFolder = TemporaryMemoryFolder()
        let memoryStore = memoryFolder.store()
        let writerGate = BrainGate()
        let writerModel = BrainScriptModel([[.wait(writerGate), .text("{\"session_note\": \"Picked the Pro plan.\"}"), .finish(.stop)]])
        let memory = BrainMemory(store: memoryStore, writer: MemoryWriter(client: writerModel, model: "fast"))
        let clock = BrainClock()
        let model = BrainScriptModel([])
        let runtime = BrainFixtures.runtime(model, store: folder.store, memory: memory, clock: clock) { $0.idleTimeout = 600 }
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("which plan should I buy"))
        let firstID = await runtime.currentSession.id

        clock.advance(601)
        // The memory writer is stuck; the new turn must still run and finish.
        let started = ContinuousClock.now
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("hello again"))
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(BrainFixtures.summary(events) != nil)
        #expect(await runtime.currentSession.id != firstID)

        writerGate.open()
        await runtime.waitForBackgroundWork()
        #expect(writerModel.requests.count == 1)
        #expect(try folder.store.load(firstID).ended)
        #expect(try memoryStore.list().contains { $0.text.contains("Pro plan") })
    }

    @Test func aSessionLeftFromLastLaunchIsNotedWithoutHoldingUpTheFirstTurn() async throws {
        let folder = BrainTemporaryFolder()
        let memoryFolder = TemporaryMemoryFolder()
        let memoryStore = memoryFolder.store()
        let clock = BrainClock()
        let earlier = BrainFixtures.runtime(BrainScriptModel([]), store: folder.store, clock: clock) { $0.idleTimeout = 600 }
        _ = try await BrainFixtures.events(earlier, BrainFixtures.input("remember my sister is called Ana"))
        let staleID = await earlier.currentSession.id

        clock.advance(3_600)
        let writerGate = BrainGate()
        let writerModel = BrainScriptModel([[.wait(writerGate), .text("{\"session_note\": \"Sister: Ana.\"}"), .finish(.stop)]])
        let memory = BrainMemory(store: memoryStore, writer: MemoryWriter(client: writerModel, model: "fast"))
        let runtime = BrainFixtures.runtime(BrainScriptModel([]), store: folder.store, memory: memory, clock: clock) { $0.idleTimeout = 600 }
        let started = ContinuousClock.now
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("good morning"))
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(BrainFixtures.summary(events) != nil)
        #expect(await runtime.currentSession.id != staleID)

        writerGate.open()
        await runtime.waitForBackgroundWork()
        #expect(try folder.store.load(staleID).ended)
        #expect(writerModel.requests.count == 1)
    }

    @Test func endSessionStillWaitsForItsMemoryNotes() async throws {
        let memoryFolder = TemporaryMemoryFolder()
        let memoryStore = memoryFolder.store()
        let writerModel = BrainScriptModel([[.sleep(.milliseconds(200)), .text("{\"session_note\": \"Talked about gears.\"}"), .finish(.stop)]])
        let memory = BrainMemory(store: memoryStore, writer: MemoryWriter(client: writerModel, model: "fast"))
        let runtime = BrainFixtures.runtime(BrainScriptModel([]), memory: memory)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("how do gears work"))
        await runtime.endSession()
        #expect(writerModel.requests.count == 1)
        #expect(try memoryStore.list().contains { $0.text.contains("gears") })
    }

    @Test func seedingAConversationEndsTheCurrentOneWithItsMemoryNotes() async throws {
        let folder = BrainTemporaryFolder()
        let memoryFolder = TemporaryMemoryFolder()
        let memoryStore = memoryFolder.store()
        let writerModel = BrainScriptModel([[.text("{\"session_note\": \"Planned a trip to Lisbon.\"}"), .finish(.stop)]])
        let memory = BrainMemory(store: memoryStore, writer: MemoryWriter(client: writerModel, model: "fast"))
        let runtime = BrainFixtures.runtime(BrainScriptModel([]), store: folder.store, memory: memory)
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("help me plan a trip to Lisbon"))
        let voiceID = await runtime.currentSession.id

        var picked = HistoryTurn(id: UUID().uuidString, sessionID: "h1", startedAt: Date(timeIntervalSince1970: 1_793_300_000),
                                 source: .text, words: "what's a monad")
        picked.spokenLines = ["A monad wraps a value."]
        picked.outcome = .completed
        await runtime.seedConversation([picked])
        await runtime.waitForBackgroundWork()
        #expect(await runtime.currentSession.id != voiceID)
        #expect(try folder.store.load(voiceID).ended)
        #expect(writerModel.requests.count == 1)
        #expect(try memoryStore.list().contains { $0.text.contains("Lisbon") })
    }

    // MARK: Picking up the newest session

    @Test func theNewestSessionIsFoundByItsLastSaveAndBrokenFilesAreSkipped() async throws {
        let folder = BrainTemporaryFolder()
        let clock = BrainClock()
        let first = BrainFixtures.runtime(BrainScriptModel([]), store: folder.store, clock: clock)
        _ = try await BrainFixtures.events(first, BrainFixtures.input("older"))
        clock.advance(30)
        let second = BrainFixtures.runtime(BrainScriptModel([]), store: folder.store, clock: clock, resume: false)
        _ = try await BrainFixtures.events(second, BrainFixtures.input("newer"))
        let newerID = await second.currentSession.id
        #expect(folder.store.latest()?.id == newerID)

        // A newer folder whose thread can't be read is passed over.
        let broken = folder.store.directory(for: "broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: folder.store.threadURL(for: "broken"))
        #expect(folder.store.latest()?.id == newerID)
    }
}
