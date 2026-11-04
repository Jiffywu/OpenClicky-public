import Foundation
import OpenClickyKit

/// `occtl onboarding …`: the first-run flow without a window. `simulate` drives the same state machine the
/// onboarding window uses, performing its effects headlessly (config validation, a test line written to WAV, an
/// optional typed first question), so the flow can be checked on a Mac where nobody can click permission prompts.
enum OnboardingCommands {
    static let usageText = """
        Usage:
          occtl onboarding status                  where the saved first-run flow stands
          occtl onboarding reset                   forget it, so the app shows onboarding again
          occtl onboarding simulate [--config c.json] [--grant all|none|mic,screen,ax] [--speak f.wav]
                                    [--ask "question" [--send]]
              Walk every step. Permissions are taken from --grant (default: all) instead of macOS. With --speak the
              test line goes through the voice slot into f.wav (nothing plays). With --send the first question goes
              to the brain slot and into the history. The welcome chat is skipped (run it with occtl realtime
              --interview) and the skill picks are shown, not switched on. Never touches the saved progress.
        """

    static let onboarding = OcctlCommand(name: "onboarding", usage: "onboarding <status|reset|simulate>  the first-run flow, headless") { args in
        guard let verb = args.first else { fail(usageText) }
        switch verb {
        case "status":
            guard let state = OnboardingProgress.load() else {
                print("Not started: the app will show onboarding on next launch.")
                return
            }
            if let done = state.completedAt { print("Finished \(done).") } else { print("Stopped at \(state.step.title) (furthest: \(state.furthest.title)).") }
        case "reset":
            try? FileManager.default.removeItem(at: OnboardingProgress.defaultURL)
            print("Onboarding will show on next launch.")
        case "simulate":
            try await simulate(Array(args.dropFirst()))
        default:
            fail(usageText)
        }
    }

