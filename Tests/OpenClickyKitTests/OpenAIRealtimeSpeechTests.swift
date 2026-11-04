import Foundation
import Testing
@testable import OpenClickyKit

// Scripted Realtime servers built from the GA server-event reference
// (https://developers.openai.com/api/reference/resources/realtime/server-events). No network, no real keys.

private let fakeKey = "sk-test-not-a-real-key"

private func makeContext(_ connector: any WebSocketConnector, baseURL: String? = "wss://api.openai.com/v1/realtime",
                         apiKey: String? = fakeKey, headers: [String: String]? = nil) -> ProviderContext {
    ProviderContext(
        provider: ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: baseURL.flatMap(URL.init(string:)),
                                 credential: "openai", headers: headers),
        apiKey: apiKey, http: FakeHTTPTransport([]), webSocket: connector)
}

/// A fake Realtime server: answers client events the way the reference documents.
private struct ScriptedServer: Sendable {
    enum ResponseCreate: Sendable {
        /// Stream the audio chunks and finish with response.done (completed).
        case speak
        /// Start the response and stream the audio, then hold it open (no response.done).
        case speakAndHold
        /// Reject response.create with an error event.
        case reject
        /// Stream the audio, then end with response.done status "failed".
        case fail
    }

    var audio: [Data] = []
    var onResponseCreate: ResponseCreate = .speak
    var rejectReasoning = false
    var rejectSessionUpdate = false
    var answerCancel = true
    var betaEventNames = false
    /// The response a `.speakAndHold` server is still streaming, for `response.cancel` without a `response_id`
    /// (the client-events reference: "If not specified, the in-progress response in the default conversation
    /// will be cancelled").
    let inProgress = LockedValue<String?>(nil)

