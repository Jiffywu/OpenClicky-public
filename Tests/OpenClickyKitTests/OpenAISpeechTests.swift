import Foundation
import Testing
@testable import OpenClickyKit

/// OpenAISpeechClient against scripted `/audio/speech` responses. No network, no real keys.
@Suite struct OpenAISpeechTests {
    static let fakeKey = "sk-test-not-a-real-key-0123456789abcdef"

    static func context(_ http: any HTTPTransport, baseURL: String? = nil, apiKey: String? = fakeKey,
                        headers: [String: String]? = nil) -> ProviderContext {
        ProviderContext(
            provider: ProviderConfig(id: "openai", dialect: .openAISpeech, baseURL: baseURL.flatMap(URL.init(string:)),
                                     credential: "openai", headers: headers),
            apiKey: apiKey, http: http)
    }

    /// 24 kHz 16-bit little-endian mono samples of a 440 Hz tone, the shape `response_format: "pcm"` returns.
    static func tone(samples: Int) -> Data {
        var data = Data(capacity: samples * 2)
        for n in 0..<samples {
            let value = Int16(8_000 * sin(2 * Double.pi * 440 * Double(n) / 24_000))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Splits data at the given sizes (the last piece takes the remainder), as a network might deliver it.
    static func chunks(_ data: Data, sizes: [Int]) -> [Data] {
        var result: [Data] = []
        var offset = 0
        for size in sizes where offset < data.count {
            let end = min(offset + size, data.count)
            result.append(Data(data[offset..<end]))
            offset = end
        }
        if offset < data.count { result.append(Data(data[offset...])) }
        return result
    }

    static func collect(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async throws -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// The ProviderError a line fails with, or nil (recording an issue) if it does not fail that way.
    static func providerError(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async -> ProviderError? {
        do {
            _ = try await collect(stream)
            Issue.record("expected a ProviderError")
        } catch let error as ProviderError {
            return error
        } catch {
            Issue.record("expected a ProviderError, got \(error)")
        }
        return nil
    }

    static func audio(in events: [SpeechEvent]) -> [Data] {
        events.compactMap { if case .audio(let data, _) = $0 { data } else { nil } }
    }

    // MARK: - Streaming

    @Test func streamsWholeSamplesAcrossAwkwardChunkBoundariesThenFinishesTheLine() async throws {
        let pcm = Self.tone(samples: 600)
        let pieces = Self.chunks(pcm, sizes: [1, 3, 1, 1, 7, 2, 101, 64, 333])
        let fake = FakeHTTPTransport([.init(headers: ["Content-Type": "application/octet-stream"], chunks: pieces)])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let events = try await Self.collect(client.speak("Hello there.", voice: nil, instructions: nil))

        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        let audio = Self.audio(in: events)
        #expect(audio.count > 1)
        #expect(audio.allSatisfy { !$0.isEmpty && $0.count % 2 == 0 })
        #expect(audio.reduce(Data(), +) == pcm)
        for event in events {
            if case .audio(_, let format) = event { #expect(format == PCMFormat(sampleRate: 24_000, channels: 1)) }
        }
        #expect(client.inFlightCount == 0)
    }

    @Test func yieldsAudioBeforeTheResponseBodyEnds() async throws {
        let transport = ControlledTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        var iterator = client.speak("Streaming check.", voice: nil, instructions: nil).makeAsyncIterator()

        try await transport.waitForRequest()
        transport.send(Data([0x01, 0x02, 0x03]))  // one and a half samples
        #expect(try await iterator.next() == .audio(Data([0x01, 0x02]), .speech24k))
        transport.send(Data([0x04, 0x05]))
        #expect(try await iterator.next() == .audio(Data([0x03, 0x04]), .speech24k))
        transport.send(Data([0x06]))
        transport.finish()
        #expect(try await iterator.next() == .audio(Data([0x05, 0x06]), .speech24k))
        #expect(try await iterator.next() == .lineFinished)
        #expect(try await iterator.next() == nil)
    }

    @Test func oneByteChunksReassembleExactlyAsWholeSamples() async throws {
        let pcm = Self.tone(samples: 601)
        let body = pcm + Data([0x7F])  // a trailing half sample, as a cut-off body would end
        let pieces = body.map { Data([$0]) }  // the worst case: one byte per network read
        let fake = FakeHTTPTransport([.init(headers: ["Content-Type": "audio/pcm"], chunks: pieces)])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let events = try await Self.collect(client.speak("One byte at a time.", voice: nil, instructions: nil))

        let audio = Self.audio(in: events)
        #expect(audio.count == 601)
        #expect(audio.allSatisfy { $0.count == 2 })
        #expect(audio.reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
    }

    @Test func dropsATrailingHalfSample() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Data([1, 2, 3]), Data([4, 5])])])
        let client = OpenAISpeechClient(context: Self.context(fake))
        let events = try await Self.collect(client.speak("Odd.", voice: nil, instructions: nil))
        #expect(events == [.audio(Data([1, 2]), .speech24k), .audio(Data([3, 4]), .speech24k), .lineFinished])
    }

