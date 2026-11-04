import Foundation
import Testing
@testable import OpenClickyKit

// Settings → Agents (approval mode, folder, effort, announcements), Settings → Routines (runs, last failure, edits from
// occtl while the app runs) and Settings → Browser (profiles, the saved choice, manifests from the bundle, the
// unpacked extension).

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let anthropic = ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic")

@Test func agentPreferencesDefaultToAskingAndRoundTrip() throws {
    let root = try scratch("agent-prefs")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AgentPaths(root: root)
    let url = AgentPreferences.url(in: paths)
    #expect(url.lastPathComponent == "agent-settings.json")
    let defaults = AgentPreferences.load(from: url)
    #expect(defaults.approvalMode == .ask && defaults.voiceAnnouncements && defaults.textAnnouncements && defaults.suggestTasks)
    #expect(defaults.brainNote == nil)
    try #"{"approvalMode":"full-access","suggestTasks":false,"approvalModeTypo":1}"#.write(to: url, atomically: true, encoding: .utf8)
    let loaded = AgentPreferences.load(from: url)
    #expect(loaded.approvalMode == .fullAccess && !loaded.suggestTasks && loaded.voiceAnnouncements)
    #expect(loaded.brainNote?.contains("only when they ask") == true)
    // An unknown mode falls back to asking rather than failing the whole file.
    try #"{"approvalMode":"yolo","textAnnouncements":false}"#.write(to: url, atomically: true, encoding: .utf8)
    let odd = AgentPreferences.load(from: url)
    #expect(odd.approvalMode == .ask && !odd.textAnnouncements)
}

@Test func theAgentFolderMovesJobFoldersOnlyWhenValid() throws {
    let root = try scratch("agent-folder")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = AgentPaths(root: root.appendingPathComponent("support"))
    #expect(AgentPreferences().paths(base: base).projects == base.root.appendingPathComponent("projects", isDirectory: true))

    let custom = root.appendingPathComponent("My Agents", isDirectory: true)
    let moved = AgentPreferences(customFolder: custom.path).paths(base: base)
    #expect(moved.projects.path == custom.path)
    #expect(moved.jobs.path == custom.appendingPathComponent("jobs").path)
    #expect(moved.agents.path == custom.appendingPathComponent("agents").path)
    // Routines, the Codex home and settings stay in the support folder.
    #expect(moved.routines == base.routines && moved.codexHome == base.codexHome)

    #expect(AgentPreferences.validateFolder("relative/path") == .failure(.notAbsolute))
    #expect(AgentPreferences.validateFolder("/Applications/OpenClicky.app/Contents") == .failure(.insideApp))
    #expect(AgentPreferences.validateFolder("/System/Library") == .failure(.systemLocation))
    #expect(AgentPreferences.validateFolder("/") == .failure(.systemLocation))
    let file = root.appendingPathComponent("file.txt")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    #expect(AgentPreferences.validateFolder(file.path) == .failure(.notAFolder))
    #expect(AgentPreferences(customFolder: "/System/Library").paths(base: base).projects == base.projects)

    // Jobs really land in the custom folder.
    let store = AgentJobStore(paths: moved)
    let record = try store.createJob(task: "Write a haiku", title: nil, harness: .claudeCode, model: nil, provider: "anthropic")
    #expect(record.folderPath.hasPrefix(custom.path))
}

