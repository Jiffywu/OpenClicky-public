import Foundation
import Testing
@testable import OpenClickyKit

/// ElevenLabs streaming TTS, scripted with the response shapes from
/// https://elevenlabs.io/docs/api-reference/text-to-speech/stream and
/// https://elevenlabs.io/docs/eleven-api/resources/errors. No network, no real keys.
@Suite struct ElevenLabsSpeechTests {
    static let key = "xi-test-key-not-real"
    static let voice = "JBFqnCBsd6RMkjVDRZzb"

    // MARK: Fixtures

    /// 16-bit little-endian mono sine, the layout ElevenLabs documents for pcm_* formats.
    static func sinePCM(samples: Int, sampleRate: Int = 24_000) -> Data {
        var data = Data(capacity: samples * 2)
        for n in 0..<samples {
            let value = Int16(10_000 * sin(2 * Double.pi * 440 * Double(n) / Double(sampleRate)))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Splits data at uneven, mostly odd offsets so samples straddle chunk boundaries.
    static func awkwardChunks(_ data: Data, sizes: [Int] = [1, 3, 517, 2, 7, 1_201, 999, 64, 5]) -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let size = min(sizes[index % sizes.count], data.count - offset)
            chunks.append(Data(data[offset..<offset + size]))
            offset += size
            index += 1
        }
        return chunks
    }

