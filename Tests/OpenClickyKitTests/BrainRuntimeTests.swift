import Foundation
import Testing
@testable import OpenClickyKit

@Suite("Brain runtime: turn loop")
struct BrainRuntimeTests {
    @Test func eventsComeInOrderAndTheProgramLosesItsFences() async throws {
        let model = BrainScriptModel([[
            .text("```js\nstep(1)\nsay(\"The Share"), .text(" button is top right.\")\npoint(1180, 52, \"Share\")\n"),
            .text("step(2)\nsay('Click it to invite people.')\n```"), .usage(input: 1200, cached: 900, output: 80), .finish(.stop),
        ]])
        let runtime = BrainFixtures.runtime(model)
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Where is the share button?"))

        let kinds = events.map { event -> String in
            switch event {
            case .programDelta: "program"
            case .sayLine(let index, _): "say\(index)"
            case .roundFinished(let round): "round\(round)"
            case .finished: "finished"
            default: "other"
            }
        }
        #expect(kinds.filter { $0 != "program" } == ["say0", "say1", "round0", "finished"])
        #expect(kinds.firstIndex(of: "say0")! > kinds.firstIndex(of: "program")!)
        let summary = try #require(BrainFixtures.summary(events))
        #expect(!summary.program.contains("```"))
        #expect(summary.program.hasPrefix("step(1)\nsay(\"The Share button is top right.\")"))
        #expect(summary.spokenLines == ["The Share button is top right.", "Click it to invite people."])
        #expect(summary.rounds == 1)
        #expect(summary.usage == TokenUsage(inputTokens: 1200, cachedInputTokens: 900, outputTokens: 80))
        #expect(summary.model == "test-brain")
        #expect(summary.firstTokenSeconds != nil)
        let deltas = events.compactMap { if case .programDelta(let text) = $0 { text } else { nil } }.joined()
        #expect(deltas == summary.program)
    }

    @Test func sayLinesStreamBeforeTheProgramEnds() async throws {
        let gate = BrainGate()
        let model = BrainScriptModel([[
            .text("```js\nstep(1)\nsay(\"First line, right away.\")\n"), .wait(gate),
            .text("box(100, 100, 200, 120, {label: \"later\"})\n```"), .finish(.stop),
        ]])
        let runtime = BrainFixtures.runtime(model)
        var events: [TurnEvent] = []
        for try await event in runtime.run(BrainFixtures.input("Explain")) {
            events.append(event)
            if case .sayLine(0, _) = event { gate.open() }
        }
        #expect(gate.openedByTest)
        let sayIndex = try #require(events.firstIndex { if case .sayLine(0, _) = $0 { true } else { false } })
        let boxIndex = try #require(events.firstIndex { if case .programDelta(let text) = $0 { text.contains("box(") } else { false } })
        #expect(sayIndex < boxIndex)
    }

