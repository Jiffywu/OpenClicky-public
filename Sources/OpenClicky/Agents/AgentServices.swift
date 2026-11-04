import AppKit
import OpenClickyKit

/// The app's agent subsystem in one place: the coordinator (jobs, routines, brain tools, report batching), the HUD
/// and its panel, the result card, job-finished notifications, the browser bridge jobs reach as `openclicky_browser`,
/// and the connected apps every job is given at launch. The app creates one and calls `start()` after launch and
/// `stop()` on quit; the voice pipeline reads `tools`, `brainContext()` and `turnAssets`, receives report turns via
/// `onReportTurn`, and plays the agent sounds through `playCue`.
@MainActor
final class AgentServices {
    let coordinator: AgentCoordinator
    let hud: AgentHUDModel
    let panel: AgentHUDPanel
    let resultCard = AgentResultCardPanel()
    let notifier = AgentNotifier()
    let browserBridge = AppBrowserBridge()
    /// The current turn's screenshots (the voice loop records them), handed to `sessions_spawn` as task assets.
    let turnAssets: AgentTurnAssetsBox
    /// Called with the note that starts a report turn (`AgentReportTurn.note(for:)`) when jobs come back.
    var onReportTurn: ((String, [AgentJobReport]) -> Void)?
    /// Called when a job's card is shown (by `show_result` or a click); the card itself is `resultCard`.
    var onShowResult: ((AgentJobReport) -> Void)?
    /// Plays an interface sound: a job started, or one needs the user.
    var playCue: ((UICue) -> Void)?
    /// `open_agent_dashboard`: opens an `openclicky://` link through the app's router, or (nil) closes the dashboard.
    var openLink: ((String?) -> Bool)?

    private var soundListener: Task<Void, Never>?
    private var browserListener: Task<Void, Never>?
    /// The jobs that were already waiting on the user, so each new wait chimes once.
    private var waiting = Set<String>()
    /// Settings → Agents, read when it matters (each launch, each report, each notice).
    private let preferences: @Sendable () -> AgentPreferences
    /// For the organizer's one automatic run (brain-fast slot).
    private let config: @Sendable () -> OpenClickyConfig
    /// For the job tools' web search (the configured search service, read at each call) and the organizer's run.
    private let credentials: any CredentialStore
    private let paths: AgentPaths

    /// The brain's job tools; approving a job's `chrome_setup` request opens Settings → Browser and returns the steps.
    var tools: AgentTools {
        var tools = coordinator.tools
        tools.openBrowserSetup = { await AgentServices.openBrowserSetup() }
        return tools
    }