    @Test func blankTextFinishesWithoutARequest() async throws {
        let fake = FakeHTTPTransport([])
        let client = OpenAISpeechClient(context: Self.context(fake))
        let events = try await Self.collect(client.speak(" \n\t ", voice: nil, instructions: nil))
        #expect(events == [.lineFinished])
        #expect(fake.requests.isEmpty)
    }

    @Test func splitsTextOverTheInputLimitIntoSequentialRequests() async throws {
        let sentence = "This sentence is part of a very long line that the brain asked the voice to read aloud. "
        let text = String(repeating: sentence, count: 60)  // about 5,300 characters
        let first = Self.tone(samples: 10)
        let second = Self.tone(samples: 7)
        let fake = FakeHTTPTransport([
            .init(chunks: Self.chunks(first, sizes: [5, 4])),
            .init(chunks: Self.chunks(second, sizes: [3])),
        ])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let events = try await Self.collect(client.speak(text, voice: nil, instructions: nil))

        #expect(fake.requests.count == 2)
        let inputs = try (0..<2).map { try #require(fake.jsonBody($0)["input"]?.stringValue) }
        #expect(inputs.allSatisfy { $0.unicodeScalars.count <= 4096 })
        #expect(inputs[0].hasSuffix("aloud."))  // cut after a sentence
        #expect(inputs.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
        #expect(Self.audio(in: events).reduce(Data(), +) == first + second)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        #expect(events.last == .lineFinished)
    }

    @Test func segmentsCutAtSentencesThenSpacesAndNeverSplitGraphemes() {
        #expect(OpenAISpeechClient.segments(of: "One. Two three. Four", maxScalars: 10) == ["One.", "Two three.", "Four"])
        #expect(OpenAISpeechClient.segments(of: "alpha beta gamma delta", maxScalars: 11) == ["alpha beta", "gamma delta"])
        #expect(OpenAISpeechClient.segments(of: "abcdefghij", maxScalars: 4) == ["abcd", "efgh", "ij"])
        #expect(OpenAISpeechClient.segments(of: "Version 3.5 is out", maxScalars: 10) == ["Version", "3.5 is out"])
        // 👍🏽 is two scalars: count scalars, keep each emoji whole.
        let thumbs = String(repeating: "👍🏽", count: 5)
        let pieces = OpenAISpeechClient.segments(of: thumbs, maxScalars: 5)
        #expect(pieces == ["👍🏽👍🏽", "👍🏽👍🏽", "👍🏽"])
        #expect(OpenAISpeechClient.segments(of: "   ") == [])
    }

    // MARK: - Request encoding

    @Test func encodesTheDocumentedRequest() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Data([0, 0])])])
        let client = OpenAISpeechClient(context: Self.context(fake), model: "gpt-4o-mini-tts")

        _ = try await Self.collect(client.speak("  Hello there.  ", voice: "coral", instructions: "Speak warmly and briskly."))

        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)")
        #expect(try fake.jsonBody() == [
            "model": "gpt-4o-mini-tts",
            "input": "Hello there.",
            "voice": "coral",
            "instructions": "Speak warmly and briskly.",
            "response_format": "pcm",
        ])
    }

    @Test func honoursBaseURLExtraHeadersAndKeylessServers() async throws {
        let fake = FakeHTTPTransport([.init(chunks: [Data([0, 0])])])
        let context = Self.context(fake, baseURL: "http://127.0.0.1:8880/v1/", apiKey: nil, headers: ["X-Title": "OpenClicky"])
        let client = OpenAISpeechClient(context: context, model: "tts-1")

        _ = try await Self.collect(client.speak("Local.", voice: nil, instructions: nil))

        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8880/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == "OpenClicky")
        #expect(try fake.jsonBody()["voice"] == "alloy")  // tts-1 has no cedar
    }

    @Test func mapsVoicesInstructionsAndSpeed() async throws {
        let fake = FakeHTTPTransport(Array(repeating: FakeHTTPTransport.Scripted(chunks: [Data([0, 0])]), count: 6))

        let defaults = OpenAISpeechClient(context: Self.context(fake))
        _ = try await Self.collect(defaults.speak("A.", voice: nil, instructions: "   "))
        _ = try await Self.collect(defaults.speak("B.", voice: "  ", instructions: nil))
        _ = try await Self.collect(defaults.speak("C.", voice: "voice_1234", instructions: nil))

        let configured = OpenAISpeechClient(context: Self.context(fake), model: "gpt-4o-mini-tts", defaultVoice: "marin", speed: 9)
        _ = try await Self.collect(configured.speak("D.", voice: nil, instructions: String(repeating: "x", count: 5000)))

        let legacy = OpenAISpeechClient(context: Self.context(fake), model: "tts-1-hd", speed: 0.1)
        _ = try await Self.collect(legacy.speak("E.", voice: "nova", instructions: "Whisper."))

        let snapshot = OpenAISpeechClient(context: Self.context(fake), model: "gpt-4o-mini-tts-2025-12-15")
        _ = try await Self.collect(snapshot.speak("F.", voice: nil, instructions: "Calm."))
        #expect(fake.requests.count == 6)

        let bodies = try (0..<6).map { try fake.jsonBody($0) }
        #expect(bodies[0]["voice"] == "cedar")
        #expect(bodies[0]["instructions"] == nil)  // blank instructions are not sent
        #expect(bodies[0]["speed"] == nil)
        #expect(bodies[1]["voice"] == "cedar")
        #expect(bodies[2]["voice"] == ["id": "voice_1234"])  // custom voices go by id
        #expect(bodies[3]["voice"] == "marin")
        #expect(bodies[3]["speed"] == 4)  // clamped to the documented maximum
        #expect(bodies[3]["instructions"]?.stringValue?.count == 4096)
        #expect(bodies[4]["model"] == "tts-1-hd")
        #expect(bodies[4]["voice"] == "nova")
        #expect(bodies[4]["instructions"] == nil)  // "Does not work with tts-1 or tts-1-hd"
        #expect(bodies[4]["speed"] == 0.25)
        #expect(bodies[5]["instructions"] == "Calm.")
    }

    @Test func leavesOutANonFiniteSpeedInsteadOfSendingANullBody() async throws {
        let fake = FakeHTTPTransport(Array(repeating: FakeHTTPTransport.Scripted(chunks: [Data([0, 0])]), count: 2))
        for speed in [Double.nan, -Double.infinity] {
            let client = OpenAISpeechClient(context: Self.context(fake), speed: speed)
            _ = try await Self.collect(client.speak("Hi.", voice: nil, instructions: nil))
        }
        for index in 0..<2 {
            // JSONEncoder cannot encode NaN or infinity; a stray one used to turn the whole body into `null`.
            let body = try fake.jsonBody(index)
            #expect(body == ["model": "gpt-4o-mini-tts", "input": "Hi.", "voice": "cedar", "response_format": "pcm"])
        }
    }

    @Test func descriptionsNeverContainTheKey() {
        let client = OpenAISpeechClient(context: Self.context(FakeHTTPTransport([])))
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
            #expect(!text.contains(Self.fakeKey), "a description leaked the API key")
            #expect(text.contains("gpt-4o-mini-tts"))
        }
    }

    // MARK: - Errors

    @Test func surfacesTheDocumentedErrorMessageWithStatus() async throws {
        let body = """
        {
            "error": {
                "message": "Incorrect API key provided: sk-test-*****************************cdef. You can find your API key at https://platform.openai.com/account/api-keys.",
                "type": "invalid_request_error",
                "param": null,
                "code": "invalid_api_key"
            }
        }
        """
        let fake = FakeHTTPTransport([.init(status: 401, headers: ["Content-Type": "application/json"],
                                            chunks: Self.chunks(Data(body.utf8), sizes: [7, 1, 30, 2, 90]))])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let error = try #require(await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil)))
        #expect(error.status == 401)
        #expect(error.provider == "openai")
        #expect(error.message == "Incorrect API key provided: sk-test-*****************************cdef. You can find your API key at https://platform.openai.com/account/api-keys.")
        #expect(fake.requests.count == 1)
        #expect(client.inFlightCount == 0)
    }

    @Test func fallsBackToTheRawBodyForUndocumentedErrors() async throws {
        let fake = FakeHTTPTransport([
            .body("upstream connect error or disconnect/reset before headers", status: 503, contentType: "text/plain"),
            .init(status: 500, chunks: []),
        ])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let plain = try #require(await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil)))
        #expect(plain.status == 503)
        #expect(plain.message == "upstream connect error or disconnect/reset before headers")
        let empty = try #require(await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil)))
        #expect(empty.status == 500)
        #expect(empty.message == HTTPURLResponse.localizedString(forStatusCode: 500))
    }

    @Test func oneByteChunkedErrorBodiesKeepTheMessageIntact() async throws {
        // The spec's InferenceRateLimited example, and a 400 whose message has multi-byte UTF-8 that a one-byte
        // read splits mid-character.
        let rateLimited = """
        {"error":{"message":"Your request rate increased too quickly. Please reduce the request rate and gradually increase it again.","type":"rate_limit_error","param":null,"code":"slow_down"}}
        """
        let badVoice = """
        {"error":{"message":"Invalid value for 'voice': 'zoë' is not a supported voice — use one of alloy, cedar, marin… 声音","type":"invalid_request_error","param":"voice","code":null}}
        """
        let oneByte = { (text: String) in Data(text.utf8).map { Data([$0]) } }
        let fake = FakeHTTPTransport([
            .init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "2"], chunks: oneByte(rateLimited)),
            .init(status: 400, headers: ["Content-Type": "application/json"], chunks: oneByte(badVoice)),
        ])
        let client = OpenAISpeechClient(context: Self.context(fake))

        let limited = try #require(await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil)))
        #expect(limited.status == 429)
        #expect(limited.message == "Your request rate increased too quickly. Please reduce the request rate and gradually increase it again.")
        let invalid = try #require(await Self.providerError(client.speak("Hi.", voice: "zoë", instructions: nil)))
        #expect(invalid.status == 400)
        #expect(invalid.message == "Invalid value for 'voice': 'zoë' is not a supported voice — use one of alloy, cedar, marin… 声音")
    }

    @Test func refusesToPlayA2xxBodyThatIsNotPCM() async throws {
        // A server that ignored response_format "pcm" and sent MP3 (ID3 tag, then an MPEG frame header).
        let mp3 = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFB, 0x90, 0x64])
        // stream_format "sse" events, shaped like the spec's SpeechAudioDeltaEvent.
        let sse = "data: {\"type\":\"speech.audio.delta\",\"audio\":\"AAABAA==\"}\n\n"
        let fake = FakeHTTPTransport([
            .init(headers: ["Content-Type": "audio/mpeg"], chunks: [mp3]),
            .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data(sse.utf8)]),
            .init(headers: ["Content-Type": "application/json"],
                  chunks: [Data(#"{"error":{"message":"Gateway quota exhausted.","type":"server_error","param":null,"code":null}}"#.utf8)]),
            .init(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data("<!doctype html><title>Login</title>".utf8)]),
        ])
        let client = OpenAISpeechClient(context: Self.context(fake))

        for _ in 0..<4 {
            var audio: [Data] = []
            do {
                for try await event in client.speak("Hi.", voice: nil, instructions: nil) {
                    if case .audio(let data, _) = event { audio.append(data) }
                }
                Issue.record("a non-PCM body was accepted")
            } catch let error as ProviderError {
                #expect(error.status == 200)
                #expect(!error.message.isEmpty)
                let request = fake.requests.count
                switch request {
                case 1: #expect(error.message.contains("audio/mpeg"))
                case 2: #expect(error.message.contains("text/event-stream"))
                case 3: #expect(error.message == "Gateway quota exhausted.")
                default: #expect(error.message.contains("text/html") && error.message.contains("Login"))
                }
            }
            #expect(audio.isEmpty, "non-PCM bytes were played as samples")
        }
    }

    @Test func playsTheDocumentedPCMContentTypesAndUntypedBodies() async throws {
        let types: [[String: String]] = [
            ["Content-Type": "audio/pcm"],
            ["Content-Type": "application/octet-stream"],
            ["Content-Type": "Audio/PCM; rate=24000"],
            [:],
        ]
        let fake = FakeHTTPTransport(types.map { .init(headers: $0, chunks: [Data([1, 2, 3, 4])]) })
        let client = OpenAISpeechClient(context: Self.context(fake))
        for _ in types {
            let events = try await Self.collect(client.speak("Hi.", voice: nil, instructions: nil))
            #expect(events == [.audio(Data([1, 2, 3, 4]), .speech24k), .lineFinished])
        }
    }

    @Test func aMidLineErrorStopsWithoutFinishingTheLine() async throws {
        let transport = ControlledTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        var iterator = client.speak("Hi.", voice: nil, instructions: nil).makeAsyncIterator()
        try await transport.waitForRequest()
        transport.send(Data([1, 2]))
        #expect(try await iterator.next() == .audio(Data([1, 2]), .speech24k))
        transport.finish(throwing: URLError(.networkConnectionLost))
        await #expect(throws: URLError.self) { _ = try await iterator.next() }
    }

    // MARK: - Cancellation

    @Test func cancellingTheConsumerCancelsTheRequest() async throws {
        let transport = ControlledTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        let (firstAudio, firstAudioContinuation) = AsyncStream<Void>.makeStream()

        let consumer = Task { () -> [SpeechEvent] in
            var events: [SpeechEvent] = []
            for try await event in client.speak("Barge in on me.", voice: nil, instructions: nil) {
                events.append(event)
                firstAudioContinuation.yield()
            }
            return events
        }

        try await transport.waitForRequest()
        transport.send(Data([1, 2, 3, 4]))
        var signals = firstAudio.makeAsyncIterator()
        _ = await signals.next()
        consumer.cancel()

        #expect(try await transport.waitForTermination() == "cancelled")
        let events = (try? await consumer.value) ?? []
        #expect(!events.contains(.lineFinished))
        try await eventually { client.inFlightCount == 0 }
    }

    @Test func stopAllCancelsEveryLineInFlight() async throws {
        let transport = ControlledTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        let consumer = Task { try await Self.collect(client.speak("Stop me.", voice: nil, instructions: nil)) }

        try await transport.waitForRequest()
        transport.send(Data([9, 9]))
        try await eventually { client.inFlightCount == 1 }
        await client.stopAll()

        #expect(try await transport.waitForTermination() == "cancelled")
        await #expect(throws: CancellationError.self) { _ = try await consumer.value }
        try await eventually { client.inFlightCount == 0 }
    }

    @Test func stopAllBeforeTheHeadersArriveEndsWithCancellationErrorNotURLError() async throws {
        // URLSession throws URLError(.cancelled) when the task awaiting `bytes(for:)` is cancelled; this transport
        // does the same.
        let transport = HeaderWaitTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        let consumer = Task { try await Self.collect(client.speak("Stop before the headers.", voice: nil, instructions: nil)) }

        try await eventually { transport.waiting }
        await client.stopAll()

        await #expect(throws: CancellationError.self) { _ = try await consumer.value }
        try await eventually { transport.cancelled }
        try await eventually { client.inFlightCount == 0 }
    }

    @Test func cancellingTheConsumerBeforeTheHeadersCancelsTheRequest() async throws {
        let transport = HeaderWaitTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        let consumer = Task { try await Self.collect(client.speak("Cancel me early.", voice: nil, instructions: nil)) }

        try await eventually { transport.waiting }
        consumer.cancel()

        try await eventually { transport.cancelled }
        let events = (try? await consumer.value) ?? []
        #expect(events.isEmpty)
        try await eventually { client.inFlightCount == 0 }
    }

    @Test func droppingAnUnreadStreamCancelsTheWork() async throws {
        let transport = ControlledTransport()
        let client = OpenAISpeechClient(context: Self.context(transport))
        do {
            let stream = client.speak("Never mind.", voice: nil, instructions: nil)
            _ = stream
        }
        try await eventually { client.inFlightCount == 0 }
    }
}

