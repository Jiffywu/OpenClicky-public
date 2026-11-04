import Foundation
import Testing
@testable import OpenClickyKit

// Background jobs, cache writes, catalog prices and limit alerts in the usage ledger.

extension InfraUsageTests {
    /// A manager over a scripted harness whose jobs run on a keyed provider, writing usage to `collector`.
    static func jobRig(kind: HarnessKind, model: String?, provider: String, collector: any UsageRecording, temp: AgentTempDir = AgentTempDir(),
                       script: @escaping @Sendable (ScriptedSession) async -> Void) async -> (AgentTempDir, AgentManager) {
        let harness = ScriptedHarness(kind: kind, script: script)
        let manager = AgentManager(store: AgentJobStore(paths: temp.paths), harnesses: [harness]) { _ in
            let dialect: ProviderDialect = kind == .codex ? .openAIResponses : .anthropicMessages
            let auth: HarnessAuth = provider == AgentLaunchSettings.loginProviderID
                ? .harnessLogin : .provider(ProviderConfig(id: provider, dialect: dialect), apiKey: "placeholder")
            return AgentLaunchSettings(harness: kind, model: model, providerID: provider, auth: auth,
                                       baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"])
        }
        let dialects: [String: ProviderDialect] = ["openai": .openAIResponses, "anthropic": .anthropicMessages]
        await manager.setUsageRecorder(AgentUsageRecorder(recorder: collector, client: "test", dialect: { dialects[$0] }))
        return (temp, manager)
    }

    static func waitForRecords(_ collector: UsageCollector, count: Int) async -> Bool {
        await agentEventually(5) { collector.records.count >= count }
    }

    @Test func codexRunningTotalsAreWrittenAsDeltasOnce() async throws {
        let collector = UsageCollector()
        let (temp, manager) = await Self.jobRig(kind: .codex, model: "gpt-5.4-mini", provider: "openai", collector: collector) { session in
            // Codex repeats the thread's running total after every model call, sometimes unchanged.
            await session.emit(.usage(AgentTokenUsage(input: 1_000, cachedInput: 0, output: 100)))
            await session.emit(.usage(AgentTokenUsage(input: 1_000, cachedInput: 0, output: 100)))
            await session.emit(.usage(AgentTokenUsage(input: 2_500, cachedInput: 800, output: 300)))
            await session.finish("Done.\n\n<report>\nsay: Done.\n</report>")
        }
        _ = temp
        let job = try await manager.spawn(AgentSpawnRequest(task: "Tidy the notes"), waitForStart: true).record
        #expect(await Self.waitForRecords(collector, count: 2))
        #expect(await agentEventually { await !manager.isRunning(job.id) })
        let records = collector.records
        #expect(records.count == 2, "an unchanged total adds nothing")
        #expect(records.map(\.inputTokens) == [1_000, 1_500])
        #expect(records.map(\.cachedInputTokens) == [0, 800])
        #expect(records.map(\.outputTokens) == [100, 200])
        #expect(records.allSatisfy { $0.slot == "agent" && $0.surface == "jobs" && $0.provider == "openai" && $0.model == "gpt-5.4-mini" })
        #expect(records.allSatisfy { $0.turn == "job:\(job.id)#1" && $0.client == "test" })
        // gpt-5.4-mini: $0.75 in, $0.075 cached, $4.50 out per million.
        let expected = (1_000 * 0.75 + 100 * 4.5) / 1e6 + (700 * 0.75 + 800 * 0.075 + 200 * 4.5) / 1e6
        #expect(abs(records.compactMap(\.costUSD).reduce(0, +) - expected) < 1e-12)

        let saved = try #require(await manager.job(job.id))
        #expect(saved.usage == AgentTokenUsage(input: 2_500, cachedInput: 800, output: 300))
        #expect(saved.usageCursor == AgentTokenUsage(input: 2_500, cachedInput: 800, output: 300))
        let summary = UsageSummary(records: records, from: .distantPast, to: .distantFuture)
        #expect(summary.bySurface["jobs"]?.inputTokens == 2_500)
        #expect(summary.byJob[job.id]?.outputTokens == 300)
    }

    @Test func aRelaunchedHarnessThatCountsAgainIsCountedInFull() {
        let cursor = AgentTokenUsage(input: 5_000, cachedInput: 1_000, output: 400)
        // Continues: only the growth.
        #expect(AgentUsageMeter.delta(reported: AgentTokenUsage(input: 6_000, cachedInput: 1_500, output: 450), cursor: cursor, cumulative: true)
                == AgentTokenUsage(input: 1_000, cachedInput: 500, output: 50))
        // Went backwards (a new process started from zero): all of it is new.
        let fresh = AgentTokenUsage(input: 300, cachedInput: 0, output: 20)
        #expect(AgentUsageMeter.delta(reported: fresh, cursor: cursor, cumulative: true) == fresh)
        // Per-run reports (Claude Code) are always new.
        #expect(AgentUsageMeter.delta(reported: cursor, cursor: cursor, cumulative: false) == cursor)
        #expect(HarnessKind.codex.reportsCumulativeUsage && !HarnessKind.claudeCode.reportsCumulativeUsage)
    }

