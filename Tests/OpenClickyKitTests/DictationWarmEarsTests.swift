import Foundation
import Testing
@testable import OpenClickyKit

/// Dictation on `VoiceEars` (#26): the speech session opens at key-down with the mic, audio spoken while the
/// connection opens reaches it in order, a warm connection is taken over, and a refused account falls back.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DictationWarmEarsTests {
    /// A streaming client that takes `connectDelay` to connect (unless a warm connection opened for the same language
    /// and keywords is ready, as Gemini Live's is), counts warm-ups, and records every chunk its sessions get, in order.
    final class SlowWarmSTT: SpeechToTextWarming, @unchecked Sendable {
        let connectDelay: Duration
        let words: String
        private let lock = NSLock()
        private var _warm: [String]?
        private var _warmUps = 0
        private var _starts: [Bool] = []
        private(set) var sessions: [ScriptedSTTSession] = []

        init(connectDelay: Duration, words: String) {
            self.connectDelay = connectDelay
            self.words = words
        }

        var inputFormat: PCMFormat { .speech16k }
        var warmUps: Int { lock.withLock { _warmUps } }
        /// For each session: whether it took a warm connection.
        var starts: [Bool] { lock.withLock { _starts } }
        var lastSession: ScriptedSTTSession? { lock.withLock { sessions.last } }

        func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
            let key = [language ?? ""] + keywords
            let warm = lock.withLock { () -> Bool in
                defer { _warm = nil }
                return _warm == key
            }
            if !warm { try await Task.sleep(for: connectDelay) }
            let session = ScriptedSTTSession(script: [.final(words)])
            lock.withLock {
                sessions.append(session)
                _starts.append(warm)
            }
            return session
        }

        func warmUp(language: String?, keywords: [String]) async {
            lock.withLock {
                _warmUps += 1
                _warm = [language ?? ""] + keywords
            }
        }
        func waitUntilWarm(language: String?, keywords: [String]) async -> Bool { lock.withLock { _warm != nil } }
        func discardWarmSocket() async { lock.withLock { _warm = nil } }
    }

    /// A mic that yields numbered chunks: `early` at once (spoken before any connection is up), then `late` more.
    final class NumberedMic: DictationAudioInput, @unchecked Sendable {
        let early: Int
        let late: Int
        let chunkSize: Int
        private let lock = NSLock()
        private var continuation: AsyncStream<Data>.Continuation?
        private var feeder: Task<Void, Never>?

        init(early: Int = 5, late: Int = 5, chunkSize: Int = 3_200) {
            self.early = early
            self.late = late
            self.chunkSize = chunkSize
        }

        /// What the mic sent, back to back.
        var expected: Data { (0..<(early + late)).reduce(into: Data()) { $0.append(Self.chunk($1, size: chunkSize)) } }

        static func chunk(_ index: Int, size: Int) -> Data { Data(repeating: UInt8(index % 250 + 1), count: size) }

        func start(format: PCMFormat) async throws -> AsyncStream<Data> {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            for index in 0..<early { continuation.yield(Self.chunk(index, size: chunkSize)) }
            let early = early, late = late, size = chunkSize
            let feeder = Task {
                for index in early..<(early + late) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continuation.yield(Self.chunk(index, size: size))
                }
            }
            lock.withLock {
                self.continuation = continuation
                self.feeder = feeder
            }
            return stream
        }

        func stop() async {
            let (continuation, feeder) = lock.withLock { (self.continuation, self.feeder) }
            await feeder?.value
            continuation?.finish()
        }
    }

    static func controller(_ ears: VoiceEars, mic: NumberedMic, system: FakeInsertionSystem,
                           reports: @escaping (DictationSessionReport) -> Void) -> DictationController {
        let focus = makeFocus("")
        system.focus = focus
        system.values["field-1"] = ""
        system.selections["field-1"] = UTF16Range(location: 0, length: 0)
        let services = DictationController.Services(
            focus: FixedFocusReader(focus: focus), audio: mic, speechToText: { ears },
            cleaner: { nil }, inserter: TextInserter(system: system, pasteRestoreDelay: 0), language: "en",
            learnCorrections: false, finalTranscriptTimeout: 10, resultDisplaySeconds: 60)
        let controller = DictationController(services: services)
        controller.onSessionFinished = reports
        return controller
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func audioSpokenWhileTheConnectionOpensReachesItInOrder() async throws {
        let stt = SlowWarmSTT(connectDelay: .milliseconds(250), words: "meet me at noon")
        let ears = VoiceEars(primary: .init(name: "stt", client: stt))
        let mic = NumberedMic()
        let system = FakeInsertionSystem()
        var reports: [DictationSessionReport] = []
        let controller = Self.controller(ears, mic: mic, system: system) { reports.append($0) }

        controller.begin()
        // Let the late chunks arrive too, then let go.
        try await Task.sleep(for: .milliseconds(150))
        controller.commit()
        #expect(await Self.waitUntil { !reports.isEmpty })
        let session = try #require(stt.lastSession)
        #expect(session.audio == mic.expected)  // every chunk, in the order spoken, the early ones held for the connection
        #expect(reports.first?.rawTranscript == "meet me at noon")
        #expect(reports.first?.result == .typed(appName: "TextEdit"))
        let report = try #require(await ears.lastReport)
        #expect(!report.warm)
        #expect(report.audioSeconds > 0.9)
    }

    @Test func aDictationUsedRecentlyTakesTheWarmConnection() async throws {
        let stt = SlowWarmSTT(connectDelay: .milliseconds(250), words: "hello there")
        let ears = VoiceEars(primary: .init(name: "stt", client: stt), usage: .memory(Date()))
        // What the app does at launch: the warm socket opens for dictation's language and keyterms.
        await ears.expect(language: "en", keywords: DictationVocabulary().keyterms(seeds: DictationController.Services.defaultKeytermSeeds))
        await ears.refresh(.launch)
        #expect(stt.warmUps == 1)
        let mic = NumberedMic(early: 2, late: 2)
        var reports: [DictationSessionReport] = []
        let controller = Self.controller(ears, mic: mic, system: FakeInsertionSystem()) { reports.append($0) }
        controller.begin()
        try await Task.sleep(for: .milliseconds(80))
        controller.commit()
        #expect(await Self.waitUntil { !reports.isEmpty })
        #expect(stt.starts == [true])  // no connect wait: the press landed on the warm connection
        #expect(stt.lastSession?.audio == mic.expected)
        // After the press the ears open the next connection ahead of time.
        #expect(await Self.waitUntil { stt.warmUps >= 2 })
        await ears.shutDown()
    }

    /// Without being told dictation's keyterms, the launch socket is opened for none and the first press can't use it.
    @Test func aWarmSocketForOtherKeywordsIsNotTaken() async throws {
        let stt = SlowWarmSTT(connectDelay: .milliseconds(100), words: "hello there")
        let ears = VoiceEars(primary: .init(name: "stt", client: stt), usage: .memory(Date()))
        await ears.refresh(.launch)
        let mic = NumberedMic(early: 2, late: 2)
        var reports: [DictationSessionReport] = []
        let controller = Self.controller(ears, mic: mic, system: FakeInsertionSystem()) { reports.append($0) }
        controller.begin()
        try await Task.sleep(for: .milliseconds(80))
        controller.commit()
        #expect(await Self.waitUntil { !reports.isEmpty })
        #expect(stt.starts == [false])
        #expect(stt.lastSession?.audio == mic.expected)
        await ears.shutDown()
    }

    @Test func aRefusedAccountFallsBackAndTheTextIsStillTyped() async throws {
        final class Refused: SpeechToTextClient, @unchecked Sendable {
            var inputFormat: PCMFormat { .speech16k }
            func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
                throw ProviderError(provider: "stt", status: 402, message: "Insufficient credits")
            }
        }
        let fallback = FixedBatch(text: "dictated by the fallback")
        let ears = VoiceEars(primary: .init(name: "stt", client: Refused()),
                             fallbacks: [.init(name: "on device", client: fallback, sharesPrimaryAccount: false)])
        let mic = NumberedMic()
        let system = FakeInsertionSystem()
        var reports: [DictationSessionReport] = []
        let controller = Self.controller(ears, mic: mic, system: system) { reports.append($0) }
        controller.begin()
        try await Task.sleep(for: .milliseconds(120))
        controller.commit()
        #expect(await Self.waitUntil { !reports.isEmpty })
        #expect(reports.first?.rawTranscript == "dictated by the fallback")
        #expect(reports.first?.result == .typed(appName: "TextEdit"))
        #expect(fallback.heardBytes == mic.expected.count)  // the whole press, kept while the stream failed
        #expect(await ears.isRefusing())  // later dictations avoid the refusing account for ten minutes
        #expect(await ears.lastReport?.outcome == .fallback)
    }
}

/// A batch recognizer that always hears `text` and records how much audio it got.
final class FixedBatch: SpeechToTextBatchClient, @unchecked Sendable {
    let text: String
    private let lock = NSLock()
    private var bytes = 0
    init(text: String) { self.text = text }
    var heardBytes: Int { lock.withLock { bytes } }
    func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String {
        lock.withLock { bytes += audio.pcm.count }
        return text
    }
}
