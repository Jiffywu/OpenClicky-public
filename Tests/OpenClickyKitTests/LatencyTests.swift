import Foundation
import Testing
@testable import OpenClickyKit

/// The latency work around a voice turn: thinking that doesn't hold the answer back, the prewarm matching the turn,
/// the voice's connection opened at key-down, the ears in the turn loop (with the screenshots taken at key-up),
/// Gemini's batch transcription and warm-socket readiness, and the brain latency probe. No network.
@Suite(.timeLimit(.minutes(1)))
struct LatencyTests {
    // MARK: Thinking

    @Test func thinkingModesMapToAnthropicsThinkingSettings() throws {
        let client = AnthropicMessagesTests.client(FakeHTTPTransport([]))
        func thinking(_ mode: ThinkingMode?, effort: String? = "low") -> (JSONValue?, JSONValue?) {
            let body = client.requestBody(ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))], reasoningEffort: effort, thinking: mode))
            return (body["thinking"], body["output_config"])
        }
        #expect(thinking(.hidden) == (["type": "adaptive", "display": "omitted"], ["effort": "low"]))
        #expect(thinking(.summarized) == (["type": "adaptive", "display": "summarized"], ["effort": "low"]))
        #expect(thinking(.off) == (["type": "disabled"], ["effort": "low"]))
        #expect(thinking(.off, effort: nil) == (["type": "disabled"], nil))
        #expect(thinking(.hidden, effort: nil) == (["type": "adaptive", "display": "omitted"], nil))
        // No mode: the effort brings adaptive thinking with the client's display (summarized by default), as before.
        #expect(thinking(nil) == (["type": "adaptive", "display": "summarized"], ["effort": "low"]))
        #expect(thinking(nil, effort: nil) == (nil, nil))
    }

    @Test func voiceTurnsOnAnthropicThinkWithoutStreamingTheSummary() throws {
        let anthropic = EngineResolution(slot: .brain, sourceSlot: .brain, selection: SlotSelection(provider: "a", model: "claude-haiku-5-5"),
                                         provider: ProviderConfig(id: "a", dialect: .anthropicMessages), adapter: nil, errors: [])
        #expect(BrainRuntime.defaultThinking(resolution: anthropic) == .hidden)
        var openAI = anthropic
        openAI.provider = ProviderConfig(id: "o", dialect: .openAIResponses)
        #expect(BrainRuntime.defaultThinking(resolution: openAI) == nil)
    }

    @Test func thePrewarmSendsTheSameThinkingAsTheTurnSoItWritesTheCacheTheTurnReads() async throws {
        let model = BrainScriptModel([
            [.text("ok"), .finish(.length)],
            [.text(BrainFixtures.program("say(\"One.\")")), .finish(.stop)],
        ])
        let runtime = BrainFixtures.runtime(model) {
            $0.reasoningEffort = "low"
            $0.thinking = .hidden
        }
        await runtime.prewarm()
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("hello"))
        let requests = model.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.thinking == .hidden && $0.reasoningEffort == "low" })
        #expect(requests[0].maxOutputTokens == 1)
        let preview = await runtime.previewRequest(for: BrainFixtures.input("again"))
        #expect(preview.thinking == .hidden && preview.messages.count == requests[1].messages.count + 2)
    }

    @Test func anthropicUsageReportsCacheWrites() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","usage":{"input_tokens":20,"cache_creation_input_tokens":1200,"cache_read_input_tokens":13000,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let client = AnthropicMessagesTests.client(FakeHTTPTransport([.sse(sse)]))
        let events = try await AnthropicMessagesTests.collect(client, ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))]))
        let usage = try #require(events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }.first)
        #expect(usage == TokenUsage(inputTokens: 14_220, cachedInputTokens: 13_000, outputTokens: 3, cacheWriteTokens: 1_200))
    }

    @Test func turnTimingsReportTheBrainsTokensAndWhetherTheCacheWasHit() {
        var timings = TurnTimings(kind: .voice)
        timings.usage = TokenUsage(inputTokens: 14_739, cachedInputTokens: 13_279, outputTokens: 238, cacheWriteTokens: 1_456)
        #expect(timings.report().contains("tokens: in 14739 (cache hit: 13279 read, 1456 written), out 238"))
        #expect(timings.json["usage"]?["cache_write"] == 1456)
        timings.usage = TokenUsage(inputTokens: 100, outputTokens: 5)
        #expect(timings.report().contains("cache miss"))
    }

    // MARK: The voice's connection

    @Test func elevenLabsWarmUpOpensTheConnectionOncePerIntervalWithoutTheKey() async throws {
        let fake = FakeHTTPTransport([.body("", status: 404), .body("", status: 404)])
        let client = ElevenLabsSpeechClient(context: ElevenLabsSpeechTests.context(fake, baseURL: "https://api.elevenlabs.io/v1"))
        await client.warmUp()
        await client.warmUp()
        #expect(fake.requests.count == 1)
        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "HEAD")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == nil)
    }

    // MARK: Gemini batch transcription

    static func geminiContext(_ http: FakeHTTPTransport, baseURL: String? = "https://generativelanguage.googleapis.com/v1beta") -> ProviderContext {
        ProviderContext(provider: ProviderConfig(id: "gemini-live", dialect: .geminiLive, baseURL: baseURL.flatMap(URL.init(string:)), credential: "gemini"),
                        apiKey: "AIza-test-not-real", http: http)
    }

    @Test func geminiBatchSendsThePressAsAWAVWithItsHintsAndReadsTheTranscript() async throws {
        let reply = """
        {"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"What does the say hello button do?"}]}],"object":"interaction","model":"gemini-3.5-transcribe"}
        """
        let fake = FakeHTTPTransport([.body(reply)])
        let client = GeminiTranscriptionClient(context: Self.geminiContext(fake), model: GeminiTranscriptionClient.batchModel(forLive: "gemini-3.5-transcribe-live"))
        let audio = DecodedAudio(pcm: Data(count: 32_000), format: .speech16k)
        let text = try await client.transcribe(audio, language: "en-US", keywords: ["OpenClicky", " OpenClicky ", ""])
        #expect(text == "What does the say hello button do?")
        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test-not-real")
        #expect(request.url?.query == nil)  // the key never goes in the URL
        let body = try fake.jsonBody()
        #expect(body["model"] == "gemini-3.5-transcribe")
        #expect(body["store"] == false)
        #expect(body["generation_config"] == ["transcription_config": ["language_codes": ["en-US"], "custom_vocabulary": ["OpenClicky"]]])
        let input = try #require(body["input"]?.arrayValue?.first)
        #expect(input["type"] == "audio" && input["mime_type"] == "audio/wav")
        let wav = try #require(input["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        let decoded = try WAVDecoder.decode(wav)
        #expect(decoded.format == .speech16k && decoded.pcm.count == 32_000)
        #expect(!String(describing: client).contains("AIza"))
    }

    @Test func geminiBatchErrorsKeepTheStatusSoARefusalSwitches() async throws {
        let refusal = #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED"}}"#
        let fake = FakeHTTPTransport([.body(refusal, status: 429)])
        let client = GeminiTranscriptionClient(context: Self.geminiContext(fake, baseURL: GeminiLiveSpeechToTextClient.defaultEndpoint))
        do {
            _ = try await client.transcribe(DecodedAudio(pcm: Data(count: 640), format: .speech16k), language: nil, keywords: [])
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 429)
            #expect(error.message.contains("RESOURCE_EXHAUSTED"))
            #expect(SpeechRefusal.isAccountRefusal(error))
        }
        // A WebSocket base for the Live API still reaches the unary API over HTTPS.
        #expect(fake.requests.first?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(fake.requests.first.map { (try? JSONValue.parse(String(decoding: $0.httpBody ?? Data(), as: UTF8.self)))?["generation_config"] } == .some(nil))
        #expect(GeminiTranscriptionClient.batchModel(forLive: "gemini-3.8-live") == "gemini-3.5-transcribe")
        #expect(GeminiTranscriptionClient.transcript(in: ["steps": [["type": "user_input"], ["type": "model_output", "content": [["type": "text", "text": "a"], ["type": "text", "text": "b"]]]]]) == "a b")
    }

    @Test func aWarmGeminiSocketReportsReadinessAndThatThePressFoundItWarm() async throws {
        let factory = GeminiLiveSpeechToTextTests.SocketFactory()
        let client = GeminiLiveSpeechToTextTests.client(factory)
        #expect(!(await client.waitUntilWarm(language: nil, keywords: [])))
        await client.warmUp(language: "en-US", keywords: [])
        #expect(await client.waitUntilWarm(language: "en-US", keywords: []))
        let session = try await client.startSession(language: "en-US", keywords: [])
        let ready = try #require(session as? any SpeechToTextSessionReadiness)
        #expect(await ready.startedWarm)
        #expect(await ready.waitUntilReady())
        await session.cancel()

        let cold = try await client.startSession(language: "fr-FR", keywords: [])
        let coldReady = try #require(cold as? any SpeechToTextSessionReadiness)
        #expect(!(await coldReady.startedWarm))
        #expect(await coldReady.waitUntilReady())
        await cold.cancel()

        let silent = GeminiLiveSpeechToTextTests.client(GeminiLiveSpeechToTextTests.SocketFactory(autoSetup: false))
        let never = try await silent.startSession(language: nil, keywords: [])
        let waiter = Task { await (never as? any SpeechToTextSessionReadiness)?.waitUntilReady() }
        try await Task.sleep(for: .milliseconds(20))
        await never.cancel()
        #expect(await waiter.value == false)
    }

    // MARK: The ears in the turn loop

    @MainActor
    @Test func aVoiceTurnThroughTheEarsCarriesTheirReportAndCapturesAtKeyUp() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["It opens the menu."])])
        let ears = VoiceEars(primary: .init(name: "scripted stt", client: SimulatedSpeechToText(text: "what does this do", chunksPerWord: 1)))
        rig.orchestrator.services.speechToText = { ears }
        rig.orchestrator.settings.transcriptTimeout = 10  // a loaded machine can be slow to hand the audio over
        await rig.ask(holding: 0.15)
        #expect(await rig.waitForRecords(1))
        let record = try #require(rig.records.first)
        #expect(record.words == "what does this do")
        let report = try #require(record.timings.ears)
        #expect(report.outcome == .streamed && report.recognizer == "scripted stt")
        let captureStarted = try #require(record.timings.captureStartedAt)
        let transcript = try #require(record.timings.transcriptAt)
        let released = try #require(record.timings.releasedAt)
        #expect(captureStarted >= released && captureStarted <= transcript)  // the screenshots overlap the last words
        #expect(record.timings.releaseToWordsMs != nil)
        #expect(record.timings.report().contains("ears: warm=no outcome=streamed"))
        #expect(record.timings.json["ears"]?["outcome"] == "streamed")
        #expect(rig.screen.looks == 1)
    }

    @MainActor
    @Test func aVoiceTurnWhoseStreamFailsIsAnsweredFromTheFallback() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Sure."])])
        let ears = VoiceEars(primary: .init(name: "down", client: SimulatedSpeechToText(text: "", behavior: .failToStart("socket refused"))),
                             fallbacks: [.init(name: "batch", client: VoiceEarsTests.FakeBatch(.success("open my calendar")), sharesPrimaryAccount: true)])
        rig.orchestrator.services.speechToText = { ears }
        rig.orchestrator.settings.transcriptTimeout = 10  // a loaded machine can be slow to hand the audio over
        // Half a second of audio at once, so the kept press is long enough for a fallback however busy the machine is.
        rig.orchestrator.services.microphone = AudioFileMicrophone(pcm: Data(count: 16_000), format: .speech16k, realTime: false)
        await rig.ask(holding: 0.3)
        #expect(await rig.waitForRecords(1))
        let record = try #require(rig.records.first)
        #expect(record.words == "open my calendar")
        #expect(record.outcome == .completed, "\(record.outcome) \(String(describing: record.notice)) \(record.timings.ears.map { $0.logLine() } ?? "no ears") \(rig.trace.all)")
        #expect(record.timings.ears?.outcome == .fallback)
        #expect(rig.brain.inputs.first?.words == "open my calendar")
    }

    @MainActor
    @Test func nothingHeardThroughTheEarsSaysSoAndReportsSilence() async throws {
        let rig = VoiceLoopRig(scripts: [ScriptedBrain.program(["Never."])])
        let ears = VoiceEars(primary: .init(name: "quiet", client: SimulatedSpeechToText(text: "")))
        rig.orchestrator.services.speechToText = { ears }
        rig.orchestrator.settings.transcriptTimeout = 10  // a loaded machine can be slow to hand the audio over
        await rig.ask(holding: 0.15)
        #expect(await rig.waitForRecords(1))
        let record = try #require(rig.records.first)
        #expect(record.notice == .nothingHeard)
        #expect(record.timings.ears?.outcome == .silent)
        #expect(rig.brain.inputs.isEmpty)
    }

    @MainActor
    @Test func aRecordingPlaysThroughTheFileMicrophoneThenSilence() async throws {
        let pcm = Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0) })
        let microphone = AudioFileMicrophone(pcm: pcm, format: .speech16k, chunkDuration: 0.01, realTime: false)
        #expect(abs(microphone.duration - 0.1) < 0.001)
        let stream = try microphone.start(format: .speech16k)
        var received = Data()
        for await chunk in stream {
            received.append(chunk)
            if received.count >= pcm.count + 640 { break }
        }
        #expect(received.prefix(pcm.count) == pcm)
        #expect(received.dropFirst(pcm.count).allSatisfy { $0 == 0 })
        microphone.stop()
        #expect(microphone.starts == 1)
        // Another format is converted (8 kHz: half the bytes).
        let converted = try microphone.start(format: PCMFormat(sampleRate: 8_000))
        var first = Data()
        for await chunk in converted {
            first.append(chunk)
            if first.count >= 1_600 { break }
        }
        microphone.stop()
        #expect(first.count >= 1_600)
    }

    // MARK: The probe

    final class ThinkingModel: LanguageModelClient, @unchecked Sendable {
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.reasoningDelta("Point at the button."))
                    try? await Task.sleep(for: .milliseconds(20))
                    continuation.yield(.textDelta("```js\nstep(1)\nsay(\"It saves "))
                    continuation.yield(.textDelta("the file.\")\npoint(10, 20)\n```"))
                    continuation.yield(.usage(TokenUsage(inputTokens: 100, cachedInputTokens: 90, outputTokens: 12, cacheWriteTokens: 5)))
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                }
            }
        }
    }

    @Test func theProbeTimesThinkingTheFirstCodeAndTheFirstLine() async throws {
        let timing = await BrainLatencyProbe.time(ChatRequest(model: "m", messages: [.user(.text("hi"))]), on: ThinkingModel(), label: "1")
        #expect(timing.error == nil)
        #expect(timing.thinkingStartMs != nil && timing.thinkingEndMs != nil && timing.thinkingCharacters == 20)
        let code = try #require(timing.firstCodeMs), line = try #require(timing.firstLineMs)
        #expect(code <= line)
        #expect(timing.lines == ["It saves the file."])
        #expect(timing.program.contains("point(10, 20)") && !timing.program.contains("```"))
        #expect(timing.usage?.cacheWriteTokens == 5)
        #expect(timing.json["usage"]?["cache_write"] == 5)
    }

    /// Anthropic's stream for an answer after a thinking block whose text was omitted.
    static let omittedThinkingStream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":500,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"```js\\nsay(\\"Hi.\\")\\n```"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    @Test func theProbeSeesAnOmittedThinkingBlockInAnthropicsStream() async throws {
        let sse = Self.omittedThinkingStream
        let client = AnthropicMessagesTests.client(FakeHTTPTransport([.sse(sse)]))
        let timing = await BrainLatencyProbe.time(ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))], thinking: .hidden),
                                                  on: client, label: "raw")
        #expect(timing.error == nil)
        #expect(timing.headersMs != nil && timing.firstEventMs != nil)
        #expect(timing.thinkingStartMs != nil && timing.thinkingEndMs != nil && timing.thinkingCharacters == 0)
        #expect(timing.lines == ["Hi."])
        #expect(timing.usage?.cachedInputTokens == 500 && timing.usage?.outputTokens == 40)
    }

    /// Review fix: occtl meters every engine, so the brain arrived inside the usage meter and the probe never took its
    /// Anthropic path (no response head, no hidden thinking) and `--sizes` always refused.
    @Test func theProbeReadsAnthropicsRawStreamThroughTheUsageMeter() async throws {
        let resilience = ProviderResilience(recorder: UsageCollector(), sleep: RecordedSleeps().sleep)
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "test-not-a-key"]),
                                    http: FakeHTTPTransport([.sse(Self.omittedThinkingStream)]), resilience: resilience)
        let client = try factory.languageModel(for: .brain)
        #expect(!(client is AnthropicMessagesClient))
        let timing = await BrainLatencyProbe.time(ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))], thinking: .hidden),
                                                  on: client, label: "metered")
        #expect(timing.error == nil)
        #expect(timing.headersMs != nil)
        #expect(timing.thinkingStartMs != nil && timing.thinkingEndMs != nil)
        #expect(timing.lines == ["Hi."])
    }

    @Test func tokenCountingUsesTheFreeEndpointWithoutOutputSettings() async throws {
        let fake = FakeHTTPTransport([.body(#"{"input_tokens": 1234}"#)])
        let client = AnthropicMessagesTests.client(fake)
        let tokens = try await BrainLatencyProbe.countTokens(
            ChatRequest(model: "claude-haiku-5-5", messages: [.system("Be brief."), .user(.text("hi"))], reasoningEffort: "low",
                        maxOutputTokens: 100, promptCache: .conversation, thinking: .hidden), on: client)
        #expect(tokens == 1234)
        let request = try #require(fake.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages/count_tokens")
        let body = try fake.jsonBody()
        #expect(body["stream"] == nil && body["max_tokens"] == nil && body["thinking"] == nil && body["output_config"] == nil)
        #expect(body["cache_control"] == nil && body["system"] == "Be brief.")
    }

    @Test func systemPromptSectionsJoinIntoTheSystemPrompt() throws {
        let assembler = try BrainPromptAssembler()
        let options = BrainPromptOptions(toolGroups: [.lookups, .memory])
        let sections = assembler.systemSections(options)
        #expect(sections.map(\.text).joined(separator: "\n\n") == assembler.systemPrompt(options))
        #expect(sections.map(\.name).prefix(5) == ["persona", "answering", "pointing", "explaining", "draw-2d"])
        #expect(sections.contains { $0.name == "draw-3d" })
        #expect(assembler.systemSections(BrainPromptOptions(figuresAvailable: false)).contains { $0.name == "no-figures" })
    }
}
