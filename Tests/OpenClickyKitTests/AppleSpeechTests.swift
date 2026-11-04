import AVFAudio
import Foundation
import Speech
import Testing
@testable import OpenClickyKit

// The real recognizers never run in these tests. SFSpeechRecognizer needs user authorization (a TCC prompt) and an
// app bundle with NSSpeechRecognitionUsageDescription. SpeechAnalyzer needs no prompt, but starting it reserves a
// language for this process and may download its model. These tests cover everything around the engines through
// internal seams: PCM16 → AVAudioPCMBuffer assembly, format conversion, result mapping, request configuration,
// engine choice and authorization, and the session's streaming / error / cancellation / lifetime behaviour against
// a scripted engine.

@Suite struct AppleSpeechTests {

    // MARK: PCM16 → AVAudioPCMBuffer

    @Test func assemblerKeepsSamplesAcrossAwkwardChunks() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 258, -2, 12345, -12345]
        let bytes = littleEndianBytes(samples)
        var assembler = try #require(PCM16BufferAssembler(format: .speech16k))
        var collected: [Int16] = []
        var offset = 0
        // Splits land mid-sample (odd byte counts) and include a 1-byte chunk that completes nothing on its own.
        for size in [3, 1, 5, 1, 2, 4, 2] {
            let chunk = bytes[offset..<min(offset + size, bytes.count)]
            offset += size
            if let buffer = assembler.append(Data(chunk)) {
                #expect(buffer.format.commonFormat == .pcmFormatInt16)
                #expect(buffer.format.sampleRate == 16_000)
                #expect(buffer.format.channelCount == 1)
                collected += int16Samples(buffer)
            }
            #expect(assembler.pendingByteCount == offset % 2)
        }
        #expect(offset == bytes.count)
        #expect(collected == samples)
    }

    @Test func assemblerReturnsNothingUntilAWholeSample() throws {
        var assembler = try #require(PCM16BufferAssembler(format: .speech16k))
        #expect(assembler.append(Data([0x34])) == nil)
        let bufferMaybe = assembler.append(Data([0x12]))
        let buffer = try #require(bufferMaybe)
        #expect(int16Samples(buffer) == [0x1234])
        // A dangling byte at the end of the stream is dropped, not glued onto the next session's audio.
        #expect(assembler.append(Data([0x01])) == nil)
        assembler.reset()
        #expect(assembler.pendingByteCount == 0)
    }

    @Test func assemblerCarriesPartialStereoFrames() throws {
        // Interleaved L/R frames: (100, -100), (200, -200), (300, -300).
        let samples: [Int16] = [100, -100, 200, -200, 300, -300]
        let bytes = littleEndianBytes(samples)
        var assembler = try #require(PCM16BufferAssembler(format: PCMFormat(sampleRate: 24_000, channels: 2)))
        let firstMaybe = assembler.append(bytes.prefix(6))  // one frame + half of the next
        let first = try #require(firstMaybe)
        #expect(first.frameLength == 1)
        #expect(first.format.channelCount == 2)
        #expect(first.format.isInterleaved)
        #expect(assembler.pendingByteCount == 2)
        let secondMaybe = assembler.append(bytes.dropFirst(6))
        let second = try #require(secondMaybe)
        #expect(second.frameLength == 2)
        #expect(int16Samples(first) + int16Samples(second) == samples)
    }

    @Test func assemblerRejectsUnusableFormats() {
        #expect(PCM16BufferAssembler(format: PCMFormat(sampleRate: 0)) == nil)
        #expect(PCM16BufferAssembler(format: PCMFormat(sampleRate: 16_000, channels: 0)) == nil)
    }

    // MARK: Format conversion

    @Test func converterTurnsInt16IntoFloat() throws {
        var assembler = try #require(PCM16BufferAssembler(format: .speech16k))
        let inputMaybe = assembler.append(littleEndianBytes([0, 16384, -16384, -32768]))
        let input = try #require(inputMaybe)
        let float = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(PCMBufferConverter(from: assembler.audioFormat, to: float))
        let output = try converter.convert(input) + converter.flush()
        let values = output.flatMap(floatSamples)
        #expect(values.count == 4)
        #expect(values == [0, 0.5, -0.5, -1])
    }

    @Test func converterResamplesAChunkedStreamWithoutLosingAudio() throws {
        var assembler = try #require(PCM16BufferAssembler(format: .speech16k))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                                interleaved: false))
        let converter = try #require(PCMBufferConverter(from: assembler.audioFormat, to: target))
        // 100 ms of a 440 Hz tone, delivered as 10 ms chunks.
        let tone = (0..<1_600).map { Int16(8_000 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        var frames: AVAudioFrameCount = 0
        for chunk in stride(from: 0, to: tone.count, by: 160) {
            let bufferMaybe = assembler.append(littleEndianBytes(Array(tone[chunk..<chunk + 160])))
            let buffer = try #require(bufferMaybe)
            for out in try converter.convert(buffer) {
                #expect(out.format.sampleRate == 48_000)
                frames += out.frameLength
            }
        }
        for out in try converter.flush() { frames += out.frameLength }
        // 3× the input, give or take the resampler's edge handling.
        #expect(abs(Int(frames) - 4_800) <= 48)
    }

    // MARK: Result mapping

    @Test func resultsMapToInterimAndFinal() {
        #expect(AppleSpeechTranscript.event(text: "turn the", isFinal: false) == .interim("turn the"))
        #expect(AppleSpeechTranscript.event(text: "Turn the lights on.", isFinal: true) == .final("Turn the lights on."))
        // An empty volatile SpeechTranscriber result revokes the previous one for that range: clear the interim.
        #expect(AppleSpeechTranscript.event(text: "", isFinal: false) == .interim(""))
        // Empty finals add nothing to the transcript.
        #expect(AppleSpeechTranscript.event(text: "", isFinal: true) == nil)
        #expect(AppleSpeechTranscript.event(text: "  ", isFinal: true) == nil)
        // Spacing is the engine's: consecutive finals concatenate as delivered.
        #expect(AppleSpeechTranscript.event(text: " And dim them.", isFinal: true) == .final(" And dim them."))
    }

    // MARK: Session against a scripted engine

    @Test(.timeLimit(.minutes(1)))
    func sessionStreamsInterimsThenFinalsAndEnds() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        #expect(backend.started)
        let consumer = Task { try await collect(session.events) }

        let samples: [Int16] = [10, -20, 30, -40, 50]
        let bytes = littleEndianBytes(samples)
        await session.send(bytes.prefix(3))           // 1 sample + 1 byte
        await session.send(bytes.dropFirst(3).prefix(4))  // completes sample 2, adds sample 3, half of 4
        await session.send(bytes.dropFirst(7))        // rest
        await session.send(Data([0x7F]))              // a dangling byte that finish() must drop

        // Partial results as SFSpeechRecognizer delivers them: each carries the whole transcription so far.
        backend.emit(.result(text: "what's", isFinal: false))
        backend.emit(.result(text: "what's the weather", isFinal: false))
        await session.finish()
        #expect(backend.endAudioCount == 1)
        backend.emit(.result(text: "What's the weather?", isFinal: true))
        backend.emit(.finished)

        let events = try await consumer.value
        #expect(events == [.interim("what's"), .interim("what's the weather"), .final("What's the weather?")])
        #expect(backend.int16 == samples)
        #expect(backend.cancelCount == 0)
        // After finish(), audio is no longer forwarded.
        await session.send(littleEndianBytes([1, 2]))
        #expect(backend.int16 == samples)
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionHandlesPhraseByPhraseResults() async throws {
        // SpeechTranscriber style: volatile results per phrase, each phrase finalised once, an empty volatile result
        // revoking the previous guess.
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        let consumer = Task { try await collect(session.events) }
        backend.emit(.result(text: "Open", isFinal: false))
        backend.emit(.result(text: "Open Safari.", isFinal: true))
        backend.emit(.result(text: " Then", isFinal: false))
        backend.emit(.result(text: "", isFinal: false))
        backend.emit(.result(text: " Then search.", isFinal: true))
        await session.finish()
        backend.emit(.finished)
        let events = try await consumer.value
        #expect(events == [.interim("Open"), .final("Open Safari."), .interim(" Then"), .interim(""),
                           .final(" Then search.")])
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionConvertsAudioToTheEngineFormat() async throws {
        let float = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let backend = ScriptedSpeechBackend(format: float)
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        await session.send(littleEndianBytes([16384, -16384, 0]))
        await session.finish()
        #expect(backend.formats.allSatisfy { $0.commonFormat == .pcmFormatFloat32 && $0.sampleRate == 16_000 })
        #expect(backend.float == [0.5, -0.5, 0])
        await session.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func engineErrorsSurfaceAsProviderErrors() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        let consumer = Task { try await collect(session.events) }
        backend.emit(.result(text: "hel", isFinal: false))
        let failure = NSError(domain: "kAFAssistantErrorDomain", code: 1110,
                              userInfo: [NSLocalizedDescriptionKey: "No speech detected"])
        backend.emit(.failed(failure))
        // Anything after the failure is ignored.
        backend.emit(.result(text: "hello", isFinal: true))

        let error = await #expect(throws: ProviderError.self) { try await consumer.value }
        #expect(error?.provider == "apple")
        #expect(error?.status == nil)
        #expect(error?.message.contains("No speech detected") == true)
        #expect(error?.message.contains("1110") == true)
        #expect(backend.cancelCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelStopsTheEngineAndEndsTheStreamQuietly() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        let consumer = Task { try await collect(session.events) }
        backend.emit(.result(text: "never mind", isFinal: false))
        await session.cancel()
        #expect(backend.cancelCount == 1)
        backend.emit(.result(text: "never mind.", isFinal: true))
        await session.send(littleEndianBytes([1, 2, 3]))
        await session.finish()
        await session.cancel()
        let events = try await consumer.value
        #expect(events == [.interim("never mind")])
        #expect(backend.int16.isEmpty)
        #expect(backend.endAudioCount == 0)
        #expect(backend.cancelCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheConsumingTaskStopsTheEngine() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        let firstEvent = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            for try await _ in session.events { firstEvent.continuation.yield() }
        }
        backend.emit(.result(text: "hey", isFinal: false))
        for await _ in firstEvent.stream { break }  // the consumer is iterating
        consumer.cancel()
        #expect(await eventually { backend.cancelCount == 1 })
        _ = await consumer.result
        // The session is closed: nothing more is forwarded to the engine.
        await session.send(littleEndianBytes([1, 2]))
        #expect(backend.int16.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func droppingTheSessionStopsTheEngine() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        var session: AppleSpeechSession? = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k,
                                                                  backend: backend)
        let events = try #require(session?.events)
        session = nil
        #expect(backend.cancelCount == 1)
        var iterator = events.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func droppingTheSessionAfterFinishStillDeliversTheFinals() async throws {
        // A caller may keep only `events` once input is over: Swift can release a session right after its last
        // use, before the engine has delivered the last finals. finish() promises those finals, so they must arrive.
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        var session: AppleSpeechSession? = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k,
                                                                  backend: backend)
        let events = try #require(session?.events)
        let consumer = Task { try await collect(events) }
        await session?.send(littleEndianBytes([1, 2, 3]))
        await session?.finish()
        let released = WeakReference(session)
        session = nil
        #expect(backend.cancelCount == 0)
        backend.emit(.result(text: "Turn on the lights.", isFinal: true))
        backend.emit(.finished)
        #expect(try await consumer.value == [.final("Turn on the lights.")])
        #expect(backend.cancelCount == 0)
        // Once the engine is done, nothing keeps the session alive.
        #expect(released.value == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheConsumerAfterFinishReleasesTheSession() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        var session: AppleSpeechSession? = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k,
                                                                  backend: backend)
        let events = try #require(session?.events)
        let firstEvent = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            for try await _ in events { firstEvent.continuation.yield() }
            firstEvent.continuation.yield()  // also wake the test if the stream ended early
        }
        await session?.finish()
        let released = WeakReference(session)
        session = nil
        #expect(backend.cancelCount == 0)
        backend.emit(.result(text: "still", isFinal: false))
        for await _ in firstEvent.stream { break }
        consumer.cancel()
        #expect(await eventually { backend.cancelCount == 1 })
        _ = await consumer.result
        #expect(await eventually { released.value == nil })
    }

    // MARK: 1-byte chunks (adversarial)

    @Test(.timeLimit(.minutes(1)))
    func oneByteChunksReachTheEngineIntact() async throws {
        let backend = ScriptedSpeechBackend(format: int16Mono16k())
        let session = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: backend)
        let samples = (0..<801).map { Int16(truncatingIfNeeded: $0 &* 977 &- 30_000) }
        for byte in littleEndianBytes(samples) { await session.send(Data([byte])) }
        await session.send(Data([0xAB]))  // a dangling half sample at the end
        await session.finish()
        #expect(backend.int16 == samples)
        #expect(backend.endAudioCount == 1)
        await session.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func oneByteChunksResampleLikeOneBigChunk() async throws {
        // An engine that wants 48 kHz Float32: the converter keeps resampler state across 1-frame buffers.
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                                interleaved: false))
        let tone = (0..<1_600).map { Int16(8_000 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        let bytes = littleEndianBytes(tone)

        let whole = ScriptedSpeechBackend(format: target)
        let wholeSession = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: whole)
        await wholeSession.send(bytes)
        await wholeSession.finish()

        let trickle = ScriptedSpeechBackend(format: target)
        let trickleSession = try AppleSpeechSession(providerID: "apple", inputFormat: .speech16k, backend: trickle)
        for byte in bytes { await trickleSession.send(Data([byte])) }
        await trickleSession.finish()

        #expect(abs(whole.float.count - 4_800) <= 48)
        #expect(abs(trickle.float.count - whole.float.count) <= 48)
        let compared = min(whole.float.count, trickle.float.count)
        let worst = zip(whole.float.prefix(compared), trickle.float.prefix(compared)).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 0.01)
        await wholeSession.cancel()
        await trickleSession.cancel()
    }

    // MARK: Authorization (never prompts: the authorizer is a fake)

    @Test func deniedAuthorizationFailsTheSessionClearly() async throws {
        let authorizer = FakeAuthorizer(status: .denied)
        let engines = ScriptedEngines(analyzer: .available)
        let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: true,
                                       authorizer: authorizer, backends: engines.factory)
        let error = await #expect(throws: ProviderError.self) {
            _ = try await client.startSession(language: "en-US", keywords: [])
        }
        #expect(error?.provider == "apple")
        #expect(error?.message.contains("denied") == true)
        #expect(error?.message.contains("System Settings") == true)
        #expect(authorizer.requests == 0)
        // The user's "no" covers SpeechAnalyzer too, even though that engine doesn't require the permission.
        #expect(engines.analyzerCalls == 0)
        #expect(engines.recognizerCalls == 0)
    }

    @Test func restrictedAuthorizationStopsBothEngines() async throws {
        let engines = ScriptedEngines(analyzer: .available)
        let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: true,
                                       authorizer: FakeAuthorizer(status: .restricted), backends: engines.factory)
        let error = await #expect(throws: ProviderError.self) {
            _ = try await client.startSession(language: nil, keywords: [])
        }
        #expect(error?.message.contains("restricted") == true)
        #expect(engines.analyzerCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func speechAnalyzerSessionsDontNeedThePermission() async throws {
        // Undecided, and a process that can't ask (prompt false, like occtl): SpeechAnalyzer still runs.
        for prompt in [true, false] {
            let authorizer = FakeAuthorizer(status: .notDetermined, answer: .authorized)
            let engines = ScriptedEngines(analyzer: .available)
            let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: prompt,
                                           authorizer: authorizer, backends: engines.factory)
            let session = try await client.startSession(language: "en-US", keywords: [" OpenClicky ", "OpenClicky"])
            #expect(authorizer.requests == 0)
            #expect(engines.analyzerCalls == 1)
            #expect(engines.recognizerCalls == 0)
            #expect(engines.lastLocale?.identifier == "en-US")
            #expect(engines.lastContextualStrings == ["OpenClicky"])
            let backend = try #require(engines.lastBackend)
            let consumer = Task { try await collect(session.events) }
            await session.send(littleEndianBytes([7, 8]))
            await session.finish()
            backend.emit(.result(text: "Hi.", isFinal: true))
            backend.emit(.finished)
            #expect(try await consumer.value == [.final("Hi.")])
            #expect(backend.int16 == [7, 8])
        }
    }

    @Test func fallingBackToSFSpeechRecognizerAsksForPermissionFirst() async throws {
        let authorizer = FakeAuthorizer(status: .notDetermined, answer: .authorized)
        let engines = ScriptedEngines(analyzer: .unsupported)
        let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: true,
                                       authorizer: authorizer, backends: engines.factory)
        let session = try await client.startSession(language: "fr-CA", keywords: [])
        #expect(engines.analyzerCalls == 1)
        #expect(authorizer.requests == 1)
        #expect(engines.recognizerCalls == 1)
        #expect(engines.lastLocale?.identifier == "fr-CA")
        await session.cancel()
    }

    @Test func whenBothEnginesFailTheErrorExplainsBoth() async throws {
        let analyzerFailure = NSError(domain: "SFSpeechErrorDomain", code: 4,
                                      userInfo: [NSLocalizedDescriptionKey: "Too many reserved languages"])
        let authorizer = FakeAuthorizer(status: .notDetermined, answer: .authorized)
        let engines = ScriptedEngines(analyzer: .fails(analyzerFailure))
        let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: false,
                                       authorizer: authorizer, backends: engines.factory)
        let error = await #expect(throws: ProviderError.self) {
            _ = try await client.startSession(language: "de-DE", keywords: [])
        }
        #expect(error?.message.contains("not been granted") == true)
        #expect(error?.message.contains("SpeechAnalyzer couldn't be used") == true)
        #expect(error?.message.contains("Too many reserved languages") == true)
        #expect(authorizer.requests == 0)
        #expect(engines.recognizerCalls == 0)
    }

    @Test func speechRecognizerEngineSkipsTheAnalyzer() async throws {
        let authorizer = FakeAuthorizer(status: .authorized)
        let engines = ScriptedEngines(analyzer: .available)
        let client = AppleSpeechClient(context: appleContext(), engine: .speechRecognizer,
                                       promptsForAuthorization: true, authorizer: authorizer,
                                       backends: engines.factory)
        let session = try await client.startSession(language: nil, keywords: [])
        #expect(engines.analyzerCalls == 0)
        #expect(engines.recognizerCalls == 1)
        #expect(engines.lastLocale == Locale.current)
        await session.cancel()
    }

    @Test func cancellationWhileStartingTheAnalyzerDoesNotFallBack() async throws {
        let authorizer = FakeAuthorizer(status: .notDetermined, answer: .authorized)
        let engines = ScriptedEngines(analyzer: .fails(CancellationError()))
        let client = AppleSpeechClient(context: appleContext(), engine: .automatic, promptsForAuthorization: true,
                                       authorizer: authorizer, backends: engines.factory)
        await #expect(throws: CancellationError.self) {
            _ = try await client.startSession(language: "en-US", keywords: [])
        }
        #expect(authorizer.requests == 0)
        #expect(engines.recognizerCalls == 0)
    }

    @Test func undecidedAuthorizationPromptsOnlyWhenAllowed() async throws {
        let granting = FakeAuthorizer(status: .notDetermined, answer: .authorized)
        try await AppleSpeechClient.authorize(provider: "apple", authorizer: granting, prompt: true)
        #expect(granting.requests == 1)

        let declining = FakeAuthorizer(status: .notDetermined, answer: .denied)
        await #expect(throws: ProviderError.self) {
            try await AppleSpeechClient.authorize(provider: "apple", authorizer: declining, prompt: true)
        }
        #expect(declining.requests == 1)

        let silent = FakeAuthorizer(status: .notDetermined, answer: .authorized)
        let error = await #expect(throws: ProviderError.self) {
            try await AppleSpeechClient.authorize(provider: "apple", authorizer: silent, prompt: false)
        }
        #expect(error?.message.contains("not been granted") == true)
        #expect(silent.requests == 0)

        let restricted = FakeAuthorizer(status: .restricted)
        await #expect(throws: ProviderError.self) {
            try await AppleSpeechClient.authorize(provider: "apple", authorizer: restricted, prompt: true)
        }
        #expect(restricted.requests == 0)

        let granted = FakeAuthorizer(status: .authorized)
        try await AppleSpeechClient.authorize(provider: "apple", authorizer: granted, prompt: true)
        #expect(granted.requests == 0)
    }

    @Test func systemAuthorizationStatusesMap() {
        #expect(SystemSpeechRecognitionAuthorizer.map(.authorized) == .authorized)
        #expect(SystemSpeechRecognitionAuthorizer.map(.denied) == .denied)
        #expect(SystemSpeechRecognitionAuthorizer.map(.restricted) == .restricted)
        #expect(SystemSpeechRecognitionAuthorizer.map(.notDetermined) == .notDetermined)
    }

    // MARK: Request options

    @Test func recognizerRequestIsOnDeviceWithPartialsAndKeywords() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        AppleSpeechRecognizerBackend.configure(request, supportsOnDeviceRecognition: true,
                                               contextualStrings: ["OpenClicky", "Blender"])
        #expect(request.shouldReportPartialResults)
        #expect(request.requiresOnDeviceRecognition)
        #expect(request.contextualStrings == ["OpenClicky", "Blender"])
        #expect(request.addsPunctuation)

        let serverOnly = SFSpeechAudioBufferRecognitionRequest()
        AppleSpeechRecognizerBackend.configure(serverOnly, supportsOnDeviceRecognition: false, contextualStrings: [])
        #expect(!serverOnly.requiresOnDeviceRecognition)
        #expect(serverOnly.contextualStrings.isEmpty)
    }

    @Test func analyzerContextCarriesKeywords() throws {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else { return }
        #expect(AppleSpeechAnalyzerBackend.analysisContext(contextualStrings: []) == nil)
        let context = try #require(AppleSpeechAnalyzerBackend.analysisContext(contextualStrings: ["OpenClicky"]))
        #expect(context.contextualStrings[.general] == ["OpenClicky"])
        #endif
    }

    @Test func keywordsAreTrimmedDeduplicatedAndCapped() {
        #expect(AppleSpeechClient.contextualStrings(from: [" Clicky ", "", "Clicky", "  ", "Blender"]) == ["Clicky", "Blender"])
        let many = (0..<150).map { "word\($0)" }
        #expect(AppleSpeechClient.contextualStrings(from: many) == Array(many.prefix(100)))
    }

    @Test func languageBecomesALocale() {
        let bcp47 = AppleSpeechClient.locale(for: "en-US")
        #expect(bcp47.language.languageCode?.identifier == "en")
        #expect(bcp47.region?.identifier == "US")
        let icu = AppleSpeechClient.locale(for: "fr_CA")
        #expect(icu.language.languageCode?.identifier == "fr")
        #expect(icu.region?.identifier == "CA")
        #expect(AppleSpeechClient.locale(for: nil) == Locale.current)
        #expect(AppleSpeechClient.locale(for: "  ") == Locale.current)
    }

    @Test func clientWantsSixteenKilohertzMonoAndNeedsNoKey() {
        let client = AppleSpeechClient(context: appleContext())
        #expect(client.inputFormat == .speech16k)
        #expect(ProviderDialect.appleSpeech.isOnDevice)
        #expect(ProviderDialect.appleSpeech.servableKinds == [.speechToText])
    }
}

