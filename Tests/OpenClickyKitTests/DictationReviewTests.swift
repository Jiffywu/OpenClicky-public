import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests from the review of the dictation branch.

/// A speech session that reports some words and then closes cleanly on its own, before any audio is finished.
private final class EarlyEndingSpeechToText: SpeechToTextClient, @unchecked Sendable {
    let heard: String
    init(heard: String) { self.heard = heard }
    var inputFormat: PCMFormat { .speech16k }

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        Session(heard: heard)
    }

    final class Session: SpeechToTextSession, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        init(heard: String) {
            let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
            continuation.yield(.final(heard))
            continuation.finish()
            events = stream
        }
        func send(_ pcm: Data) async {}
        func finish() async {}
        func cancel() async {}
    }
}

/// A session that drops with an error after some words, and whose `finish()` then waits until it is cancelled.
private final class DroppingThenHangingSpeechToText: SpeechToTextClient, @unchecked Sendable {
    let lock = NSLock()
    private(set) var sessions: [Session] = []
    var inputFormat: PCMFormat { .speech16k }

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let session = Session()
        lock.withLock { sessions.append(session) }
        return session
    }

    final class Session: SpeechToTextSession, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        private let lock = NSLock()
        private var cancelledFlag = false
        var cancelled: Bool { lock.withLock { cancelledFlag } }

        init() {
            let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
            continuation.yield(.final("remember to call"))
            continuation.finish(throwing: ProviderError(provider: "stt", message: "connection lost"))
            events = stream
        }
        func send(_ pcm: Data) async {}
        func finish() async {
            while !cancelled { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func cancel() async { lock.withLock { cancelledFlag = true } }
    }
}

/// Key-down finds the app but no field; the second read finds `later`. Records which thread each read ran on.
private final class ThreadRecordingFocusReader: FocusReading, @unchecked Sendable {
    let lock = NSLock()
    private(set) var readsOnMainThread: [Bool] = []
    let later: CapturedFocus

    init(later: CapturedFocus) { self.later = later }

    func captureFocus() -> Result<CapturedFocus, FocusReadError> {
        let isFirst = lock.withLock {
            readsOnMainThread.append(Thread.isMainThread)
            return readsOnMainThread.count == 1
        }
        return isFirst ? .failure(.noFocusedElement(appName: later.context.appName, processID: later.context.processID))
            : .success(later)
    }
}

@MainActor
private func makeController(speech: any SpeechToTextClient, fallback: (any SpeechToTextClient)? = nil,
                            reader: (any FocusReading)? = nil, system: FakeInsertionSystem,
                            focus: CapturedFocus) -> (DictationController, AsyncStream<DictationSessionReport>) {
    system.focus = focus
    if let id = focus.element?.raw as? String { system.values[id] = focus.context.beforeText }
    let services = DictationController.Services(
        focus: reader ?? FixedFocusReader(focus: focus), audio: FakeMicrophone(chunks: 10, chunkSize: 1600),
        speechToText: { speech }, cleaner: { nil }, inserter: TextInserter(system: system, pasteRestoreDelay: 0),
        // Every session here ends by itself, so the final-transcript timeout only guards against a hang. A short one
        // would fire on a busy machine before the scripted words arrive.
        language: "en", learnCorrections: false, finalTranscriptTimeout: 10, resultDisplaySeconds: 60,
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

// MARK: The stt contract: finals carry their own spacing

@Test func theTranscriptConcatenatesFinalsAsTheyAreSpaced() {
    // Deepgram and Apple Speech give every final after the first its own leading space in spaced languages…
    #expect(DictationController.transcript(finals: ["Open Safari.", " Then turn on the lights."], interim: "") ==
        "Open Safari. Then turn on the lights.")
    // …and none in languages written without spaces, where adding one would be wrong.
    #expect(DictationController.transcript(finals: ["你好", "世界"], interim: "") == "你好世界")
    #expect(DictationController.transcript(finals: ["今日は", "いい天気です"], interim: "") == "今日はいい天気です")
    // An interim not yet settled follows the finals (the live caption), and stray whitespace collapses.
    #expect(DictationController.transcript(finals: ["send the"], interim: " report") == "send the report")
    #expect(DictationController.transcript(finals: [], interim: "  hello   there ") == "hello there")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func chineseFinalsAreTypedWithoutSpacesBetweenThem() async throws {
    let system = FakeInsertionSystem()
    let (controller, reports) = makeController(speech: ScriptedSpeechToText([.final("我们明天"), .final("下午开会")]),
                                               system: system, focus: makeFocus(""))
    controller.begin()
    try await Task.sleep(for: .milliseconds(30))
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.rawTranscript == "我们明天下午开会")
    #expect(system.values["field-1"] == "我们明天下午开会")
}

