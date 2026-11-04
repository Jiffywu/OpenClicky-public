import Darwin
import Foundation

// The local usage ledger (docs/infra.md): every model call, spoken line, listening session, realtime reply and lookup
// is written as one JSON line under Application Support/OpenClicky/Usage, with tokens, seconds or characters and a cost
// from the catalog's prices. HeyClicky meters usage on its server (leases, credits); OpenClicky keeps the record on the
// Mac, adds it up by day, slot and surface, and can warn or stop at a limit the user sets.

// MARK: - Prices

/// One price tier: what a model costs once a prompt is at least `minPromptTokens` long (long-context pricing).
public struct PriceTier: Codable, Sendable, Hashable {
    public var minPromptTokens: Int
    public var inputPerMillion: Double?
    public var cachedInputPerMillion: Double?
    public var cacheWritePerMillion: Double?
    public var outputPerMillion: Double?

    public init(minPromptTokens: Int, inputPerMillion: Double? = nil, cachedInputPerMillion: Double? = nil, outputPerMillion: Double? = nil,
                cacheWritePerMillion: Double? = nil) {
        self.minPromptTokens = minPromptTokens
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.outputPerMillion = outputPerMillion
    }
}

/// What a model costs, in US dollars. Each field is optional: a speech model has only a per-character or per-minute
/// price. `model-catalog.json` carries prices for the models it knows; a model declared in config can carry its own.
public struct ModelPrice: Codable, Sendable, Hashable {
    /// Per million input tokens (cached ones included unless `cachedInputPerMillion` is given).
    public var inputPerMillion: Double?
    /// Per million input tokens read from the provider's prompt cache.
    public var cachedInputPerMillion: Double?
    /// Per million input tokens written to the provider's prompt cache (Anthropic charges a premium for them); nil
    /// prices them as plain input.
    public var cacheWritePerMillion: Double?
    public var outputPerMillion: Double?
    /// Realtime models: per million audio tokens in and out (text tokens use the fields above).
    public var audioInputPerMillion: Double?
    public var audioOutputPerMillion: Double?
    /// Speech to text: per minute of audio sent.
    public var perMinute: Double?
    /// Text to speech: per thousand characters spoken.
    public var perThousandCharacters: Double?
    /// Text to speech priced by the audio it makes: per minute of speech produced.
    public var perMinuteSpoken: Double?
    /// Lookups and other per-call services.
    public var perRequest: Double?
    /// Higher prices for long prompts, lowest threshold first.
    public var tiers: [PriceTier]?
    /// Where the numbers came from, and when.
    public var source: String?
    /// True when the numbers are an estimate (the provider prices in credits or plans), shown with "≈".
    public var estimate: Bool?

    public init(inputPerMillion: Double? = nil, cachedInputPerMillion: Double? = nil, outputPerMillion: Double? = nil,
                audioInputPerMillion: Double? = nil, audioOutputPerMillion: Double? = nil, perMinute: Double? = nil,
                perThousandCharacters: Double? = nil, perRequest: Double? = nil, tiers: [PriceTier]? = nil,
                source: String? = nil, estimate: Bool? = nil, cacheWritePerMillion: Double? = nil, perMinuteSpoken: Double? = nil) {
        self.cacheWritePerMillion = cacheWritePerMillion
        self.perMinuteSpoken = perMinuteSpoken
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
        self.audioInputPerMillion = audioInputPerMillion
        self.audioOutputPerMillion = audioOutputPerMillion
        self.perMinute = perMinute
        self.perThousandCharacters = perThousandCharacters
        self.perRequest = perRequest
        self.tiers = tiers
        self.source = source
        self.estimate = estimate
    }

    /// Free (on-device models).
    public static let free = ModelPrice(inputPerMillion: 0, outputPerMillion: 0, perMinute: 0, perThousandCharacters: 0, perRequest: 0,
                                        source: "runs on this Mac")

