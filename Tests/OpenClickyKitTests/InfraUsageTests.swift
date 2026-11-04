import Foundation
import Testing
@testable import OpenClickyKit

@Suite struct InfraUsageTests {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-usage-\(UUID().uuidString)", isDirectory: true)
    }

    static func record(_ slot: String, surface: String, cost: Double?, at: Date, turn: String? = nil, model: String = "m",
                       measure: UsageMeasure = UsageMeasure(inputTokens: 100, outputTokens: 10)) -> UsageRecord {
        UsageRecord(at: at, slot: slot, surface: surface, provider: "p", model: model, turn: turn, client: "test", measure: measure, costUSD: cost)
    }

    @Test func catalogPricesCoverTheCheapConfigAndAreNonNegative() throws {
        let book = PriceBook.builtIn()
        let haiku = try #require(book.price(model: "claude-haiku-5-5", dialect: .anthropicMessages))
        #expect(haiku.inputPerMillion == 0.10 && haiku.outputPerMillion == 0.50 && haiku.cachedInputPerMillion == 0.01)
        #expect(book.price(model: "eleven_flash_v2_5", dialect: .elevenLabsSpeech)?.estimate == true)
        #expect(book.price(model: "on-device", dialect: .appleSpeech)?.cost(of: UsageMeasure(audioSeconds: 60)) == 0)
        #expect(book.price(model: "system", dialect: .appleSpeechSynthesis)?.cost(of: UsageMeasure(characters: 500)) == 0)
        #expect(book.servicePrice("brave")?.perRequest == 0.005)
        for model in book.catalog.models {
            guard let price = model.price else { continue }
            for value in [price.inputPerMillion, price.cachedInputPerMillion, price.outputPerMillion, price.perMinute,
                          price.perThousandCharacters, price.perRequest].compactMap({ $0 }) {
                #expect(value >= 0, "\(model.id)")
            }
            #expect(price.source?.isEmpty == false, "\(model.id) needs a price source")
        }
    }

    @Test func tokenCostsSplitCachedInputAndUseLongPromptTiers() throws {
        let haiku = try #require(PriceBook.builtIn().price(model: "claude-haiku-5-5", dialect: .anthropicMessages))
        // 10k prompt tokens of which 8k cached, 500 output.
        let cost = try #require(haiku.cost(of: UsageMeasure(inputTokens: 10_000, cachedInputTokens: 8_000, outputTokens: 500)))
        #expect(abs(cost - (2_000 * 0.10 + 8_000 * 0.01 + 500 * 0.50) / 1e6) < 1e-12)
        // Past 100k prompt tokens Haiku costs five times as much.
        let long = try #require(haiku.cost(of: UsageMeasure(inputTokens: 200_000, outputTokens: 1_000)))
        #expect(abs(long - (200_000 * 0.50 + 1_000 * 2.50) / 1e6) < 1e-12)
    }

    @Test func speechListeningAndRealtimeCosts() {
        let voice = ModelPrice(perThousandCharacters: 0.05)
        #expect(abs((voice.cost(of: UsageMeasure(audioSeconds: 3, characters: 400)) ?? 0) - 0.02) < 1e-12)
        let ears = ModelPrice(perMinute: 0.006)
        #expect(abs((ears.cost(of: UsageMeasure(audioSeconds: 30)) ?? 0) - 0.003) < 1e-12)
        let realtime = ModelPrice(inputPerMillion: 4, outputPerMillion: 16, audioInputPerMillion: 32, audioOutputPerMillion: 64)
        let cost = realtime.cost(of: UsageMeasure(inputTokens: 1_000, outputTokens: 500, audioInputTokens: 800, audioOutputTokens: 400)) ?? 0
        #expect(abs(cost - (200 * 4 + 100 * 16 + 800 * 32 + 400 * 64) / 1e6) < 1e-12)
        #expect(ModelPrice(perRequest: 0.005).cost(of: UsageMeasure(requests: 2)) == 0.01)
        #expect(ModelPrice().cost(of: UsageMeasure(inputTokens: 5)) == nil)
    }

    @Test func theLedgerAddsUpByDaySlotSurfaceAndTurn() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26
        let ledger = UsageLedger(directory: directory, calendar: calendar, now: { now })
        let yesterday = now.addingTimeInterval(-86_400)
        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.01, at: now, turn: "t1"))
        ledger.record(Self.record("voice", surface: "voice turn", cost: 0.002, at: now.addingTimeInterval(1), turn: "t1",
                                  measure: UsageMeasure(audioSeconds: 2, characters: 40)))
        ledger.record(Self.record("stt", surface: "voice turn", cost: 0, at: now.addingTimeInterval(2), turn: "t1",
                                  measure: UsageMeasure(audioSeconds: 3)))
        ledger.record(Self.record("lookups", surface: "voice turn", cost: nil, at: now.addingTimeInterval(3), turn: "t1"))
        ledger.record(Self.record("realtime-voice", surface: "realtime", cost: 0.05, at: yesterday))
        // A record from another month lands in its own file.
        ledger.record(Self.record("brain", surface: "occtl", cost: 1, at: now.addingTimeInterval(-40 * 86_400)))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".jsonl") }.sorted()
        #expect(files == ["usage-2026-09.jsonl", "usage-2026-10.jsonl"])

        let week = ledger.summary(days: 7)
        #expect(week.total.records == 5)
        #expect(abs(week.total.costUSD - 0.062) < 1e-12)
        #expect(week.total.unpriced == 1)
        #expect(week.byDay.keys.sorted() == ["2026-10-25", "2026-10-26"])
        #expect(abs((week.byDay["2026-10-26"]?.costUSD ?? 0) - 0.012) < 1e-12)
        #expect(week.bySlot["realtime-voice"]?.records == 1)
        #expect(week.bySlot["lookups"]?.records == 1)
        #expect(week.bySurface["voice turn"]?.records == 4)
        #expect(week.byModel["p · m"]?.records == 5)
        let turn = try #require(week.recentTurns.first)
        #expect(turn.turn == "t1" && turn.totals.records == 4)
        #expect(abs(turn.totals.costUSD - 0.012) < 1e-12)
        #expect(UsageFormat.cost(turn.totals) == "$0.01+")
        #expect(ledger.records(from: .distantPast).count == 6)
        let spending = ledger.spending()
        #expect(abs(spending.today - 0.012) < 1e-12)
        #expect(abs(spending.month - 0.062) < 1e-12)
    }

    @Test func limitsWarnThenStop() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = UsageLedger(directory: directory)
        #expect(ledger.limitStatus() == .unlimited)
        try ledger.setLimits(UsageLimits(dailyUSD: 1.00, warnAtFraction: 0.8, stopAtLimit: true))
        let seen = StatusLog()
        ledger.onRecord = { _, status in seen.append(status) }
        ledger.record(Self.record("brain", surface: "s", cost: 0.5, at: Date()))
        #expect(ledger.limitStatus().level == .ok)
        ledger.record(Self.record("brain", surface: "s", cost: 0.35, at: Date()))
        #expect(ledger.limitStatus().level == .warning)
        #expect(ledger.limitStatus().message == "You've used $0.85 of your $1.00 limit today.")
        ledger.record(Self.record("brain", surface: "s", cost: 0.2, at: Date()))
        let reached = ledger.limitStatus()
        #expect(reached.level == .reached && reached.blocksCalls)
        #expect(seen.levels == [.ok, .warning, .reached])
        // A second ledger on the same folder (occtl beside the app) sees the same totals and limits.
        #expect(UsageLedger(directory: directory).limitStatus().blocksCalls)
        try ledger.setLimits(UsageLimits(dailyUSD: 1.00, stopAtLimit: false))
        #expect(!ledger.limitStatus().blocksCalls)
        #expect(ledger.limitStatus().message?.contains("gone past") == true)
    }

    @Test func limitTotalsAreKeptUpWithoutRereadingTheMonthUnlessAnotherProcessWrote() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26
        let ledger = UsageLedger(directory: directory, calendar: calendar, now: { now })
        try ledger.setLimits(UsageLimits(dailyUSD: 10, monthlyUSD: 100))
        for index in 0..<20 { ledger.record(Self.record("brain", surface: "s", cost: 0.1, at: now.addingTimeInterval(Double(index)))) }
        #expect(ledger.monthReads == 1)
        // Yesterday counts toward the month only; a record from another month changes neither total nor the cache.
        ledger.record(Self.record("brain", surface: "s", cost: 1, at: now.addingTimeInterval(-86_400)))
        ledger.record(Self.record("brain", surface: "s", cost: 5, at: now.addingTimeInterval(-40 * 86_400)))
        #expect(ledger.monthReads == 1)
        #expect(abs(ledger.spending().today - 2) < 1e-9)
        #expect(abs(ledger.spending().month - 3) < 1e-9)
        // occtl (another ledger on the same folder) appends: the next record reads the month again and counts it.
        UsageLedger(directory: directory, calendar: calendar, now: { now }).record(Self.record("brain", surface: "occtl", cost: 0.5, at: now))
        ledger.record(Self.record("brain", surface: "s", cost: 0.1, at: now.addingTimeInterval(30)))
        #expect(ledger.monthReads == 2)
        #expect(ledger.limitStatus().level == .ok)
        #expect(abs(ledger.spending().today - 2.6) < 1e-9)
        #expect(abs(ledger.spending().month - 3.6) < 1e-9)
    }

    @Test func monthlyLimitsCountTheWholeMonth() {
        let limits = UsageLimits(dailyUSD: 5, monthlyUSD: 20)
        #expect(limits.status(today: 1, month: 17).level == .warning)
        #expect(limits.status(today: 1, month: 17).period == .month)
        #expect(limits.status(today: 5.5, month: 6).period == .day)
        #expect(limits.status(today: 5.5, month: 6).level == .reached)
    }

    @Test func aStoppingLimitRefusesModelCallsWithASentence() async throws {
        let blocked = UsageLimitStatus(level: .reached, period: .day, spentUSD: 2, limitUSD: 1, stops: true)
        let resilience = ProviderResilience(recorder: UsageCollector(status: blocked), sleep: RecordedSleeps().sleep)
        let fake = FakeHTTPTransport([.sse(AnthropicMessagesTests.basicStream)])
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "k"]), http: fake, resilience: resilience)
        await #expect(throws: UsageLimitError.self) {
            _ = try await factory.languageModel(for: .brain).completeReply(ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text("hi"))]))
        }
        #expect(fake.requests.isEmpty)
    }

    /// A take-over drive on Anthropic's computer tool goes around the streaming wrapper, so its steps are metered
    /// and limited on their own: recorded under the take-over surface, and refused before sending once a stopping
    /// limit is reached.
    @Test func computerToolStepsAreMeteredAndStopAtTheLimit() async throws {
        let collector = UsageCollector()
        let fake = FakeHTTPTransport([.body(AnthropicComputerUseTests.toolsetReply)])
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "k"]), http: fake,
                                    resilience: ProviderResilience(recorder: collector, sleep: RecordedSleeps().sleep))
        let planner = try TakeoverPlannerChoice.automatic.makePlanner(factory: factory)
        try await UsageContext.$current.withValue(UsageContext(surface: .voiceTurn, turnID: "t4")) {
            _ = try await planner.start(brief: TakeoverBrief(task: "Title it"), observation: TakeoverFixtures.observation())
        }
        let record = try #require(collector.records.first)
        #expect(collector.records.count == 1)
        #expect(record.slot == "brain" && record.surface == "take-over" && record.turn == "t4")
        #expect(record.inputTokens == 5200 && record.outputTokens == 120 && record.model == "claude-haiku-5-5")

        let blocked = UsageLimitStatus(level: .reached, period: .day, spentUSD: 2, limitUSD: 1, stops: true)
        let refused = FakeHTTPTransport([.body(AnthropicComputerUseTests.toolsetReply)])
        let stopped = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["anthropic": "k"]), http: refused,
                                    resilience: ProviderResilience(recorder: UsageCollector(status: blocked), sleep: RecordedSleeps().sleep))
        let limited = try TakeoverPlannerChoice.automatic.makePlanner(factory: stopped)
        await #expect(throws: UsageLimitError.self) {
            _ = try await limited.start(brief: TakeoverBrief(task: "Title it"), observation: TakeoverFixtures.observation())
        }
        #expect(refused.requests.isEmpty)
    }

    /// Adapters report usage only when a reply completes. A reply cut off by a barge-in or a failure mid-stream was
    /// still billed, so it is recorded as an estimate; a request refused before any reply is not recorded.
    @Test func interruptedAndFailedRepliesAreRecordedAsEstimates() async throws {
        let request = ChatRequest(model: "claude-haiku-5-5", messages: [.user(.text(String(repeating: "a", count: 400)))])
        func metered(_ base: any LanguageModelClient, _ collector: UsageCollector) throws -> MeteredLanguageModelClient {
            let resilience = ProviderResilience(recorder: collector, sleep: RecordedSleeps().sleep)
            let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                        credentials: InMemoryCredentialStore(["anthropic": "k"]), resilience: resilience)
            return MeteredLanguageModelClient(base: base, identity: try #require(factory.identity(for: .brain, resilience: resilience)),
                                              resilience: resilience)
        }

        // Fails after some text.
        let failed = UsageCollector()
        await #expect(throws: ProviderError.self) {
            for try await _ in try metered(ScriptedReply(events: [.textDelta("Hello there!")], error: ProviderError(provider: "anthropic", message: "overloaded")),
                                           failed).stream(request) {}
        }
        let failure = try #require(failed.records.first)
        #expect(failed.records.count == 1)
        #expect(failure.estimate == true && failure.inputTokens == 100 && failure.outputTokens == 3 && (failure.costUSD ?? 0) > 0)

        // The caller stops reading mid-reply (a barge-in); the provider never sent its usage.
        let cancelled = UsageCollector()
        for try await event in try metered(ScriptedReply(events: [.textDelta("Sure")], error: nil), cancelled).stream(request) {
            if case .textDelta = event { break }
        }
        #expect(await waitUntil { cancelled.records.count == 1 })
        #expect(cancelled.records.first?.estimate == true && cancelled.records.first?.inputTokens == 100)

        // Refused before any reply: not billed, not recorded.
        let refused = UsageCollector()
        await #expect(throws: ProviderError.self) {
            for try await _ in try metered(ScriptedReply(events: [], error: ProviderError(provider: "anthropic", status: 401, message: "bad key")),
                                           refused).stream(request) {}
        }
        #expect(refused.records.isEmpty)

        // A complete reply records its reported usage, not an estimate.
        let complete = UsageCollector()
        let usage = TokenUsage(inputTokens: 900, cachedInputTokens: 0, outputTokens: 40)
        for try await _ in try metered(ScriptedReply(events: [.textDelta("Done."), .usage(usage), .finished(.stop)], error: nil, ends: true),
                                       complete).stream(request) {}
        #expect(complete.records.count == 1 && complete.records.first?.inputTokens == 900 && complete.records.first?.estimate != true)
    }

    @Test func listeningVoiceAndLookupsAreMetered() async throws {
        let collector = UsageCollector()
        let resilience = ProviderResilience(recorder: collector, sleep: RecordedSleeps().sleep)
        let factory = EngineFactory(config: InfraFixtures.config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["elevenlabs": "k"]), resilience: resilience)
        // Listening: two seconds of 16 kHz audio through a scripted session.
        let ears = MeteredSpeechToTextClient(base: ScriptedEars(), identity: try #require(factory.identity(for: .stt, resilience: resilience)),
                                             resilience: resilience)
        try await UsageContext.$current.withValue(UsageContext(surface: .voiceTurn, turnID: "t9")) {
            let session = try await ears.startSession(language: nil, keywords: [])
            await session.send(Data(count: 32_000))
            await session.send(Data(count: 32_000))
            await session.finish()
            await session.cancel() // once only
        }
        // A line: 24 kHz audio, 0.5 s.
        let voice = MeteredSpeechOutputClient(base: ScriptedVoice(), identity: try #require(factory.identity(for: .voice, resilience: resilience)),
                                              resilience: resilience)
        for try await _ in voice.speak("Hello there, friend.", voice: nil, instructions: nil) {}
        // A Brave web search through the lookup transport.
        let lookups = resilience.lookupTransport(FakeHTTPTransport([.body("{}")]))
        _ = try await lookups.data(for: URLRequest(url: URL(string: "https://api.search.brave.com/res/v1/web/search?q=x")!))

        let records = collector.records
        #expect(records.count == 3)
        let stt = try #require(records.first { $0.slot == "stt" })
        #expect(stt.audioSeconds == 2 && stt.turn == "t9" && stt.surface == "voice turn" && stt.costUSD == 0)
        let line = try #require(records.first { $0.slot == "voice" })
        #expect(line.characters == 20 && line.audioSeconds == 0.5 && line.surface == "voice lines")
        #expect(abs((line.costUSD ?? 0) - 0.001) < 1e-12 && line.estimate == true)
        let search = try #require(records.first { $0.slot == "lookups" })
        #expect(search.provider == "brave" && search.model == "web-search" && search.costUSD == 0.005)
    }

    @Test func realtimeRepliesAreMeteredFromTheirUsage() async throws {
        let collector = UsageCollector()
        let resilience = ProviderResilience(recorder: collector, sleep: RecordedSleeps().sleep)
        var config = InfraFixtures.config
        config.providers.append(ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"),
                                               credential: "openai"))
        config.slots[.realtimeVoice] = SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1")
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(), credentials: InMemoryCredentialStore(["openai": "k"]),
                                    resilience: resilience)
        let session = FakeRealtimeVoiceSession()
        let client = MeteredRealtimeVoiceClient(base: OneSessionClient(session: session),
                                                identity: try #require(factory.identity(for: .realtimeVoice, resilience: resilience)), resilience: resilience)
        let open = try await client.connect(RealtimeSessionConfiguration(instructions: "hi"))
        session.emit(.responseFinished(RealtimeResponseSummary(responseID: "r1", status: .completed,
                                                               usage: RealtimeUsage(inputTokens: 900, outputTokens: 300, inputAudioTokens: 600, outputAudioTokens: 250))))
        session.finish()
        var events = 0
        for try await _ in open.events { events += 1 }
        #expect(events == 1)
        let record = try #require(collector.records.first)
        #expect(record.slot == "realtime-voice" && record.surface == "realtime")
        #expect(record.inputTokens == 900 && record.audioOutputTokens == 250)
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [UsageLimitStatus] = []
    func append(_ status: UsageLimitStatus) { lock.withLock { statuses.append(status) } }
    var levels: [UsageLimitStatus.Level] { lock.withLock { statuses.map(\.level) } }
}

