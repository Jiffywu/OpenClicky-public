import Foundation

// The first-run flow as a pure state machine. The window feeds it what happened (a permission changed, a key was
// saved, the test line finished) and performs the effects it returns, so the whole flow runs in tests and in
// `occtl onboarding simulate` without a screen, permissions or audio.

public enum OnboardingStep: String, Codable, Sendable, CaseIterable, Comparable {
    /// What OpenClicky is and how it works.
    case welcome
    /// Microphone, screen recording and accessibility, with live status.
    case permissions
    /// Pick providers and paste keys.
    case providers
    /// Speak a test line through the voice slot.
    case voiceTest
    /// The talk keys, with a chance to try them.
    case talkKeys
    /// A short welcome chat in the realtime voice (or typed), saved to memory.
    case interview
    /// "What should it be good at?": starter skills to switch on.
    case skills
    /// Suggested first questions.
    case firstQuestion
    case done

    public static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .permissions: "Permissions"
        case .providers: "Models and keys"
        case .voiceTest: "Test the voice"
        case .talkKeys: "Talk keys"
        case .interview: "Welcome chat"
        case .skills: "Skills"
        case .firstQuestion: "First question"
        case .done: "All set"
        }
    }

    var next: OnboardingStep? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index + 1 < all.count ? all[index + 1] : nil
    }

    var previous: OnboardingStep? {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return index > 0 ? all[index - 1] : nil
    }
}

/// The permissions onboarding asks for. Speech recognition is only needed for the Apple Speech listener.
public enum OnboardingPermission: String, Codable, Sendable, CaseIterable, Hashable {
    case microphone, screenRecording, accessibility, speechRecognition

    public var isRequired: Bool { self != .speechRecognition }
}

public enum OnboardingVoiceTest: Codable, Sendable, Hashable {
    case notTried
    case speaking
    case succeeded(seconds: Double)
    case failed(String)
}

public enum OnboardingEvent: Sendable, Hashable {
    case next
    case back
    /// Jump to a step already reached (the step list in the window).
    case goTo(OnboardingStep)
    /// Live permission status, polled while the permissions step is open.
    case permissionsChanged([OnboardingPermission: Bool])
    case requestPermission(OnboardingPermission)
    /// Go on without every required permission; OpenClicky keeps asking from Settings.
    case continueWithoutPermissions
    /// The config was validated: blocking problems for the slots onboarding needs, and warnings for the rest.
    case providersChecked(blocking: [String], warnings: [String])
    case startVoiceTest
    case voiceTestFinished(seconds: Double)
    case voiceTestFailed(String)
    case skipVoiceTest
    /// The user held the voice talk key during the tutorial.
    case talkKeyPracticed
    case askFirstQuestion(String)
    /// Open the welcome chat again from the start (its step's "Start over").
    case startInterview
    /// The realtime session for the welcome chat is on.
    case interviewReady
    /// The realtime session couldn't be opened; the flow tries once more, then falls back to typing.
    case interviewPreparationFailed(String)
    /// The user answered, by voice (a final transcript) or typed.
    case interviewAnswered(String, typed: Bool)
    /// What OpenClicky said in the welcome chat (one finished reply).
    case interviewSaid(String)
    /// A longer transcript of the last spoken answer arrived after it was counted (transcription can trail the reply).
    case interviewAnswerRevised(String)
    /// Show or hide the "type instead" field.
    case interviewTyping(Bool)
    /// The session dropped mid-chat; the rest is typed.
    case interviewEnded(String)
    /// The skip button, or the model's `skip_onboarding_interview` tool: answers so far are kept and the flow goes on.
    case skipInterview
    /// The saved skill picks (with first-launch defaults applied), loaded when the skills step first opens.
    case skillPicksLoaded([String])
    case toggleSkillPick(String)
    /// What switching the picked skills on did, for the step list.
    case skillsActivated(String)
    /// Close the flow from any step; it stays incomplete and can be resumed.
    case dismiss
    /// Start again from the welcome step (Settings → Replay welcome).
    case restart
}

