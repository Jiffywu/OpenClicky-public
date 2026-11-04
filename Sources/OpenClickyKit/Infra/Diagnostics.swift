import CoreGraphics
import Foundation

// The local diagnostics bundle behind "Report a bug" (docs/infra.md). HeyClicky gathers app state, displays and recent
// unified logs and posts them to its server (docs/re/08-apps-memory-ui.md §10); OpenClicky writes the same kind of
// bundle to a folder and a zip on this Mac, scrubbed of keys and tokens, for the user to look at and attach.

// MARK: - Scrubbing

/// Removes secrets from text: bearer headers, provider key shapes, JWTs, OAuth parameters, key-like JSON fields, any
/// exact secrets it is given, and the home folder's path.
public struct SecretScrubber: Sendable {
    /// Exact strings to remove wherever they appear (keys from the environment the process was started with).
    public var knownSecrets: [String]
    /// Replaced with "~" (keeps the user's name out of shared logs).
    public var homeDirectory: String?

    public init(knownSecrets: [String] = [], homeDirectory: String? = NSHomeDirectory()) {
        // Short values would redact ordinary words.
        self.knownSecrets = knownSecrets.filter { $0.count >= 8 }.sorted { $0.count > $1.count }
        self.homeDirectory = homeDirectory
    }

    /// A scrubber that also removes every `OPENCLICKY_KEY_*` and `*_API_KEY` value in `environment`.
    public static func forEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> SecretScrubber {
        let secrets = environment.filter { key, _ in
            key.hasPrefix("OPENCLICKY_KEY_") || key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") || key.hasSuffix("_SECRET")
        }.map(\.value)
        return SecretScrubber(knownSecrets: secrets)
    }

    public static let redacted = "<redacted>"

