import Foundation
import OpenClickyKit

/// `occtl usage`, `occtl probe`, `occtl diagnostics` and `occtl flags` (docs/infra.md).
enum InfraCommands {
    // MARK: - usage

    static let usage = OcctlCommand(
        name: "usage",
        usage: "usage [--days n] [--json] | usage limits [--daily $] [--monthly $] [--warn 0.8] [--stop|--no-stop] [--clear] | usage prices [config.json]"
    ) { args in
        let ledger = UsageLedger()
        switch args.first {
        case "limits": try limits(Array(args.dropFirst()), ledger: ledger)
        case "prices": try prices(args.dropFirst().first)
        default: try summary(args, ledger: ledger)
        }
    }

    private static func summary(_ args: [String], ledger: UsageLedger) throws {
        var days = 7
        var json = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--days":
                index += 1
                guard index < args.count, let value = Int(args[index]), value > 0 else { fail("--days needs a positive number") }
                days = value
            case "--json": json = true
            default: fail("Unknown option \(args[index]). Usage: occtl usage [--days n] [--json]")
            }
            index += 1
        }
        let summary = ledger.summary(days: days)
        let status = ledger.limitStatus()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            struct Out: Encodable {
                var days: Int
                var total: UsageTotals
                var byDay: [String: UsageTotals]
                var bySlot: [String: UsageTotals]
                var bySurface: [String: UsageTotals]
                var byModel: [String: UsageTotals]
                var byJob: [String: UsageTotals]
                var limits: UsageLimits
                var status: String
                var message: String?
            }
            let out = Out(days: days, total: summary.total, byDay: summary.byDay, bySlot: summary.bySlot, bySurface: summary.bySurface,
                          byModel: summary.byModel, byJob: summary.byJob, limits: ledger.limits(), status: status.level.rawValue, message: status.message)
            print(String(decoding: try encoder.encode(out), as: UTF8.self))
            return
        }
        print("Usage, last \(days) day\(days == 1 ? "" : "s") (ledger: \(ledger.directory.path))")
        print("Total: \(UsageFormat.cost(summary.total)) over \(summary.total.records) records\(summary.total.unpriced > 0 ? " (\(summary.total.unpriced) without a known price)" : "")")
        func table(_ title: String, _ rows: [String: UsageTotals]) {
            guard !rows.isEmpty else { return }
            print("\n\(title)")
            let width = rows.keys.map(\.count).max() ?? 0
            for (key, totals) in rows.sorted(by: { $0.key < $1.key }) {
                var parts = ["\(totals.records) rec", UsageFormat.cost(totals)]
                if totals.inputTokens + totals.outputTokens > 0 {
                    let written = totals.cacheWriteTokens > 0 ? ", \(UsageFormat.tokens(totals.cacheWriteTokens)) cache writes" : ""
                    parts.append("\(UsageFormat.tokens(totals.inputTokens)) in (\(UsageFormat.tokens(totals.cachedInputTokens)) cached\(written)) / \(UsageFormat.tokens(totals.outputTokens)) out")
                }
                if totals.audioSeconds > 0 { parts.append(String(format: "%.1f s audio", totals.audioSeconds)) }
                if totals.characters > 0 { parts.append("\(totals.characters) chars") }
                print("  \(key.padding(toLength: width, withPad: " ", startingAt: 0))  " + parts.joined(separator: " · "))
            }
        }
        table("By day", summary.byDay)
        table("By slot", summary.bySlot)
        table("By surface", summary.bySurface)
        table("By provider and model", summary.byModel)
        table("Background jobs", summary.byJob)
        if !summary.recentTurns.isEmpty {
            print("\nRecent turns")
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            for turn in summary.recentTurns.prefix(10) {
                print("  \(formatter.string(from: turn.at))  \(turn.surface)  \(UsageFormat.cost(turn.totals))  (\(turn.totals.records) records)")
            }
        }
        let limits = ledger.limits()
        print("\nLimits: " + (limits.isSet
            ? [limits.dailyUSD.map { "daily \(UsageFormat.dollars($0))" }, limits.monthlyUSD.map { "monthly \(UsageFormat.dollars($0))" }]
                .compactMap { $0 }.joined(separator: ", ") + (limits.stopAtLimit ? ", stop at the limit" : ", warn only")
            : "none"))
        if let message = status.message { print("⚠︎ " + message) }
    }

    private static func limits(_ args: [String], ledger: UsageLedger) throws {
        var limits = ledger.limits()
        var index = 0
        func number(_ flag: String) -> Double {
            index += 1
            guard index < args.count, let value = Double(args[index].replacingOccurrences(of: "$", with: "")), value >= 0 else {
                fail("\(flag) needs a dollar amount")
            }
            return value
        }
        while index < args.count {
            switch args[index] {
            case "--daily": limits.dailyUSD = number("--daily").nonZero
            case "--monthly": limits.monthlyUSD = number("--monthly").nonZero
            case "--warn": limits.warnAtFraction = min(1, max(0.1, number("--warn")))
            case "--stop": limits.stopAtLimit = true
            case "--no-stop": limits.stopAtLimit = false
            case "--clear": limits = UsageLimits()
            default: fail("Unknown option \(args[index]).")
            }
            index += 1
        }
        if !args.isEmpty { try ledger.setLimits(limits) }
        let spending = ledger.spending()
        print("Daily limit: \(limits.dailyUSD.map(UsageFormat.dollars) ?? "none") (today \(UsageFormat.dollars(spending.today)))")
        print("Monthly limit: \(limits.monthlyUSD.map(UsageFormat.dollars) ?? "none") (this month \(UsageFormat.dollars(spending.month)))")
        print("Warn at \(Int(limits.warnAtFraction * 100))%; \(limits.stopAtLimit ? "stop paid calls at the limit" : "warn only")")
        if let message = ledger.limitStatus().message { print("⚠︎ " + message) }
    }

    private static func prices(_ configPath: String?) throws {
        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let book = PriceBook.builtIn(merging: config.models)
        for slot in SlotID.allCases {
            guard let selection = config.selection(for: slot) else { continue }
            let dialect = config.provider(selection.provider)?.dialect
            let price = book.price(model: selection.model, dialect: dialect)
            print("\(slot.rawValue): \(selection.provider) \(selection.model) — \(price.map(describe) ?? "no known price (tokens are still counted)")")
        }
        for (service, price) in book.services.sorted(by: { $0.key < $1.key }) { print("lookups: \(service) — \(describe(price))") }
    }

    private static func describe(_ price: ModelPrice) -> String {
        let values = [price.inputPerMillion, price.cachedInputPerMillion, price.outputPerMillion, price.perThousandCharacters,
                      price.perMinute, price.perRequest].compactMap { $0 }
        if !values.isEmpty, values.allSatisfy({ $0 == 0 }) { return "free" + (price.source.map { " [\($0)]" } ?? "") }
        var parts: [String] = []
        if let value = price.inputPerMillion { parts.append("in $\(value)/M") }
        if let value = price.cachedInputPerMillion { parts.append("cached $\(value)/M") }
        if let value = price.cacheWritePerMillion { parts.append("cache writes $\(value)/M") }
        if let value = price.outputPerMillion { parts.append("out $\(value)/M") }
        if let value = price.audioInputPerMillion { parts.append("audio in $\(value)/M") }
        if let value = price.audioOutputPerMillion { parts.append("audio out $\(value)/M") }
        if let value = price.perThousandCharacters { parts.append("$\(value)/1k chars") }
        if let value = price.perMinuteSpoken { parts.append("$\(value)/min spoken") }
        if let value = price.perMinute { parts.append("$\(value)/min") }
        if let value = price.perRequest { parts.append("$\(value)/request") }
        if price.estimate == true { parts.append("estimate") }
        return parts.joined(separator: ", ") + (price.source.map { " [\($0)]" } ?? "")
    }

    // MARK: - probe

    static let probe = OcctlCommand(
        name: "probe",
        usage: "probe [--config c.json] [--no-key] [slot…] | probe --simulate region|blocked|offline|key|down [--slot s]  diagnose why a provider can't open"
    ) { args in
        var configPath: String?
        var useKey = true
        var slots: [SlotID] = []
        var simulate: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--config":
                index += 1
                guard index < args.count else { fail("--config needs a value") }
                configPath = args[index]
            case "--no-key": useKey = false
            case "--simulate":
                index += 1
                guard index < args.count else { fail("--simulate needs a case") }
                simulate = args[index]
            case "--slot":
                index += 1
                guard index < args.count, let slot = SlotID(rawValue: args[index]) else { fail("--slot needs a slot name") }
                slots.append(slot)
            default:
                guard let slot = SlotID(rawValue: args[index]) else { fail("Unknown slot \(args[index])") }
                slots.append(slot)
            }
            index += 1
        }
        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        if let simulate {
            try await simulateFailure(simulate, slot: slots.first ?? .realtimeVoice)
            return
        }
        let chosen = slots.isEmpty ? [SlotID.stt, .voice, .brain, .brainFast, .realtimeVoice] : slots
        let probe = ProviderProbe()
        var probed: Set<String> = []
        for slot in chosen {
            guard let selection = config.selection(for: slot), let provider = config.provider(selection.provider) else {
                print("\(slot.rawValue): not set")
                continue
            }
            guard ProviderProbe.probeURL(for: provider) != nil else {
                print("\(slot.rawValue): \(provider.id) runs on this Mac; nothing to probe")
                continue
            }
            if probed.contains(provider.id) { print("\(slot.rawValue): \(provider.id) (probed above)"); continue }
            probed.insert(provider.id)
            let key = useKey ? provider.credential.flatMap { try? CoreCommands.store.secret(named: $0) } : nil
            guard let result = await probe.probe(provider, apiKey: key) else { continue }
            var verdict = ProviderProbe.classify(result)
            // Without a key a 401 only says the provider answered from here (HeyClicky's region check works this way).
            if key == nil, verdict == .keyRejected { verdict = .reachable }
            print("\(slot.rawValue): \(provider.id) → \(verdict.rawValue) (\(result.summary)\(key == nil ? ", no key sent" : ", key sent"))")
            if verdict != .reachable {
                let diagnosis = ProviderDiagnosis(providerID: provider.id, providerName: ProviderProbe.displayName(host: result.url.host ?? "", providerID: provider.id),
                                                  host: result.url.host ?? provider.id, purpose: .init(slot: slot), verdict: verdict,
                                                  probe: result.summary, failure: "probe only")
                print("    " + diagnosis.explanation)
            }
        }
    }

    /// Runs the whole failure path offline: a session open is refused, the probe answers as a blocked region, network
    /// or outage would, and the plain explanation and notch notice are printed.
    private static func simulateFailure(_ name: String, slot: SlotID) async throws {
        struct Refusing: WebSocketConnector {
            let error: any Error
            func connect(_ request: URLRequest) async throws -> any WebSocketConnection { throw error }
        }
        let refusal: any Error
        let probeAnswer: [FakeHTTPTransport.Scripted]
        switch name {
        case "region":
            refusal = ProviderError(provider: "api.openai.com", status: 403, message: "The server refused the WebSocket connection (HTTP 403 Forbidden).")
            probeAnswer = [.body(#"{"error":{"code":"unsupported_country_region_territory","message":"Country, region, or territory not supported"}}"#, status: 403)]
        case "blocked":
            refusal = URLError(.cannotConnectToHost)
            probeAnswer = [.body("<html><body>Blocked by your organization's firewall</body></html>", status: 403, contentType: "text/html")]
        case "offline":
            refusal = URLError(.notConnectedToInternet)
            probeAnswer = []
        case "key":
            refusal = ProviderError(provider: "api.openai.com", status: 401, message: "Incorrect API key provided.")
            probeAnswer = []
        case "down":
            refusal = ProviderError(provider: "api.openai.com", status: 503, message: "The server refused the WebSocket connection (HTTP 503).")
            probeAnswer = [.body("upstream unavailable", status: 503)]
        default: fail("--simulate takes region, blocked, offline, key or down")
        }
        let config = OpenClickyConfig(
            providers: [ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, baseURL: URL(string: "wss://api.openai.com/v1/realtime"), credential: "openai"),
                        ProviderConfig(id: "deepgram", dialect: .deepgramListen, baseURL: URL(string: "wss://api.deepgram.com/v1/listen"), credential: "deepgram")],
            slots: [.realtimeVoice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1"),
                    .voice: SlotSelection(provider: "openai-realtime", model: "gpt-realtime-2.1-mini"),
                    .stt: SlotSelection(provider: "deepgram", model: "nova-3")])
        let probeHTTP = FakeHTTPTransport(probeAnswer)
        let log = LogLines()
        let resilience = ProviderResilience(recorder: nil, diagnostician: ProviderDiagnostician(probe: ProviderProbe(http: probeHTTP)),
                                            sleep: { _ in }, log: { log.append($0) })
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn(),
                                    credentials: InMemoryCredentialStore(["openai": "simulated", "deepgram": "simulated"]),
                                    webSocket: Refusing(error: refusal), resilience: resilience)
        print("Simulating \(name) for the \(slot.rawValue) slot (no network: the socket and the probe are scripted).")
        let failure: Error
        do {
            switch slot {
            case .stt: _ = try await factory.speechToText().startSession(language: "en", keywords: [])
            case .voice: for try await _ in try factory.speechOutput().speak("Hello.", voice: nil, instructions: nil) {}
            default: _ = try await factory.realtimeVoice().connect(RealtimeSessionConfiguration(instructions: "simulated"))
            }
            fail("The simulated session opened, which it shouldn't.")
        } catch {
            failure = error
        }
        for line in log.lines { print("log: \(line)") }
        if let request = probeHTTP.requests.first { print("probe: GET \(request.url?.absoluteString ?? "?")") }
        print("error: \(failure)")
        if let unavailable = failure as? ProviderUnavailableError { print("verdict: \(unavailable.diagnosis.verdict.rawValue)") }
        switch slot {
        case .stt:
            let notice = TurnNotice.listeningFailed(failure)
            print("notch: \(notice.title) — \(notice.detail ?? "")")
        case .realtimeVoice:
            print("notch: Always-on voice didn't start. — Couldn't start always-on voice: \(failure)")
        default:
            print("narrator: falls back to the Mac's voice; reason: \(failure)")
        }
    }

    // MARK: - diagnostics

    static let diagnostics = OcctlCommand(
        name: "diagnostics",
        usage: "diagnostics [--out dir] [--config c.json] [--no-log] [--log-minutes n] [--note text]  write a scrubbed diagnostics bundle"
    ) { args in
        var out = DiagnosticsBundle.defaultDirectory
        var configPath: String?
        var options = DiagnosticsOptions()
        var note: String?
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--out": out = URL(fileURLWithPath: value("--out"), isDirectory: true)
            case "--config": configPath = value("--config")
            case "--no-log": options.includeUnifiedLog = false
            case "--log-minutes":
                guard let minutes = Double(value("--log-minutes")), minutes > 0 else { fail("--log-minutes needs a number") }
                options.logWindow = minutes * 60
            case "--note": note = value("--note")
            default: fail("Unknown option \(args[index]).")
            }
            index += 1
        }
        let config = try? EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let flags = FeatureFlagStore()
        let inputs = DiagnosticsInputs(client: "occtl", appState: ["arguments": .array(args.map { .string($0) })], config: config,
                                       credentials: config.map { DiagnosticsInputs.credentialStates(config: $0, store: CoreCommands.store) } ?? [:],
                                       flags: flags, usage: UsageLedger(), note: note)
        let started = Date()
        let report = try DiagnosticsBundle.write(inputs, to: out, options: options)
        print(report.summary)
        print("\nWrote \(report.files.count) files to \(report.folder.path) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for file in report.files { print("  \(file)") }
        if let zip = report.zip { print("Zip: \(zip.path)") }
    }

    // MARK: - flags

    static let flags = OcctlCommand(
        name: "flags",
        usage: "flags | flags set <id> on|off | flags reset | flags keys   OpenClicky's feature flags and HeyClicky's Clicky* keys"
    ) { args in
        let store = FeatureFlagStore()
        switch args.first {
        case nil, "list":
            let width = FeatureFlag.all.map(\.id.count).max() ?? 0
            for entry in store.snapshot() {
                let mark = entry.overridden ? "*" : " "
                print("\(mark) \(entry.flag.id.padding(toLength: width, withPad: " ", startingAt: 0))  \(entry.value ? "on " : "off")  \(entry.flag.title)"
                    + (entry.flag.isWired ? "" : "  (feature not built yet)"))
            }
            print("\n* changed from the default. File: \(store.url?.path ?? "memory")")
        case "set":
            guard args.count == 3, let flag = FeatureFlag.named(args[1]), ["on", "off", "true", "false"].contains(args[2]) else {
                fail("Usage: occtl flags set <id> on|off  (ids: occtl flags)")
            }
            try store.set(flag, args[2] == "on" || args[2] == "true")
            print("\(flag.id) is \(store.isOn(flag) ? "on" : "off")")
        case "reset":
            try store.reset()
            print("Every flag is back to its default.")
        case "keys":
            let all = HeyClickyFlagKeys.all
            for key in all {
                switch key.disposition {
                case .flag(let id): print("\(key.key) → flag \(id)")
                case .setting(let place): print("\(key.key) → setting: \(place)")
                case .dropped(let why): print("\(key.key) → dropped: \(why)")
                }
            }
            let flags = all.filter { if case .flag = $0.disposition { true } else { false } }.count
            let settings = all.filter { if case .setting = $0.disposition { true } else { false } }.count
            print("\n\(all.count) keys: \(flags) flags, \(settings) settings, \(all.count - flags - settings) dropped")
        default:
            fail("Usage: occtl flags | flags set <id> on|off | flags reset | flags keys")
        }
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