    static func simulate(_ args: [String]) async throws {
        var configPath: String?
        var grant = "all"
        var speakPath: String?
        var question = "What can you help me with?"
        var send = false
        var index = 0
        func value() -> String {
            index += 1
            guard index < args.count else { fail("\(args[index - 1]) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--config": configPath = value()
            case "--grant": grant = value()
            case "--speak": speakPath = value()
            case "--ask": question = value()
            case "--send": send = true
            default: fail(usageText)
            }
            index += 1
        }
        let config = try EngineCommands.loadConfig(configPath)
        let catalog = try ModelCatalog.builtIn().merging(config.models)
        let factory = EngineFactory(config: config, catalog: catalog, credentials: CoreCommands.store)
        let granted = permissions(from: grant)

        var machine = OnboardingMachine()
        var pending: [OnboardingEvent] = []

        func perform(_ effects: [OnboardingEffect]) async {
            for effect in effects {
                switch effect {
                case .watchPermissions:
                    print("    effect: watch permissions → \(granted.filter(\.value).keys.map(\.rawValue).sorted().joined(separator: ", "))")
                    pending.append(.permissionsChanged(granted))
                case .stopWatchingPermissions, .saveProgress, .close, .sendInterviewText, .closeInterview, .saveInterview:
                    break
                case .openInterview:
                    print("    effect: would open the welcome chat in the realtime voice (try it with occtl realtime --interview)")
                case .loadSkillPicks:
                    let picks = SkillPicker.firstLaunchDefaults
                    print("    effect: skill picks → first-launch defaults (\(picks.joined(separator: ", ")))")
                    pending.append(.skillPicksLoaded(picks))
                case .activateSkills(let picks):
                    let skills = SkillPicker().skillIDs(for: picks)
                    print("    effect: would switch on \(skills.joined(separator: ", ")) (the library is left alone here)")
                    pending.append(.skillsActivated("Would switch on \(skills.count) skill\(skills.count == 1 ? "" : "s")."))
                case .requestPermission(let permission):
                    print("    effect: ask macOS for \(permission.rawValue) (skipped: no prompts here)")
                case .checkProviders:
                    let issues = ConfigValidator(catalog: catalog, credentials: CoreCommands.store).validate(config)
                    let split = OnboardingProviderCheck.split(issues, config: config)
                    print("    effect: checked providers → \(split.blocking.count) blocking, \(split.warnings.count) warning(s)")
                    for line in split.blocking { print("      blocking: \(line)") }
                    for line in split.warnings { print("      warning: \(line)") }
                    pending.append(.providersChecked(blocking: split.blocking, warnings: split.warnings))
                case .speakTestLine(let line):
                    guard let speakPath else { continue }
                    do {
                        let renderer = VoicePreviewRenderer(cacheIdentity: "onboarding", cacheDirectory: nil) { try factory.speechOutput() }
                        let clip = try await renderer.render(voice: nil, text: line, useCache: false)
                        try clip.wavData.write(to: URL(fileURLWithPath: speakPath))
                        print(String(format: "    effect: spoke the test line → %@ (%.1f s, first audio %.2f s)", speakPath, clip.duration,
                                     clip.firstAudioSeconds ?? 0))
                        pending.append(.voiceTestFinished(seconds: clip.duration))
                    } catch {
                        print("    effect: test line failed: \(error)")
                        pending.append(.voiceTestFailed("\(error)"))
                    }
                case .sendFirstQuestion(let text):
                    guard send else {
                        print("    effect: would send \"\(text)\" to the brain (add --send)")
                        continue
                    }
                    let brain = try? StandInTextBrain.forBrainSlot(factory) { [SkillsCommands.library().skillsPromptSection()] }
                    guard let brain else { print("    effect: no brain slot"); continue }
                    let chat = TypedChatController(brain: brain, history: HistoryStore(directory: HistoryCommands.directory))
                    // Like the app: the first question opens its own conversation.
                    await chat.startNewConversation()
                    let turn = await chat.send(text)
                    print("    effect: asked \"\(text)\" → \(turn.replyText) [\(turn.outcome.rawValue), \(turn.timings.totalMs ?? 0) ms, turn \(turn.id)]")
                }
            }
        }

        func step(_ event: OnboardingEvent) async {
            let before = machine.step
            let effects = machine.send(event)
            print("\(before.title) + \(describe(event)) → \(machine.step.title)" + (machine.blocker.map { "  [blocked: \($0)]" } ?? ""))
            await perform(effects)
            while !pending.isEmpty {
                let next = pending.removeFirst()
                let effects = machine.send(next)
                print("  \(describe(next)) → \(machine.step.title)" + (machine.blocker.map { "  [blocked: \($0)]" } ?? ""))
                await perform(effects)
            }
        }

        await step(.next)                       // welcome → permissions
        if machine.canContinue { await step(.next) } else { await step(.continueWithoutPermissions) }
        guard machine.canContinue else {
            print("Stopped: \(machine.blocker ?? "")")
            exit(2)
        }
        await step(.next)                       // providers → voice test
        if speakPath != nil { await step(.startVoiceTest) }
        if machine.canContinue { await step(.next) } else { await step(.skipVoiceTest) }
        await step(.talkKeyPracticed)
        print("    talk keys: \(TalkKeySettings.load().voice.phrase) to talk, \(TalkKeySettings.load().text.phrase) to type")
        await step(.next)                       // talk keys → welcome chat
        await step(.skipInterview)              // welcome chat → skills
        await step(.next)                       // skills → first question
        await step(.askFirstQuestion(question))
        print(machine.isComplete ? "Onboarding complete." : "Onboarding stopped at \(machine.step.title).")
    }

    static func permissions(from text: String) -> [OnboardingPermission: Bool] {
        var result = Dictionary(uniqueKeysWithValues: OnboardingPermission.allCases.map { ($0, false) })
        switch text {
        case "all": for key in result.keys { result[key] = true }
        case "none": break
        default:
            for item in text.split(separator: ",") {
                switch item.trimmingCharacters(in: .whitespaces).lowercased() {
                case "mic", "microphone": result[.microphone] = true
                case "screen", "screenrecording": result[.screenRecording] = true
                case "ax", "accessibility": result[.accessibility] = true
                case "speech", "speechrecognition": result[.speechRecognition] = true
                default: fail("Unknown permission \(item); use mic, screen, ax or speech.")
                }
            }
        }
        return result
    }

    static func describe(_ event: OnboardingEvent) -> String {
        switch event {
        case .next: "Continue"
        case .back: "Back"
        case .goTo(let step): "go to \(step.title)"
        case .permissionsChanged(let status): "permissions (\(status.filter(\.value).count)/\(status.count) granted)"
        case .requestPermission(let permission): "ask for \(permission.rawValue)"
        case .continueWithoutPermissions: "Continue without"
        case .providersChecked(let blocking, _): "providers checked (\(blocking.isEmpty ? "ok" : "\(blocking.count) blocking"))"
        case .startVoiceTest: "Play test line"
        case .voiceTestFinished(let seconds): String(format: "test line spoke %.1f s", seconds)
        case .voiceTestFailed(let message): "test line failed (\(message))"
        case .skipVoiceTest: "Skip voice test"
        case .talkKeyPracticed: "talk key practiced"
        case .askFirstQuestion(let text): "Ask \"\(text)\""
        case .startInterview: "Start the welcome chat"
        case .interviewReady: "welcome chat ready"
        case .interviewPreparationFailed(let why): "welcome chat failed (\(why))"
        case .interviewAnswered(let text, let typed): "answered\(typed ? " (typed)" : "") \"\(text)\""
        case .interviewSaid(let text): "OpenClicky said \"\(text)\""
        case .interviewAnswerRevised(let text): "answer revised to \"\(text)\""
        case .interviewTyping(let on): on ? "type instead" : "talk instead"
        case .interviewEnded(let why): "welcome chat ended (\(why))"
        case .skipInterview: "Skip the welcome chat"
        case .skillPicksLoaded(let picks): "skill picks loaded (\(picks.joined(separator: ", ")))"
        case .toggleSkillPick(let id): "toggle \(id)"
        case .skillsActivated(let note): "skills: \(note)"
        case .dismiss: "Close"
        case .restart: "Replay"
        }
    }
}
