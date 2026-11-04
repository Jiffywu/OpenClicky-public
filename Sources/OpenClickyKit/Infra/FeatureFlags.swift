import Foundation

// One typed registry of OpenClicky's switches (docs/infra.md). Each flag has a default, says which part of the app
// reads it, and names the HeyClicky `Clicky*` defaults keys it stands in for. `HeyClickyFlagKeys.all` accounts for
// every such key: covered by a flag here, covered by a regular setting elsewhere, or dropped with the reason. The
// Developer page lists them all and the diagnostics bundle includes their values.

/// A boolean switch with a default.
public struct FeatureFlag: Sendable, Hashable, Identifiable {
    public enum Group: String, Sendable, Hashable, CaseIterable, Codable {
        case providers, usage, diagnostics, brain, voice, drawing, agents, notch, onboarding, developer

        public var title: String {
            switch self {
            case .providers: "Provider calls"
            case .usage: "Usage"
            case .diagnostics: "Diagnostics"
            case .brain: "Brain"
            case .voice: "Voice"
            case .drawing: "Drawing"
            case .agents: "Agents"
            case .notch: "Notch"
            case .onboarding: "Onboarding"
            case .developer: "Developer"
            }
        }
    }

    /// Stable id, also the key in flags.json ("providers.retries").
    public let id: String
    public let title: String
    public let summary: String
    public let defaultValue: Bool
    public let group: Group
    /// The HeyClicky defaults keys this flag stands in for.
    public let replaces: [String]
    /// What reads the flag, or nil when nothing does yet (kept so the choice survives until the feature lands).
    public let readBy: String?

    public init(id: String, title: String, summary: String, defaultValue: Bool, group: Group, replaces: [String] = [], readBy: String?) {
        self.id = id
        self.title = title
        self.summary = summary
        self.defaultValue = defaultValue
        self.group = group
        self.replaces = replaces
        self.readBy = readBy
    }

    public var isWired: Bool { readBy != nil }
}

extension FeatureFlag {
    // Infrastructure (this registry's own readers).
    public static let providerRetries = FeatureFlag(
        id: "providers.retries", title: "Retry provider calls",
        summary: "Try brain, voice and listening calls again after rate limits, overloads and dropped connections, honouring Retry-After.",
        defaultValue: true, group: .providers, readBy: "ProviderResilience.standard (engine factory)")
    public static let providerDiagnosis = FeatureFlag(
        id: "providers.diagnosis", title: "Explain provider failures",
        summary: "When a session can't open, probe the provider and say plainly whether it's the region, the network, the key or an outage.",
        defaultValue: true, group: .providers, readBy: "ProviderResilience.standard (engine factory)")
    public static let usageLedger = FeatureFlag(
        id: "usage.ledger", title: "Keep a usage ledger",
        summary: "Write each model call, spoken line, listening session and lookup to the local ledger (Settings → Usage).",
        defaultValue: true, group: .usage, replaces: ["ClickyOpenAIModelPricing"], readBy: "ProviderResilience.standard (engine factory)")
    public static let diagnosticsUnifiedLog = FeatureFlag(
        id: "diagnostics.unified-log", title: "Include recent logs in bug reports",
        summary: "Add the last 30 minutes of OpenClicky's unified log (scrubbed of keys and tokens) to the diagnostics bundle.",
        defaultValue: true, group: .diagnostics, readBy: "DiagnosticsBundle")
    public static let brainStats = FeatureFlag(
        id: "developer.brain-stats", title: "Show brain stats",
        summary: "Show the brain session's turns, thread size, cached tokens and compactions on the Developer page.",
        defaultValue: true, group: .developer, readBy: "Settings → Developer")