// MARK: - Helpers

/// Plays the recognizer: records what the session feeds it and emits whatever results a test scripts.
private final class ScriptedSpeechBackend: AppleSpeechBackend, @unchecked Sendable {
    let bufferFormat: AVAudioFormat
    private let lock = NSLock()
    private var handler: (@Sendable (AppleSpeechBackendEvent) -> Void)?
    private var _int16: [Int16] = []
    private var _float: [Float] = []
    private var _formats: [AVAudioFormat] = []
    private var _endAudio = 0
    private var _cancel = 0

    init(format: AVAudioFormat) { self.bufferFormat = format }

    var started: Bool { lock.withLock { handler != nil } }
    var int16: [Int16] { lock.withLock { _int16 } }
    var float: [Float] { lock.withLock { _float } }
    var formats: [AVAudioFormat] { lock.withLock { _formats } }
    var endAudioCount: Int { lock.withLock { _endAudio } }
    var cancelCount: Int { lock.withLock { _cancel } }

    func start(reporting handler: @escaping @Sendable (AppleSpeechBackendEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            _formats.append(buffer.format)
            if buffer.format.commonFormat == .pcmFormatInt16 { _int16 += int16Samples(buffer) }
            if buffer.format.commonFormat == .pcmFormatFloat32 { _float += floatSamples(buffer) }
        }
    }