    static let sessionCreated: JSONValue = [
        "type": "session.created", "event_id": "event_C1",
        "session": [
            "type": "realtime", "object": "realtime.session", "id": "sess_C1", "model": "gpt-realtime-2.1-mini",
            "output_modalities": ["audio"], "instructions": "", "reasoning": ["effort": "minimal"],
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "transcription": ["model": "gpt-4o-mini-transcribe"],
                    "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 200],
                ],
                "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": "cedar", "speed": 1.0],
            ],
        ],
    ]

    func install(on socket: FakeWebSocket) {
        socket.push(.text(Self.sessionCreated.jsonString()))
        socket.onSend = { message, ws in
            guard case .text(let text) = message, let event = try? JSONValue.parse(text),
                  let type = event["type"]?.stringValue else { return }
            let eventID = event["event_id"]?.stringValue ?? ""
            switch type {
            case "session.update":
                if rejectSessionUpdate {
                    ws.pushJSON(Self.error(code: "invalid_value", message: "Invalid value: 'nope'. Supported values are: 'alloy', 'cedar', 'marin'.",
                                           param: "session.audio.output.voice", eventID: eventID))
                } else if rejectReasoning, event["session"]?["reasoning"] != nil {
                    ws.pushJSON(Self.error(code: "unknown_parameter", message: "Unknown parameter: 'session.reasoning'.",
                                           param: "session.reasoning", eventID: eventID))
                } else {
                    var session = event["session"]?.objectValue ?? [:]
                    session["object"] = "realtime.session"
                    session["id"] = "sess_C1"
                    session["model"] = "gpt-realtime-2.1-mini"
                    ws.pushJSON(["type": "session.updated", "event_id": .string("event_U\(eventID)"), "session": .object(session)])
                }
            case "conversation.item.create":
                var item = event["item"]?.objectValue ?? [:]
                item["id"] = .string("item_user_\(eventID)")
                item["object"] = "realtime.item"
                item["status"] = "completed"
                ws.pushJSON(["type": betaEventNames ? "conversation.item.created" : "conversation.item.added",
                             "event_id": .string("event_A\(eventID)"), "previous_item_id": .null, "item": .object(item)])
                if !betaEventNames {
                    ws.pushJSON(["type": "conversation.item.done", "event_id": .string("event_D\(eventID)"), "previous_item_id": .null, "item": .object(item)])
                }
            case "response.create":
                if onResponseCreate == .reject {
                    ws.pushJSON(Self.error(code: "invalid_value", message: "Invalid value for 'response.instructions'.",
                                           param: "response.instructions", eventID: eventID))
                    return
                }
                let responseID = "resp_\(eventID)"
                let itemID = "item_reply_\(eventID)"
                if onResponseCreate == .speakAndHold { inProgress.set(responseID) }
                for frame in streamFrames(responseID: responseID, itemID: itemID) { ws.pushJSON(frame) }
                switch onResponseCreate {
                case .speak: ws.pushJSON(Self.responseDone(responseID: responseID, itemID: itemID, status: "completed"))
                case .fail: ws.pushJSON(Self.responseDone(responseID: responseID, itemID: itemID, status: "failed"))
                case .speakAndHold, .reject: break
                }
            case "response.cancel":
                guard answerCancel else { return }
                guard let responseID = event["response_id"]?.stringValue ?? inProgress.get() else {
                    // Nothing to cancel. The error shape is the documented one; the wording is illustrative.
                    ws.pushJSON(Self.error(code: "response_cancel_not_active", message: "Cancellation failed: no active response found.",
                                           param: nil, eventID: eventID))
                    return
                }
                inProgress.set(nil)
                let itemID = "item_reply_" + responseID.dropFirst("resp_".count)
                ws.pushJSON(Self.responseDone(responseID: responseID, itemID: itemID, status: "cancelled"))
            case "conversation.item.delete":
                ws.pushJSON(["type": "conversation.item.deleted", "event_id": .string("event_X\(eventID)"), "item_id": event["item_id"] ?? .null])
            default:
                break
            }
        }
    }

    private func streamFrames(responseID: String, itemID: String) -> [JSONValue] {
        let assistantItem: JSONValue = ["id": .string(itemID), "object": "realtime.item", "type": "message",
                                        "status": "in_progress", "role": "assistant", "content": []]
        var frames: [JSONValue] = [
            ["type": "response.created", "event_id": "event_R1",
             "response": ["object": "realtime.response", "id": .string(responseID), "status": "in_progress", "status_details": .null,
                          "output": [], "conversation_id": "conv_1", "output_modalities": ["audio"],
                          "audio": ["output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": "cedar"]],
                          "usage": .null, "metadata": .null]],
            ["type": "rate_limits.updated", "event_id": "event_RL",
             "rate_limits": [["name": "requests", "limit": 1000, "remaining": 999, "reset_seconds": 60]]],
            ["type": "response.output_item.added", "event_id": "event_R2", "response_id": .string(responseID), "output_index": 0,
             "item": assistantItem],
            ["type": betaEventNames ? "conversation.item.created" : "conversation.item.added", "event_id": "event_R3",
             "previous_item_id": "item_user", "item": assistantItem],
            ["type": "response.content_part.added", "event_id": "event_R4", "response_id": .string(responseID),
             "item_id": .string(itemID), "output_index": 0, "content_index": 0, "part": ["type": "audio", "transcript": ""]],
        ]
        for (index, chunk) in audio.enumerated() {
            frames.append(["type": .string(betaEventNames ? "response.audio.delta" : "response.output_audio.delta"),
                           "event_id": .string("event_AD\(index)"), "response_id": .string(responseID), "item_id": .string(itemID),
                           "output_index": 0, "content_index": 0, "delta": .string(chunk.base64EncodedString())])
            frames.append(["type": .string(betaEventNames ? "response.audio_transcript.delta" : "response.output_audio_transcript.delta"),
                           "event_id": .string("event_TD\(index)"), "response_id": .string(responseID), "item_id": .string(itemID),
                           "output_index": 0, "content_index": 0, "delta": "word "])
        }
        return frames
    }

    static func responseDone(responseID: String, itemID: String, status: String) -> JSONValue {
        let details: JSONValue = switch status {
        case "cancelled": ["type": "cancelled", "reason": "client_cancelled"]
        case "failed": ["type": "failed", "error": ["type": "server_error", "code": "server_error", "message": "The server had an error while processing your request."]]
        default: .null
        }
        return [
            "type": "response.done", "event_id": "event_DONE",
            "response": [
                "object": "realtime.response", "id": .string(responseID), "status": .string(status), "status_details": details,
                "output": [["id": .string(itemID), "object": "realtime.item", "type": "message", "status": "completed", "role": "assistant",
                            "content": [["type": "output_audio", "transcript": "Hello there."]]]],
                "conversation_id": "conv_1", "output_modalities": ["audio"],
                "usage": ["total_tokens": 60, "input_tokens": 40, "output_tokens": 20,
                          "input_token_details": ["text_tokens": 40, "audio_tokens": 0, "image_tokens": 0, "cached_tokens": 0],
                          "output_token_details": ["text_tokens": 5, "audio_tokens": 15]],
            ],
        ]
    }

    static func error(code: String?, message: String, param: String?, eventID: String?) -> JSONValue {
        [
            "type": "error", "event_id": "event_E1",
            "error": ["type": "invalid_request_error", "code": code.map(JSONValue.string) ?? .null, "message": .string(message),
                      "param": param.map(JSONValue.string) ?? .null, "event_id": eventID.map(JSONValue.string) ?? .null],
        ]
    }
}