// MARK: - Helpers

/// Polls a condition for up to two seconds.
/// The timeout only guards against a hang: a busy machine can take far longer than an idle one.
private func eventually(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(10)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct TimeoutError: Error {}

/// An HTTP transport that never sends response headers and, like URLSession, throws URLError(.cancelled) when the
/// waiting task is cancelled.
private final class HeaderWaitTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    var waiting: Bool { lock.withLock { pending != nil } }
    var cancelled: Bool { lock.withLock { isCancelled } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = lock.withLock {
                    if isCancelled { return true }
                    pending = continuation
                    return false
                }
                if resumeNow { continuation.resume(throwing: URLError(.cancelled)) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                isCancelled = true
                defer { pending = nil }
                return pending
            }
            continuation?.resume(throwing: URLError(.cancelled))
        }
        throw URLError(.badServerResponse)  // never reached: headers never arrive
    }
}

/// An HTTP transport whose single streamed body the test feeds by hand, recording how the stream ended.
private final class ControlledTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var body: AsyncThrowingStream<Data, Error>.Continuation?
    private var terminations: [String] = []
    private(set) var requests: [URLRequest] = []
    let status: Int

    init(status: Int = 200) { self.status = status }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            guard let self else { return }
            let label: String
            switch termination {
            case .cancelled: label = "cancelled"
            case .finished(let error): label = error == nil ? "finished" : "failed"
            @unknown default: label = "unknown"
            }
            lock.withLock { terminations.append(label) }
        }
        lock.withLock {
            requests.append(request)
            body = continuation
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/octet-stream"])!
        return (stream, response)
    }

    func send(_ data: Data) { _ = lock.withLock { body }?.yield(data) }
    func finish(throwing error: Error? = nil) { lock.withLock { body }?.finish(throwing: error) }

    func waitForRequest() async throws {
        try await eventually { [self] in lock.withLock { body != nil } }
    }

    func waitForTermination() async throws -> String {
        try await eventually { [self] in lock.withLock { !terminations.isEmpty } }
        return lock.withLock { terminations[0] }
    }
}
