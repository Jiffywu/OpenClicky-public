import Foundation
import Testing
@testable import OpenClickyKit

/// Gemini Live push-to-talk transcription against scripted sockets. Server frames follow the shapes on
/// ai.google.dev/api/live (BidiGenerateContentServerMessage) and the live-transcribe guide; the setup and realtime
/// input frames are compared field by field with the guide's WebSocket samples. No network, no real key.
@Suite(.timeLimit(.minutes(1)))
struct GeminiLiveSpeechToTextTests {
    static let testKey = "AIza-test-key-not-real-0123456789"
    static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    // MARK: Server frames (ai.google.dev/api/live)

    static let setupComplete: JSONValue = ["setupComplete": [:]]
    static func interim(_ text: String) -> JSONValue { ["serverContent": ["interimInputTranscription": ["text": .string(text)]]] }
    static func final(_ text: String) -> JSONValue { ["serverContent": ["inputTranscription": ["text": .string(text)]]] }
    static let turnComplete: JSONValue = ["serverContent": ["turnComplete": true, "interactionStatus": "IDLE"]]
    static func goAway(_ timeLeft: String) -> JSONValue { ["goAway": ["timeLeft": .string(timeLeft)]] }
    static func voiceActivity(_ type: String) -> JSONValue { ["voiceActivity": ["type": .string(type)]] }

    // MARK: Client frames (the guide's WebSocket samples)

    static let activityStart: JSONValue = ["realtimeInput": ["activityStart": [:]]]
    static let activityEnd: JSONValue = ["realtimeInput": ["activityEnd": [:]]]

    // MARK: Helpers