public enum OnboardingEffect: Sendable, Hashable {
    /// Ask macOS for a permission (or open the right System Settings pane).
    case requestPermission(OnboardingPermission)
    /// Start polling permission status (the permissions step opened).
    case watchPermissions
    case stopWatchingPermissions
    /// Validate the current config and report back with `providersChecked`.
    case checkProviders
    /// Speak the test line through the voice slot and report back.
    case speakTestLine(String)
    /// Send the user's first question to the brain as a typed turn.
    case sendFirstQuestion(String)
    /// Open a realtime session for the welcome chat (`attempt` is 1, then 2 for the one retry) and report back with
    /// `interviewReady` or `interviewPreparationFailed`.
    case openInterview(attempt: Int)
    /// Add text to the welcome chat's session: a note (`respond` false) or a typed answer / opener request.
    case sendInterviewText(String, respond: Bool)
    /// Close the welcome chat's session once what it is saying has been heard.
    case closeInterview
    /// Save the transcript and write the answers into the memory profile.
    case saveInterview(OnboardingInterviewState)
    /// Load the saved skill picks (applying the first-launch defaults once) and report back with `skillPicksLoaded`.
    case loadSkillPicks
    /// Save the picks and switch on the skills they bundle; report back with `skillsActivated`.
    case activateSkills([String])
    /// Persist `OnboardingProgress`.
    case saveProgress
    case close
}

/// Everything the flow knows. Codable so a half-finished onboarding resumes where it stopped.
public struct OnboardingState: Codable, Sendable, Hashable {
    public var step: OnboardingStep = .welcome
    /// The furthest step reached; the step list lets the user jump back to any of them.
    public var furthest: OnboardingStep = .welcome
    public var permissions: [OnboardingPermission: Bool] = [:]
    public var continuedWithoutPermissions = false
    public var providerProblems: [String] = []
    public var providerWarnings: [String] = []
    /// Whether the providers have been checked since the step opened.
    public var providersChecked = false
    public var voiceTest: OnboardingVoiceTest = .notTried
    public var practicedTalkKey = false
    public var firstQuestion: String?
    public var completedAt: Date?
    /// The welcome chat.
    public var interview = OnboardingInterviewState()
    /// Picker entry ids chosen on the skills step; nil until the step has loaded them.
    public var skillPicks: [String]?
    /// The picks that were last switched on, so leaving the step again without a change does nothing.
    public var activatedSkillPicks: [String]?
    /// What switching the picks on did.
    public var skillsNote: String?

    public init() {}

    public var missingRequiredPermissions: [OnboardingPermission] {
        OnboardingPermission.allCases.filter { $0.isRequired && permissions[$0] != true }
    }
}

extension OnboardingState {
    enum CodingKeys: String, CodingKey {
        case step, furthest, permissions, continuedWithoutPermissions, providerProblems, providerWarnings, providersChecked
        case voiceTest, practicedTalkKey, firstQuestion, completedAt, interview, skillPicks, activatedSkillPicks, skillsNote
    }

    /// Every key is optional, so a file saved before a step existed still loads (and a finished onboarding stays
    /// finished).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        step = try container.decodeIfPresent(OnboardingStep.self, forKey: .step) ?? .welcome
        furthest = try container.decodeIfPresent(OnboardingStep.self, forKey: .furthest) ?? step
        permissions = try container.decodeIfPresent([OnboardingPermission: Bool].self, forKey: .permissions) ?? [:]
        continuedWithoutPermissions = try container.decodeIfPresent(Bool.self, forKey: .continuedWithoutPermissions) ?? false
        providerProblems = try container.decodeIfPresent([String].self, forKey: .providerProblems) ?? []
        providerWarnings = try container.decodeIfPresent([String].self, forKey: .providerWarnings) ?? []
        providersChecked = try container.decodeIfPresent(Bool.self, forKey: .providersChecked) ?? false
        voiceTest = try container.decodeIfPresent(OnboardingVoiceTest.self, forKey: .voiceTest) ?? .notTried
        practicedTalkKey = try container.decodeIfPresent(Bool.self, forKey: .practicedTalkKey) ?? false
        firstQuestion = try container.decodeIfPresent(String.self, forKey: .firstQuestion)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        interview = try container.decodeIfPresent(OnboardingInterviewState.self, forKey: .interview) ?? OnboardingInterviewState()
        skillPicks = try container.decodeIfPresent([String].self, forKey: .skillPicks)
        activatedSkillPicks = try container.decodeIfPresent([String].self, forKey: .activatedSkillPicks)
        skillsNote = try container.decodeIfPresent(String.self, forKey: .skillsNote)
    }
}