    /// The cost of what a record measured, or nil when this price says nothing about it.
    public func cost(of usage: UsageMeasure) -> Double? {
        var total = 0.0
        var priced = false
        let prompt = usage.inputTokens ?? 0
        let tier = tiers?.filter { prompt >= $0.minPromptTokens }.max { $0.minPromptTokens < $1.minPromptTokens }
        let inputRate = tier?.inputPerMillion ?? inputPerMillion
        let cachedRate = tier?.cachedInputPerMillion ?? cachedInputPerMillion ?? inputRate
        let writeRate = tier?.cacheWritePerMillion ?? cacheWritePerMillion ?? inputRate
        let outputRate = tier?.outputPerMillion ?? outputPerMillion
        // Audio tokens of a realtime reply are priced on their own when the model has audio prices; the rest of the
        // tokens are text.
        let audioIn = audioInputPerMillion != nil ? (usage.audioInputTokens ?? 0) : 0
        let audioOut = audioOutputPerMillion != nil ? (usage.audioOutputTokens ?? 0) : 0
        if usage.inputTokens != nil || usage.outputTokens != nil {
            let cached = min(usage.cachedInputTokens ?? 0, prompt)
            // Tokens written to the prompt cache are part of the prompt but cost their own (higher) rate.
            let written = min(usage.cacheWriteTokens ?? 0, prompt - cached)
            let uncached = max(0, prompt - cached - written - audioIn)
            if let inputRate { total += Double(uncached) * inputRate / 1e6; priced = true }
            if cached > 0, let cachedRate { total += Double(cached) * cachedRate / 1e6; priced = true }
            if written > 0, let writeRate { total += Double(written) * writeRate / 1e6; priced = true }
            if let outputRate { total += Double(max(0, (usage.outputTokens ?? 0) - audioOut)) * outputRate / 1e6; priced = true }
        }
        if let rate = audioInputPerMillion, audioIn > 0 { total += Double(audioIn) * rate / 1e6; priced = true }
        if let rate = audioOutputPerMillion, audioOut > 0 { total += Double(audioOut) * rate / 1e6; priced = true }
        if let rate = perMinute, let seconds = usage.audioSeconds, usage.characters == nil { total += seconds / 60 * rate; priced = true }
        if let rate = perThousandCharacters, let characters = usage.characters { total += Double(characters) / 1000 * rate; priced = true }
        if let rate = perMinuteSpoken, let seconds = usage.audioSeconds, usage.characters != nil { total += seconds / 60 * rate; priced = true }
        if let rate = perRequest, usage.inputTokens == nil, usage.characters == nil, usage.audioSeconds == nil {
            total += Double(usage.requests) * rate
            priced = true
        }
        return priced ? total : nil
    }
}

/// The quantities one record measured (also what a price is applied to).
public struct UsageMeasure: Sendable, Hashable {
    public var requests: Int
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    /// Input tokens written to the prompt cache (part of `inputTokens`).
    public var cacheWriteTokens: Int?
    public var outputTokens: Int?
    public var audioInputTokens: Int?
    public var audioOutputTokens: Int?
    public var audioSeconds: Double?
    public var characters: Int?

    public init(requests: Int = 1, inputTokens: Int? = nil, cachedInputTokens: Int? = nil, outputTokens: Int? = nil,
                audioInputTokens: Int? = nil, audioOutputTokens: Int? = nil, audioSeconds: Double? = nil, characters: Int? = nil,
                cacheWriteTokens: Int? = nil) {
        self.requests = requests
        self.cacheWriteTokens = cacheWriteTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.audioInputTokens = audioInputTokens
        self.audioOutputTokens = audioOutputTokens
        self.audioSeconds = audioSeconds
        self.characters = characters
    }

    public init(_ usage: TokenUsage) {
        self.init(inputTokens: usage.inputTokens, cachedInputTokens: usage.cachedInputTokens, outputTokens: usage.outputTokens,
                  cacheWriteTokens: usage.cacheWriteTokens > 0 ? usage.cacheWriteTokens : nil)
    }
}

/// Prices for models (from the catalog and the config's own model declarations) and for lookup services.
public struct PriceBook: Sendable {
    public var catalog: ModelCatalog
    /// Per-request services, by provider id ("brave", "exa", "wikimedia-commons", "mapkit").
    public var services: [String: ModelPrice]

    public init(catalog: ModelCatalog, services: [String: ModelPrice] = [:]) {
        self.catalog = catalog
        self.services = services
    }

