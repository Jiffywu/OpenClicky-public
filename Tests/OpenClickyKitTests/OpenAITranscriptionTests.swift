import Foundation
import Testing
@testable import OpenClickyKit

/// OpenAITranscriptionClient against scripted responses shaped like the API reference's examples. No network,
/// no real key: the key below is a placeholder and is only ever compared, never printed.
@Suite struct OpenAITranscriptionTests {
    // MARK: Doc-shaped payloads

    /// `stream=true` response from the reference (lyrics replaced), with logprobs as `include[]=logprobs` adds them.
    /// The third delta carries a multi-byte character so awkward chunk sizes split it.
    static let streamedBody = """
        data: {"type":"transcript.text.delta","delta":"Open","logprobs":[{"token":"Open","logprob":-0.00007588794,"bytes":[79,112,101,110]}]}

        data: {"type":"transcript.text.delta","delta":" the","logprobs":[{"token":" the","logprob":-3.1281633e-7,"bytes":[32,116,104,101]}]}

        data: {"type":"transcript.text.delta","delta":" café menu.","logprobs":[{"token":" café","logprob":-0.0012,"bytes":[32,99,97,102,195,169]}]}

        data: {"type":"transcript.text.done","text":"Open the café menu.","logprobs":[{"token":"Open","logprob":-0.00007588794,"bytes":[79,112,101,110]}],"usage":{"input_tokens":14,"input_token_details":{"text_tokens":0,"audio_tokens":14},"output_tokens":45,"total_tokens":59}}


        """

    /// Default `json` response from the reference.
    static let jsonBody = """
        {"text":"Open the café menu.","usage":{"type":"tokens","input_tokens":14,"input_token_details":{"text_tokens":0,"audio_tokens":14},"output_tokens":45,"total_tokens":59}}
        """

    static let fakeKey = "sk-test-placeholder-not-a-key"

    // MARK: Streamed result