@Test func theFallbackJoinsItsFinalsTheSameWay() async throws {
    let (stream, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
    continuation.yield(.final("你好"))
    continuation.yield(.final("世界"))
    continuation.yield(.interim("！"))
    continuation.finish()
    #expect(try await DictationFallbackTranscription.collect(stream) == "你好世界！")
}

// MARK: A session that hangs up cleanly mid-press

@MainActor @Test(.timeLimit(.minutes(1)))
func aSessionThatClosesBeforeTheReleaseIsHeardByTheFallback() async throws {
    let system = FakeInsertionSystem()
    let fallback = ScriptedSpeechToText([.final("book the flight for Tuesday")])
    let (controller, reports) = makeController(speech: EarlyEndingSpeechToText(heard: "book the"), fallback: fallback,
                                               system: system, focus: makeFocus(""))
    let losses = speechSessionLosses(controller)
    controller.begin()
    // The session hangs up while the key is still held.
    try #require(await firstValue(losses) != nil)
    // The microphone stays open so the rest of the press is kept for the fallback.
    #expect(controller.isCapturing)
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.heardByFallback)
    #expect(report.rawTranscript == "book the flight for Tuesday")
    #expect(system.values["field-1"] == "Book the flight for Tuesday")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func withoutAFallbackASessionThatClosesEarlyStopsListeningAndTypesWhatItHeard() async throws {
    let system = FakeInsertionSystem()
    let (controller, reports) = makeController(speech: EarlyEndingSpeechToText(heard: "book the"), system: system,
                                               focus: makeFocus(""))
    controller.begin()
    // Nothing would hear the rest of the press, so dictation stops by itself instead of listening into the void.
    let report = try #require(await first(reports))
    #expect(!controller.isCapturing)
    #expect(report.rawTranscript == "book the")
    #expect(system.values["field-1"] == "Book the")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFailedSessionIsReleasedOnceTheDictationFinishes() async throws {
    let system = FakeInsertionSystem()
    let speech = DroppingThenHangingSpeechToText()
    let (controller, reports) = makeController(speech: speech, system: system, focus: makeFocus(""))
    controller.begin()
    let report = try #require(await first(reports))
    #expect(report.rawTranscript == "remember to call")
    // The dead session is cancelled, so the audio pump waiting on its finish() ends instead of leaking.
    let session = try #require(speech.sessions.first)
    for _ in 0..<100 where !session.cancelled { try await Task.sleep(for: .milliseconds(10)) }
    #expect(session.cancelled)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func wordsSpokenWhileSecureInputIsOnNeverReachTheCleanupModel() async throws {
    // Terminal's text area isn't a password field, but `sudo` turns on Secure Event Input while it asks.
    let system = FakeInsertionSystem()
    system.secureInput = true
    let focus = makeFocus("$ sudo ls\nPassword:", bundleID: "com.apple.Terminal", appName: "Terminal")
    system.focus = focus
    let model = RecordingLanguageModel(.reply("Hunter two is my password."))
    let services = DictationController.Services(
        focus: FixedFocusReader(focus: focus), audio: FakeMicrophone(),
        speechToText: { ScriptedSpeechToText([.final("hunter two is my password")]) },
        cleaner: { DictationCleaner(client: model, options: DictationCleanupOptions(model: "fast")) },
        inserter: TextInserter(system: system, pasteRestoreDelay: 0), learnCorrections: false, resultDisplaySeconds: 60)
    let controller = DictationController(services: services)
    let (reports, continuation) = AsyncStream<DictationSessionReport>.makeStream()
    controller.onSessionFinished = { continuation.yield($0) }
    controller.begin()
    try await Task.sleep(for: .milliseconds(30))
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.result == .refused(.secureEventInput))
    #expect(model.requests.isEmpty)
    #expect(system.fakePasteboard.string == nil)
}

