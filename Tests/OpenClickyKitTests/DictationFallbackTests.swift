import Foundation
import Testing
@testable import OpenClickyKit

/// A speech session that hears something and then never delivers its final words, until it is cancelled.
private final class StallingSpeechToText: SpeechToTextClient, @unchecked Sendable {
    var inputFormat: PCMFormat { .speech16k }
    let lock = NSLock()
    private(set) var sessions: [Session] = []

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let session = Session()
        lock.withLock { sessions.append(session) }
        return session
    }

    final class Session: SpeechToTextSession, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
        private let lock = NSLock()
        private(set) var cancelled = false

        init() {
            (events, continuation) = AsyncThrowingStream.makeStream()
            continuation.yield(.interim("send the"))
        }

        func send(_ pcm: Data) async {}
        func finish() async {}
        func cancel() async {
            lock.withLock { cancelled = true }
            continuation.finish()
        }
    }
}

/// One controller with a streaming client and a fallback client.
/// `finalTranscriptTimeout` is long unless a test is about words that never arrive: a short one would fire on a busy
/// machine before a healthy session's words do.
@MainActor
private func makeController(streaming: any SpeechToTextClient, fallback: (any SpeechToTextClient)?, system: FakeInsertionSystem,
                            mic: FakeMicrophone, finalTranscriptTimeout: Double = 10) -> (DictationController, AsyncStream<DictationSessionReport>) {
    let focus = makeFocus("")
    system.focus = focus
    system.values["field-1"] = ""
    let services = DictationController.Services(
        focus: FixedFocusReader(focus: focus), audio: mic, speechToText: { streaming }, cleaner: { nil },
        inserter: TextInserter(system: system, pasteRestoreDelay: 0), language: "en", keytermSeeds: ["OpenClicky"],
        learnCorrections: false, finalTranscriptTimeout: finalTranscriptTimeout, resultDisplaySeconds: 60,
        fallbackSpeechToText: { fallback }, fallbackTimeout: 30)
    let controller = DictationController(services: services)
    let (reports, continuation) = AsyncStream<DictationSessionReport>.makeStream()
    controller.onSessionFinished = { continuation.yield($0) }
    return (controller, reports)
}

private func first(_ reports: AsyncStream<DictationSessionReport>) async -> DictationSessionReport? {
    for await report in reports { return report }
    return nil
}

/// Half a second of audio at 16 kHz in ten chunks.
private func halfSecondMic() -> FakeMicrophone { FakeMicrophone(chunks: 10, chunkSize: 1600) }