/// Listening that hears nothing and ends when finished.
struct ScriptedEars: SpeechToTextClient {
    var inputFormat: PCMFormat { .speech16k }

    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession { Session() }

    final class Session: SpeechToTextSession, @unchecked Sendable {
        let events: AsyncThrowingStream<TranscriptEvent, Error>
        private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
        init() { (events, continuation) = AsyncThrowingStream.makeStream() }
        func send(_ pcm: Data) async {}
        func finish() async { continuation.finish() }
        func cancel() async { continuation.finish() }
    }
}

/// A voice that answers every line with half a second of 24 kHz silence.
struct ScriptedVoice: SpeechOutputClient {
    func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.audio(Data(count: 24_000), .speech24k))
            continuation.yield(.lineFinished)
            continuation.finish()
        }
    }
}

/// Hands out one prepared session.
struct OneSessionClient: RealtimeVoiceClient {
    let session: FakeRealtimeVoiceSession
    var model: String { "gpt-realtime-2.1" }
    func connect(_ configuration: RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession { session }
}

/// A reply that sends `events`, then fails with `error`, ends (`ends`), or stays open until cancelled.
struct ScriptedReply: LanguageModelClient {
    var events: [ChatEvent]
    var error: Error?
    var ends = false

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        for event in events { continuation.yield(event) }
        if let error { continuation.finish(throwing: error) } else if ends { continuation.finish() }
        // Held until the stream ends, so an open reply stays open until it is cancelled.
        continuation.onTermination = { _ in _ = continuation }
        return stream
    }
}