// MARK: Accessibility reads stay off the main actor

@MainActor @Test(.timeLimit(.minutes(1)))
func theLateFocusReadRunsOffTheMainThread() async throws {
    let field = makeFocus("Hi ", appName: "Notes", pid: 42)
    let reader = ThreadRecordingFocusReader(later: field)
    let system = FakeInsertionSystem()
    let (controller, reports) = makeController(speech: ScriptedSpeechToText([.final("see you at noon")]), reader: reader,
                                               system: system, focus: field)
    controller.begin()
    try await Task.sleep(for: .milliseconds(30))
    controller.commit()
    let report = try #require(await first(reports))
    #expect(report.focus?.element != nil)
    #expect(system.values["field-1"] == "Hi see you at noon")
    // Both reads (key-down and the late one) happened off the main thread: a slow app can't freeze the HUD.
    #expect(reader.readsOnMainThread == [false, false])
}

// MARK: Cleanup clients

@Test func anthropicCleanupKeepsItsTurnsOutOfTheSharedThinkingStore() throws {
    let provider = ProviderConfig(id: "anthropic", dialect: .anthropicMessages, credential: "anthropic")
    let client = try #require(AdapterModelClientFactory(http: FakeHTTPTransport([]))
        .makeClient(provider: provider, apiKey: "placeholder") as? AnthropicMessagesClient)
    // Cleanup turns are never continued; recording them in the process-wide store would push out the brain's turns.
    #expect(client.thinkingReplay !== AnthropicThinkingReplay.shared)
    #expect(client.thinkingDisplay == "omitted")
}

@Test func anEmptyStoredCredentialMeansNoRealCleanupModel() {
    let provider = ProviderConfig(id: "openai", dialect: .openAIResponses, credential: "openai")
    let choice = DictationCleanupModelChoice(provider: provider, model: "gpt-5.4-mini", reasoningEffort: nil)
    let resolution = DictationCleanupClientResolver.resolve(choice: .success(choice), factory: AdapterModelClientFactory(),
                                                            credentials: InMemoryCredentialStore(["openai": ""]))
    #expect(!resolution.isReal)
    if case .fake(let reason) = resolution { #expect(reason.contains("openai")) }
}

// MARK: Learning from long dictations

@Test func aFixInALongDictationIsStillLearned() {
    // A long hands-free dictation with one fix near the end: only the changed middle is aligned.
    let filler = (0..<1_200).map { "word\($0)" }
    let inserted = (filler + ["ship", "it", "with", "open", "clicky", "today"]).joined(separator: " ")
    let edited = (filler + ["ship", "it", "with", "OpenClicky", "today"]).joined(separator: " ")
    let found = CorrectionLearner.corrections(inserted: inserted, edited: edited)
    #expect(found.map(\.original) == ["open clicky"])
    #expect(found.map(\.corrected) == ["OpenClicky"])
    // A case-only fix inside the shared opening run still counts.
    let capitals = CorrectionLearner.corrections(inserted: "the github repo is ready " + filler.joined(separator: " "),
                                                 edited: "the GitHub repo is ready " + filler.joined(separator: " "))
    #expect(capitals.map(\.corrected) == ["GitHub"])
}

@Test func aChangedMiddleTooLargeToAlignIsNotACorrection() {
    let a = (0..<600).map { "alpha\($0)" }, b = (0..<600).map { "beta\($0)" }
    #expect(CorrectionLearner.alignment(a, b) == nil)
    #expect(CorrectionLearner.alignment(["a", "b", "c"], ["a", "x", "c"]) == [.keep, .delete, .insert, .keep])
}