    /// The built-in catalog's prices plus its service prices.
    public static func builtIn(merging declared: [ModelDescriptor] = []) -> PriceBook {
        let catalog = ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(declared)
        return PriceBook(catalog: catalog, services: builtInServicePrices())
    }

    /// The `servicePrices` section of model-catalog.json.
    public static func builtInServicePrices() -> [String: ModelPrice] {
        struct File: Decodable { var servicePrices: [String: ModelPrice]? }
        guard let url = ModelCatalog.resourceURL("model-catalog", "json"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return file.servicePrices ?? [:]
    }

    /// The price of `model` as served by `dialect` (falling back to any catalog entry with that id). On-device
    /// dialects are free whatever the catalog says.
    public func price(model: String, dialect: ProviderDialect?) -> ModelPrice? {
        if let dialect, dialect.isOnDevice { return .free }
        if let dialect, let found = catalog.model(model, servedBy: dialect)?.price { return found }
        return catalog.models(named: model).lazy.compactMap(\.price).first
    }

    public func servicePrice(_ provider: String) -> ModelPrice? { services[provider] }
}

// MARK: - Records

/// Where the usage came from, beyond the slot: the voice loop, typed questions, always-on, dictation, occtl…
public struct UsageSurface: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let voiceTurn: UsageSurface = "voice turn"
    public static let typedTurn: UsageSurface = "typed turn"
    public static let reportTurn: UsageSurface = "job report"
    public static let guidedTurn: UsageSurface = "walkthrough"
    public static let realtime: UsageSurface = "realtime"
    public static let dictation: UsageSurface = "dictation"
    public static let chat: UsageSurface = "home chat"
    public static let takeover: UsageSurface = "take-over"
    public static let lookups: UsageSurface = "lookups"
    /// Background agent jobs (Codex and Claude Code runs).
    public static let jobs: UsageSurface = "jobs"
    public static let occtl: UsageSurface = "occtl"

    /// The surface for a record that came with no context: named after what the slot does.
    public static func fallback(for slot: String) -> UsageSurface {
        switch slot {
        case SlotID.stt.rawValue: "listening"
        case SlotID.voice.rawValue: "voice lines"
        case SlotID.realtimeVoice.rawValue: .realtime
        case SlotID.brainFast.rawValue: "background text"
        case SlotID.agent.rawValue: .jobs
        case UsageRecord.lookupsSlot: .lookups
        default: "brain"
        }
    }
}

/// Context carried down a task tree, so records made deep inside a turn know which turn and surface they belong to.
public struct UsageContext: Sendable, Hashable {
    public var surface: UsageSurface?
    /// Groups the records of one turn (a voice turn's listening, brain rounds, spoken lines and lookups).
    public var turnID: String?

    public init(surface: UsageSurface? = nil, turnID: String? = nil) {
        self.surface = surface
        self.turnID = turnID
    }

    @TaskLocal public static var current = UsageContext()

    /// A fresh turn on `surface`.
    public static func turn(_ surface: UsageSurface) -> UsageContext { UsageContext(surface: surface, turnID: UUID().uuidString) }
}

/// One line of the ledger.
public struct UsageRecord: Codable, Sendable, Hashable, Identifiable {
    /// The pseudo-slot for lookup services.
    public static let lookupsSlot = "lookups"

    public var id: String
    public var at: Date
    /// A model slot's raw value ("brain", "stt", "voice", "brain-fast", "realtime-voice", "agent") or "lookups".
    public var slot: String
    public var surface: String
    /// The provider id from config, or the lookup service ("brave").
    public var provider: String
    /// The model id, or the lookup kind ("web-search").
    public var model: String?
    public var turn: String?
    /// "app" or "occtl".
    public var client: String?
    public var requests: Int
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    /// Input tokens written to the prompt cache (part of `inputTokens`).
    public var cacheWriteTokens: Int?
    public var outputTokens: Int?
    public var audioInputTokens: Int?
    public var audioOutputTokens: Int?
    /// Seconds of audio sent to listening, or spoken by the voice.
    public var audioSeconds: Double?
    /// Characters sent to the voice.
    public var characters: Int?
    /// US dollars, from the price known when the record was made; nil when no price was known.
    public var costUSD: Double?
    /// The price used was an estimate.
    public var estimate: Bool?

