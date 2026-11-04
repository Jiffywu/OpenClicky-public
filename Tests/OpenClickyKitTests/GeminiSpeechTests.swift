import Foundation
import Testing
@testable import OpenClickyKit

/// GeminiSpeechClient against scripted Interactions API responses shaped like the speech-generation and streaming
/// guides on ai.google.dev (SSE `event:`/`data:` pairs, `step.delta` audio deltas, `interaction.completed`,
/// `event: done` / `data: [DONE]`). No network, no real key.
@Suite(.timeLimit(.minutes(1)))
struct GeminiSpeechTests {
    static let fakeKey = "AIza-tts-test-key-not-real-0123456789"
    static let format24k = PCMFormat(sampleRate: 24_000, channels: 1)

    static func context(_ http: any HTTPTransport, baseURL: String? = "https://generativelanguage.googleapis.com/v1beta",
                        apiKey: String? = fakeKey, headers: [String: String]? = nil) -> ProviderContext {
        ProviderContext(
            provider: ProviderConfig(id: "gemini-speech", dialect: .geminiSpeech, baseURL: baseURL.flatMap(URL.init(string:)),
                                     credential: "gemini", headers: headers),
            apiKey: apiKey, http: http)
    }

    /// 16-bit little-endian mono samples of a tone, the `audio/l16` shape.
    static func tone(samples: Int, rate: Double = 24_000) -> Data {
        var data = Data(capacity: samples * 2)
        for n in 0..<samples {
            let value = Int16(8_000 * sin(2 * Double.pi * 440 * Double(n) / rate))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func wav(_ pcm: Data, rate: Int = 24_000, channels: Int = 1, bits: Int = 16) -> Data {
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        var header: [UInt8] = Array("RIFF".utf8) + le32(36 + pcm.count) + Array("WAVE".utf8)
        header += Array("fmt ".utf8) + le32(16) + le16(1) + le16(channels) + le32(rate)
        header += le32(rate * channels * bits / 8) + le16(channels * bits / 8) + le16(bits)
        header += Array("data".utf8) + le32(pcm.count)
        return Data(header) + pcm
    }

    // MARK: Stream bodies (the streaming guide's event order)

    static func event(_ name: String, _ data: JSONValue) -> String { "event: \(name)\ndata: \(data.jsonString())\n\n" }

    static func audioDelta(_ bytes: Data, index: Int = 0, extra: [String: JSONValue] = [:]) -> String {
        var delta: [String: JSONValue] = ["type": "audio", "data": .string(bytes.base64EncodedString())]
        delta.merge(extra) { $1 }
        return event("step.delta", ["index": .number(Double(index)), "delta": .object(delta), "event_type": "step.delta"])
    }

    static func stream(_ deltas: [String], status: String = "completed", done: Bool = true, completed: Bool = true) -> String {
        var body = event("interaction.created", ["interaction": ["id": "v1_test", "status": "in_progress", "object": "interaction",
                                                                 "model": "gemini-3.8-flash-lite-tts"], "event_type": "interaction.created"])
        body += event("step.start", ["index": 0, "step": ["type": "model_output"], "event_type": "step.start"])
        body += deltas.joined()
        body += event("step.stop", ["index": 0, "event_type": "step.stop"])
        if completed {
            body += event("interaction.completed", ["interaction": ["id": "v1_test", "status": .string(status),
                                                                   "usage": ["total_tokens": 42]], "event_type": "interaction.completed"])
        }
        if done { body += "event: done\ndata: [DONE]\n\n" }
        return body
    }

    static func collect(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async throws -> [SpeechEvent] {
        var events: [SpeechEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

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

    static func audio(in events: [SpeechEvent]) -> [(data: Data, format: PCMFormat)] {
        events.compactMap { if case .audio(let data, let format) = $0 { (data, format) } else { nil } }
    }

    // MARK: Request

    @Test func requestMatchesTheStreamingSpeechSampleAndSpeaksTheLineVerbatim() async throws {
        let line = "Click the blue <short pause> \"Share\" button — top right."
        let fake = FakeHTTPTransport([.sse(Self.stream([Self.audioDelta(Self.tone(samples: 480))]))])
        let client = GeminiSpeechClient(context: Self.context(fake, headers: ["X-Trace": "abc"]))
        _ = try await Self.collect(client.speak(line, voice: "gemini:puck", instructions: "  calm, friendly "))

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == Self.fakeKey)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Trace") == "abc")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let requestURL = try #require(request.url).absoluteString
        #expect(!requestURL.contains(Self.fakeKey))

        let expected: JSONValue = [
            "model": "gemini-3.8-flash-lite-tts",
            "input": [["type": "user_input", "content": [[
                "type": "text",
                "text": .string(line),
                "annotations": [["type": "speech_metadata", "style": "calm, friendly"]],
            ]]]],
            "response_format": ["type": "audio", "mime_type": "audio/l16", "sample_rate": 24_000],
            "generation_config": ["speech_config": [["voice": "Puck"]]],
            "stream": true,
            "store": false,
        ]
        #expect(try fake.jsonBody() == expected)
    }

    @Test func voicesInstructionsAndOptionsMapOntoTheBody() async throws {
        let options = GeminiSpeechClient.Options(sampleRate: 16_000, store: true, maxStyleCharacters: 10, language: "en-US",
                                                 speechConfigField: "structured_speech_config")
        let client = GeminiSpeechClient(context: Self.context(FakeHTTPTransport([])), model: "gemini-3.8-flash-tts",
                                        defaultVoice: "achernar", options: options)
        #expect(client.defaultVoice == "Achernar")
        #expect(client.outputFormat == PCMFormat(sampleRate: 16_000, channels: 1))

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(
            client.makeRequest(text: "Hi", voice: "voice_abc123", style: String(repeating: "x", count: 10)).httpBody))
        #expect(body["model"] == "gemini-3.8-flash-tts")
        #expect(body["store"] == true)
        #expect(body["response_format"]?["sample_rate"] == 16_000)
        #expect(body["generation_config"] == ["structured_speech_config": [["voice": "voice_abc123", "language": "en-US"]]])

        let plain = GeminiSpeechClient(context: Self.context(FakeHTTPTransport([])))
        let noStyle = try JSONDecoder().decode(JSONValue.self, from: try #require(plain.makeRequest(text: "Hi", voice: "Kore", style: "").httpBody))
        #expect(noStyle["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["annotations"] == nil)

        #expect(GeminiSpeechWire.voiceName(nil) == nil)
        #expect(GeminiSpeechWire.voiceName("  ") == nil)
        #expect(GeminiSpeechWire.voiceName("gemini:") == nil)
        #expect(GeminiSpeechWire.voiceName("ZUBENELGENUBI") == "Zubenelgenubi")
        #expect(GeminiSpeechWire.voiceName("Gemini:Sulafat") == "Sulafat")
        #expect(GeminiSpeechWire.voiceName("voicekey_xyz") == "voicekey_xyz")
        #expect(GeminiSpeechClient.prebuiltVoices.count == 30)
    }

    @Test func longInstructionsAreCappedAndBlankDefaultsFallBack() async throws {
        let fake = FakeHTTPTransport([.sse(Self.stream([Self.audioDelta(Self.tone(samples: 10))]))])
        let client = GeminiSpeechClient(context: Self.context(fake), defaultVoice: " ",
                                        options: .init(maxStyleCharacters: 5))
        #expect(client.defaultVoice == "Kore")
        _ = try await Self.collect(client.speak("Hello.", voice: nil, instructions: "whispering softly"))
        let body = try fake.jsonBody()
        #expect(body["generation_config"] == ["speech_config": [["voice": "Kore"]]])
        let annotation = body["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["annotations"]?.arrayValue?.first
        #expect(annotation?["style"] == "whisp")
    }

    @Test func interactionsURLAcceptsBasesWithAndWithoutAVersion() {
        func url(_ base: String?) -> String { GeminiSpeechWire.interactionsURL(base: base.flatMap(URL.init(string:))).absoluteString }
        let standard = "https://generativelanguage.googleapis.com/v1beta/interactions"
        #expect(url(nil) == standard)
        #expect(url("https://generativelanguage.googleapis.com") == standard)
        #expect(url("https://generativelanguage.googleapis.com/") == standard)
        #expect(url("https://generativelanguage.googleapis.com/v1beta/") == standard)
        #expect(url("https://generativelanguage.googleapis.com/v1alpha") == "https://generativelanguage.googleapis.com/v1alpha/interactions")
        #expect(url(standard) == standard)
        #expect(url("http://127.0.0.1:8080/proxy/v1beta") == "http://127.0.0.1:8080/proxy/v1beta/interactions")
    }

    // MARK: Streaming

    @Test func streamedDeltasBecomeWholeSampleChunksAcrossOddSplitsThenTheLineFinishes() async throws {
        let pcm = Self.tone(samples: 6_000)  // 12,000 bytes, 250 ms
        // Deltas split mid-sample, the way a network-agnostic test should assume they could be.
        let sizes = [3, 5, 1, 4_801, 2_190]
        var deltas: [String] = []
        var offset = 0
        for size in sizes {
            deltas.append(Self.audioDelta(pcm.subdata(in: offset..<(offset + size))))
            offset += size
        }
        deltas.append(Self.audioDelta(pcm.subdata(in: offset..<pcm.count), extra: ["mime_type": "audio/l16"]))
        // .sse cuts the body into 37-byte network chunks, splitting events and base64 alike.
        let fake = FakeHTTPTransport([.sse(Self.stream(deltas))])
        let client = GeminiSpeechClient(context: Self.context(fake))

        let events = try await Self.collect(client.speak("Here is the answer.", voice: "Kore", instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        let chunks = Self.audio(in: events)
        #expect(chunks.allSatisfy { !$0.data.isEmpty && $0.data.count % 2 == 0 && $0.data.count <= 4_800 })
        #expect(chunks.allSatisfy { $0.format == Self.format24k })
        #expect(chunks.map(\.data).reduce(Data(), +) == pcm)
        #expect(client.inFlightCount == 0)
    }

    @Test func deltaSampleRatesAndRateParametersAreReported() async throws {
        let pcm16k = Self.tone(samples: 320, rate: 16_000)
        let fake = FakeHTTPTransport([
            .sse(Self.stream([Self.audioDelta(pcm16k, extra: ["mime_type": "audio/l16", "sample_rate": 16_000, "channels": 1])])),
            .sse(Self.stream([Self.audioDelta(pcm16k, extra: ["mime_type": "audio/l16;rate=8000"])])),
        ])
        let client = GeminiSpeechClient(context: Self.context(fake))
        let first = Self.audio(in: try await Self.collect(client.speak("One.", voice: nil, instructions: nil)))
        #expect(first.map(\.format) == [PCMFormat(sampleRate: 16_000)])
        let second = Self.audio(in: try await Self.collect(client.speak("Two.", voice: nil, instructions: nil)))
        #expect(second.map(\.format) == [PCMFormat(sampleRate: 8_000)])
    }

    /// Review fix: a delta's `sample_rate` or `channels` near `Int.max` used to overflow `sampleRate * channels * 2`
    /// (or the frame size), which traps and takes the app down. Such a line now fails with a ProviderError.
    @Test func absurdDeltaFormatsFailTheLineInsteadOfCrashing() async throws {
        let pcm = Self.tone(samples: 64)
        let fake = FakeHTTPTransport([
            .sse(Self.stream([Self.audioDelta(pcm, extra: ["sample_rate": 4.7e18])])),
            .sse(Self.stream([Self.audioDelta(pcm, extra: ["channels": 5e18])])),
            .sse(Self.stream([Self.audioDelta(pcm, extra: ["mime_type": "audio/l16;rate=9000000000000000000"])])),
            .sse(Self.stream([Self.audioDelta(Self.wav(pcm, rate: 0x7FFF_FFFF), extra: ["mime_type": "audio/wav"])])),
        ])
        let client = GeminiSpeechClient(context: Self.context(fake))
        for line in ["One.", "Two.", "Three.", "Four."] {
            let error = await Self.providerError(client.speak(line, voice: nil, instructions: nil))
            #expect(error?.message.contains("cannot play") == true, "\(line) \(String(describing: error))")
        }
        #expect(fake.requests.count == 4)
    }

    @Test func aWAVHeaderInAStreamedDeltaIsStripped() async throws {
        let pcm = Self.tone(samples: 100)
        let fake = FakeHTTPTransport([.sse(Self.stream([
            Self.audioDelta(Self.wav(pcm.prefix(100), rate: 24_000), extra: ["mime_type": "audio/wav"]),
            Self.audioDelta(pcm.dropFirst(100), extra: ["mime_type": "audio/wav"]),
        ]))])
        let events = try await Self.collect(GeminiSpeechClient(context: Self.context(fake)).speak("Hi.", voice: nil, instructions: nil))
        #expect(Self.audio(in: events).map(\.data).reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
    }

    @Test func longLinesAreSentAsSeveralVerbatimPiecesInOrder() async throws {
        let sentence = "This sentence is exactly fifty characters long ok. "
        let text = String(repeating: sentence, count: 4).trimmingCharacters(in: .whitespaces)
        let fake = FakeHTTPTransport([
            .sse(Self.stream([Self.audioDelta(Self.tone(samples: 10))])),
            .sse(Self.stream([Self.audioDelta(Self.tone(samples: 20))])),
        ])
        let client = GeminiSpeechClient(context: Self.context(fake), options: .init(maxInputCharacters: 110))
        let events = try await Self.collect(client.speak(text, voice: nil, instructions: nil))
        #expect(fake.requests.count == 2)
        let texts = try (0..<2).map { try fake.jsonBody($0)["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["text"]?.stringValue }
        #expect(texts.compactMap { $0 }.joined(separator: " ") == text)
        #expect(Self.audio(in: events).map(\.data).reduce(Data(), +) == Self.tone(samples: 10) + Self.tone(samples: 20))
        #expect(events.last == .lineFinished)
    }

    @Test func blankTextFinishesWithoutARequest() async throws {
        let fake = FakeHTTPTransport([])
        let events = try await Self.collect(GeminiSpeechClient(context: Self.context(fake)).speak("  \n", voice: nil, instructions: nil))
        #expect(events == [.lineFinished])
        #expect(fake.requests.isEmpty)
    }

    // MARK: Unary fallback

    @Test func aUnaryInteractionIsReadAndItsWAVIsChunkedIntoWholeSamples() async throws {
        let pcm = Self.tone(samples: 5_001)
        let body: JSONValue = [
            "id": "v1_unary", "status": "completed",
            "steps": [
                ["type": "model_output", "content": [
                    ["type": "audio", "mime_type": "audio/wav", "data": .string(Self.wav(pcm).base64EncodedString())],
                ]],
            ],
        ]
        let fake = FakeHTTPTransport([.body(body.jsonString())])
        let events = try await Self.collect(GeminiSpeechClient(context: Self.context(fake)).speak("Hi.", voice: nil, instructions: nil))
        let chunks = Self.audio(in: events)
        #expect(chunks.map(\.data.count) == [4_800, 4_800, 402])
        #expect(chunks.allSatisfy { $0.format == Self.format24k })
        #expect(chunks.map(\.data).reduce(Data(), +) == pcm)
        #expect(events.last == .lineFinished)
    }

    @Test func wavPayloadSkipsExtraChunksAndRejectsNonPCM() {
        let pcm = Self.tone(samples: 4)
        var withList = Self.wav(pcm)
        // Insert a LIST chunk between fmt and data.
        let list = Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("INFO".utf8)
        withList.insert(contentsOf: list, at: 36)
        let parsed = GeminiSpeechWire.wavPayload(withList)
        #expect(parsed?.pcm == pcm)
        #expect(parsed?.format == PCMFormat(sampleRate: 24_000))
        #expect(GeminiSpeechWire.wavPayload(Self.wav(pcm, bits: 8)) == nil)
        #expect(GeminiSpeechWire.wavPayload(pcm) == nil)
        #expect(GeminiSpeechWire.decodeBase64("AQID") == Data([1, 2, 3]))
        #expect(GeminiSpeechWire.decodeBase64("_-8") == Data([0xFF, 0xEF]))
        #expect(GeminiSpeechWire.decodeBase64("A") == nil)
    }

    // MARK: Errors

    @Test func googleHTTPErrorsSurfaceStatusAndMessage() async throws {
        let body = #"{"error": {"code": 400, "message": "Invalid voice name: Nobody", "status": "INVALID_ARGUMENT"}}"#
        let fake = FakeHTTPTransport([.body(body, status: 400)])
        let error = await Self.providerError(GeminiSpeechClient(context: Self.context(fake)).speak("Hi.", voice: "Nobody", instructions: nil))
        #expect(error?.status == 400)
        #expect(error?.message == "INVALID_ARGUMENT: Invalid voice name: Nobody")
        #expect(error?.provider == "gemini-speech")

        let plain = FakeHTTPTransport([.body("upstream connect error", status: 503, contentType: "text/plain")])
        let plainError = await Self.providerError(GeminiSpeechClient(context: Self.context(plain)).speak("Hi.", voice: nil, instructions: nil))
        #expect(plainError?.status == 503)
        #expect(plainError?.message == "upstream connect error")
    }

    @Test func anInStreamErrorEventFailsTheLine() async throws {
        let errorEvent = #"event: error"# + "\n"
            + #"data: {"error":{"message":"Deadline expired before operation could complete.","code":"gateway_timeout"},"event_type":"error"}"#
            + "\n\n"
        let fake = FakeHTTPTransport([.sse(Self.stream([Self.audioDelta(Self.tone(samples: 10)), errorEvent], done: false, completed: false))])
        let stream = GeminiSpeechClient(context: Self.context(fake)).speak("Hi.", voice: nil, instructions: nil)
        var sawAudio = false
        do {
            for try await event in stream { if case .audio = event { sawAudio = true } }
            Issue.record("expected the line to fail")
        } catch let error as ProviderError {
            #expect(error.message == "Gemini speech failed: gateway_timeout: Deadline expired before operation could complete.")
        }
        #expect(sawAudio)
    }

    @Test func aStreamCutOffBeforeCompletionIsAnError() async throws {
        let fake = FakeHTTPTransport([.sse(Self.stream([Self.audioDelta(Self.tone(samples: 10))], done: false, completed: false))])
        let error = await Self.providerError(GeminiSpeechClient(context: Self.context(fake)).speak("Hi.", voice: nil, instructions: nil))
        #expect(error?.message.contains("ended before the line was complete") == true)
    }

    @Test func aCompletedStreamWithNoAudioOrAFailedStatusIsAnError() async throws {
        let fake = FakeHTTPTransport([
            .sse(Self.stream([])),
            .sse(Self.stream([Self.audioDelta(Self.tone(samples: 10))], status: "failed")),
        ])
        let client = GeminiSpeechClient(context: Self.context(fake))
        let silent = await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(silent?.message.contains("without sending any audio") == true)
        let failed = await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(failed?.message.contains("as failed") == true)
    }

    @Test func compressedAudioOrUnexpectedContentIsRefused() async throws {
        let fake = FakeHTTPTransport([
            .sse(Self.stream([Self.audioDelta(Data([1, 2, 3, 4]), extra: ["mime_type": "audio/mp3"])])),
            .body("<html>Not Found</html>", status: 200, contentType: "text/html"),
            .body("{\"id\":\"v1_x\",\"steps\":[]}"),
        ])
        let client = GeminiSpeechClient(context: Self.context(fake))
        let mp3 = await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(mp3?.message.contains("audio/mp3") == true)
        let html = await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(html?.message.contains("text/html") == true)
        let empty = await Self.providerError(client.speak("Hi.", voice: nil, instructions: nil))
        #expect(empty?.message.contains("held no audio") == true)
    }

    // MARK: Cancellation and warm-up

    /// A transport whose response body never ends until the request task is cancelled.
    final class HangingTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requestCount: Int { lock.withLock { count } }
        let first: Data

        init(first: Data) { self.first = first }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

        func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
            lock.withLock { count += 1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            let first = first
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(first)
                let task = Task {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (stream, response)
        }
    }

    @Test func stopAllCancelsALineMidStream() async throws {
        let transport = HangingTransport(first: Data(Self.audioDelta(Self.tone(samples: 240)).utf8))
        let client = GeminiSpeechClient(context: Self.context(transport))
        let stream = client.speak("A long line.", voice: nil, instructions: nil)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        if case .audio(let data, _)? = first { #expect(data.count == 480) } else { Issue.record("expected audio first") }
        #expect(client.inFlightCount == 1)
        await client.stopAll()
        do {
            while let event = try await iterator.next() { #expect(event != .lineFinished) }
            Issue.record("expected CancellationError")
        } catch is CancellationError {
        }
        #expect(client.inFlightCount == 0)
    }

    @Test func aConsumerThatGoesAwayCancelsTheRequest() async throws {
        let transport = HangingTransport(first: Data(Self.audioDelta(Self.tone(samples: 24)).utf8))
        let client = GeminiSpeechClient(context: Self.context(transport))
        let consumer = Task {
            for try await _ in client.speak("Interrupt me.", voice: nil, instructions: nil) {}
        }
        // The limits are hang guards: a busy machine can be slow, and the transport never answers on its own.
        _ = await waitUntil { transport.requestCount > 0 }
        #expect(client.inFlightCount == 1)
        consumer.cancel()
        _ = await consumer.result
        _ = await waitUntil { client.inFlightCount == 0 }
        #expect(client.inFlightCount == 0)
    }

    @Test func warmUpSendsOneKeylessHeadPerInterval() async throws {
        let fake = FakeHTTPTransport([.body("", status: 404, contentType: "text/html"), .body("")])
        let client = GeminiSpeechClient(context: Self.context(fake), options: .init(warmUpInterval: .seconds(60)))
        await client.warmUp()
        await client.warmUp()
        #expect(fake.requests.count == 1)
        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
    }

    // MARK: Catalog, dialect, presets, redaction

    @Test func catalogDialectAndPresetCoverGeminiSpeech() throws {
        #expect(ProviderDialect(rawValue: "gemini-speech") == .geminiSpeech)
        #expect(ProviderDialect.geminiSpeech.servableKinds == [.textToSpeech])
        let catalog = try ModelCatalog.builtIn()
        for id in ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"] {
            let model = try #require(catalog.model(id, servedBy: .geminiSpeech))
            #expect(model.kind == .textToSpeech)
            #expect(model.voices == GeminiSpeechClient.prebuiltVoices)
            #expect(model.has(.streaming))
        }
        #expect(Set(catalog.candidates(for: .voice, dialect: .geminiSpeech).map(\.id)) == ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"])
        #expect(catalog.candidates(for: .stt, dialect: .geminiSpeech).isEmpty)
        let preset = try #require(ProviderPreset.all.first { $0.id == "gemini-speech" })
        #expect(preset.config.dialect == .geminiSpeech)
        #expect(GeminiSpeechWire.interactionsURL(base: preset.config.baseURL).absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/interactions")
    }

    @Test func theEngineFactoryBuildsTheAdapterForTheVoiceSlotWithTheChosenVoice() throws {
        let provider = try #require(ProviderPreset.all.first { $0.id == "gemini-speech" }).config
        let config = OpenClickyConfig(providers: [provider], slots: [
            .voice: SlotSelection(provider: "gemini-speech", model: "gemini-3.8-flash-lite-tts", voice: "Sulafat"),
        ])
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["gemini": Self.fakeKey]), http: FakeHTTPTransport([]))
        let client = try #require(try factory.speechOutput() as? GeminiSpeechClient)
        #expect(client.model == "gemini-3.8-flash-lite-tts")
        #expect(client.defaultVoice == "Sulafat")
        #expect(EngineFactory.adapterName(for: .geminiSpeech) == "GeminiSpeechClient")
        #expect(try factory.resolve(.voice).errors.isEmpty)
    }

    @Test func descriptionsNeverShowTheKey() {
        let client = GeminiSpeechClient(context: Self.context(FakeHTTPTransport([])))
        for text in [String(describing: client), String(reflecting: client), "\(client)"] {
            #expect(!text.contains(Self.fakeKey))
            #expect(text.contains("apiKey: set"))
        }
        var dumped = ""
        dump(client, to: &dumped)
        #expect(!dumped.contains(Self.fakeKey))
    }
}