/// The rules: which step comes next, what blocks it, and which effects each event causes.
public struct OnboardingMachine: Sendable, Hashable {
    public private(set) var state: OnboardingState
    private let now: @Sendable () -> Date

    public static let testLine = "Hi! I'm OpenClicky. Hold your talk keys and ask me anything about your screen."

    public init(state: OnboardingState = OnboardingState(), now: @escaping @Sendable () -> Date = Date.init) {
        self.state = state
        self.now = now
    }

    public static func == (lhs: OnboardingMachine, rhs: OnboardingMachine) -> Bool { lhs.state == rhs.state }
    public func hash(into hasher: inout Hasher) { hasher.combine(state) }

    public var step: OnboardingStep { state.step }
    public var isComplete: Bool { state.completedAt != nil }

    /// Why Continue is disabled on the current step, or nil when the user may go on.
    public var blocker: String? {
        switch state.step {
        case .welcome, .talkKeys, .interview, .skills, .firstQuestion, .done:
            return nil
        case .permissions:
            let missing = state.missingRequiredPermissions
            guard !missing.isEmpty, !state.continuedWithoutPermissions else { return nil }
            return "Waiting for " + missing.map(Self.name).joined(separator: ", ") + "."
        case .providers:
            if !state.providersChecked { return "Checking your models and keys…" }
            return state.providerProblems.first
        case .voiceTest:
            switch state.voiceTest {
            case .speaking: return "Speaking the test line…"
            case .notTried, .failed: return "Play the test line first, or skip it."
            case .succeeded: return nil
            }
        }
    }

    public var canContinue: Bool { blocker == nil }

    static func name(_ permission: OnboardingPermission) -> String {
        switch permission {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .speechRecognition: "Speech Recognition"
        }
    }