    // HeyClicky switches kept as flags because something reads them, or so a choice survives until the feature it
    // gates is built (readBy nil: the Developer page badges these "not built yet" and doesn't offer them as switches).
    // Switches a regular setting already covers (captions, job announcements, job suggestions, the meeting countdown)
    // are not flags: HeyClickyFlagKeys points their keys at that setting.
    public static let brainReadsConnectedApps = FeatureFlag(
        id: "brain.reads-connected-apps", title: "Brain reads connected apps",
        summary: "Let the brain read from connected apps (mail, calendar, documents) during a turn.",
        defaultValue: true, group: .brain, replaces: ["ClickyOneBrainReadsApps"],
        readBy: "BrainWiring.tools and always-on voice's tools (read_connected_apps)")
    public static let brainKeepsScreens = FeatureFlag(
        id: "brain.keeps-screens", title: "Keep screenshots in the thread",
        summary: "Keep earlier turns' screenshots in the brain's conversation (up to \(BrainWiring.keptScreens)) instead of pruning all but the newest few.",
        defaultValue: false, group: .brain, replaces: ["ClickyOneBrainKeepsScreensInHistory"], readBy: "BrainWiring.makeRuntime (pruning policy)")
    public static let drawingSounds = FeatureFlag(
        id: "drawing.sounds", title: "Drawing sounds",
        summary: "Play soft sounds while a drawing appears, and a pen sound under strokes.",
        defaultValue: true, group: .drawing, replaces: ["ClickyScreenDrawingSounds", "ClickyScreenDrawingPenSounds"],
        readBy: "DrawingSoundPlayer (with Settings → Voice: Play drawing sounds)")
    public static let drawingKeepsInChat = FeatureFlag(
        id: "drawing.keeps-in-chat", title: "Keep drawings in the chat",
        summary: "Save each drawing with its turn in Home's chat history.",
        defaultValue: true, group: .drawing, replaces: ["ClickyScreenDrawingKeepsDrawingsInChat"], readBy: nil)
    public static let drawingSavesLessons = FeatureFlag(
        id: "drawing.saves-lessons", title: "Save drawings as lessons",
        summary: "Keep each drawing with its narration and the screenshot it was drawn on, as a replayable lesson. Deleting the conversation removes them.",
        defaultValue: false, group: .drawing, replaces: ["ClickyScreenDrawingSavesLessons"],
        readBy: "VoiceLoopController (DrawingLessonRecorder writes <history>/lessons/<turn>/)")
    public static let agentLabelsInActivity = FeatureFlag(
        id: "agents.labels-in-activity", title: "Label jobs in the activity strip",
        summary: "Show each job's name next to its icon in the notch's activity strip.",
        defaultValue: false, group: .agents, replaces: ["ClickyShowAgentLabelsInActivityStrip"], readBy: nil)
    public static let notchSounds = FeatureFlag(
        id: "notch.sounds", title: "Notch sounds",
        summary: "Play the notch's open and close sounds.",
        defaultValue: true, group: .notch, replaces: ["ClickyNotchSoundsEnabled"], readBy: nil)
    public static let pinnedSkillInNotch = FeatureFlag(
        id: "notch.pinned-skill", title: "Pin the active skill in the notch",
        summary: "Keep the switched-on skill's badge in the notch while it is active.",
        defaultValue: false, group: .notch, replaces: ["ClickySkillPinnedNotchStateEnabled"], readBy: nil)
    public static let onboardingLanguageStep = FeatureFlag(
        id: "onboarding.language-step", title: "Language step in onboarding",
        summary: "Ask which language to speak in during the welcome tour.",
        defaultValue: false, group: .onboarding, replaces: ["ClickyOnboardingLanguageStepEnabled"], readBy: nil)

    /// Every flag, in the order the Developer page lists them.
    public static let all: [FeatureFlag] = [
        .providerRetries, .providerDiagnosis, .usageLedger, .diagnosticsUnifiedLog, .brainStats,
        .brainReadsConnectedApps, .brainKeepsScreens, .drawingSounds, .drawingKeepsInChat, .drawingSavesLessons,
        .agentLabelsInActivity, .notchSounds, .pinnedSkillInNotch, .onboardingLanguageStep, .latencyHUD,
    ]

    public static func named(_ id: String) -> FeatureFlag? { all.first { $0.id == id } }

    /// The flags Settings → Developer offers as switches: only ones something reads.
    public static var developerSwitches: [FeatureFlag] { all.filter(\.isWired) }
    /// Flags kept for features not built yet; Developer lists them badged, without a switch.
    public static var notBuilt: [FeatureFlag] { all.filter { !$0.isWired } }
}

/// The flag values the user changed, in `flags.json` beside the config. Missing entries use the flag's default. Both
/// the app and occtl read the same file.
public final class FeatureFlagStore: @unchecked Sendable {
    public let url: URL?
    private let lock = NSLock()
    private var values: [String: Bool]
    private var loadedModified: Date?

    /// - Parameter url: The file; nil keeps values in memory (fixtures, tests).
    public init(url: URL? = FeatureFlagStore.defaultURL, values: [String: Bool] = [:]) {
        self.url = url
        self.values = values
        if let url { reload(url) }
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("flags.json")
    }

    public func isOn(_ flag: FeatureFlag) -> Bool {
        lock.withLock {
            refreshIfChanged()
            return values[flag.id] ?? flag.defaultValue
        }
    }

    /// Whether the user changed the flag from its default.
    public func isOverridden(_ flag: FeatureFlag) -> Bool { lock.withLock { values[flag.id].map { $0 != flag.defaultValue } ?? false } }

