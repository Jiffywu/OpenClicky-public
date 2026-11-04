import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-snapshots <folder> [--history <dir>]`: renders every Home, Settings and onboarding page offscreen
/// (NSHostingView in a borderless window, drawn with `cacheDisplay`) from fixtures in a temporary folder. Uses an
/// in-memory credential store and fixed permission states, so it never reads the Keychain, asks for a permission or
/// writes the user's settings. `--history` copies a real history folder in (for example one `occtl history chat`
/// recorded) so live turns show up in the chat render.
@MainActor
enum EvidenceSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.renderAll(into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: Rendering

    static func render<V: View>(_ view: V, size: NSSize, dark: Bool = false, to url: URL, settle: TimeInterval = 0.4) throws {
        // An opaque window background, as a real window has; without it translucent fills composite over nothing.
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SnapshotFailure.noBitmap(url.lastPathComponent) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotFailure.noBitmap(url.lastPathComponent) }
        try png.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        window.contentView = nil
    }

    enum SnapshotFailure: Error { case noBitmap(String) }

    // MARK: Fixture

    @MainActor
    final class Fixture {
        let root: URL
        let model: AppModel
        let services: HomeServices
        let now = Date()
        /// Sessions copied in with --history (live runs), newest first.
        private(set) var liveSessionIDs: [String] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-snapshots-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = OpenClickyConfig(
                providers: [
                    ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
                    ProviderConfig(id: "openrouter", dialect: .openAIChat, baseURL: URL(string: "https://openrouter.ai/api/v1"), credential: "openrouter"),
                    ProviderConfig(id: "elevenlabs", dialect: .elevenLabsSpeech, baseURL: URL(string: "https://api.elevenlabs.io"), credential: "elevenlabs"),
                    ProviderConfig(id: "apple-speech", dialect: .appleSpeech),
                ],
                models: [ModelDescriptor(id: "openai/gpt-5-nano", displayName: "GPT-5 nano (OpenRouter)", kind: .languageModel,
                                         capabilities: [.textInput, .imageInput, .textOutput, .streaming, .toolCalling, .reasoning],
                                         dialects: [.openAIChat])],
                slots: [.stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                        .voice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5", voice: "EXAVITQu4vr4xnSDxMaL"),
                        .brain: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5"),
                        .brainFast: SlotSelection(provider: "openrouter", model: "openai/gpt-5-nano"),
                        .agent: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5", harness: .claudeCode, reasoningEffort: "low")])
            // Placeholder values only; nothing here is a real key.
            let credentials = InMemoryCredentialStore(["anthropic": "fixture", "elevenlabs": "fixture", "openrouter": "fixture"])
            // Screen Recording allowed after launch (restart required), Speech asked and refused, Input Monitoring never asked.
            let permissions = PermissionsCenter(fixed: [.microphone: .granted, .screenRecording: .restartRequired, .accessibility: .granted,
                                                        .speechRecognition: .denied, .inputMonitoring: .notDetermined],
                                                reach: Self.agentReach)
            model = AppModel(config: config, credentials: credentials, permissions: permissions)
            var locations = HomeServices.Locations()
            locations.history = root.appendingPathComponent("History")
            locations.skills = root.appendingPathComponent("Skills")
            locations.skillsState = root.appendingPathComponent("skills.json")
            locations.memory = root.appendingPathComponent("Memory")
            locations.connectors = root.appendingPathComponent("connectors.json")
            locations.services = root.appendingPathComponent("services.json")
            locations.thumbnails = nil
            locations.voiceSettings = root.appendingPathComponent("voice.json")
            locations.voicePreviews = nil
            locations.talkKeys = root.appendingPathComponent("talk-keys.json")
            locations.dictation = root.appendingPathComponent("dictation.json")
            locations.onboarding = nil
            locations.appPreferences = root.appendingPathComponent("app-preferences.json")
            locations.microphone = root.appendingPathComponent("microphone.json")
            locations.dictationVocabulary = nil
            locations.agentSettings = root.appendingPathComponent("agent-settings.json")
            locations.agentPaths = AgentPaths(root: root.appendingPathComponent("Agents"))
            locations.browserBridge = BrowserBridgePaths(directory: root.appendingPathComponent("BrowserBridge"))
            locations.browserSupport = root.appendingPathComponent("BrowserSupport")
            try MicrophoneSettings(deviceUID: Self.microphones[1].uid).save(to: root.appendingPathComponent("microphone.json"))
            try DictationSettings(language: "en-GB").save(to: root.appendingPathComponent("dictation.json"))
            try Self.writeBrowsers(into: locations.browserSupport, root: root)
            locations.usage = root.appendingPathComponent("Usage", isDirectory: true)
            locations.flags = root.appendingPathComponent("flags.json")
            InfraSnapshots.writeUsage(into: locations.usage, now: now)
            try Self.writeHistory(into: locations.history, now: now)
            if let index = CommandLine.arguments.firstIndex(of: "--history"), index + 1 < CommandLine.arguments.count {
                liveSessionIDs = try Self.copyHistory(from: URL(fileURLWithPath: CommandLine.arguments[index + 1]), into: locations.history)
            }
            try Self.writeSkills(locations.skills, state: locations.skillsState)
            try Self.writeMemory(locations.memory)
            services = HomeServices(model: model, locations: locations, startAgents: false, agentHUD: Self.agentHUD(now: now))
            services.voice.playsAudio = false
            services.microphone.show(inputs: Self.microphones, test: .finished(.heard, "Heard you clearly on AirPods Pro."))
            services.dictation.show(settings: DictationSettings(language: "en-GB"), vocabulary: Self.vocabulary)
            let summaries = Self.routineSummaries(now: now)
            services.routines.show(summaries, selected: summaries.first?.id)
            services.browser.show(state: .connected(Self.peers(now: now)),
                                  preferences: BrowserBridgePreferences(preferredProfileID: Self.peers(now: now)[0].profileId),
                                  staged: root.appendingPathComponent("BrowserExtension"))
            services.chat.reload()
            services.drawings.reload()
            for drawing in services.drawings.drawings { services.drawings.renderNow(drawing) }
            services.skills.reload()
        }

        func renderAll(into folder: URL) throws {
            func out(_ name: String) -> URL { folder.appendingPathComponent(name + ".png") }
            let home = NSSize(width: 1040, height: 680)
            func homeView() -> some View { HomeView().environment(services).environment(model) }

            // Home
            if let latest = services.chat.sessions.first(where: { $0.drawingCount > 0 }) ?? services.chat.sessions.first {
                services.chat.select(latest.id)
            }
            services.chat.section = .chat
            services.chat.draft = "Can you turn that into a checklist?"
            try render(homeView(), size: home, to: out("home-chat"))
            try render(homeView(), size: home, dark: true, to: out("home-chat-dark"))
            services.chat.draft = ""
            if let live = liveSessionIDs.first {
                services.chat.select(live)
                try render(homeView(), size: home, to: out("home-chat-live"))
            }
            services.chat.section = .agents
            try render(homeView(), size: home, to: out("home-agents"))
            services.chat.section = .drawings
            services.drawings.selectedID = services.drawings.drawings.first?.id
            try render(homeView(), size: home, to: out("home-drawings"))
            services.drawings.selectedID = nil
            services.chat.section = .skills
            try render(homeView(), size: home, to: out("home-skills"))
            try render(homeView(), size: home, dark: true, to: out("home-skills-dark"))
            try renderSkillStates(size: home, view: homeView, out: out)

            // Settings
            let settingsSize = NSSize(width: 860, height: 620)
            func settings() -> some View { SettingsView().environment(services).environment(model) }
            services.voice.showVoices(Self.voices, note: "Voices in your ElevenLabs account.")
            services.voice.setPreviewState(.ready(seconds: 4.2), for: "EXAVITQu4vr4xnSDxMaL")
            services.voice.setPreviewState(.rendering, for: "pNInz6obpgDQGcFmaJgB")
            for page in HomeServices.SettingsPage.allCases {
                services.settingsPage = page
                try render(settings(), size: settingsSize, to: out("settings-\(page.rawValue)"), settle: page == .connectedApps ? 0.8 : 0.4)
            }
            try InfraSnapshots.render(services: services, settings: settings, size: settingsSize, out: out)
            try AgentsUXSnapshots.render(services: services, root: root, settings: settings, size: settingsSize, out: out)
            services.settingsPage = .voice
            try render(settings(), size: settingsSize, dark: true, to: out("settings-voice-dark"))
            services.settingsPage = .browser
            try render(settings(), size: settingsSize, dark: true, to: out("settings-browser-dark"))
            // A refused extension shows "Setup failed" with the reason; a first connection shows its notice.
            let browserState = services.browser.state
            let browserPreferences = services.browser.preferences
            let browserStaged = services.browser.stagedFolder
            services.browser.show(state: .waitingForExtension, preferences: BrowserBridgePreferences(), staged: browserStaged,
                                  failure: BrowserSetupFailure(reason: "A browser extension OpenClicky doesn't know (chrome-extension://abcdefghijklmnopabcdefghijklmnop/) tried to connect. Load OpenClicky's own extension folder.",
                                                               browser: "com.google.Chrome", at: Date()))
            try render(settings(), size: settingsSize, to: out("settings-browser-setup-failed"))
            var first = BrowserBridgePreferences()
            _ = first.noteConnected(Self.peers(now: Date()))
            services.browser.show(state: .connected(Self.peers(now: Date())), preferences: first, staged: browserStaged)
            try render(settings(), size: settingsSize, to: out("settings-browser-first-connection"))
            services.browser.show(state: browserState, preferences: browserPreferences, staged: browserStaged)
            services.talkKeys.startRecording(.handsFreeDictation)
            services.talkKeys.feed([.option])
            services.talkKeys.feed([])
            services.settingsPage = .talkKeys
            try render(settings(), size: settingsSize, to: out("settings-talkKeys-handsfree"))
            services.talkKeys.resetToDefaults()
            services.settingsPage = .talkKeys
            services.talkKeys.startRecording(.dictation)
            services.talkKeys.feed([.control, .option, .shift])
            try render(settings(), size: settingsSize, to: out("settings-talkKeys-recording"))
            // Tearing down the last render cancelled that recording (the page's onDisappear); record the clash again.
            services.talkKeys.startRecording(.dictation)
            services.talkKeys.feed([.control, .option, .shift])
            services.talkKeys.feed([])
            try render(settings(), size: settingsSize, to: out("settings-talkKeys-clash"))
            // Per-slot kinds: talk on a double tap of Option, type with a held Shift+Command.
            services.talkKeys.resetToDefaults()
            services.talkKeys.startRecording(.voice, kind: .doubleTap)
            services.talkKeys.feed([.option])
            services.talkKeys.feed([])
            services.talkKeys.startRecording(.text, kind: .hold)
            services.talkKeys.feed([.shift, .command])
            services.talkKeys.feed([])
            services.settingsPage = .talkKeys
            try render(settings(), size: settingsSize, to: out("settings-talkKeys-kinds"))
            services.talkKeys.resetToDefaults()
            // The whole Permissions page, down to What agents can reach: folders.
            try render(PermissionsSettings().environment(services).environment(model), size: NSSize(width: 670, height: 960),
                       to: out("settings-permissions-full"))

            // Onboarding, one render per step.
            let flow = OnboardingModel(services: services)
            flow.playsAudio = false
            func onboarding() -> some View { OnboardingView(flow: flow).environment(services).environment(model) }
            let onboardingSize = NSSize(width: 720, height: 520)
            var state = OnboardingState()
            func show(_ step: OnboardingStep, _ name: String, _ change: (inout OnboardingState) -> Void = { _ in }) throws {
                state.step = step
                state.furthest = max(state.furthest, step)
                change(&state)
                flow.restore(state)
                try render(onboarding(), size: onboardingSize, to: out("onboarding-\(name)"))
            }
            try show(.welcome, "1-welcome")
            try show(.permissions, "2-permissions") {
                $0.permissions = [.microphone: true, .accessibility: true, .screenRecording: false, .speechRecognition: false]
            }
            flow.showStoredKeys(["anthropic"])
            try show(.providers, "3-providers") {
                $0.providersChecked = true
                $0.providerProblems = ["Voice: No credential named \"elevenlabs\". Add it with: occtl key set elevenlabs"]
                $0.providerWarnings = ["Background agent: Claude Code signs in by itself; the key is only used when you pick it."]
            }
            try show(.voiceTest, "4-voice-test") {
                $0.providerProblems = []
                $0.voiceTest = .succeeded(seconds: 4.6)
            }
            try show(.talkKeys, "5-talk-keys") { $0.practicedTalkKey = true }
            try show(.firstQuestion, "6-first-question")
            try show(.done, "7-done") {
                $0.firstQuestion = "Explain what a VPN does, with a drawing."
                $0.completedAt = Date()
            }
            flow.stopWatchingTalkKeys()
        }

        // MARK: Fixture data

        static let agentReach = AgentReach(
            browsers: [AgentReach.BrowserRow(browser: .safari, permission: .granted),
                       AgentReach.BrowserRow(browser: .chrome, permission: .notDetermined),
                       AgentReach.BrowserRow(browser: .arc, permission: .denied)],
            folders: GuardedFolder.allCases.map { AgentReach.FolderRow(folder: $0, readBefore: $0 == .desktop || $0 == .documents) })

        static let microphones: [AudioDeviceInfo] = [
            AudioDeviceInfo(id: 81, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone", transport: .builtIn, inputChannels: 1,
                            outputChannels: 0, nominalSampleRate: 48_000, isDefaultInput: true, isDefaultOutput: false),
            AudioDeviceInfo(id: 95, uid: "AC-80-0A-11-22-33:input", name: "AirPods Pro", transport: .bluetooth, inputChannels: 1,
                            outputChannels: 0, nominalSampleRate: 24_000, isDefaultInput: false, isDefaultOutput: false),
            AudioDeviceInfo(id: 102, uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:1", name: "Studio Display Microphone", transport: .usb,
                            inputChannels: 3, outputChannels: 0, nominalSampleRate: 48_000, isDefaultInput: false, isDefaultOutput: false),
        ]

        static var vocabulary: DictationVocabulary {
            var vocabulary = DictationVocabulary(words: ["OpenClicky", "SwiftPM", "ElevenLabs", "Haiku", "Jeffrey", "MCP", "ScreenCaptureKit"])
            vocabulary.learn(LearnedCorrection(original: "open clicky", corrected: "OpenClicky", count: 3))
            vocabulary.learn(LearnedCorrection(original: "github", corrected: "GitHub", count: 2))
            return vocabulary
        }

        static func peers(now: Date) -> [BrowserPeer] {
            let json = """
            [{"id":"p1","session":"8f0d6f3e-5b1a-4c2e-9d77-0a1b2c3d4e5f","profileId":"3c9a1f40-6d2b-4e8a-9f11-7b5e2d0c4a99",
              "origin":"chrome-extension://emfgfcpifjoglbdkhjnnmokbagmgmlem/","browser":"com.google.Chrome","extensionVersion":"0.1.0",
              "connectedAt":"2026-10-31T09:12:00Z","lastSeen":"2026-10-31T09:40:00Z"},
             {"id":"p2","session":"1b2c3d4e-0000-4c2e-9d77-0a1b2c3d4e5f","profileId":"a7e3c2b1-1d2e-4f3a-8b9c-0d1e2f3a4b5c",
              "origin":"chrome-extension://emfgfcpifjoglbdkhjnnmokbagmgmlem/","browser":"company.thebrowser.Browser","extensionVersion":"0.1.0",
              "connectedAt":"2026-10-31T09:30:00Z","lastSeen":"2026-10-31T09:40:00Z"}]
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([BrowserPeer].self, from: Data(json.utf8))) ?? []
        }

        /// Chrome with two profiles and OpenClicky's helper manifest, Arc with one profile and none; a staged extension.
        static func writeBrowsers(into support: URL, root: URL) throws {
            let chrome = support.appendingPathComponent("Google/Chrome", isDirectory: true)
            let arc = support.appendingPathComponent("Arc/User Data", isDirectory: true)
            try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
            try #"{"profile":{"info_cache":{"Default":{"name":"Personal","active_time":1761900000.5},"Profile 1":{"name":"Work","active_time":1761990000.0}}}}"#
                .write(to: chrome.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
            try #"{"profile":{"info_cache":{"Default":{"name":"Jeff","active_time":1761000000}}}}"#
                .write(to: arc.appendingPathComponent("Local State"), atomically: true, encoding: .utf8)
            let host = root.appendingPathComponent("OpenClicky.app/Contents/Helpers/OpenClickyBrowserHost")
            try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: host, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
            _ = NativeHostInstaller.install(hostPath: host, applicationSupport: support, browsers: NativeHostInstaller.browsers.filter { $0.id == "chrome" })
            let staged = root.appendingPathComponent("BrowserExtension", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"OpenClicky","version":"0.1.0"}"#.write(to: staged.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }

        static func routineSummaries(now: Date) -> [RoutineSummary] {
            func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }
            var inbox = AgentRoutine(id: "1a2b3c4d", title: "Morning inbox summary", task: "Summarize my unread email from overnight and list anything that needs a reply today.",
                                     schedule: .daily(TimeOfDay(hour: 8, minute: 30), weekdays: [1, 2, 3, 4, 5]), jobID: "morning-inbox-summary-0a1b2c3d4e",
                                     harness: .claudeCode, createdAt: at(24 * 6))
            let calendar = Calendar.current
            // The last four weekday mornings at 08:30.
            var mornings: [Date] = []
            var day = now
            while mornings.count < 4 {
                day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
                if !calendar.isDateInWeekend(day), let slot = calendar.date(bySettingHour: 8, minute: 30, second: 0, of: day) { mornings.append(slot) }
            }
            inbox.runCount = 4
            inbox.lastRunAt = mornings.first
            inbox.lastOutcome = .completed
            inbox.nextRunAt = inbox.schedule.nextRun(after: now)
            var prices = AgentRoutine(id: "5e6f7a8b", title: "Flight price check", task: "Check the price of a return flight SFO to JFK on Dec 20–27 and tell me if it dropped below $350.",
                                      schedule: .every(minutes: 240), jobID: "flight-price-check-9f8e7d6c5b", createdAt: at(30))
            prices.runCount = 5
            prices.lastRunAt = at(1)
            prices.lastOutcome = .failed
            prices.consecutiveFailures = 3
            prices.isPaused = true
            var inboxJob = AgentJobRecord(id: "morning-inbox-summary-0a1b2c3d4e", kind: .job, title: "Morning inbox summary", task: inbox.task,
                                          harness: .claudeCode, model: "claude-haiku-5-5", provider: "anthropic", status: .done,
                                          createdAt: at(24 * 6), updatedAt: at(3), folderPath: "/tmp/jobs/morning-inbox-summary-0a1b2c3d4e")
            inboxJob.runs = mornings.reversed().map { start in
                var run = AgentRun(ask: inbox.task, startedAt: start, routineID: inbox.id)
                run.finishedAt = start.addingTimeInterval(140)
                run.outcome = .completed
                run.spoken = start == mornings.first ? "Six new emails; two need a reply today, from Dana and the landlord." : "Your inbox summary is ready."
                return run
            }
            var pricesJob = AgentJobRecord(id: "flight-price-check-9f8e7d6c5b", kind: .job, title: "Flight price check", task: prices.task,
                                           harness: .codex, model: "gpt-6-luna", provider: "openai", status: .failed, createdAt: at(30), updatedAt: at(1),
                                           error: "The airline site asked for a sign-in the agent couldn't complete.",
                                           folderPath: "/tmp/jobs/flight-price-check-9f8e7d6c5b")
            pricesJob.runs = [(13.0, AgentTurnOutcome.completed), (9.0, .failed), (5.0, .failed), (1.0, .failed)].map { hours, outcome in
                var run = AgentRun(ask: prices.task, startedAt: at(hours), routineID: prices.id)
                run.finishedAt = at(hours - 0.05)
                run.outcome = outcome
                run.spoken = outcome == .completed ? "Still $412 return." : nil
                return run
            }
            return RoutineSummary.make(routines: [inbox, prices], jobs: [inboxJob, pricesJob])
        }

        static let voices: [VoiceOption] = [
            VoiceOption(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", detail: "young adult woman, confident and warm, American"),
            VoiceOption(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", detail: "deep, American, narration"),
            VoiceOption(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", detail: "seductive, Swedish, characters"),
            VoiceOption(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", detail: "authoritative, British, news"),
        ]

        static func program(named name: String, fallback: String) -> String {
            let path = FileManager.default.currentDirectoryPath + "/Tests/Fixtures/Drawing/2d/\(name)"
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? fallback
        }

        static func writeHistory(into directory: URL, now: Date) throws {
            let store = HistoryStore(directory: directory)
            let diagram = program(named: "2-paper-diagram.js", fallback: """
                step(1)
                say("Light enters through the lens and lands on the sensor.")
                box(240, 260, 320, 220, { tone: "#3380FF" })
                arrow(600, 370, 860, 370)
                """)
            let timeline = program(named: "3-graph-timeline.js", fallback: """
                step(1)
                say("Sales climbed every quarter.")
                line(200, 600, 1000, 240)
                """)
            func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
            let canvas = HistoryCanvas(width: 1280, height: 832)
            let first = "older-\(UUID().uuidString.prefix(8))"
            try store.append(HistoryTurn(sessionID: first, startedAt: at(60 * 26), source: .voice, words: "How does a camera actually take a photo?",
                                         frontApp: "Safari", spokenLines: ["Light comes in through the lens.", "The sensor turns it into numbers."],
                                         program: diagram, canvas: canvas, model: "claude-haiku-5-5", rounds: 1,
                                         usage: HistoryUsage(input: 3400, cached: 2900, output: 410),
                                         timings: HistoryTimings(firstEventMs: 690, firstProgramMs: 690, firstLineMs: 910, modelFirstTokenMs: 640, totalMs: 3900)))
            let current = "today-\(UUID().uuidString.prefix(8))"
            try store.append(HistoryTurn(sessionID: current, startedAt: at(14), source: .voice, words: "What's this chart telling me?",
                                         frontApp: "Numbers",
                                         spokenLines: ["Revenue grew every quarter this year.", "The jump in Q3 is the new pricing.",
                                                       "Q4 slowed a little, but still beat last year."],
                                         program: timeline, canvas: canvas, statuses: ["Looking at Numbers"], model: "claude-haiku-5-5", rounds: 1,
                                         usage: HistoryUsage(input: 4100, cached: 3300, output: 520),
                                         timings: HistoryTimings(firstEventMs: 610, firstProgramMs: 610, firstLineMs: 820, modelFirstTokenMs: 580, totalMs: 4200)))
            try store.append(HistoryTurn(sessionID: current, startedAt: at(12), source: .text, words: "Which quarter had the biggest jump?",
                                         spokenLines: ["Q3, by about 18 percent over Q2.", "That's when the new pricing started."],
                                         model: "claude-haiku-5-5", rounds: 1, usage: HistoryUsage(input: 900, cached: 0, output: 40),
                                         timings: HistoryTimings(firstEventMs: 700, firstLineMs: 1100, modelFirstTokenMs: 690, totalMs: 1300)))
            try store.append(HistoryTurn(sessionID: current, startedAt: at(9), source: .voice, words: "Find me a few articles about pricing changes like that",
                                         frontApp: "Numbers", spokenLines: ["I've started a background job to find a few good ones.",
                                                                            "I'll tell you when it's back."],
                                         tools: ["sessions_spawn"], deferredActions: [], model: "claude-haiku-5-5", rounds: 2,
                                         timings: HistoryTimings(firstEventMs: 520, firstLineMs: 1350, modelFirstTokenMs: 500, totalMs: 2600)))
            try store.append(HistoryTurn(sessionID: current, startedAt: at(2), source: .app, words: "", trigger: "job_report",
                                         spokenLines: ["Your pricing articles are ready.", "The Harvard Business Review piece is the best place to start."],
                                         model: "claude-haiku-5-5", rounds: 1,
                                         timings: HistoryTimings(firstEventMs: 480, firstLineMs: 760, modelFirstTokenMs: 450, totalMs: 1900)))
            let failed = "failed-\(UUID().uuidString.prefix(8))"
            try store.append(HistoryTurn(sessionID: failed, startedAt: at(60 * 50), source: .text, words: "Summarize my unread email",
                                         outcome: .failed, errorSpoken: "I couldn't reach the brain model just now.",
                                         errorDetail: "anthropic HTTP 529: overloaded", model: "claude-haiku-5-5",
                                         timings: HistoryTimings(totalMs: 30_000)))
        }

        @discardableResult
        static func copyHistory(from source: URL, into directory: URL) throws -> [String] {
            let sessions = source.appendingPathComponent("sessions")
            let files = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
            let target = directory.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "jsonl" {
                try? FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
            let copied = Set(files.map { $0.deletingPathExtension().lastPathComponent })
            return try HistoryStore(directory: directory).rebuildIndex().map(\.id).filter { copied.contains(HistoryStore.safeName($0)) }
        }

        static func writeSkills(_ directory: URL, state: URL) throws {
            let library = SkillsLibrary(directory: directory, stateURL: state)
            try library.create(name: "Writing coach", description: "Tightens prose while keeping the user's own voice; flags filler words and passive voice before suggesting rewrites.",
                               body: "Read the whole draft before suggesting anything.", enable: true)
            try library.create(name: "Pitch decks", description: "Shapes Keynote slides around one message per slide and a clear ask at the end.",
                               builtFor: "Keynote", body: "One idea per slide.", enable: true)
            try library.create(name: "Spreadsheet tidy-up", description: "Cleans messy spreadsheets: consistent headers, one fact per column, no merged cells.",
                               builtFor: "Numbers", body: "Keep a copy of the original.")
            let loose = directory.appendingPathComponent("video-notes", isDirectory: true)
            try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
            try "# Video editing notes\n\nGives cut-by-cut advice for short videos.\n".write(to: loose.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("half-finished"), withIntermediateDirectories: true)
        }

        static func writeMemory(_ directory: URL) throws {
            let store = MemoryStore(directory: directory)
            _ = try? store.snapshot()
        }

        static func agentHUD(now: Date) -> AgentHUDModel {
            func job(_ id: String, _ title: String, _ status: AgentJobStatus, harness: HarnessKind = .claudeCode, started: TimeInterval) -> AgentJobRecord {
                var record = AgentJobRecord(id: id, kind: .job, title: title, task: title, harness: harness, model: "claude-haiku-5-5",
                                            provider: "anthropic", status: status, createdAt: now.addingTimeInterval(-started),
                                            updatedAt: now.addingTimeInterval(-started), runs: [AgentRun(ask: title, startedAt: now.addingTimeInterval(-started))],
                                            folderPath: "/Users/me/Library/Application Support/OpenClicky/projects/jobs/\(id)")
                if status == .done || status == .failed { record.runs[0].finishedAt = now.addingTimeInterval(-started + 140) }
                return record
            }
            var articles = job("pricing-articles-3f2a91c0de", "Find articles on pricing changes", .done, started: 540)
            articles.report = AgentFinalReport(markdown: "", spoken: "Your pricing articles are ready.", title: "Pricing Articles")
            var deck = job("pitch-deck-outline-9b1e7d22aa", "Outline the Q4 pitch deck", .running, started: 95)
            deck.lastProgress = "Writing: output/q4-deck-outline.md"
            let updates: [AgentManagerUpdate] = [
                .event(jobID: deck.id, .plan([AgentPlanStep(step: "Read last quarter's deck", status: .completed),
                                              AgentPlanStep(step: "Draft one message per slide", status: .inProgress),
                                              AgentPlanStep(step: "Write the outline", status: .pending)])),
                .event(jobID: deck.id, .progress("Writing: output/q4-deck-outline.md")),
            ]
            return AgentHUDModel(records: [deck, articles], updates: updates, now: now)
        }
    }
}

extension OnboardingModel {
    /// Shows a given state (evidence renders).
    func restore(_ state: OnboardingState) {
        restoreMachine(OnboardingMachine(state: state))
    }
}
