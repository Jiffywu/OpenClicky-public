import AVFAudio
import Foundation
import Testing
@testable import OpenClickyKit

/// Scripted stand-in for AVSpeechSynthesizer: records what it was asked to render and lets a test feed buffers and
/// delegate events, in any order, from any thread.
private final class ScriptedRenderer: AppleSpeechSynthesisClient.Renderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [(text: String, voice: String?)] = []
    private var _stops = 0
    private var _line: AppleSpeechSynthesisClient.Line?
    /// Runs inside `start`, the way AVSpeechSynthesizer begins calling back once `write` is called.
    let onStart: (@Sendable (AppleSpeechSynthesisClient.Line) -> Void)?

    init(onStart: (@Sendable (AppleSpeechSynthesisClient.Line) -> Void)? = nil) { self.onStart = onStart }

    func start(text: String, voice: String?, line: AppleSpeechSynthesisClient.Line) {
        lock.withLock {
            _starts.append((text, voice))
            _line = line
        }
        onStart?(line)
    }

    func stop() { lock.withLock { _stops += 1 } }

    var starts: [(text: String, voice: String?)] { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var line: AppleSpeechSynthesisClient.Line? { lock.withLock { _line } }
}

/// A buffer like the ones the system voices write: deinterleaved Float32.
private func floatBuffer(_ samples: [[Float]], sampleRate: Double = 22_050, interleaved: Bool = false) -> AVAudioPCMBuffer {
    let channels = samples.count
    let frames = samples.first?.count ?? 0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: AVAudioChannelCount(channels), interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let planes = buffer.floatChannelData!
    for channel in 0..<channels {
        for frame in 0..<frames { planes[channel][frame * buffer.stride] = samples[channel][frame] }
    }
    return buffer
}

private func int16Buffer(_ samples: [[Int16]], sampleRate: Double = 16_000, interleaved: Bool = true) -> AVAudioPCMBuffer {
    let channels = samples.count
    let frames = samples[0].count
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                               channels: AVAudioChannelCount(channels), interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let planes = buffer.int16ChannelData!
    for channel in 0..<channels {
        for frame in 0..<frames { planes[channel][frame * buffer.stride] = samples[channel][frame] }
    }
    return buffer
}

/// The zero-length buffer the synthesizer writes at the end of each segment.
private func emptyBuffer(sampleRate: Double = 22_050) -> AVAudioPCMBuffer { floatBuffer([[]], sampleRate: sampleRate) }