    @Test func claudeCodeRunReportsAddUpAndPriceTheirCacheWrites() async throws {
        let collector = UsageCollector()
        let (temp, manager) = await Self.jobRig(kind: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", collector: collector) { session in
            await session.emit(.usage(AgentTokenUsage(input: 10_000, cachedInput: 6_000, output: 500, cacheWrite: 3_000)))
            await session.emit(.usage(AgentTokenUsage(input: 4_000, cachedInput: 3_000, output: 200)))
            await session.finish("Done.\n\n<report>\nsay: Done.\n</report>")
        }
        _ = temp
        let job = try await manager.spawn(AgentSpawnRequest(task: "Summarise the PDF"), waitForStart: true).record
        #expect(await Self.waitForRecords(collector, count: 2))
        let records = collector.records
        #expect(records.map(\.inputTokens) == [10_000, 4_000])
        #expect(records.map(\.cacheWriteTokens) == [3_000, nil])
        // Haiku 5.5: $0.10 in, $0.01 cached, $0.125 cache writes, $0.50 out per million.
        let first = (1_000 * 0.10 + 6_000 * 0.01 + 3_000 * 0.125 + 500 * 0.50) / 1e6
        #expect(abs((records[0].costUSD ?? 0) - first) < 1e-12)
        let saved = try #require(await manager.job(job.id))
        #expect(saved.usage == AgentTokenUsage(input: 14_000, cachedInput: 9_000, output: 700, cacheWrite: 3_000))
        #expect(saved.usageCursor == nil)
    }

    @Test func aWholeRunTotalIsPricedAtTheBaseRatesNotALongPromptTier() async throws {
        let collector = UsageCollector()
        // Claude Code's run total adds up six calls of about 21k context each: past Haiku's 100k tier, though no call was.
        let (temp, manager) = await Self.jobRig(kind: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", collector: collector) { session in
            await session.emit(.usage(AgentTokenUsage(input: 130_000, cachedInput: 0, output: 2_000)))
            await session.finish("Done.\n\n<report>\nsay: Done.\n</report>")
        }
        _ = temp
        _ = try await manager.spawn(AgentSpawnRequest(task: "Sort the inbox"), waitForStart: true)
        #expect(await Self.waitForRecords(collector, count: 1))
        let record = try #require(collector.records.first)
        // Haiku 5.5 base rates: $0.10 in, $0.50 out per million (the tier would be $0.50 and $2.50).
        #expect(abs((record.costUSD ?? 0) - (130_000 * 0.10 + 2_000 * 0.50) / 1e6) < 1e-12)

        // One call's growth of a running total (Codex) still reaches the tier.
        let recorder = AgentUsageRecorder(recorder: UsageCollector(), dialect: { _ in .anthropicMessages })
        var job = try AgentJobStore(paths: temp.paths).createJob(task: "t", title: nil, harness: .codex, model: "claude-haiku-5-5", provider: "anthropic")
        job.usage = .init()
        let long = AgentTokenUsage(input: 200_000, cachedInput: 0, output: 0)
        #expect(abs((recorder.record(job: job, delta: long, oneCall: true).costUSD ?? 0) - 200_000 * 0.50 / 1e6) < 1e-12)
        #expect(abs((recorder.record(job: job, delta: long).costUSD ?? 0) - 200_000 * 0.10 / 1e6) < 1e-12)
        let cursor = AgentTokenUsage(input: 50_000, cachedInput: 0, output: 100)
        #expect(AgentUsageMeter.coversOneCall(reported: AgentTokenUsage(input: 90_000, cachedInput: 0, output: 300), cursor: cursor, cumulative: true))
        #expect(!AgentUsageMeter.coversOneCall(reported: AgentTokenUsage(input: 90_000, cachedInput: 0, output: 300), cursor: nil, cumulative: true))
        #expect(!AgentUsageMeter.coversOneCall(reported: AgentTokenUsage(input: 9_000, cachedInput: 0, output: 300), cursor: cursor, cumulative: true))
        #expect(!AgentUsageMeter.coversOneCall(reported: cursor, cursor: cursor, cumulative: false))
    }

