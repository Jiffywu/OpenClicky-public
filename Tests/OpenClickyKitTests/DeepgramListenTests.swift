import Foundation
import Testing
@testable import OpenClickyKit

/// Deepgram live transcription against a scripted socket. Payloads follow the shapes in Deepgram's docs
/// (live-streaming-audio, endpointing, speech-started, utterance-end, close-stream, listen-streaming reference).
/// WebSocket frames arrive whole, so instead of byte chunking these tests push frames one at a time while the
/// consumer is reading, and check each event comes out before the next frame goes in.
@Suite(.timeLimit(.minutes(1)))
struct DeepgramListenTests {
    static let testKey = "dg-test-key-not-real"

    // MARK: Payloads

    /// A Results frame shaped like the live-streaming-audio example.
    static func results(_ transcript: String, isFinal: Bool, speechFinal: Bool = false, start: Double = 0,
                        duration: Double = 1, fromFinalize: Bool = false) -> String {
        let words = transcript.split(separator: " ").enumerated().map { index, word in
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let wordStart = start + Double(index) * 0.3
            return #"{"word":"\#(bare)","start":\#(wordStart),"end":\#(wordStart + 0.28),"confidence":0.9978,"punctuated_word":"\#(word)"}"#
        }.joined(separator: ",")
        return #"{"type":"Results","channel_index":[0,1],"duration":\#(duration),"start":\#(start),"is_final":\#(isFinal),"speech_final":\#(speechFinal),"channel":{"alternatives":[{"transcript":"\#(transcript)","confidence":0.99964225,"words":[\#(words)]}]},"metadata":{"request_id":"52cc0efe-fa77-4aa7-b79c-0dda09de2f14","model_info":{"name":"general-nova-3","version":"2025-01-01.0","arch":"nova-3"},"model_uuid":"c0d1a568-ce81-4fea-97e7-bd45cb1fdf3c"},"from_finalize":\#(fromFinalize)}"#
    }

    /// Verbatim from the live-streaming-audio doc, pretty-printed as published.
    static let docResults = """
    {
      "type": "Results",
      "channel_index": [
        0,
        1
      ],
      "duration": 1.98,
      "start": 5.99,
      "is_final": true,
      "speech_final": true,
      "channel": {
        "alternatives": [
          {
            "transcript": "Tell me more about this.",
            "confidence": 0.99964225,
            "words": [
              { "word": "tell", "start": 6.0699997, "end": 6.3499994, "confidence": 0.99782443, "punctuated_word": "Tell" },
              { "word": "me", "start": 6.3499994, "end": 6.6299996, "confidence": 0.9998324, "punctuated_word": "me" },
              { "word": "more", "start": 6.6299996, "end": 6.79, "confidence": 0.9995466, "punctuated_word": "more" },
              { "word": "about", "start": 6.79, "end": 7.0299997, "confidence": 0.99984455, "punctuated_word": "about" },
              { "word": "this", "start": 7.0299997, "end": 7.2699995, "confidence": 0.99964225, "punctuated_word": "this" }
            ]
          }
        ]
      },
      "metadata": {
        "request_id": "52cc0efe-fa77-4aa7-b79c-0dda09de2f14",
        "model_info": { "name": "2-general-nova", "version": "2024-01-18.26916", "arch": "nova-2" },
        "model_uuid": "c0d1a568-ce81-4fea-97e7-bd45cb1fdf3c"
      },
      "from_finalize": false
    }
    """