    /// (pattern, replacement template) pairs, applied in order.
    static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Header lines and header-like pairs.
            (#"(?i)\b(authorization|proxy-authorization)\s*[:=]\s*(bearer|basic|token)\s+[^\s"',;]+"#, "$1: $2 <redacted>"),
            (#"(?i)\b(x-api-key|xi-api-key|x-goog-api-key|api-key|openai-api-key|anthropic-api-key)\s*[:=]\s*[^\s"',;]+"#, "$1: <redacted>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer <redacted>"),
            // Provider key shapes.
            (#"\bsk-ant-[A-Za-z0-9_-]{8,}"#, "<redacted>"),
            (#"\bsk-or-v1-[A-Za-z0-9]{8,}"#, "<redacted>"),
            (#"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}"#, "<redacted>"),
            (#"\bsk_[A-Za-z0-9]{24,}"#, "<redacted>"),
            (#"\bAIza[0-9A-Za-z_-]{30,}"#, "<redacted>"),
            (#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, "<redacted>"),
            (#"\bgithub_pat_[A-Za-z0-9_]{30,}"#, "<redacted>"),
            (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, "<redacted>"),
            (#"\bya29\.[A-Za-z0-9._-]{20,}"#, "<redacted>"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "<redacted>"),
            // JWTs.
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "<redacted-jwt>"),
            // OAuth and key parameters in URLs and form bodies.
            (#"(?i)\b(access_token|refresh_token|id_token|client_secret|api_key|apikey|key|token|code|password|secret|signature|sig)=([^&\s"'<>]{8,})"#,
             "$1=<redacted>"),
            // Key-like JSON fields.
            (#"(?i)"(api_?key|apikey|access_?token|refresh_?token|id_?token|client_?secret|secret|password|authorization|token|session_?token)"\s*:\s*"[^"]*""#,
             #""$1": "<redacted>""#),
            // Long hex or base64 runs that look like secrets (Deepgram keys are 40 hex characters).
            (#"\b[a-f0-9]{40,}\b"#, "<redacted-hex>"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public func scrub(_ text: String) -> String {
        var result = text
        for secret in knownSecrets { result = result.replacingOccurrences(of: secret, with: Self.redacted) }
        for (regex, template) in Self.rules {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        if let home = homeDirectory, home.count > 1 { result = result.replacingOccurrences(of: home, with: "~") }
        return result
    }

    public func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(scrub(text))
        case .array(let items): return .array(items.map(scrub))
        case .object(let fields):
            return .object(Dictionary(uniqueKeysWithValues: fields.map { key, value in
                Self.isSecretKey(key) ? (key, .string(Self.redacted)) : (key, scrub(value))
            }))
        default: return value
        }
    }

    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return ["apikey", "accesstoken", "refreshtoken", "idtoken", "clientsecret", "secret", "password", "authorization", "token",
                "sessiontoken", "bearer"].contains(lowered)
    }
}

// MARK: - Commands

/// Runs a command with a deadline (the unified log can take a while on a busy Mac).
public protocol DiagnosticsCommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, maxOutput: Int) -> DiagnosticsCommandResult
}

public struct DiagnosticsCommandResult: Sendable, Hashable {
    public var status: Int32
    public var output: String
    public var timedOut: Bool
    public var truncated: Bool

    public init(status: Int32, output: String, timedOut: Bool, truncated: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

/// `Process` with a deadline: the command is terminated once `timeout` passes, and what it printed so far is kept.
public struct ProcessCommandRunner: DiagnosticsCommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, maxOutput: Int) -> DiagnosticsCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collected = OutputBuffer(limit: maxOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collected.append(chunk) }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return DiagnosticsCommandResult(status: -1, output: "could not run \(executable): \(error)", timedOut: false)
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        // Let the last bytes arrive.
        Thread.sleep(forTimeInterval: 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        let (data, truncated) = collected.contents
        return DiagnosticsCommandResult(status: timedOut ? -1 : process.terminationStatus, output: String(decoding: data, as: UTF8.self),
                                        timedOut: timedOut, truncated: truncated)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.withLock {
                let room = limit - data.count
                if room <= 0 { truncated = true; return }
                if chunk.count > room { truncated = true }
                data.append(chunk.prefix(room))
            }
        }

        var contents: (Data, Bool) { lock.withLock { (data, truncated) } }
    }
}

// MARK: - The bundle

/// Where the running app is installed, and whether macOS moved it to a randomized path (App Translocation), which
/// breaks permissions and updates.
public struct DiagnosticsInstall: Sendable, Hashable, Codable {
    public var bundlePath: String
    public var kind: String
    public var translocated: Bool

    public static func classify(bundlePath: String, home: String = NSHomeDirectory()) -> DiagnosticsInstall {
        let translocated = bundlePath.contains("/AppTranslocation/")
        let kind: String
        if translocated { kind = "translocated (opened from Downloads or a disk image without moving it)" }
        else if !bundlePath.hasSuffix(".app") { kind = "not an app bundle (swift run or occtl)" }
        else if bundlePath.hasPrefix("/Applications/") { kind = "/Applications" }
        else if bundlePath.hasPrefix(home + "/Applications/") { kind = "~/Applications" }
        else if bundlePath.hasPrefix("/Volumes/") { kind = "a mounted volume" }
        else { kind = "another folder" }
        return DiagnosticsInstall(bundlePath: bundlePath, kind: kind, translocated: translocated)
    }
}

/// One display as CoreGraphics sees it.
public struct DiagnosticsDisplay: Sendable, Hashable, Codable {
    public var id: UInt32
    public var main: Bool
    public var builtIn: Bool
    public var points: String
    public var pixels: String
    public var refreshHz: Double?

    public static func current() -> [DiagnosticsDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return DiagnosticsDisplay(id: id, main: CGDisplayIsMain(id) != 0, builtIn: CGDisplayIsBuiltin(id) != 0,
                                      points: "\(Int(bounds.width))x\(Int(bounds.height)) at \(Int(bounds.minX)),\(Int(bounds.minY))",
                                      pixels: mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?",
                                      refreshHz: mode.map(\.refreshRate).flatMap { $0 > 0 ? $0 : nil })
        }
    }
}

/// What goes into a diagnostics bundle. The caller (app or occtl) fills what it knows; everything is scrubbed again on
/// the way out.
public struct DiagnosticsInputs: Sendable {
    /// "OpenClicky" or "occtl".
    public var client: String
    public var appVersion: String
    public var build: String
    public var bundlePath: String
    /// Free-form state of the running app (turn phase, always-on, permissions, last timings…).
    public var appState: [String: JSONValue]
    public var config: OpenClickyConfig?
    /// Credential names the config uses, and whether each is stored. Never the values.
    public var credentials: [String: Bool]
    public var flags: FeatureFlagStore?
    public var usage: UsageLedger?
    /// The brain session's stats when a runtime is up.
    public var brainStats: BrainSessionStats?
    /// What the user wrote about the problem.
    public var note: String?

    public init(client: String, appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
                bundlePath: String = Bundle.main.bundlePath, appState: [String: JSONValue] = [:], config: OpenClickyConfig? = nil,
                credentials: [String: Bool] = [:], flags: FeatureFlagStore? = nil, usage: UsageLedger? = nil,
                brainStats: BrainSessionStats? = nil, note: String? = nil) {
        self.client = client
        self.appVersion = appVersion
        self.build = build
        self.bundlePath = bundlePath
        self.appState = appState
        self.config = config
        self.credentials = credentials
        self.flags = flags
        self.usage = usage
        self.brainStats = brainStats
        self.note = note
    }

    /// Which of the config's credentials are stored, read without printing them.
    public static func credentialStates(config: OpenClickyConfig, store: any CredentialStore) -> [String: Bool] {
        var states: [String: Bool] = [:]
        for provider in config.providers where !provider.dialect.isOnDevice {
            guard let name = provider.credential else { continue }
            states[name] = ((try? store.secret(named: name)) ?? nil)?.isEmpty == false
        }
        return states
    }
}

public struct DiagnosticsOptions: Sendable {
    /// OpenClicky's own log lines, plus errors and faults from its processes (system frameworks log there too).
    public static let standardPredicate = #"subsystem BEGINSWITH "app.openclicky" OR ((process == "OpenClicky" OR process == "occtl" OR process == "OpenClickyBrowserHost") AND (messageType == error OR messageType == fault))"#

    public var includeUnifiedLog: Bool
    /// How far back the log goes.
    public var logWindow: TimeInterval
    /// `/usr/bin/log` is stopped after this long.
    public var logTimeout: TimeInterval
    public var logPredicate: String
    public var maxLogBytes: Int
    /// Zip the folder (with /usr/bin/ditto).
    public var zip: Bool

    public init(includeUnifiedLog: Bool = true, logWindow: TimeInterval = 30 * 60, logTimeout: TimeInterval = 20,
                logPredicate: String = DiagnosticsOptions.standardPredicate,
                maxLogBytes: Int = 4_000_000, zip: Bool = true) {
        self.includeUnifiedLog = includeUnifiedLog
        self.logWindow = logWindow
        self.logTimeout = logTimeout
        self.logPredicate = logPredicate
        self.maxLogBytes = maxLogBytes
        self.zip = zip
    }
}

/// What was written.
public struct DiagnosticsReport: Sendable, Hashable {
    public var folder: URL
    public var zip: URL?
    public var files: [String]
    /// The plain summary (also `summary.txt`), for a bug report body.
    public var summary: String
    public var logLines: Int
    public var logTimedOut: Bool
}

public enum DiagnosticsBundle {
    /// The turn orchestrator logs the user's own words: what was heard (`heard: …`) and each turn's words
    /// (`voice turn: …`, `typed turn: …`). The secret scrubber can't recognise those, so they are removed here.
    static let transcriptLine = try! NSRegularExpression(pattern: #"\b(heard|[a-z]+ turn): .*$"#)

    /// `log` with the user's spoken and typed words taken out. A message's continuation lines (lines that don't start
    /// with a timestamp) go with it.
    static func removingTranscripts(_ log: String) -> String {
        var removing = false
        var lines: [Substring] = []
        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if removing, let first = line.first, !first.isNumber { continue }
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            if transcriptLine.firstMatch(in: text, range: range) != nil {
                removing = true
                lines.append(Substring(transcriptLine.stringByReplacingMatches(in: text, range: range, withTemplate: "$1: <words removed>")))
            } else {
                removing = false
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The folder bundles go in: `~/Library/Application Support/OpenClicky/Diagnostics`.
    public static var defaultDirectory: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Writes a bundle into a new folder under `directory` and returns what it holds.
    public static func write(_ inputs: DiagnosticsInputs, to directory: URL = defaultDirectory, options: DiagnosticsOptions = DiagnosticsOptions(),
                             scrubber: SecretScrubber = .forEnvironment(), runner: any DiagnosticsCommandRunning = ProcessCommandRunner(),
                             now: Date = Date()) throws -> DiagnosticsReport {
        let stamp = Self.stamp(now)
        let folder = directory.appendingPathComponent("openclicky-diagnostics-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [String] = []
        func write(_ name: String, _ text: String) throws {
            try Data(scrubber.scrub(text).utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
            files.append(name)
        }
        func writeJSON(_ name: String, _ value: JSONValue) throws {
            try write(name, pretty(scrubber.scrub(value)))
        }

        let install = DiagnosticsInstall.classify(bundlePath: inputs.bundlePath)
        let displays = DiagnosticsDisplay.current()
        let process = ProcessInfo.processInfo
        var system: [String: JSONValue] = [
            "client": .string(inputs.client), "version": .string(inputs.appVersion), "build": .string(inputs.build),
            "macOS": .string(process.operatingSystemVersionString), "hardware": .string(hardwareModel()),
            "memoryGB": .number((Double(process.physicalMemory) / 1_073_741_824).rounded()),
            "processors": .number(Double(process.activeProcessorCount)),
            "uptimeHours": .number((process.systemUptime / 3600 * 10).rounded() / 10),
            "locale": .string(Locale.current.identifier), "timeZone": .string(TimeZone.current.identifier),
            "lowPowerMode": .bool(process.isLowPowerModeEnabled), "thermalState": .string(thermal(process.thermalState)),
            "install": .object(["path": .string(install.bundlePath), "kind": .string(install.kind), "translocated": .bool(install.translocated)]),
        ]
        system["displays"] = .array(displays.map { display in
            ["id": .number(Double(display.id)), "main": .bool(display.main), "builtIn": .bool(display.builtIn),
             "points": .string(display.points), "pixels": .string(display.pixels),
             "refreshHz": display.refreshHz.map { .number($0) } ?? .null]
        })
        try writeJSON("system.json", .object(system))
        try writeJSON("app-state.json", .object(inputs.appState))
        if let config = inputs.config { try writeJSON("config.json", redactedConfig(config)) }
        try writeJSON("credentials.json", .object(inputs.credentials.mapValues { .string($0 ? "stored" : "missing") }))
        if let flags = inputs.flags {
            try writeJSON("flags.json", .array(flags.snapshot().map { entry in
                ["id": .string(entry.flag.id), "value": .bool(entry.value), "default": .bool(entry.flag.defaultValue),
                 "readBy": entry.flag.readBy.map { .string($0) } ?? .null]
            }))
        }
        var usageLine = "Usage ledger: off"
        if let usage = inputs.usage {
            let week = usage.summary(days: 7)
            let status = usage.limitStatus()
            usageLine = "Usage, last 7 days: \(UsageFormat.cost(week.total)) over \(week.total.records) records"
                + (status.message.map { "; \($0)" } ?? "")
            try writeJSON("usage-7-days.json", usageJSON(week, limits: usage.limits(), status: status))
        }
        if let stats = inputs.brainStats {
            try writeJSON("brain.json", ["session": .string(stats.sessionID), "turns": .number(Double(stats.turns)),
                                         "threadItems": .number(Double(stats.threadItems)),
                                         "screenshots": .number(Double(stats.screenshotsInThread)),
                                         "lastInputTokens": .number(Double(stats.lastInputTokens)),
                                         "compactions": .number(Double(stats.compactions))])
        }
        var logLines = 0
        var logTimedOut = false
        let logEnabled = options.includeUnifiedLog && (inputs.flags?.isOn(.diagnosticsUnifiedLog) ?? true)
        if logEnabled {
            let minutes = max(1, Int((options.logWindow / 60).rounded()))
            let result = runner.run("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--info", "--predicate", options.logPredicate],
                                    timeout: options.logTimeout, maxOutput: options.maxLogBytes)
            logTimedOut = result.timedOut
            var text = removingTranscripts(result.output)
            if result.timedOut { text += "\n[log stopped after \(Int(options.logTimeout)) s]" }
            if result.truncated { text += "\n[log truncated at \(options.maxLogBytes) bytes]" }
            logLines = text.split(separator: "\n").count
            try write("unified-log.txt", text)
        }

        var summary = """
        OpenClicky diagnostics, \(ISO8601DateFormatter().string(from: now))
        \(inputs.client) \(inputs.appVersion) (\(inputs.build)) on macOS \(process.operatingSystemVersionString), \(hardwareModel())
        Installed: \(install.kind)\(install.translocated ? " (App Translocation: move OpenClicky to /Applications)" : "")
        Displays: \(displays.count) (\(displays.map { $0.pixels + ($0.main ? " main" : "") }.joined(separator: ", ")))
        """
        if let config = inputs.config {
            let slots = SlotID.allCases.compactMap { slot in config.slots[slot].map { "\(slot.rawValue) \($0.provider)/\($0.model)" } }
            summary += "\nSlots: " + slots.joined(separator: ", ")
        }
        let missing = inputs.credentials.filter { !$0.value }.keys.sorted()
        if !missing.isEmpty { summary += "\nMissing keys: " + missing.joined(separator: ", ") }
        if let flags = inputs.flags {
            let changed = flags.snapshot().filter(\.overridden).map { "\($0.flag.id)=\($0.value)" }
            summary += "\nFlags changed from default: " + (changed.isEmpty ? "none" : changed.joined(separator: ", "))
        }
        summary += "\n" + usageLine
        if let stats = inputs.brainStats {
            summary += "\nBrain session: \(stats.turns) turns, \(stats.threadItems) thread items, last input \(stats.lastInputTokens) tokens"
        }
        summary += "\nUnified log: " + (logEnabled ? "\(logLines) lines\(logTimedOut ? " (stopped at the time limit)" : "")" : "not included")
        if let note = inputs.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { summary += "\n\nWhat happened:\n" + note }
        summary = scrubber.scrub(summary)
        try write("summary.txt", summary)

        var zip: URL?
        if options.zip {
            let archive = directory.appendingPathComponent("openclicky-diagnostics-\(stamp).zip")
            let result = runner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, archive.path], timeout: 30, maxOutput: 10_000)
            if result.status == 0, FileManager.default.fileExists(atPath: archive.path) { zip = archive }
        }
        return DiagnosticsReport(folder: folder, zip: zip, files: files.sorted(), summary: summary, logLines: logLines, logTimedOut: logTimedOut)
    }

    /// The config as JSON with provider header values and URL credentials and queries replaced (the config never holds
    /// a key, but a gateway header or a proxy URL can).
    public static func redactedConfig(_ config: OpenClickyConfig) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config), case .object(var root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        let byID = Dictionary(config.providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if case .array(let providers)? = root["providers"] {
            root["providers"] = .array(providers.map { entry in
                guard case .object(var fields) = entry, let id = fields["id"]?.stringValue, let provider = byID[id] else { return entry }
                if let url = provider.baseURL { fields["baseURL"] = .string(ProviderContext.redacted(url)) }
                if let headers = provider.headers {
                    fields["headers"] = .object(Dictionary(uniqueKeysWithValues: headers.keys.map { ($0, JSONValue.string(SecretScrubber.redacted)) }))
                }
                return .object(fields)
            })
        }
        return .object(root)
    }

    static func usageJSON(_ summary: UsageSummary, limits: UsageLimits, status: UsageLimitStatus) -> JSONValue {
        func totals(_ t: UsageTotals) -> JSONValue {
            ["records": .number(Double(t.records)), "costUSD": .number(t.costUSD), "unpriced": .number(Double(t.unpriced)),
             "inputTokens": .number(Double(t.inputTokens)), "outputTokens": .number(Double(t.outputTokens)),
             "audioSeconds": .number(t.audioSeconds), "characters": .number(Double(t.characters))]
        }
        return [
            "total": totals(summary.total),
            "byDay": .object(summary.byDay.mapValues(totals)),
            "bySlot": .object(summary.bySlot.mapValues(totals)),
            "bySurface": .object(summary.bySurface.mapValues(totals)),
            "limits": ["dailyUSD": limits.dailyUSD.map { .number($0) } ?? .null, "monthlyUSD": limits.monthlyUSD.map { .number($0) } ?? .null,
                       "stopAtLimit": .bool(limits.stopAtLimit)],
            "status": .string(status.level.rawValue),
        ]
    }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? value.jsonString()
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown Mac" }
        return String(cString: buffer)
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// A prefilled new-issue link for a bug report: the summary as the body, the zip to be attached by hand.
    public static func issueURL(summary: String, repository: String = "Jiffywu/OpenClicky-public") -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        let body = """
        **What happened**

        (Describe what you did and what went wrong.)

        **Diagnostics** (the zip from Settings → Developer → Report a Bug is attached)

        ```
        \(summary.prefix(3_000))
        ```
        """
        components?.queryItems = [URLQueryItem(name: "title", value: "Bug: "), URLQueryItem(name: "body", value: body)]
        return components?.url
    }
}
