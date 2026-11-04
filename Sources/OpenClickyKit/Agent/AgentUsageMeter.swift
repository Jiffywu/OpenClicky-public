import Foundation

// Background jobs in the usage ledger (docs/infra.md). The harnesses report tokens in two ways: Codex sends the
// thread's running total after every model call (`thread/tokenUsage/updated`), Claude Code sends one total per run at
// the end (`result`). The manager turns either into deltas, so each token is written to the ledger once, under the
// agent slot and the "jobs" surface.

extension HarnessKind {
    /// The harness reports a running total for the whole conversation rather than what one run used.
    public var reportsCumulativeUsage: Bool {
        switch self {
        case .codex: true
        case .claudeCode: false
        }
    }
}

public enum AgentUsageMeter {
    /// What a usage report adds to a job.
    ///
    /// - Parameters:
    ///   - reported: the harness's report.
    ///   - cursor: the last running total seen for this job (cumulative harnesses only).
    ///   - cumulative: whether `reported` is a running total.
    /// - Returns: the tokens not yet counted. A running total that went backwards (a relaunched harness that started
    ///   counting again) counts in full.
    public static func delta(reported: AgentTokenUsage, cursor: AgentTokenUsage?, cumulative: Bool) -> AgentTokenUsage {
        guard cumulative, let cursor, continues(reported, from: cursor) else { return reported }
        return AgentTokenUsage(input: reported.input - cursor.input, cachedInput: reported.cachedInput - cursor.cachedInput,
                               output: reported.output - cursor.output, cacheWrite: reported.cacheWrite - cursor.cacheWrite)
    }

    /// Whether a running total carries on from `cursor` (no count went backwards).
    public static func continues(_ reported: AgentTokenUsage, from cursor: AgentTokenUsage) -> Bool {
        reported.input >= cursor.input && reported.cachedInput >= cursor.cachedInput
            && reported.output >= cursor.output && reported.cacheWrite >= cursor.cacheWrite
    }

    /// The cursor to measure a report against. A Codex job saved before jobs kept a cursor stored the thread's running
    /// total as its usage, so that total is where a resumed thread carries on from. (A launch that starts a new
    /// conversation sets the cursor to zero, so a nil cursor with usage only means such an old record.)
    public static func cursor(for record: AgentJobRecord) -> AgentTokenUsage? {
        guard record.harness.reportsCumulativeUsage else { return nil }
        if let cursor = record.usageCursor { return cursor }
        return record.usage.isZero ? nil : record.usage
    }

    /// Whether the tokens a report adds come from one model call, so a long-prompt price tier can be chosen from them.
    /// Only a running total's growth since the last report is known to be one call; Claude Code's per-run total and a
    /// first or restarted running total can add up several calls, whose summed prompt would wrongly reach a tier.
    public static func coversOneCall(reported: AgentTokenUsage, cursor: AgentTokenUsage?, cumulative: Bool) -> Bool {
        guard cumulative, let cursor else { return false }
        return continues(reported, from: cursor)
    }
}

/// Writes job usage to the ledger. Priced from the catalog when the job runs on a keyed provider; a job that runs on
/// the harness's own sign-in (a ChatGPT or Claude subscription) isn't billed per token, so its cost stays blank.
public struct AgentUsageRecorder: Sendable {
    public let recorder: any UsageRecording
    public let prices: PriceBook
    /// The dialect of an agent-slot provider id (nil when unknown).
    public let dialect: @Sendable (String) -> ProviderDialect?
    public let client: String

    public init(recorder: any UsageRecording, prices: PriceBook = .builtIn(), client: String = "app",
                dialect: @escaping @Sendable (String) -> ProviderDialect? = { _ in nil }) {
        self.recorder = recorder
        self.prices = prices
        self.client = client
        self.dialect = dialect
    }

    /// A recorder for the config's providers and declared models.
    public init(recorder: any UsageRecording, config: OpenClickyConfig, client: String = "app") {
        let dialects = Dictionary(config.providers.map { ($0.id, $0.dialect) }, uniquingKeysWith: { first, _ in first })
        self.init(recorder: recorder, prices: .builtIn(merging: config.models), client: client, dialect: { dialects[$0] })
    }

    /// Writes through whatever ledger the app or occtl installed (`ProviderResilience.installed`), so turning the
    /// usage ledger flag off stops job records too. Providers are looked up in the config as it is at each record.
    public static func installed(config: @escaping @Sendable () -> OpenClickyConfig) -> AgentUsageRecorder {
        let current = config()
        return AgentUsageRecorder(recorder: InstalledUsageRecorder(), prices: .builtIn(merging: current.models),
                                  client: ProviderResilience.installed?.options.client ?? "app",
                                  dialect: { config().provider($0)?.dialect })
    }

    /// The model name a record carries: the job's model, or the harness's default.
    public static func modelName(for job: AgentJobRecord) -> String {
        job.model ?? "\(job.harness.rawValue) default"
    }

    /// The record for `delta` tokens of `job`, as written. Long-prompt tiers apply only when `oneCall` says the delta
    /// is a single model call; a delta that sums several calls is priced at the base rates.
    @discardableResult
    public func record(job: AgentJobRecord, delta: AgentTokenUsage, oneCall: Bool = false, at date: Date = Date()) -> UsageRecord {
        let measure = UsageMeasure(inputTokens: delta.input, cachedInputTokens: delta.cachedInput, outputTokens: delta.output,
                                   cacheWriteTokens: delta.cacheWrite > 0 ? delta.cacheWrite : nil)
        var price: ModelPrice? = job.provider == AgentLaunchSettings.loginProviderID || job.model == nil
            ? nil : prices.price(model: job.model ?? "", dialect: dialect(job.provider))
        if !oneCall { price?.tiers = nil }
        let record = UsageRecord(at: date, slot: SlotID.agent.rawValue, surface: UsageSurface.jobs.rawValue, provider: job.provider,
                                 model: Self.modelName(for: job), turn: "job:\(job.id)#\(max(1, job.runs.count))", client: client,
                                 measure: measure, costUSD: price?.cost(of: measure), estimate: price?.estimate)
        recorder.record(record)
        return record
    }
}

/// The installed `ProviderResilience`'s ledger, looked up at each record (nil records nothing).
public struct InstalledUsageRecorder: UsageRecording {
    public init() {}
    public func record(_ record: UsageRecord) { ProviderResilience.installed?.recorder?.record(record) }
    public func limitStatus() -> UsageLimitStatus { ProviderResilience.installed?.recorder?.limitStatus() ?? .unlimited }
}