    @Test func readsGoBackToTheModelInAnotherRoundAndTheProgramContinues() async throws {
        let lookup = BrainProbeTool("web_search", kind: .read, result: ["status": "ok", "answer": "42 degrees"], status: "Searching the web…")
        let model = BrainScriptModel([
            [.text("```js\nstep(1)\nsay(\"Let me check.\")\n```"), .call("c1", "web_search", "{\"query\":\"temp\"}"), .finish(.toolCalls)],
            [.text("```js\nstep(2)\nsay(\"It's 42 degrees.\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [lookup])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("How warm is it?"))

        #expect(lookup.runs.count == 1)
        #expect(model.requests.count == 2)
        let second = model.requests[1].messages
        let toolMessage = try #require(second.last)
        #expect(toolMessage.role == .tool && toolMessage.toolCallID == "c1")
        #expect(toolMessage.text.contains("42 degrees"))
        #expect(second[second.count - 2].toolCalls.map(\.id) == ["c1"])
        #expect(events.contains(.status("Searching the web…")))
        #expect(events.contains(.toolStarted(name: "web_search", callID: "c1")))
        #expect(events.contains(.toolFinished(name: "web_search", callID: "c1", succeeded: true)))
        #expect(events.contains(.roundFinished(0)) && events.contains(.roundFinished(1)))
        let summary = try #require(BrainFixtures.summary(events))
        #expect(summary.rounds == 2)
        #expect(summary.spokenLines == ["Let me check.", "It's 42 degrees."])
        #expect(summary.program == "step(1)\nsay(\"Let me check.\")\nstep(2)\nsay(\"It's 42 degrees.\")\n")
        let lines = events.compactMap { if case .sayLine(let index, _) = $0 { index } else { nil } }
        #expect(lines == [0, 1])
    }

    @Test func resultsGoBackInTheOrderTheCallsStarted() async throws {
        let slow = BrainProbeTool("slow_read", kind: .read, delay: .milliseconds(150), result: ["status": "ok", "which": "slow"])
        let fast = BrainProbeTool("fast_read", kind: .read, result: ["status": "ok", "which": "fast"])
        let model = BrainScriptModel([
            [.text("```js\nsay(\"One moment.\")\n```"), .call("a", "slow_read", "{}"), .call("b", "fast_read", "{}"), .finish(.toolCalls)],
            [.text("```js\nsay(\"Here.\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [slow, fast])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Both please"))
        let toolMessages = model.requests[1].messages.filter { $0.role == .tool }
        #expect(toolMessages.map(\.toolCallID) == ["a", "b"])
        #expect(toolMessages[0].text.contains("slow") && toolMessages[1].text.contains("fast"))
        let finished = events.compactMap { if case .toolFinished(_, let id, _) = $0 { id } else { nil } }
        #expect(finished == ["a", "b"])
    }

    @Test func actionsRunWithoutAnotherRound() async throws {
        let copy = BrainProbeTool("copy_to_clipboard", kind: .action, result: ["status": "copied"])
        let model = BrainScriptModel([
            [.text("```js\nsay(\"Copied it for you.\")\n```"), .call("c1", "copy_to_clipboard", "{\"text\":\"hi\"}"), .finish(.toolCalls)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [copy])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Copy hi"))
        #expect(model.requests.count == 1)
        #expect(copy.runs.count == 1)
        #expect(BrainFixtures.summary(events)?.rounds == 1)
        // The thread still answers the call, so the next request is valid.
        let session = await runtime.currentSession
        #expect(session.messages.last?.role == .tool)
        #expect(session.messages.last?.text.contains("copied") == true)
    }

    @Test func screenChangingActionsAreDeferredUntilNarrationAndFailuresBecomeAppNotes() async throws {
        let open = BrainProbeTool("open_url", kind: .deferredAction, result: ["status": "failed", "message": "No browser."])
        let model = BrainScriptModel([
            [.text("```js\nsay(\"I'll open it for you.\")\n```"), .call("c9", "open_url", "{\"url\":\"https://example.com\"}"), .finish(.toolCalls)],
            [.text("```js\nsay(\"Sorry about that.\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model, tools: [open])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Open example.com"))

        let deferred = events.compactMap { if case .deferredAction(let action) = $0 { action } else { nil } }
        #expect(deferred == [DeferredAction(callID: "c9", name: "open_url", arguments: ["url": "https://example.com"])])
        #expect(open.runs.isEmpty)
        #expect(model.requests.count == 1)
        let queued = await runtime.currentSession.messages.last
        #expect(queued?.text.contains("queued") == true)

        // The orchestrator runs it after the narration; it fails, so the next turn hears about it.
        let result = await runtime.performDeferred(deferred[0])
        #expect(open.runs.count == 1)
        #expect(result["status"] == "failed")
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("Did it open?"))
        let notes = model.requests[1].messages.last?.content.first.flatMap { if case .text(let text) = $0 { text } else { nil } } ?? ""
        #expect(notes.contains("[App] open_url did not work (failed). No browser."))
    }

    @Test func backgroundCallsDoNotHoldTheTurn() async throws {
        let save = BrainProbeTool("save_memory", kind: .async, delay: .milliseconds(100), result: ["status": "refused", "message": "secret"])
        let model = BrainScriptModel([[.text("```js\nsay(\"I'll remember that.\")\n```"), .call("m1", "save_memory", "{\"text\":\"x\"}"), .finish(.toolCalls)]])
        let runtime = BrainFixtures.runtime(model, tools: [save])
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Remember x"))
        #expect(BrainFixtures.summary(events) != nil)
        #expect(await runtime.currentSession.messages.last?.text.contains("started") == true)
        await runtime.waitForBackgroundWork()
        #expect(save.runs.count == 1)
        #expect(await runtime.currentSession.pendingAppNotes == ["[App] save_memory did not work (refused). secret"])
    }

    @Test func toolCallsBeyondTheCapDoNotRun() async throws {
        let act = BrainProbeTool("act", kind: .action)
        let model = BrainScriptModel([[
            .text("```js\nsay(\"Doing it.\")\n```"), .call("1", "act", "{}"), .call("2", "act", "{}"), .call("3", "act", "{}"), .finish(.toolCalls),
        ]])
        let runtime = BrainFixtures.runtime(model, tools: [act]) { $0.maxToolCallsPerTurn = 2 }
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("Go"))
        #expect(act.runs.count == 2)
        let results = await runtime.currentSession.messages.filter { $0.role == .tool }
        #expect(results.count == 3)
        #expect(results[2].text.contains("tool_limit_reached"))
        #expect(results[2].isError)
    }

    @Test func roundsStopAtTheCap() async throws {
        let read = BrainProbeTool("look", kind: .read)
        let again = [BrainScriptModel.Step.text("```js\nsay(\"Still looking.\")\n```"), .call(UUID().uuidString, "look", "{}"), .finish(.toolCalls)]
        let model = BrainScriptModel([again, again, again, again])
        let runtime = BrainFixtures.runtime(model, tools: [read]) { $0.maxRounds = 2 }
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Look"))
        #expect(model.requests.count == 2)
        #expect(read.runs.count == 1) // the read in the last round is answered without running
        #expect(BrainFixtures.summary(events)?.rounds == 2)
    }

    @Test func cancellingStopsTheModelAndToolsAndKeepsTheThreadValid() async throws {
        let stuck = BrainProbeTool("slow_lookup", kind: .read, delay: .seconds(30), ignoresCancellation: true)
        let model = BrainScriptModel([[
            .text("```js\nsay(\"Let me look.\")\n"), .call("s1", "slow_lookup", "{}"), .hang,
        ]])
        let runtime = BrainFixtures.runtime(model, tools: [stuck])
        let consumer = Task { () -> [TurnEvent] in
            var seen: [TurnEvent] = []
            for try await event in runtime.run(BrainFixtures.input("Find it")) {
                seen.append(event)
            }
            return seen
        }
        // Let the turn reach the hanging model and the stuck tool, then cancel.
        for _ in 0..<200 where stuck.runs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        consumer.cancel()
        let started = ContinuousClock.now
        _ = try? await consumer.value
        // Wait for the runtime's bookkeeping (it does not wait for the stuck tool).
        for _ in 0..<200 {
            if await runtime.currentSession.messages.last?.role == .tool { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(model.cancelledStreams == 1)
        let messages = await runtime.currentSession.messages
        let assistant = try #require(messages.last { $0.role == .assistant })
        #expect(assistant.toolCalls.map(\.id) == ["s1"])
        let result = try #require(messages.last)
        #expect(result.toolCallID == "s1" && result.text.contains("cancelled"))
    }

    @Test func aNewTurnCancelsTheRunningOne() async throws {
        let model = BrainScriptModel([
            [.text("```js\nsay(\"First.\")\n"), .hang],
            [.text("```js\nsay(\"Second.\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model)
        let first = Task { try await BrainFixtures.events(runtime, BrainFixtures.input("one")) }
        for _ in 0..<200 where model.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let second = try await BrainFixtures.events(runtime, BrainFixtures.input("two"))
        _ = try? await first.value
        #expect(BrainFixtures.summary(second)?.spokenLines == ["Second."])
        #expect(model.cancelledStreams == 1)
        let users = await runtime.currentSession.items.filter { $0.message.role == .user }.compactMap(\.words)
        #expect(users == ["one", "two"])
    }

    @Test func providerErrorsBecomeAShortSpokenSentence() async throws {
        let model = BrainScriptModel([[.fail(ProviderError(provider: "anthropic", status: 429, message: "slow down"))]])
        let runtime = BrainFixtures.runtime(model)
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("Hello"))
        guard case .failed(let spoken, let detail)? = events.last else { Issue.record("expected failed, got \(events)"); return }
        #expect(spoken.contains("too many requests"))
        #expect(detail.contains("429"))
    }

    @Test func proseInsteadOfCodeGetsOneRoundToContinueAsAProgram() async throws {
        let model = BrainScriptModel([
            [.text("```js\nsay(\"Let me look that up.\")\n\nThe newest version is Swift 6.4, released in September.\n"), .finish(.stop)],
            [.text("```js\nstep(2)\nsay(\"Swift 6.4 is the newest version.\")\n```"), .finish(.stop)],
            [.text("```js\nsay(\"unused\")\n```"), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model)
        let events = try await BrainFixtures.events(runtime, BrainFixtures.input("newest swift?"))
        #expect(model.requests.count == 2)
        #expect(model.requests[1].messages.last?.text.contains("plain sentences") == true)
        let summary = try #require(BrainFixtures.summary(events))
        #expect(summary.spokenLines == ["Let me look that up.", "Swift 6.4 is the newest version."])
        #expect(summary.rounds == 2)
        #expect(ProgramProse.sentences(in: "const card = paper(1, 2, 3, 4)\nsay(\"Hi there, how are you?\")\nif (x) {\n}") == [])
        #expect(ProgramProse.sentences(in: "Swift 6.4 is out now, says swift.org.") == ["Swift 6.4 is out now, says swift.org."])
        #expect(ProgramProse.sentences(in: "/* The card goes here\n   and the arrow between them goes there */\ntext(1, 2, `Plans and prices\nfor everyone in the family`)") == [])
        // The prose never reached the program, so nothing after it was swallowed.
        #expect(!summary.program.contains("released in September"))
        let deltas = events.compactMap { if case .programDelta(let text) = $0 { text } else { nil } }.joined()
        #expect(deltas == summary.program)

        var filter = ProgramLineFilter()
        let kept = filter.feed("text(1, 2, `It's a long\nline of words in a template`)\nIt's out now, says the project's page.\nsay(\"ok\")")
            + filter.finish()
        #expect(kept == "text(1, 2, `It's a long\nline of words in a template`)\nsay(\"ok\")")
        #expect(filter.dropped == ["It's out now, says the project's page."])
    }

    @Test func runnerGivesNeverRanToCallsAfterCancellation() async throws {
        let runner = BrainToolRunner(cap: 5)
        let registry = ToolRegistry([BrainProbeTool("t", kind: .read)])
        let context = BrainToolContext(sessionID: "s", turn: 1, callID: "x")
        runner.abandon()
        _ = runner.start(ToolCall(id: "late", name: "t", arguments: "{}"), registry: registry, context: context, lastRound: false) { _, _, _, _ in }
        let outcomes = await runner.collect(from: 0)
        #expect(outcomes.map { $0.result["status"] } == ["never_ran"])
    }

    @Test func unknownToolsAndBadArgumentsAreAnsweredWithoutRunning() async throws {
        let runner = BrainToolRunner(cap: 5)
        let registry = ToolRegistry([BrainProbeTool("t", kind: .read)])
        let context = BrainToolContext(sessionID: "s", turn: 1, callID: "x")
        _ = runner.start(ToolCall(id: "1", name: "nope", arguments: "{}"), registry: registry, context: context, lastRound: false) { _, _, _, _ in }
        _ = runner.start(ToolCall(id: "2", name: "t", arguments: "[1,2]"), registry: registry, context: context, lastRound: false) { _, _, _, _ in }
        let outcomes = await runner.collect(from: 0)
        #expect(outcomes.map { $0.result["status"] } == ["not_implemented", "invalid_arguments"])
        #expect(!runner.needsRound(from: 0))
    }
}