/// Hands out a fresh socket per connection, for reconnect tests.
private final class SocketSequence: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [FakeWebSocket]
    private(set) var requests: [URLRequest] = []

    init(_ sockets: [FakeWebSocket]) { remaining = sockets }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        try lock.withLock {
            requests.append(request)
            guard !remaining.isEmpty else { throw URLError(.cannotConnectToHost) }
            return remaining.removeFirst()
        }
    }

    var connectCount: Int { lock.withLock { requests.count } }
}

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

/// Wraps a FakeWebSocket and parks the first send of one event type until `release()`, so a test can act while
/// that send is still in flight (as a slow real socket would allow).
private final class HoldingSocket: WebSocketConnection, WebSocketConnector, @unchecked Sendable {
    let inner: FakeWebSocket
    private let holdType: String
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var released = false
    private var holding = false

    init(_ inner: FakeWebSocket, holding type: String) {
        self.inner = inner
        holdType = type
    }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection { self }

    var isHolding: Bool { lock.withLock { holding } }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { parked = nil }
            return parked
        }
        waiter?.resume()
    }

    func send(_ message: WebSocketMessage) async throws {
        if case .text(let text) = message, (try? JSONValue.parse(text))?["type"]?.stringValue == holdType {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let goNow: Bool = lock.withLock {
                    if released { return true }
                    holding = true
                    parked = continuation
                    return false
                }
                if goNow { continuation.resume() }
            }
        }
        try await inner.send(message)
    }

    func receive() async throws -> WebSocketMessage { try await inner.receive() }
    func close() async { await inner.close() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// Polls `condition` until it holds or `timeout` passes. The timeout only guards against a hang: a busy machine can
/// take far longer than an idle one.
private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func collect(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async throws -> [SpeechEvent] {
    var events: [SpeechEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func types(_ socket: FakeWebSocket) -> [String] { socket.sentJSON.compactMap { $0["type"]?.stringValue } }

private func sent(_ socket: FakeWebSocket, _ type: String) -> [JSONValue] { socket.sentJSON.filter { $0["type"]?.stringValue == type } }

/// 0.1 s of 24 kHz PCM16, split at odd byte offsets the way deltas can land mid-sample.
private let linePCM = Data((0..<4_800).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
private let lineChunks: [Data] = {
    var chunks: [Data] = []
    var start = 0
    for size in [1, 333, 1_000, 7, 2_048] {
        chunks.append(linePCM.subdata(in: start..<(start + size)))
        start += size
    }
    chunks.append(linePCM.subdata(in: start..<linePCM.count))
    return chunks
}()

@Suite struct OpenAIRealtimeSpeechTests {
    @Test func handshakeTargetsGAEndpointWithBearerAuthAndNoBetaHeader() async throws {
        let socket = FakeWebSocket()
        ScriptedServer().install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket, headers: ["X-Gateway": "clicky"]))
        await client.warmUp()
        await client.warmUp()  // already connected and configured: no second socket or session.update

        #expect(socket.connectRequests.count == 1)
        let request = try #require(socket.connectRequests.first)
        #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        let hasBearer = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)"
        #expect(hasBearer)  // compared without printing the header value
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Gateway") == "clicky")
        #expect(types(socket) == ["session.update"])
        await client.disconnect()
    }

    @Test func endpointAcceptsPlainAPIBaseAndKeepsQuery() {
        let model = "gpt-realtime-2.1-mini"
        #expect(OpenAIRealtimeWire.endpoint(base: nil, model: model).absoluteString
            == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        #expect(OpenAIRealtimeWire.endpoint(base: URL(string: "https://api.openai.com/v1/"), model: model).absoluteString
            == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        #expect(OpenAIRealtimeWire.endpoint(base: URL(string: "http://127.0.0.1:8080/v1/realtime?team=a&model=old"), model: model).absoluteString
            == "ws://127.0.0.1:8080/v1/realtime?team=a&model=gpt-realtime-2.1-mini")
    }

    @Test func noKeyMeansNoAuthorizationHeader() {
        let client = OpenAIRealtimeSpeechClient(context: makeContext(FakeWebSocket(), apiKey: nil))
        #expect(client.handshakeRequest().value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sessionUpdateConfiguresOutputOnlyVerbatimSpeech() async throws {
        let socket = FakeWebSocket()
        ScriptedServer().install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        await client.warmUp()

        let update = try #require(sent(socket, "session.update").first)
        #expect(update["event_id"]?.stringValue?.isEmpty == false)
        var session = try #require(update["session"]?.objectValue)
        let instructions = try #require(session.removeValue(forKey: "instructions")?.stringValue)
        #expect(instructions.contains("word for word"))
        #expect(.object(session) == [
            "type": "realtime",
            "output_modalities": ["audio"],
            "reasoning": ["effort": "minimal"],
            "audio": [
                "input": ["turn_detection": .null],
                "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": "cedar"],
            ],
        ] as JSONValue)
        // turn_detection must go out as an explicit null, which is how the API clears it.
        if case .text(let raw) = socket.sent[0] { #expect(raw.contains("\"turn_detection\":null")) }
        await client.disconnect()
    }

    @Test func speaksALineFromChunkedAudioDeltasAndDeletesItsItems() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))

        let events = try await collect(client.speak("Hello there.", voice: nil, instructions: nil))

        #expect(events.last == .lineFinished)
        let audio = events.compactMap { if case .audio(let data, let format) = $0 { (data, format) } else { nil } }
        #expect(audio.allSatisfy { $0.1 == .speech24k })
        // Deltas of 1, 333, 1000, 7, 2048 and 1411 bytes come out as whole 16-bit samples, in order.
        #expect(audio.map(\.0.count) == [334, 1_000, 6, 2_048, 1_412])
        #expect(audio.map(\.0).reduce(Data(), +) == linePCM)

        let create = try #require(sent(socket, "conversation.item.create").first)
        #expect(create["item"] == ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Hello there."]]])
        let response = try #require(sent(socket, "response.create").first)
        #expect(response["response"] == nil)  // session settings apply as configured

        #expect(await eventually { sent(socket, "conversation.item.delete").count == 2 })
        let itemEvent = try #require(create["event_id"]?.stringValue)
        let responseEvent = try #require(response["event_id"]?.stringValue)
        #expect(sent(socket, "conversation.item.delete").compactMap { $0["item_id"]?.stringValue }
            == ["item_user_\(itemEvent)", "item_reply_\(responseEvent)"])
        #expect(types(socket) == ["session.update", "conversation.item.create", "response.create",
                                  "conversation.item.delete", "conversation.item.delete"])
        #expect(!socket.isClosed)  // kept for the next line
        await client.disconnect()
    }

    @Test func oneByteAudioDeltasAreReassembledIntoWholeSamples() async throws {
        let pcm = linePCM.prefix(1_200)
        let socket = FakeWebSocket()
        ScriptedServer(audio: pcm.map { Data([$0]) }).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))

        let events = try await collect(client.speak("Byte by byte.", voice: nil, instructions: nil))

        let audio = events.compactMap { if case .audio(let data, _) = $0 { data } else { nil } }
        #expect(audio.count == 600)
        #expect(audio.allSatisfy { $0.count == 2 })
        #expect(audio.reduce(Data(), +) == Data(pcm))
        #expect(events.last == .lineFinished)
        await client.disconnect()
    }

    @Test func aDanglingHalfSampleIsHeldThenDropped() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: [Data([1]), Data([2, 3, 4, 5])]).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        let events = try await collect(client.speak("Odd.", voice: nil, instructions: nil))
        #expect(events == [.audio(Data([1, 2, 3, 4]), .speech24k), .lineFinished])
        await client.disconnect()
    }

    @Test func acceptsBetaEventNames() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: lineChunks, betaEventNames: true).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        let events = try await collect(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(events.compactMap { if case .audio(let d, _) = $0 { d } else { nil } }.reduce(Data(), +) == linePCM)
        #expect(events.last == .lineFinished)
        #expect(await eventually { sent(socket, "conversation.item.delete").count == 2 })
        await client.disconnect()
    }

    @Test func lineInstructionsGoOnTheResponseAndVoiceChangesBeforeAudioReuseTheSession() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        await client.warmUp()  // session in cedar, nothing spoken yet

        _ = try await collect(client.speak("Careful, that's hot.", voice: "marin", instructions: "Sound worried."))

        #expect(socket.connectRequests.count == 1)
        let updates = sent(socket, "session.update")
        #expect(updates.map { $0["session"]?["audio"]?["output"]?["voice"] } == ["cedar", "marin"])
        let instructions = try #require(sent(socket, "response.create").first?["response"]?["instructions"]?.stringValue)
        #expect(instructions.hasPrefix(OpenAIRealtimeSpeechClient.readAloudInstructions))
        #expect(instructions.hasSuffix("Sound worried."))
        await client.disconnect()
    }

    @Test func voiceChangeAfterAudioOpensANewSession() async throws {
        let first = FakeWebSocket(), second = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: first)
        ScriptedServer(audio: lineChunks).install(on: second)
        let connector = SocketSequence([first, second])
        let client = OpenAIRealtimeSpeechClient(context: makeContext(connector))

        _ = try await collect(client.speak("One.", voice: nil, instructions: nil))
        let events = try await collect(client.speak("Two.", voice: "marin", instructions: nil))

        #expect(events.last == .lineFinished)
        #expect(connector.connectCount == 2)
        #expect(first.isClosed)
        #expect(sent(second, "session.update").first?["session"]?["audio"]?["output"]?["voice"] == "marin")
        #expect(sent(second, "conversation.item.create").first?["item"]?["content"]?.arrayValue?.first?["text"] == "Two.")
        await client.disconnect()
    }

    @Test func anIdleMouthClosesItsSocketAndTheNextLineReopensIt() async throws {
        let first = FakeWebSocket(), second = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: first)
        ScriptedServer(audio: lineChunks).install(on: second)
        let connector = SocketSequence([first, second])
        let client = OpenAIRealtimeSpeechClient(context: makeContext(connector), idleTimeout: .milliseconds(150))

        _ = try await collect(client.speak("One.", voice: nil, instructions: nil))
        // A line soon after reuses the socket and restarts the idle clock.
        try await Task.sleep(for: .milliseconds(60))
        _ = try await collect(client.speak("Two.", voice: nil, instructions: nil))
        try await Task.sleep(for: .milliseconds(60))
        #expect(!first.isClosed)
        #expect(connector.connectCount == 1)

        // Then nothing for longer than the idle period: the socket closes on our side.
        let deadline = ContinuousClock.now + .seconds(3)
        while !first.isClosed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(first.isClosed)
        #expect(!(await client.isConnected))

        // The next line opens a fresh session and is spoken in full.
        let events = try await collect(client.speak("Three.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(connector.connectCount == 2)
        #expect(sent(second, "conversation.item.create").first?["item"]?["content"]?.arrayValue?.first?["text"] == "Three.")
        await client.disconnect()
    }

    @Test func aMouthWithoutAnIdleTimeoutKeepsItsSocket() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket), idleTimeout: nil)
        _ = try await collect(client.speak("One.", voice: nil, instructions: nil))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!socket.isClosed)
        #expect(await client.isConnected)
        await client.disconnect()
    }

    @Test func aResponseWithoutAudioStillLocksTheVoice() async throws {
        let first = FakeWebSocket(), second = FakeWebSocket()
        ScriptedServer(audio: []).install(on: first)
        ScriptedServer(audio: lineChunks).install(on: second)
        let connector = SocketSequence([first, second])
        let client = OpenAIRealtimeSpeechClient(context: makeContext(connector))

        // The first response produced no audio delta that reached us, but the model did respond.
        #expect(try await collect(client.speak("One.", voice: nil, instructions: nil)) == [.lineFinished])
        let events = try await collect(client.speak("Two.", voice: "marin", instructions: nil))

        #expect(events.last == .lineFinished)
        #expect(connector.connectCount == 2)
        #expect(sent(first, "session.update").count == 1)
        #expect(sent(second, "session.update").first?["session"]?["audio"]?["output"]?["voice"] == "marin")
        await client.disconnect()
    }

    @Test func stopAllWhileTheLineIsStillBeingSentCancelsAfterResponseCreate() async throws {
        let fake = FakeWebSocket()
        ScriptedServer(audio: [Data([1, 2])], onResponseCreate: .speakAndHold).install(on: fake)
        let socket = HoldingSocket(fake, holding: "conversation.item.create")
        // The server answers the cancel; a grace far longer than the test keeps a busy machine from dropping the socket.
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket), cancelGrace: .seconds(60))

        let consumer = Task { try await collect(client.speak("Stopped on the way out.", voice: nil, instructions: nil)) }
        #expect(await eventually { socket.isHolding })
        await client.stopAll()
        socket.release()

        await #expect(throws: CancellationError.self) { _ = try await consumer.value }
        #expect(await eventually { sent(fake, "conversation.item.delete").count == 2 })
        // The cancel waits for the response it is meant to stop, then the line cleans up on the same socket.
        #expect(types(fake) == ["session.update", "conversation.item.create", "response.create", "response.cancel",
                                "conversation.item.delete", "conversation.item.delete"])
        #expect(!fake.isClosed)
        await client.disconnect()
    }

    @Test func cancellingTheConsumerSendsResponseCancelAndCleansUp() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: Array(lineChunks.prefix(2)), onResponseCreate: .speakAndHold).install(on: socket)
        // The server answers the cancel; a grace far longer than the test keeps a busy machine from dropping the socket.
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket), cancelGrace: .seconds(60))
        let heardAudio = Flag()

        let consumer = Task {
            for try await event in client.speak("A long line that gets interrupted.", voice: nil, instructions: nil) {
                if case .audio = event { heardAudio.raise() }
            }
        }
        #expect(await eventually { heardAudio.isRaised })
        consumer.cancel()

        #expect(await eventually { !sent(socket, "response.cancel").isEmpty })
        let responseEvent = try #require(sent(socket, "response.create").first?["event_id"]?.stringValue)
        #expect(sent(socket, "response.cancel").first?["response_id"]?.stringValue == "resp_\(responseEvent)")
        // After response.done (cancelled) the line's items are deleted; nothing else (no WebRTC-only buffer clear).
        #expect(await eventually { sent(socket, "conversation.item.delete").count == 2 })
        #expect(!types(socket).contains("output_audio_buffer.clear"))
        #expect(!socket.isClosed)
        _ = await consumer.result
        await client.disconnect()
    }

    @Test func unansweredCancelDropsTheSocketAndTheNextLineReconnects() async throws {
        let first = FakeWebSocket(), second = FakeWebSocket()
        ScriptedServer(audio: [Data([1, 2])], onResponseCreate: .speakAndHold, answerCancel: false).install(on: first)
        ScriptedServer(audio: lineChunks).install(on: second)
        let connector = SocketSequence([first, second])
        let client = OpenAIRealtimeSpeechClient(context: makeContext(connector), cancelGrace: .milliseconds(150))
        let heardAudio = Flag()

        let consumer = Task {
            for try await event in client.speak("Interrupted.", voice: nil, instructions: nil) {
                if case .audio = event { heardAudio.raise() }
            }
        }
        #expect(await eventually { heardAudio.isRaised })
        consumer.cancel()
        #expect(await eventually { first.isClosed })

        let events = try await collect(client.speak("Next.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(connector.connectCount == 2)
        await client.disconnect()
    }

    @Test func errorEventFailsTheLineWithTheProviderMessage() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(onResponseCreate: .reject).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))

        do {
            _ = try await collect(client.speak("Hello.", voice: nil, instructions: "x"))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.provider == "openai-realtime")
            #expect(error.status == nil)
            #expect(error.message == "invalid_value: Invalid value for 'response.instructions'.")
        }
        // response.create was rejected, so there is no response to cancel; the user item is still cleaned up.
        #expect(await eventually { sent(socket, "conversation.item.delete").count == 1 })
        #expect(sent(socket, "response.cancel").isEmpty)
        await client.disconnect()
    }

    @Test func unattributedErrorMidLineFailsItAndCancelsTheResponse() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: [Data([1, 2, 3, 4])], onResponseCreate: .speakAndHold).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        let stream = client.speak("Hello.", voice: nil, instructions: nil)
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        #expect(firstEvent == .audio(Data([1, 2, 3, 4]), .speech24k))

        socket.pushJSON(["type": "error", "event_id": "event_E9",
                         "error": ["type": "server_error", "code": .null, "message": "The server had an error.", "param": .null, "event_id": .null]])
        do {
            _ = try await iterator.next()
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.message == "The server had an error.")
        }
        #expect(await eventually { sent(socket, "response.cancel").count == 1 })
        await client.disconnect()
    }

    @Test func failedResponseSurfacesStatusDetails() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: [Data([0, 0])], onResponseCreate: .fail).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        do {
            _ = try await collect(client.speak("Hello.", voice: nil, instructions: nil))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.message.contains("failed"))
            #expect(error.message.contains("The server had an error while processing your request."))
        }
        await client.disconnect()
    }

    @Test func sessionUpdateRetriesWithoutReasoningWhenTheModelRejectsIt() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: lineChunks, rejectReasoning: true).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        let events = try await collect(client.speak("Hello.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        let updates = sent(socket, "session.update")
        #expect(updates.count == 2)
        #expect(updates[0]["session"]?["reasoning"] == ["effort": "minimal"])
        #expect(updates[1]["session"]?["reasoning"] == nil)
        await client.disconnect()
    }

    @Test func rejectedSessionUpdateFailsTheLine() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(rejectSessionUpdate: true).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        do {
            _ = try await collect(client.speak("Hello.", voice: "nope", instructions: nil))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.message.hasPrefix("invalid_value: Invalid value: 'nope'."))
        }
        #expect(sent(socket, "conversation.item.create").isEmpty)
        #expect(socket.isClosed)
    }

    @Test func linesAreSpokenOneAtATime() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: [Data([9, 9])], onResponseCreate: .speakAndHold).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))

        let first = Task { try await collect(client.speak("First.", voice: nil, instructions: nil)) }
        #expect(await eventually { sent(socket, "response.create").count == 1 })
        // Asked for now, while the first line is speaking (not whenever a busy machine gets round to a task).
        let secondLine = client.speak("Second.", voice: nil, instructions: nil)
        let second = Task { try await collect(secondLine) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(sent(socket, "conversation.item.create").count == 1)  // the second line waits its turn

        let firstEvent = sent(socket, "response.create")[0]["event_id"]?.stringValue ?? ""
        socket.pushJSON(ScriptedServer.responseDone(responseID: "resp_\(firstEvent)", itemID: "item_reply_\(firstEvent)", status: "completed"))
        #expect(try await first.value.last == .lineFinished)

        #expect(await eventually { sent(socket, "response.create").count == 2 })
        // The first line's items were deleted before the second line's item went in.
        let order = types(socket)
        let secondCreate = try #require(order.lastIndex(of: "conversation.item.create"))
        #expect(order[..<secondCreate].filter { $0 == "conversation.item.delete" }.count == 2)
        let secondEvent = sent(socket, "response.create")[1]["event_id"]?.stringValue ?? ""
        socket.pushJSON(ScriptedServer.responseDone(responseID: "resp_\(secondEvent)", itemID: "item_reply_\(secondEvent)", status: "completed"))
        #expect(try await second.value.last == .lineFinished)
        await client.disconnect()
    }

    @Test func stopAllCancelsTheActiveAndQueuedLines() async throws {
        let socket = FakeWebSocket()
        ScriptedServer(audio: [Data([5, 5])], onResponseCreate: .speakAndHold).install(on: socket)
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))

        let first = Task { try await collect(client.speak("First.", voice: nil, instructions: nil)) }
        #expect(await eventually { sent(socket, "response.create").count == 1 })
        // Queued before the stop. Asked for inside the task instead, it could start after stopAll on a busy machine and
        // then (rightly) not be cancelled.
        let secondLine = client.speak("Second.", voice: nil, instructions: nil)
        let second = Task { try await collect(secondLine) }

        await client.stopAll()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
        #expect(await eventually { sent(socket, "response.cancel").count == 1 })
        #expect(sent(socket, "conversation.item.create").count == 1)
        await client.disconnect()
    }

    @Test func reconnectsWhenTheServerClosedTheSocket() async throws {
        let first = FakeWebSocket(), second = FakeWebSocket()
        ScriptedServer(audio: lineChunks).install(on: first)
        ScriptedServer(audio: lineChunks).install(on: second)
        let connector = SocketSequence([first, second])
        let client = OpenAIRealtimeSpeechClient(context: makeContext(connector))

        _ = try await collect(client.speak("One.", voice: nil, instructions: nil))
        #expect(await eventually { sent(first, "conversation.item.delete").count == 2 })
        await first.close()  // e.g. the 60-minute session limit
        // The next line comes once the client has seen the close, as it would long after a real session ended.
        let giveUp = ContinuousClock.now + .seconds(10)
        while await client.isConnected, ContinuousClock.now < giveUp { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await !client.isConnected)

        let events = try await collect(client.speak("Two.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(connector.connectCount == 2)
        #expect(types(second).prefix(3) == ["session.update", "conversation.item.create", "response.create"])
        await client.disconnect()
    }

    @Test func emptyLineFinishesWithoutConnecting() async throws {
        let socket = FakeWebSocket()
        let client = OpenAIRealtimeSpeechClient(context: makeContext(socket))
        #expect(try await collect(client.speak("  \n", voice: nil, instructions: nil)) == [.lineFinished])
        #expect(socket.connectRequests.isEmpty)
    }
}