    @Test(arguments: [1, 5, 37, 4096])
    func streamedDeltasBecomeGrowingInterimsThenOneFinal(chunkSize: Int) async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody, chunkSize: chunkSize)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: "en", keywords: [])
        await session.send(Data(repeating: 1, count: 3200))
        await session.finish()
        #expect(try await collect(session) == [
            .interim("Open"), .interim("Open the"), .interim("Open the café menu."), .final("Open the café menu."),
        ])
        #expect(fake.requests.count == 1)
    }

    @Test func streamWithoutLogprobsOrTrailingBlankLineStillFinishes() async throws {
        let body = """
            data: {"type":"transcript.text.delta","delta":"Hi"}

            data: {"type":"transcript.text.done","text":"Hi.","usage":{"type":"tokens","input_tokens":3,"output_tokens":2,"total_tokens":5}}
            """
        let fake = FakeHTTPTransport([.sse(body, chunkSize: 4)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [.interim("Hi"), .final("Hi.")])
    }

    @Test func streamThatEndsWithoutDoneKeepsTheHeardText() async throws {
        let body = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Open\"}\n\ndata: {\"type\":\"transcript.text.delta\",\"delta\":\" Finder\"}\n\n"
        let fake = FakeHTTPTransport([.sse(body, chunkSize: 9)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [.interim("Open"), .interim("Open Finder"), .final("Open Finder")])
    }

    @Test func plainJSONAnswerToAStreamRequestIsOneFinal() async throws {
        // whisper-1 and some compatible servers ignore stream=true; the Content-Type says which body came back.
        let fake = FakeHTTPTransport([.body(Self.jsonBody)])
        let client = OpenAITranscriptionClient(context: context(fake))
        #expect(client.streamsTranscript)
        let session = try await client.startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [.final("Open the café menu.")])
    }

    @Test func whisperIsNotAskedToStreamAndItsJSONIsRead() async throws {
        let body = #"{"text":"Hello there.","usage":{"type":"duration","seconds":2}}"#
        let fake = FakeHTTPTransport([.body(body)])
        let client = OpenAITranscriptionClient(context: context(fake), model: "whisper-1")
        #expect(!client.streamsTranscript)
        let session = try await client.startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [.final("Hello there.")])
        let request = try #require(fake.requests.first)
        let fields = try formParts(request).filter { $0.fileName == nil }
        #expect(fields.map(\.name) == ["model"])
    }

    // MARK: Request encoding

    @Test func requestIsMultipartWithExactLayout() async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody)])
        let client = OpenAITranscriptionClient(context: context(fake, headers: ["OpenAI-Project": "proj_test"]))
        let session = try await client.startSession(language: "en-US", keywords: ["OpenClicky", "Deepgram"])
        // 11 bytes in uneven pieces: the odd trailing byte is half a sample and must not reach the WAV.
        for piece in [Data([1, 2, 3]), Data([4, 5, 6, 7]), Data([8, 9, 10, 11])] { await session.send(piece) }
        await session.finish()
        _ = try await collect(session)

        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)"
        #expect(authorized)
        #expect(request.value(forHTTPHeaderField: "OpenAI-Project") == "proj_test")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        #expect(contentType.hasPrefix(prefix))
        let boundary = String(contentType.dropFirst(prefix.count))
        #expect(!boundary.isEmpty && boundary.count <= 70)

        var expected = Data()
        func text(_ s: String) { expected.append(contentsOf: Array(s.utf8)) }
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nOpenClicky, Deepgram\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"stream\"\r\n\r\ntrue\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        text("RIFF"); expected.append(contentsOf: [46, 0, 0, 0] as [UInt8])  // 36 + 10 data bytes
        text("WAVEfmt "); expected.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0] as [UInt8])  // PCM, mono
        expected.append(contentsOf: [0x80, 0x3E, 0, 0, 0x00, 0x7D, 0, 0, 2, 0, 16, 0] as [UInt8])  // 16000 Hz, 32000 B/s, align 2, 16 bit
        text("data"); expected.append(contentsOf: [10, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10] as [UInt8])
        text("\r\n--\(boundary)--\r\n")
        #expect(request.httpBody == expected)
    }

    @Test func gptTranscribeSendsKeywordAndLanguageArrays() async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody)])
        let client = OpenAITranscriptionClient(context: context(fake), model: "gpt-transcribe", prompt: "Commands for a Mac assistant.")
        let session = try await client.startSession(language: "fr_CA", keywords: ["OpenClicky", " AC-42 <beta> ", "two\nlines", "openclicky", ""])
        await session.send(Data(count: 320))
        await session.finish()
        _ = try await collect(session)

        let parts = try formParts(try #require(fake.requests.first))
        #expect(parts.map { [$0.name, $0.value] } == [
            ["model", "gpt-transcribe"],
            ["languages[]", "fr"],
            ["prompt", "Commands for a Mac assistant."],
            ["keywords[]", "OpenClicky"],
            ["keywords[]", "AC-42 beta"],
            ["keywords[]", "two lines"],
            ["stream", "true"],
            ["file", parts.last!.value],
        ])
        let file = try #require(parts.last)
        #expect(file.fileName == "audio.wav")
        #expect(file.contentType == "audio/wav")
        #expect(file.data.count == 44 + 320)
    }

    @Test func formFieldsFollowEachModelsDocumentedParameters() {
        let ctx = context(FakeHTTPTransport([]))
        func fields(_ client: OpenAITranscriptionClient, _ language: String?, _ keywords: [String]) -> [[String]] {
            client.formFields(language: language, keywords: keywords).map { [$0.name, $0.value] }
        }
        // Older models: keywords become the prompt's spelling list, after any configured prompt.
        #expect(fields(OpenAITranscriptionClient(context: ctx, prompt: "Mac commands."), "pt-BR", ["Deepgram", "nova-3"]) == [
            ["model", "gpt-4o-mini-transcribe"], ["language", "pt"], ["prompt", "Mac commands.\nDeepgram, nova-3"], ["stream", "true"],
        ])
        #expect(fields(OpenAITranscriptionClient(context: ctx, model: "whisper-1"), nil, ["Deepgram"]) == [
            ["model", "whisper-1"], ["prompt", "Deepgram"],
        ])
        // Diarize takes no prompt and needs chunking_strategy past 30 seconds.
        #expect(fields(OpenAITranscriptionClient(context: ctx, model: "gpt-4o-transcribe-diarize", prompt: "x"), "en", ["Deepgram"]) == [
            ["model", "gpt-4o-transcribe-diarize"], ["language", "en"], ["chunking_strategy", "auto"], ["stream", "true"],
        ])
        #expect(fields(OpenAITranscriptionClient(context: ctx, streaming: false), nil, []) == [["model", "gpt-4o-mini-transcribe"]])
        #expect(fields(OpenAITranscriptionClient(context: ctx, model: "gpt-transcribe-2026-08-26"), "  ", []) == [
            ["model", "gpt-transcribe-2026-08-26"], ["stream", "true"],
        ])
    }

    @Test func inputFormatDefaultsTo16kMonoAndTheWAVHeaderFollowsAnOverride() {
        #expect(OpenAITranscriptionClient(context: context(FakeHTTPTransport([]))).inputFormat == .speech16k)
        let wav = OpenAITranscriptionClient.WAV.wrap(Data(count: 9), format: PCMFormat(sampleRate: 24_000, channels: 2))
        #expect(Array(wav[22..<36]) == [2, 0, 0xC0, 0x5D, 0, 0, 0x00, 0x77, 0x01, 0, 4, 0, 16, 0] as [UInt8])  // 2 ch, 24 kHz, 96000 B/s, align 4
        #expect(Array(wav[40..<44]) == [8, 0, 0, 0])  // 9 bytes trimmed to two whole 4-byte frames
        #expect(wav.count == 52)
    }

    @Test func keylessLocalServerGetsNoAuthorizationHeader() async throws {
        let fake = FakeHTTPTransport([.body(Self.jsonBody)])
        let ctx = context(fake, baseURL: "http://127.0.0.1:8000/v1/", key: nil)
        let session = try await OpenAITranscriptionClient(context: ctx).startSession(language: nil, keywords: [])
        await session.send(Data(count: 320))
        await session.finish()
        _ = try await collect(session)
        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8000/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func missingKeyForOpenAIFailsBeforeRecording() async {
        let client = OpenAITranscriptionClient(context: context(FakeHTTPTransport([]), key: nil))
        await #expect(throws: ProviderError.self) { _ = try await client.startSession(language: nil, keywords: []) }
    }

    @Test func emptyRecordingMakesNoRequest() async throws {
        let fake = FakeHTTPTransport([])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data([7]))  // half a sample is not audio
        await session.finish()
        #expect(try await collect(session) == [])
        #expect(fake.requests.isEmpty)
    }

    // MARK: Errors

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key provided: sk-test***-key. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#,
         "Incorrect API key provided: sk-test***-key. You can find your API key at https://platform.openai.com/account/api-keys."),
        (400, #"{"error":{"message":"Audio file is too short. Minimum audio length is 0.1 seconds.","type":"invalid_request_error","param":"file","code":"audio_too_short"}}"#,
         "Audio file is too short. Minimum audio length is 0.1 seconds."),
        (502, "upstream connect error\n", "upstream connect error"),
    ])
    func httpErrorsSurfaceAsProviderErrors(status: Int, body: String, message: String) async throws {
        let fake = FakeHTTPTransport([.body(body, status: status)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        let error = await #expect(throws: ProviderError.self) { try await collect(session) }
        #expect(error?.status == status)
        #expect(error?.message == message)
        #expect(error?.provider == "openai")
    }

    @Test func errorInsideTheStreamEndsItWithAProviderError() async throws {
        let body = """
            data: {"type":"transcript.text.delta","delta":"Op"}

            data: {"type":"error","error":{"message":"The server had an error while processing your request.","type":"server_error"}}

            """
        let fake = FakeHTTPTransport([.sse(body, chunkSize: 6)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        var seen: [TranscriptEvent] = []
        let error = await #expect(throws: ProviderError.self) { for try await event in session.events { seen.append(event) } }
        #expect(seen == [.interim("Op")])
        #expect(error?.message == "The server had an error while processing your request.")
    }

    // MARK: Cancellation

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheReadingTaskCancelsTheUpload() async throws {
        let transport = StallingTransport(firstChunk: "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hel\"}\n\n")
        let session = try await OpenAITranscriptionClient(context: context(transport)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        let (seen, seenContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        let reader = Task {
            do { for try await event in session.events { seenContinuation.yield(event) } } catch {}
        }
        #expect(await firstValue(seen) == .interim("Hel"))
        reader.cancel()
        #expect(await firstValue(transport.terminations) == .cancelled)
        await reader.value
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionCancelStopsTheUploadAndEndsEvents() async throws {
        let transport = StallingTransport(firstChunk: "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hel\"}\n\n")
        let session = try await OpenAITranscriptionClient(context: context(transport)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        var iterator = session.events.makeAsyncIterator()
        #expect(try await iterator.next() == .interim("Hel"))
        await session.cancel()
        #expect(try await iterator.next() == nil)
        #expect(await firstValue(transport.terminations) == .cancelled)
    }

    @Test func cancelBeforeFinishNeverUploads() async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.cancel()
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [])
        #expect(fake.requests.isEmpty)
    }

    @Test func readerThatLeftBeforeFinishMeansNoUpload() async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        let reader = Task { for try await _ in session.events {} }
        reader.cancel()
        _ = await reader.result
        await session.finish()
        #expect(fake.requests.isEmpty)
    }

    // MARK: Adversarial (review)

    /// Variants the adapter claims to tolerate, one byte at a time: CRLF line endings, a keep-alive comment, an SSE
    /// `event:` name standing in for a missing `type`, an event that has both, and a trailing `[DONE]` line.
    @Test func sseVariantsSurviveOneByteChunks() async throws {
        let body = [
            ": keep-alive",
            "",
            "event: transcript.text.delta",
            #"data: {"delta":"Ouvre "}"#,
            "",
            "event: transcript.text.delta",
            #"data: {"type":"transcript.text.delta","delta":"le café"}"#,
            "",
            #"data: {"type":"transcript.text.done","text":"Ouvre le café.","languages":[{"code":"fr"}],"usage":{"type":"tokens","input_tokens":14,"output_tokens":31,"total_tokens":45}}"#,
            "",
            "data: [DONE]",
            "",
            "",
        ].joined(separator: "\r\n")
        let fake = FakeHTTPTransport([.sse(body, chunkSize: 1)])
        let session = try await OpenAITranscriptionClient(context: context(fake), model: "gpt-transcribe")
            .startSession(language: "fr", keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        #expect(try await collect(session) == [.interim("Ouvre "), .interim("Ouvre le café"), .final("Ouvre le café.")])
    }

    @Test func jsonAndErrorBodiesSurviveOneByteChunks() async throws {
        func oneByte(_ text: String, status: Int) -> FakeHTTPTransport.Scripted {
            FakeHTTPTransport.Scripted(status: status, headers: ["Content-Type": "application/json; charset=utf-8"],
                                       chunks: Data(text.utf8).map { Data([$0]) })
        }
        let error = #"{"error":{"message":"Rate limit reached for gpt-4o-mini-transcribe — café.","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#
        let fake = FakeHTTPTransport([oneByte(Self.jsonBody, status: 200), oneByte(error, status: 429)])
        let client = OpenAITranscriptionClient(context: context(fake))

        let first = try await client.startSession(language: nil, keywords: [])
        await first.send(Data(count: 640))
        await first.finish()
        #expect(try await collect(first) == [.final("Open the café menu.")])

        let second = try await client.startSession(language: nil, keywords: [])
        await second.send(Data(count: 640))
        await second.finish()
        let thrown = await #expect(throws: ProviderError.self) { try await collect(second) }
        #expect(thrown?.status == 429)
        #expect(thrown?.message == "Rate limit reached for gpt-4o-mini-transcribe — café.")
    }

    /// A proxy that sends a 503 status and then drops the connection must still surface as HTTP 503.
    @Test func errorStatusSurvivesABodyThatBreaks() async throws {
        let transport = ClosureTransport { request in
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.yield(Data(#"{"error":{"mess"#.utf8))
            continuation.finish(throwing: URLError(.networkConnectionLost))
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "application/json"])!)
        }
        let session = try await OpenAITranscriptionClient(context: context(transport)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        let thrown = await #expect(throws: ProviderError.self) { try await collect(session) }
        #expect(thrown?.status == 503)
    }

    /// A connection lost mid-stream is an error, not a truncated transcript passed off as final.
    @Test func connectionLostMidStreamIsAnErrorNotAFinal() async throws {
        let transport = ClosureTransport { request in
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            continuation.yield(Data("data: {\"type\":\"transcript.text.delta\",\"delta\":\"Open\"}\n\n".utf8))
            continuation.finish(throwing: URLError(.networkConnectionLost))
            return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "text/event-stream; charset=utf-8"])!)
        }
        let session = try await OpenAITranscriptionClient(context: context(transport)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        var seen: [TranscriptEvent] = []
        await #expect(throws: URLError.self) { for try await event in session.events { seen.append(event) } }
        #expect(seen == [.interim("Open")])
    }

    @Test func recordingOverTheUploadLimitFailsWithoutARequest() async throws {
        let fake = FakeHTTPTransport([.body(Self.jsonBody)])
        let session = try await OpenAITranscriptionClient(context: context(fake)).startSession(language: nil, keywords: [])
        await session.send(Data(count: OpenAITranscriptionClient.maxUploadBytes))
        await session.finish()
        let thrown = await #expect(throws: ProviderError.self) { try await collect(session) }
        #expect(thrown?.message.contains("25 MB") == true)
        #expect(fake.requests.isEmpty)
    }

    /// The common case for a long utterance: the reader leaves while the upload is still waiting for response
    /// headers. The cancellation has to reach the transport call itself, not only a body stream.
    @Test(.timeLimit(.minutes(1)))
    func cancellingWhileWaitingForResponseHeadersCancelsTheRequest() async throws {
        let transport = HangingTransport()
        let session = try await OpenAITranscriptionClient(context: context(transport)).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        let reader = Task { do { for try await _ in session.events {} } catch {} }
        #expect(await firstValue(transport.started) != nil)
        reader.cancel()
        #expect(await firstValue(transport.cancelled) != nil)
        await reader.value
    }

    /// If the upload task is cancelled before it sends (the reader left during finish()), no request goes out.
    @Test func uploadCancelledBeforeSendingMakesNoRequest() async throws {
        let fake = FakeHTTPTransport([.sse(Self.streamedBody)])
        let upload = OpenAITranscriptionUpload(
            providerID: "openai", http: fake, url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            extraHeaders: [:], apiKey: Self.fakeKey, fields: [.init("model", "gpt-4o-mini-transcribe")],
            format: .speech16k, streaming: true)
        let (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await upload.run(pcm: Data(count: 640), into: continuation)
        }.value
        var seen: [TranscriptEvent] = []
        for try await event in events { seen.append(event) }
        #expect(seen.isEmpty)
        #expect(fake.requests.isEmpty)
    }

    @Test func requestTimeoutMatchesTheSharedProviderRequests() async throws {
        let fake = FakeHTTPTransport([.body(Self.jsonBody)])
        let ctx = context(fake)
        let session = try await OpenAITranscriptionClient(context: ctx).startSession(language: nil, keywords: [])
        await session.send(Data(count: 640))
        await session.finish()
        _ = try await collect(session)
        let request = try #require(fake.requests.first)
        // Whisper and unstreamed answers say nothing until the whole file is transcribed; don't give up sooner
        // than every other provider request does.
        #expect(request.timeoutInterval == ctx.jsonRequest(request.url!, body: .null).timeoutInterval)
    }

    // MARK: Helpers

    private func context(_ http: any HTTPTransport, baseURL: String? = "https://api.openai.com/v1", key: String? = fakeKey,
                         headers: [String: String]? = nil) -> ProviderContext {
        ProviderContext(
            provider: ProviderConfig(id: "openai", dialect: .openAITranscription, baseURL: baseURL.flatMap { URL(string: $0) },
                                     credential: "openai", headers: headers),
            apiKey: key, http: http, webSocket: FakeWebSocket())
    }

    private func collect(_ session: any SpeechToTextSession) async throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        for try await event in session.events { events.append(event) }
        return events
    }

    /// The first value a stream yields, or nil after ten seconds (a hang guard; a busy machine can be slow).
    private func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    struct FormPart {
        var name: String
        var fileName: String?
        var contentType: String?
        var data: Data
        var value: String { String(decoding: data, as: UTF8.self) }
    }

    /// An independent multipart/form-data reader, so field assertions don't trust the encoder under test.
    private func formParts(_ request: URLRequest) throws -> [FormPart] {
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let body = try #require(request.httpBody)
        let crlf = Data("\r\n".utf8)
        let separator = Data("\r\n--\(boundary)".utf8)
        try #require(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        try #require(body.suffix(boundary.count + 8) == Data("\r\n--\(boundary)--\r\n".utf8))
        var rest = body.dropFirst(boundary.count + 2)
        var parts: [FormPart] = []
        while rest.starts(with: crlf) {
            rest = rest.dropFirst(2)
            let end = try #require(rest.range(of: separator))
            let part = rest[rest.startIndex..<end.lowerBound]
            let split = try #require(part.range(of: Data("\r\n\r\n".utf8)))
            let headers = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let disposition = try #require(headers.first { $0.hasPrefix("Content-Disposition: form-data; ") })
            func attribute(_ key: String) -> String? {
                guard let range = disposition.range(of: "\(key)=\"") else { return nil }
                return String(disposition[range.upperBound...].prefix { $0 != "\"" })
            }
            parts.append(FormPart(
                name: try #require(attribute("name")), fileName: attribute("filename"),
                contentType: headers.first { $0.hasPrefix("Content-Type: ") }.map { String($0.dropFirst(14)) },
                data: Data(part[split.upperBound...])))
            rest = rest[end.upperBound...]
        }
        try #require(rest == Data("--\r\n".utf8))
        return parts
    }
}

/// Builds each response with a closure, for bodies FakeHTTPTransport can't script (a body that fails part-way).
private struct ClosureTransport: HTTPTransport {
    let respond: @Sendable (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)

    init(_ respond: @escaping @Sendable (URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)) {
        self.respond = respond
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await respond(request)
    }
}

/// Never answers: `stream(for:)` waits for response headers that don't come, as URLSession does during a long
/// upload. Reports when the request started and when its task was cancelled.
private final class HangingTransport: HTTPTransport, @unchecked Sendable {
    let started: AsyncStream<Void>
    let cancelled: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let cancelledContinuation: AsyncStream<Void>.Continuation

    init() {
        (started, startedContinuation) = AsyncStream<Void>.makeStream()
        (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        startedContinuation.yield(())
        let report = cancelledContinuation
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(3600))
            throw URLError(.timedOut)
        } onCancel: {
            report.yield(())
        }
    }
}

/// Answers with one SSE chunk and then never finishes, like a slow model. Reports how each response body ended.
private final class StallingTransport: HTTPTransport, @unchecked Sendable {
    enum Ending: Sendable, Equatable { case cancelled, finished }

    let terminations: AsyncStream<Ending>
    private let terminationsContinuation: AsyncStream<Ending>.Continuation
    private let firstChunk: Data
    private let lock = NSLock()
    private var open: [AsyncThrowingStream<Data, Error>.Continuation] = []

    init(firstChunk: String) {
        self.firstChunk = Data(firstChunk.utf8)
        (terminations, terminationsContinuation) = AsyncStream<Ending>.makeStream()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let report = terminationsContinuation
        continuation.onTermination = { termination in
            if case .cancelled = termination { report.yield(.cancelled) } else { report.yield(.finished) }
        }
        continuation.yield(firstChunk)
        lock.withLock { open.append(continuation) }  // keep it open until cancelled
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        return (stream, response)
    }
}
