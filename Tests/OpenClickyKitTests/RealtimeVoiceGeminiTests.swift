import Foundation
import Testing
@testable import OpenClickyKit

/// The Gemini Live native-audio adapter against a scripted socket. The live check is in
/// docs/evidence/feat-realtime-voice/.
@Suite struct RealtimeVoiceGeminiTests {
    static let key = "AIza-test-GEMINI-SECRET"
    typealias Events = RealtimeVoiceOpenAITests.Events

    static func context(_ socket: FakeWebSocket) -> ProviderContext {
        ProviderContext(provider: ProviderConfig(id: "gemini-live", dialect: .geminiLive,
                                                 baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta"), credential: "gemini"),
                        apiKey: key, http: FakeHTTPTransport([]), webSocket: socket)
    }

    static func acceptingSocket() -> FakeWebSocket {
        let socket = FakeWebSocket()
        socket.onSend = { message, socket in
            guard case .text(let text) = message, (try? JSONValue.parse(text))?["setup"] != nil else { return }
            socket.pushJSON(["setupComplete": [:]])
        }
        return socket
    }

    static let tool = ToolSpec(name: "save_memory", description: "Remember something.", parameters: [
        "type": "object",
        "properties": ["text": ["type": "string", "description": "What to remember."],
                       "limit": ["type": "integer", "minimum": 1, "maximum": 10]],
        "required": ["text"],
        "additionalProperties": false,
    ])

    static func connect(_ socket: FakeWebSocket, configuration: RealtimeSessionConfiguration? = nil,
                        options: GeminiLiveVoiceClient.Options = .init()) async throws -> any RealtimeVoiceSession {
        let client = GeminiLiveVoiceClient(context: context(socket), model: "gemini-3.8-live", defaultVoice: "Puck", options: options)
        return try await client.connect(configuration ?? RealtimeSessionConfiguration(instructions: "Be brief.", tools: [tool]))
    }

    static func sent(_ socket: FakeWebSocket, _ key: String) -> [JSONValue] {
        socket.sentJSON.compactMap { $0[key] }
    }

    static func audioPart(_ data: Data) -> JSONValue {
        ["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": .string(data.base64EncodedString())]]
    }

    // MARK: - Setup