    public init(id: String = UUID().uuidString, at: Date = Date(), slot: String, surface: String, provider: String, model: String?,
                turn: String? = nil, client: String? = nil, measure: UsageMeasure, costUSD: Double?, estimate: Bool? = nil) {
        self.id = id
        self.at = at
        self.slot = slot
        self.surface = surface
        self.provider = provider
        self.model = model
        self.turn = turn
        self.client = client
        requests = measure.requests
        inputTokens = measure.inputTokens
        cachedInputTokens = measure.cachedInputTokens
        cacheWriteTokens = measure.cacheWriteTokens
        outputTokens = measure.outputTokens
        audioInputTokens = measure.audioInputTokens
        audioOutputTokens = measure.audioOutputTokens
        audioSeconds = measure.audioSeconds
        characters = measure.characters
        self.costUSD = costUSD
        self.estimate = estimate
    }

    public var measure: UsageMeasure {
        UsageMeasure(requests: requests, inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, outputTokens: outputTokens,
                     audioInputTokens: audioInputTokens, audioOutputTokens: audioOutputTokens, audioSeconds: audioSeconds, characters: characters,
                     cacheWriteTokens: cacheWriteTokens)
    }
}

/// Anything that takes usage records: the ledger, or a test's collector.
public protocol UsageRecording: Sendable {
    func record(_ record: UsageRecord)
    /// Where spending stands against the user's limits (checked before a model call when limits stop calls).
    func limitStatus() -> UsageLimitStatus
}

extension UsageRecording {
    public func limitStatus() -> UsageLimitStatus { .unlimited }
}

// MARK: - Limits

/// Spending limits the user sets. Off unless a limit is set.
public struct UsageLimits: Codable, Sendable, Equatable {
    public var dailyUSD: Double?
    public var monthlyUSD: Double?
    /// Warn once spending reaches this share of a limit.
    public var warnAtFraction: Double
    /// Refuse new brain, voice and listening calls once a limit is reached (otherwise only warn).
    public var stopAtLimit: Bool

    public init(dailyUSD: Double? = nil, monthlyUSD: Double? = nil, warnAtFraction: Double = 0.8, stopAtLimit: Bool = false) {
        self.dailyUSD = dailyUSD
        self.monthlyUSD = monthlyUSD
        self.warnAtFraction = warnAtFraction
        self.stopAtLimit = stopAtLimit
    }

    public var isSet: Bool { (dailyUSD ?? 0) > 0 || (monthlyUSD ?? 0) > 0 }

    /// Where spending of `today` and `month` stands.
    public func status(today: Double, month: Double) -> UsageLimitStatus {
        var worst = UsageLimitStatus.unlimited
        for (period, spent, limit) in [(UsageLimitStatus.Period.month, month, monthlyUSD), (.day, today, dailyUSD)] {
            guard let limit, limit > 0 else { continue }
            let level: UsageLimitStatus.Level = spent >= limit ? .reached : (spent >= limit * warnAtFraction ? .warning : .ok)
            let candidate = UsageLimitStatus(level: level, period: period, spentUSD: spent, limitUSD: limit, stops: stopAtLimit)
            if candidate.level.rank > worst.level.rank || worst.limitUSD == nil { worst = candidate }
        }
        return worst
    }
}

/// How spending compares with the limits.
public struct UsageLimitStatus: Sendable, Hashable {
    public enum Level: String, Sendable, Hashable, Codable {
        case ok, warning, reached
        var rank: Int { switch self { case .ok: 0; case .warning: 1; case .reached: 2 } }
    }

    public enum Period: String, Sendable, Hashable, Codable { case day, month }

    public var level: Level
    public var period: Period?
    public var spentUSD: Double
    public var limitUSD: Double?
    /// Calls are refused at the limit.
    public var stops: Bool

    public static let unlimited = UsageLimitStatus(level: .ok, period: nil, spentUSD: 0, limitUSD: nil, stops: false)

    /// New calls should be refused.
    public var blocksCalls: Bool { level == .reached && stops }