    /// The endpointing doc's sample: no `type`, and `speech_final: true` with `is_final: false`.
    static let endpointingDocResults = #"{"channel_index":[0,1],"duration":1.039875,"start":0.0,"is_final":false,"speech_final":true,"channel":{"alternatives":[{"transcript":"another big","confidence":0.9600255,"words":[{"word":"another","start":0.2971154,"end":0.7971154,"confidence":0.9588303},{"word":"big","start":0.85173076,"end":1.039875,"confidence":0.9600255}]}]}}"#
    static let speechStarted = #"{"type":"SpeechStarted","channel":[0,1],"timestamp":9.54}"#
    static func utteranceEnd(_ lastWordEnd: Double) -> String { #"{"channel":[0,1],"last_word_end":\#(lastWordEnd),"type":"UtteranceEnd"}"# }
    static let metadata = #"{"type":"Metadata","transaction_key":"deprecated","request_id":"8c8ebea9-dbec-45fa-a035-e4632cb05b5f","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","created":"2024-08-29T22:37:55.202Z","duration":0.0,"channels":0}"#
    static let closeStream = WebSocketMessage.text(#"{"type":"CloseStream"}"#)
    static let keepAlive = WebSocketMessage.text(#"{"type":"KeepAlive"}"#)

    // MARK: Helpers

    static func client(_ connector: any WebSocketConnector, model: String = "nova-3", baseURL: String? = "wss://api.deepgram.com/v1/listen",
                       apiKey: String? = testKey, headers: [String: String]? = nil,
                       options: DeepgramListenClient.Options = .init()) -> DeepgramListenClient {
        let provider = ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: baseURL.flatMap(URL.init(string:)),
                                      credential: "deepgram", headers: headers)
        let context = ProviderContext(provider: provider, apiKey: apiKey, http: FakeHTTPTransport([]), webSocket: connector)
        return DeepgramListenClient(context: context, model: model, options: options)
    }

    static func collect(_ events: AsyncThrowingStream<TranscriptEvent, Error>) async throws -> [TranscriptEvent] {
        var seen: [TranscriptEvent] = []
        for try await event in events { seen.append(event) }
        return seen
    }

    /// The limit only guards against a hang: a busy machine can take far longer than an idle one.
    static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    static func keepAliveCount(_ sent: [WebSocketMessage]) -> Int { sent.filter { $0 == keepAlive }.count }

    // MARK: Request encoding

    @Test func requestCarriesStreamSettingsKeytermsAndTokenAuth() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket, headers: ["X-Trace": "abc"])
            .startSession(language: "en-US", keywords: ["OpenClicky", "three.js", "C++ code", "  OpenClicky ", ""])
        await session.cancel()

        let request = try #require(socket.connectRequests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.host == "api.deepgram.com")
        #expect(components.path == "/v1/listen")
        #expect(components.percentEncodedQuery == "model=nova-3&encoding=linear16&sample_rate=16000&channels=1"
            + "&interim_results=true&smart_format=true&punctuate=true&vad_events=true&utterance_end_ms=1000"
            + "&endpointing=300&language=en-US&keyterm=OpenClicky&keyterm=three.js&keyterm=C%2B%2B%20code")
        #expect(components.queryItems?.filter { $0.name == "keyterm" }.map(\.value) == ["OpenClicky", "three.js", "C++ code"])
        #expect(components.queryItems?.contains { $0.name == "keywords" } == false)

