import AppKit
import OpenClickyKit
import os
import SwiftUI

/// The interactive notch in the running app: the panels, the presenter, and the live events from services that
/// already exist — the calendar's next meeting, background jobs, a document macOS wouldn't let OpenClicky read,
/// dictation left on the clipboard, and a spoken reply copied because the Mac's sound is off. Effects (open a link,
/// show a job, send a typed question, turn a notice off) are carried out here.
///
/// With Settings' "interactive notch" off it does nothing and the overlay keeps its click-through pill.
@MainActor
final class NotchController {
    let model: NotchModel
    private let app: AppModel
    private let home: HomeServices
    private weak var voiceLoop: VoiceLoopController?
    private var windows: NotchWindowManager?
    private let folderNotice: FolderAccessNotice
    private var meetingMonitor: MeetingCountdownMonitor?
    /// Countdowns the user closed, handed to a monitor restarted for a new lead time so they stay closed.
    private var dismissedMeetings: Set<String> = []
    private var meetingTask: Task<Void, Never>?
    private var agentTask: Task<Void, Never>?
    /// Live events from features that already exist: provider failures, the browser extension, take-over drives,
    /// always-on voice and spending limits.
    private var providerEvents = ProviderLiveEvents()
    private var providerFeed: UUID?
    private var browserEvents = BrowserLiveEvents()
    private var takeoverDriving = false
    private var usageHooked = false
    private var windowCloseObserver: NSObjectProtocol?
    private var onboardingDeferred = false
    private let log = Logger(subsystem: "app.openclicky", category: "notch")
    private(set) var isRunning = false

    init(app: AppModel, home: HomeServices, voiceLoop: VoiceLoopController?, settingsURL: URL? = NotchSettings.defaultURL,
         folderNotice: FolderAccessNotice = FolderAccessNotice()) {
        self.app = app
        self.home = home
        self.voiceLoop = voiceLoop
        self.folderNotice = folderNotice
        model = NotchModel(settings: settingsURL.map(NotchSettings.load(from:)) ?? NotchSettings(), settingsURL: settingsURL)
    }

    func start() {
        guard model.settings.interactive, !isRunning else { return }
        isRunning = true
        app.notchPanelActive = true
        let windows = NotchWindowManager(model: model) { [unowned self] id in
            AnyView(NotchRootView(display: id, controller: self)
                .environment(self.model)
                .environment(self.app)
                .environment(self.home))
        }
        windows.capturePolicy = voiceLoop?.capturePolicy
        windows.onOverlayYield = { [weak self] hidden in
            self?.app.setOverlayHidden(hidden)
            self?.log.info("overlays \(hidden ? "step aside" : "back", privacy: .public)")
        }
        windows.onProbe = { [weak self] reasons, fullscreen in
            guard !reasons.isEmpty || !fullscreen.isEmpty else { return }
            self?.log.debug("notch yields to \(reasons.map(\.rawValue).sorted().joined(separator: ","), privacy: .public) fullscreen \(fullscreen.count)")
        }
        self.windows = windows
        model.onEffect = { [weak self] effect in self?.perform(effect) }
        model.onEscapeInterestChange = { [weak self] in
            guard let self else { return }
            self.voiceLoop?.refreshEscapeGate()
            if !self.model.isExpanded { self.windows?.releaseKeyFocus() }
        }
        windows.start()
        for panel in windows.panels.values {
            log.notice("notch panel \(panel.windowNumber, privacy: .public) at \(NSStringFromRect(panel.frame), privacy: .public), level \(panel.level.rawValue, privacy: .public), visible \(panel.isVisible, privacy: .public)")
        }
        hookVoiceLoop()
        observeActivity()
        startMeetingCountdown()
        startJobEvents()
        watchOnboarding()
        startServiceEvents()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Fold first, so the voice loop's Escape gate stops claiming Escape for a notch that is gone.
        if model.isExpanded { model.send(.escape) }
        windows?.stop()
        windows = nil
        // Nil the tasks too, so a later start() runs the sources again.
        meetingTask?.cancel()
        meetingTask = nil
        agentTask?.cancel()
        agentTask = nil
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        stopServiceEvents()
        activity.cancel()
        for item in voiceLoop?.audio.quiet.held ?? [] where item.id.hasPrefix("notch:") {
            voiceLoop?.audio.withdraw(item.id)
        }
        unhookVoiceLoop()
        app.notchPanelActive = false
        app.setOverlayHidden(false)
    }

