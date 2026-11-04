import Foundation
import Testing
@testable import OpenClickyKit

/// Answers `log` with canned text and zips with the real ditto.
struct ScriptedRunner: DiagnosticsCommandRunning {
    var log: String
    var timedOut = false

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, maxOutput: Int) -> DiagnosticsCommandResult {
        if executable == "/usr/bin/log" { return DiagnosticsCommandResult(status: timedOut ? -1 : 0, output: log, timedOut: timedOut) }
        return ProcessCommandRunner().run(executable, arguments, timeout: timeout, maxOutput: maxOutput)
    }
}

@Suite struct InfraDiagnosticsTests {
    // Shapes only; none of these is a real credential.
    static let fakeAnthropic = "sk-ant-api03-" + String(repeating: "A1b2", count: 12)
    static let fakeOpenAI = "sk-proj-" + String(repeating: "Zz9", count: 12)
    static let fakeGoogle = "AIza" + String(repeating: "Q", count: 35)
    static let fakeJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVlLWhlcmU"

    @Test func scrubbingRemovesKeysTokensAndTheHomeFolder() {
        let scrubber = SecretScrubber(knownSecrets: ["exact-secret-value-123"], homeDirectory: "/Users/someone")
        let text = """
        Authorization: Bearer abcdefghijklmnop1234
        x-api-key: \(Self.fakeAnthropic)
        openai key \(Self.fakeOpenAI) and google \(Self.fakeGoogle)
        callback https://example.com/cb?code=4/0AbCdEfGhIjKlMn&state=xyz&access_token=ya29.a0AfH6SMBxyz1234567890abcdef
        {"api_key": "plain-json-key", "refresh_token": "1//0gAbC"}
        jwt \(Self.fakeJWT)
        the exact-secret-value-123 leaked
        file /Users/someone/Library/Application Support/OpenClicky/config.json
        exit code=0 and status ok
        """
        let scrubbed = scrubber.scrub(text)
        for secret in ["abcdefghijklmnop1234", Self.fakeAnthropic, Self.fakeOpenAI, Self.fakeGoogle, "4/0AbCdEfGhIjKlMn", "ya29.a0AfH6SMB",
                       "plain-json-key", "1//0gAbC", Self.fakeJWT, "exact-secret-value-123", "/Users/someone"] {
            #expect(!scrubbed.contains(secret), "\(secret.prefix(12))… survived")
        }
        // Ordinary text is left alone.
        #expect(scrubbed.contains("exit code=0 and status ok"))
        #expect(scrubbed.contains("~/Library/Application Support/OpenClicky/config.json"))
        #expect(scrubbed.contains("state=xyz"))
    }

    @Test func jsonScrubbingRedactsSecretFields() {
        let value: JSONValue = ["provider": "anthropic", "apiKey": "abc", "nested": ["Authorization": "Bearer zzz", "note": "Bearer abcdefghij123"]]
        let scrubbed = SecretScrubber(homeDirectory: nil).scrub(value)
        #expect(scrubbed["apiKey"]?.stringValue == SecretScrubber.redacted)
        #expect(scrubbed["nested"]?["Authorization"]?.stringValue == SecretScrubber.redacted)
        #expect(scrubbed["nested"]?["note"]?.stringValue == "Bearer <redacted>")
        #expect(scrubbed["provider"]?.stringValue == "anthropic")
    }

    @Test func theConfigLosesHeaderValuesAndURLSecrets() throws {
        let config = OpenClickyConfig(
            providers: [ProviderConfig(id: "gw", dialect: .openAIChat, baseURL: URL(string: "https://user:pw@gateway.example/v1?key=hidden"),
                                       credential: "gw", headers: ["X-Gateway-Key": "header-secret", "X-Title": "OpenClicky"])],
            slots: [.brain: SlotSelection(provider: "gw", model: "m")])
        let text = DiagnosticsBundle.redactedConfig(config).jsonString()
        #expect(!text.contains("header-secret"))
        #expect(!text.contains("hidden"))
        #expect(!text.contains("pw@"))
        #expect(text.contains("gateway.example"))
        #expect(text.contains("X-Gateway-Key"))
    }