    @MainActor
    private static func openBrowserSetup() -> [String] {
        if let url = URL(string: BrowserSetupGuide.settingsURL) { NSWorkspace.shared.open(url) }
        guard let browser = ChromiumProfileDiscovery.installed().first?.browser else { return BrowserSetupGuide.genericSteps }
        let staged = BrowserExtensionFolder.defaultStaged
        let ready = FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path)
        let prepare = ready ? [] : ["In the Browser page that just opened, click Prepare the Extension Folder."]
        return prepare + BrowserSetupGuide.loadUnpackedSteps(browser: browser, folder: staged)
    }

    /// - Parameter config: read at every launch, so settings changes apply to the next job.
    /// - Parameter paths: where jobs live (Settings → Agents' folder, chosen at app launch).
    /// - Parameter preferences: Settings → Agents; its approval mode is read at every launch.
    /// - Parameter extraInstructions: appended to every job's instructions at launch (the active skills).
    /// - Parameter connectorRegistry: the connected apps exported to every job at launch.
    init(config: @escaping @Sendable () -> OpenClickyConfig, credentials: any CredentialStore, paths: AgentPaths = .default,
         preferences: @escaping @Sendable () -> AgentPreferences = { AgentPreferences() },
         extraInstructions: @escaping @Sendable () -> String? = { nil },
         connectorRegistry: URL = ConnectorRegistry.defaultURL) {
        let relay = Relay()
        self.preferences = preferences
        self.config = config
        self.credentials = credentials
        self.paths = paths
        let assets = AgentTurnAssetsBox()
        turnAssets = assets
        coordinator = AgentCoordinator.live(
            paths: paths, config: config, credentials: credentials, approvalMode: { preferences().approvalMode },
            extraInstructions: extraInstructions,
            connectedApps: AgentConnectedApps(registryURL: connectorRegistry,
                                              environment: ConnectorEnvironment(credentials: credentials, composioSessions: .shared)),
            catalog: { ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(config().models) },
            turnAssets: { assets.current() },
            presentResult: { report in await relay.showResult(report) },
            openFile: { url in await relay.openFile(url) }, openLink: { link in await relay.openLink(link) },
            fileDiffs: { preferences().developerFileDiffs },
            onReports: { reports in await relay.reports(reports) },
            onNotice: { notice in await relay.notice(notice) })
        hud = AgentHUDModel(manager: coordinator.manager)
        panel = AgentHUDPanel(model: hud)
        relay.owner = self
        notifier.onOpen = { [weak self] _ in self?.panel.show() }
        let manager = coordinator.manager
        resultCard.model.sendFollowUp = { jobID, text in _ = try await manager.send(to: jobID, message: text) }
        resultCard.model.onSent = { [weak self] in self?.playCue?(.agentLaunch) }
        resultCard.model.answerJob = { jobID, requestID, decision in
            _ = try await manager.answer(jobID, requestID: requestID, decision: decision, fromUser: true)
        }
        resultCard.avoid = { [weak self] in self?.panel.visibleFrame }
        browserBridge.askForChromeSetup = { [manager] jobID in await manager.requestChromeSetup(jobID: jobID) }
        browserBridge.approveChange = { [manager] request in
            guard let jobID = request.jobID else { return false }
            let decision = await manager.confirm(jobID, summary: request.summary, reason: request.details, kind: .browserAction)
            if case .approve = decision { return true }
            return false
        }
        browserBridge.onBrowserConnected = { [manager] in Task { await manager.browserConnected() } }
        let bridge = browserBridge
        Task { await manager.setBrowserConnectedCheck { if case .connected = bridge.connectionState() { true } else { false } } }
    }

    func start() {
        hud.start()
        let credentials = self.credentials
        // Jobs reach OpenClicky's web search, progress and routines tools on the browser bridge's MCP server.
        browserBridge.start(extraTools: coordinator.jobTools(lookups: {
            LookupTools(services: LookupServices.make(config: (try? ServicesConfig.load()) ?? .defaults, credentials: credentials))
        }).tools)
        listenForSounds()
        listenForBrowserTurns()
        let coordinator = coordinator
        Task { [weak self] in
            await coordinator.start()
            await self?.organizeOnceIfDue()
        }
    }

    /// The organizer's one automatic run: once enough finished one-off jobs have piled up, the brain-fast model groups
    /// the ones that belong together under kept agents. Settings → Agents can run it again.
    private func organizeOnceIfDue() async {
        let store = AgentJobStore(paths: paths)
        let catalog = ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(config().models)
        guard AgentOrganizerState.load(paths).completedAt == nil,
              let organizer = try? AgentOrganizer(store: store, factory: EngineFactory(config: config(), catalog: catalog, credentials: credentials),
                                                  manager: coordinator.manager),
              organizer.candidates().count >= AgentOrganizer.automaticMinimumJobs else { return }
        _ = try? await organizer.runOnce()
    }

    func stop() async {
        hud.stop()
        soundListener?.cancel()
        soundListener = nil
        browserListener?.cancel()
        browserListener = nil
        resultCard.hide()
        await coordinator.stop()
        browserBridge.stop()
    }

    func brainContext() async -> String? {
        let jobs = await coordinator.brainContext()
        let lines = [jobs, preferences().brainNote].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The notes for every brain turn: `[Your jobs]` (with Settings → Agents' note), `[Your routines]` and
    /// `[Your Clickys]`. The brain runtime passes each on only when its text changed.
    func brainNotes() async -> [String] {
        let clickys = await coordinator.brainNotes().filter { $0.hasPrefix("[Your Clickys]") }
        return [await brainContext(), await coordinator.routinesContext()].compactMap { $0 } + clickys
    }

    /// The brain couldn't tell the user about finished jobs: the jobs panel shows them instead.
    func reportsUndelivered() { panel.show() }

    /// The launch sound when work starts, and the needs-you chime when a running job stops to ask for a yes.
    /// (A job that comes back with a question chimes with its report turn.)
    private func listenForSounds() {
        guard soundListener == nil else { return }
        let manager = coordinator.manager
        soundListener = Task { [weak self] in
            let updates = await manager.subscribe()
            for await update in updates {
                guard let self else { return }
                switch update {
                case .launched:
                    self.playCue?(.agentLaunch)
                case .job(let record):
                    let asks = record.status == .needsYou && record.pendingRequest != nil
                    if asks, !self.waiting.contains(record.id) { self.playCue?(.agentNeedsYou) }
                    if asks { self.waiting.insert(record.id) } else { self.waiting.remove(record.id) }
                default:
                    continue
                }
            }
        }
    }

    /// Binds browser calls to job turns: a turn's start lets its calls through, its end refuses them, closes the tabs
    /// it opened and didn't keep, and keeps what it did with the browser on the job's run.
    private func listenForBrowserTurns() {
        guard browserListener == nil else { return }
        let manager = coordinator.manager
        let bridge = browserBridge
        browserListener = Task.detached {
            for await update in await manager.subscribe() {
                guard case .event(let jobID, let event) = update else { continue }
                switch event {
                case .turnStarted:
                    let record = await manager.job(jobID)
                    bridge.beginTurn(jobID: jobID, title: record?.title, folder: record?.folder)
                case .sessionStarted(let threadID):
                    bridge.noteThread(jobID: jobID, threadID: threadID)
                case .turnFinished:
                    // The turn ends here, in order with the job's events, before a next turn can start; only closing
                    // its tabs runs in the background, so it can never end the turn after it.
                    guard let tidy = bridge.endTurn(jobID: jobID) else { continue }
                    Task.detached {
                        if let usage = await tidy() { await manager.recordBrowserUsage(jobID: jobID, usage) }
                    }
                default:
                    continue
                }
            }
        }
    }

    /// The `[Browser]` note for the brain's turn notes.
    func browserNote() -> String { browserBridge.brainNote() }

    fileprivate func deliver(_ reports: [AgentJobReport]) {
        // "Tell me out loud when a job finishes" off: no report turn, unless a job needs the user's answer.
        guard preferences().voiceAnnouncements || reports.contains(where: { $0.outcome == .needsYou }) else { return }
        onReportTurn?(AgentReportTurn.note(for: reports), reports)
    }

    fileprivate func post(_ notice: AgentNotice) {
        if notice.needsAttention { panel.show() }
        guard notice.needsAttention || preferences().textAnnouncements else { return }
        Task { await notifier.post(notice) }
    }

    fileprivate func show(_ report: AgentJobReport) {
        resultCard.show(report)
        onShowResult?(report)
    }

    /// Hops coordinator callbacks onto the main actor without the coordinator holding the services strongly.
    @MainActor
    private final class Relay: Sendable {
        weak var owner: AgentServices?

        nonisolated func reports(_ reports: [AgentJobReport]) async { await MainActor.run { owner?.deliver(reports) } }
        nonisolated func notice(_ notice: AgentNotice) async { await MainActor.run { owner?.post(notice) } }
        nonisolated func showResult(_ report: AgentJobReport) async { await MainActor.run { owner?.show(report) } }
        /// `open_artifact`: the tool only passes files inside the job's or kept agent's folder.
        nonisolated func openFile(_ url: URL) async -> Bool { await MainActor.run { NSWorkspace.shared.open(url) } }
        nonisolated func openLink(_ link: String?) async -> Bool { await MainActor.run { owner?.openLink?(link) ?? false } }
    }
}