    /// A sentence for Settings, the menu and occtl; nil when there is nothing to say.
    public var message: String? {
        guard let limit = limitUSD, let period else { return nil }
        let when = period == .day ? "today" : "this month"
        let spent = UsageFormat.dollars(spentUSD), cap = UsageFormat.dollars(limit)
        switch level {
        case .ok: return nil
        case .warning: return "You've used \(spent) of your \(cap) limit \(when)."
        case .reached:
            return stops ? "You've reached your \(cap) limit \(when), so OpenClicky has stopped calling paid models. Raise it in Settings → Usage."
                         : "You've gone past your \(cap) limit \(when) (\(spent))."
        }
    }
}

/// Thrown instead of calling a model once the user's limit is reached and limits stop calls.
public struct UsageLimitError: Error, Sendable, CustomStringConvertible, LocalizedError, SpokenError {
    public var status: UsageLimitStatus
    public init(status: UsageLimitStatus) { self.status = status }
    public var description: String { status.message ?? "The usage limit is reached." }
    public var errorDescription: String? { description }
    public var spokenExplanation: String {
        "You've reached the spending limit you set for \(status.period == .month ? "this month" : "today"). You can raise it in Settings, under Usage."
    }
}

// MARK: - Summaries

/// Totals for one group of records.
public struct UsageTotals: Sendable, Hashable, Codable {
    public var records = 0
    public var requests = 0
    public var inputTokens = 0
    public var cachedInputTokens = 0
    public var cacheWriteTokens = 0
    public var outputTokens = 0
    public var audioSeconds = 0.0
    public var characters = 0
    public var costUSD = 0.0
    /// Records with no known price (their cost is missing from `costUSD`).
    public var unpriced = 0
    public var estimated = 0

    public init() {}

    public mutating func add(_ record: UsageRecord) {
        records += 1
        requests += record.requests
        inputTokens += record.inputTokens ?? 0
        cachedInputTokens += record.cachedInputTokens ?? 0
        cacheWriteTokens += record.cacheWriteTokens ?? 0
        outputTokens += record.outputTokens ?? 0
        audioSeconds += record.audioSeconds ?? 0
        characters += record.characters ?? 0
        if let cost = record.costUSD { costUSD += cost } else { unpriced += 1 }
        if record.estimate == true { estimated += 1 }
    }
}

/// Records added up by day, slot, surface and model, plus per-turn costs.
public struct UsageSummary: Sendable, Hashable {
    public var from: Date
    public var to: Date
    public var total = UsageTotals()
    /// Keyed by local day, "2026-10-31".
    public var byDay: [String: UsageTotals] = [:]
    public var bySlot: [String: UsageTotals] = [:]
    public var bySurface: [String: UsageTotals] = [:]
    /// Keyed "provider · model".
    public var byModel: [String: UsageTotals] = [:]
    /// Background jobs (the agent slot's "jobs" surface), keyed by job id.
    public var byJob: [String: UsageTotals] = [:]
    /// The most recent turns, newest first.
    public var recentTurns: [TurnCost] = []

    public struct TurnCost: Sendable, Hashable {
        public var turn: String
        public var surface: String
        public var at: Date
        public var totals: UsageTotals
    }

    public init(records: [UsageRecord], from: Date, to: Date, calendar: Calendar = .current, turnLimit: Int = 20) {
        self.from = from
        self.to = to
        var turns: [String: TurnCost] = [:]
        for record in records where record.at >= from && record.at < to {
            total.add(record)
            byDay[UsageFormat.day(record.at, calendar: calendar), default: UsageTotals()].add(record)
            bySlot[record.slot, default: UsageTotals()].add(record)
            bySurface[record.surface, default: UsageTotals()].add(record)
            byModel[record.provider + " · " + (record.model ?? "-"), default: UsageTotals()].add(record)
            if let job = Self.jobID(of: record) { byJob[job, default: UsageTotals()].add(record) }
            if let turn = record.turn {
                var entry = turns[turn] ?? TurnCost(turn: turn, surface: record.surface, at: record.at, totals: UsageTotals())
                entry.at = min(entry.at, record.at)
                entry.totals.add(record)
                turns[turn] = entry
            }
        }
        recentTurns = Array(turns.values.sorted { $0.at > $1.at }.prefix(turnLimit))
    }