    func endAudio() { lock.withLock { _endAudio += 1 } }
    func cancel() { lock.withLock { _cancel += 1 } }

    func emit(_ event: AppleSpeechBackendEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }
}

/// Stands in for both engine constructors and records how the client used them.
private final class ScriptedEngines: @unchecked Sendable {
    enum Analyzer { case available, unsupported, fails(any Error) }

    private let lock = NSLock()
    private let analyzer: Analyzer
    private var _analyzerCalls = 0
    private var _recognizerCalls = 0
    private var _lastLocale: Locale?
    private var _lastContextualStrings: [String]?
    private var _lastBackend: ScriptedSpeechBackend?

    init(analyzer: Analyzer) { self.analyzer = analyzer }

    var analyzerCalls: Int { lock.withLock { _analyzerCalls } }
    var recognizerCalls: Int { lock.withLock { _recognizerCalls } }
    var lastLocale: Locale? { lock.withLock { _lastLocale } }
    var lastContextualStrings: [String]? { lock.withLock { _lastContextualStrings } }
    var lastBackend: ScriptedSpeechBackend? { lock.withLock { _lastBackend } }

    var factory: AppleSpeechBackendFactory {
        AppleSpeechBackendFactory(
            analyzer: { locale, strings in
                let backend = ScriptedSpeechBackend(format: int16Mono16k())
                self.lock.withLock {
                    self._analyzerCalls += 1
                    self._lastLocale = locale
                    self._lastContextualStrings = strings
                }
                switch self.analyzer {
                case .available:
                    self.lock.withLock { self._lastBackend = backend }
                    return backend
                case .unsupported: return nil
                case .fails(let error): throw error
                }
            },
            recognizer: { locale, strings, _ in
                let backend = ScriptedSpeechBackend(format: int16Mono16k())
                self.lock.withLock {
                    self._recognizerCalls += 1
                    self._lastLocale = locale
                    self._lastContextualStrings = strings
                    self._lastBackend = backend
                }
                return backend
            })
    }
}