        // The key travels only in the Authorization header, in Deepgram's "Token <key>" form.
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "Token \(Self.testKey)")
        #expect(!url.absoluteString.contains(Self.testKey))
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "abc")
    }

    @Test func olderModelsUseKeywordsAndBaseURLsAreNormalized() async throws {
        let socket = FakeWebSocket()
        let options = DeepgramListenClient.Options(endpointingMs: nil, utteranceEndMs: nil)
        let session = try await Self.client(socket, model: "nova-2", apiKey: nil, options: options)
            .startSession(language: nil, keywords: ["snuffleupagus"])
        await session.cancel()

        let request = try #require(socket.connectRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let items = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "model" }?.value == "nova-2")
        #expect(items.first { $0.name == "keywords" }?.value == "snuffleupagus")
        #expect(!items.contains { ["keyterm", "language", "endpointing", "utterance_end_ms"].contains($0.name) })

        func base(_ baseURL: String?) -> String {
            let url = Self.client(socket, baseURL: baseURL).listenURL(language: nil, keywords: [])
            return url.absoluteString.components(separatedBy: "model=").first ?? ""
        }
        #expect(base(nil) == "wss://api.deepgram.com/v1/listen?")
        #expect(base("https://api.deepgram.com/v1") == "wss://api.deepgram.com/v1/listen?")
        #expect(base("ws://10.0.0.5:8080") == "ws://10.0.0.5:8080/v1/listen?")
        #expect(base("wss://dg.example.com/v1/listen?tag=clicky") == "wss://dg.example.com/v1/listen?tag=clicky&")
        #expect(DeepgramListenClient.searchTerms((0..<150).map { "term\($0)" }).count == 100)
        #expect(DeepgramListenClient(context: ProviderContext(provider: ProviderConfig(id: "d", dialect: .deepgramListen), apiKey: nil)).model == "nova-3")
        #expect(Self.client(socket).inputFormat == .speech16k)
    }

    // MARK: Streaming

    @Test func resultsStreamAsTheyArrive() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        var events = session.events.makeAsyncIterator()

        // The interim/final sequence from Deepgram's endpointing and interim-results guide.
        socket.push(.text(Self.speechStarted))
        #expect(try await events.next() == .speechStarted)
        socket.push(.text(Self.results("yeah so", isFinal: false, duration: 1.1)))
        #expect(try await events.next() == .interim("yeah so"))
        socket.push(.text(Self.results("yeah so my credit card number", isFinal: false, duration: 2.2)))
        #expect(try await events.next() == .interim("yeah so my credit card number"))
        socket.push(.text(Self.results("yeah so my credit card number is two two", isFinal: true, duration: 3.26)))
        #expect(try await events.next() == .final("yeah so my credit card number is two two"))
        socket.push(.text(Self.results("two two three three", isFinal: false, start: 3.26, duration: 1.84)))
        #expect(try await events.next() == .interim(" two two three three"))
        socket.push(.text(Self.results("two two three three three three", isFinal: true, speechFinal: true, start: 3.26, duration: 2.24)))
        #expect(try await events.next() == .final(" two two three three three three"))
        #expect(try await events.next() == .utteranceEnd)

        // speech_final already ended that utterance, so the UtteranceEnd that follows it is not reported again.
        socket.push(.text(Self.utteranceEnd(5.5)))
        socket.push(.text(Self.results("", isFinal: false, start: 5.5)))
        socket.push(.text(Self.speechStarted))
        #expect(try await events.next() == .speechStarted)

        socket.push(.text(Self.docResults))
        #expect(try await events.next() == .final(" Tell me more about this."))
        #expect(try await events.next() == .utteranceEnd)

        await session.cancel()
        #expect(try await events.next() == nil)
        #expect(socket.isClosed)
    }

    @Test func finishSendsCloseStreamAndWaitsForFlushedResults() async throws {
        let socket = FakeWebSocket()
        socket.onSend = { message, ws in
            guard message == Self.closeStream else { return }
            ws.push(.text(Self.results("and that's all.", isFinal: true, speechFinal: true, start: 0.4, duration: 1.2)))
            ws.push(.text(Self.metadata))
        }
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        let reader = Task { try await Self.collect(session.events) }

        let first = Data(repeating: 0x11, count: 3200), second = Data(repeating: 0x22, count: 1600)
        await session.send(first)
        await session.send(Data())  // never sent: an empty frame closes Deepgram's stream
        await session.send(second)
        socket.push(.text(Self.results("and that", isFinal: false, duration: 0.8)))
        await session.finish()
        await session.send(Data([1, 2, 3]))  // after finish: dropped

        #expect(try await reader.value == [.interim("and that"), .final("and that's all."), .utteranceEnd])
        #expect(socket.sent == [.binary(first), .binary(second), Self.closeStream])
        #expect(socket.isClosed)
    }

    @Test func serverClosingAfterCloseStreamEndsTheStreamNormally() async throws {
        let socket = FakeWebSocket()
        socket.onSend = { message, ws in
            guard message == Self.closeStream else { return }
            ws.push(.text(Self.results("done", isFinal: true, fromFinalize: true)))
            Task { await ws.close() }
        }
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        await session.send(Data(repeating: 0, count: 640))
        await session.finish()
        #expect(try await Self.collect(session.events) == [.final("done")])
    }

    @Test func finishGivesUpWhenDeepgramNeverAnswers() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket, options: .init(finishTimeout: .milliseconds(50)))
            .startSession(language: nil, keywords: [])
        await session.finish()
        #expect(try await Self.collect(session.events) == [])
        #expect(socket.sent == [Self.closeStream])
        #expect(socket.isClosed)
    }

    @Test func keepAliveGoesOutAsTextWhileIdleAndStopsOnFinish() async throws {
        let socket = FakeWebSocket()
        let log = SentLog(socket)
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .milliseconds(30), finishTimeout: .milliseconds(100)))
            .startSession(language: nil, keywords: [])
        #expect(await Self.eventually { Self.keepAliveCount(log.messages) >= 2 })
        #expect(log.messages.allSatisfy { $0 == Self.keepAlive })

        await session.send(Data(repeating: 7, count: 320))
        #expect(await Self.eventually { log.messages.last == Self.keepAlive && log.messages.contains(.binary(Data(repeating: 7, count: 320))) })

        await session.finish()
        #expect(await Self.eventually { log.messages.last == Self.closeStream })
        let sentAtFinish = log.messages.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.messages.count == sentAtFinish)
        #expect(log.messages.last == Self.closeStream)
        #expect(socket.isClosed)
    }

    // MARK: Errors

    @Test func errorFrameEndsTheSessionWithProviderError() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        socket.push(.text(Self.results("hello", isFinal: false)))
        socket.push(.text(#"{"type":"Error","variant":"SchemaError","description":"Failed to parse client message.","message":"{\"type\":\"Bogus\"}"}"#))

        var seen: [TranscriptEvent] = []
        do {
            for try await event in session.events { seen.append(event) }
            Issue.record("expected the Error frame to throw")
        } catch let error as ProviderError {
            #expect(error.provider == "deepgram")
            #expect(error.status == nil)
            #expect(error.message == "SchemaError: Failed to parse client message.")
        }
        #expect(seen == [.interim("hello")])
        #expect(socket.isClosed)
    }

    @Test func unexpectedCloseThrowsProviderError() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        var events = session.events.makeAsyncIterator()
        socket.push(.text(Self.results("hel", isFinal: false)))
        #expect(try await events.next() == .interim("hel"))

        await socket.close()  // e.g. Deepgram's 1011 NET-0001 close
        do {
            _ = try await events.next()
            Issue.record("expected the close to throw")
        } catch let error as ProviderError {
            #expect(error.status == nil)
            #expect(error.message.hasPrefix("Deepgram connection failed while streaming"))
        }
    }

    @Test func connectFailuresSurfaceAsProviderErrors() async throws {
        struct FailingConnector: WebSocketConnector {
            let error: any Error
            func connect(_ request: URLRequest) async throws -> any WebSocketConnection { throw error }
        }
        // A transport that reports the failed upgrade's status keeps it.
        let rejected = ProviderError(provider: "deepgram", status: 401, message: "INVALID_AUTH: Invalid credentials.")
        let passed = await #expect(throws: ProviderError.self) {
            _ = try await Self.client(FailingConnector(error: rejected)).startSession(language: nil, keywords: [])
        }
        #expect(passed?.status == 401)
        #expect(passed?.message == "INVALID_AUTH: Invalid credentials.")

        let wrapped = await #expect(throws: ProviderError.self) {
            _ = try await Self.client(FailingConnector(error: URLError(.cannotConnectToHost))).startSession(language: nil, keywords: [])
        }
        #expect(wrapped?.provider == "deepgram")
        #expect(wrapped?.message.hasPrefix("Deepgram connection failed while connecting") == true)

        #expect(DeepgramListenClient.errorMessage(try JSONValue.parse(#"{"err_code":"INVALID_AUTH","err_msg":"Invalid credentials.","request_id":"uuid"}"#))
            == "INVALID_AUTH: Invalid credentials.")
        #expect(DeepgramListenClient.errorMessage(try JSONValue.parse(#"{"category":"INVALID_JSON","message":"Invalid JSON submitted.","details":"x","request_id":"uuid"}"#))
            == "INVALID_JSON: Invalid JSON submitted.")
    }

    // MARK: Cancellation

    @Test func cancellingTheConsumerClosesTheSocket() async throws {
        let socket = FakeWebSocket()
        let log = SentLog(socket)
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .milliseconds(20)))
            .startSession(language: nil, keywords: [])
        let firstEvent = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await _ in session.events { firstEvent.continuation.yield() }
        }
        socket.push(.text(Self.results("hello", isFinal: false)))
        for await _ in firstEvent.stream { break }

        consumer.cancel()
        _ = await consumer.result
        #expect(await Self.eventually { socket.isClosed })
        let sentAfterClose = log.messages.count
        await session.send(Data(repeating: 1, count: 320))
        try await Task.sleep(for: .milliseconds(60))
        #expect(log.messages.count == sentAfterClose)
        #expect(!log.messages.contains(Self.closeStream))
    }

    @Test func cancelAbandonsTheStreamWithoutCloseStream() async throws {
        let socket = FakeWebSocket()
        let log = SentLog(socket)
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        let reader = Task { try await Self.collect(session.events) }
        await session.send(Data(repeating: 3, count: 320))
        #expect(await Self.eventually { !log.messages.isEmpty })
        await session.cancel()
        #expect(try await reader.value == [])
        #expect(log.messages == [.binary(Data(repeating: 3, count: 320))])
        #expect(socket.isClosed)
    }

    // MARK: Review: ordering, adversarial framing, redaction

    @Test func finishFromAnotherTaskStillGoesOutAfterAudioAlreadyHandedOver() async throws {
        // A capture task and a key-release task: the last audio is still being written when finish() arrives.
        let socket = GatedSocket()
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .zero, finishTimeout: .milliseconds(100)))
            .startSession(language: nil, keywords: [])
        let audio = Data(repeating: 9, count: 320)
        let capture = Task { await session.send(audio) }
        #expect(await Self.eventually { socket.blockedWrites == 1 })
        await session.finish()
        socket.openGate()
        _ = await capture.value
        _ = try await Self.collect(session.events)
        // CloseStream must not overtake audio: Deepgram stops taking audio after it.
        #expect(socket.sent == [.binary(audio), Self.closeStream])
    }

    @Test func audioGoesOutUnbufferedOneByteAtATime() async throws {
        let socket = FakeWebSocket()
        let log = SentLog(socket)
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .zero))
            .startSession(language: nil, keywords: [])
        var events = session.events.makeAsyncIterator()
        let audio = Data((0..<48).map { UInt8($0) })
        for (index, byte) in audio.enumerated() {
            await session.send(Data([byte]))
            // Every byte is its own binary frame, written without waiting for more audio.
            #expect(await Self.eventually { log.messages.count == index + 1 })
            if index == 23 {
                // Results come back while audio is still going out.
                socket.push(.text(Self.results("half way", isFinal: false)))
                #expect(try await events.next() == .interim("half way"))
            }
        }
        #expect(log.messages == audio.map { .binary(Data([$0])) })
        await session.cancel()
        #expect(try await events.next() == nil)
    }

    @Test func burstOfFramesKeepsOrderAndSkipsJunk() async throws {
        let socket = FakeWebSocket()
        let session = try await Self.client(socket).startSession(language: nil, keywords: [])
        // Every frame lands before the consumer reads anything.
        socket.push(.binary(Data(#"{"type":"Results"}"#.utf8)))  // Deepgram's messages are text; binary is ignored
        socket.push(.text("not json"))
        socket.push(.text("[1,2,3]"))
        socket.push(.text(#"{"type":"Results"}"#))
        socket.push(.text(#"{"type":"Results","is_final":true,"channel":{"alternatives":[]}}"#))
        socket.push(.text(Self.results("café 🎉", isFinal: false)))
        socket.push(.text(Self.metadata))  // Metadata before finish() does not end the stream
        socket.push(.text(Self.results("café 🎉 日本語です。", isFinal: true)))
        socket.push(.text(#"{"type":"ConfigureSuccess","request_id":"r","keyterms":["x"]}"#))
        socket.push(.text(Self.speechStarted))
        socket.push(.text(Self.utteranceEnd(2.4)))
        socket.push(.text(Self.results("next", isFinal: false, start: 2.5)))

        var events = session.events.makeAsyncIterator()
        var seen: [TranscriptEvent] = []
        for _ in 0..<5 { seen.append(try #require(try await events.next())) }
        #expect(seen == [.interim("café 🎉"), .final("café 🎉 日本語です。"), .speechStarted, .utteranceEnd, .interim(" next")])
        await session.cancel()
        #expect(try await events.next() == nil)
    }

    @Test func zeroKeepAliveIntervalSendsNoKeepAlive() async throws {
        let socket = FakeWebSocket()
        let log = SentLog(socket)
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .zero))
            .startSession(language: nil, keywords: [])
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.messages.isEmpty)
        await session.cancel()
    }

    @Test func refusedUpgradeNamesTheLikelyCause() async throws {
        // URLSession reports a WebSocket upgrade answered with HTTP 4xx/5xx as a bad server response.
        let refused = ScriptedSocket(inbound: [], then: URLError(.badServerResponse))
        let session = try await Self.client(refused).startSession(language: nil, keywords: [])
        let error = await #expect(throws: ProviderError.self) { _ = try await Self.collect(session.events) }
        #expect(error?.provider == "deepgram")
        #expect(error?.message.hasPrefix("Deepgram refused the WebSocket connection") == true)
        #expect(error?.message.contains(Self.testKey) == false)

        // Once Deepgram has answered, the same error is an ordinary dropped connection.
        let dropped = ScriptedSocket(inbound: [.text(Self.results("hi", isFinal: false))], then: URLError(.badServerResponse))
        let later = try await Self.client(dropped).startSession(language: nil, keywords: [])
        var events = later.events.makeAsyncIterator()
        #expect(try await events.next() == .interim("hi"))
        let laterError = await #expect(throws: ProviderError.self) { _ = try await events.next() }
        #expect(laterError?.message.hasPrefix("Deepgram connection failed while streaming") == true)
    }

    @Test func failedCloseStreamWriteIsAnError() async throws {
        // The socket takes audio but the CloseStream write fails, so Deepgram never flushes: that is not a clean finish.
        let socket = GatedSocket(failText: URLError(.networkConnectionLost))
        socket.openGate()
        let session = try await Self.client(socket, options: .init(keepAliveInterval: .zero))
            .startSession(language: nil, keywords: [])
        await session.send(Data(repeating: 5, count: 320))
        await session.finish()
        let error = await #expect(throws: ProviderError.self) { _ = try await Self.collect(session.events) }
        #expect(error?.message.hasPrefix("Deepgram connection failed while closing the stream") == true)
        #expect(socket.sent == [.binary(Data(repeating: 5, count: 320))])
    }

    @Test func descriptionsNeverShowTheKey() {
        let client = Self.client(FakeWebSocket())
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
            #expect(!text.contains(Self.testKey))
            #expect(text.contains("nova-3"))
        }
    }

    @Test func racingFinishCancelAndSendEndCleanly() async throws {
        for round in 0..<40 {
            let socket = FakeWebSocket()
            let log = SentLog(socket) { message, ws in
                if message == Self.closeStream { ws.push(.text(Self.metadata)) }
            }
            let session = try await Self.client(socket, options: .init(keepAliveInterval: .milliseconds(1), finishTimeout: .milliseconds(200)))
                .startSession(language: nil, keywords: [])
            let reader = Task { try await Self.collect(session.events) }
            await withTaskGroup(of: Void.self) { group in
                for byte in 1...6 { group.addTask { await session.send(Data([UInt8(byte), 0])) } }
                group.addTask { socket.push(.text(Self.results("x", isFinal: true))) }
                group.addTask { await session.finish() }
                if round.isMultiple(of: 2) { group.addTask { await session.cancel() } }
            }
            // finish() and cancel() are not errors, whichever wins.
            _ = try await reader.value
            #expect(socket.isClosed)
            let sent = log.messages
            if let close = sent.firstIndex(of: Self.closeStream) {
                #expect(!sent[close...].dropFirst().contains { if case .binary = $0 { true } else { false } })
                #expect(sent.filter { $0 == Self.closeStream }.count == 1)
            }
        }
    }

    // MARK: Mapping rules

    @Test func mapperHandlesDocumentedVariants() throws {
        var mapper = DeepgramTranscriptMapper()
        func map(_ text: String) throws -> [TranscriptEvent] { mapper.map(try JSONValue.parse(text)) }

        // Untyped, speech_final without is_final: settled, and the utterance ends.
        #expect(try map(Self.endpointingDocResults) == [.final("another big"), .utteranceEnd])
        // Repeated interims are reported once; an empty final after an interim clears it.
        #expect(try map(Self.results("um", isFinal: false)) == [.interim(" um")])
        #expect(try map(Self.results("um", isFinal: false)) == [])
        #expect(try map(Self.results("", isFinal: true)) == [.interim("")])
        // No speech_final (noisy room): UtteranceEnd ends the utterance, once.
        #expect(try map(Self.results("Testing. 123.", isFinal: true)) == [.final(" Testing. 123.")])
        #expect(try map(Self.utteranceEnd(2.395)) == [.utteranceEnd])
        #expect(try map(Self.utteranceEnd(3.1)) == [])
        // last_word_end -1 is documented as "ignore".
        #expect(try map(Self.results("more", isFinal: true)) == [.final(" more")])
        #expect(try map(Self.utteranceEnd(-1)) == [])
        // Messages that carry no transcript produce nothing.
        #expect(try map(Self.metadata) == [])
        #expect(try map(#"{"type":"ConfigureSuccess","request_id":"r"}"#) == [])
    }
}

// MARK: - Test sockets

/// Records what the adapter sends under a lock. `FakeWebSocket.sent` is read without its lock, so reading it while
/// the session is still sending (KeepAlive) is a data race under the thread sanitizer.
final class SentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [WebSocketMessage] = []

    init(_ socket: FakeWebSocket, then reply: (@Sendable (WebSocketMessage, FakeWebSocket) -> Void)? = nil) {
        socket.onSend = { [self] message, ws in
            lock.withLock { log.append(message) }
            reply?(message, ws)
        }
    }

    var messages: [WebSocketMessage] { lock.withLock { log } }
}

/// A socket whose binary writes stall until `openGate()`, like a slow network. Text writes can be made to fail.
final class GatedSocket: WebSocketConnection, WebSocketConnector, @unchecked Sendable {
    private let inner = FakeWebSocket()
    private let lock = NSLock()
    private var gateOpen = false
    private var stalled: [CheckedContinuation<Void, Never>] = []
    private var log: [WebSocketMessage] = []
    private let failText: URLError?

    init(failText: URLError? = nil) { self.failText = failText }

    var sent: [WebSocketMessage] { lock.withLock { log } }
    var blockedWrites: Int { lock.withLock { stalled.count } }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection { self }

    func send(_ message: WebSocketMessage) async throws {
        if case .text = message, let failText { throw failText }
        if case .binary = message {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    stalled.append(continuation)
                    lock.unlock()
                }
            }
        }
        lock.withLock { log.append(message) }
    }

    func openGate() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            gateOpen = true
            defer { stalled.removeAll() }
            return stalled
        }
        waiting.forEach { $0.resume() }
    }

    func receive() async throws -> WebSocketMessage { try await inner.receive() }
    func close() async { await inner.close() }
}

/// Delivers `inbound` frames, then fails every receive and send with `error`.
final class ScriptedSocket: WebSocketConnection, WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [WebSocketMessage]
    private let error: URLError

    init(inbound: [WebSocketMessage], then error: URLError) {
        self.inbound = inbound
        self.error = error
    }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection { self }
    func send(_ message: WebSocketMessage) async throws { throw error }

    func receive() async throws -> WebSocketMessage {
        let next: WebSocketMessage? = lock.withLock { inbound.isEmpty ? nil : inbound.removeFirst() }
        guard let next else { throw error }
        return next
    }

    func close() async {}
}