    /// The job a record belongs to: its turn is "job:<id>#<run>".
    public static func jobID(of record: UsageRecord) -> String? {
        guard record.surface == UsageSurface.jobs.rawValue, let turn = record.turn, turn.hasPrefix("job:") else { return nil }
        let rest = turn.dropFirst(4)
        return String(rest.split(separator: "#", maxSplits: 1).first ?? rest)
    }
}

public enum UsageFormat {
    public static func dollars(_ value: Double) -> String {
        if value == 0 { return "$0.00" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        return String(format: "$%.2f", value)
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM", Double(count) / 1e6) : count >= 10_000 ? String(format: "%.0fk", Double(count) / 1e3)
            : count >= 1_000 ? String(format: "%.1fk", Double(count) / 1e3) : "\(count)"
    }

    /// "$0.0123", "≈$0.01", or "—" when nothing was priced.
    public static func cost(_ totals: UsageTotals) -> String {
        if totals.records > 0 && totals.unpriced == totals.records { return "—" }
        return (totals.estimated > 0 ? "≈" : "") + dollars(totals.costUSD) + (totals.unpriced > 0 ? "+" : "")
    }
}

// MARK: - The ledger

/// The ledger on disk: one JSON line per record in `usage-YYYY-MM.jsonl` files, and the limits in `limits.json`.
/// Safe to share between threads; the app and `occtl` may append to the same folder.
public final class UsageLedger: UsageRecording, @unchecked Sendable {
    public let directory: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Spending of the current day and month, kept up to date as records are added (and re-read when another
    /// process appended).
    private var cachedTotals: (day: String, month: String, today: Double, monthTotal: Double, fileSize: UInt64)?
    /// How many times the month was read from disk to total it (tests check the cache holds).
    private(set) var monthReads = 0
    /// Called after each record with where spending now stands (for warnings).
    public var onRecord: (@Sendable (UsageRecord, UsageLimitStatus) -> Void)? {
        get { lock.withLock { recordHandler } }
        set { lock.withLock { recordHandler = newValue } }
    }
    private var recordHandler: (@Sendable (UsageRecord, UsageLimitStatus) -> Void)?

    public init(directory: URL = UsageLedger.defaultDirectory, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.calendar = calendar
        self.now = now
    }

    /// `~/Library/Application Support/OpenClicky/Usage`, or `OPENCLICKY_USAGE_DIR` when set (tests, evidence runs).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_USAGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true).appendingPathComponent("Usage", isDirectory: true)
    }

    public var limitsURL: URL { directory.appendingPathComponent("limits.json") }

    func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent("usage-\(UsageFormat.month(date, calendar: calendar)).jsonl")
    }

    // MARK: Writing

    public func record(_ record: UsageRecord) {
        let status: UsageLimitStatus = lock.withLock {
            let written = append(record)
            // The cached totals stay valid only if the file still ended where they were read: then this record is the
            // only line added since, and adding its cost avoids re-reading the month. Otherwise another process
            // appended (or the write failed), and the next status reads the file again.
            if var totals = cachedTotals, let written, UsageFormat.month(record.at, calendar: calendar) == totals.month,
               written.url == fileURL(for: now()), totals.fileSize == written.start {
                if UsageFormat.day(record.at, calendar: calendar) == totals.day { totals.today += record.costUSD ?? 0 }
                totals.monthTotal += record.costUSD ?? 0
                totals.fileSize = written.end
                cachedTotals = totals
            } else if written == nil || UsageFormat.month(record.at, calendar: calendar) == cachedTotals?.month {
                cachedTotals = nil
            }
            return currentStatus()
        }
        onRecord?(record, status)
    }