    /// Applies an event and returns what the app should do.
    @discardableResult
    public mutating func send(_ event: OnboardingEvent) -> [OnboardingEffect] {
        switch event {
        case .next:
            guard canContinue, let next = state.step.next else { return [] }
            return move(to: next)
        case .back:
            guard let previous = state.step.previous, state.step != .done else { return [] }
            return move(to: previous)
        case .goTo(let step):
            guard step <= state.furthest, step != state.step, step != .done else { return [] }
            return move(to: step)
        case .permissionsChanged(let status):
            state.permissions.merge(status) { _, new in new }
            return []
        case .requestPermission(let permission):
            return [.requestPermission(permission)]
        case .continueWithoutPermissions:
            guard state.step == .permissions else { return [] }
            state.continuedWithoutPermissions = true
            return move(to: .providers)
        case .providersChecked(let blocking, let warnings):
            state.providersChecked = true
            state.providerProblems = blocking
            state.providerWarnings = warnings
            return []
        case .startVoiceTest:
            guard state.step == .voiceTest, state.voiceTest != .speaking else { return [] }
            state.voiceTest = .speaking
            return [.speakTestLine(Self.testLine)]
        case .voiceTestFinished(let seconds):
            guard state.voiceTest == .speaking else { return [] }
            state.voiceTest = seconds > 0 ? .succeeded(seconds: seconds) : .failed("No audio came back from the voice.")
            return [.saveProgress]
        case .voiceTestFailed(let message):
            guard state.voiceTest == .speaking else { return [] }
            state.voiceTest = .failed(message)
            return []
        case .skipVoiceTest:
            guard state.step == .voiceTest, state.voiceTest != .speaking else { return [] }
            return move(to: .talkKeys)
        case .talkKeyPracticed:
            guard state.step == .talkKeys else { return [] }
            state.practicedTalkKey = true
            return [.saveProgress]
        case .askFirstQuestion(let question):
            let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.step == .firstQuestion, !question.isEmpty else { return [] }
            state.firstQuestion = question
            return move(to: .done) + [.sendFirstQuestion(question)]
        case .startInterview:
            guard state.step == .interview, !state.interview.isRunning else { return [] }
            return beginInterview() + [.saveProgress]
        case .interviewReady:
            guard state.interview.phase == .preparing else { return [] }
            state.interview.phase = .live
            state.interview.failure = nil
            return [.sendInterviewText(OnboardingInterviewScript.openerNote, respond: true)]
        case .interviewPreparationFailed(let message):
            guard state.interview.phase == .preparing else { return [] }
            if state.interview.attempts < OnboardingInterviewScript.maxAttempts {
                state.interview.attempts += 1
                return [.openInterview(attempt: state.interview.attempts)]
            }
            // No voice chat today: the same questions, typed.
            state.interview.phase = .scripted
            state.interview.failure = message
            state.interview.typing = true
            for line in OnboardingInterviewScript.opener {
                state.interview.lines.append(OnboardingInterviewLine(role: .assistant, text: line))
            }
            return [.saveProgress]
        case .interviewAnswered(let text, let typed):
            return interviewAnswered(text, typed: typed)
        case .interviewSaid(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard state.interview.phase == .live, !text.isEmpty else { return [] }
            state.interview.lines.append(OnboardingInterviewLine(role: .assistant, text: text))
            guard state.interview.answers.count >= state.interview.total else { return [] }
            // The wrap-up after the last answer: the chat is over.
            state.interview.phase = .finished
            state.interview.saved = true
            return [.closeInterview, .saveInterview(state.interview), .saveProgress]
        case .interviewAnswerRevised(let text):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard [.live, .finished].contains(state.interview.phase), !text.isEmpty,
                  let index = state.interview.lines.lastIndex(where: { $0.role == .user }),
                  state.interview.lines[index].typed != true else { return [] }
            state.interview.lines[index].text = text
            return []
        case .interviewTyping(let on):
            guard state.step == .interview, state.interview.phase == .live else { return [] }
            state.interview.typing = on
            return []
        case .interviewEnded(let message):
            guard state.interview.phase == .live else { return [] }
            // Carry on typed from where the voice stopped.
            state.interview.phase = .scripted
            state.interview.failure = message
            state.interview.typing = true
            return [.closeInterview, .saveProgress]
        case .skipInterview:
            guard acceptsInterviewSkip else { return [] }
            var effects = endInterview(as: .skipped)
            if state.step == .interview, let next = state.step.next { effects += move(to: next) }
            return effects
        case .skillPicksLoaded(let picks):
            guard state.skillPicks == nil else { return [] }
            state.skillPicks = picks
            return []
        case .toggleSkillPick(let id):
            guard state.step == .skills else { return [] }
            var picks = state.skillPicks ?? []
            if let index = picks.firstIndex(of: id) { picks.remove(at: index) } else { picks.append(id) }
            state.skillPicks = picks
            return [.saveProgress]
        case .skillsActivated(let note):
            state.skillsNote = note
            return [.saveProgress]
        case .dismiss:
            let closing: [OnboardingEffect] = state.step == .interview && state.interview.isRunning ? [.closeInterview] : []
            if state.step == .interview, state.interview.isRunning {
                // A chat cut off by closing the window starts again when the flow resumes.
                state.interview = OnboardingInterviewState()
            }
            return closing + (state.step == .permissions ? [.stopWatchingPermissions] : []) + [.saveProgress, .close]
        case .restart:
            let permissions = state.permissions
            let closing: [OnboardingEffect] = state.interview.isRunning ? [.closeInterview] : []
            state = OnboardingState()
            state.permissions = permissions
            return closing + [.saveProgress]
        }
    }

    /// Whether `skip_onboarding_interview` (or the skip button) would end a chat now.
    public var acceptsInterviewSkip: Bool {
        state.step == .interview && [.preparing, .live, .scripted].contains(state.interview.phase)
    }

    private mutating func beginInterview() -> [OnboardingEffect] {
        state.interview = OnboardingInterviewState()
        state.interview.phase = .preparing
        state.interview.attempts = 1
        state.interview.startedAt = now()
        return [.openInterview(attempt: 1)]
    }

    private mutating func interviewAnswered(_ text: String, typed: Bool) -> [OnboardingEffect] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let phase = state.interview.phase
        guard phase == .live || phase == .scripted, !text.isEmpty, state.interview.answers.count < state.interview.total else { return [] }
        state.interview.lines.append(OnboardingInterviewLine(role: .user, text: text, typed: typed ? true : nil))
        let answered = state.interview.answers.count
        let total = state.interview.total
        if phase == .live {
            // The count goes in as a note so the model knows which question comes next; a typed answer then asks
            // for the reply.
            let asked = state.interview.questions.map(OnboardingInterviewArchive.lastSentence)
            let note = RealtimeInstructions.interviewProgress(asked: asked, answered: answered, total: total)
            return [.sendInterviewText(note, respond: false)] + (typed ? [.sendInterviewText(text, respond: true)] : [])
        }
        // Typed without a voice session: OpenClicky's own questions, then a short close.
        if answered < total {
            state.interview.lines.append(OnboardingInterviewLine(role: .assistant, text: OnboardingInterviewScript.question(after: answered, total: total)))
            return [.saveProgress]
        }
        state.interview.lines.append(OnboardingInterviewLine(role: .assistant, text: OnboardingInterviewScript.typedWrapUp))
        state.interview.phase = .finished
        state.interview.saved = true
        return [.saveInterview(state.interview), .saveProgress]
    }

