import Foundation
import Testing
@testable import OpenClickyKit

/// The voice loop's ears (`VoiceEars`): streamed presses, the kept press audio and its fallbacks, the ten-minute
/// switch after a billing refusal, the warm connection and the per-press report. Scripted recognizers only.
@Suite(.timeLimit(.minutes(1)))
struct VoiceEarsTests {
    // MARK: Fakes

    /// Counts sessions and the audio each one got, around another client.
    final class CountingSTT: SpeechToTextClient, @unchecked Sendable {
        let inner: any SpeechToTextClient
        private let lock = NSLock()
        private var sessions: [RecordingSession] = []

        init(_ inner: any SpeechToTextClient) { self.inner = inner }

        var inputFormat: PCMFormat { inner.inputFormat }
        var starts: Int { lock.withLock { sessions.count } }
        var bytesSent: Int { lock.withLock { sessions.reduce(0) { $0 + $1.bytes } } }

        func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
            let placeholder = RecordingSession(nil)
            lock.withLock { sessions.append(placeholder) }
            placeholder.inner = try await inner.startSession(language: language, keywords: keywords)
            return placeholder
        }
    }

    final class RecordingSession: SpeechToTextSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _inner: (any SpeechToTextSession)?
        private var _bytes = 0
        init(_ inner: (any SpeechToTextSession)?) { _inner = inner }
        var inner: (any SpeechToTextSession)? {
            get { lock.withLock { _inner } }
            set { lock.withLock { _inner = newValue } }
        }
        var bytes: Int { lock.withLock { _bytes } }
        var events: AsyncThrowingStream<TranscriptEvent, Error> { inner!.events }
        func send(_ pcm: Data) async {
            lock.withLock { _bytes += pcm.count }
            await inner?.send(pcm)
        }
        func finish() async { await inner?.finish() }
        func cancel() async { await inner?.cancel() }
    }

    /// A batch recognizer that answers with `text` or throws, and records what it got.
    final class FakeBatch: SpeechToTextBatchClient, @unchecked Sendable {
        let result: Result<String, Error>
        let delay: Duration
        private let lock = NSLock()
        private var heard: [DecodedAudio] = []
        init(_ result: Result<String, Error>, delay: Duration = .zero) {
            self.result = result
            self.delay = delay
        }
        var calls: [DecodedAudio] { lock.withLock { heard } }
        func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String {
            lock.withLock { heard.append(audio) }
            if delay > .zero { try await Task.sleep(for: delay) }
            return try result.get()
        }
    }

    /// A streaming client that can open a connection ahead of key-down.
    final class WarmingSTT: SpeechToTextWarming, @unchecked Sendable {
        let inner: SimulatedSpeechToText
        init(_ inner: SimulatedSpeechToText = SimulatedSpeechToText(text: "hello", chunksPerWord: 1)) { self.inner = inner }
        private let lock = NSLock()
        private var _warmUps = 0
        private var _discards = 0
        private var _margins: [Duration] = []
        var inputFormat: PCMFormat { inner.inputFormat }
        var warmUps: Int { lock.withLock { _warmUps } }
        /// The replacement margins the timer's refreshes asked for.
        var margins: [Duration] { lock.withLock { _margins } }
        var discards: Int { lock.withLock { _discards } }
        func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
            try await inner.startSession(language: language, keywords: keywords)
        }
        func warmUp(language: String?, keywords: [String]) async { lock.withLock { _warmUps += 1 } }
        func warmUp(language: String?, keywords: [String], replacingWithin margin: Duration) async {
            lock.withLock {
                _warmUps += 1
                _margins.append(margin)
            }
        }
        func waitUntilWarm(language: String?, keywords: [String]) async -> Bool { warmUps > 0 }
        func discardWarmSocket() async { lock.withLock { _discards += 1 } }
    }

    /// A session whose `startedWarm` waits until the test releases it, and which records whether it was closed.
    final class GatedSession: SpeechToTextSessionReadiness, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Bool, Never>?
        private var released = false
        private var _cancelled = false
        init() { (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream() }
        var isWaiting: Bool { lock.withLock { waiting != nil } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        var startedWarm: Bool {
            get async {
                await withCheckedContinuation { gate in
                    let open = lock.withLock { () -> Bool in
                        if !released { waiting = gate }
                        return released
                    }
                    if open { gate.resume(returning: true) }
                }
            }
        }
        func release() {
            let gate = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                released = true
                defer { waiting = nil }
                return waiting
            }
            gate?.resume(returning: true)
        }
        func waitUntilReady() async -> Bool { true }
        func send(_ pcm: Data) async {}
        func finish() async { continuation.finish() }
        func cancel() async {
            lock.withLock { _cancelled = true }
            continuation.finish()
        }
    }

    final class GatedSTT: SpeechToTextClient, @unchecked Sendable {
        let session = GatedSession()
        var inputFormat: PCMFormat { .speech16k }
        func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession { session }
    }

    /// A clock the test moves.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 2_000_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    static func ears(_ primary: any SpeechToTextClient, alternate: (any SpeechToTextClient)? = nil, fallbacks: [VoiceEars.Fallback] = [],
                     policy: VoiceEars.Policy = .init(finalTimeout: .seconds(3)), usage: VoiceEars.UsageStore = .memory(),
                     clock: TestClock? = nil) -> VoiceEars {
        let now: @Sendable () -> Date
        if let clock { now = { clock.now } } else { now = { Date() } }
        return VoiceEars(primary: .init(name: "primary", client: primary), alternate: alternate.map { .init(name: "alternate", client: $0) },
                         fallbacks: fallbacks, policy: policy, usage: usage, now: now)
    }

    /// One press: `chunks` tenth-of-a-second chunks of silence, then key-up. Returns the events and the report.
    static func press(_ ears: VoiceEars, chunks: Int = 5) async throws -> (events: [TranscriptEvent], error: Error?, report: EarsPressReport) {
        let session = try await ears.startSession(language: "en-US", keywords: ["OpenClicky"])
        let collector = Task { () -> ([TranscriptEvent], Error?) in
            var seen: [TranscriptEvent] = []
            do {
                for try await event in session.events { seen.append(event) }
                return (seen, nil)
            } catch {
                return (seen, error)
            }
        }
        for _ in 0..<chunks {
            await session.send(Data(count: PCMFormat.speech16k.bytesPerSecond / 10))
            try await Task.sleep(for: .milliseconds(5))
        }
        await session.finish()
        let (events, error) = await collector.value
        let report = try #require(await (session as? any EarsPressReporting)?.pressReport())
        return (events, error, report)
    }

    static func finals(_ events: [TranscriptEvent]) -> [String] {
        events.compactMap { if case .final(let text) = $0 { text } else { nil } }
    }

    static func interims(_ events: [TranscriptEvent]) -> [String] {
        events.compactMap { if case .interim(let text) = $0 { text } else { nil } }
    }

    // MARK: Streamed presses

    @Test func aStreamedPressGivesTheRunningTranscriptThenOneFinal() async throws {
        let ears = Self.ears(SimulatedSpeechToText(text: "open the settings", chunksPerWord: 1))
        let (events, error, report) = try await Self.press(ears)
        #expect(error == nil)
        #expect(Self.interims(events) == ["open", "open the", "open the settings"])
        #expect(Self.finals(events) == ["open the settings"])
        #expect(report.outcome == .streamed)
        #expect(report.recognizer == "primary")
        #expect(!report.warm)
        #expect(report.connectedAt != nil && report.readyAt != nil && report.firstTextAt != nil)
        #expect(report.finishAt != nil && report.finalAt != nil)
        #expect(abs(report.audioSeconds - 0.5) < 0.01)
        #expect(report.fallback == nil && report.streamError == nil)
        #expect(await ears.lastReport?.outcome == .streamed)
        let line = report.logLine(heldMs: 500, releaseToWordsMs: 30)
        #expect(line.hasPrefix("ears: warm=no outcome=streamed"))
        #expect(line.contains("held_ms=500") && line.contains("release_to_words_ms=30") && line.contains("keydown_to_first_text_ms="))
    }

    @Test func audioSentWhileTheStreamConnectsIsHeldAndSentInOrder() async throws {
        let counting = CountingSTT(SimulatedSpeechToText(text: "one two three", chunksPerWord: 1))
        let ears = Self.ears(counting)
        let (events, _, report) = try await Self.press(ears, chunks: 6)
        #expect(Self.finals(events) == ["one two three"])
        #expect(counting.bytesSent == 6 * PCMFormat.speech16k.bytesPerSecond / 10)
        #expect(report.outcome == .streamed)
    }

    @Test func aPressWithNothingSaidIsSilent() async throws {
        let ears = Self.ears(SimulatedSpeechToText(text: ""), fallbacks: [.init(name: "batch", client: FakeBatch(.success("ghost")), sharesPrimaryAccount: true)])
        let (events, error, report) = try await Self.press(ears)
        #expect(error == nil && Self.finals(events).isEmpty)
        #expect(report.outcome == .silent)
        #expect(report.fallback == nil)  // a healthy stream that heard nothing is trusted
    }

    // MARK: Fallbacks

    @Test func aStreamThatFailsToStartIsHeardFromTheKeptAudio() async throws {
        let batch = FakeBatch(.success("what is this button"))
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("network is down")),
                             fallbacks: [.init(name: "gemini batch", client: batch, sharesPrimaryAccount: true)])
        let (events, error, report) = try await Self.press(ears, chunks: 7)
        #expect(error == nil)
        #expect(Self.finals(events) == ["what is this button"])
        #expect(report.outcome == .fallback)
        #expect(report.fallback == "gemini batch")
        #expect(report.fallbackMs != nil)
        #expect(report.streamError?.contains("network is down") == true)
        let heard = try #require(batch.calls.first)
        #expect(heard.format == .speech16k)
        #expect(abs(heard.duration - 0.7) < 0.01)  // the whole press, kept while the stream was down
        #expect(!report.startedRefusalSwitch)
        #expect(!(await ears.isRefusing()))
    }

    @Test func aStreamThatNeverSettlesGoesToTheFallbackAfterTheFinalTimeout() async throws {
        let batch = FakeBatch(.success("turn it up"))
        let ears = Self.ears(SimulatedSpeechToText(text: "turn it", behavior: .neverFinish, chunksPerWord: 1),
                             fallbacks: [.init(name: "batch", client: batch, sharesPrimaryAccount: true)],
                             policy: .init(finalTimeout: .milliseconds(200)))
        let (events, _, report) = try await Self.press(ears)
        #expect(Self.finals(events) == ["turn it up"])
        #expect(report.outcome == .fallback)
        #expect((report.finishToFinalMs ?? 0) >= 200)
        #expect(report.streamError?.contains("no settled transcript") == true)
    }

    @Test func fallbacksAreTriedInOrderAndAFailedOneIsNoted() async throws {
        let first = FakeBatch(.failure(ProviderError(provider: "gemini", status: 503, message: "overloaded")))
        let second = FakeBatch(.success("hello there"))
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("socket closed")),
                             fallbacks: [.init(name: "first", client: first, sharesPrimaryAccount: true),
                                         .init(name: "second", client: second, sharesPrimaryAccount: false)])
        let (events, _, report) = try await Self.press(ears)
        #expect(Self.finals(events) == ["hello there"])
        #expect(first.calls.count == 1 && second.calls.count == 1)
        #expect(report.fallback == "second")
        #expect(report.streamError?.contains("fallback first") == true)
    }

    @Test func aSlowFallbackIsCutOffByTheFallbackTimeout() async throws {
        // The fallback would take a minute; the bound is far below that but loose enough for a very busy machine.
        let slow = FakeBatch(.success("too late"), delay: .seconds(60))
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("down")),
                             fallbacks: [.init(name: "slow", client: slow, sharesPrimaryAccount: true)],
                             policy: .init(finalTimeout: .seconds(3), fallbackTimeout: .milliseconds(150)))
        let started = Date()
        let (_, error, report) = try await Self.press(ears)
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(error != nil)
        #expect(report.outcome == .failed)
    }

    @Test func whenEverythingFailsTheWordsTheStreamHadAreKept() async throws {
        let ears = Self.ears(SimulatedSpeechToText(text: "draw a cat", behavior: .dropAtFinish("connection reset"), chunksPerWord: 1),
                             fallbacks: [.init(name: "batch", client: FakeBatch(.failure(URLError(.timedOut))), sharesPrimaryAccount: true)])
        let (events, error, report) = try await Self.press(ears)
        #expect(error == nil)
        #expect(Self.finals(events) == ["draw a cat"])
        #expect(report.outcome == .partial)
    }

    @Test func withNoWordsAndNoWorkingFallbackThePressFails() async throws {
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("connection refused")),
                             fallbacks: [.init(name: "batch", client: FakeBatch(.failure(URLError(.notConnectedToInternet))), sharesPrimaryAccount: true)])
        let (events, error, report) = try await Self.press(ears)
        #expect(Self.finals(events).isEmpty)
        #expect(String(describing: try #require(error)).contains("connection refused"))
        #expect(report.outcome == .failed)
    }

    // MARK: Refusal switch

    @Test func aBillingRefusalSwitchesPressesToTheAlternateForTenMinutes() async throws {
        let clock = TestClock()
        let primary = CountingSTT(SimulatedSpeechToText(text: "", behavior: .failToStart("RESOURCE_EXHAUSTED: You exceeded your current quota, check your billing")))
        let alternate = CountingSTT(SimulatedSpeechToText(text: "second press", chunksPerWord: 1))
        let sameAccount = FakeBatch(.success("never asked"))
        let onDevice = FakeBatch(.success("first press"))
        let ears = Self.ears(primary, alternate: alternate,
                             fallbacks: [.init(name: "gemini batch", client: sameAccount, sharesPrimaryAccount: true),
                                         .init(name: "on device", client: onDevice, sharesPrimaryAccount: false)],
                             clock: clock)

        let first = try await Self.press(ears)
        #expect(Self.finals(first.events) == ["first press"])
        #expect(first.report.outcome == .fallback && first.report.fallback == "on device")
        #expect(first.report.startedRefusalSwitch)
        #expect(sameAccount.calls.isEmpty)  // the same account would refuse too
        #expect(await ears.isRefusing())

        clock.advance(9 * 60)
        let second = try await Self.press(ears)
        #expect(Self.finals(second.events) == ["second press"])
        #expect(second.report.outcome == .switched)
        #expect(second.report.recognizer == "alternate")
        #expect(primary.starts == 1 && alternate.starts == 1)

        clock.advance(61)
        #expect(!(await ears.isRefusing()))
        _ = try await Self.press(ears)
        #expect(primary.starts == 2)  // back on the stt slot
    }

    @Test func aRefusalFromTheSameAccountBatchAlsoSwitches() async throws {
        let refused = FakeBatch(.failure(ProviderError(provider: "gemini", status: 402, message: "Payment required")))
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("socket closed: 1011")),
                             fallbacks: [.init(name: "gemini batch", client: refused, sharesPrimaryAccount: true),
                                         .init(name: "on device", client: FakeBatch(.success("heard it")), sharesPrimaryAccount: false)])
        let (_, _, report) = try await Self.press(ears)
        #expect(report.fallback == "on device")
        #expect(report.startedRefusalSwitch)
        #expect(await ears.isRefusing())
    }

    /// A streaming client whose sessions fail to start with `error`.
    final class FailingSTT: SpeechToTextClient, @unchecked Sendable {
        let error: Error
        private let lock = NSLock()
        private var _starts = 0
        init(_ error: Error) { self.error = error }
        var inputFormat: PCMFormat { .speech16k }
        var starts: Int { lock.withLock { _starts } }
        func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
            lock.withLock { _starts += 1 }
            throw error
        }
    }

    @Test func aRegionRefusalSwitchesPressesToTheAlternateForTenMinutesToo() async throws {
        let clock = TestClock()
        // What the diagnostician makes of an OpenAI-style 403 from a country it doesn't serve.
        let diagnosis = ProviderDiagnosis(providerID: "gemini", providerName: "Gemini", host: "generativelanguage.googleapis.com",
                                          purpose: .listening, verdict: .regionUnsupported, probe: "403", failure: "socket closed")
        let refused = ProviderUnavailableError(diagnosis: diagnosis, underlying: "1007 User location is not supported")
        let primary = FailingSTT(refused)
        let alternate = CountingSTT(SimulatedSpeechToText(text: "second press", chunksPerWord: 1))
        let sameAccount = FakeBatch(.success("never asked"))
        let ears = Self.ears(primary, alternate: alternate,
                             fallbacks: [.init(name: "gemini batch", client: sameAccount, sharesPrimaryAccount: true),
                                         .init(name: "on device", client: FakeBatch(.success("first press")), sharesPrimaryAccount: false)],
                             clock: clock)
        let first = try await Self.press(ears)
        #expect(Self.finals(first.events) == ["first press"])
        #expect(first.report.startedRefusalSwitch)
        #expect(sameAccount.calls.isEmpty)
        #expect(await ears.isRefusing())

        clock.advance(9 * 60)
        let second = try await Self.press(ears)
        #expect(second.report.outcome == .switched && second.report.recognizer == "alternate")
        #expect(primary.starts == 1)
        clock.advance(61)
        #expect(!(await ears.isRefusing()))
    }

    @Test func regionRefusalsAreToldApartFromOtherFailures() {
        let region = ProviderDiagnosis(providerID: "openai", providerName: "OpenAI", host: "api.openai.com", purpose: .listening,
                                       verdict: .regionUnsupported, probe: nil, failure: "")
        let outage = ProviderDiagnosis(providerID: "openai", providerName: "OpenAI", host: "api.openai.com", purpose: .listening,
                                       verdict: .providerDown, probe: nil, failure: "")
        #expect(SpeechRefusal.isRegionRefusal(ProviderUnavailableError(diagnosis: region, underlying: "403")))
        #expect(!SpeechRefusal.isRegionRefusal(ProviderUnavailableError(diagnosis: outage, underlying: "503")))
        #expect(SpeechRefusal.isRegionRefusal(ProviderError(provider: "x", status: 451, message: "")))
        #expect(SpeechRefusal.isRegionRefusal(ProviderError(provider: "x", status: 403, message: "Country, region, or territory not supported")))
        #expect(!SpeechRefusal.isRegionRefusal(ProviderError(provider: "x", status: 403, message: "Invalid API key")))
        #expect(SpeechRefusal.switchesSlot(ProviderError(provider: "x", status: 402, message: "")))
        #expect(!SpeechRefusal.switchesSlot(URLError(.timedOut)))
    }

    @Test func refusalsAreToldApartFromOtherFailures() {
        #expect(SpeechRefusal.isAccountRefusal(ProviderError(provider: "x", status: 402, message: "")))
        #expect(SpeechRefusal.isAccountRefusal(ProviderError(provider: "x", status: 429, message: "Quota exceeded for this project")))
        #expect(SpeechRefusal.isAccountRefusal(ProviderError(provider: "x", message: "Your credit balance is too low")))
        #expect(SpeechRefusal.isAccountRefusal(ProviderError(provider: "x", message: "prepayment credits are depleted")))
        #expect(!SpeechRefusal.isAccountRefusal(ProviderError(provider: "x", status: 503, message: "The service is unavailable")))
        #expect(!SpeechRefusal.isAccountRefusal(URLError(.timedOut)))
    }

    // MARK: Alternate formats

    @Test func audioForARecognizerWithAnotherRateIsConverted() async throws {
        let clock = TestClock()
        let alternate = CountingSTT(SimulatedSpeechToText(text: "hi", inputFormat: PCMFormat(sampleRate: 8_000), chunksPerWord: 1))
        let ears = Self.ears(SimulatedSpeechToText(text: "", behavior: .failToStart("quota exhausted")), alternate: alternate,
                             fallbacks: [.init(name: "on device", client: FakeBatch(.success("x")), sharesPrimaryAccount: false)], clock: clock)
        _ = try await Self.press(ears)  // refused: switches
        let (events, _, report) = try await Self.press(ears, chunks: 4)
        #expect(report.outcome == .switched && Self.finals(events) == ["hi"])
        #expect(abs(alternate.bytesSent - 4 * PCMFormat(sampleRate: 8_000).bytesPerSecond / 10) <= 8)
    }

    // MARK: Warm connection

    @Test func theConnectionIsKeptWarmOnlyWhileTheEarsAreInUse() async throws {
        let clock = TestClock()
        let stale = WarmingSTT()
        let idle = Self.ears(stale, usage: .memory(clock.now.addingTimeInterval(-20 * 60)), clock: clock)
        await idle.refresh(.launch)
        #expect(stale.warmUps == 0)  // last used 20 minutes ago

        let recent = WarmingSTT()
        let ears = Self.ears(recent, usage: .memory(clock.now.addingTimeInterval(-60)), clock: clock)
        await ears.refresh(.launch)
        #expect(recent.warmUps == 1)
        await ears.refresh(.wake)
        #expect(recent.warmUps == 2)
        let (_, _, report) = try await Self.press(ears)
        #expect(report.outcome == .streamed)
        #expect(await Self.eventually { recent.warmUps == 3 })  // ready for the next press, after the turn has its words
        await ears.shutDown()
        #expect(recent.discards == 1)
    }

    @Test func theWarmConnectionIsRefreshedOnATimerAndDroppedAfterARefusal() async throws {
        let warming = WarmingSTT()
        let ears = Self.ears(warming, policy: .init(rewarmInterval: .milliseconds(40)), usage: .memory(Date()))
        await ears.refresh(.launch)
        #expect(await Self.eventually { warming.warmUps >= 3 })
        await ears.shutDown()
        let settled = warming.warmUps
        try await Task.sleep(for: .milliseconds(150))
        #expect(warming.warmUps == settled)

        let refused = WarmingSTT(SimulatedSpeechToText(text: "", behavior: .failToStart("billing account is not active")))
        let switching = Self.ears(refused, usage: .memory(Date()))
        await switching.refresh(.launch)
        #expect(refused.warmUps == 1)
        _ = try await Self.press(switching)
        #expect(await switching.isRefusing())
        #expect(await Self.eventually { refused.discards == 1 })
        await switching.refresh(.wake)
        #expect(refused.warmUps == 1)  // no warm connection on a refusing account
    }

    /// Review fix: the timer only reopened a connection the provider had already closed, so the one opened after a
    /// press (two-minute lifetime, one-minute ticks) expired up to a tick before it was replaced.
    @Test func theTimerReplacesAConnectionThatWouldCloseBeforeTheNextTick() async throws {
        let warming = WarmingSTT()
        let ears = Self.ears(warming, policy: .init(rewarmInterval: .milliseconds(40)), usage: .memory(Date()))
        await ears.refresh(.launch)
        #expect(await Self.eventually { warming.margins.count >= 2 })
        await ears.shutDown()
        #expect(warming.margins.allSatisfy { $0 > .milliseconds(40) })
        #expect(VoiceEars.rewarmMargin(.seconds(60)) == .seconds(75))
    }

    @Test func warmUpNowWarmsWhateverTheLastUseAndWaitsUntilReady() async throws {
        let warming = WarmingSTT()
        let ears = Self.ears(warming)
        #expect(await ears.warmUpNow(waitUntilReady: true))
        #expect(warming.warmUps == 1)
        await ears.shutDown()
    }

    static func eventually(within limit: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: Cancelling

    @Test func aCancelledPressEndsQuietlyAndIsReported() async throws {
        let ears = Self.ears(SimulatedSpeechToText(text: "never mind", chunksPerWord: 1))
        let session = try await ears.startSession(language: nil, keywords: [])
        await session.send(Data(count: 3_200))
        await session.cancel()
        var count = 0
        for try await _ in session.events { count += 1 }
        let report = try #require(await (session as? any EarsPressReporting)?.pressReport())
        #expect(report.outcome == .cancelled)
        #expect(await ears.lastReport?.outcome == .cancelled)
    }

    /// Review fix: a press cancelled while the recognizer's session was being set up (here, while asking whether it
    /// started warm) left that session open, because cancel() only closes a session the press already holds.
    @Test func aPressCancelledWhileItsSessionIsSetUpClosesThatSession() async throws {
        let recognizer = GatedSTT()
        let ears = Self.ears(recognizer)
        let session = try await ears.startSession(language: nil, keywords: [])
        await session.send(Data(count: 3_200))
        #expect(await Self.eventually { recognizer.session.isWaiting })
        await session.cancel()
        recognizer.session.release()
        #expect(await Self.eventually { recognizer.session.cancelled })
        let report = try #require(await (session as? any EarsPressReporting)?.pressReport())
        #expect(report.outcome == .cancelled)
    }

    // MARK: Building

    @Test func theFactoryBuildsEarsWithTheSlotsBatchSideAndTheOnDeviceFallback() throws {
        var config = OpenClickyConfig.heyClickyLike
        config.providers.append(ProviderConfig(id: "gemini-live", dialect: .geminiLive,
                                               baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta"), credential: "gemini"))
        config.slots[.stt] = SlotSelection(provider: "gemini-live", model: "gemini-3.5-transcribe-live")
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore(["gemini": "AIza-test"]),
                                    http: FakeHTTPTransport([]), webSocket: FakeWebSocket())
        let batch = try factory.speechToTextBatch()
        #expect((batch as? GeminiTranscriptionClient)?.model == "gemini-3.5-transcribe")
        let ears = try VoiceEars.make(factory: factory, onDevice: SimulatedSpeechToText(text: ""))
        #expect(ears.primary.name == "gemini-live / gemini-3.5-transcribe-live")
        #expect(ears.primary.client is GeminiLiveSpeechToTextClient)
        #expect(ears.alternate?.name == "Apple Speech (on device)")
        #expect(ears.inputFormat == .speech16k)
    }
}