/// Little-endian 16-bit samples back out of the emitted bytes.
private func samples(_ data: Data) -> [Int16] {
    stride(from: 0, to: data.count, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
}

private let context = ProviderContext(provider: ProviderConfig(id: "mac-voice", dialect: .appleSpeechSynthesis), apiKey: nil)

private func client(_ renderer: ScriptedRenderer, defaultVoice: String? = nil,
                    timing: AppleSpeechSynthesisClient.Timing = .init(tick: .milliseconds(10))) -> AppleSpeechSynthesisClient {
    AppleSpeechSynthesisClient(context: context, defaultVoice: defaultVoice, timing: timing, makeRenderer: { renderer })
}

private func collect(_ stream: AsyncThrowingStream<SpeechEvent, Error>) async throws -> [SpeechEvent] {
    var events: [SpeechEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

/// Polls until `condition` holds or ten seconds pass (a hang guard; a busy machine can take far longer than an idle one).
private func eventually(_ condition: () -> Bool) async -> Bool {
    await waitUntil(.seconds(10), condition)
}

/// Simulated time for a line's fallbacks: it moves only when the test says so.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance(by duration: Duration) { lock.withLock { current += duration } }
}

@Suite("AppleSpeechSynthesis")
struct AppleSpeechSynthesisTests {
    // MARK: Float32 → PCM16 conversion

    @Test func sampleConversionClipsAndRoundsHalvesAwayFromZero() {
        typealias PCM16 = AppleSpeechSynthesisClient.PCM16
        #expect(PCM16.sample(0) == 0)
        #expect(PCM16.sample(1) == 32767)
        #expect(PCM16.sample(-1) == -32767)
        #expect(PCM16.sample(1.5) == 32767)
        #expect(PCM16.sample(-2) == -32767)
        #expect(PCM16.sample(.infinity) == 32767)
        #expect(PCM16.sample(-.infinity) == -32767)
        #expect(PCM16.sample(.nan) == 0)
        #expect(PCM16.sample(0.5) == 16384)       // 16383.5
        #expect(PCM16.sample(-0.5) == -16384)     // -16383.5
        #expect(PCM16.sample(0.25) == 8192)       // 8191.75
        #expect(PCM16.sample(0.75) == 24575)      // 24575.25
        #expect(PCM16.sample(-0.75) == -24575)
    }

    @Test func monoFloatBufferBecomesLittleEndianPCM16AtItsOwnRate() throws {
        let buffer = floatBuffer([[0, 1, -1, 0.5, -0.25, 2]], sampleRate: 22_050)
        let (data, format) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: buffer))
        #expect(format == PCMFormat(sampleRate: 22_050, channels: 1))
        #expect(data.count == 12)
        #expect(Array(data.prefix(6)) == [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80])  // 0, 32767, -32767
        #expect(samples(data) == [0, 32767, -32767, 16384, -8192, 32767])
    }

    @Test func stereoFloatIsAveragedToMonoInterleavedOrNot() throws {
        let left: [Float] = [1, 1, 0.5, -1, 0.75]
        let right: [Float] = [1, -1, 0, -1, 0.75]
        let expected: [Int16] = [32767, 0, 8192, -32767, 24575]
        for interleaved in [false, true] {
            let buffer = floatBuffer([left, right], sampleRate: 24_000, interleaved: interleaved)
            #expect(buffer.stride == (interleaved ? 2 : 1))
            let (data, format) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: buffer))
            #expect(format == PCMFormat(sampleRate: 24_000))
            #expect(samples(data) == expected)
        }
    }

    @Test func clippingHappensAfterTheDownmix() throws {
        // (1.5 + 0.5) / 2 = 1.0 and (1.5 - 0.5) / 2 = 0.5: neither clips once mixed.
        let buffer = floatBuffer([[1.5, 1.5, 3], [0.5, -0.5, 3]])
        let (data, _) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: buffer))
        #expect(samples(data) == [32767, 16384, 32767])
    }

    @Test func int16BuffersPassThroughOrAverage() throws {
        let mono = int16Buffer([[0, 1, -1, 32767, -32768]])
        let (monoData, monoFormat) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: mono))
        #expect(samples(monoData) == [0, 1, -1, 32767, -32768])
        #expect(monoFormat == PCMFormat(sampleRate: 16_000))

        let stereo = int16Buffer([[3, -3, 32767, -32768], [4, -4, 32767, -32768]], sampleRate: 44_100)
        let (stereoData, stereoFormat) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: stereo))
        #expect(samples(stereoData) == [4, -4, 32767, -32768])
        #expect(stereoFormat.sampleRate == 44_100)
    }

    @Test func int32AndUnsupportedFormats() throws {
        let int32Format = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 22_050, channels: 1, interleaved: false)!
        let int32 = AVAudioPCMBuffer(pcmFormat: int32Format, frameCapacity: 3)!
        int32.frameLength = 3
        int32.int32ChannelData![0][0] = Int32.max
        int32.int32ChannelData![0][1] = Int32.min
        int32.int32ChannelData![0][2] = 1 << 30  // 0.5
        let (data, _) = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: int32))
        #expect(samples(data) == [32767, -32767, 16384])

        let doubleFormat = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 22_050, channels: 1, interleaved: false)!
        let float64 = AVAudioPCMBuffer(pcmFormat: doubleFormat, frameCapacity: 4)!
        float64.frameLength = 4
        #expect(AppleSpeechSynthesisClient.PCM16.monoData(from: float64) == nil)
    }

    // MARK: Line lifecycle

    @Test func streamsEachBufferAsItArrivesAndFinishesAfterDidFinish() async throws {
        // Fallback timers far longer than the test, so only didFinish plus the zero-length buffer can end this line,
        // however late a busy machine runs the other thread.
        let renderer = ScriptedRenderer()
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), terminatorIdle: .seconds(60), finishGrace: .seconds(60))
        let stream = client(renderer, timing: timing).speak("Hello there. This is long enough for two segments.", voice: nil, instructions: nil)
        var iterator = stream.makeAsyncIterator()
        let line = try #require(renderer.line)

        // The first chunk is readable before the rest of the line exists.
        line.deliver(floatBuffer([[0, 0.5, -0.5]]))
        #expect(try await iterator.next() == .audio(Data([0x00, 0x00, 0x00, 0x40, 0x00, 0xC0]), PCMFormat(sampleRate: 22_050)))

        // A zero-length buffer mid-line ends a segment, not the line: more audio follows on another thread.
        line.deliver(emptyBuffer())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                line.deliver(floatBuffer([[1, 1]]))
                line.deliver(floatBuffer([[-1]]))
                line.deliver(emptyBuffer())
                line.synthesizerDidFinish()
                done.resume()
            }
        }
        var rest: [SpeechEvent] = []
        while let event = try await iterator.next() { rest.append(event) }
        #expect(rest == [
            .audio(Data([0xFF, 0x7F, 0xFF, 0x7F]), PCMFormat(sampleRate: 22_050)),
            .audio(Data([0x01, 0x80]), PCMFormat(sampleRate: 22_050)),
            .lineFinished,
        ])
        #expect(await eventually { renderer.stops == 1 })
    }

    @Test func oneFrameBuffersAndStraySegmentEndsReassembleExactly() async throws {
        // The worst chunking the synthesizer could choose: every frame in its own buffer, zero-length buffers at
        // arbitrary points, delivered from another thread. The concatenated chunks must equal converting the whole
        // signal at once, in order, with exactly one lineFinished at the end.
        let mono: [Float] = (0..<997).map { Float(sin(Double($0) * 0.37)) * 1.3 }  // clips at the peaks
        let left: [Float] = (0..<301).map { Float(cos(Double($0) * 0.11)) }
        let right: [Float] = (0..<301).map { Float(sin(Double($0) * 0.23)) * -0.9 }
        let wholeMono = try #require(AppleSpeechSynthesisClient.PCM16.monoData(from: floatBuffer([mono]))).0
        let wholeStereo = try #require(AppleSpeechSynthesisClient.PCM16.monoData(
            from: floatBuffer([left, right], interleaved: true))).0

        let renderer = ScriptedRenderer { line in
            DispatchQueue.global().async {
                for (frame, value) in mono.enumerated() {
                    line.deliver(floatBuffer([[value]]))
                    if frame % 97 == 0 || frame % 13 == 5 { line.deliver(emptyBuffer()) }
                }
                for frame in left.indices {
                    line.deliver(floatBuffer([[left[frame]], [right[frame]]], interleaved: frame % 2 == 0))
                    if frame % 50 == 49 { line.deliver(emptyBuffer()) }
                }
                line.deliver(emptyBuffer())
                line.synthesizerDidFinish()
            }
        }
        let events = try await collect(client(renderer).speak("A long line.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        var joined = Data()
        for event in events.dropLast() {
            guard case .audio(let data, let format) = event else { Issue.record("unexpected \(event)"); continue }
            #expect(data.count == 2)
            #expect(format == PCMFormat(sampleRate: 22_050, channels: 1))
            joined.append(data)
        }
        #expect(events.count == mono.count + left.count + 1)
        #expect(joined == wholeMono + wholeStereo)
    }

    @Test func didFinishBeforeTheLastBufferWaitsForTheTerminator() async throws {
        // A long finishGrace, so only the zero-length buffer can end this line.
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), finishGrace: .seconds(30))
        let renderer = ScriptedRenderer { line in
            line.deliver(floatBuffer([[0.25]], sampleRate: 16_000))
            line.synthesizerDidFinish()
            line.deliver(floatBuffer([[0.75]], sampleRate: 16_000))
            line.deliver(emptyBuffer(sampleRate: 16_000))
            line.deliver(floatBuffer([[1]], sampleRate: 16_000))  // after the end: dropped
        }
        let events = try await collect(client(renderer, timing: timing).speak("Hi.", voice: nil, instructions: nil))
        #expect(events == [
            .audio(Data([0x00, 0x20]), PCMFormat(sampleRate: 16_000)),
            .audio(Data([0xFF, 0x5F]), PCMFormat(sampleRate: 16_000)),
            .lineFinished,
        ])
    }

    @Test func aTerminatorFollowedBySilenceEndsTheLineWithoutTheDelegate() async throws {
        // Simulated time, so the gaps are exactly what the test says however busy the machine is.
        let clock = ManualClock()
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), terminatorIdle: .milliseconds(150), now: { clock.now })
        let renderer = ScriptedRenderer()
        let stream = client(renderer, timing: timing).speak("Hi.", voice: nil, instructions: nil)
        let events = Locked<[SpeechEvent]>([])
        let consumer = Task { for try await event in stream { events.mutate { $0.append(event) } } }
        let line = try #require(renderer.line)

        line.deliver(floatBuffer([[0.5]]))
        line.deliver(emptyBuffer())
        // The next segment starts well inside terminatorIdle, so the line goes on.
        clock.advance(by: .milliseconds(100))
        line.deliver(floatBuffer([[-0.5]]))
        line.deliver(emptyBuffer())
        // No didFinish: the forum-reported macOS 10.15/11 behaviour. Just short of terminatorIdle the line is still
        // open, however many times the watchdog looks…
        clock.advance(by: .milliseconds(149))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!events.mutate { $0 }.contains(.lineFinished))
        // …and at terminatorIdle it ends.
        clock.advance(by: .milliseconds(1))
        try await consumer.value
        let all = events.mutate { $0 }
        #expect(all.count == 3)
        #expect(all.last == .lineFinished)
    }

    @Test func onceDidFinishHasBeenSeenALateSegmentDoesNotCutTheLineShort() async throws {
        // Callbacks come on the main thread in the app, so a busy main thread can hold the next segment back well
        // past terminatorIdle. Once this system has shown it sends didFinish, the zero-length buffer is only a
        // segment boundary and the line must wait for didFinish.
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), terminatorIdle: .milliseconds(100))
        let first = ScriptedRenderer { line in
            line.deliver(floatBuffer([[0.5]]))
            line.deliver(emptyBuffer())
            line.synthesizerDidFinish()
        }
        let second = ScriptedRenderer { line in
            DispatchQueue.global().async {
                line.deliver(floatBuffer([[0.25]]))
                line.deliver(emptyBuffer())             // mid-line segment boundary
                Thread.sleep(forTimeInterval: 0.4)      // a main-thread stall, 4x terminatorIdle
                line.deliver(floatBuffer([[-0.25]]))
                line.deliver(emptyBuffer())
                line.synthesizerDidFinish()
            }
        }
        let renderers = [first, second]
        let index = Counter()
        let speech = AppleSpeechSynthesisClient(context: context, defaultVoice: nil, timing: timing,
                                                makeRenderer: { renderers[index.next()] })
        #expect(try await collect(speech.speak("One.", voice: nil, instructions: nil))
            == [.audio(Data([0x00, 0x40]), PCMFormat(sampleRate: 22_050)), .lineFinished])
        #expect(try await collect(speech.speak("Two. Three. Four.", voice: nil, instructions: nil)) == [
            .audio(Data([0x00, 0x20]), PCMFormat(sampleRate: 22_050)),
            .audio(Data([0x00, 0xE0]), PCMFormat(sampleRate: 22_050)),
            .lineFinished,
        ])
    }

    @Test func didFinishWithoutATerminatorEndsTheLineAfterTheGrace() async throws {
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), finishGrace: .milliseconds(80))
        let renderer = ScriptedRenderer { line in
            line.deliver(floatBuffer([[0.5]]))
            line.synthesizerDidFinish()
        }
        let events = try await collect(client(renderer, timing: timing).speak("Hi.", voice: nil, instructions: nil))
        #expect(events == [.audio(Data([0x00, 0x40]), PCMFormat(sampleRate: 22_050)), .lineFinished])
    }

    @Test func didFinishWithNoAudioFinishesAtOnce() async throws {
        let renderer = ScriptedRenderer { line in line.synthesizerDidFinish() }
        let events = try await collect(client(renderer).speak("…", voice: nil, instructions: nil))
        #expect(events == [.lineFinished])
    }

    @Test func aSilentSynthesizerFailsWithAProviderError() async throws {
        let timing = AppleSpeechSynthesisClient.Timing(tick: .milliseconds(10), stallTimeout: .milliseconds(100))
        let renderer = ScriptedRenderer()  // never calls back
        do {
            _ = try await collect(client(renderer, timing: timing).speak("Hello.", voice: nil, instructions: nil))
            Issue.record("expected the line to fail")
        } catch let error as ProviderError {
            #expect(error.provider == "mac-voice")
            #expect(error.status == nil)
            #expect(error.message.contains("no audio"))
        }
        #expect(await eventually { renderer.stops == 1 })
    }

    @Test func aSystemCancelSurfacesAsProviderError() async throws {
        let renderer = ScriptedRenderer { line in
            line.deliver(floatBuffer([[0.5]]))
            line.synthesizerDidCancel()
        }
        var events: [SpeechEvent] = []
        let error = await #expect(throws: ProviderError.self) {
            for try await event in client(renderer).speak("Hello.", voice: nil, instructions: nil) { events.append(event) }
        }
        #expect(error?.message.contains("cancelled") == true)
        #expect(events.count == 1)
    }

    @Test func anUnsupportedBufferFailsTheLine() async throws {
        let doubleFormat = AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 22_050, channels: 1, interleaved: false)!
        let renderer = ScriptedRenderer { line in
            let buffer = AVAudioPCMBuffer(pcmFormat: doubleFormat, frameCapacity: 2)!
            buffer.frameLength = 2
            line.deliver(buffer)
        }
        let error = await #expect(throws: ProviderError.self) {
            _ = try await collect(client(renderer).speak("Hello.", voice: nil, instructions: nil))
        }
        #expect(error?.provider == "mac-voice")
        #expect(error?.message.contains("unsupported") == true)
    }

    // MARK: Cancellation

    @Test func cancellingTheConsumerStopsTheSynthesizer() async throws {
        let renderer = ScriptedRenderer()
        let speech = client(renderer)
        let stream = speech.speak("A long line that the user interrupts.", voice: nil, instructions: nil)
        let line = try #require(renderer.line)
        let firstChunk = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var count = 0
            for try await event in stream {
                if case .audio = event { count += 1; firstChunk.continuation.yield() }
            }
            return count
        }
        line.deliver(floatBuffer([[0.1, 0.2]]))
        var signals = firstChunk.stream.makeAsyncIterator()
        _ = await signals.next()
        consumer.cancel()
        #expect(await eventually { renderer.stops == 1 })
        // Late buffers and delegate calls after the stop are ignored.
        line.deliver(floatBuffer([[0.3]]))
        line.deliver(emptyBuffer())
        line.synthesizerDidFinish()
        let chunks = try await consumer.value
        #expect(chunks == 1)
        #expect(renderer.stops == 1)
    }

    @Test func cancellingBeforeAnyAudioStillStops() async throws {
        let renderer = ScriptedRenderer()
        let consumer = Task {
            for try await _ in client(renderer).speak("Hello.", voice: nil, instructions: nil) {}
        }
        #expect(await eventually { renderer.line != nil })
        consumer.cancel()
        _ = await consumer.result
        #expect(await eventually { renderer.stops == 1 })
    }

    @Test func stopAllEndsEveryLineWithCancellationError() async throws {
        let first = ScriptedRenderer()
        let second = ScriptedRenderer()
        let renderers = [first, second]
        let index = Counter()
        let speech = AppleSpeechSynthesisClient(context: context, defaultVoice: nil, timing: .init(tick: .milliseconds(10)),
                                                makeRenderer: { renderers[index.next()] })
        let a = speech.speak("One.", voice: nil, instructions: nil)
        let b = speech.speak("Two.", voice: nil, instructions: nil)
        try #require(first.line).deliver(floatBuffer([[0.5]]))
        await speech.stopAll()
        var aEvents: [SpeechEvent] = []
        await #expect(throws: CancellationError.self) { for try await event in a { aEvents.append(event) } }
        await #expect(throws: CancellationError.self) { _ = try await collect(b) }
        #expect(aEvents.count == 1)  // the chunk that arrived first, and no lineFinished
        #expect(first.stops == 1)
        #expect(second.stops == 1)
    }

    @Test func stopAllRacingSpeakNeverLeavesARendererRunning() async throws {
        // stopAll from one thread while another starts lines. A line stopAll ends must still stop its renderer,
        // however the two interleave; a renderer nobody stops keeps the real synthesizer rendering for nothing.
        let made = Locked<[ScriptedRenderer]>([])
        let speech = AppleSpeechSynthesisClient(context: context, defaultVoice: nil, timing: .init(tick: .seconds(5)),
                                                makeRenderer: { made.mutate { let r = ScriptedRenderer(); $0.append(r); return r } })
        let lineCount = 20_000
        let streams = Locked<[AsyncThrowingStream<SpeechEvent, Error>]>([])  // kept alive, so only stopAll ends them
        let speaking = Locked(true)
        let stopper = Task.detached {
            var calls = 0
            while speaking.mutate({ $0 }) {
                await speech.stopAll()
                calls += 1
            }
            return calls
        }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                for _ in 0..<lineCount {
                    let stream = speech.speak("Hi.", voice: nil, instructions: nil)
                    streams.mutate { $0.append(stream) }
                }
                speaking.mutate { $0 = false }
                finished.resume()
            }
        }
        let stopCalls = await stopper.value
        await speech.stopAll()  // every line still running
        let renderers = made.mutate { $0 }
        #expect(renderers.count == lineCount)
        #expect(stopCalls > 100, "the race was barely exercised")
        #expect(await eventually { renderers.allSatisfy { $0.stops == 1 } })
        #expect(renderers.filter { $0.stops != 1 }.count == 0)
        #expect(streams.mutate { $0.count } == lineCount)
    }

    // MARK: Request mapping

    @Test func blankTextFinishesWithoutRendering() async throws {
        let renderer = ScriptedRenderer()
        let events = try await collect(client(renderer).speak("  \n ", voice: "Samantha", instructions: nil))
        #expect(events == [.lineFinished])
        #expect(renderer.starts.isEmpty)
    }

    @Test func voiceFallsBackToDefaultVoiceAndInstructionsAreIgnored() async throws {
        for (requested, configuredDefault, expected) in [
            ("com.apple.voice.compact.en-GB.Daniel", "Samantha", "com.apple.voice.compact.en-GB.Daniel"),
            (nil, " Samantha ", "Samantha"),
            ("  ", "en-GB", "en-GB"),
            (nil, nil, nil),
        ] as [(String?, String?, String?)] {
            let renderer = ScriptedRenderer { line in line.synthesizerDidFinish() }
            let speech = client(renderer, defaultVoice: configuredDefault)
            _ = try await collect(speech.speak("Say this.", voice: requested, instructions: "Sound cheerful"))
            #expect(renderer.starts.map(\.text) == ["Say this."])
            #expect(renderer.starts.first?.voice == expected)
        }
    }

    @Test func voiceMatchingByIdentifierNameAndLanguage() {
        typealias Voice = AppleSpeechSynthesisClient.VoiceInfo
        let voices = [
            Voice(identifier: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: 1),
            Voice(identifier: "com.apple.eloquence.de-DE.Eddy", name: "Eddy", language: "de-DE", quality: 1),
            Voice(identifier: "com.apple.eloquence.en-GB.Eddy", name: "Eddy", language: "en-GB", quality: 1),
            Voice(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: 1),
            Voice(identifier: "com.apple.voice.enhanced.en-US.Samantha", name: "Samantha", language: "en-US", quality: 2),
            Voice(identifier: "com.apple.voice.compact.fr-CA.Amelie", name: "Amélie", language: "fr-CA", quality: 1),
            Voice(identifier: "com.apple.voice.compact.fr-FR.Thomas", name: "Thomas", language: "fr-FR", quality: 1),
            Voice(identifier: "com.apple.voice.compact.en-AU.Karen", name: "Karen", language: "en-AU", quality: 1),
        ]
        func choose(_ requested: String?, preferred: String = "en-US") -> AppleSpeechSynthesisClient.VoiceChoice {
            AppleSpeechSynthesisClient.chooseVoice(requested, among: voices, preferredLanguage: preferred)
        }
        #expect(choose(nil) == .systemDefault)
        #expect(choose("   ") == .systemDefault)
        #expect(choose("com.apple.eloquence.en-GB.Eddy") == .identifier("com.apple.eloquence.en-GB.Eddy"))
        // Names: the user's language first, then the best quality.
        #expect(choose("eddy") == .identifier("com.apple.eloquence.en-US.Eddy"))
        #expect(choose("Eddy", preferred: "en_GB") == .identifier("com.apple.eloquence.en-GB.Eddy"))
        #expect(choose("Eddy", preferred: "de-AT") == .identifier("com.apple.eloquence.de-DE.Eddy"))
        #expect(choose("samantha") == .identifier("com.apple.voice.enhanced.en-US.Samantha"))
        #expect(choose("Amelie") == .identifier("com.apple.voice.compact.fr-CA.Amelie"))
        // Languages: exact, then the base language's best region.
        #expect(choose("en_gb") == .language("en-GB"))
        #expect(choose("FR-ca") == .language("fr-CA"))
        #expect(choose("fr") == .language("fr-FR"))
        #expect(choose("fr-BE") == .language("fr-FR"))
        #expect(choose("fr", preferred: "fr-CA") == .language("fr-CA"))
        #expect(choose("en", preferred: "en-AU") == .language("en-AU"))
        #expect(choose("en", preferred: "ja-JP") == .language("en-US"))
        #expect(choose("de") == .language("de-DE"))
        // No match: the system default.
        #expect(choose("ja-JP") == .systemDefault)
        #expect(choose("Nonexistent Voice") == .systemDefault)
    }

    @Test func initReadsNothingButTheProviderID() {
        let keyed = ProviderContext(provider: ProviderConfig(id: "mac", dialect: .appleSpeechSynthesis), apiKey: "unused")
        let speech = AppleSpeechSynthesisClient(context: keyed, defaultVoice: "  ")
        #expect(speech.defaultVoice == nil)
        #expect(ProviderDialect.appleSpeechSynthesis.isOnDevice)
    }

    // MARK: Live synthesis (skipped when this Mac has no voices)

    static var voicesInstalled: Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }

    @Test(.enabled(if: AppleSpeechSynthesisTests.voicesInstalled, "no AVSpeechSynthesisVoice is installed"),
          .timeLimit(.minutes(1)))
    func liveSynthesisWritesPCMThenFinishes() async throws {
        let speech = AppleSpeechSynthesisClient(context: context)
        let events = try await collect(speech.speak("Hello from OpenClicky. This is a test.", voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        let chunks = events.compactMap { event -> (Data, PCMFormat)? in
            if case .audio(let data, let format) = event { (data, format) } else { nil }
        }
        try #require(!chunks.isEmpty)
        let bytes = chunks.reduce(0) { $0 + $1.0.count }
        let format = chunks[0].1
        #expect(format.channels == 1)
        #expect(format.sampleRate >= 8_000)
        #expect(chunks.allSatisfy { $0.0.count % 2 == 0 })
        // About two seconds of speech, and not silence.
        #expect(bytes > format.bytesPerSecond / 2)
        #expect(chunks.contains { samples($0.0).contains { abs(Int($0)) > 1_000 } })
    }

    @Test(.enabled(if: AppleSpeechSynthesisTests.voicesInstalled, "no AVSpeechSynthesisVoice is installed"),
          .timeLimit(.minutes(1)))
    func liveLongLineFinishesOnceAndCancelsPromptly() async throws {
        // Fallback timers far longer than this test may run (its time limit is a minute), so finishing at all proves the
        // line ended on didFinish plus the zero-length buffer, not on a timer, however slowly a busy machine renders.
        let slowFallbacks = AppleSpeechSynthesisClient.Timing(terminatorIdle: .seconds(600), finishGrace: .seconds(600))
        let speech = AppleSpeechSynthesisClient(context: context, defaultVoice: AVSpeechSynthesisVoice.currentLanguageCode(),
                                                timing: slowFallbacks, makeRenderer: { AppleSpeechSynthesisClient.SynthesizerRenderer() })
        // Seven sentences: on macOS 27.2 the synthesizer writes a zero-length buffer about every three.
        let text = String(repeating: "This sentence keeps the synthesizer busy for a while. ", count: 7)
        let events = try await collect(speech.speak(text, voice: nil, instructions: nil))
        #expect(events.last == .lineFinished)
        #expect(events.filter { $0 == .lineFinished }.count == 1)
        #expect(events.count > 10)

        // Walking away mid-line stops the real renderer.
        let spy = SpyRenderer()
        let watched = AppleSpeechSynthesisClient(context: context, defaultVoice: nil, timing: .standard, makeRenderer: { spy })
        var received = 0
        for try await event in watched.speak(String(repeating: text, count: 6), voice: nil, instructions: nil) {
            #expect(event != .lineFinished)
            received += 1
            if received == 3 { break }  // drops the only reference to the stream, which terminates it
        }
        #expect(received == 3)
        #expect(await eventually { spy.stops == 1 })

        // Calling stop() is not enough: the synthesizer itself must stop calling back. The abandoned line is several
        // seconds of rendering, so a synthesizer still running would keep adding callbacks across this window.
        let abandoned = try #require(spy.line)
        // Let stop() run on its queue and in-flight callbacks drain: wait until the count holds still for half a
        // second (a running synthesizer never lets it), then watch it for another second.
        var settled = abandoned.callbacksAfterEnd
        var stillSince = ContinuousClock.now
        let giveUp = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now - stillSince < .milliseconds(500), ContinuousClock.now < giveUp {
            try await Task.sleep(for: .milliseconds(50))
            let count = abandoned.callbacksAfterEnd
            if count != settled {
                settled = count
                stillSince = .now
            }
        }
        try await Task.sleep(for: .seconds(1))
        #expect(abandoned.callbacksAfterEnd == settled)
    }
}

/// The real AVSpeechSynthesizer renderer, counting stops.
private final class SpyRenderer: AppleSpeechSynthesisClient.Renderer, @unchecked Sendable {
    private let inner = AppleSpeechSynthesisClient.SynthesizerRenderer()
    private let lock = NSLock()
    private var _stops = 0
    private var _line: AppleSpeechSynthesisClient.Line?

    func start(text: String, voice: String?, line: AppleSpeechSynthesisClient.Line) {
        lock.withLock { _line = line }
        inner.start(text: text, voice: voice, line: line)
    }

    func stop() {
        lock.withLock { _stops += 1 }
        inner.stop()
    }

    var stops: Int { lock.withLock { _stops } }
    var line: AppleSpeechSynthesisClient.Line? { lock.withLock { _line } }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func next() -> Int { lock.withLock { value += 1; return value } }
}