private final class FakeAuthorizer: SpeechRecognitionAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private let current: SpeechRecognitionAuthorization
    private let answer: SpeechRecognitionAuthorization
    private var _requests = 0

    init(status: SpeechRecognitionAuthorization, answer: SpeechRecognitionAuthorization = .denied) {
        self.current = status
        self.answer = answer
    }

    var requests: Int { lock.withLock { _requests } }
    func status() -> SpeechRecognitionAuthorization { current }
    func request() async throws -> SpeechRecognitionAuthorization {
        lock.withLock { _requests += 1 }
        return answer
    }
}

/// Watches whether an object has been deallocated.
private final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: Object?
    init(_ value: Object?) { _value = value }
    var value: Object? { lock.withLock { _value } }
}

private func appleContext() -> ProviderContext {
    ProviderContext(provider: ProviderConfig(id: "apple", dialect: .appleSpeech), apiKey: nil,
                    http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
}

private func int16Mono16k() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
}

private func littleEndianBytes(_ samples: [Int16]) -> Data {
    var data = Data()
    for sample in samples {
        let bits = UInt16(bitPattern: sample)
        data.append(UInt8(bits & 0xFF))
        data.append(UInt8(bits >> 8))
    }
    return data
}

/// Interleaved Int16 samples in order.
private func int16Samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
    guard let data = buffer.int16ChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength) * Int(buffer.format.channelCount)))
}

/// Mono Float32 samples.
private func floatSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

private func collect(_ events: AsyncThrowingStream<TranscriptEvent, Error>) async throws -> [TranscriptEvent] {
    var collected: [TranscriptEvent] = []
    for try await event in events { collected.append(event) }
    return collected
}

/// The timeout only guards against a hang: a busy machine can take far longer than an idle one.
private func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