    @Test func aStoppingLimitStopsRunningPaidJobsAndRefusesNewOnes() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = UsageLedger(directory: directory)
        try ledger.setLimits(UsageLimits(dailyUSD: 0.001, warnAtFraction: 0.8, stopAtLimit: true))
        let launches = LaunchCount()
        let (temp, manager) = await Self.jobRig(kind: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", collector: ledger) { session in
            launches.add()
            // $0.0025, past the $0.001 limit; the job then keeps working until it is stopped.
            await session.emit(.usage(AgentTokenUsage(input: 20_000, cachedInput: 0, output: 1_000)))
        }
        _ = temp
        let job = try await manager.spawn(AgentSpawnRequest(task: "Draft the report"), waitForStart: true).record
        #expect(await agentEventually(5) { await manager.job(job.id)?.status == .stopped })
        let stopped = try #require(await manager.job(job.id))
        #expect(stopped.error?.contains("stopped calling paid models") == true)
        #expect(ledger.limitStatus().blocksCalls)

        // A new paid job isn't started.
        await #expect(throws: UsageLimitError.self) {
            _ = try await manager.spawn(AgentSpawnRequest(task: "Draft another report"), waitForStart: true)
        }
        #expect(launches.value == 1)

        // A job on the harness's own sign-in isn't billed per token, so it still runs.
        let (loginTemp, loginManager) = await Self.jobRig(kind: .codex, model: nil, provider: AgentLaunchSettings.loginProviderID,
                                                          collector: ledger) { session in
            launches.add()
            await session.finish("Done.")
        }
        _ = loginTemp
        _ = try await loginManager.spawn(AgentSpawnRequest(task: "Look something up"), waitForStart: true)
        #expect(launches.value == 2)
    }

    @Test func aCodexJobSavedBeforeCursorsCountsOnlyNewTokensWhenResumed() async throws {
        let collector = UsageCollector()
        let temp = AgentTempDir()
        // Saved by the earlier build: the thread's running total as the job's usage, and no cursor.
        let store = AgentJobStore(paths: temp.paths)
        var old = try store.createJob(task: "Tidy the notes", title: nil, harness: .codex, model: "gpt-5.4-mini", provider: "openai")
        let history = AgentTokenUsage(input: 1_500_000, cachedInput: 900_000, output: 40_000)
        old.usage = history
        old.threadID = "scripted-thread"
        old.status = .done
        try store.save(old)
        #expect(old.usageCursor == nil)
        let (_, manager) = await Self.jobRig(kind: .codex, model: "gpt-5.4-mini", provider: "openai", collector: collector, temp: temp) { session in
            // The resumed thread repeats its running total: the history plus the new call.
            await session.emit(.usage(AgentTokenUsage(input: 1_520_000, cachedInput: 915_000, output: 40_400)))
            await session.finish("Done.\n\n<report>\nsay: Done.\n</report>")
        }
        _ = try await manager.send(to: old.id, message: "And the drafts folder", waitForStart: true)
        #expect(await Self.waitForRecords(collector, count: 1))
        #expect(await agentEventually { await !manager.isRunning(old.id) })
        let record = try #require(collector.records.first)
        #expect(collector.records.count == 1)
        #expect(record.inputTokens == 20_000 && record.cachedInputTokens == 15_000 && record.outputTokens == 400)
        let saved = try #require(await manager.job(old.id))
        #expect(saved.usage == AgentTokenUsage(input: 1_520_000, cachedInput: 915_000, output: 40_400))
        #expect(saved.usageCursor == AgentTokenUsage(input: 1_520_000, cachedInput: 915_000, output: 40_400))
    }

    @Test func aNewConversationStartsItsRunningTotalFromZero() async throws {
        let collector = UsageCollector()
        let temp = AgentTempDir()
        // A Codex job that ran on another account: switching accounts starts a new thread, whose first total is small.
        let store = AgentJobStore(paths: temp.paths)
        var earlier = try store.createJob(task: "Tidy the notes", title: nil, harness: .codex, model: "gpt-5.4-mini", provider: "openai-work")
        earlier.usage = AgentTokenUsage(input: 3_000, cachedInput: 0, output: 50)
        earlier.usageCursor = AgentTokenUsage(input: 3_000, cachedInput: 0, output: 50)
        earlier.threadID = "work-thread"
        earlier.status = .done
        try store.save(earlier)
        let (_, manager) = await Self.jobRig(kind: .codex, model: "gpt-5.4-mini", provider: "openai", collector: collector, temp: temp) { session in
            await session.emit(.usage(AgentTokenUsage(input: 4_000, cachedInput: 0, output: 60)))
            await session.finish("Done.\n\n<report>\nsay: Done.\n</report>")
        }
        _ = try await manager.send(to: earlier.id, message: "Again", waitForStart: true)
        #expect(await Self.waitForRecords(collector, count: 1))
        #expect(collector.records.first?.inputTokens == 4_000, "the new thread's whole total is new")
    }

    @Test func jobsOnTheHarnessLoginAreCountedWithoutACost() async throws {
        let collector = UsageCollector()
        let (temp, manager) = await Self.jobRig(kind: .codex, model: nil, provider: AgentLaunchSettings.loginProviderID,
                                                collector: collector) { session in
            await session.emit(.usage(AgentTokenUsage(input: 800, cachedInput: 0, output: 50)))
            await session.finish("Done.")
        }
        _ = temp
        _ = try await manager.spawn(AgentSpawnRequest(task: "Look something up"), waitForStart: true)
        #expect(await Self.waitForRecords(collector, count: 1))
        let record = try #require(collector.records.first)
        #expect(record.costUSD == nil && record.model == "codex default" && record.provider == "harness-login")
        #expect(UsageFormat.cost({ var totals = UsageTotals(); totals.add(record); return totals }()) == "—")
    }

    @Test func oldJobRecordsWithoutCacheWritesStillDecode() throws {
        let old = Data(#"{"input":12,"cachedInput":3,"output":4}"#.utf8)
        #expect(try JSONDecoder().decode(AgentTokenUsage.self, from: old) == AgentTokenUsage(input: 12, cachedInput: 3, output: 4))
        let encoded = try JSONEncoder().encode(AgentTokenUsage(input: 1, cachedInput: 0, output: 1, cacheWrite: 7))
        #expect(try JSONDecoder().decode(AgentTokenUsage.self, from: encoded).cacheWrite == 7)
    }

    @Test func cacheWritesArePricedOnTheirOwn() throws {
        let price = ModelPrice(inputPerMillion: 2, cachedInputPerMillion: 0.1, outputPerMillion: 10, cacheWritePerMillion: 2.5)
        let measure = UsageMeasure(inputTokens: 10_000, cachedInputTokens: 4_000, outputTokens: 1_000, cacheWriteTokens: 5_000)
        let cost = try #require(price.cost(of: measure))
        #expect(abs(cost - (1_000 * 2 + 4_000 * 0.1 + 5_000 * 2.5 + 1_000 * 10) / 1e6) < 1e-12)
        // Without a cache-write price they are plain input, as before.
        let plain = try #require(ModelPrice(inputPerMillion: 2, cachedInputPerMillion: 0.1, outputPerMillion: 10).cost(of: measure))
        #expect(abs(plain - (6_000 * 2 + 4_000 * 0.1 + 1_000 * 10) / 1e6) < 1e-12)
        // Long Haiku prompts use the long-prompt cache-write rate.
        let haiku = try #require(PriceBook.builtIn().price(model: "claude-haiku-5-5", dialect: .anthropicMessages))
        #expect(haiku.cacheWritePerMillion == 0.125 && haiku.tiers?.first?.cacheWritePerMillion == 0.625)
        let long = try #require(haiku.cost(of: UsageMeasure(inputTokens: 200_000, outputTokens: 0, cacheWriteTokens: 100_000)))
        #expect(abs(long - (100_000 * 0.50 + 100_000 * 0.625) / 1e6) < 1e-12)
        // A brain reply's cache writes reach the record.
        let fromReply = UsageMeasure(TokenUsage(inputTokens: 900, cachedInputTokens: 100, outputTokens: 5, cacheWriteTokens: 700))
        #expect(fromReply.cacheWriteTokens == 700)
        #expect(UsageRecord(slot: "brain", surface: "s", provider: "p", model: "m", measure: fromReply, costUSD: nil).measure == fromReply)
    }

    @Test func everyCatalogModelHasAPriceOrAnExplicitUnknownMarker() throws {
        let catalog = try ModelCatalog.builtIn()
        for model in catalog.models {
            let marked = model.priceUnknown.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            #expect(model.price != nil || marked, "\(model.id) needs a price or a priceUnknown reason")
            if let price = model.price {
                #expect(price.source?.isEmpty == false, "\(model.id) needs a price source")
                for value in [price.cacheWritePerMillion, price.audioInputPerMillion, price.audioOutputPerMillion, price.perMinuteSpoken]
                    .compactMap({ $0 }) { #expect(value >= 0, "\(model.id)") }
            }
        }
        let book = PriceBook.builtIn()
        // Spot checks against the providers' published prices.
        #expect(book.price(model: "gpt-realtime-2.1", dialect: .openAIRealtime)?.audioOutputPerMillion == 64)
        #expect(book.price(model: "gemini-3.8-live", dialect: .geminiLive)?.audioInputPerMillion == 3)
        #expect(book.price(model: "nova-3", dialect: .deepgramListen)?.perMinute == 0.0077)
        #expect(book.price(model: "gpt-transcribe", dialect: .openAITranscription)?.perMinute == 0.0045)
        // A voice priced by audio produced: 20 s of speech from 300 characters.
        let tts = try #require(book.price(model: "gemini-3.8-flash-tts", dialect: .geminiSpeech))
        #expect(tts.estimate == true)
        let line = try #require(tts.cost(of: UsageMeasure(audioSeconds: 20, characters: 300)))
        #expect(abs(line - (300.0 / 1000 * 0.000125 + 20.0 / 60 * 0.0135)) < 1e-12)
    }

    @Test func crossingALimitAlertsOncePerLevelAndPeriod() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_793_000_000))
        let ledger = UsageLedger(directory: directory, calendar: calendar, now: { clock.now })
        try ledger.setLimits(UsageLimits(dailyUSD: 1, warnAtFraction: 0.8, stopAtLimit: true))
        var alerter = UsageLimitAlerter(calendar: calendar)
        alerter.seed(ledger.limitStatus(), now: clock.now)
        // The seam: the ledger's record callback hands each status to the alerter, as the app does.
        let alerts = AlertBox()
        let utc = calendar
        ledger.onRecord = { _, status in alerts.observe(status, now: clock.now, calendar: utc) }

        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.5, at: clock.now))
        #expect(alerts.all.isEmpty)
        ledger.record(Self.record("agent", surface: "jobs", cost: 0.35, at: clock.now))
        #expect(alerts.all.map(\.kind) == [.warned])
        #expect(alerts.all.first?.title == "Nearing your spending limit today")
        #expect(alerts.all.first?.body.contains("$0.85 of your $1.00 limit today") == true)
        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.01, at: clock.now))
        #expect(alerts.all.count == 1, "the same warning isn't repeated")
        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.2, at: clock.now))
        #expect(alerts.all.map(\.kind) == [.warned, .stopped])
        #expect(alerts.all.last?.body.contains("stopped calling paid models") == true)
        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.2, at: clock.now))
        #expect(alerts.all.count == 2)

        // A new day: the day's limit can warn again.
        clock.now = clock.now.addingTimeInterval(86_400)
        ledger.record(Self.record("brain", surface: "voice turn", cost: 0.9, at: clock.now))
        #expect(alerts.all.map(\.kind) == [.warned, .stopped, .warned])
        #expect(Set(alerts.all.map(\.id)).count == 3)

        // Seeding with a limit already reached says nothing about it (or its warning).
        var seeded = UsageLimitAlerter(calendar: calendar)
        let reached = UsageLimitStatus(level: .reached, period: .day, spentUSD: 2, limitUSD: 1, stops: false)
        seeded.seed(reached, now: clock.now)
        let again = seeded.observe(reached, now: clock.now)
        let warning = seeded.observe(UsageLimitStatus(level: .warning, period: .day, spentUSD: 0.9, limitUSD: 1, stops: false), now: clock.now)
        #expect(again == nil)
        #expect(warning == nil)
        #expect(UsageLimitAlert(id: "x", kind: .passed, status: reached).title == "Past your spending limit today")
    }
}

