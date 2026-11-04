import Foundation
import Testing
@testable import OpenClickyKit

/// Problems found reviewing the realtime voice branch, each pinned by a test.
@Suite struct RealtimeVoiceReviewTests {
    // MARK: - Tool time limits

    /// Waits on a lock-protected flag with no cancellation support, like a blocking AppleScript call would.
    final class StubbornWork: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func release() { lock.withLock { released = true } }
        func run() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    while !self.lock.withLock({ self.released }) { usleep(2_000) }
                    continuation.resume()
                }
            }
        }
    }

    @Test func aToolThatIgnoresCancellationStillTimesOutOnTime() async throws {
        let work = StubbornWork()
        defer { work.release() }
        let session = FakeRealtimeVoiceSession()
        let tool = RealtimeTool(spec: ToolSpec(name: "stuck", description: "stuck", parameters: ["type": "object"]),
                                statusLabel: nil, timeout: .milliseconds(50)) { _ in
            await work.run()
            return .status("ok", succeeded: true)
        }
        let dispatcher = RealtimeToolDispatcher(tools: [tool])
        await dispatcher.handle(RealtimeToolCall(callID: "c1", name: "stuck", arguments: "{}"), session: session)
        // The work stays stuck until this test ends (`defer`), so any answer at all means the time limit didn't wait
        // for it. The wait is generous because the full suite runs in parallel and can starve this machine's threads.
        #expect(await waitUntil(.seconds(10)) { !session.toolResults.isEmpty })
        #expect(session.toolResults.first?.output["status"] == "timed_out")
    }

    // MARK: - Gemini: calls from a reply the user stopped

    @Test func geminiCallsFromAStoppedReplyAreAnsweredSilentlyAndNeverRun() async throws {
        let socket = RealtimeVoiceGeminiTests.acceptingSocket()
        let session = try await RealtimeVoiceGeminiTests.connect(socket)
        let events = RealtimeVoiceGeminiTests.Events(session)
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [RealtimeVoiceGeminiTests.audioPart(Data([1, 2]))]]]])
        #expect(await waitUntil { events.all.count == 2 })
        // Escape: the rest of this turn is dropped here, including a call Gemini makes after it.
        await session.interrupt(itemID: "gemini-turn-1", heard: 0.01, clearInput: true)
        #expect(await waitUntil { events.all.count == 3 })
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c9", "name": "open_url", "args": ["url": "https://example.com"]]]]])
        #expect(await waitUntil { RealtimeVoiceGeminiTests.sent(socket, "toolResponse").count == 1 })
        let response = RealtimeVoiceGeminiTests.sent(socket, "toolResponse")[0]["functionResponses"]?.arrayValue?.first
        #expect(response?["id"] == "c9")
        #expect(response?["response"]?["scheduling"] == "SILENT")
        #expect(response?["response"]?["status"] == "cancelled")
        try await Task.sleep(for: .milliseconds(30))
        #expect(!events.all.contains { if case .toolCall = $0 { true } else { false } })
        // The next turn's calls go to the app again.
        socket.pushJSON(["serverContent": ["turnComplete": true]])
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c10", "name": "save_memory", "args": ["text": "x"]]]]])
        #expect(await waitUntil { events.all.contains(.toolCall(RealtimeToolCall(callID: "c10", name: "save_memory", arguments: "{\"text\":\"x\"}"))) })
        await session.close()
    }

    @Test func geminiDropsAScreenshotWhoseCallWasWithdrawn() async throws {
        let socket = RealtimeVoiceGeminiTests.acceptingSocket()
        let session = try await RealtimeVoiceGeminiTests.connect(socket)
        let events = RealtimeVoiceGeminiTests.Events(session)
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c1", "name": "capture_screen", "args": [:]]]]])
        #expect(await waitUntil { events.all.count == 2 })
        await session.addImage(Data([0xFF, 0xD8, 0x01]), mimeType: "image/jpeg", caption: nil)
        socket.pushJSON(["toolCallCancellation": ["ids": ["c1"]]])
        #expect(await waitUntil { events.all.count == 3 })
        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "capture_screen", output: ["status": "ok"]))
        // A later, unrelated call must not carry the old screenshot.
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c2", "name": "save_memory", "args": ["text": "x"]]]]])
        #expect(await waitUntil { events.all.count == 4 })
        await session.sendToolResult(RealtimeToolResult(callID: "c2", name: "save_memory", output: ["status": "saved"]))
        #expect(await waitUntil { RealtimeVoiceGeminiTests.sent(socket, "toolResponse").count == 1 })
        let response = RealtimeVoiceGeminiTests.sent(socket, "toolResponse")[0]["functionResponses"]?.arrayValue?.first
        #expect(response?["id"] == "c2")
        #expect(response?["parts"] == nil)
        await session.close()
    }

    // MARK: - OpenAI: calls from a reply the app cancelled

    @Test func openAICallsFromACancelledReplyAreNotRun() async throws {
        let socket = RealtimeVoiceOpenAITests.acceptingSocket()
        let session = try await RealtimeVoiceOpenAITests.connect(socket)
        let events = RealtimeVoiceOpenAITests.Events(session)
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        #expect(await waitUntil { events.all.count == 1 })
        await session.interrupt(itemID: nil, heard: nil, clearInput: true)
        #expect(await waitUntil { RealtimeVoiceOpenAITests.sent(socket, "response.cancel").count == 1 })
        // A call that was already on its way, and one only listed in the cancelled reply's final output.
        socket.pushJSON(["type": "response.function_call_arguments.done", "response_id": "r1", "call_id": "c1",
                         "name": "open_url", "arguments": "{\"url\":\"https://example.com\"}"])
        socket.pushJSON(["type": "response.done", "response": [
            "id": "r1", "status": "cancelled", "status_details": ["type": "cancelled", "reason": "client_cancelled"],
            "output": [["type": "function_call", "call_id": "c2", "name": "open_url", "arguments": "{}", "status": "incomplete"]],
        ]])
        #expect(await waitUntil { events.all.count == 2 })
        #expect(events.all[1] == .responseFinished(RealtimeResponseSummary(responseID: "r1", status: .cancelled)))
        // The next reply's calls go to the app as usual.
        socket.pushJSON(["type": "response.created", "response": ["id": "r2"]])
        socket.pushJSON(["type": "response.function_call_arguments.done", "response_id": "r2", "call_id": "c3",
                         "name": "capture_screen", "arguments": "{}"])
        #expect(await waitUntil { events.all.count == 4 })
        #expect(events.all[3] == .toolCall(RealtimeToolCall(callID: "c3", name: "capture_screen", arguments: "{}")))
        await session.close()
    }

    @Test func openAICallsFromAReplyCancelledBeforeItStartedAreNotRun() async throws {
        let socket = RealtimeVoiceOpenAITests.acceptingSocket()
        let session = try await RealtimeVoiceOpenAITests.connect(socket)
        let events = RealtimeVoiceOpenAITests.Events(session)
        await session.createResponse(instructions: nil)
        await session.interrupt(itemID: nil, heard: nil, clearInput: true)
        #expect(await waitUntil { RealtimeVoiceOpenAITests.sent(socket, "response.cancel").count == 1 })
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        socket.pushJSON(["type": "response.function_call_arguments.done", "response_id": "r1", "call_id": "c1",
                         "name": "open_url", "arguments": "{}"])
        socket.pushJSON(["type": "response.done", "response": ["id": "r1", "status": "cancelled"]])
        #expect(await waitUntil { events.all.count == 2 })
        #expect(!events.all.contains { if case .toolCall = $0 { true } else { false } })
        await session.close()
    }

    // MARK: - Slot pickers

    @Test func theVoiceSlotPickerOffersNoGeminiLiveModels() throws {
        let catalog = try ModelCatalog.builtIn()
        #expect(catalog.candidates(for: .voice, dialect: .geminiLive).isEmpty)
        #expect(catalog.candidates(for: .realtimeVoice, dialect: .geminiLive).map(\.id).contains("gemini-3.8-live"))
        #expect(catalog.candidates(for: .stt, dialect: .geminiLive).map(\.id).contains("gemini-3.5-transcribe-live"))
        #expect(!catalog.candidates(for: .voice, dialect: .openAIRealtime).isEmpty)
    }

    // MARK: - Output route changes

    @Test func soundMovingToTheSpeakersTurnsTheEchoGateOn() async throws {
        let (conversation, session, output, clock) = RealtimeConversationTests.make(route: .headphones)
        let run = Task { await conversation.run() }
        await conversation.outputRouteChanged(to: .speakers)
        session.emit(.responseStarted(responseID: "r1"))
        session.emit(.audio(speechTone(seconds: 3), itemID: "a1"))
        #expect(await waitUntil { output.isPlaying })
        for _ in 0..<5 {
            clock.advance(0.04)
            await conversation.feedMicrophone(speechTone(seconds: 0.04, amplitude: 0.01))
        }
        // The voice leaking back into the mic goes out as silence.
        #expect(session.sentSilentAudioBytes == 5 * 1_920)
        await conversation.close()
        _ = await run.value
    }

    @Test func alwaysOnPassesARouteChangeToTheConversationWhenSpeakersAreAllowed() async throws {
        let harness = AlwaysOnVoiceTests.Harness()
        let controller = AlwaysOnVoiceController(environment: harness.environment(requireHeadphones: false))
        #expect(await controller.start() == .on)
        harness.route = .speakers
        await controller.outputRouteChanged()
        #expect(await controller.state == .on)
        let conversation = try #require(await controller.currentConversation)
        #expect(await conversation.outputRoute == .speakers)
        await controller.stop()
    }
}