    @Test func installLocationsAreClassified() {
        #expect(DiagnosticsInstall.classify(bundlePath: "/Applications/OpenClicky.app").kind == "/Applications")
        let moved = DiagnosticsInstall.classify(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/OpenClicky.app")
        #expect(moved.translocated)
        #expect(DiagnosticsInstall.classify(bundlePath: "/Users/a/Applications/OpenClicky.app", home: "/Users/a").kind == "~/Applications")
        #expect(DiagnosticsInstall.classify(bundlePath: "/Users/a/dev/.build/debug").kind.contains("not an app bundle"))
    }

    @Test func aBundleHoldsStateConfigFlagsUsageAndAScrubbedLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(directory: root.appendingPathComponent("Usage"))
        ledger.record(UsageRecord(slot: "brain", surface: "voice turn", provider: "anthropic", model: "claude-haiku-5-5",
                                  measure: UsageMeasure(inputTokens: 100, outputTokens: 10), costUSD: 0.00002))
        let flags = FeatureFlagStore(url: root.appendingPathComponent("flags.json"))
        try flags.set(.providerRetries, false)
        let config = OpenClickyConfig(providers: [ProviderConfig(id: "anthropic", dialect: .anthropicMessages, credential: "anthropic")],
                                      slots: [.brain: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5")])
        let inputs = DiagnosticsInputs(client: "test", appVersion: "1.0", build: "7", bundlePath: "/Applications/OpenClicky.app",
                                       appState: ["phase": "idle", "lastError": .string("Bearer abcdefghijklmnop1234")], config: config,
                                       credentials: DiagnosticsInputs.credentialStates(config: config, store: InMemoryCredentialStore()),
                                       flags: flags, usage: ledger, note: "It stopped talking after I pasted \(Self.fakeOpenAI).")
        let log = "11:00:01 occtl[1] [app.openclicky:providers] brain: retrying api.anthropic.com\n11:00:02 occtl[1] header x-api-key: \(Self.fakeAnthropic)\n"
        let report = try DiagnosticsBundle.write(inputs, to: root.appendingPathComponent("Out"), options: DiagnosticsOptions(),
                                                 scrubber: SecretScrubber(homeDirectory: nil), runner: ScriptedRunner(log: log))
        #expect(report.files == ["app-state.json", "config.json", "credentials.json", "flags.json", "summary.txt", "system.json",
                                 "unified-log.txt", "usage-7-days.json"])
        #expect(report.logLines == 2)
        let zip = try #require(report.zip)
        #expect(FileManager.default.fileExists(atPath: zip.path))
        var everything = ""
        for file in report.files { everything += try String(contentsOf: report.folder.appendingPathComponent(file), encoding: .utf8) }
        #expect(!everything.contains(Self.fakeAnthropic))
        #expect(!everything.contains(Self.fakeOpenAI))
        #expect(!everything.contains("abcdefghijklmnop1234"))
        #expect(everything.contains("retrying api.anthropic.com"))
        #expect(report.summary.contains("Missing keys: anthropic"))
        #expect(report.summary.contains("providers.retries=false"))
        #expect(report.summary.contains("Slots: brain anthropic/claude-haiku-5-5"))
        #expect(report.summary.contains("Installed: /Applications"))
        let credentials = try String(contentsOf: report.folder.appendingPathComponent("credentials.json"), encoding: .utf8)
        #expect(credentials.contains("\"anthropic\" : \"missing\""))
    }

    /// The orchestrator logs what the user said and typed; the bundle keeps the lines but not the words.
    @Test func theLogLosesWhatTheUserSaidAndTyped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = """
        2026-11-03 11:00:01.000 I  OpenClicky[1:2] [app.openclicky:voice] heard: my account number is 4417 and my doctor is Dr Lee
        2026-11-03 11:00:01.100 I  OpenClicky[1:2] [app.openclicky:voice] voice turn: my account number is 4417
        2026-11-03 11:00:02.000 I  OpenClicky[1:2] [app.openclicky:voice] typed turn: first line of a private note
        and its second private line
        2026-11-03 11:00:03.000 I  OpenClicky[1:2] [app.openclicky:providers] brain: retrying api.anthropic.com
        """
        let report = try DiagnosticsBundle.write(DiagnosticsInputs(client: "test"), to: root, options: DiagnosticsOptions(zip: false),
                                                 scrubber: SecretScrubber(homeDirectory: nil), runner: ScriptedRunner(log: log))
        let written = try String(contentsOf: report.folder.appendingPathComponent("unified-log.txt"), encoding: .utf8)
        #expect(!written.contains("4417") && !written.contains("Dr Lee") && !written.contains("private"))
        #expect(written.contains("[app.openclicky:voice] heard: <words removed>"))
        #expect(written.contains("voice turn: <words removed>") && written.contains("typed turn: <words removed>"))
        #expect(written.contains("brain: retrying api.anthropic.com"))
        #expect(report.logLines == 4)
    }

    @Test func aSlowLogIsCutShortAndSaidSo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try DiagnosticsBundle.write(DiagnosticsInputs(client: "test"), to: root,
                                                 options: DiagnosticsOptions(logTimeout: 1, zip: false),
                                                 scrubber: SecretScrubber(homeDirectory: nil), runner: ScriptedRunner(log: "partial line", timedOut: true))
        #expect(report.logTimedOut)
        #expect(report.zip == nil)
        let log = try String(contentsOf: report.folder.appendingPathComponent("unified-log.txt"), encoding: .utf8)
        #expect(log.contains("[log stopped after 1 s]"))
    }

    @Test func theProcessRunnerStopsACommandAtItsDeadline() {
        let started = Date()
        let result = ProcessCommandRunner().run("/bin/sh", ["-c", "echo started; sleep 30"], timeout: 0.5, maxOutput: 1_000)
        #expect(result.timedOut)
        #expect(result.output.contains("started"))
        #expect(Date().timeIntervalSince(started) < 5)
        let quick = ProcessCommandRunner().run("/bin/echo", ["hello"], timeout: 5, maxOutput: 3)
        #expect(quick.status == 0 && quick.output == "hel" && quick.truncated)
    }

    @Test func anIssueLinkCarriesTheSummary() throws {
        let url = try #require(DiagnosticsBundle.issueURL(summary: "OpenClicky diagnostics\nSlots: brain anthropic/claude-haiku-5-5"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/Jiffywu/OpenClicky-public/issues/new")
        #expect(items.first { $0.name == "body" }?.value?.contains("Slots: brain anthropic/claude-haiku-5-5") == true)
    }
}

