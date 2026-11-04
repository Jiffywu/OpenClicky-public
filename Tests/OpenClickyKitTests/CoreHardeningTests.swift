import Foundation
import Testing
@testable import OpenClickyKit

/// Shared fixes from the provider-adapter reviews: each test fails on the code before the fix.
@Suite struct CoreHardeningTests {
    // MARK: - JSONValue

    @Test(arguments: [1.5, 1e300, -1e300, Double.nan, Double.infinity, -Double.infinity, 9.3e18])
    func intValueIsNilForNumbersThatAreNotExactInts(_ value: Double) {
        // `Int(value)` traps on NaN, infinity and anything outside Int's range.
        #expect(JSONValue.number(value).intValue == nil)
    }

    @Test func intValueKeepsExactIntegers() {
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(-0.0).intValue == 0)
        #expect(JSONValue.number(-7).intValue == -7)
        #expect(JSONValue.string("3").intValue == nil)
    }

    @Test func nonFiniteNumbersEncodeAsNullInTheirOwnField() throws {
        let value: JSONValue = ["speed": .number(.nan), "gain": .number(.infinity), "n": 2, "list": [.number(-.infinity), 1.5]]
        // Before: JSONEncoder threw and the whole document became the text "null".
        #expect(value.jsonString() == #"{"gain":null,"list":[null,1.5],"n":2,"speed":null}"#)
        #expect(try JSONValue.parse(String(decoding: value.jsonData(), as: UTF8.self))["n"] == 2)
    }

    @Test func requestBodyWithANonFiniteNumberKeepsEveryOtherField() throws {
        let context = ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil)
        let request = context.jsonRequest(URL(string: "https://example.com/x")!, body: ["model": "m", "temperature": .number(.nan)])
        let body = try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        #expect(body == ["model": "m", "temperature": .null])
    }

    // MARK: - ProviderContext

    static let secretKey = "sk-live-SECRET-0123456789"
    static let secretHeader = "Bearer gateway-SECRET-header"

    static var secretContext: ProviderContext {
        ProviderContext(provider: ProviderConfig(id: "gateway", dialect: .openAIChat, baseURL: URL(string: "https://gw.example.com/v1"),
                                                 credential: "gw", headers: ["X-Gateway-Auth": secretHeader, "X-Title": "OpenClicky"]),
                        apiKey: secretKey)
    }

    @Test func providerContextNeverPrintsTheKeyOrHeaderValues() {
        let context = Self.secretContext
        var dumped = ""
        dump(context, to: &dumped)
        let renderings = [String(describing: context), String(reflecting: context), "\(context)", dumped,
                          String(describing: Mirror(reflecting: context).children.map { "\($0.label ?? ""): \($0.value)" })]
        for text in renderings {
            #expect(!text.contains("SECRET"), "leaked in: \(text)")
            #expect(text.contains("gateway"))
        }
        #expect(String(describing: context).contains("apiKey: <redacted>"))
        #expect(String(describing: context).contains("X-Gateway-Auth: <redacted>"))
        let keyless = ProviderContext(provider: ProviderConfig(id: "local", dialect: .openAIChat), apiKey: nil)
        #expect(String(describing: keyless).contains("apiKey: none"))
    }

    @Test func adapterHeadersWinOverProviderHeadersInAnyCase() {
        let provider = ProviderConfig(id: "p", dialect: .openAIChat,
                                      headers: ["authorization": "Bearer from-config", "X-TITLE": "OpenClicky", "anthropic-version": "2023-06-01"])
        let context = ProviderContext(provider: provider, apiKey: "k")
        // Repeat: dictionary order varies between runs, and the old merge let whichever came last win.
        for _ in 0..<50 {
            let request = context.jsonRequest(URL(string: "https://example.com")!, body: [:],
                                              headers: ["Authorization": "Bearer adapter", "Anthropic-Version": "2026-10-21"])
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer adapter")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
            #expect(request.value(forHTTPHeaderField: "x-title") == "OpenClicky")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
        let merged = ProviderContext.mergedHeaders(provider: ["a": "1", "B": "2"], adapter: ["b": "3"])
        #expect(merged.map(\.0) == ["a", "b"])
        #expect(merged.map(\.1) == ["1", "3"])
    }

    // MARK: - ProviderError

    @Test func providerErrorLocalizedDescriptionIsItsDescription() {
        let error: Error = ProviderError(provider: "api.openai.com", status: 401, message: "The server refused it.")
        // Adapters wrap transport errors with `localizedDescription`; before, this read "OpenClickyKit.ProviderError error 1".
        #expect(error.localizedDescription == "api.openai.com HTTP 401: The server refused it.")
    }

    // MARK: - Fakes

    @Test func fakeRecordsAreSafeToReadWhileRequestsRun() async throws {
        let fake = FakeHTTPTransport(Array(repeating: .body("{}"), count: 200))
        let socket = FakeWebSocket()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    _ = try await fake.data(for: URLRequest(url: URL(string: "https://example.com/\(index)")!))
                    try await socket.send(.text("\(index)"))
                    _ = try await socket.connect(URLRequest(url: URL(string: "wss://example.com/\(index)")!))
                }
                group.addTask { _ = (fake.requests.count, fake.streamModes.count, socket.sent.count, socket.connectRequests.count) }
            }
            try await group.waitForAll()
        }
        #expect(fake.requests.count == 200)
        #expect(socket.sent.count == 200)
        #expect(socket.connectRequests.count == 200)
        #expect(fake.streamModes.allSatisfy { $0 == nil })
    }

    @Test func fakeRecordsTheStreamModeAskedFor() async throws {
        let fake = FakeHTTPTransport([.body("a"), .body("b"), .body("c")])
        let request = URLRequest(url: URL(string: "https://example.com")!)
        _ = try await fake.stream(for: request)
        _ = try await fake.stream(for: request, mode: .binary)
        _ = try await fake.checkedStream(for: request, provider: "p", mode: .binary)
        #expect(fake.streamModes == [.lines, .binary, .binary])
    }

    @Test func fakeWebSocketServerCloseThrowsTheGivenErrorAfterQueuedMessages() async throws {
        let socket = FakeWebSocket(inbound: [.text("last words")])
        socket.serverClose(with: ProviderError(provider: "ws", message: "The server closed the WebSocket (code 4001: nope)."))
        #expect(try await socket.receive() == .text("last words"))
        let error = await #expect(throws: ProviderError.self) { _ = try await socket.receive() }
        #expect(error?.message.contains("4001") == true)
    }

    // MARK: - WebSocket errors

    @Test func refusedUpgradeBecomesProviderErrorWithStatus() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.deepgram.com/v1/listen")!, statusCode: 401, httpVersion: "HTTP/1.1",
                                       headerFields: nil)
        let error = URLSessionWebSocketConnection.describe(URLError(.badServerResponse), response: response, closeCode: 0,
                                                           closeReason: nil, label: "api.deepgram.com")
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.status == 401)
        #expect(providerError.provider == "api.deepgram.com")
    }

    @Test func serverCloseBecomesProviderErrorWithCodeAndReason() throws {
        let switched = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 101, httpVersion: "HTTP/1.1", headerFields: nil)
        let error = URLSessionWebSocketConnection.describe(POSIXError(.ENOTCONN), response: switched, closeCode: 4001,
                                                           closeReason: Data("bad model".utf8), label: "example.com")
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.status == nil)
        #expect(providerError.message == "The server closed the WebSocket (code 4001: bad model).")
        // Nothing to add: the original error passes through.
        let plain = URLSessionWebSocketConnection.describe(URLError(.timedOut), response: switched, closeCode: 0, closeReason: nil,
                                                           label: "example.com")
        #expect((plain as? URLError)?.code == .timedOut)
    }

    @Test func deepgramNamesTheStatusOfARefusedUpgrade() async throws {
        let socket = FakeWebSocket()
        socket.serverClose(with: ProviderError(provider: "api.deepgram.com", status: 403, message: "refused"))
        let client = DeepgramListenClient(context: ProviderContext(
            provider: ProviderConfig(id: "deepgram", dialect: .deepgramListen, credential: "deepgram"), apiKey: "k", webSocket: socket))
        let session = try await client.startSession(language: "en", keywords: [])
        let error = await #expect(throws: ProviderError.self) { for try await _ in session.events {} }
        #expect(error?.provider == "deepgram")
        #expect(error?.status == 403)
        #expect(error?.message.contains("HTTP 403") == true)
    }

    // MARK: - Speech output uses binary streaming

    @Test func textToSpeechAdaptersAskForBinaryStreaming() async throws {
        let openAIFake = FakeHTTPTransport([.init(headers: ["Content-Type": "audio/pcm"], chunks: [Data([1, 0, 2, 0])])])
        let openAI = OpenAISpeechClient(context: ProviderContext(
            provider: ProviderConfig(id: "openai-speech", dialect: .openAISpeech, credential: "openai"), apiKey: "k", http: openAIFake))
        for try await _ in openAI.speak("Hello.", voice: nil, instructions: nil) {}
        #expect(openAIFake.streamModes == [.binary])

        let elevenFake = FakeHTTPTransport([.init(headers: ["Content-Type": "audio/pcm"], chunks: [Data([1, 0, 2, 0])])])
        let eleven = ElevenLabsSpeechClient(context: ProviderContext(
            provider: ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, credential: "elevenlabs"), apiKey: "k", http: elevenFake),
            defaultVoice: "voice123")
        for try await _ in eleven.speak("Hello.", voice: nil, instructions: nil) {}
        #expect(elevenFake.streamModes == [.binary])
    }

    // MARK: - Chat messages

    @Test func chatReplyCollectsProviderItemsAndPhase() {
        var reply = ChatReply()
        let items: [JSONValue] = [["type": "reasoning", "encrypted_content": "enc"],
                                  ["type": "message", "phase": "final_answer", "content": [["type": "output_text", "text": "Hi"]]]]
        for event: ChatEvent in [.reasoningDelta("think"), .textDelta("Hi"), .providerItems(dialect: "openai-responses", items: items),
                                 .usage(TokenUsage(inputTokens: 1)), .finished(.stop)] {
            reply.apply(event)
        }
        #expect(reply.message == ChatMessage(role: .assistant, content: [.text("Hi")], providerItems: items,
                                             providerDialect: "openai-responses", phase: "final_answer"))
        #expect(reply.reasoning == "think")
        #expect(reply.finishReason == .stop)
        #expect(reply.message.providerItems(for: "anthropic-messages").isEmpty)
        #expect(reply.message.providerItems(for: "openai-responses") == items)
    }

    @Test func oldMessageInitializersStillDefaultTheNewFields() {
        let message = ChatMessage(role: .assistant, content: [.text("x")], toolCalls: [], toolCallID: nil)
        #expect(message.providerItems.isEmpty && message.providerDialect == nil && message.phase == nil && !message.isError)
        #expect(ChatMessage.tool(callID: "c", result: "boom", isError: true).isError)
        #expect(!ChatMessage.tool(callID: "c", result: "ok").isError)
    }

    // MARK: - Catalog

    @Test func catalogHasTheNewTranscriptionModelVoicesAndShutdownNotes() throws {
        let catalog = try ModelCatalog.builtIn()
        let transcribe = try #require(catalog.model("gpt-transcribe", servedBy: .openAITranscription))
        #expect(transcribe.kind == .speechToText)
        #expect(transcribe.has(.streaming))
        #expect(catalog.candidates(for: .stt, dialect: .openAITranscription).map(\.id).contains("gpt-transcribe"))

        let tts = try #require(catalog.model("gpt-4o-mini-tts", servedBy: .openAISpeech))
        #expect(Set(["fable", "nova", "onyx", "cedar", "marin"]).isSubset(of: Set(tts.voices ?? [])))
        #expect(tts.notes?.contains("2027-01-06") == true)
        #expect(catalog.model("gpt-4o-mini-transcribe", servedBy: .openAITranscription)?.notes?.contains("2027-02-26") == true)

        let apple = try #require(catalog.model("on-device", servedBy: .appleSpeech))
        #expect(apple.notes?.contains("Apple's servers") == true)
        #expect(ProviderPreset.all.first { $0.id == "apple-speech" }?.name.contains("Apple's servers") == true)
    }
}