    /// Hands out a fresh scripted socket per connection, optionally answering `setup` with `setupComplete` the way the
    /// server does.
    final class SocketFactory: WebSocketConnector, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeWebSocket] = []
        let autoSetup: Bool

        init(autoSetup: Bool = true) { self.autoSetup = autoSetup }

        var sockets: [FakeWebSocket] { lock.withLock { made } }

        func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
            let socket = FakeWebSocket()
            if autoSetup {
                socket.onSend = { message, socket in
                    if case .text(let text) = message, (try? JSONValue.parse(text))?["setup"] != nil {
                        socket.pushJSON(GeminiLiveSpeechToTextTests.setupComplete)
                    }
                }
            }
            _ = try await socket.connect(request)
            lock.withLock { made.append(socket) }
            return socket
        }
    }

    /// Collects a session's events as they arrive, so a test can wait for each step.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [TranscriptEvent] = []
        private var ending: Result<Void, Error>?

        init(_ events: AsyncThrowingStream<TranscriptEvent, Error>) {
            Task {
                do {
                    for try await event in events { self.lock.withLock { self.seen.append(event) } }
                    self.lock.withLock { self.ending = .success(()) }
                } catch {
                    self.lock.withLock { self.ending = .failure(error) }
                }
            }
        }

        var events: [TranscriptEvent] { lock.withLock { seen } }
        var ended: Bool { lock.withLock { ending != nil } }
        var error: Error? { lock.withLock { if case .failure(let error)? = ending { error } else { nil } } }
    }

    static func client(_ connector: any WebSocketConnector, model: String = "gemini-3.5-transcribe-live",
                       baseURL: String? = "https://generativelanguage.googleapis.com/v1beta", apiKey: String? = testKey,
                       headers: [String: String]? = nil,
                       options: GeminiLiveSpeechToTextClient.Options = .init()) -> GeminiLiveSpeechToTextClient {
        let provider = ProviderConfig(id: "gemini-live", dialect: .geminiLive, baseURL: baseURL.flatMap(URL.init(string:)),
                                      credential: "gemini", headers: headers)
        let context = ProviderContext(provider: provider, apiKey: apiKey, http: FakeHTTPTransport([]), webSocket: connector)
        return GeminiLiveSpeechToTextClient(context: context, model: model, options: options)
    }

    /// The default limit only guards against a hang: a busy machine can take far longer than an idle one. Tests whose
    /// press could also end on a timer set that timer far past it.
    static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    static func eventuallyAsync(within limit: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Base64 audio payloads sent so far, decoded, with their MIME types.
    static func audioFrames(_ socket: FakeWebSocket) -> [(data: Data, mimeType: String?)] {
        socket.sentJSON.compactMap { frame in
            guard let audio = frame["realtimeInput"]?["audio"], let encoded = audio["data"]?.stringValue,
                  let data = Data(base64Encoded: encoded) else { return nil }
            return (data, audio["mimeType"]?.stringValue)
        }
    }

    static func samples(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// Opens a press on a fresh socket and waits until `activityStart` has gone out.
    static func livePress(_ factory: SocketFactory, model: String = "gemini-3.5-transcribe-live",
                          options: GeminiLiveSpeechToTextClient.Options = .init(),
                          language: String? = "en-US") async throws -> (any SpeechToTextSession, FakeWebSocket, Recorder) {
        let session = try await client(factory, model: model, options: options).startSession(language: language, keywords: [])
        let socket = try #require(factory.sockets.last)
        let recorder = Recorder(session.events)
        #expect(await eventually { socket.sentJSON.contains(activityStart) })
        return (session, socket, recorder)
    }

    // MARK: Setup and connection

    @Test func setupFrameMatchesTheLiveTranscriptionDocsAndTheKeyStaysInAHeader() async throws {
        let factory = SocketFactory(autoSetup: false)
        let session = try await Self.client(factory, headers: ["X-Trace": "abc"])
            .startSession(language: "en-US", keywords: ["OpenClicky", " three.js ", "", "OpenClicky", "C++"])
        let socket = try #require(factory.sockets.first)
        #expect(await Self.eventually { socket.sent.count == 1 })

        let request = try #require(socket.connectRequests.first)
        #expect(request.url?.absoluteString == Self.endpoint)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.testKey)
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "abc")
        let requestURL = try #require(request.url).absoluteString
        #expect(!requestURL.contains(Self.testKey))

        let expected: JSONValue = ["setup": [
            "model": "models/gemini-3.5-transcribe-live",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": ["languageCodes": ["en-US"], "customVocabulary": ["OpenClicky", "three.js", "C++"]],
        ]]
        #expect(socket.sentJSON == [expected])

        // Nothing else may go out before setupComplete: audio captured now is held, not sent.
        await session.send(Self.samples(640))
        try await Task.sleep(for: .milliseconds(50))
        #expect(socket.sent.count == 1)

        socket.pushJSON(Self.setupComplete)
        #expect(await Self.eventually { socket.sent.count == 3 })
        #expect(socket.sentJSON[1] == Self.activityStart)
        let audio = Self.audioFrames(socket)
        #expect(audio.map(\.data) == [Self.samples(640)])
        #expect(audio.first?.mimeType == "audio/pcm;rate=16000")
        await session.cancel()
        #expect(socket.isClosed)
    }

    @Test func automaticLanguageModeAndSmartModeFollowTheDocs() async throws {
        let options = GeminiLiveSpeechToTextClient.Options(transcriptionMode: "SMART")
        let client = Self.client(SocketFactory(), options: options)
        #expect(client.inputFormat == PCMFormat(sampleRate: 16_000, channels: 1))
        let setup = client.setupMessage(language: nil, keywords: [])
        #expect(setup["setup"]?["inputAudioTranscription"] == ["languageCodes": [], "mode": "SMART"])
        #expect(setup["setup"]?["systemInstruction"] == nil)

        let blankModel = Self.client(SocketFactory(), model: "  ")
        #expect(blankModel.model == "gemini-3.5-transcribe-live")
        #expect(blankModel.setupMessage(language: " ", keywords: [])["setup"]?["model"] == "models/gemini-3.5-transcribe-live")
        let prefixed = Self.client(SocketFactory(), model: "models/gemini-3.5-transcribe-live")
        #expect(prefixed.setupMessage(language: nil, keywords: [])["setup"]?["model"] == "models/gemini-3.5-transcribe-live")
    }

    @Test func vocabularyIsTrimmedDeduplicatedAndCappedAtTheDocumentedThousand() {
        let terms = (0..<1_200).map { "term\($0)" }
        let vocabulary = WarmKey(language: nil, keywords: [" a ", "a", ""] + terms).vocabulary
        #expect(vocabulary.count == 1_000)
        #expect(vocabulary.prefix(2) == ["a", "term0"])
    }

    @Test func liveAgentModelsAnswerInAudioSoTheyAreToldToStaySilent() {
        let client = Self.client(SocketFactory(), model: "gemini-3.8-live")
        let setup = client.setupMessage(language: nil, keywords: ["Clicky"])["setup"]
        #expect(setup?["generationConfig"] == ["responseModalities": ["AUDIO"]])
        #expect(setup?["inputAudioTranscription"] == ["customVocabulary": ["Clicky"]])
        #expect(setup?["systemInstruction"]?["parts"]?.arrayValue?.first?["text"]?.stringValue?.isEmpty == false)
        #expect(setup?["realtimeInputConfig"] == ["automaticActivityDetection": ["disabled": true]])
        #expect(client.joining == .fragments)
        #expect(Self.client(SocketFactory()).joining == .segments)
    }

    @Test func endpointAcceptsRESTStyleBasesAndFullSocketURLs() {
        func url(_ base: String?) -> String { GeminiLiveWire.endpoint(base: base.flatMap(URL.init(string:))).absoluteString }
        #expect(url(nil) == Self.endpoint)
        #expect(url("https://generativelanguage.googleapis.com") == Self.endpoint)
        #expect(url("https://generativelanguage.googleapis.com/v1beta/") == Self.endpoint)
        #expect(url("https://generativelanguage.googleapis.com/v1alpha")
            == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent")
        #expect(url(Self.endpoint) == Self.endpoint)
        #expect(url("http://127.0.0.1:9000/gemini") == "ws://127.0.0.1:9000/gemini/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
    }

    // MARK: Audio

    @Test func audioIsSentAsWholeSamplesInChunksOfAtMost2048Frames() async throws {
        let factory = SocketFactory()
        let (session, socket, _) = try await Self.livePress(factory)
        let pcm = Self.samples(10_001)
        await session.send(pcm.prefix(4_097))
        await session.send(pcm.dropFirst(4_097))
        await session.send(Data())
        #expect(await Self.eventually { Self.audioFrames(socket).reduce(0) { $0 + $1.data.count } == 10_000 })
        let frames = Self.audioFrames(socket)
        #expect(frames.allSatisfy { $0.data.count <= 4_096 && $0.data.count % 2 == 0 && $0.mimeType == "audio/pcm;rate=16000" })
        #expect(frames.map(\.data).reduce(Data(), +) == pcm.prefix(10_000))
        await session.cancel()
    }

    // MARK: Transcripts

    @Test func chunkedInterimsReplaceEachOtherAndSegmentFinalsAppendWithSpaces() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), settleDelay: .milliseconds(50))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        await session.send(Self.samples(3_200))

        socket.pushJSON(Self.interim("Hel"))
        socket.pushJSON(Self.interim("Hello wor"))
        socket.pushJSON(Self.interim("Hello world"))
        socket.pushJSON(Self.interim("Hello world"))  // a repeat changes nothing on screen
        socket.pushJSON(Self.final("Hello world."))
        socket.pushJSON(["usageMetadata": ["totalTokenCount": 12]])
        socket.pushJSON(Self.interim("<speaker:1>how are</speaker>"))
        #expect(await Self.eventually { recorder.events.count == 8 })

        await session.finish()
        #expect(await Self.eventually { socket.sentJSON.last == Self.activityEnd })
        // activityEnd went out after all the audio.
        let lastAudio = socket.sentJSON.lastIndex { $0["realtimeInput"]?["audio"] != nil } ?? 0
        #expect(socket.sentJSON.firstIndex(of: Self.activityEnd)! > lastAudio)

        socket.pushJSON(Self.final("How are you?"))
        #expect(await Self.eventually { recorder.ended })
        #expect(recorder.error == nil)
        #expect(recorder.events == [
            .speechStarted, .interim("Hel"), .interim("Hello wor"), .interim("Hello world"),
            .final("Hello world."), .utteranceEnd,
            .speechStarted, .interim(" how are"),
            .final(" How are you?"), .utteranceEnd,
        ])
        #expect(socket.isClosed)
    }

    @Test func turnCompleteAfterActivityEndEndsThePressWithoutWaiting() async throws {
        let factory = SocketFactory()
        // Both timers far past the hang guard below, so ending within it proves the press didn't wait for either.
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), settleDelay: .seconds(30))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        socket.pushJSON(Self.voiceActivity("ACTIVITY_START"))
        socket.pushJSON(Self.interim("open"))
        #expect(await Self.eventually { recorder.events.count == 2 })
        await session.finish()
        socket.pushJSON(["serverContent": ["inputTranscription": ["text": "Open Safari."], "turnComplete": true]])
        #expect(await Self.eventually(within: .seconds(10)) { recorder.ended })
        #expect(recorder.events == [.speechStarted, .interim("open"), .final("Open Safari."), .utteranceEnd])
    }

    @Test func aFinalThatNeverComesPromotesTheLastInterimAtTheTimeout() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .milliseconds(150))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        socket.pushJSON(Self.interim("open the"))
        #expect(await Self.eventually { recorder.events.count == 2 })
        await session.finish()
        #expect(await Self.eventually { recorder.ended })
        #expect(recorder.error == nil)
        #expect(recorder.events == [.speechStarted, .interim("open the"), .final("open the"), .utteranceEnd])
        #expect(socket.isClosed)
    }

    @Test func aSilentPressEndsQuicklyWithNoEvents() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), quietFinishTimeout: .milliseconds(50))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        await session.finish()
        #expect(await Self.eventually(within: .seconds(10)) { recorder.ended })  // a hang guard, well short of finalTimeout
        #expect(recorder.events.isEmpty)
        #expect(recorder.error == nil)
        #expect(socket.sentJSON.last == Self.activityEnd)
    }

    /// Review fix: when every word was settled before key-up and Gemini sends nothing after `activityEnd`, the press
    /// used to wait the whole `finalTimeout` (5 s by default) before returning its transcript.
    @Test func aPressSettledBeforeKeyUpEndsAfterTheQuietWaitNotTheFinalTimeout() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), quietFinishTimeout: .milliseconds(50))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        socket.pushJSON(Self.interim("open safari"))
        socket.pushJSON(Self.final("Open Safari."))
        #expect(await Self.eventually { recorder.events.count == 4 })
        await session.finish()
        #expect(await Self.eventually(within: .seconds(10)) { recorder.ended })  // a hang guard, well short of finalTimeout
        #expect(recorder.error == nil)
        #expect(recorder.events == [.speechStarted, .interim("open safari"), .final("Open Safari."), .utteranceEnd])
        #expect(socket.sentJSON.last == Self.activityEnd)
        #expect(socket.isClosed)
    }

    /// The quiet wait never cuts off words Gemini is still settling after key-up.
    @Test func textArrivingAfterKeyUpIsWaitedForEvenPastTheQuietWait() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), settleDelay: .milliseconds(20),
                                                           quietFinishTimeout: .milliseconds(500))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        socket.pushJSON(Self.final("Open Safari."))
        #expect(await Self.eventually { recorder.events.count == 3 })
        let released = ContinuousClock.now
        await session.finish()
        socket.pushJSON(Self.interim("and search"))
        #expect(await Self.eventually { recorder.events.contains(.interim(" and search")) })
        try await Task.sleep(until: released.advanced(by: .milliseconds(800)))
        #expect(!recorder.ended)  // an unsettled interim keeps the press open past the quiet wait
        socket.pushJSON(Self.final("And search."))
        #expect(await Self.eventually(within: .seconds(10)) { recorder.ended })  // a hang guard, well short of finalTimeout
        #expect(recorder.error == nil)
        let finals = recorder.events.compactMap { if case .final(let text) = $0 { text } else { nil } }
        #expect(finals == ["Open Safari.", " And search."])
    }

    @Test func finishBeforeSetupCompleteStillSendsTheMarkersAndAudioInOrder() async throws {
        let factory = SocketFactory(autoSetup: false)
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), quietFinishTimeout: .milliseconds(50))
        let session = try await Self.client(factory, options: options).startSession(language: nil, keywords: [])
        let socket = try #require(factory.sockets.first)
        let recorder = Recorder(session.events)
        await session.send(Self.samples(320))
        await session.finish()
        await session.send(Self.samples(320, seed: 9))  // after finish: ignored
        socket.pushJSON(Self.setupComplete)
        #expect(await Self.eventually { recorder.ended })
        let kinds = socket.sentJSON.map { frame -> String in
            if frame["setup"] != nil { return "setup" }
            if frame == Self.activityStart { return "start" }
            if frame == Self.activityEnd { return "end" }
            return frame["realtimeInput"]?["audio"] != nil ? "audio" : "other"
        }
        #expect(kinds == ["setup", "start", "audio", "end"])
        #expect(Self.audioFrames(socket).map(\.data) == [Self.samples(320)])
    }

    @Test func fragmentsFromLiveAgentModelsKeepTheirOwnSpacing() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30), settleDelay: .milliseconds(30))
        let (session, socket, recorder) = try await Self.livePress(factory, model: "gemini-3.8-live", options: options)
        for piece in [" Hel", "lo", " ", "there", ", friend"] { socket.pushJSON(Self.final(piece)) }
        #expect(await Self.eventually { recorder.events.filter { if case .final = $0 { true } else { false } }.count == 4 })
        await session.finish()
        socket.pushJSON(Self.turnComplete)
        #expect(await Self.eventually { recorder.ended })
        let finals = recorder.events.compactMap { if case .final(let text) = $0 { text } else { nil } }
        #expect(finals == ["Hel", "lo", " there", ", friend"])
        #expect(finals.joined() == "Hello there, friend")
        #expect(recorder.events.last == .utteranceEnd)
    }

    @Test func mapperHandlesSpeakerTagsScriptsWithoutSpacesAndClosingPunctuation() {
        var mapper = GeminiLiveTranscriptMapper(joining: .segments)
        _ = mapper.map(Self.final("<speaker id=\"1\">你好</speaker>"))
        _ = mapper.map(Self.final("世界"))
        #expect(mapper.transcript == "你好世界")
        _ = mapper.map(Self.final("。Then English"))
        _ = mapper.map(Self.final("again"))
        #expect(mapper.transcript == "你好世界。Then English again")
        #expect(mapper.map(Self.final("  ")) == [])
        #expect(mapper.map(Self.interim("half")) == [.speechStarted, .interim(" half")])
        #expect(mapper.map(Self.final("")) == [.interim("")])
        #expect(GeminiLiveTranscriptMapper.stripSpeakerTags("a <b> c</speaker>") == "a <b> c")
    }

    // MARK: Errors and endings

    @Test func anErrorFrameFailsThePressAsARefusal() async throws {
        let factory = SocketFactory()
        let (_, socket, recorder) = try await Self.livePress(factory)
        socket.pushJSON(["error": ["code": 429, "message": "Resource has been exhausted (e.g. check quota).", "status": "RESOURCE_EXHAUSTED"]])
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.status == 429)
        #expect(error.message == "Gemini Live rejected the transcription session: RESOURCE_EXHAUSTED: "
            + "Resource has been exhausted (e.g. check quota).")
        #expect(socket.isClosed)
    }

    @Test func aSocketThatClosesBeforeSetupPointsAtTheKeyAndModel() async throws {
        let factory = SocketFactory(autoSetup: false)
        let session = try await Self.client(factory).startSession(language: nil, keywords: [])
        let socket = try #require(factory.sockets.first)
        let recorder = Recorder(session.events)
        #expect(await Self.eventually { socket.sent.count == 1 })
        await socket.close()
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.message.contains("before it was set up"))
        #expect(error.message.contains("API key"))
    }

    @Test func aServerCloseReasonIsKeptAndLabelledWithTheProvider() async throws {
        let factory = SocketFactory(autoSetup: false)
        let session = try await Self.client(factory).startSession(language: nil, keywords: [])
        let socket = try #require(factory.sockets.first)
        let recorder = Recorder(session.events)
        #expect(await Self.eventually { socket.sent.count == 1 })
        // What the shared URLSession connector reports for a server close frame.
        socket.serverClose(with: ProviderError(provider: "generativelanguage.googleapis.com",
                                               message: "The server closed the WebSocket (code 1007: API key not valid.)."))
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.provider == "gemini-live")
        #expect(error.message.contains("code 1007: API key not valid."))
        #expect(error.message.contains("before it was set up"))
    }

    @Test func aRefusedConnectionIsAProviderErrorAndCancellationStaysCancellation() async throws {
        struct Refusing: WebSocketConnector {
            let error: any Error
            func connect(_ request: URLRequest) async throws -> any WebSocketConnection { throw error }
        }
        let refused = ProviderError(provider: "generativelanguage.googleapis.com", status: 403,
                                    message: "The server refused the WebSocket connection (HTTP 403 forbidden).")
        do {
            _ = try await Self.client(Refusing(error: refused)).startSession(language: nil, keywords: [])
            Issue.record("expected a refusal")
        } catch let error as ProviderError {
            #expect(error.provider == "gemini-live")
            #expect(error.status == 403)
            #expect(error.message.contains("HTTP 403"))
        }
        await #expect(throws: CancellationError.self) {
            _ = try await Self.client(Refusing(error: CancellationError())).startSession(language: nil, keywords: [])
        }
    }

    @Test func setupThatNeverCompletesTimesOut() async throws {
        let factory = SocketFactory(autoSetup: false)
        let options = GeminiLiveSpeechToTextClient.Options(setupTimeout: .milliseconds(80))
        let session = try await Self.client(factory, options: options).startSession(language: nil, keywords: [])
        let recorder = Recorder(session.events)
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.message.contains("did not finish setting up"))
        #expect(factory.sockets.first?.isClosed == true)
    }

    @Test func goAwayThenADroppedSocketMidPressIsReportedWithTheWarning() async throws {
        let factory = SocketFactory()
        let (_, socket, recorder) = try await Self.livePress(factory)
        socket.pushJSON(Self.goAway("5s"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!recorder.ended)  // a warning alone does not end the press
        await socket.close()
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.message.contains("announcing it would close"))
        #expect(error.message.contains("5"))
    }

    @Test func aDropWhileFinishingKeepsTheWordsAlreadyHeard() async throws {
        let factory = SocketFactory()
        let options = GeminiLiveSpeechToTextClient.Options(finalTimeout: .seconds(30))
        let (session, socket, recorder) = try await Self.livePress(factory, options: options)
        socket.pushJSON(Self.interim("draw a circle"))
        #expect(await Self.eventually { recorder.events.count == 2 })
        await session.finish()
        socket.pushJSON(Self.goAway("0s"))
        await socket.close()
        #expect(await Self.eventually { recorder.ended })
        #expect(recorder.error == nil)
        #expect(recorder.events == [.speechStarted, .interim("draw a circle"), .final("draw a circle"), .utteranceEnd])
    }

    @Test func cancelAbandonsThePressWithoutActivityEnd() async throws {
        let factory = SocketFactory()
        let (session, socket, recorder) = try await Self.livePress(factory)
        socket.pushJSON(Self.interim("never mind"))
        await session.cancel()
        #expect(await Self.eventually { recorder.ended })
        #expect(recorder.error == nil)
        #expect(socket.isClosed)
        #expect(!socket.sentJSON.contains(Self.activityEnd))
        await session.send(Self.samples(64))
        await session.finish()
        #expect(!socket.sentJSON.contains(Self.activityEnd))
    }

    @Test func aConsumerThatStopsListeningClosesTheSocket() async throws {
        let factory = SocketFactory()
        let session = try await Self.client(factory).startSession(language: nil, keywords: [])
        let socket = try #require(factory.sockets.first)
        let consumer = Task { for try await _ in session.events {} }
        #expect(await Self.eventually { socket.sentJSON.contains(Self.activityStart) })
        consumer.cancel()
        #expect(await Self.eventually { socket.isClosed })
    }

    @Test func goAwayDurationsParseInProtoJSONForms() {
        #expect(GeminiLiveWire.duration("50s") == .seconds(50))
        #expect(GeminiLiveWire.duration("1.5s") == .milliseconds(1_500))
        #expect(GeminiLiveWire.duration(["seconds": "3", "nanos": 250_000_000]) == .milliseconds(3_250))
        #expect(GeminiLiveWire.duration("soon") == nil)
        #expect(GeminiLiveWire.duration(nil) == nil)
    }

    /// Review fix: an out-of-range `timeLeft` used to reach `Int64(Double)`, which traps and takes the app down.
    @Test func absurdGoAwayDurationsAreIgnoredInsteadOfCrashing() async throws {
        #expect(GeminiLiveWire.duration("1e300s") == nil)
        #expect(GeminiLiveWire.duration(.number(1e300)) == nil)
        #expect(GeminiLiveWire.duration(["seconds": 1e300]) == nil)
        #expect(GeminiLiveWire.duration(["seconds": "9e18", "nanos": 0]) == nil)
        #expect(GeminiLiveWire.duration(["seconds": -5]) == nil)
        #expect(GeminiLiveWire.duration("-5s") == nil)

        let factory = SocketFactory()
        let (_, socket, recorder) = try await Self.livePress(factory)
        socket.pushJSON(Self.goAway("1e300s"))
        try await Task.sleep(for: .milliseconds(30))
        await socket.close()
        #expect(await Self.eventually { recorder.ended })
        let error = try #require(recorder.error as? ProviderError)
        #expect(error.message.contains("announcing it would close"))
    }

    // MARK: Warm sockets

    @Test func aWarmSocketIsTakenByTheNextPressWithTheSameSettings() async throws {
        let factory = SocketFactory()
        let client = Self.client(factory)
        await client.warmUp(language: "en-US", keywords: ["Clicky"])
        let warm = try #require(factory.sockets.first)
        #expect(await Self.eventually { warm.sent.count == 1 })
        #expect(await client.hasWarmSocket(language: "en-US", keywords: ["Clicky"]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!warm.sentJSON.contains(Self.activityStart))  // idle until a press claims it

        await client.warmUp(language: "en-US", keywords: ["Clicky"])  // already warm: no second socket
        #expect(factory.sockets.count == 1)

        let session = try await client.startSession(language: "en-US", keywords: [" Clicky "])
        #expect(factory.sockets.count == 1)
        #expect(await Self.eventually { warm.sentJSON.last == Self.activityStart })
        #expect(!(await client.hasWarmSocket(language: "en-US", keywords: ["Clicky"])))
        await session.send(Self.samples(320))
        #expect(await Self.eventually { Self.audioFrames(warm).count == 1 })
        await session.cancel()
    }

    @Test func aWarmSocketForOtherSettingsIsClosedAndANewOneOpened() async throws {
        let factory = SocketFactory()
        let client = Self.client(factory)
        await client.warmUp(language: "en-US", keywords: [])
        let warm = try #require(factory.sockets.first)
        let session = try await client.startSession(language: "fr-FR", keywords: [])
        #expect(factory.sockets.count == 2)
        #expect(warm.isClosed)
        let fresh = factory.sockets[1]
        #expect(await Self.eventually { fresh.sentJSON.contains(Self.activityStart) })
        #expect(fresh.sentJSON.first?["setup"]?["inputAudioTranscription"]?["languageCodes"] == ["fr-FR"])
        await session.cancel()
    }

    @Test func warmSocketsExpireAndAreDroppedOnGoAway() async throws {
        let factory = SocketFactory()
        let client = Self.client(factory, options: .init(warmSocketLifetime: .milliseconds(60)))
        await client.warmUp(language: nil, keywords: [])
        let first = try #require(factory.sockets.first)
        #expect(await Self.eventually { first.isClosed })
        #expect(!(await client.hasWarmSocket(language: nil, keywords: [])))

        let lasting = Self.client(factory)
        await lasting.warmUp(language: nil, keywords: [])
        let second = factory.sockets[1]
        #expect(await Self.eventually { second.sent.count == 1 })
        second.pushJSON(Self.goAway("10s"))
        #expect(await Self.eventually { second.isClosed })
        let session = try await lasting.startSession(language: nil, keywords: [])
        #expect(factory.sockets.count == 3)
        await session.cancel()
    }

    /// Review fix: a socket about to expire counted as warm, so the keep-warm timer left it to die and presses in the
    /// gap until the next tick connected cold. A refresh asking for a margin replaces it first.
    @Test func aWarmSocketCloseToExpiryIsReplacedBeforeItCloses() async throws {
        let factory = SocketFactory()
        let client = Self.client(factory, options: .init(warmSocketLifetime: .seconds(30)))
        await client.warmUp(language: nil, keywords: [])
        let first = try #require(factory.sockets.first)
        await client.warmUp(language: nil, keywords: [], replacingWithin: .seconds(10))
        #expect(factory.sockets.count == 1)  // 30 s left: kept
        await client.warmUp(language: nil, keywords: [], replacingWithin: .seconds(60))
        #expect(factory.sockets.count == 2)  // would close within the margin: replaced
        #expect(first.isClosed)
        #expect(!factory.sockets[1].isClosed)
        #expect(await client.hasWarmSocket(language: nil, keywords: []))
        await client.discardWarmSocket()
    }

    @Test func rewarmAfterUseOpensTheNextSocketAhead() async throws {
        let factory = SocketFactory()
        let client = Self.client(factory, options: .init(rewarmAfterUse: true))
        let session = try await client.startSession(language: nil, keywords: [])
        #expect(await Self.eventually { factory.sockets.count == 2 })
        let rewarmed = factory.sockets[1]
        #expect(await Self.eventuallyAsync { await client.hasWarmSocket(language: nil, keywords: []) })
        #expect(await Self.eventually { rewarmed.sent.count == 1 })
        #expect(!rewarmed.sentJSON.contains(Self.activityStart))
        await session.cancel()
        await client.discardWarmSocket()
        #expect(rewarmed.isClosed)
    }

    // MARK: Catalog, dialect, presets, redaction

    @Test func catalogDialectAndPresetCoverGeminiLive() throws {
        #expect(ProviderDialect(rawValue: "gemini-live") == .geminiLive)
        #expect(ProviderDialect.geminiLive.servableKinds == [.speechToText, .realtimeSpeech])
        #expect(!ProviderDialect.geminiLive.isOnDevice)
        let catalog = try ModelCatalog.builtIn()
        let model = try #require(catalog.model("gemini-3.5-transcribe-live", servedBy: .geminiLive))
        #expect(model.kind == .speechToText)
        #expect(model.has(.interimResults) && model.has(.streaming))
        #expect(catalog.candidates(for: .stt, dialect: .geminiLive).map(\.id) == ["gemini-3.5-transcribe-live"])
        let preset = try #require(ProviderPreset.all.first { $0.id == "gemini-live" })
        #expect(preset.config.dialect == .geminiLive)
        #expect(preset.config.credential == "gemini")
        #expect(GeminiLiveWire.endpoint(base: preset.config.baseURL).absoluteString == Self.endpoint)
    }

    @Test func theEngineFactoryBuildsTheAdapterForTheSttSlot() throws {
        let provider = try #require(ProviderPreset.all.first { $0.id == "gemini-live" }).config
        let config = OpenClickyConfig(providers: [provider], slots: [.stt: SlotSelection(provider: "gemini-live", model: "gemini-3.5-transcribe-live")])
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["gemini": Self.testKey]),
                                    http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
        let client = try #require(try factory.speechToText() as? GeminiLiveSpeechToTextClient)
        #expect(client.model == "gemini-3.5-transcribe-live")
        #expect(client.context.apiKey == Self.testKey)
        #expect(EngineFactory.adapterName(for: .geminiLive) == "GeminiLiveSpeechToTextClient")
        #expect(try factory.resolve(.stt).errors.isEmpty)

        let keyless = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore([:]),
                                    http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
        #expect(throws: EngineFactoryError.missingCredential(slot: .stt, provider: "gemini-live", credential: "gemini")) {
            _ = try keyless.speechToText()
        }
    }

    @Test func descriptionsNeverShowTheKey() {
        let client = Self.client(SocketFactory())
        for text in [String(describing: client), String(reflecting: client), "\(client)"] {
            #expect(!text.contains(Self.testKey))
            #expect(text.contains("apiKey: set"))
        }
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(Self.testKey))
    }
}