    /// Ends a chat that is preparing, live or typed: answers so far are kept and saved.
    private mutating func endInterview(as phase: OnboardingInterviewPhase) -> [OnboardingEffect] {
        let wasOpen = state.interview.isRunning
        state.interview.phase = phase
        state.interview.typing = false
        var effects: [OnboardingEffect] = wasOpen ? [.closeInterview] : []
        if !state.interview.answers.isEmpty, !state.interview.saved {
            state.interview.saved = true
            effects.append(.saveInterview(state.interview))
        }
        return effects
    }

    private mutating func move(to step: OnboardingStep) -> [OnboardingEffect] {
        var effects: [OnboardingEffect] = []
        if state.step == .permissions, step != .permissions { effects.append(.stopWatchingPermissions) }
        // Leaving the chat while it runs counts as skipping it; answers so far are kept.
        if state.step == .interview, step != .interview, [.preparing, .live, .scripted].contains(state.interview.phase) {
            effects += endInterview(as: .skipped)
        }
        // Leaving the picker switches on what was picked (once per change).
        if state.step == .skills, step != .skills, let picks = state.skillPicks, picks != state.activatedSkillPicks {
            state.activatedSkillPicks = picks
            effects.append(.activateSkills(picks))
        }
        state.step = step
        state.furthest = max(state.furthest, step)
        switch step {
        case .permissions:
            effects.append(.watchPermissions)
        case .providers:
            state.providersChecked = false
            effects.append(.checkProviders)
        case .interview:
            if state.interview.phase == .notStarted { effects += beginInterview() }
        case .skills:
            if state.skillPicks == nil { effects.append(.loadSkillPicks) }
        case .done:
            if state.completedAt == nil { state.completedAt = now() }
        default:
            break
        }
        effects.append(.saveProgress)
        return effects
    }
}

/// The saved onboarding state at `~/Library/Application Support/OpenClicky/onboarding.json`.
public enum OnboardingProgress {
    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("onboarding.json")
    }

    public static func load(from url: URL = defaultURL) -> OnboardingState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnboardingState.self, from: data)
    }

    public static func save(_ state: OnboardingState, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var saved = state
        // Live status is re-read on launch; a stale "granted" must never skip the step.
        saved.permissions = [:]
        if saved.voiceTest == .speaking { saved.voiceTest = .notTried }
        // A session can't survive a relaunch: a chat that was open starts again when the step reopens.
        if saved.interview.isRunning { saved.interview = OnboardingInterviewState() }
        try encoder.encode(saved).write(to: url, options: .atomic)
    }

    /// First launch, or a flow the user left before the end.
    public static func needsOnboarding(at url: URL = defaultURL) -> Bool { load(from: url)?.completedAt == nil }
}

/// Which config problems block onboarding: listening, the voice and the brain must work; the agent and the optional
/// slots only warn (background jobs can be set up later).
public enum OnboardingProviderCheck {
    public static let requiredSlots: Set<SlotID> = [.stt, .voice, .brain]

    public static func label(_ slot: SlotID) -> String {
        switch slot {
        case .stt: "Listening"
        case .voice: "Voice"
        case .brain: "Brain"
        case .agent: "Background agent"
        case .brainFast: "Quick text work"
        case .realtimeVoice: "Always-on voice"
        }
    }