    /// Appends one line under an exclusive file lock. Returns where the file ended before and after it, or nil when
    /// nothing was written.
    @discardableResult
    private func append(_ record: UsageRecord) -> (url: URL, start: UInt64, end: UInt64)? {
        let url = fileURL(for: record.at)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(record) else { return nil }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw Self.fileError() }
            defer { Darwin.close(descriptor) }
            try Self.lockFile(descriptor, operation: LOCK_EX)
            defer { _ = flock(descriptor, LOCK_UN) }
            let start = Darwin.lseek(descriptor, 0, SEEK_END)
            guard start >= 0 else { throw Self.fileError() }
            do {
                try line.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw Self.fileError() }
                        offset += written
                    }
                }
            } catch {
                _ = Darwin.ftruncate(descriptor, start)
                throw error
            }
            return (url, UInt64(start), UInt64(start) + UInt64(line.count))
        } catch {
            // The ledger never stops a turn.
            return nil
        }
    }

    private static func fileError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func lockFile(_ descriptor: Int32, operation: Int32) throws {
        while flock(descriptor, operation) != 0 {
            if errno != EINTR { throw fileError() }
        }
    }

    private func readFile(_ url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try Self.lockFile(descriptor, operation: LOCK_SH)
            defer { _ = flock(descriptor, LOCK_UN) }
            return try handle.readToEnd() ?? Data()
        } catch { return nil }
    }

    // MARK: Reading

    /// Records made from `from` up to `to`.
    public func records(from: Date, to: Date = .distantFuture) -> [UsageRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var result: [UsageRecord] = []
        for url in files(from: from, to: min(to, now().addingTimeInterval(86_400))) {
            guard let data = readFile(url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let record = try? decoder.decode(UsageRecord.self, from: line), record.at >= from, record.at < to { result.append(record) }
            }
        }
        return result.sorted { $0.at < $1.at }
    }

    /// The month files that can hold records between two dates.
    private func files(from: Date, to: Date) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let first = "usage-\(UsageFormat.month(max(from, Date(timeIntervalSince1970: 0)), calendar: calendar)).jsonl"
        let last = "usage-\(UsageFormat.month(to, calendar: calendar)).jsonl"
        return names.filter { $0.hasPrefix("usage-") && $0.hasSuffix(".jsonl") && $0 >= first && $0 <= last }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// The summary of the last `days` days (today included).
    public func summary(days: Int, turnLimit: Int = 20) -> UsageSummary {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now())) ?? now()
        let start = calendar.date(byAdding: .day, value: -max(1, days), to: end) ?? end
        return UsageSummary(records: records(from: start, to: end), from: start, to: end, calendar: calendar, turnLimit: turnLimit)
    }

    // MARK: Limits

    public func limits() -> UsageLimits { lock.withLock { loadLimits() } }

    public func setLimits(_ limits: UsageLimits) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(limits).write(to: limitsURL, options: .atomic)
        }
    }

    public func limitStatus() -> UsageLimitStatus { lock.withLock { currentStatus() } }

    /// Spent today and this month.
    public func spending() -> (today: Double, month: Double) {
        lock.withLock {
            let totals = currentTotals()
            return (totals.today, totals.monthTotal)
        }
    }

    private func loadLimits() -> UsageLimits {
        // This small atomic file may be replaced by another process, even with the same modification time.
        (try? Data(contentsOf: limitsURL)).flatMap { try? JSONDecoder().decode(UsageLimits.self, from: $0) } ?? UsageLimits()
    }

    private func currentStatus() -> UsageLimitStatus {
        let limits = loadLimits()
        guard limits.isSet else { return .unlimited }
        let totals = currentTotals()
        return limits.status(today: totals.today, month: totals.monthTotal)
    }

    private func currentTotals() -> (day: String, month: String, today: Double, monthTotal: Double, fileSize: UInt64) {
        let date = now()
        let day = UsageFormat.day(date, calendar: calendar), month = UsageFormat.month(date, calendar: calendar)
        let size = fileSize(fileURL(for: date))
        if let cached = cachedTotals, cached.day == day, cached.month == month, cached.fileSize == size { return cached }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        monthReads += 1
        var today = 0.0, monthTotal = 0.0
        for record in records(from: monthStart) {
            monthTotal += record.costUSD ?? 0
            if UsageFormat.day(record.at, calendar: calendar) == day { today += record.costUSD ?? 0 }
        }
        let fresh = (day, month, today, monthTotal, size)
        cachedTotals = fresh
        return fresh
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

/// Collects records in memory (tests, `occtl` dry runs).
public final class UsageCollector: UsageRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [UsageRecord] = []
    private let status: UsageLimitStatus

    public init(status: UsageLimitStatus = .unlimited) { self.status = status }

    public func record(_ record: UsageRecord) { lock.withLock { collected.append(record) } }
    public func limitStatus() -> UsageLimitStatus { status }
    public var records: [UsageRecord] { lock.withLock { collected } }
}