@Test func reasoningEffortAndApprovalModeReachTheHarness() throws {
    var config = OpenClickyConfig(providers: [anthropic],
                                  slots: [.agent: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5", harness: .claudeCode, reasoningEffort: "low")])
    let credentials = InMemoryCredentialStore(["anthropic": "test-key"])
    let preferences = AgentPreferences(approvalMode: .fullAccess)
    let settings = try AgentLaunchSettings.fromConfig(config, credentials: credentials, approvalMode: preferences.approvalMode)
    #expect(settings.reasoningEffort == "low" && settings.approvalMode == .fullAccess)

    // Claude Code gets --effort low (with a stand-in executable; nothing runs).
    let temp = try scratch("effort")
    defer { try? FileManager.default.removeItem(at: temp) }
    let claude = temp.appendingPathComponent("claude")
    try "#!/bin/sh\nexit 0\n".write(to: claude, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    let launch = HarnessLaunch(folder: temp, instructions: "x", model: settings.model, reasoningEffort: settings.reasoningEffort,
                               auth: settings.auth, approvalMode: settings.approvalMode, executable: claude, paths: AgentPaths(root: temp))
    let arguments = try ClaudeCodeHarness().plan(for: launch).arguments
    let index = try #require(arguments.firstIndex(of: "--effort"))
    #expect(arguments[index + 1] == "low")

    // Codex gets it as model_reasoning_effort in OpenClicky's own config.toml.
    let openAI = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai")
    let codexConfig = OpenClickyConfig(providers: [openAI],
                                       slots: [.agent: SlotSelection(provider: "openai", model: "gpt-6-luna", harness: .codex, reasoningEffort: "high")])
    let codexSettings = try AgentLaunchSettings.fromConfig(codexConfig, credentials: InMemoryCredentialStore(["openai": "test-key"]))
    let codex = temp.appendingPathComponent("codex")
    try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
    let codexLaunch = HarnessLaunch(folder: temp, instructions: "x", model: codexSettings.model, reasoningEffort: codexSettings.reasoningEffort,
                                    auth: codexSettings.auth, executable: codex, paths: AgentPaths(root: temp),
                                    baseEnvironment: ["PATH": "/usr/bin", "HOME": temp.path])
    let toml = try #require(try CodexHarness(hasLogin: { _ in true }).plan(for: codexLaunch).configTOML)
    #expect(toml.contains(#"model_reasoning_effort = "high""#))

    // "default" and blank mean the harness's own; the saved config round-trips the field.
    config.slots[.agent]?.reasoningEffort = "default"
    #expect(try AgentLaunchSettings.fromConfig(config, credentials: credentials).reasoningEffort == nil)
    config.slots[.agent]?.reasoningEffort = "high"
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(OpenClickyConfig.self, from: data).slots[.agent]?.reasoningEffort == "high")
    // Old configs without the field still load.
    let old = #"{"version":1,"providers":[],"models":[],"slots":{"agent":{"provider":"anthropic","model":"m"}}}"#
    #expect(try JSONDecoder().decode(OpenClickyConfig.self, from: Data(old.utf8)).slots[.agent]?.reasoningEffort == nil)
}

@Test func effortChoicesFollowTheHarnessAndModel() throws {
    let catalog = try ModelCatalog.builtIn()
    let haiku = OpenClickyConfig(providers: [anthropic], slots: [.agent: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5", harness: .claudeCode)])
    #expect(AgentEffortOptions.choices(config: haiku, catalog: catalog) == ["low", "medium", "high"])
    #expect(AgentEffortOptions.choices(harness: .codex, model: nil) == ["minimal", "low", "medium", "high", "xhigh"])
    #expect(AgentEffortOptions.choices(config: OpenClickyConfig(providers: [], slots: [:]), catalog: catalog).isEmpty)
}

@Test func routineSummariesListRunsAndTheLastFailure() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var routine = AgentRoutine(id: "r1", title: "Prices", task: "Check prices", schedule: .every(minutes: 60), jobID: "j1", createdAt: now)
    routine.runCount = 3
    routine.lastRunAt = now.addingTimeInterval(-600)
    routine.lastOutcome = .failed
    routine.consecutiveFailures = 2
    routine.nextRunAt = now.addingTimeInterval(3000)
    var job = AgentJobRecord(id: "j1", kind: .job, title: "Prices", task: "Check prices", harness: .codex, model: nil, provider: "openai",
                             status: .failed, createdAt: now, updatedAt: now, error: "Sign-in required", folderPath: "/tmp/j1")
    job.runs = [
        AgentRun(ask: "first ask, not a routine", startedAt: now.addingTimeInterval(-9000)),
        { var run = AgentRun(ask: "Check prices", startedAt: now.addingTimeInterval(-7200), routineID: "r1"); run.outcome = .completed; run.finishedAt = now.addingTimeInterval(-7100); run.spoken = "Still $412."; return run }(),
        { var run = AgentRun(ask: "Check prices", startedAt: now.addingTimeInterval(-3600), routineID: "r1"); run.outcome = .failed; return run }(),
        { var run = AgentRun(ask: "Check prices", startedAt: now.addingTimeInterval(-600), routineID: "r1"); run.outcome = .failed; return run }(),
    ]
    let other = AgentRoutine(id: "r2", title: "Never ran", task: "x", schedule: .daily(TimeOfDay(hour: 9, minute: 0), weekdays: nil), createdAt: now)
    let summaries = RoutineSummary.make(routines: [routine, other], jobs: [job])
    #expect(summaries.map(\.id) == ["r1", "r2"])
    #expect(summaries[0].runs.map(\.runIndex) == [3, 2, 1])
    #expect(summaries[0].runs.map(\.statusText) == ["failed", "failed", "done"])
    #expect(summaries[0].lastFailure == "Sign-in required")
    #expect(summaries[1].runs.isEmpty && summaries[1].lastFailure == nil)
    #expect(summaries[1].lastRunLine(now: now) == "Hasn't run yet")
    #expect(summaries[0].lastRunLine(now: now).hasPrefix("Ran 3 times"))

    var paused = routine
    paused.isPaused = true
    #expect(RoutineSummary(routine: paused, runs: [], lastFailure: nil).statusLine(now: now) == "Paused after 2 failed runs")
    paused.consecutiveFailures = 0
    #expect(RoutineSummary(routine: paused, runs: [], lastFailure: nil).statusLine(now: now) == "Paused")
    var retrying = routine
    retrying.retryAt = now.addingTimeInterval(1200)
    #expect(RoutineSummary(routine: retrying, runs: [], lastFailure: nil).statusLine(now: now).hasPrefix("Retrying at"))
    #expect(RoutineSummary(routine: routine, runs: [], lastFailure: nil).statusLine(now: now).hasPrefix("Next run"))
}

@Test func theAppSchedulerPicksUpEditsOcctlMadeToTheFile() async throws {
    let root = try scratch("routine-sync")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RoutineStore(url: root.appendingPathComponent("routines.json"))
    let runs = RoutineRunLog()
    let app = RoutineScheduler(store: store) { routine, _ in await runs.add(routine.id); return "job-\(routine.id)" }
    let occtl = RoutineScheduler(store: store) { _, _ in "unused" }

    let made = try await occtl.create(title: "Inbox", task: "Summarize email", schedule: .every(minutes: 30))
    // The app sees it before its next pass and doesn't write over it with its stale list.
    #expect(await app.list().map(\.id) == [made.id])
    try await app.setPaused(made.id, true)
    #expect(await occtl.list().first?.isPaused == true)
    try await occtl.delete(made.id)
    #expect(await app.list().isEmpty)

    // A run started from occtl moves the app's copy too (run count, last run).
    let second = try await app.create(title: "Prices", task: "Check prices", schedule: .every(minutes: 60))
    let occtlRuns = RoutineScheduler(store: store) { routine, _ in await runs.add("occtl:" + routine.id); return "job-x" }
    _ = try await occtlRuns.runNow(second.id)
    #expect(await app.list().first?.runCount == 1)
    #expect(await runs.ids == ["occtl:\(second.id)"])
}

private actor RoutineRunLog {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

// MARK: - Browser

@Test func profilesAreReadFromLocalStateWithoutEmails() {
    let chrome = NativeHostInstaller.browsers[0]
    let json = #"""
    {"profile":{"info_cache":{
      "Default":{"name":"Personal","active_time":1761900000.5,"user_name":"me@example.com"},
      "Profile 2":{"name":"Work","active_time":"1761990000"},
      "Profile 3":{"name":"","active_time":0},
      "../evil":{"name":"x"}
    }}}
    """#
    let profiles = ChromiumProfileDiscovery.parse(localState: Data(json.utf8), browser: chrome)
    #expect(profiles.map(\.name) == ["Work", "Personal", "Profile 3"])
    #expect(profiles.map(\.directory) == ["Profile 2", "Default", "Profile 3"])
    #expect(profiles[2].lastActive == nil)
    #expect(ChromiumProfileDiscovery.parse(localState: Data("{}".utf8), browser: chrome).isEmpty)
    #expect(ChromiumProfileDiscovery.parse(localState: Data("nope".utf8), browser: chrome).isEmpty)
}

@Test func installedBrowsersAndTheMostRecentProfile() throws {
    let support = try scratch("browsers")
    defer { try? FileManager.default.removeItem(at: support) }
    let chromeFolder = support.appendingPathComponent("Google/Chrome")
    let arcFolder = support.appendingPathComponent("Arc/User Data")
    try FileManager.default.createDirectory(at: chromeFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: arcFolder, withIntermediateDirectories: true)
    try #"{"profile":{"info_cache":{"Default":{"name":"Personal","active_time":100}}}}"#.write(to: chromeFolder.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
    try #"{"profile":{"info_cache":{"Default":{"name":"Arc me","active_time":200}}}}"#.write(to: arcFolder.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
    let installed = ChromiumProfileDiscovery.installed(applicationSupport: support)
    #expect(installed.map(\.browser.id) == ["chrome", "arc"])
    #expect(ChromiumProfileDiscovery.mostRecent(applicationSupport: support)?.name == "Arc me")
}

@Test func theProfileChoiceIsSavedPrivatelyAndAppliedWhenTheBridgeStarts() throws {
    let folder = try scratch("bridge-prefs")
    defer { try? FileManager.default.removeItem(at: folder) }
    let paths = BrowserBridgePaths(directory: folder.appendingPathComponent("BrowserBridge"))
    #expect(BrowserBridgePreferences.load(from: paths) == BrowserBridgePreferences())

    var preferences = BrowserBridgePreferences()
    preferences.choose("3C9A1F40-6D2B-4E8A-9F11-7B5E2D0C4A99")
    #expect(preferences.preferredProfileID == "3c9a1f40-6d2b-4e8a-9f11-7b5e2d0c4a99")
    preferences.choose("not-a-uuid")
    #expect(preferences.preferredProfileID == nil)
    preferences.choose("3c9a1f40-6d2b-4e8a-9f11-7b5e2d0c4a99")
    try preferences.save(to: paths)
    let attributes = try FileManager.default.attributesOfItem(atPath: BrowserBridgePreferences.url(in: paths).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(BrowserBridgePreferences.load(from: paths) == preferences)

    // A hand-edited file can't point commands at something that isn't a profile id.
    try #"{"preferredProfileID":"../../x","knownProfiles":[]}"#.write(to: BrowserBridgePreferences.url(in: paths), atomically: true, encoding: .utf8)
    #expect(BrowserBridgePreferences.load(from: paths).preferredProfileID == nil)

    try preferences.save(to: paths)
    let service = try BrowserBridgeService(paths: paths)
    #expect(service.bridge.preferredProfile == "3c9a1f40-6d2b-4e8a-9f11-7b5e2d0c4a99")
}

@Test func connectedProfilesAreRememberedNewestFirst() throws {
    let json = #"[{"id":"p1","session":"s","profileId":"AAAAAAAA-0000-4000-8000-000000000001","origin":"o","browser":"com.google.Chrome","connectedAt":"2026-10-31T09:00:00Z","lastSeen":"2026-10-31T09:00:00Z"}]"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let peers = try decoder.decode([BrowserPeer].self, from: Data(json.utf8))
    var preferences = BrowserBridgePreferences()
    preferences.remember(peers, at: Date(timeIntervalSince1970: 10))
    preferences.remember(peers, at: Date(timeIntervalSince1970: 20))
    #expect(preferences.knownProfiles.count == 1)
    #expect(preferences.knownProfiles[0].id == "aaaaaaaa-0000-4000-8000-000000000001" && preferences.knownProfiles[0].browserName == "Chrome")
    #expect(preferences.knownProfiles[0].lastSeen == Date(timeIntervalSince1970: 20))

    #expect(BrowserConnectionState.from(probe: .success(BrowserBridgeProbe.Status(peers: peers))).isConnected)
    #expect(BrowserConnectionState.from(probe: .success(BrowserBridgeProbe.Status(peers: []))) == .waitingForExtension)
    let down = BrowserConnectionState.from(probe: .failure(BrowserBridgeProbe.ProbeError.noToken))
    #expect(down.title == "Not connected" && down.detail.contains("never run"))
}

@Test func manifestsComeFromARealAppBundleOnly() throws {
    let root = try scratch("bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)

    // A build folder, not an app: refused, nothing written.
    let buildFolder = root.appendingPathComponent(".build/debug")
    try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true)
    guard case .failure(.notAnAppBundle) = BundledHostInstall.refresh(bundleURL: buildFolder, applicationSupport: support) else {
        Issue.record("a build folder should be refused")
        return
    }
    // An app without its helper: refused with the path.
    let app = root.appendingPathComponent("OpenClicky.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
    try "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    guard case .failure(.helperMissing(let path)) = BundledHostInstall.refresh(bundleURL: app, applicationSupport: support) else {
        Issue.record("an app without the helper should be refused")
        return
    }
    #expect(path.hasSuffix("Contents/Helpers/OpenClickyBrowserHost"))
    #expect(!FileManager.default.fileExists(atPath: NativeHostInstaller.manifestURL(for: NativeHostInstaller.browsers[0], applicationSupport: support).path))

    // The real thing: written for installed browsers only, then left alone when unchanged.
    let helper = app.appendingPathComponent("Contents/Helpers/OpenClickyBrowserHost")
    try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let first = try BundledHostInstall.refresh(bundleURL: app, applicationSupport: support).get()
    #expect(BundledHostInstall.summary(first) == "Chrome: written")
    let inspection = try #require(NativeHostInstaller.inspect(applicationSupport: support).first { $0.browser.id == "chrome" })
    #expect(inspection.manifestPresent && inspection.hostExecutable && inspection.allowsOpenClickyExtension)
    #expect(inspection.hostPath == helper.standardizedFileURL.path)
    #expect(BundledHostInstall.summary(try BundledHostInstall.refresh(bundleURL: app, applicationSupport: support).get()) == "Chrome: unchanged")
    #expect(BundledHostInstall.summary([]) == "no Chromium browser installed")
}

@Test func aTranslocatedOrDiskImageCopyLeavesTheInstalledAppsManifestAlone() throws {
    let root = try scratch("temporary-copy")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appendingPathComponent("Support")
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)

    // A complete app, but in the read-only copy macOS makes for a quarantined download.
    let app = root.appendingPathComponent("AppTranslocation/1234/d/OpenClicky.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Helpers"), withIntermediateDirectories: true)
    try "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    let helper = app.appendingPathComponent("Contents/Helpers/OpenClickyBrowserHost")
    try "#!/bin/sh\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    guard case .failure(.temporaryCopy(let path)) = BundledHostInstall.refresh(bundleURL: app, applicationSupport: support) else {
        Issue.record("a translocated copy should be refused")
        return
    }
    #expect(path == app.standardizedFileURL.path)
    #expect(!FileManager.default.fileExists(atPath: NativeHostInstaller.manifestURL(for: NativeHostInstaller.browsers[0], applicationSupport: support).path))
    #expect(BundledHostInstall.Refusal.temporaryCopy(path).description.contains("Move OpenClicky to Applications"))

    // Straight from a mounted disk image: refused the same way.
    guard case .failure(.temporaryCopy) = BundledHostInstall.helper(inBundle: URL(fileURLWithPath: "/Volumes/OpenClicky/OpenClicky.app")) else {
        Issue.record("a disk-image copy should be refused")
        return
    }
}

@Test func theExtensionIsStagedWithoutItsTestsAndTheStepsNameTheFolder() throws {
    let root = try scratch("extension")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("BrowserExtension-src")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("tests"), withIntermediateDirectories: true)
    try #"{"manifest_version":3,"version":"0.1.0"}"#.write(to: source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    try "//".write(to: source.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
    try "x".write(to: source.appendingPathComponent("tests/e2e.sh"), atomically: true, encoding: .utf8)
    try "x".write(to: source.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    let destination = root.appendingPathComponent("Support/BrowserExtension")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try "old".write(to: destination.appendingPathComponent("stale.js"), atomically: true, encoding: .utf8)

    let staged = try BrowserExtensionFolder.stage(from: source, to: destination)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: staged.path)) == ["manifest.json", "background.js"])
    #expect(BrowserExtensionFolder.version(at: staged) == "0.1.0")
    #expect(throws: BrowserExtensionFolder.StageError.self) { try BrowserExtensionFolder.stage(from: root.appendingPathComponent("missing"), to: destination) }
    #expect(BrowserExtensionFolder.bundled(in: URL(fileURLWithPath: "/Applications/OpenClicky.app")).path
            == "/Applications/OpenClicky.app/Contents/Resources/BrowserExtension")

    let edge = try #require(NativeHostInstaller.browsers.first { $0.id == "edge" })
    let steps = BrowserSetupGuide.loadUnpackedSteps(browser: edge, folder: staged)
    #expect(steps.first == "Open edge://extensions in Edge.")
    #expect(steps.contains { $0.contains("other stores") })
    #expect(steps.contains { $0.contains(staged.path) })
    #expect(BrowserSetupGuide.extensionsPage(for: NativeHostInstaller.browsers[0]) == "chrome://extensions")
}

@Test func theFirstConnectionIsRememberedOnceAndAnnouncedForAWhile() throws {
    let peer = BrowserPeer(id: "p", session: "s", profileId: "aaaaaaaa-0000-4000-8000-000000000001", origin: "o",
                           browser: "com.google.Chrome", connectedAt: Date(), lastSeen: Date())
    var preferences = BrowserBridgePreferences()
    #expect(!preferences.hasEverConnected)
    #expect(preferences.firstConnectionNotice() == nil)
    let none = preferences.noteConnected([])
    #expect(!none)
    let first = Date(timeIntervalSince1970: 1_000_000)
    let isFirst = preferences.noteConnected([peer], at: first)
    let isFirstAgain = preferences.noteConnected([peer], at: first.addingTimeInterval(5))
    #expect(isFirst)
    #expect(!isFirstAgain, "only the first time")
    #expect(preferences.hasEverConnected && preferences.firstConnectedAt == first)
    let notice = try #require(preferences.firstConnectionNotice(now: first.addingTimeInterval(60)))
    #expect(notice.contains("Chrome for the first time"))
    #expect(preferences.firstConnectionNotice(now: first.addingTimeInterval(3600)) == nil)

    // Saved and loaded with the rest; files from before these keys existed still load.
    let paths = BrowserBridgePaths(directory: try scratch("prefs"))
    defer { try? FileManager.default.removeItem(at: paths.directory) }
    try preferences.save(to: paths)
    let loaded = BrowserBridgePreferences.load(from: paths)
    #expect(loaded.hasEverConnected && loaded.firstConnectedAt == first)
    try Data(#"{"knownProfiles":[]}"#.utf8).write(to: BrowserBridgePreferences.url(in: paths))
    #expect(!BrowserBridgePreferences.load(from: paths).hasEverConnected)
    try Data(#"{"knownProfiles":[{"id":"aaaaaaaa-0000-4000-8000-000000000001","browserName":"Chrome","lastSeen":"2026-10-31T09:00:00Z"}]}"#.utf8)
        .write(to: BrowserBridgePreferences.url(in: paths))
    #expect(BrowserBridgePreferences.load(from: paths).hasEverConnected, "a profile seen before means it connected before")
}

@Test func theBadgeShowsOffWaitingSetupFailedOrConnected() {
    let now = Date()
    let peer = BrowserPeer(id: "p", session: "s", profileId: "aaaaaaaa-0000-4000-8000-000000000001", origin: "o",
                           browser: "com.google.Chrome", connectedAt: now, lastSeen: now)
    let refused = BrowserSetupFailure(reason: "A browser extension OpenClicky doesn't know tried to connect.", at: now.addingTimeInterval(-60))
    #expect(BrowserSetupBadge.make(state: .bridgeNotRunning("x"), failure: nil).badge == .off)
    #expect(BrowserSetupBadge.make(state: .waitingForExtension, failure: nil).badge == .waiting)
    let failed = BrowserSetupBadge.make(state: .waitingForExtension, failure: refused).badge
    #expect(failed == .setupFailed(refused.reason) && failed.title == "Setup failed" && failed.reason == refused.reason)
    #expect(BrowserSetupBadge.make(state: .bridgeNotRunning("x"), failure: nil, setupError: "Couldn't write the helper").badge
        == .setupFailed("Couldn't write the helper"))
    // A failure from before the browser connected is over; a problem reported after it is shown beside Connected.
    let connected = BrowserSetupBadge.make(state: .connected([peer]), failure: refused)
    #expect(connected.badge == .connected && connected.attention == nil)
    let later = BrowserSetupFailure(reason: "Reload the extension.", at: now.addingTimeInterval(5))
    #expect(BrowserSetupBadge.make(state: .connected([peer]), failure: later).attention == "Reload the extension.")
    #expect(BrowserSetupBadge.connected.title == "Connected" && BrowserSetupBadge.off.title == "Off" && BrowserSetupBadge.waiting.title == "Waiting")
}

@Test func theBridgeReportsWhyAnExtensionWasTurnedAway() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let service = try BrowserBridgeService(paths: paths, allowedExtensionIDs: [ChromeExtensionIdentity.extensionID])
    try service.start()
    defer { service.stop() }
    #expect(try BrowserBridgeProbe.status(paths: paths).failure == nil)
    let stranger = "abcdefghijklmnopabcdefghijklmnop"
    let fake = FakeExtension(paths: paths, origin: ChromeExtensionIdentity.origin(for: stranger), allowedIDs: [stranger])
    defer { fake.disconnect() }
    try fake.sendHello()
    #expect(eventually { service.bridge.lastFailure != nil })
    let failure = try #require(try BrowserBridgeProbe.status(paths: paths).failure)
    #expect(failure.reason.contains("doesn't know") && failure.browser == "com.google.Chrome")

    // The real extension connects: the failure is over. A problem it reports afterwards is kept.
    let real = FakeExtension(paths: paths)
    defer { real.disconnect() }
    try real.sendHello(profile: "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f51")
    #expect(eventually { service.bridge.peers.count == 1 })
    #expect(service.bridge.lastFailure == nil)
    try real.send(["type": "event", "name": "problem", "reason": "Reload the extension."])
    #expect(eventually { service.bridge.lastFailure?.reason == "Reload the extension." })
}
