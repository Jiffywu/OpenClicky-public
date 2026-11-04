import Foundation
import Testing
@testable import OpenClickyKit

/// The OpenAI Realtime voice adapter against a scripted socket (no OpenAI key was available, so this is its only check).
@Suite struct RealtimeVoiceOpenAITests {
    static let key = "sk-test-REALTIME-SECRET"

    static func context(_ socket: FakeWebSocket, base: String = "wss://api.openai.com/v1/realtime") -> ProviderContext {
        ProviderContext(provider: ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: base),
                                                 credential: "openai", headers: ["X-Extra": "1"]),
                        apiKey: key, http: FakeHTTPTransport([]), webSocket: socket)
    }

    /// A socket that accepts the session as soon as `session.update` arrives.
    static func acceptingSocket() -> FakeWebSocket {
        let socket = FakeWebSocket()
        socket.onSend = { message, socket in
            guard case .text(let text) = message, let json = try? JSONValue.parse(text),
                  json["type"]?.stringValue == "session.update", json["session"]?["audio"] != nil else { return }
            socket.pushJSON(["type": "session.updated", "session": ["type": "realtime"]])
        }
        return socket
    }

    static let tool = ToolSpec(name: "capture_screen", description: "Look at the screen.", parameters: ["type": "object", "properties": [:]])

    static func connect(_ socket: FakeWebSocket, configuration: RealtimeSessionConfiguration? = nil) async throws -> any RealtimeVoiceSession {
        let client = OpenAIRealtimeVoiceClient(context: context(socket), model: "gpt-realtime-2.1", defaultVoice: "marin")
        return try await client.connect(configuration ?? RealtimeSessionConfiguration(instructions: "Be brief.", tools: [tool]))
    }

    static func sent(_ socket: FakeWebSocket, _ type: String) -> [JSONValue] {
        socket.sentJSON.filter { $0["type"]?.stringValue == type }
    }

    /// Collects events from a session into an array a test can poll.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [RealtimeVoiceEvent] = []
        private(set) var error: Error?
        private var done = false
        init(_ session: any RealtimeVoiceSession) {
            Task {
                do {
                    for try await event in session.events { self.lock.withLock { self.items.append(event) } }
                } catch {
                    self.lock.withLock { self.error = error }
                }
                self.lock.withLock { self.done = true }
            }
        }
        var all: [RealtimeVoiceEvent] { lock.withLock { items } }
        var finished: Bool { lock.withLock { done } }
        var failure: Error? { lock.withLock { error } }
    }

    // MARK: - Setup

    @Test func connectSendsTheSessionConfigurationAndWaitsForTheServer() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket, configuration: RealtimeSessionConfiguration(
            instructions: "Be brief.", tools: [Self.tool], voice: nil,
            turnDetection: .serverVAD(RealtimeVADSettings(threshold: 0.72, prefixPadding: .milliseconds(300), silence: .milliseconds(700))),
            language: "en-US", noiseReduction: .farField, speed: 1.2))
        #expect(session.inputFormat == .speech24k && session.outputFormat == .speech24k)
        #expect(session.features.truncatesToHeardAudio && session.features.deletesItems && session.features.imageInput)

        let request = try #require(socket.connectRequests.first)
        #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        #expect(request.value(forHTTPHeaderField: "X-Extra") == "1")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)

        let update = try #require(Self.sent(socket, "session.update").first)["session"]
        #expect(update?["type"] == "realtime")
        #expect(update?["output_modalities"] == ["audio"])
        #expect(update?["instructions"] == "Be brief.")
        let input = update?["audio"]?["input"]
        #expect(input?["format"] == ["type": "audio/pcm", "rate": 24_000])
        #expect(input?["transcription"] == ["model": "gpt-transcribe", "language": "en"])
        #expect(input?["noise_reduction"] == ["type": "far_field"])
        #expect(input?["turn_detection"] == ["type": "server_vad", "threshold": 0.72, "prefix_padding_ms": 300,
                                             "silence_duration_ms": 700, "create_response": true, "interrupt_response": true])
        #expect(update?["audio"]?["output"]?["voice"] == "marin")
        #expect(update?["audio"]?["output"]?["speed"] == 1.2)
        #expect(update?["tools"] == [["type": "function", "name": "capture_screen", "description": "Look at the screen.",
                                      "parameters": ["type": "object", "properties": [:]]]])
        #expect(update?["tool_choice"] == "auto")
        await session.close()
        #expect(socket.isClosed)
    }

    @Test func manualTurnsTurnDetectionOffAndCommitWithAReply() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket, configuration: RealtimeSessionConfiguration(
            instructions: "x", turnDetection: .manual, transcribeInput: false, noiseReduction: nil))
        let input = Self.sent(socket, "session.update").first?["session"]?["audio"]?["input"]
        #expect(input?["turn_detection"] == .null)
        #expect(input?["noise_reduction"] == .null)
        #expect(input?["transcription"] == nil)
        await session.sendAudio(Data(count: 12_000))
        await session.endAudioTurn()
        #expect(await waitUntil { Self.sent(socket, "response.create").count == 1 })
        let types = socket.sentJSON.compactMap { $0["type"]?.stringValue }
        #expect(types == ["session.update", "input_audio_buffer.append", "input_audio_buffer.append", "input_audio_buffer.append",
                          "input_audio_buffer.commit", "response.create"])
        #expect(Self.sent(socket, "input_audio_buffer.append").allSatisfy {
            (Data(base64Encoded: $0["audio"]?.stringValue ?? "")?.count ?? 0) <= OpenAIRealtimeVoiceWire.maxAudioChunkBytes
        })
        await session.close()
    }

    @Test func aRejectedSessionFailsTheConnect() async throws {
        let socket = FakeWebSocket()
        socket.onSend = { _, socket in
            socket.pushJSON(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_model", "message": "No such model"]])
        }
        do {
            _ = try await Self.connect(socket)
            Issue.record("connect should have failed")
        } catch let error as ProviderError {
            #expect(error.message.contains("invalid_model"))
            #expect(!error.description.contains(Self.key))
        }
        #expect(socket.isClosed)
    }

    @Test func aSilentServerTimesOut() async throws {
        let socket = FakeWebSocket()
        let client = OpenAIRealtimeVoiceClient(context: Self.context(socket), options: .init(setupTimeout: .milliseconds(50)))
        await #expect(throws: ProviderError.self) { _ = try await client.connect(RealtimeSessionConfiguration(instructions: "x")) }
        #expect(socket.isClosed)
    }

    // MARK: - Events

    @Test func serverEventsBecomeProviderNeutralEvents() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "input_audio_buffer.speech_started", "audio_start_ms": 100, "item_id": "u1"])
        socket.pushJSON(["type": "input_audio_buffer.speech_stopped", "audio_end_ms": 900, "item_id": "u1"])
        socket.pushJSON(["type": "input_audio_buffer.committed", "item_id": "u1"])
        socket.pushJSON(["type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "What's"])
        socket.pushJSON(["type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": " up"])
        socket.pushJSON(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "What's up?"])
        socket.pushJSON(["type": "response.created", "response": ["id": "r1", "status": "in_progress"]])
        // Three bytes: one whole frame now, the odd byte held for the next delta.
        socket.pushJSON(["type": "response.output_audio.delta", "item_id": "a1", "delta": .string(Data([1, 2, 3]).base64EncodedString())])
        socket.pushJSON(["type": "response.output_audio.delta", "item_id": "a1", "delta": .string(Data([4]).base64EncodedString())])
        socket.pushJSON(["type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Not much."])
        socket.pushJSON(["type": "response.function_call_arguments.done", "call_id": "c1", "name": "capture_screen", "arguments": "{}", "item_id": "f1"])
        socket.pushJSON(["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "c1", "name": "capture_screen", "arguments": "{}"]])
        socket.pushJSON(["type": "response.done", "response": [
            "id": "r1", "status": "completed",
            "usage": ["input_tokens": 50, "output_tokens": 20, "input_token_details": ["audio_tokens": 30], "output_token_details": ["audio_tokens": 15]],
        ]])
        #expect(await waitUntil { events.all.count >= 12 })
        let all = events.all
        #expect(all[0] == .userSpeechStarted)
        #expect(all[1] == .userSpeechStopped)
        #expect(all[2] == .userTurnCommitted(itemID: "u1"))
        #expect(all[3] == .userTranscript(text: "What's", isFinal: false, itemID: "u1"))
        #expect(all[4] == .userTranscript(text: "What's up", isFinal: false, itemID: "u1"))
        #expect(all[5] == .userTranscript(text: "What's up?", isFinal: true, itemID: "u1"))
        #expect(all[6] == .responseStarted(responseID: "r1"))
        #expect(all[7] == .audio(Data([1, 2]), itemID: "a1"))
        #expect(all[8] == .audio(Data([3, 4]), itemID: "a1"))
        #expect(all[9] == .assistantTranscriptDelta("Not much.", itemID: "a1"))
        let call = RealtimeToolCall(callID: "c1", name: "capture_screen", arguments: "{}")
        #expect(all[10] == .toolCall(call))  // once, although two events carried it
        #expect(all[11] == .responseFinished(RealtimeResponseSummary(
            responseID: "r1", status: .completed, itemIDs: ["a1"], transcript: "Not much.", toolCalls: [call],
            usage: RealtimeUsage(inputTokens: 50, outputTokens: 20, inputAudioTokens: 30, outputAudioTokens: 15))))
        await session.close()
    }

    @Test func responseStatusesMap() {
        let cases: [(JSONValue, RealtimeResponseStatus)] = [
            (["status": "cancelled", "status_details": ["type": "cancelled", "reason": "turn_detected"]], .interrupted),
            (["status": "cancelled", "status_details": ["type": "cancelled", "reason": "client_cancelled"]], .cancelled),
            (["status": "incomplete"], .incomplete),
            (["status": "failed", "status_details": ["error": ["message": "boom"]]], .failed),
            (["status": "completed"], .completed),
        ]
        for (response, status) in cases { #expect(OpenAIRealtimeVoiceWire.status(of: response) == status) }
    }

    @Test func aServerErrorAfterSetupIsAWarningAndHarmlessCancelsAreSilent() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "error", "error": ["type": "invalid_request_error", "code": "response_cancel_not_active", "message": "nothing"]])
        socket.pushJSON(["type": "error", "error": ["type": "invalid_request_error", "code": "item_not_found", "message": "No item"]])
        #expect(await waitUntil { !events.all.isEmpty })
        #expect(events.all == [.warning("item_not_found: No item")])
        await session.close()
    }

    @Test func theSocketClosingEndsTheEventsWithAnError() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.serverClose(with: ProviderError(provider: "api.openai.com", message: "The server closed the WebSocket (code 1011)."))
        #expect(await waitUntil { events.finished })
        let error = try #require(events.failure as? ProviderError)
        #expect(error.provider == "openai-realtime")
        #expect(error.message.contains("1011"))
    }

    // MARK: - Tools, images, interrupts

    @Test func toolResultsAskForTheNextReplyOnlyOnceEveryCallIsAnsweredAndTheReplyIsDone() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        socket.pushJSON(["type": "response.function_call_arguments.done", "call_id": "c1", "name": "a", "arguments": "{}"])
        socket.pushJSON(["type": "response.function_call_arguments.done", "call_id": "c2", "name": "b", "arguments": "{}"])
        #expect(await waitUntil { events.all.count == 3 })

        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "a", output: ["status": "ok"]))
        #expect(await waitUntil { Self.sent(socket, "conversation.item.create").count == 1 })
        let output = Self.sent(socket, "conversation.item.create")[0]["item"]
        #expect(output == ["type": "function_call_output", "call_id": "c1", "output": "{\"status\":\"ok\"}"])
        await session.sendToolResult(RealtimeToolResult(callID: "c2", name: "b", output: "plain"))
        #expect(await waitUntil { Self.sent(socket, "conversation.item.create").count == 2 })
        #expect(Self.sent(socket, "conversation.item.create")[1]["item"]?["output"] == "plain")
        // Both answered, but the reply that made the calls is still running.
        try await Task.sleep(for: .milliseconds(30))
        #expect(Self.sent(socket, "response.create").isEmpty)
        socket.pushJSON(["type": "response.done", "response": ["id": "r1", "status": "completed"]])
        #expect(await waitUntil { Self.sent(socket, "response.create").count == 1 })
        await session.close()
    }

    @Test func aSupersededResultIsRecordedWithoutAskingForAReply() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        socket.pushJSON(["type": "response.function_call_arguments.done", "call_id": "c1", "name": "a", "arguments": "{}"])
        socket.pushJSON(["type": "response.done", "response": ["id": "r1", "status": "completed"]])
        #expect(await waitUntil { events.all.count == 3 })
        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "a", output: ["status": "superseded"], respond: false))
        #expect(await waitUntil { Self.sent(socket, "conversation.item.create").count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(Self.sent(socket, "response.create").isEmpty)
        await session.close()
    }

    @Test func screenshotsAreImageItemsAndOnlyTheLatestIsKept() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        await session.addImage(Data([0xFF, 0xD8, 0x01]), mimeType: "image/jpeg", caption: "Main display")
        await session.addImage(Data([0xFF, 0xD8, 0x02]), mimeType: "image/jpeg", caption: nil)
        #expect(await waitUntil { Self.sent(socket, "conversation.item.delete").count == 1 })
        let creates = Self.sent(socket, "conversation.item.create")
        #expect(creates.count == 2)
        let first = try #require(creates.first?["item"])
        #expect(first["role"] == "user" && first["type"] == "message")
        #expect(first["content"]?.arrayValue?.first == [
            "type": "input_image", "image_url": .string("data:image/jpeg;base64,\(Data([0xFF, 0xD8, 0x01]).base64EncodedString())"),
        ])
        #expect(first["content"]?.arrayValue?.last == ["type": "input_text", "text": "Main display"])
        let firstID = try #require(first["id"]?.stringValue)
        #expect(firstID.hasPrefix("ocimg_") && firstID.count <= 32)
        #expect(Self.sent(socket, "conversation.item.delete").first?["item_id"]?.stringValue == firstID)
        await session.close()
    }

    @Test func interruptCancelsTheReplyAndTruncatesToWhatWasHeard() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        // One second of 24 kHz audio received.
        socket.pushJSON(["type": "response.output_audio.delta", "item_id": "a1", "delta": .string(Data(count: 48_000).base64EncodedString())])
        #expect(await waitUntil { events.all.count == 2 })
        await session.interrupt(itemID: "a1", heard: 0.4, clearInput: false)
        #expect(await waitUntil { Self.sent(socket, "conversation.item.truncate").count == 1 })
        #expect(Self.sent(socket, "response.cancel").count == 1)
        #expect(Self.sent(socket, "input_audio_buffer.clear").isEmpty)
        #expect(Self.sent(socket, "conversation.item.truncate")[0] == [
            "type": "conversation.item.truncate", "item_id": "a1", "content_index": 0, "audio_end_ms": 400,
        ])
        // Never past the audio that arrived, and Escape also drops buffered input.
        socket.pushJSON(["type": "response.done", "response": ["id": "r1", "status": "cancelled"]])
        #expect(await waitUntil { events.all.count == 3 })
        await session.interrupt(itemID: "a1", heard: 5, clearInput: true)
        #expect(await waitUntil { Self.sent(socket, "conversation.item.truncate").count == 2 })
        #expect(Self.sent(socket, "conversation.item.truncate")[1]["audio_end_ms"] == 1_000)
        #expect(Self.sent(socket, "input_audio_buffer.clear").count == 1)
        #expect(Self.sent(socket, "response.cancel").count == 1)  // nothing was running the second time
        await session.close()
    }

    @Test func discardingATurnCancelsItsReplyAndDeletesIt() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["type": "response.created", "response": ["id": "r1"]])
        #expect(await waitUntil { events.all.count == 1 })
        await session.discardUserTurn(itemID: "u7")
        #expect(await waitUntil { Self.sent(socket, "conversation.item.delete").count == 1 })
        #expect(Self.sent(socket, "response.cancel").count == 1)
        #expect(Self.sent(socket, "conversation.item.delete")[0]["item_id"] == "u7")
        await session.close()
    }

    @Test func textNotesAndInstructionUpdates() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        await session.addText("[App] The link opened.", respond: false)
        await session.addText("Hello", respond: true)
        await session.updateInstructions("Speak French.")
        await session.createResponse(instructions: "Say hi.")
        #expect(await waitUntil { Self.sent(socket, "response.create").count == 2 })
        #expect(Self.sent(socket, "conversation.item.create").count == 2)
        #expect(Self.sent(socket, "session.update").last?["session"] == ["type": "realtime", "instructions": "Speak French."])
        #expect(Self.sent(socket, "response.create").last?["response"] == ["instructions": "Say hi."])
        await session.close()
    }

    @Test func descriptionsNeverShowTheKey() {
        let client = OpenAIRealtimeVoiceClient(context: Self.context(FakeWebSocket()))
        for text in [String(describing: client), String(reflecting: client), "\(client)"] {
            #expect(!text.contains(Self.key))
        }
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(Self.key))
        #expect(client.model == OpenAIRealtimeVoiceClient.defaultModel)
        #expect(client.defaultVoice == "cedar")
    }
}