    static func context(_ http: any HTTPTransport, baseURL: String? = nil, apiKey: String? = key,
                        headers: [String: String]? = nil) -> ProviderContext {
        let provider = ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: baseURL.flatMap(URL.init(string:)),
                                      credential: "elevenlabs", headers: headers)
        return ProviderContext(provider: provider, apiKey: apiKey, http: http)
    }

    static func collect(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async throws -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    static func audio(in events: [SpeechEvent]) -> [(Data, PCMFormat)] {
        events.compactMap { if case .audio(let data, let format) = $0 { (data, format) } else { nil } }
    }

    // MARK: Streaming

    @Test func streamsSampleAlignedPCMThenFinishesTheLine() async throws {
        let pcm = Self.sinePCM(samples: 4_800) // 200 ms at 24 kHz
        let fake = FakeHTTPTransport([.init(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                            chunks: Self.awkwardChunks(pcm))])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        let events = try await Self.collect(client.speak("Hello there.", voice: nil, instructions: nil))

        let audio = Self.audio(in: events)
        #expect(audio.count > 1)
        #expect(audio.allSatisfy { $0.0.count % 2 == 0 })
        #expect(audio.allSatisfy { $0.1 == .speech24k })
        #expect(audio.dropLast().allSatisfy { $0.0.count >= 960 }) // 20 ms coalescing floor
        #expect(audio.map(\.0).reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
    }

    @Test func dropsADanglingHalfSampleAtTheEnd() async throws {
        let pcm = Self.sinePCM(samples: 1_000)
        let fake = FakeHTTPTransport([.init(chunks: Self.awkwardChunks(pcm + Data([0x7F])))])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        let events = try await Self.collect(client.speak("Hi.", voice: nil, instructions: nil))

        #expect(Self.audio(in: events).map(\.0).reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
    }

    @Test func yieldsAudioBeforeTheResponseEnds() async throws {
        let gate = ElevenLabsGatedTransport()
        let client = ElevenLabsSpeechClient(context: Self.context(gate), defaultVoice: Self.voice)
        var events = client.speak("Streaming check.", voice: nil, instructions: nil).makeAsyncIterator()

        let first = Self.sinePCM(samples: 600) // 1200 bytes
        gate.body.yield(first.prefix(701))     // odd split: one byte of a sample is held back
        gate.body.yield(first.suffix(from: 701))
        guard case .audio(let a, _) = try await events.next() else { Issue.record("expected audio"); return }
        #expect(a.count % 2 == 0)

        let second = Self.sinePCM(samples: 600)
        gate.body.yield(second)
        guard case .audio(let b, _) = try await events.next() else { Issue.record("expected audio"); return }
        #expect(a + b == (first + second).prefix(a.count + b.count))

        gate.body.finish()
        var tail: [SpeechEvent] = []
        while let event = try await events.next() { tail.append(event) }
        #expect(tail.last == .lineFinished)
        #expect(a + b + Self.audio(in: tail).map(\.0).reduce(Data(), +) == first + second)
    }

    @Test func chunkerKeepsWholeSamplesFedByteByByte() {
        let pcm = Self.sinePCM(samples: 300)
        var chunker = ElevenLabsSpeechClient.PCMChunker(frameBytes: 2, minimumBytes: 100)
        var out: [Data] = []
        for byte in pcm { if let chunk = chunker.feed(Data([byte])) { out.append(chunk) } }
        if let rest = chunker.finish() { out.append(rest) }
        #expect(out.allSatisfy { $0.count % 2 == 0 && !$0.isEmpty })
        #expect(out.reduce(Data(), +) == pcm)
        #expect(chunker.finish() == nil)
    }

    // MARK: Request encoding

    @Test func encodesTheDocumentedRequest() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Self.sinePCM(samples: 10)])])
        let settings = ElevenLabsVoiceSettings(stability: 0.4, similarityBoost: 0.8, style: 0.1, useSpeakerBoost: true, speed: 1.1)
        let client = ElevenLabsSpeechClient(context: Self.context(fake), model: "eleven_multilingual_v2",
                                            defaultVoice: "ignored-default", voiceSettings: settings)

        _ = try await Self.collect(client.speak("Héllo, “world”!\nLine two.", voice: Self.voice, instructions: "Sound cheerful"))

        #expect(fake.requests.count == 1)
        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/\(Self.voice)/stream?output_format=pcm_24000")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Compare without letting a failure message echo the key.
        let keyMatches = request.value(forHTTPHeaderField: "xi-api-key") == Self.key
        #expect(keyMatches)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try fake.jsonBody(0)
        #expect(body == [
            "text": "Héllo, “world”!\nLine two.",
            "model_id": "eleven_multilingual_v2",
            "voice_settings": [
                "stability": 0.4,
                "similarity_boost": 0.8,
                "style": 0.1,
                "use_speaker_boost": true,
                "speed": 1.1,
            ],
        ])
    }

    @Test func omitsVoiceSettingsAndInstructionsWhenUnset() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Self.sinePCM(samples: 10)])])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        _ = try await Self.collect(client.speak("Plain.", voice: nil, instructions: "whisper"))

        #expect(try fake.jsonBody(0) == ["text": "Plain.", "model_id": "eleven_flash_v2_5"])
    }

    @Test func honoursBaseURLVersionSampleRateAndProviderHeaders() async throws {
        let pcm = Self.sinePCM(samples: 800, sampleRate: 16_000)
        let fake = FakeHTTPTransport([.init(chunks: Self.awkwardChunks(pcm))])
        let ctx = Self.context(fake, baseURL: "https://api.eu.residency.elevenlabs.io/v1/", headers: ["X-Team": "clicky"])
        let client = ElevenLabsSpeechClient(context: ctx, sampleRate: 16_000)

        let events = try await Self.collect(client.speak("Bonjour.", voice: "voice/with space", instructions: nil))

        let url = try #require(fake.requests.first?.url)
        #expect(url.absoluteString == "https://api.eu.residency.elevenlabs.io/v1/text-to-speech/voice%2Fwith%20space/stream?output_format=pcm_16000")
        #expect(fake.requests.first?.value(forHTTPHeaderField: "X-Team") == "clicky")
        #expect(Self.audio(in: events).allSatisfy { $0.1 == PCMFormat(sampleRate: 16_000, channels: 1) })
        #expect(Self.audio(in: events).map(\.0).reduce(Data(), +) == pcm)
    }

    // MARK: Errors

    struct ErrorCase: Sendable, CustomTestStringConvertible {
        var status: Int
        var body: String
        var expected: String
        var testDescription: String { "HTTP \(status)" }
    }

    static let errorCases: [ErrorCase] = [
        // Current envelope from the errors reference.
        ErrorCase(status: 401, body: #"{"detail":{"type":"authentication_error","code":"invalid_api_key","message":"Invalid API key","request_id":"req_7f3a"}}"#,
                  expected: "Invalid API key"),
        // Legacy envelope ("status" instead of "code").
        ErrorCase(status: 401, body: #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#,
                  expected: "Invalid API key"),
        // 422 validation shape from the stream endpoint reference.
        ErrorCase(status: 422, body: #"{"detail":[{"loc":["body","text"],"msg":"Field required","type":"missing"},{"loc":["body","voice_settings","stability",0],"msg":"Input should be a valid number","type":"float_parsing"}]}"#,
                  expected: "body.text: Field required; body.voice_settings.stability.0: Input should be a valid number"),
        ErrorCase(status: 404, body: #"{"detail":{"type":"not_found","code":"voice_not_found"}}"#,
                  expected: "voice_not_found"),
        ErrorCase(status: 429, body: #"{"detail":"Too many concurrent requests"}"#,
                  expected: "Too many concurrent requests"),
        ErrorCase(status: 502, body: "upstream connect error\n", expected: "upstream connect error"),
    ]

    @Test(arguments: errorCases)
    func surfacesTheDetailMessage(_ errorCase: ErrorCase) async throws {
        let fake = FakeHTTPTransport([.init(status: errorCase.status, headers: ["Content-Type": "application/json"],
                                           chunks: Self.awkwardChunks(Data(errorCase.body.utf8), sizes: [5, 11, 3]))])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        let error = await #expect(throws: ProviderError.self) {
            _ = try await Self.collect(client.speak("Hello.", voice: nil, instructions: nil))
        }
        #expect(error?.status == errorCase.status)
        #expect(error?.message == errorCase.expected)
        #expect(error?.provider == "elevenlabs")
        #expect(error?.description.contains(Self.key) == false)
    }

    @Test func failsFastWithoutAKeyOrVoice() async {
        let noKey = FakeHTTPTransport([])
        let keyless = ElevenLabsSpeechClient(context: Self.context(noKey, apiKey: nil), defaultVoice: Self.voice)
        await #expect(throws: ProviderError.self) { _ = try await Self.collect(keyless.speak("Hi.", voice: nil, instructions: nil)) }
        #expect(noKey.requests.isEmpty)

        let noVoice = FakeHTTPTransport([])
        let voiceless = ElevenLabsSpeechClient(context: Self.context(noVoice))
        await #expect(throws: ProviderError.self) { _ = try await Self.collect(voiceless.speak("Hi.", voice: "  ", instructions: nil)) }
        #expect(noVoice.requests.isEmpty)

        let badRate = FakeHTTPTransport([])
        let odd = ElevenLabsSpeechClient(context: Self.context(badRate), defaultVoice: Self.voice, sampleRate: 11_025)
        await #expect(throws: ProviderError.self) { _ = try await Self.collect(odd.speak("Hi.", voice: nil, instructions: nil)) }
        #expect(badRate.requests.isEmpty)
    }

    @Test func blankLineFinishesWithoutARequest() async throws {
        let fake = FakeHTTPTransport([])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)
        #expect(try await Self.collect(client.speak(" \n ", voice: nil, instructions: nil)) == [.lineFinished])
        #expect(fake.requests.isEmpty)
    }

    // MARK: Cancellation

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheConsumerCancelsTheRequest() async throws {
        let gate = ElevenLabsGatedTransport()
        let client = ElevenLabsSpeechClient(context: Self.context(gate), defaultVoice: Self.voice)
        let (seen, observer) = AsyncStream<SpeechEvent>.makeStream()

        let consumer = Task { () -> (events: [SpeechEvent], error: (any Error)?) in
            var events: [SpeechEvent] = []
            do {
                for try await event in client.speak("A long answer that gets interrupted.", voice: nil, instructions: nil) {
                    events.append(event)
                    observer.yield(event)
                }
                return (events, nil)
            } catch {
                return (events, error)
            }
        }

        gate.body.yield(Self.sinePCM(samples: 1_200))
        var observed = seen.makeAsyncIterator()
        guard case .audio = await observed.next() else { Issue.record("expected audio before cancelling"); return }

        consumer.cancel()
        await gate.waitForTermination()

        let outcome = await consumer.value
        #expect(outcome.error == nil)
        #expect(!outcome.events.contains(.lineFinished))
    }

    @Test(.timeLimit(.minutes(1)))
    func stopAllCancelsLinesInFlight() async throws {
        let gate = ElevenLabsGatedTransport()
        let client = ElevenLabsSpeechClient(context: Self.context(gate), defaultVoice: Self.voice)
        var events = client.speak("Interrupt me.", voice: nil, instructions: nil).makeAsyncIterator()

        gate.body.yield(Self.sinePCM(samples: 1_200))
        guard case .audio = try await events.next() else { Issue.record("expected audio"); return }

        await client.stopAll()
        await gate.waitForTermination()

        var rest: [SpeechEvent] = []
        while let event = try await events.next() { rest.append(event) }
        #expect(!rest.contains(.lineFinished))
    }
}