    @Test func connectSendsSetupWithTheKeyInAHeader() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket, configuration: RealtimeSessionConfiguration(
            instructions: "Be brief.", tools: [Self.tool], voice: "Kore",
            turnDetection: .serverVAD(RealtimeVADSettings(threshold: 0.72, prefixPadding: .milliseconds(200), silence: .milliseconds(700),
                                                          interruptsResponse: false)),
            language: "en-US"))
        #expect(session.inputFormat == .speech16k && session.outputFormat == .speech24k)
        #expect(!session.features.deletesItems && !session.features.truncatesToHeardAudio)

        let request = try #require(socket.connectRequests.first)
        #expect(request.url?.absoluteString
            == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.key)
        #expect(!(request.url?.absoluteString.contains(Self.key) ?? true))

        let setup = try #require(Self.sent(socket, "setup").first)
        #expect(setup["model"] == "models/gemini-3.8-live")
        #expect(setup["generationConfig"] == ["responseModalities": ["AUDIO"],
                                              "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": "Kore"]]]])
        #expect(setup["systemInstruction"] == ["parts": [["text": "Be brief."]]])
        #expect(setup["inputAudioTranscription"] == ["languageCodes": ["en-US"]])
        #expect(setup["outputAudioTranscription"] == [:])
        #expect(setup["contextWindowCompression"] == ["slidingWindow": [:]])
        #expect(setup["realtimeInputConfig"] == [
            "automaticActivityDetection": ["disabled": false, "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                                           "prefixPaddingMs": 200, "silenceDurationMs": 700],
            "activityHandling": "NO_INTERRUPTION",
        ])
        // The schema loses keywords outside Gemini's OpenAPI subset; the rest stays.
        #expect(setup["tools"] == [["functionDeclarations": [[
            "name": "save_memory", "description": "Remember something.",
            "parameters": ["type": "object",
                           "properties": ["text": ["type": "string", "description": "What to remember."],
                                          "limit": ["type": "integer", "minimum": 1, "maximum": 10]],
                           "required": ["text"]],
        ]]]])
        await session.close()
        #expect(socket.isClosed)
    }

    @Test func toolsWithoutArgumentsSendNoParametersAndBehaviorCanBeForced() {
        let spec = ToolSpec(name: "capture_screen", description: "Look.", parameters: ["type": "object", "properties": [:]])
        #expect(GeminiLiveVoiceWire.declaration(spec, behavior: nil) == ["name": "capture_screen", "description": "Look."])
        #expect(GeminiLiveVoiceWire.declaration(spec, behavior: .blocking)["behavior"] == "BLOCKING")
        let defaultVoice = GeminiLiveVoiceWire.setup(model: "gemini-3.8-live", configuration: RealtimeSessionConfiguration(instructions: "x",
            transcribeInput: false), voice: nil, behavior: nil, compressContext: false)
        #expect(defaultVoice["setup"]?["generationConfig"] == ["responseModalities": ["AUDIO"]])
        #expect(defaultVoice["setup"]?["inputAudioTranscription"] == nil)
        #expect(defaultVoice["setup"]?["tools"] == nil)
        #expect(defaultVoice["setup"]?["contextWindowCompression"] == nil)
    }

    @Test func aRefusedSetupFailsTheConnect() async throws {
        let socket = FakeWebSocket()
        socket.onSend = { _, socket in
            socket.pushJSON(["error": ["code": 400, "message": "models/nope is not found", "status": "NOT_FOUND"]])
        }
        do {
            _ = try await Self.connect(socket)
            Issue.record("connect should have failed")
        } catch let error as ProviderError {
            #expect(error.status == 400)
            #expect(error.message.contains("NOT_FOUND"))
            #expect(!error.description.contains(Self.key))
        }
        #expect(socket.isClosed)
    }

    @Test func aSocketClosedBeforeSetupExplainsItself() async throws {
        let socket = FakeWebSocket()
        socket.onSend = { _, socket in socket.serverClose(with: ProviderError(provider: "x", message: "code 1008: API key not valid")) }
        do {
            _ = try await Self.connect(socket)
            Issue.record("connect should have failed")
        } catch let error as ProviderError {
            #expect(error.message.contains("before it was set up"))
            #expect(error.message.contains("API key not valid"))
        }
    }

    // MARK: - Conversation

    @Test func aSpokenTurnAndItsReply() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        await session.sendAudio(Data(count: 8_000))
        #expect(await waitUntil { Self.sent(socket, "realtimeInput").count == 3 })
        #expect(Self.sent(socket, "realtimeInput").allSatisfy { $0["audio"]?["mimeType"] == "audio/pcm;rate=16000" })

        socket.pushJSON(["voiceActivity": ["type": "ACTIVITY_START", "audioOffset": "0.2s"]])
        socket.pushJSON(["serverContent": ["inputTranscription": ["text": "What time"]]])
        socket.pushJSON(["serverContent": ["inputTranscription": ["text": " is it?"]]])
        socket.pushJSON(["voiceActivity": ["type": "ACTIVITY_END"]])
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([1, 2, 3]))]],
                                           "outputTranscription": ["text": "It's noon."]]])
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([4])), Self.audioPart(Data([5, 6]))]]]])
        socket.pushJSON(["serverContent": ["generationComplete": true]])
        socket.pushJSON(["usageMetadata": ["promptTokenCount": 40, "responseTokenCount": 12,
                                           "responseTokensDetails": [["modality": "AUDIO", "tokenCount": 12]]],
                         "serverContent": ["turnComplete": true]])
        #expect(await waitUntil { events.all.count >= 12 })
        let all = events.all
        #expect(all[0] == .userSpeechStarted)
        #expect(all[1] == .userTranscript(text: "What time", isFinal: false, itemID: "gemini-user-1"))
        #expect(all[2] == .userTranscript(text: "What time is it?", isFinal: false, itemID: "gemini-user-1"))
        #expect(all[3] == .userSpeechStopped)
        #expect(all[4] == .userTurnCommitted(itemID: "gemini-user-1"))
        #expect(all[5] == .responseStarted(responseID: "gemini-turn-1"))
        #expect(all[6] == .audio(Data([1, 2]), itemID: "gemini-turn-1"))
        #expect(all[7] == .assistantTranscriptDelta("It's noon.", itemID: "gemini-turn-1"))
        #expect(all[8] == .audio(Data([3, 4]), itemID: "gemini-turn-1"))
        #expect(all[9] == .audio(Data([5, 6]), itemID: "gemini-turn-1"))
        #expect(all[10] == .responseFinished(RealtimeResponseSummary(
            responseID: "gemini-turn-1", status: .completed, itemIDs: ["gemini-turn-1"], transcript: "It's noon.",
            usage: RealtimeUsage(inputTokens: 40, outputTokens: 12, outputAudioTokens: 12))))
        #expect(all[11] == .userTranscript(text: "What time is it?", isFinal: true, itemID: "gemini-user-1"))
        await session.close()
    }

    @Test func lateInputTranscriptionStaysWithItsTurn() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["voiceActivity": ["type": "ACTIVITY_START"]])
        socket.pushJSON(["serverContent": ["inputTranscription": ["text": "Open my"]]])
        socket.pushJSON(["voiceActivity": ["type": "ACTIVITY_END"]])
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c1", "name": "send_to_higher_model", "args": ["question": "q"]]]]])
        socket.pushJSON(["serverContent": ["turnComplete": true]])
        // The rest of the user's words arrive after their turn was settled, while the tool is still running.
        socket.pushJSON(["serverContent": ["inputTranscription": ["text": " calendar"]]])
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([1, 2]))]]]])
        #expect(await waitUntil { events.all.count >= 11 })
        let all = events.all
        #expect(all.filter { if case .userTurnCommitted = $0 { true } else { false } } == [.userTurnCommitted(itemID: "gemini-user-1")])
        #expect(all.contains(.userTranscript(text: "Open my", isFinal: true, itemID: "gemini-user-1")))
        #expect(all.contains(.userTranscript(text: "Open my calendar", isFinal: true, itemID: "gemini-user-1")))
        #expect(all.last == .audio(Data([1, 2]), itemID: "gemini-turn-2"))
        await session.close()
    }

    @Test func theServerInterruptingTheReplyIsABargeIn() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([1, 2]))]]]])
        socket.pushJSON(["serverContent": ["interrupted": true]])
        #expect(await waitUntil { events.all.count == 4 })
        #expect(events.all[2] == .userSpeechStarted)
        #expect(events.all[3] == .responseFinished(RealtimeResponseSummary(responseID: "gemini-turn-1", status: .interrupted,
                                                                         itemIDs: ["gemini-turn-1"])))
        await session.close()
    }

    @Test func interruptingDropsTheRestOfTheTurnOnThisSide() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([1, 2]))]]]])
        #expect(await waitUntil { events.all.count == 2 })
        await session.interrupt(itemID: "gemini-turn-1", heard: 0.01, clearInput: true)
        #expect(await waitUntil { events.all.count == 3 })
        #expect(events.all[2] == .responseFinished(RealtimeResponseSummary(responseID: "gemini-turn-1", status: .cancelled,
                                                                         itemIDs: ["gemini-turn-1"])))
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([3, 4]))]], "outputTranscription": ["text": "more"]]])
        socket.pushJSON(["serverContent": ["turnComplete": true]])
        // The next turn plays again.
        socket.pushJSON(["serverContent": ["modelTurn": ["parts": [Self.audioPart(Data([7, 8]))]]]])
        #expect(await waitUntil { events.all.count == 5 })
        #expect(events.all[3] == .responseStarted(responseID: "gemini-turn-2"))
        #expect(events.all[4] == .audio(Data([7, 8]), itemID: "gemini-turn-2"))
        await session.close()
    }

    @Test func toolCallsAnswersAndWithdrawals() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["toolCall": ["functionCalls": [
            ["id": "c1", "name": "save_memory", "args": ["text": "Likes tea"]],
            ["id": "c2", "name": "capture_screen"],
        ]]])
        #expect(await waitUntil { events.all.count == 3 })
        #expect(events.all[0] == .responseStarted(responseID: "gemini-turn-1"))
        #expect(events.all[1] == .toolCall(RealtimeToolCall(callID: "c1", name: "save_memory", arguments: "{\"text\":\"Likes tea\"}")))
        #expect(events.all[2] == .toolCall(RealtimeToolCall(callID: "c2", name: "capture_screen", arguments: "{}")))

        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "save_memory", output: ["status": "saved"]))
        #expect(await waitUntil { Self.sent(socket, "toolResponse").count == 1 })
        #expect(Self.sent(socket, "toolResponse")[0] == ["functionResponses": [[
            "id": "c1", "name": "save_memory", "response": ["status": "saved", "scheduling": "WHEN_IDLE"],
        ]]])
        socket.pushJSON(["toolCallCancellation": ["ids": ["c2"]]])
        #expect(await waitUntil { events.all.count == 4 })
        #expect(events.all[3] == .toolCallsCancelled(["c2"]))
        await session.sendToolResult(RealtimeToolResult(callID: "c2", name: "capture_screen", output: "late"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(Self.sent(socket, "toolResponse").count == 1)  // a withdrawn call gets no answer
        await session.close()
    }

    @Test func supersededAnswersAreSilent() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c1", "name": "web_search", "args": ["query": "x"]]]]])
        #expect(await waitUntil { events.all.count == 2 })
        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "web_search", output: "old news", respond: false))
        #expect(await waitUntil { Self.sent(socket, "toolResponse").count == 1 })
        #expect(Self.sent(socket, "toolResponse")[0]["functionResponses"]?.arrayValue?.first?["response"]
            == ["result": "old news", "scheduling": "SILENT"])
        await session.close()
    }

    @Test func aScreenshotForAToolCallRidesInItsResponse() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["toolCall": ["functionCalls": [["id": "c1", "name": "capture_screen", "args": [:]]]]])
        #expect(await waitUntil { events.all.count == 2 })
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        await session.addImage(jpeg, mimeType: "image/jpeg", caption: nil)
        await session.sendToolResult(RealtimeToolResult(callID: "c1", name: "capture_screen", output: ["status": "ok"]))
        #expect(await waitUntil { Self.sent(socket, "toolResponse").count == 1 })
        let response = Self.sent(socket, "toolResponse")[0]["functionResponses"]?.arrayValue?.first
        #expect(response?["parts"] == [["inlineData": ["mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]]])
        #expect(Self.sent(socket, "clientContent").isEmpty && Self.sent(socket, "realtimeInput").isEmpty)

        // With no call waiting, a picture becomes a conversation turn that doesn't end the user's turn.
        await session.addImage(jpeg, mimeType: "image/jpeg", caption: "The main display")
        #expect(await waitUntil { Self.sent(socket, "clientContent").count == 1 })
        #expect(Self.sent(socket, "clientContent")[0] == ["turns": [["role": "user", "parts": [
            ["inlineData": ["mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]], ["text": "The main display"],
        ]]], "turnComplete": false])
        await session.close()
    }

    @Test func videoFrameDeliveryIsStillAvailable() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket, options: .init(imageDelivery: .videoFrame))
        await session.addImage(Data([1, 2, 3]), mimeType: "image/png", caption: nil)
        #expect(await waitUntil { Self.sent(socket, "realtimeInput").count == 1 })
        #expect(Self.sent(socket, "realtimeInput")[0] == ["video": ["data": .string(Data([1, 2, 3]).base64EncodedString()), "mimeType": "image/png"]])
        await session.close()
    }

    @Test func manualTurnsMarkActivityAndTextNotes() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket, configuration: RealtimeSessionConfiguration(instructions: "x", turnDetection: .manual))
        #expect(Self.sent(socket, "setup").first?["realtimeInputConfig"] == ["automaticActivityDetection": ["disabled": true]])
        await session.sendAudio(Data(count: 320))
        await session.sendAudio(Data(count: 320))
        await session.endAudioTurn()
        await session.endAudioTurn()  // nothing open: no second activityEnd
        await session.addText("[App] Opened the page.", respond: false)
        await session.createResponse(instructions: nil)
        #expect(await waitUntil { Self.sent(socket, "clientContent").count == 2 })
        let inputs = Self.sent(socket, "realtimeInput")
        #expect(inputs.first == ["activityStart": [:]])
        #expect(inputs.filter { $0["activityStart"] != nil }.count == 1)
        #expect(inputs.last == ["activityEnd": [:]])
        #expect(inputs.filter { $0["activityEnd"] != nil }.count == 1)
        #expect(Self.sent(socket, "clientContent")[0] == ["turns": [["role": "user", "parts": [["text": "[App] Opened the page."]]]],
                                                         "turnComplete": false])
        #expect(Self.sent(socket, "clientContent")[1] == ["turnComplete": true])
        await session.close()
    }

    @Test func automaticTurnsFlushWithAudioStreamEnd() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        await session.endAudioTurn()
        #expect(await waitUntil { Self.sent(socket, "realtimeInput").count == 1 })
        #expect(Self.sent(socket, "realtimeInput")[0] == ["audioStreamEnd": true])
        await session.close()
    }

    @Test func goAwayIsAnnouncedAndTheCloseExplainsIt() async throws {
        let socket = Self.acceptingSocket()
        let session = try await Self.connect(socket)
        let events = Events(session)
        socket.pushJSON(["goAway": ["timeLeft": "5s"]])
        #expect(await waitUntil { events.all.count == 1 })
        #expect(events.all[0] == .goingAway(timeLeft: .seconds(5)))
        socket.serverClose(with: ProviderError(provider: "x", message: "code 1000"))
        #expect(await waitUntil { events.finished })
        let error = try #require(events.failure as? ProviderError)
        #expect(error.message.contains("announcing it would close"))
    }

    @Test func descriptionsNeverShowTheKey() {
        let client = GeminiLiveVoiceClient(context: Self.context(FakeWebSocket()))
        for text in [String(describing: client), String(reflecting: client), "\(client)"] { #expect(!text.contains(Self.key)) }
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(Self.key))
        #expect(client.model == "gemini-3.8-live" && client.defaultVoice == "Kore")
    }
}