/// Counts harness launches across scripted sessions.
private final class LaunchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A settable clock for ledger tests.
final class UsageTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Alerts collected from the ledger's record callback.
private final class AlertBox: @unchecked Sendable {
    private let lock = NSLock()
    private var alerter: UsageLimitAlerter?
    private var alerts: [UsageLimitAlert] = []

    func observe(_ status: UsageLimitStatus, now: Date, calendar: Calendar) {
        lock.withLock {
            var current = alerter ?? UsageLimitAlerter(calendar: calendar)
            if let alert = current.observe(status, now: now) { alerts.append(alert) }
            alerter = current
        }
    }

    var all: [UsageLimitAlert] { lock.withLock { alerts } }
}

extension DictationAdapterCleanupTests {
    @Test func cleanupRepliesAreMeteredUnderDictation() async throws {
        let transport = FakeHTTPTransport([.sse(Self.responsesSSE("Can you send me the deck before Friday?"))])
        let collector = UsageCollector()
        let factory = AdapterModelClientFactory(http: transport, resilience: ProviderResilience(options: .init(client: "test"), recorder: collector))
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: .heyClickyLike, settings: DictationSettings(), catalog: try ModelCatalog.builtIn(),
            factory: factory, credentials: InMemoryCredentialStore(["openai": Self.placeholderKey])))
        let result = await cleaner.clean("can you uh send me the deck before friday", context: nil, vocabulary: [])
        #expect(result.source == .model)
        let record = try #require(collector.records.first)
        #expect(collector.records.count == 1)
        #expect(record.slot == "brain-fast" && record.surface == "dictation" && record.client == "test")
        #expect(record.provider == "openai" && record.model == "gpt-5.4-mini")
        #expect(record.inputTokens == 120 && record.outputTokens == 14)
        #expect(abs((record.costUSD ?? 0) - (120 * 0.75 + 14 * 4.5) / 1e6) < 1e-12)
        // Unwrapping still finds the adapter (latency probes and the take-over planner look for it).
        let client = try #require(factory.makeClient(provider: ProviderConfig(id: "c", dialect: .anthropicMessages), apiKey: nil))
        #expect(EngineFactory.unwrapped(client) is AnthropicMessagesClient)
    }

    @Test func aStoppingLimitSendsCleanupToTheLocalTidy() async throws {
        let transport = FakeHTTPTransport([.sse(Self.responsesSSE("never sent"))])
        let collector = UsageCollector(status: UsageLimitStatus(level: .reached, period: .day, spentUSD: 2, limitUSD: 1, stops: true))
        let factory = AdapterModelClientFactory(http: transport, resilience: ProviderResilience(recorder: collector))
        let cleaner = try #require(DictationCleanupClientResolver.makeCleaner(
            config: .heyClickyLike, settings: DictationSettings(), catalog: try ModelCatalog.builtIn(),
            factory: factory, credentials: InMemoryCredentialStore(["openai": Self.placeholderKey])))
        let result = await cleaner.clean("um so we should ship it", context: nil, vocabulary: [])
        #expect(result.source != .model)
        #expect(transport.requests.isEmpty)
        #expect(collector.records.isEmpty)
    }
}