@MainActor @Test(.timeLimit(.minutes(1)))
func aSessionThatCannotConnectIsHeardByTheFallbackAfterTheRelease() async throws {
    let system = FakeInsertionSystem()
    let fallback = ScriptedSpeechToText([.final("book the flight"), .final(" for Tuesday")])
    let (controller, reports) = makeController(streaming: FailingSpeechToText(heardBeforeFailure: nil), fallback: fallback,
                                               system: system, mic: halfSecondMic())
    let losses = speechSessionLosses(controller)
    controller.begin()
    // With a fallback the press keeps recording after the streaming session fails.
    try #require(await firstValue(losses) != nil)
    #expect(controller.isCapturing)
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.heardByFallback)
    #expect(report.rawTranscript == "book the flight for Tuesday")
    #expect(report.result == .typed(appName: "TextEdit"))
    #expect(system.values["field-1"] == "Book the flight for Tuesday")
    // The fallback got the whole press, the language and the keyterms, and was finished.
    let session = try #require(fallback.sessions.first)
    #expect(session.audio.count == 16_000)
    #expect(session.audio.first == 1 && session.audio.last == 10)
    #expect(session.finished)
    #expect(fallback.languages == ["en"])
    #expect(fallback.keywords.first == ["OpenClicky"])
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aDroppedSessionPrefersTheFallbackOverThePartialWords() async throws {
    let system = FakeInsertionSystem()
    let fallback = ScriptedSpeechToText([.final("remember to call the bank before noon")])
    let (controller, reports) = makeController(streaming: FailingSpeechToText(heardBeforeFailure: "remember to call"),
                                               fallback: fallback, system: system, mic: halfSecondMic())
    let losses = speechSessionLosses(controller)
    controller.begin()
    try #require(await firstValue(losses) != nil)
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.heardByFallback)
    #expect(system.values["field-1"] == "Remember to call the bank before noon")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func whenTheFallbackHearsNothingThePartialWordsAreTyped() async throws {
    let system = FakeInsertionSystem()
    let (controller, reports) = makeController(streaming: FailingSpeechToText(heardBeforeFailure: "remember to call"),
                                               fallback: ScriptedSpeechToText([]), system: system, mic: halfSecondMic())
    let losses = speechSessionLosses(controller)
    controller.begin()
    try #require(await firstValue(losses) != nil)
    controller.commit()
    let report = try #require(await first(reports))
    #expect(!report.heardByFallback)
    #expect(report.rawTranscript == "remember to call")
    #expect(system.values["field-1"] == "Remember to call")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func finalWordsThatNeverArriveAreRecoveredByTheFallback() async throws {
    let system = FakeInsertionSystem()
    let streaming = StallingSpeechToText()
    let fallback = ScriptedSpeechToText([.final("send the report")])
    // A short wait for the final words: this is the case it is for. Firing late on a busy machine changes nothing.
    let (controller, reports) = makeController(streaming: streaming, fallback: fallback, system: system, mic: halfSecondMic(),
                                               finalTranscriptTimeout: 0.3)
    let statuses = statusChanges(controller)
    controller.begin()
    // Let go once the session is up and has heard its first words, so there is a session to cancel.
    for await status in statuses where status.liveText == "send the" { break }
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.heardByFallback)
    #expect(system.values["field-1"] == "Send the report")
    #expect(streaming.sessions.first?.cancelled == true)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aHealthySessionNeverRunsTheFallback() async throws {
    let system = FakeInsertionSystem()
    let fallback = ScriptedSpeechToText([.final("wrong")])
    let (controller, reports) = makeController(streaming: ScriptedSpeechToText([.final("all good here")]), fallback: fallback,
                                               system: system, mic: halfSecondMic())
    controller.begin()
    try await Task.sleep(for: .milliseconds(50))
    controller.commit()
    let report = try #require(await first(reports))
    #expect(!report.heardByFallback)
    #expect(fallback.sessions.isEmpty)
    #expect(system.values["field-1"] == "All good here")
}

@Test func fallbackSkipsPressesTooShortToHold() async {
    let fallback = ScriptedSpeechToText([.final("hi")])
    let text = await DictationFallbackTranscription.transcribe(Data(count: 3200), format: .speech16k, with: fallback, language: nil,
                                                              keyterms: [], timeout: 2)
    #expect(text == nil)
    #expect(fallback.sessions.isEmpty)
}

@Test func pressRecordingStopsAtItsLimit() {
    let recording = PressAudioRecording(format: .speech16k, maximumSeconds: 0.01) // 320 bytes
    recording.append(Data(repeating: 1, count: 200))
    recording.append(Data(repeating: 2, count: 200))
    recording.append(Data(repeating: 3, count: 200))
    #expect(recording.data.count == 320)
    #expect(recording.data.last == 2)
}

@Test func pcmConversionResamplesAndMixesChannels() {
    func pcm(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
    func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
    }
    // Same format: untouched.
    let mono = pcm([1, 2, 3])
    #expect(PCM16Conversion.convert(mono, from: .speech16k, to: .speech16k) == mono)
    // 48 kHz stereo → 16 kHz mono: channels averaged, every third frame (plus interpolation).
    let stereo = pcm([100, 300, -200, -400, 1000, 1000, 30, 50, 0, 0, 0, 0])
    let down = samples(PCM16Conversion.convert(stereo, from: PCMFormat(sampleRate: 48_000, channels: 2), to: .speech16k))
    #expect(down == [200, 40])
    // 8 kHz → 16 kHz doubles the samples with midpoints; mono → stereo duplicates.
    let up = samples(PCM16Conversion.convert(pcm([0, 100, 200]), from: PCMFormat(sampleRate: 8_000), to: .speech16k))
    #expect(up == [0, 50, 100, 150, 200, 200])
    let wide = samples(PCM16Conversion.convert(pcm([7, -7]), from: .speech16k, to: PCMFormat(sampleRate: 16_000, channels: 2)))
    #expect(wide == [7, 7, -7, -7])
    // Extremes survive; a trailing odd byte is dropped.
    var odd = pcm([Int16.max, Int16.min])
    odd.append(0x7F)
    #expect(samples(PCM16Conversion.convert(odd, from: .speech16k, to: PCMFormat(sampleRate: 16_000, channels: 2)))
        == [Int16.max, Int16.max, Int16.min, Int16.min])
}