    var windowNumbers: [Int] { windows?.windowNumbers ?? [] }
    var appModel: AppModel { app }
    var homeServices: HomeServices { home }

    /// Settings changed from the notch's Settings tab.
    func update(_ settings: NotchSettings) {
        let before = model.settings
        model.update(settings)
        if settings.meetingCountdown != before.meetingCountdown || settings.meetingLeadMinutes != before.meetingLeadMinutes {
            meetingTask?.cancel()
            meetingTask = nil
            // The restarted monitor posts the countdown again if it still applies (a shorter lead can rule it out).
            if let meeting = model.meeting { withdraw(meeting.id) }
            startMeetingCountdown()
        }
        if settings.jobEvents != before.jobEvents {
            agentTask?.cancel()
            agentTask = nil
            startJobEvents()
        }
        if settings.interactive != before.interactive {
            if settings.interactive { start() } else { stop() }
        }
    }

    /// The text key's or the menu's "type a question" in the notch.
    func openChat() { model.send(.openChat(display: NSScreen.main?.displayID)) }

    // MARK: Effects

    private func perform(_ effect: NotchEffect) {
        switch effect {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
        case .openJob:
            home.agents?.panel.show()
        case .revealFile(let file):
            if file.hasPrefix("http://") || file.hasPrefix("https://"), let url = URL(string: file) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
            }
        case .suppress(.folderAccessNotice):
            folderNotice.suppress()
        case .submit(let text):
            voiceLoop?.ask(text)
        case .focusComposer:
            windows?.focusComposer()
        case .openHome:
            home.openHome()
        case .openSettings:
            home.openSettings(.general)
        case .openOnboarding:
            home.openOnboarding()
        case .openSettingsPage(let page):
            home.openSettings(HomeServices.SettingsPage(rawValue: page) ?? .general)
        case .stop(let target):
            stop(target)
        case .shown(let id):
            // The kind is public; the rest of the id can be a document path or a job's id, so it stays private.
            let kind = id.split(separator: ":").first.map(String.init) ?? id
            log.info("live event shown: \(kind, privacy: .public) \(id, privacy: .private)")
        case .dismissed(let id):
            guard id.hasPrefix("meeting:") else { break }
            dismissedMeetings.insert(id)
            if let monitor = meetingMonitor { Task { await monitor.dismiss(id) } }
        }
    }

    /// The buttons inside the open notch that aren't presenter inputs.
    func openHome() { model.send(.clickOutside); home.openHome() }
    func openSettings() { model.send(.clickOutside); home.openSettings(.general) }
    func openOnboarding() {
        model.send(.onboarding(pinned: false))
        home.openOnboarding()
    }
    func deferOnboarding() {
        onboardingDeferred = true
        model.send(.onboarding(pinned: false))
    }

    // MARK: Sources

    private func hookVoiceLoop() {
        guard let voiceLoop else { return }
        voiceLoop.notchWantsEscape = { [weak self] in self?.model.wantsEscape ?? false }
        voiceLoop.notchEscape = { [weak self] in
            guard let self, self.model.wantsEscape else { return false }
            self.model.send(.escape)
            return true
        }
        voiceLoop.onLook = { [weak self] look in self?.looked(look) }
        voiceLoop.onTurnRecord = { [weak self] record in self?.turnFinished(record) }
        voiceLoop.onDictationFinished = { [weak self] report in
            guard let self, let event = DictationLiveEvents.event(for: report, now: Date()) else { return }
            self.model.send(.post(event))
        }
    }

    private func unhookVoiceLoop() {
        guard let voiceLoop else { return }
        voiceLoop.notchWantsEscape = { false }
        voiceLoop.notchEscape = { false }
        voiceLoop.onLook = nil
        voiceLoop.onTurnRecord = nil
        voiceLoop.onDictationFinished = nil
        voiceLoop.refreshEscapeGate()
    }

    /// A turn's look: macOS refused the open document.
    private func looked(_ look: TurnLook) {
        guard let event = folderNotice.event(for: look.context.document, now: Date()) else { return }
        model.send(.post(event))
    }

    /// A finished turn: when nobody could hear the answer, it goes on the clipboard and the notch says so.
    private func turnFinished(_ record: TurnRecord) {
        guard record.unheardReply == nil, model.settings.copiesReplyWhenMuted, let lines = record.history?.spokenLines, !lines.isEmpty else { return }
        let speaksTyped = voiceLoop?.settings.speaksTypedAnswers ?? false
        guard let text = MutedReplyPolicy.textToCopy(kind: record.kind, spokenLines: lines, speaksTypedAnswers: speaksTyped,
                                                     output: OutputSoundProbe.defaultOutput(), outcome: record.outcome) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        model.send(.post(MutedReplyPolicy.event(copied: text, lineCount: lines.count, now: Date())))
    }

    /// The pill (a voice turn, a notice, always-on voice at work) takes the notch while it shows. Always-on waiting
    /// for the user is a live event with its own Stop instead, so other events can still show. `takeoverChanged`
    /// refreshes it by hand, which replaces the pending observation rather than adding another one per take-over step.
    private lazy var activity = ObservationLoop<(busy: Bool, target: NotchStopTarget?, listening: NotchLiveEvent?)>(
        read: { [unowned self] in
            let app = self.app
            return (NotchController.showsActivity(turn: app.turn, alwaysOn: app.alwaysOn),
                    NotchStopTarget.current(takeoverDriving: self.takeoverDriving, answering: app.turn.phase != .idle,
                                            drawing: app.drawings.hasVisibleDrawing, alwaysOn: app.alwaysOn.isActive),
                    AlwaysOnLiveEvents.event(for: app.alwaysOn, hint: NotchController.alwaysOnHint(app.alwaysOnKeyPhrase), now: Date()))
        },
        apply: { [unowned self] state in
            guard self.isRunning else { return }
            let model = self.model
            if state.busy != model.presenter.activityBusy { model.send(.activity(state.busy)) }
            if state.target != model.presenter.stopTarget { model.send(.stoppable(state.target)) }
            let shown = model.presenter.pendingEvents.contains { $0.id == AlwaysOnLiveEvents.eventID }
            if let listening = state.listening, !shown {
                model.send(.post(listening))
            } else if state.listening == nil, shown {
                model.send(.withdraw(AlwaysOnLiveEvents.eventID))
            }
        })

    private func observeActivity() {
        guard isRunning else { return }
        activity.refresh()
    }

    static func showsActivity(turn: TurnDisplay, alwaysOn: AlwaysOnDisplay) -> Bool {
        if turn.phase != .idle || turn.notice != nil { return true }
        return alwaysOn.notch(stopHint: nil) != nil && !alwaysOn.isIdleListening
    }

    static func alwaysOnHint(_ keyPhrase: String?) -> String? {
        guard let keyPhrase = keyPhrase?.trimmingCharacters(in: .whitespaces), !keyPhrase.isEmpty else { return nil }
        return "\(keyPhrase) ends it"
    }

    // MARK: Stop

    /// The pill's or a card's Stop, through the paths the menu, Escape and the take-over overlay use.
    private func stop(_ target: NotchStopTarget) {
        log.info("notch stop: \(target.rawValue, privacy: .public)")
        switch target {
        case .voice, .drawing:
            voiceLoop?.stopTurn()
        case .takeover:
            voiceLoop?.takeover.controller.emergencyStop(.userPressedEscape)
        case .alwaysOn:
            if app.alwaysOn.isActive { voiceLoop?.toggleAlwaysOn() }
        }
    }

    // MARK: Service events

    private func startServiceEvents() {
        if providerFeed == nil {
            providerFeed = ProviderUnavailableFeed.subscribe { [weak self] error in
                Task { @MainActor in self?.providerFailed(error) }
            }
        }
        if !usageHooked {
            usageHooked = true
            home.infra.limitAlertHandlers.append { [weak self] alert in
                guard let self, self.isRunning else { return }
                self.model.send(.post(UsageLiveEvents.event(for: alert, now: Date())))
            }
        }
        home.agents?.browserBridge.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.browserPeersChanged(peers) }
        }
        voiceLoop?.takeover.presenter.onDriveChange = { [weak self] phase, detail, dryRun in
            self?.takeoverChanged(phase, detail: detail, dryRun: dryRun)
        }
    }

    private func stopServiceEvents() {
        if let providerFeed { ProviderUnavailableFeed.unsubscribe(providerFeed) }
        providerFeed = nil
        home.agents?.browserBridge.onPeersChanged = nil
        voiceLoop?.takeover.presenter.onDriveChange = nil
        takeoverDriving = false
    }

    private func providerFailed(_ error: ProviderUnavailableError) {
        guard isRunning, let event = providerEvents.event(for: error, now: Date()) else { return }
        model.send(.post(event))
    }

    private func browserPeersChanged(_ peers: [BrowserPeer]) {
        guard isRunning else { return }
        for event in browserEvents.changes(peers: peers, now: Date()) { model.send(.post(event)) }
    }

    private func takeoverChanged(_ phase: TakeoverPhase, detail: String?, dryRun: Bool) {
        guard isRunning else { return }
        if let event = TakeoverLiveEvents.event(for: phase, detail: detail, dryRun: dryRun, now: Date()) {
            takeoverDriving = true
            model.send(.post(event))
        } else {
            takeoverDriving = false
            model.send(.withdraw(TakeoverLiveEvents.eventID))
        }
        observeActivity()
    }

    private func startMeetingCountdown() {
        guard model.settings.meetingCountdown, meetingTask == nil else { return }
        let monitor = MeetingCountdownMonitor(service: CalendarService(store: EventKitCalendarStore(canAskForAccess: false)),
                                              policy: MeetingCountdownPolicy(leadMinutes: model.settings.meetingLeadMinutes),
                                              dismissed: dismissedMeetings)
        meetingMonitor = monitor
        meetingTask = Task { [weak self] in
            await monitor.run(interval: 30) { [weak self] update in await self?.apply(update) }
        }
    }

    private func apply(_ update: MeetingCountdownMonitor.Update) {
        switch update {
        case .show(let event, let replacing):
            if let replacing { withdraw(replacing) }
            postProactive(event)
        case .withdraw(let id):
            withdraw(id)
        case .nothing:
            break
        }
    }

    private func startJobEvents() {
        guard model.settings.jobEvents, agentTask == nil, let manager = home.agents?.coordinator.manager else { return }
        agentTask = Task { [weak self] in
            // Subscribe before listing, so nothing in between is missed; jobs that already exist aren't announced.
            let updates = await manager.subscribe()
            var mapper = AgentLiveEvents()
            mapper.seed(await manager.jobs())
            for await update in updates {
                let changes = mapper.changes(for: update, now: Date())
                guard !changes.post.isEmpty || !changes.withdraw.isEmpty, let self else { continue }
                for id in changes.withdraw { self.withdraw(id) }
                for event in changes.post { self.postProactive(event) }
            }
        }
    }

    private func postProactive(_ event: NotchLiveEvent) {
        guard let kind = event.proactiveKind else {
            model.send(.post(event))
            return
        }
        let expires: Date? = if case .at(let date) = event.expiry { date } else { nil }
        guard let audio = voiceLoop?.audio else { model.send(.post(event)); return }
        audio.offer(ProactiveItem(id: "notch:" + event.id, kind: kind, title: event.title, createdAt: event.postedAt, expiresAt: expires)) { [weak self] in
            guard let self else { return }
            if self.isRunning { self.model.send(.post(event)) }
        }
    }

    private func withdraw(_ id: String) {
        voiceLoop?.audio.withdraw("notch:" + id)
        model.send(.withdraw(id))
    }

    /// Setup closed before it was finished: the notch pins a reminder until the user continues or says later.
    private func watchOnboarding() {
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.isRunning, !self.onboardingDeferred else { return }
                let pinned = self.home.needsOnboarding
                if pinned != self.model.presenter.onboardingPinned { self.model.send(.onboarding(pinned: pinned)) }
            }
        }
    }
}