@Suite struct InfraFlagTests {
    @Test func everyFlagHasAUniqueIdAndEveryKeyIsAccountedFor() {
        let ids = FeatureFlag.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let keys = HeyClickyFlagKeys.all.map(\.key)
        #expect(Set(keys).count == keys.count, "a Clicky* key is listed twice")
        #expect(keys.allSatisfy { $0.hasPrefix("Clicky") })
        // The keys parity.md names for this row are all covered or dropped.
        for key in ["ClickyLibraryModeEnabled", "ClickyStreamMode", "ClickyMorningPaperEnabled", "ClickyTransparentPanesEnabled",
                    "ClickyUseLegacyMenuBarPanel", "ClickyJavaScriptJIT", "ClickyLiveNotesEnabled", "ClickyLiveNotesStreamPatches",
                    "ClickyScreenDrawingSounds", "ClickyScreenDrawingPenSounds", "ClickyScreenDrawingSubtitles", "ClickyScreenDrawingVoiceCaptions",
                    "ClickyScreenDrawingSavesLessons", "ClickyScreenDrawingKeepsDrawingsInChat", "ClickyShowAgentLabelsInActivityStrip",
                    "ClickySkillPinnedNotchStateEnabled", "ClickyUpcomingMeetingsEnabled", "ClickyProactiveAgentSuggestionsEnabled",
                    "ClickyPreferHostedIntroVideos", "ClickyForceHostedIntroVideoFailure", "ClickyOneBrainStatsHUD"] {
            #expect(keys.contains(key), "\(key) is not accounted for")
        }
        for key in HeyClickyFlagKeys.all {
            if case .flag(let id) = key.disposition { #expect(FeatureFlag.named(id) != nil) }
        }
        #expect(HeyClickyFlagKeys.all.count >= 40)
    }

    @Test func valuesPersistAndDefaultsAreNotWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FeatureFlagStore(url: url)
        #expect(store.isOn(.providerRetries))
        try store.set(.providerRetries, false)
        try store.set(.agentLabelsInActivity, false) // the default: not written
        let reread = FeatureFlagStore(url: url)
        #expect(!reread.isOn(.providerRetries))
        #expect(reread.isOverridden(.providerRetries))
        let saved = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
        #expect(saved == ["providers.retries": false])
        // Another process changing the file is seen.
        try Data(#"{"providers.retries": true, "removed.flag": false}"#.utf8).write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(store.isOn(.providerRetries))
        try store.reset()
        #expect(FeatureFlagStore(url: url).snapshot().allSatisfy { !$0.overridden })
    }

    @Test func theStandardResilienceFollowsTheFlags() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let flags = FeatureFlagStore(url: url)
        try flags.set(.providerRetries, false)
        try flags.set(.usageLedger, false)
        let resilience = ProviderResilience.standard(client: "test", flags: flags)
        #expect(resilience.policy(for: .brain) == .none)
        #expect(resilience.recorder == nil)
        #expect(resilience.options.diagnose)
        let fake = FakeHTTPTransport([])
        #expect(resilience.transport(fake, slot: .brain) is FakeHTTPTransport)
    }

    /// Switching a flag in Settings must reach engines built afterwards, not wait for a relaunch: the refreshed set-up
    /// follows the flags as they are now and keeps the ledger the app is following.
    @Test func aRefreshedResilienceFollowsChangedFlagsAndKeepsItsLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = FeatureFlagStore(url: root.appendingPathComponent("flags.json"))
        let ledger = UsageLedger(directory: root.appendingPathComponent("Usage"))
        let launched = ProviderResilience.standard(client: "app", flags: flags, ledger: ledger)
        #expect(launched.options.diagnose && launched.policy(for: .brain) != .none && (launched.recorder as? UsageLedger) === ledger)

        try flags.set(.providerDiagnosis, false)
        try flags.set(.providerRetries, false)
        let refreshed = launched.refreshed(flags: flags)
        #expect(!refreshed.options.diagnose && refreshed.policy(for: .brain) == .none)
        #expect(refreshed.options.client == "app" && (refreshed.recorder as? UsageLedger) === ledger)

        try flags.set(.usageLedger, false)
        #expect(refreshed.refreshed(flags: flags).recorder == nil)
        #expect(ProviderResilience.flagsRead == [.providerRetries, .providerDiagnosis, .usageLedger])
    }
}
