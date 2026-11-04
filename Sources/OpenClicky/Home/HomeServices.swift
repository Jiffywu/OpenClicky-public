import AppKit
import OpenClickyKit
import SwiftUI

/// The windows beyond the overlay and what they share: the history, the skills library, typed chat, the agent jobs,
/// talk keys and voice settings, plus which Settings page to show. The app delegate owns one; Home, Settings and
/// onboarding read it from the environment.
@MainActor
@Observable
final class HomeServices {
    enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
        // Raw values match OpenClickyKit's SettingsPageID, which `openclicky://settings/<page>` links use.
        case general, models, voice, microphone, dictation, talkKeys, providers, permissions, agents, routines, memory, connectedApps
        case browser, services, skills
        case usage, developer
        var id: String { rawValue }

        init?(_ id: SettingsPageID) { self.init(rawValue: id.rawValue) }

        var title: String {
            switch self {
            case .general: "General"
            case .models: "Models"
            case .voice: "Voice"
            case .microphone: "Microphone"
            case .dictation: "Dictation"
            case .talkKeys: "Talk keys"
            case .providers: "Providers & keys"
            case .permissions: "Permissions"
            case .agents: "Agents"
            case .routines: "Routines"
            case .memory: "Memory"
            case .connectedApps: "Connected apps"
            case .browser: "Browser"
            case .services: "Services"
            case .skills: "Skills"
            case .usage: "Usage"
            case .developer: "Developer"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .models: "cpu"
            case .voice: "waveform"
            case .microphone: "mic"
            case .dictation: "text.bubble"
            case .talkKeys: "keyboard"
            case .providers: "key"
            case .permissions: "lock.shield"
            case .agents: "sparkles.rectangle.stack"
            case .routines: "clock.arrow.circlepath"
            case .memory: "brain.head.profile"
            case .connectedApps: "puzzlepiece.extension"
            case .browser: "globe"
            case .services: "magnifyingglass"
            case .skills: "sparkles"
            case .usage: "chart.bar"
            case .developer: "hammer"
            }
        }
    }

    let model: AppModel
    let history: HistoryStore
    let skills: SkillsModel
    let chat: HomeChatModel
    let drawings: HomeDrawingsModel
    /// The agent jobs list; nil in fixtures that have no agents.
    let agentHUD: AgentHUDModel?
    @ObservationIgnored let agents: AgentServices?
    let memoryStore: MemoryStore
    @ObservationIgnored let locations: Locations
    @ObservationIgnored private var connectedAppsCache: ConnectedAppsModel?
    @ObservationIgnored private var servicesCache: ServicesSettingsModel?
    let voice: VoiceSettingsModel
    let talkKeys: TalkKeysModel
    /// Settings → General's switches (login item, Dock, screen recordings, reset).
    let behavior: AppBehaviorModel
    let microphone: MicrophoneSettingsModel
    let dictation: DictationSettingsModel
    let agentSettings: AgentSettingsModel
    let routines: RoutinesSettingsModel
    let browser: BrowserSettingsModel
    @ObservationIgnored private var routerCache: AppURLRouter?
    /// Settings → Usage and Developer: the usage ledger, limits, flags, brain stats and diagnostics.
    let infra: InfraSettingsModel
    var settingsPage: SettingsPage = .models
    /// Where onboarding progress is saved; nil keeps it in memory (fixtures).
    @ObservationIgnored let onboardingURL: URL?

    @ObservationIgnored private var homeWindow: HomeWindowController?
    @ObservationIgnored private var onboardingWindow: OnboardingWindowController?
    @ObservationIgnored private var settingsWindow: SettingsWindowController?

    struct Locations {
        var history = HistoryStore.defaultDirectory
        var skills = SkillsLibrary.defaultDirectory
        var skillsState = SkillsLibrary.defaultStateURL
        var memory = MemoryStore.defaultDirectory
        var connectors = ConnectorRegistry.defaultURL
        var services = ServicesConfig.defaultURL
        var thumbnails: URL? = DrawingThumbnailer.defaultCacheDirectory
        var voiceSettings: URL? = VoiceSettings.defaultURL
        var voicePreviews: URL? = VoicePreviewRenderer.defaultCacheDirectory
        var talkKeys: URL? = TalkKeySettings.defaultURL
        var dictation: URL? = DictationSettings.defaultURL
        var onboarding: URL? = OnboardingProgress.defaultURL
        var appPreferences: URL? = AppPreferences.defaultURL
        var microphone: URL? = MicrophoneSettings.defaultURL
        var dictationVocabulary: URL? = DictationVocabularyStore.defaultURL
        var agentSettings: URL? = AgentPreferences.url()
        var agentPaths = AgentPaths.default
        var browserBridge = BrowserBridgePaths.standard
        var browserSupport = NativeHostInstaller.defaultApplicationSupport
        var usage = UsageLedger.defaultDirectory
        var flags: URL? = FeatureFlagStore.defaultURL
    }

    /// - Parameters:
    ///   - startAgents: create the agent coordinator (the live app); fixtures pass a HUD model instead.
    ///   - brain: the brain for typed chat. The app passes the voice loop's brain runtime (through `BrainRelay`), so
    ///     typed questions get its tools, drawing, lookups and jobs; nil uses `StandInTextBrain` on the brain slot
    ///     (fixtures, evidence renders).
    init(model: AppModel, locations: Locations = Locations(), startAgents: Bool = true, agentHUD: AgentHUDModel? = nil,
         brain: (any BrainTurnRunning)? = nil) {
        self.model = model
        history = HistoryStore(directory: locations.history)
        let library = SkillsLibrary(directory: locations.skills, stateURL: locations.skillsState)
        skills = SkillsModel(library: library)
        memoryStore = MemoryStore(directory: locations.memory)
        self.locations = locations
        voice = VoiceSettingsModel(model: model, settingsURL: locations.voiceSettings, previewCache: locations.voicePreviews)
        talkKeys = TalkKeysModel(model: model, url: locations.talkKeys, dictationURL: locations.dictation)
        onboardingURL = locations.onboarding
        behavior = AppBehaviorModel(url: locations.appPreferences,
                                    loginItem: startAgents ? MainAppLoginItem() : FixedLoginItem(status: .requiresApproval),
                                    location: startAgents ? InstallLocation.classify(bundleURL: Bundle.main.bundleURL)
                                                          : InstallLocation(kind: .applications, bundlePath: "/Applications/OpenClicky.app"),
                                    capturePolicy: model.capturePolicy, credentials: model.credentials, isLive: startAgents)
        microphone = MicrophoneSettingsModel(url: locations.microphone, model: model)
        // The running dictation and this page share one vocabulary store, so an added word counts from the next press.
        let vocabularyStore = locations.dictationVocabulary.map {
            $0 == DictationVocabularyStore.defaultURL ? DictationCoordinator.vocabulary : DictationVocabularyStore(url: $0)
        }
        dictation = DictationSettingsModel(url: locations.dictation, store: vocabularyStore, model: model)
        let agentSettingsModel = AgentSettingsModel(url: locations.agentSettings, basePaths: locations.agentPaths, model: model)
        agentSettings = agentSettingsModel
        browser = BrowserSettingsModel(paths: locations.browserBridge, applicationSupport: locations.browserSupport)
        infra = InfraSettingsModel(model: model, ledger: UsageLedger(directory: locations.usage), flags: FeatureFlagStore(url: locations.flags))
        if startAgents, let live = ProviderResilience.installed?.recorder as? UsageLedger { infra.follow(live) }
        if startAgents {
            let credentials = model.credentials
            let memory = memoryStore
            let preferencesURL = locations.agentSettings ?? AgentPreferences.url(in: locations.agentPaths)
            // Jobs read the config at every launch; the app saves every change, so the file is current. The same goes
            // for Settings → Agents (approval mode, announcements); the job folder applies from the next launch.
            let services = AgentServices(config: { (try? OpenClickyConfig.load()) ?? .heyClickyLike }, credentials: credentials,
                                         paths: agentSettingsModel.activePaths,
                                         preferences: { AgentPreferences.load(from: preferencesURL) },
                                         extraInstructions: {
                                             [library.skillsAgentInstructions(), MemoryAgentBrief.section(store: memory)]
                                                 .filter { !$0.isEmpty }.joined(separator: "\n\n")
                                         }, connectorRegistry: locations.connectors)
            agents = services
            infra.limitAlertHandlers.append { [notifier = services.notifier] alert in Task { await notifier.post(alert) } }
            self.agentHUD = services.hud
            routines = RoutinesSettingsModel(scheduler: services.coordinator.routines, manager: services.coordinator.manager)
        } else {
            agents = nil
            self.agentHUD = agentHUD
            routines = RoutinesSettingsModel(scheduler: nil, manager: nil)
        }
        let memory = memoryStore
        chat = HomeChatModel(history: history, model: model, brain: brain, extraSections: {
            var sections = [library.skillsPromptSection()]
            if let snapshot = try? memory.snapshot() { sections.append(MemoryPromptBuilder().build(from: snapshot, query: "").stableText) }
            return sections
        })
        drawings = HomeDrawingsModel(history: history, cacheDirectory: locations.thumbnails)
    }

    /// `openclicky://` and in-app `openclicky:` links.
    var router: AppURLRouter {
        if let routerCache { return routerCache }
        let made = AppURLRouter(home: self)
        routerCache = made
        return made
    }

    /// Settings → Connected apps. Made on first use: building it reads the Keychain for each connector.
    var connectedApps: ConnectedAppsModel {
        if let connectedAppsCache { return connectedAppsCache }
        let made = ConnectedAppsModel(credentials: model.credentials, registryURL: locations.connectors)
        connectedAppsCache = made
        return made
    }

    /// Settings → Services, made on first use for the same reason.
    var services: ServicesSettingsModel {
        if let servicesCache { return servicesCache }
        let made = ServicesSettingsModel(credentials: model.credentials, url: locations.services,
                                         brainDialect: model.config.slots[.brain].flatMap { model.config.provider($0.provider)?.dialect })
        servicesCache = made
        return made
    }

    func start() {
        agents?.useSkills(skills, connectors: locations.connectors)
        agents?.start()
        agents?.panel.openURL = router.openURLAction
        agents?.openLink = { [weak self] link in self?.openAgentLink(link) ?? false }
        agents?.resultCard.openURL = router.openURLAction
        talkKeys.apply()
        chat.startFollowingHistory()
    }

    func stop() async {
        await agents?.stop()
    }

    // MARK: Windows

    func openHome(section: HomeSection? = nil) {
        if homeWindow == nil { homeWindow = HomeWindowController(services: self) }
        if let section { chat.section = section }
        homeWindow?.show()
    }

    /// `open_agent_dashboard`: a link goes through the router (Home → Agents, or a job); nil closes the jobs panel and
    /// hides Home when it shows Agents.
    func openAgentLink(_ link: String?) -> Bool {
        guard let link else {
            agents?.panel.hide()
            if chat.section == .agents { homeWindow?.hide() }
            return true
        }
        guard let url = URL(string: link) else { return false }
        return router.open(url, source: "open_agent_dashboard")
    }

    var needsOnboarding: Bool {
        guard let onboardingURL else { return false }
        return OnboardingProgress.needsOnboarding(at: onboardingURL)
    }

    func openOnboarding(restart: Bool = false) {
        if onboardingWindow == nil { onboardingWindow = OnboardingWindowController(services: self) }
        onboardingWindow?.show(restart: restart)
    }

    /// Opens the Settings window on one page.
    func openSettings(_ page: SettingsPage) {
        settingsPage = page
        if settingsWindow == nil { settingsWindow = SettingsWindowController(services: self) }
        settingsWindow?.show()
    }
}