    public func set(_ flag: FeatureFlag, _ value: Bool) throws {
        try lock.withLock {
            values[flag.id] = value == flag.defaultValue ? nil : value
            try save()
        }
    }

    /// Puts every flag back to its default.
    public func reset() throws {
        try lock.withLock {
            values = [:]
            try save()
        }
    }

    /// Every flag with its current value, for the diagnostics bundle and `occtl flags`.
    public func snapshot() -> [(flag: FeatureFlag, value: Bool, overridden: Bool)] {
        lock.withLock {
            refreshIfChanged()
            return FeatureFlag.all.map { flag in
                let value = values[flag.id] ?? flag.defaultValue
                return (flag, value, value != flag.defaultValue)
            }
        }
    }

    public func snapshotJSON() -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: snapshot().map { ($0.flag.id, JSONValue.bool($0.value)) }))
    }

    private func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: .atomic)
        loadedModified = Self.modified(url)
    }

    private func refreshIfChanged() {
        guard let url, Self.modified(url) != loadedModified else { return }
        reload(url)
    }

    private func reload(_ url: URL) {
        loadedModified = Self.modified(url)
        guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else { return }
        // Unknown ids (a flag that was removed) are ignored.
        values = decoded.filter { FeatureFlag.named($0.key) != nil }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// What became of one HeyClicky `Clicky*` defaults key.
public struct HeyClickyFlagKey: Sendable, Hashable, Identifiable {
    public enum Disposition: Sendable, Hashable {
        /// A flag in `FeatureFlag.all` stands in for it.
        case flag(String)
        /// A regular OpenClicky setting covers it (named for people: "Settings → Models, brain slot").
        case setting(String)
        /// Not carried over, and why.
        case dropped(String)
    }

    public let key: String
    public let disposition: Disposition
    public var id: String { key }

    public init(_ key: String, _ disposition: Disposition) {
        self.key = key
        self.disposition = disposition
    }
}

public enum HeyClickyFlagKeys {
    /// Every `Clicky*` preference or flag key found in HeyClicky 1.1.2's strings that has no reader doc
    /// (docs/parity.md §6, `shell-feature-flags`), plus the developer keys docs/re/08 §7.7 names.
    public static let all: [HeyClickyFlagKey] = {
        var keys: [HeyClickyFlagKey] = []
        for flag in FeatureFlag.all { for key in flag.replaces { keys.append(HeyClickyFlagKey(key, .flag(flag.id))) } }
        keys += [
            // Regular settings cover these.
            HeyClickyFlagKey("ClickyOneBrainModelKey", .setting("Settings → Models: the brain slot (and its reasoning effort)")),
            HeyClickyFlagKey("ClickyDeveloperChatModel", .setting("Settings → Models: the brain slot")),
            HeyClickyFlagKey("ClickyDeveloperChatModelSelection", .setting("Settings → Models: the brain slot")),
            HeyClickyFlagKey("ClickyDeveloperReasoningEffort", .setting("the brain runtime's reasoning effort (low for voice turns)")),
            HeyClickyFlagKey("ClickyAgentHarnessModel", .setting("Settings → Models: the agent slot's model and harness")),
            HeyClickyFlagKey("ClickyAgentHarnessDeviceHelperOff", .setting("the agent harness settings (tools are chosen per harness)")),
            HeyClickyFlagKey("ClickyAgentHarnessNoteToolsOff", .setting("the agent harness settings (tools are chosen per harness)")),
            HeyClickyFlagKey("ClickyMicrophonePreferences", .setting("Settings → Microphone")),
            HeyClickyFlagKey("ClickyAnnouncementPreferences", .setting("Settings → Agents: announcements")),
            HeyClickyFlagKey("ClickyJobsPreferences", .setting("Settings → Agents")),
            HeyClickyFlagKey("ClickyAppsPreferences", .setting("Settings → Connected apps")),
            HeyClickyFlagKey("ClickyPointerOnHoverModifier", .setting("Settings → Talk keys")),
            HeyClickyFlagKey("ClickyScreenDrawingSubtitles", .setting("Settings → Voice: Show the line being spoken as a caption")),
            HeyClickyFlagKey("ClickyScreenDrawingVoiceCaptions", .setting("Settings → Voice: Show the line being spoken as a caption")),
            HeyClickyFlagKey("ClickyAgentVoiceAnnouncementsEnabled", .setting("Settings → Agents: voice announcements (agent-settings.json voiceAnnouncements)")),
            HeyClickyFlagKey("ClickyAgentCursorTextAnnouncementsEnabled", .setting("Settings → Agents: text announcements (agent-settings.json textAnnouncements)")),
            HeyClickyFlagKey("ClickyProactiveAgentSuggestionsEnabled", .setting("Settings → Agents: suggest jobs (agent-settings.json suggestTasks)")),
            HeyClickyFlagKey("ClickyUpcomingMeetingsEnabled", .setting("the notch's settings: Count down to my next meeting (notch.json meetingCountdown)")),
            HeyClickyFlagKey("ClickyRoutineKeepAwake", .setting("routines (a routine run keeps the Mac awake while it runs)")),
            // Not carried over.
            HeyClickyFlagKey("ClickyLibraryModeEnabled", .dropped("Library mode's behaviour is unknown from the bundle; nothing in OpenClicky needs it")),
            HeyClickyFlagKey("ClickyStreamMode", .dropped("Stream mode's behaviour is unknown from the bundle; the notch has one mode")),
            HeyClickyFlagKey("ClickyMorningPaperEnabled", .dropped("the morning paper belongs to proactive suggestions (pro-suggestions), not built")),
            HeyClickyFlagKey("ClickyTransparentPanesEnabled", .dropped("a HeyClicky visual experiment; OpenClicky's panels follow the system material")),
            HeyClickyFlagKey("ClickyUseLegacyMenuBarPanel", .dropped("OpenClicky has only the menu-bar menu, no legacy panel")),
            HeyClickyFlagKey("ClickyPanelStylePreference", .dropped("one panel style")),
            HeyClickyFlagKey("ClickyPanelBackground", .dropped("one panel style")),
            HeyClickyFlagKey("ClickyJavaScriptJIT", .dropped("JavaScriptCore's JIT stays on (the app is signed with allow-jit); no switch needed")),
            HeyClickyFlagKey("ClickyLiveNotesEnabled", .dropped("live notes (agent-ink-notes) are not built")),
            HeyClickyFlagKey("ClickyLiveNotesStreamPatches", .dropped("live notes (agent-ink-notes) are not built")),
            HeyClickyFlagKey("ClickyLiveNotePreferences", .dropped("live notes (agent-ink-notes) are not built")),
            HeyClickyFlagKey("ClickyInkPlanOff", .dropped("ink notes are not built")),
            HeyClickyFlagKey("ClickyCatModeEnabled", .dropped("a HeyClicky character easter egg; OpenClicky has no character art")),
            HeyClickyFlagKey("ClickyPreferHostedIntroVideos", .dropped("no hosted onboarding videos")),
            HeyClickyFlagKey("ClickyForceHostedIntroVideoFailure", .dropped("debug switch for hosted videos, which OpenClicky doesn't have")),
            HeyClickyFlagKey("ClickyForceHostedOnboardingVideoFailure", .dropped("debug switch for hosted videos, which OpenClicky doesn't have")),
            HeyClickyFlagKey("ClickyForceHostedPaywallIntroVideoFailure", .dropped("no paywall")),
            HeyClickyFlagKey("ClickyHostedVideoDebug", .dropped("no hosted videos")),
            HeyClickyFlagKey("ClickyUseProductionBackendInLocalDev", .dropped("no HeyClicky backend; every provider is configured locally")),
            HeyClickyFlagKey("ClickyDeveloperModelAccess", .dropped("server-gated developer access; every OpenClicky setting is local")),
            HeyClickyFlagKey("ClickyDeveloperPreviewAccess", .dropped("server-gated developer access; every OpenClicky setting is local")),
            HeyClickyFlagKey("ClickyProactiveCapsLockDebugTriggerEnabled", .dropped("debug trigger for proactive suggestions, not built")),
            HeyClickyFlagKey("ClickyOnboardingDiscoveryChannel", .dropped("the 'where did you hear about us' answer went to HeyClicky's server")),
            HeyClickyFlagKey("ClickyOnboardingDiscoveryChannelOther", .dropped("the 'where did you hear about us' answer went to HeyClicky's server")),
            HeyClickyFlagKey("ClickyOnboardingDiscoveryChannelSynced", .dropped("the 'where did you hear about us' answer went to HeyClicky's server")),
            HeyClickyFlagKey("ClickyDiscoveryChannelPreferences", .dropped("the 'where did you hear about us' answer went to HeyClicky's server")),
            HeyClickyFlagKey("ClickyRecentlyUsedPowerUpIDs", .dropped("power-ups are HeyClicky's skill store; OpenClicky's skills library has its own state")),
            HeyClickyFlagKey("ClickyEdgeShelfFramesKey", .dropped("window frames of the edge shelf (agent-works-shelf), not built")),
        ]
        return keys
    }()
}