    /// Splits issues, counting a missing key as blocking only when a required slot's provider names it.
    public static func split(_ issues: [ConfigIssue], config: OpenClickyConfig) -> (blocking: [String], warnings: [String]) {
        let requiredCredentials = Set(requiredSlots.compactMap { config.selection(for: $0) }
            .compactMap { config.provider($0.provider)?.credential })
        var blocking: [String] = []
        var warnings: [String] = []
        for issue in issues {
            if let slot = issue.slot {
                let line = "\(label(slot)): \(issue.message)"
                if issue.severity == .error && requiredSlots.contains(slot) { blocking.append(line) } else { warnings.append(line) }
            } else if issue.severity == .error,
                      requiredCredentials.contains(where: { issue.message.contains("\"\($0)\"") }) {
                blocking.append(issue.message)
            } else {
                warnings.append(issue.message)
            }
        }
        return (blocking, warnings)
    }
}

/// Ready-made provider choices for the onboarding "Models and keys" step. Each one adds the providers it needs
/// (from `ProviderPreset`) and fills the slots; the user then pastes the keys it names.
public struct OnboardingSetupPlan: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    /// Provider preset ids to add when missing.
    public var presets: [String]
    public var slots: [SlotID: SlotSelection]

    public static let all: [OnboardingSetupPlan] = [
        OnboardingSetupPlan(
            id: "claude-mac-voice", title: "Claude, with voices on this Mac",
            detail: "One Anthropic key. Claude answers; listening and speaking stay on the Mac.",
            presets: ["anthropic", "apple-speech", "apple-voices"],
            slots: [.brain: SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5"),
                    .brainFast: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5"),
                    .stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                    .voice: SlotSelection(provider: "apple-voices", model: "system"),
                    .agent: SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5", harness: .claudeCode)]),
        OnboardingSetupPlan(
            id: "claude-elevenlabs", title: "Claude with an ElevenLabs voice",
            detail: "Anthropic and ElevenLabs keys. A natural voice that starts speaking fast.",
            presets: ["anthropic", "apple-speech", "elevenlabs"],
            slots: [.brain: SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5"),
                    .brainFast: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5"),
                    .stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                    .voice: SlotSelection(provider: "elevenlabs", model: "eleven_flash_v2_5", voice: "EXAVITQu4vr4xnSDxMaL"),
                    .agent: SlotSelection(provider: "anthropic", model: "claude-sonnet-5-5", harness: .claudeCode)]),
        OnboardingSetupPlan(
            id: "openai", title: "OpenAI, like HeyClicky",
            detail: "One OpenAI key: the realtime voice, GPT as the brain and Codex for background jobs.",
            presets: ["openai", "openai-realtime", "apple-speech"],
            slots: OpenClickyConfig.heyClickyLike.slots.filter { $0.key != .realtimeVoice }),
    ]

    /// The config with this plan's providers added and its slots filled. Other providers and slots are kept.
    public func apply(to config: OpenClickyConfig) -> OpenClickyConfig {
        var updated = config
        for presetID in presets where updated.provider(presetID) == nil {
            if let preset = ProviderPreset.all.first(where: { $0.id == presetID }) { updated.providers.append(preset.config) }
        }
        for (slot, selection) in slots { updated.slots[slot] = selection }
        return updated
    }

    /// Whether the config already uses this plan for every slot it sets.
    public func isApplied(in config: OpenClickyConfig) -> Bool {
        slots.allSatisfy { config.slots[$0.key]?.provider == $0.value.provider && config.slots[$0.key]?.model == $0.value.model }
    }

    /// Credential names the config's slots need, with the provider preset that explains where to get each.
    public static func neededKeys(for config: OpenClickyConfig) -> [(name: String, preset: ProviderPreset?)] {
        var names: [String] = []
        for slot in SlotID.allCases {
            guard let selection = config.slots[slot], let provider = config.provider(selection.provider),
                  !provider.dialect.isOnDevice, provider.dialect != .harnessLogin, let name = provider.credential,
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names.map { name in (name, ProviderPreset.all.first { $0.config.credential == name }) }
    }
}