/// An HTTP transport whose single 200 response body is fed by the test, and which reports when the adapter
/// tears that body down (which is what cancels the URLSession task in production).
private final class ElevenLabsGatedTransport: HTTPTransport, @unchecked Sendable {
    let body: AsyncThrowingStream<Data, Error>.Continuation
    private let stream: AsyncThrowingStream<Data, Error>
    private let terminated: AsyncStream<Void>

    init() {
        let (stream, body) = AsyncThrowingStream<Data, Error>.makeStream()
        let (terminated, signal) = AsyncStream<Void>.makeStream()
        body.onTermination = { _ in
            signal.yield()
            signal.finish()
        }
        self.stream = stream
        self.body = body
        self.terminated = terminated
    }

    func waitForTermination() async {
        for await _ in terminated { return }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

// MARK: - Adversarial cases added in review

extension ElevenLabsSpeechTests {
    /// Collects until the stream ends, keeping the events that arrived before any error.
    static func collectOutcome(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async -> (events: [SpeechEvent], error: (any Error)?) {
        var events: [SpeechEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    /// Polls a condition that another task makes true, failing the test instead of hanging.
    /// The timeout only guards against a hang: a busy machine can take far longer than an idle one.
    static func eventually(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("condition never became true"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func oneByteChunksEndToEndStillYieldWholeSamplesInOrder() async throws {
        let pcm = Self.sinePCM(samples: 2_401) // 4802 bytes: not a multiple of the 960-byte floor
        let fake = FakeHTTPTransport([.init(chunks: pcm.map { Data([$0]) })])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        let events = try await Self.collect(client.speak("One byte at a time.", voice: nil, instructions: nil))

        let audio = Self.audio(in: events).map(\.0)
        #expect(audio.map(\.count) == [960, 960, 960, 960, 960, 2]) // 20 ms pieces, then the last sample
        #expect(audio.allSatisfy { !$0.isEmpty && $0.count % 2 == 0 })
        #expect(audio.dropLast().allSatisfy { $0.count >= 960 })
        #expect(audio.reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
    }

    @Test func oneByteErrorBodyWithMultibyteTextStillParses() async throws {
        let body = #"{"detail":{"type":"rate_limit_error","code":"concurrent_limit_exceeded","message":"Trop de requêtes simultanées — réessayez","request_id":"req_1"}}"#
        let fake = FakeHTTPTransport([.init(status: 429, headers: ["Content-Type": "application/json"],
                                           chunks: Data(body.utf8).map { Data([$0]) })])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        let error = await #expect(throws: ProviderError.self) {
            _ = try await Self.collect(client.speak("Hello.", voice: nil, instructions: nil))
        }
        #expect(error?.status == 429)
        #expect(error?.message == "Trop de requêtes simultanées — réessayez")
    }

    @Test func aCancelledURLErrorWeDidNotAskForIsReported() async throws {
        // URLSession also reports a cancelled auth challenge or an invalidated session as URLError(.cancelled).
        // Only a cancellation by the consumer or stopAll() may end a line silently.
        let beforeHeaders = ElevenLabsFailingTransport(headersError: URLError(.cancelled))
        let early = ElevenLabsSpeechClient(context: Self.context(beforeHeaders), defaultVoice: Self.voice)
        let earlyOutcome = await Self.collectOutcome(early.speak("Hi.", voice: nil, instructions: nil))
        #expect((earlyOutcome.error as? URLError)?.code == .cancelled)

        let pcm = Self.sinePCM(samples: 1_200)
        let midBody = ElevenLabsFailingTransport(chunks: [pcm], bodyError: URLError(.cancelled))
        let late = ElevenLabsSpeechClient(context: Self.context(midBody), defaultVoice: Self.voice)
        let lateOutcome = await Self.collectOutcome(late.speak("Hi.", voice: nil, instructions: nil))
        #expect((lateOutcome.error as? URLError)?.code == .cancelled)
        #expect(!lateOutcome.events.contains(.lineFinished))
    }

    @Test func aDroppedConnectionMidLineFailsAfterTheAudioSoFar() async throws {
        let pcm = Self.sinePCM(samples: 1_200)
        let transport = ElevenLabsFailingTransport(chunks: [pcm], bodyError: URLError(.networkConnectionLost))
        let client = ElevenLabsSpeechClient(context: Self.context(transport), defaultVoice: Self.voice)

        let outcome = await Self.collectOutcome(client.speak("Hi.", voice: nil, instructions: nil))

        #expect(Self.audio(in: outcome.events).map(\.0).reduce(Data(), +) == pcm)
        #expect(!outcome.events.contains(.lineFinished))
        #expect((outcome.error as? URLError)?.code == .networkConnectionLost)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingBeforeTheHeadersArriveCancelsTheRequest() async throws {
        let transport = ElevenLabsHeaderWaitTransport()
        let client = ElevenLabsSpeechClient(context: Self.context(transport), defaultVoice: Self.voice)
        let consumer = Task { await Self.collectOutcome(client.speak("Slow server.", voice: nil, instructions: nil)) }

        try await Self.eventually { transport.waitingCount == 1 }
        consumer.cancel()
        let outcome = await consumer.value

        #expect(transport.cancelledCount == 1)
        #expect(outcome.error == nil)
        #expect(outcome.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopAllCancelsEveryLineStillWaitingForHeaders() async throws {
        let transport = ElevenLabsHeaderWaitTransport()
        let client = ElevenLabsSpeechClient(context: Self.context(transport), defaultVoice: Self.voice)
        let first = Task { await Self.collectOutcome(client.speak("One.", voice: nil, instructions: nil)) }
        let second = Task { await Self.collectOutcome(client.speak("Two.", voice: nil, instructions: nil)) }

        try await Self.eventually { transport.waitingCount == 2 }
        await client.stopAll()
        let outcomes = [await first.value, await second.value]

        #expect(transport.cancelledCount == 2)
        #expect(outcomes.allSatisfy { $0.error == nil && !$0.events.contains(.lineFinished) })
    }

    @Test func aBlankVoiceArgumentFallsBackToTheDefaultVoice() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Self.sinePCM(samples: 10)])])
        let client = ElevenLabsSpeechClient(context: Self.context(fake), defaultVoice: Self.voice)

        _ = try await Self.collect(client.speak("Hi.", voice: " ", instructions: nil))

        #expect(fake.requests.first?.url?.path == "/v1/text-to-speech/\(Self.voice)/stream")
    }

    @Test func printingOrDumpingTheClientNeverShowsTheKey() {
        let client = ElevenLabsSpeechClient(context: Self.context(FakeHTTPTransport([])), defaultVoice: Self.voice)
        var dumped = ""
        dump(client, to: &dumped)
        let leaked = [dumped, String(describing: client), String(reflecting: client), "\(client)"].contains { $0.contains(Self.key) }
        #expect(!leaked)
        #expect(dumped.contains("eleven_flash_v2_5"))
    }
}

/// Fails the way URLSession does: either before any response headers, or after some body bytes.
private struct ElevenLabsFailingTransport: HTTPTransport {
    var headersError: URLError?
    var chunks: [Data] = []
    var bodyError: URLError?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        if let headersError { throw headersError }
        let (chunks, bodyError) = (chunks, bodyError)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish(throwing: bodyError)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

/// Never sends response headers. Like URLSession, a cancelled wait throws URLError(.cancelled).
private final class ElevenLabsHeaderWaitTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []

    var waitingCount: Int { lock.withLock { pending.count } }
    var cancelledCount: Int { lock.withLock { cancelled.count } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled: Bool = lock.withLock {
                    if cancelled.contains(id) { return true }
                    pending[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: URLError(.cancelled)) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                cancelled.insert(id)
                return pending.removeValue(forKey: id)
            }
            continuation?.resume(throwing: URLError(.cancelled))
        }
        throw URLError(.badServerResponse) // not reached: the headers never arrive
    }
}
