import AppKit
import OpenClickyKit
import os
import os.lock

/// The voice loop in the app: the talk-key tap, the turn orchestrator and everything it drives (the mic, the stt slot,
/// screen capture and context, the brain runtime, the voice and the overlay drawings), dictation's chord, the typed
/// question panel, cues, job report turns and the history. It also joins in draw-to-ask and guided walkthroughs (the
/// overlay's `PointingOverlayModel` is the orchestrator's guide), take-over (its tools, the user's spoken yes, and
/// its report as the next turn's note) and the drawings' photo and place cards.
///
/// Triple-tap Control toggles always-on voice (`AlwaysOnVoiceLoop`, docs/realtime-voice.md): a realtime session on the
/// realtime-voice slot on the same mic and speech player, with the echo gate between them. While it runs the
/// orchestrator holds its turns; the talk keys and Escape interrupt its reply, and typed questions go into it.
///
/// Engines are built at the first press, typed question or job report (not at launch, so starting the app reads no
/// key), and rebuilt between turns when the slots change.
@MainActor
@Observable
final class VoiceLoopController {
    private(set) var settings: VoiceLoopSettings
    private(set) var lastTimings: TurnTimings?
    private(set) var keyMode: TalkKeyMonitor.Mode = .off
    private(set) var engineProblem: String?

    @ObservationIgnored let orchestrator: TurnOrchestrator
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let home: HomeServices
    @ObservationIgnored private let screenLook: ScreenLookService
    @ObservationIgnored private let screen: ScreenLookAdapter
    /// The turn's screen and launch assets. BrainWiring supplies the jobs note on every surface.
    @ObservationIgnored private let turnScreen: any TurnScreenLooking
    /// One mic for the voice loop's presses and always-on voice. It captures on its own engine, or on the shared
    /// echo-cancelling one while always-on runs on speakers (`audio.router`).
    @ObservationIgnored private let microphone: SharedMicrophone
    /// Mic trouble, muted output, echo cancellation and quiet contexts (docs/audio-robustness.md).
    @ObservationIgnored let audio: AudioRobustness
    /// Opens onboarding once the quiet (a call, a Focus) is over.
    @ObservationIgnored private var heldReportNeedsYou = false
    @ObservationIgnored private var heldOnboarding: (() -> Void)?
    @ObservationIgnored private let cues = AppCues()
    @ObservationIgnored private let player = SpeechPlayer(sampleRate: 24_000)
    @ObservationIgnored private let typedPanel: TypedTurnPanel
    @ObservationIgnored private var dictation: DictationCoordinator?
    @ObservationIgnored private var engineKey: String?
    @ObservationIgnored private var brainIsUnavailable = true
    @ObservationIgnored private let settingsURL: URL?
    @ObservationIgnored private let log = Logger(subsystem: "app.openclicky", category: "voice-loop")
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Take-over: the consent card, the drive and the brain's three tools (docs/takeover.md).
    @ObservationIgnored let takeover: TakeoverServices
    /// What take-over drives read off the main actor: the config they plan with, and whether they may post input.
    @ObservationIgnored private let takeoverConfig: OSAllocatedUnfairLock<OpenClickyConfig>
    @ObservationIgnored private let takeoverPostsInput: OSAllocatedUnfairLock<Bool>
    @ObservationIgnored private var offerExpiry: Task<Void, Never>?
    /// Always-on voice: triple-tap Control.
    @ObservationIgnored private(set) var alwaysOn: AlwaysOnVoiceLoop!
    /// Plays what the brain draws when always-on hands it a question.
    @ObservationIgnored private var brainDrawing: RealtimeBrainDrawing
    /// The lookups the brain's tools use (built with the engines), shared with always-on's tools.
    @ObservationIgnored private var lookups: LookupServices?
    /// Watches the default output while always-on runs (it stops if sound moves to the speakers).
    @ObservationIgnored private var outputWatcher: AudioDeviceWatcher?
    /// The one brain Home's typed chat and always-on reach too: set to the runtime built here (docs/home.md).
    @ObservationIgnored let brainRelay: BrainRelay
    /// The connected apps the brain reads (built with the engines; rebuilt when connectors change).
    @ObservationIgnored private var connectedApps: ConnectedAppsWiring?
    /// Records always-on's exchanges into the history and writes its memory notes when a run ends.
    @ObservationIgnored private var alwaysOnRecorder: AlwaysOnRecorder?
    /// The config always-on sessions open with: a voice change updates it, and the next session speaks with it.
    @ObservationIgnored private let alwaysOnConfig = OSAllocatedUnfairLock<OpenClickyConfig?>(initialState: nil)
    /// The voice settings the running always-on session opened with (realtime slot, voice slot's voice).
    @ObservationIgnored private var alwaysOnVoiceKey: String?
    @ObservationIgnored private var watchingVoiceSettings = false
    /// Settings → Developer → Floating latency stats.
    @ObservationIgnored let latencyHUD = LatencyStatsPanelController()
    /// Job started / came back records for the history, and how-tos learned from finished jobs.
    @ObservationIgnored private var handOffs: Task<Void, Never>?
    /// The talk keys' stt: one client kept across presses with a warm connection, fallbacks and per-press timings.
    @ObservationIgnored private var ears: VoiceEars?
    /// Dictation's own ears (its own warm connection and last-use time), rebuilt when the stt slot changes.
    @ObservationIgnored private var dictationEars: (key: String, ears: VoiceEars)?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    // MARK: Notch hooks (set by `NotchController`)

    /// Each turn's screen look, each finished turn and each finished dictation, for the notch's live events.
    @ObservationIgnored var onLook: ((TurnLook) -> Void)? {
        didSet { screenLook.onLook = onLook }
    }
    @ObservationIgnored var onTurnRecord: ((TurnRecord) -> Void)?
    @ObservationIgnored var onDictationFinished: ((DictationSessionReport) -> Void)? {
        didSet { dictation?.onSessionFinished = onDictationFinished }
    }
    /// The open notch takes Escape first (it folds).
    @ObservationIgnored var notchWantsEscape: () -> Bool = { false }
    @ObservationIgnored var notchEscape: () -> Bool = { false }

    init(model: AppModel, home: HomeServices, brain: BrainRelay = BrainRelay(), settingsURL: URL? = VoiceLoopSettings.defaultURL) {
        self.model = model
        self.home = home
        brainRelay = brain
        self.settingsURL = settingsURL
        var loaded = settingsURL.map(VoiceLoopSettings.load(from:)) ?? VoiceLoopSettings()
        loaded.microphoneUID = home.microphone.settings.deviceUID
        settings = loaded
        let audio = AudioRobustness()
        self.audio = audio
        let router = audio.router
        microphone = SharedMicrophone(device: CaptureMicrophoneDevice(deviceUID: loaded.microphoneUID, host: { router.captureHost }))
        typedPanel = TypedTurnPanel(model: model)
        let typedPanel = self.typedPanel
        screenLook = ScreenLookService(ownWindowNumbers: { [weak model, weak audio] in
            (model?.overlayWindowNumbers ?? []) + typedPanel.windowNumbers + (audio?.windowNumbers ?? [])
        }, capturePolicy: model.capturePolicy)
        screen = ScreenLookAdapter(service: screenLook)
        if let agents = home.agents {
            turnScreen = AgentContextScreen(base: screen, assets: agents.turnAssets, context: nil)
        } else {
            turnScreen = screen
        }
        brainDrawing = RealtimeBrainDrawing(surfaces: model.drawings)
        let placeholder = TurnOrchestrator.Services(microphone: nil, speechToText: { throw EngineFactoryError.slotEmpty(.stt) },
                                                    screen: turnScreen, brain: UnavailableBrain(reason: "not built yet"), narrator: nil,
                                                    drawings: model.drawings, guidance: model.pointing)
        orchestrator = TurnOrchestrator(services: placeholder)
        let takeoverConfig = OSAllocatedUnfairLock(initialState: model.config)
        // Drives are rehearsals (nothing is posted) unless the user turned real input on in Settings → Voice.
        let takeoverPostsInput = OSAllocatedUnfairLock(initialState: loaded.takeoverPostsInput)
        self.takeoverConfig = takeoverConfig
        self.takeoverPostsInput = takeoverPostsInput
        let frontApps = screenLook.frontApps
        takeover = TakeoverServices(config: { takeoverConfig.withLock { $0 } }, credentials: model.credentials, frontApp: frontApps,
                                    dryRun: { !takeoverPostsInput.withLock { $0 } })
        alwaysOn = AlwaysOnVoiceLoop(orchestrator: orchestrator) { [unowned self] in try self.makeAlwaysOnController() }
    }

    // MARK: Lifecycle

    func start() {
        let monitor = model.talkKeyMonitor
        monitor.keys = home.talkKeys.settings
        monitor.onGesture = { [weak self] gesture in self?.handle(gesture) }
        monitor.voicePressIsOpen = { [weak self] in self?.orchestrator.isListening ?? false }
        monitor.onModeChange = { [weak self] mode in self?.keyMode = mode }
        monitor.start()
        keyMode = monitor.mode

        orchestrator.onDisplayChange = { [weak self] display in
            self?.model.turn = display
            self?.updateEscapeGate()
        }
        orchestrator.onTurnFinished = { [weak self] record in self?.finished(record) }
        orchestrator.onLog = { [weak self] text in self?.log.info("\(text, privacy: .public)") }
        // While a take-over card is up, the user's words may be their answer to it (a clear yes or no).
        orchestrator.onUserWords = { [weak self] words in await self?.answerTakeoverOffer(words) }
        takeover.onReport = { [weak self] report in
            // The brain hears how the drive went at the start of its next turn.
            self?.orchestrator.noteForNextTurn(report.appNote)
            self?.log.info("take-over ended: \(report.outcome.rawValue, privacy: .public)")
        }
        // Escape is swallowed while a walkthrough runs (it stops it), and only then.
        model.pointing.onWalkthroughChange = { [weak self] in self?.updateEscapeGate() }
        model.micLevel = { [microphone] in microphone.level }
        model.speechPosition = { [player] in player.position() }
        alwaysOn.willStart = { [weak self] in self?.alwaysOnWillStart() }
        alwaysOn.onDisplayChange = { [weak self] display in
            self?.model.alwaysOn = display
            self?.updateEscapeGate()
        }
        alwaysOn.onStateChange = { [weak self] state in self?.alwaysOnStateChanged(state) }
        alwaysOn.onLog = { [weak self] text in self?.log.info("\(text, privacy: .public)") }
        // A reply into a muted Mac is copied and the Unmute / Set volume card shows, as for push-to-talk.
        alwaysOn.mutedGuard = audio.mutedGuard
        // The panel gets its capture role as soon as it exists (the registrar's sweep would find it a moment later).
        latencyHUD.register = { [weak model] window in
            let traits = WindowTraits(className: String(describing: type(of: window)), isTitled: window.styleMask.contains(.titled),
                                      ignoresMouseEvents: window.ignoresMouseEvents)
            if let role = WindowCaptureRoles.role(for: traits) { model?.capturePolicy.register(window, role: role) }
        }
        home.infra.onFlagChange = { [weak self] flag in
            if flag == .latencyHUD { self?.refreshLatencyHUD() }
        }
        refreshLatencyHUD()
        alwaysOn.onUnheardReply = { [weak self] notice in self?.audio.show(notice) }
        model.drawings.onAsk = { [weak self] question in self?.submitTyped(question) }
        // A drawing's actions: type where the caret is (or copy), copy, open a page, hand a task to an agent, a sound.
        let drawingSounds = DrawingSoundPlayer()
        drawingSounds.flags = FeatureFlagStore()
        model.drawings.sounds = drawingSounds
        model.drawings.actions = DrawingActionPerformer(
            type: { words in
                let report = await TextInserter(system: SystemTextInsertion()).insert(words, into: nil)
                if case .inserted = report.outcome { return true }
                return false
            },
            playSound: { name in
                drawingSounds.schedule(DrawingSoundRecipe(at: 0, duration: 0, texture: nil, accents: [.init(id: name, at: 0)]), now: 0)
            },
            handOff: { [weak self] task, label in
                guard let agents = self?.home.agents else { return false }
                var args: [String: JSONValue] = ["task": .string(task)]
                if let label { args["title"] = .string(label) }
                let result = await agents.tools.callJSON(name: "sessions_spawn", arguments: JSONValue.object(args).jsonString())
                return result["status"]?.stringValue != "error"
            })
        // What a drawing noted about the user is kept like a fact the brain saved.
        model.drawings.onNote = { [weak self] kind, text in
            guard kind == "noted", let store = self?.home.memoryStore else { return }
            _ = try? store.save(text, kind: .fact, source: .voice)
        }
        model.drawings.onProblem = { [weak self] text in self?.log.error("\(text, privacy: .public)") }
        model.drawings.onLog = { [weak self] text in self?.log.info("\(text, privacy: .public)") }
        typedPanel.onSubmit = { [weak self] text in self?.submitTyped(text) }
        typedPanel.onVisibilityChange = { [weak self] _ in self?.updateEscapeGate() }
        home.agents?.panel.onVisibilityChange = { [weak self] in self?.updateEscapeGate() }

        let dictation = DictationCoordinator(engines: dictationEngines(), ownsKeys: false)
        dictation.onSessionFinished = onDictationFinished
        dictation.start()
        self.dictation = dictation

        // The ears' warm connection comes back after sleep (while they are in use).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The cue output was stopped while asleep: warm it again if cues were in use lately.
                self?.cues.rewarmAfterWake()
                let all = [self?.ears, self?.dictationEars?.ears].compactMap { $0 }
                for ears in all { Task { await ears.refresh(.wake) } }
            }
        }
        home.agents?.onReportTurn = { [weak self] note, reports in
            guard let self else { return }
            // During a call or a Focus the report waits (routine runs finish quietly); it is told once that's over.
            let routine = !reports.isEmpty && reports.allSatisfy { $0.routineID != nil }
            let item = ProactiveItem(kind: routine ? .routineNotice : .jobReport, title: reports.map(\.title).joined(separator: ", "),
                                     payload: note, createdAt: Date())
            let needsYou = reports.contains { $0.outcome == .needsYou }
            guard self.audio.offer(item) else {
                self.heldReportNeedsYou = self.heldReportNeedsYou || needsYou
                return
            }
            self.deliverReport(note, needsYou: needsYou)
        }
        home.agents?.notifier.isQuiet = { [weak self] in self?.audio.quiet.isQuiet ?? false }
        audio.openMicrophoneSettings = { [weak self] in self?.openMicrophoneSettings() }
        audio.onEchoCancellationLost = { [weak self] reason in self?.alwaysOn.echoCancellationLost(reason) }
        audio.onRelease = { [weak self] items in self?.released(items) }
        audio.start(microphone: microphone)
        // The cues are synthesized now, so the first press doesn't wait for them.
        cues.prewarm()
        home.agents?.playCue = { [weak self] cue in self?.cues.play(cue) }
        orchestrator.onReportUndelivered = { [weak self] _ in self?.home.agents?.reportsUndelivered() }
        // Home's typed chat and always-on use the same brain; a question there builds the engines first.
        brainRelay.setPrepare { [weak self] in await self?.ensureEngines() }
        alwaysOn.onUpdate = { [weak self] update in self?.alwaysOnRecorder?.apply(update) }
        alwaysOn.onTyped = { [weak self] text in self?.alwaysOnRecorder?.typed(text) }
        // A skill switched on or off mid-session: the brain notices at its next turn; always-on is told now.
        home.skills.onActiveSkillsChange = { [weak self] in self?.activeSkillsChanged() }
        // Shaders compile in the background; a failure tells the brain figures can't be shown.
        FigureAvailability.shared.warmUp { [weak self] problem in
            guard let problem else { return }
            Task { @MainActor in self?.log.error("3D figures unavailable: \(problem, privacy: .public)") }
        }
        followJobs()
        applySettings()
    }

    private func deliverReport(_ note: String, needsYou: Bool = false) {
        cues.play(needsYou ? .agentNeedsYou : .agentDone)
        ensureEngines()
        orchestrator.runReportTurn(note: note)
    }

    /// What waited for a call or a Focus to end: the reports in one turn, then onboarding.
    private func released(_ items: [ProactiveItem]) {
        let reports = items.filter { $0.kind == .jobReport || $0.kind == .routineNotice }.map(\.payload)
        if !reports.isEmpty {
            deliverReport(reports.joined(separator: "\n\n"), needsYou: heldReportNeedsYou)
            heldReportNeedsYou = false
        }
        if items.contains(where: { $0.kind == .onboardingPrompt }), let open = heldOnboarding {
            heldOnboarding = nil
            open()
        }
    }

    /// Opens onboarding now, or once a call or Focus is over.
    func offerOnboarding(_ open: @escaping () -> Void) {
        let item = ProactiveItem(id: "onboarding", kind: .onboardingPrompt, title: "Finish setting up OpenClicky", createdAt: Date())
        if audio.offer(item) {
            open()
        } else {
            heldOnboarding = open
        }
    }

    private func openMicrophoneSettings() {
        home.openSettings(.microphone)
    }

    func stop() {
        audio.stop()
        model.talkKeyMonitor.stop()
        handOffs?.cancel()
        handOffs = nil
        brainRelay.setPrepare(nil)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let ears { Task { await ears.shutDown() } }
        alwaysOn.stop()
        // Closes the mic now; the session closes in the background.
        microphone.alwaysOn.stop()
        dictation?.stop()
        _ = orchestrator.interrupt()
        orchestrator.stopWalkthrough()
        typedPanel.hide()
        offerExpiry?.cancel()
        // Trips the drive's stop switch at once (no event is posted after it), then ends it.
        takeover.controller.emergencyStop(.cancelled)
        takeover.presenter.blocker.stop()
    }

    /// The user picked a microphone in Settings. Picking the one already chosen counts too: after a failover to the
    /// built-in mic that is how they ask to try it again (`update` alone only reacts to a changed choice).
    func chooseMicrophone(_ uid: String?) {
        home.microphone.select(uid)
    }

    func update(_ newSettings: VoiceLoopSettings) {
        // A different microphone drops a failover pin to the built-in mic (other settings changes leave it alone).
        if newSettings.microphoneUID != settings.microphoneUID { audio.microphoneChosen(uid: newSettings.microphoneUID) }
        settings = newSettings
        if let settingsURL { try? newSettings.save(to: settingsURL) }
        applySettings()
    }

    /// Settings → Microphone picked an input (nil = the system default): the voice loop's mic and dictation's switch.
    func selectMicrophone(uid: String?) {
        audio.microphoneChosen(uid: uid)
        var next = settings
        next.microphoneUID = uid
        update(next)
        dictation?.selectMicrophone(uid: uid)
    }

    /// Settings → Dictation changed dictation.json: the running dictation takes it from the next press.
    func reloadDictationSettings() {
        guard let dictation else { return }
        dictation.update(DictationSettings.load(), engines: dictationEngines())
    }

    /// Opens the text panel near the pointer (the menu's "Type a Question…").
    func openTypedPanel() { typedPanel.show(near: NSEvent.mouseLocation) }

    var isTypedPanelVisible: Bool { typedPanel.isVisible }

    func setTypedPanelVisible(_ visible: Bool) {
        if visible { openTypedPanel() } else { typedPanel.hide() }
    }

    /// Stops whatever is happening (the menu's Stop).
    func stopTurn() { _ = orchestrator.interrupt() }

    /// The menu's Start / Stop Always-On Voice (the same as triple-tapping Control).
    func toggleAlwaysOn() { alwaysOn.toggle() }

    /// A typed question from somewhere other than the text panel (the notch's chat tab).
    func ask(_ text: String) { submitTyped(text) }

    /// OpenClicky's own-window capture policy (the notch registers its panels with it).
    var capturePolicy: OwnWindowCapturePolicy { screenLook.capturePolicy }

    /// Re-reads who wants Escape (the notch opened or folded).
    func refreshEscapeGate() { updateEscapeGate() }

    /// Ends the walkthrough and any turn of its own still being prepared or said (the menu's Stop walkthrough).
    func stopWalkthrough() {
        orchestrator.stopWalkthrough()
        updateEscapeGate()
    }

    private func applySettings() {
        orchestrator.settings.speaksTypedAnswers = settings.speaksTypedAnswers
        orchestrator.settings.language = home.voice.settings.languages.first
        cues.enabled = settings.playsCues
        model.drawings.sounds?.isEnabled = settings.playsDrawingSounds
        player.rate = Float(home.voice.settings.speed)
        model.voiceLoopSettings = settings
        model.alwaysOnKeyPhrase = home.talkKeys.settings.text.tripleTapPhrase
        let postsInput = settings.takeoverPostsInput
        takeoverPostsInput.withLock { $0 = postsInput }
        audio.echoSetting = settings.echoCancellation
        audio.microphoneUID = settings.microphoneUID
        audio.mutedGuard.enabled = settings.handlesMutedOutput
        if audio.quiet.policy.enabled != settings.holdsDuringQuiet { audio.quiet.policy.enabled = settings.holdsDuringQuiet }
    }

    // MARK: Take-over

    /// A reply while the consent card is up: a clear yes approves (the brain then starts the drive), a clear no
    /// declines; anything else leaves the card up.
    private func answerTakeoverOffer(_ words: String) async {
        guard case .offered = takeover.controller.phase else { return }
        let phase = await takeover.controller.userReplied(words)
        log.info("take-over reply: \(phase.name, privacy: .public)")
        watchOfferExpiry()
    }

    /// Drops an offer or approval nobody acted on in time (the card hides), checking while one is pending.
    private func watchOfferExpiry() {
        guard offerExpiry == nil else { return }
        let controller = takeover.controller
        offerExpiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                switch controller.phase {
                case .offered, .approved: await controller.expireStaleOffers()
                default: self?.offerExpiry = nil; return
                }
            }
        }
    }

    // MARK: Talk keys

    private func handle(_ gesture: TalkKeyGestureMachine.Output) {
        // While Settings records a new talk key, the keys being pressed are the recording, not a command.
        if home.talkKeys.recorder?.isRecording == true {
            switch gesture {
            case .voiceReleased, .voiceCancelled: break // a press that began before recording still ends
            default: return
            }
        }
        switch gesture {
        case .voicePressed:
            guard dictation?.isDictating != true else { return }
            // Always-on has the mic: the press stops its reply (the user just keeps talking) and starts no turn.
            if alwaysOn.talkKeysPressed() { break }
            // Wake the cue output now: by the time the mic is live the start cue plays without a cold lead-in.
            cues.warmUp()
            ensureEngines()
            orchestrator.pressBegan()
        case .voiceReleased:
            orchestrator.pressEnded()
        case .voiceCancelled:
            orchestrator.pressCancelled()
        case .textTrigger:
            if typedPanel.isVisible { typedPanel.hide() } else { typedPanel.show(near: NSEvent.mouseLocation) }
        case .alwaysOnToggle:
            // The double tap before the third one may have opened the text panel.
            typedPanel.hide()
            alwaysOn.toggle()
        case .dictation(let input):
            dictation?.handleKey(input)
        case .escape:
            if notchEscape() {
                // The open notch folded.
            } else if typedPanel.isVisible {
                typedPanel.hide()
            } else if home.agents?.panel.isVisible == true {
                home.agents?.panel.hide()
            } else if dictation?.escape() == true {
                // Dictation stopped.
            } else if alwaysOn.escape() {
                // Always-on's reply stopped; it keeps listening.
            } else {
                _ = orchestrator.interrupt()
            }
        }
        updateEscapeGate()
    }

    private func submitTyped(_ text: String) {
        // While always-on runs the question goes into its conversation and is answered aloud.
        if alwaysOn.submitTyped(text) {
            typedPanel.hide()
            return
        }
        ensureEngines()
        orchestrator.submitTyped(text)
    }

    /// Escape is swallowed only when it stops something of ours (a turn, a drawing, a walkthrough, the text panel,
    /// dictation, always-on's reply, the background jobs panel).
    private func updateEscapeGate() {
        model.talkKeyMonitor.escapeGate.consumesEscape = orchestrator.canInterrupt || typedPanel.isVisible || dictation?.isDictating == true
            || alwaysOn.display.canInterrupt || notchWantsEscape() || home.agents?.panel.isVisible == true
    }

    private func showNotice(_ notice: TurnNotice) {
        model.turn.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.model.turn.notice == notice else { return }
            self.model.turn.notice = nil
        }
    }

    private func finished(_ record: TurnRecord) {
        onTurnRecord?(record)
        lastTimings = record.timings
        model.lastTimings = record.timings
        if let history = record.history {
            do { try home.history.append(history) } catch { log.error("history not saved: \(String(describing: error), privacy: .public)") }
            saveLesson(record, history: history)
        }
        log.info("\(record.timings.report(), privacy: .public)")
        if audio.turnFinished(record) {
            // The card under the notch says it, with its buttons.
            model.turn.notice = nil
        } else if let notice = record.notice {
            showNotice(notice)
        } else if record.failure != nil, let notice = model.turn.notice {
            showNotice(notice)
        }
        // An answer that offered a take-over left its card up: drop it if nobody answers in time.
        if case .offered = takeover.controller.phase { watchOfferExpiry() }
        updateEscapeGate()
        refreshLatencyHUD()
    }

    /// Shows the floating latency stats with the last turn and the brain session (or hides them when the flag is off).
    func refreshLatencyHUD() {
        guard home.infra.isOn(.latencyHUD) else {
            latencyHUD.hide()
            return
        }
        let timings = lastTimings
        let brain = brainRelay.brain as? BrainRuntime
        Task { [weak self] in
            let stats = await brain?.stats
            self?.latencyHUD.show(LatencyHUDContent.make(timings: timings, stats: stats))
        }
    }

    /// With "Save drawings as lessons" on, a turn that drew keeps its screenshot, a poster and lesson.json beside the
    /// history (Home's Drawings page replays it over that screenshot).
    private func saveLesson(_ record: TurnRecord, history: HistoryTurn) {
        guard let draft = record.lesson, history.program != nil, home.infra.flags.isOn(.drawingSavesLessons) else { return }
        do {
            if let folder = try DrawingLessonRecorder.record(draft, turn: history, store: DrawingLessonStore(historyDirectory: home.history.directory),
                                                             ink: orchestrator.settings.ink) {
                log.info("lesson saved: \(folder.lastPathComponent, privacy: .public)")
            }
        } catch {
            log.error("lesson not saved: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Engines

    /// Builds (or rebuilds, between turns) the brain, the voice and stt from the current settings.
    private func ensureEngines() {
        applySettings()
        // Not under a running turn: a Home chat or always-on question on the relay keeps the brain it started with.
        guard !orchestrator.isBusy else { return }
        // Connected apps are part of the brain's tools and prompt, so a change in Settings rebuilds it too. Sorted keys:
        // the file is read again each time, and plain encoding of its dictionaries changes order between reads.
        let connectors = (try? ConnectorRegistry.load(from: home.locations.connectors)) ?? ConnectorRegistry()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configKey = (try? encoder.encode(model.config)).map { $0.base64EncodedString() } ?? UUID().uuidString
        // The brain flags change its tools and pruning, so flipping one on the Developer page rebuilds it as well.
        let flags = FeatureFlagStore()
        let key = configKey + "|" + ConnectedAppsWiring.fingerprint(connectors)
            + "|apps:\(flags.isOn(.brainReadsConnectedApps)) screens:\(flags.isOn(.brainKeepsScreens))"
        guard key != engineKey || brainIsUnavailable else { return }
        brainRelay.replaceIfIdle {
            // Same settings, retried only because the brain couldn't be built: keep the connected-app hub (and its
            // child processes) instead of shutting it down and starting it again.
            let sameSettings = key == engineKey
            engineKey = key
            let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
            let config = model.config
            takeoverConfig.withLock { $0 = config }
            let lookups = LookupServices.make(config: (try? ServicesConfig.load()) ?? .defaults, credentials: model.credentials)
            self.lookups = lookups
            // The old hub's connections (local servers are child processes) close; anything still holding it reconnects.
            if !sameSettings || connectedApps == nil {
                if let previous = connectedApps { Task { await previous.reader.hub.shutdown() } }
                connectedApps = ConnectedAppsWiring.make(registry: connectors, credentials: model.credentials, factory: factory)
            }
            // Photo, place, quote and site-icon cards in the drawings look themselves up while the answer is spoken.
            model.drawings.media = DrawingMediaResolver(lookups: LiveDrawingMediaLookups(services: lookups))
            // Optional grounding for guided targets nothing else can place (config "grounding"; docs/guided.md).
            model.pointing.setGrounding(factory: factory)
            let brain: any BrainTurnRunning
            do {
                brain = try brainWiring(lookups: lookups).makeRuntime(factory: factory)
                brainIsUnavailable = false
                engineProblem = nil
            } catch {
                brain = UnavailableBrain(reason: Self.describe(error))
                brainIsUnavailable = true
                engineProblem = Self.describe(error)
            }
            let apple = AppleSpeechSynthesisClient(context: ProviderContext(provider: ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis), apiKey: nil))
            let narrator: LineNarrator
            if let voice = try? factory.speechOutput() {
                // A second configured cloud voice speaks before the Apple voice when the slot's provider fails.
                let alternate = factory.alternateSpeechOutput()
                narrator = LineNarrator(voice: voice, fallback: apple, player: player, alternate: alternate?.client)
                if let alternate { log.info("voice fallback order: slot, \(alternate.name, privacy: .public), Apple voice") }
            } else {
                narrator = LineNarrator(voice: apple, fallback: nil, player: player)
            }
            orchestrator.services = TurnOrchestrator.Services(
                microphone: microphone.turns, speechToText: makeEars(factory: factory), screen: turnScreen, brain: brainRelay, narrator: narrator,
                drawings: model.drawings, cues: cues, guidance: model.pointing, output: audio.mutedGuard)
            if let dictation { dictation.update(dictation.settings, engines: dictationEngines()) }
            log.info("engines built: brain \(self.brainIsUnavailable ? "unavailable" : "ready", privacy: .public)")
            return brain
        }
    }

    /// What the brain is built from: memory (recall also searches earlier chats), the local app tools, lookups,
    /// connected apps and the Obsidian vault, background jobs and take-over; the active skills, the `[Your jobs]` note
    /// every turn, and whether 3D figures work on this Mac.
    private func brainWiring(lookups: LookupServices) -> BrainWiring {
        let turnNotes: (@Sendable () async -> [String])?
        if let agents = home.agents {
            turnNotes = { [weak agents] in
                guard let agents else { return [] }
                // `[Browser]` is its own note, so the brain hears it only when the connection changes.
                return await agents.brainNotes() + [await agents.browserNote()]
            }
        } else { turnNotes = nil }
        // insert_text: the brain types where the cursor is, through dictation's inserter, after its narration.
        let appTools = AppToolbox.standard(.live()).adding(InsertTextTool.make(inserter: TextInserter(system: SystemTextInsertion())))
        var wiring = BrainWiring(memory: home.memoryStore, history: home.history, appTools: appTools,
                    lookups: LookupTools(services: lookups), agents: home.agents?.tools, connectedApps: connectedApps,
                    extraTools: ToolRegistry.takeoverTools(takeover.tools), skills: home.skills.library,
                    turnNotes: turnNotes, figures: FigureAvailability.shared)
        wiring.apply(FeatureFlagStore())
        return wiring
    }

    // MARK: Skills, jobs and hand-offs

    private func currentFactory() -> EngineFactory {
        EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
    }

    /// The active skills changed: a running always-on session gets a `[Skill update]` (the brain runtime compares at
    /// its next turn by itself).
    private func activeSkillsChanged() {
        alwaysOn.addNote(RealtimeInstructions.skillUpdate(home.skills.library.skillsPromptSection()))
    }

    /// Follows the job manager: each job that starts and each run that comes back is recorded in the conversation the
    /// brain holds, and a finished job may leave a how-to in memory (brain-fast decides).
    private func followJobs() {
        guard handOffs == nil, let manager = home.agents?.coordinator.manager else { return }
        let history = home.history, memory = home.memoryStore, relay = brainRelay
        let log = self.log
        handOffs = Task.detached(priority: .utility) { [weak self] in
            var tracker = HistoryHandOffTracker()
            let updates = await manager.subscribe()
            for await update in updates {
                guard var handOff = tracker.observe(update) else { continue }
                handOff.sessionID = await (relay.brain as? any BrainSessionNaming)?.currentSessionID()
                    ?? history.sessions(limit: 1).first?.id ?? UUID().uuidString
                do { try history.append(handOff) } catch { log.error("hand-off not saved: \(String(describing: error), privacy: .public)") }
                if case .report(let report) = update, report.outcome == .done {
                    // The job wrote down what it learned: keep that, without asking brain-fast as well.
                    if let learned = report.learned, !learned.isEmpty {
                        let outcomes = AgentHowToLearner.saveLearned(learned, store: memory)
                        log.info("how-tos from \(report.jobID, privacy: .public)'s learned block: \(outcomes.count)")
                        continue
                    }
                    // The slots as they are now (brain-fast, falling back to the brain).
                    guard let factory = await self?.currentFactory(), let learner = try? AgentHowToLearner(factory: factory) else { continue }
                    let record = await manager.jobs().first { $0.id == report.jobID }
                    let task = record?.runs.last?.ask ?? record?.task
                    Task.detached(priority: .background) {
                        do {
                            if let outcome = try await learner.learn(from: report, task: task, store: memory) {
                                log.info("how-to from \(report.jobID, privacy: .public): \(String(describing: outcome), privacy: .public)")
                            }
                        } catch {
                            log.error("how-to not learned: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    /// The ears for the stt slot (replacing the previous ones), warmed when they were used recently. When the slot can't
    /// be built, every press says why.
    private func makeEars(factory: EngineFactory) -> () throws -> any SpeechToTextClient {
        if let old = ears { Task { await old.shutDown() } }
        ears = nil
        do {
            let built = try VoiceEars.make(factory: factory, usage: .userDefaults(), language: orchestrator.settings.language,
                                           keywords: orchestrator.settings.keywords)
            ears = built
            let log = self.log
            Task {
                await built.setLogHandler { line in log.info("\(line, privacy: .public)") }
                await built.refresh(.launch)
            }
            return { built }
        } catch {
            return { throw error }
        }
    }

    // MARK: Always-on voice

    /// Before a session opens (the running turn is already stopped and turns are held): the walkthrough ends, and the
    /// narrator lets go of the speech player always-on is about to speak through.
    private func alwaysOnWillStart() {
        orchestrator.stopWalkthrough()
        orchestrator.services.narrator?.release()
        typedPanel.hide()
    }

    /// Always-on's controller for the current settings: the realtime-voice slot's client, OpenClicky's instructions,
    /// the tools (the pointer's screen, the brain for hard or visual questions with its drawing on the overlay, memory,
    /// lookups and app tools), the shared mic and speech player, and the default output for the echo gate.
    private func makeAlwaysOnController() throws -> AlwaysOnVoiceController {
        // The brain the voice loop uses answers send_to_higher_model, in the same thread.
        ensureEngines()
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        let client = try factory.realtimeVoice()
        var own = Set(model.overlayWindowNumbers + typedPanel.windowNumbers + audio.windowNumbers)
        own.formUnion(NSApp.windows.map(\.windowNumber))
        let exclusion = CaptureExclusion(windowNumbers: own, bundleIdentifiers: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
        let screen = brainDrawing.screen(LiveRealtimeScreenSource(exclusion: exclusion))
        let brain: (any BrainTurnRunning)? = brainIsUnavailable ? nil : brainRelay
        // send_to_higher_model sees what a push-to-talk turn sees: every display, the front app and window, element
        // ids and the document, plus what was said so far in this always-on run.
        let look = brainDrawing.look(AppRealtimeBrainLook { [weak self] includeScreen in
            await self?.lookForAlwaysOnBrain(includeScreen: includeScreen) ?? RealtimeBrainLook()
        })
        let memory = home.memoryStore, library = home.skills.library
        let apps = connectedApps?.apps ?? []
        let toolbox = RealtimeToolbox.standard(
            screen: screen, brain: brain, brainLook: look, brainObserver: brain == nil ? nil : brainDrawing.observer,
            memory: MemoryTools(store: memory, history: home.history), lookups: lookups.map { LookupTools(services: $0) },
            apps: AppToolbox.standard(.live()), agents: home.agents?.tools,
            connectedApps: FeatureFlagStore().isOn(.brainReadsConnectedApps) ? connectedApps.map { ($0.reader, $0.apps) } : nil,
            isDrawing: { [brainDrawing] in await brainDrawing.isPlaying },
            typingRefused: { InsertTextTool.wouldRefuse(system: SystemTextInsertion()) })
        let names = Set(toolbox.specs.map(\.name))
        let player = self.player
        // Memory and the active skills are read each time a session opens (a reconnect gets the current ones).
        let router = audio.router
        // The brain's drawing is paced by the reply as it plays through the same player.
        brainDrawing.playback = { (router.player ?? player).position() }
        brainDrawing.onLog = { [weak self] text in self?.log.info("\(text, privacy: .public)") }
        let audio = self.audio
        let current = model.config
        alwaysOnConfig.withLock { $0 = current }
        alwaysOnVoiceKey = Self.alwaysOnVoiceKey(model.config)
        var environment = AlwaysOnVoiceController.Environment.standard(
            client: client,
            instructions: {
                let stable = (try? memory.snapshot()).map { MemoryPromptBuilder().build(from: $0, query: "").stableText }
                return RealtimeInstructions.alwaysOn(memory: stable, skills: library.skillsPromptSection(), toolNames: names, connectedApps: apps)
            },
            toolbox: toolbox,
            makeOutput: { SpeechPlayerRealtimeOutput(player: router.player ?? player) }, microphone: microphone.alwaysOn,
            outputRoute: { AudioOutputRoute.classify(AudioDevices.defaultOutput()) })
        // Its exchanges go into the brain's conversation in the history; its memory is written when the run ends.
        let writer = try? MemoryWriter(factory: factory)
        let recorder = AlwaysOnRecorder(history: home.history, sessions: brainRelay, memory: writer.map { ($0, memory) }, model: client.model)
        let relay = brainRelay
        recorder.onRunNote = { note in await relay.recordOutcome(note) }
        recorder.onLog = { [weak self] text in self?.log.info("\(text, privacy: .public)") }
        alwaysOnRecorder = recorder
        // Each session's client is built from the config as it is then, so a session replaced after a voice change
        // speaks with the new voice.
        let configBox = alwaysOnConfig, catalog = model.mergedCatalog, credentials = model.credentials
        environment.connect = { configuration in
            guard let config = configBox.withLock({ $0 }) else { return try await client.connect(configuration) }
            return try await EngineFactory(config: config, catalog: catalog, credentials: credentials).realtimeVoice().connect(configuration)
        }
        environment.prepareRoute = { route in await audio.prepareAlwaysOn(route: route) }
        environment.echoSettings = { route, cancelled in .tuned(for: route, echoCancelled: cancelled) }
        environment.releaseRoute = { await audio.alwaysOnEnded() }
        return AlwaysOnVoiceController(environment: environment)
    }

    /// The look `send_to_higher_model` hands the brain.
    private func lookForAlwaysOnBrain(includeScreen: Bool) async -> RealtimeBrainLook {
        let notes = [alwaysOnRecorder?.recentNote()].compactMap { $0 }
        guard includeScreen else {
            // No screenshot wanted: don't capture the screen at all, only the front app, window and document.
            home.agents?.turnAssets.record(AgentTurnAssets(screenshots: [], capturedAt: Date()))
            let context = await screenLook.context()
            return RealtimeBrainLook(context: context.turnContext(), appNotes: context.turnAppNotes + notes)
        }
        let look = await turnScreen.look()
        return RealtimeBrainLook(screenshots: look.screenshots, context: look.context,
                                 appNotes: look.appNotes + notes)
    }

    /// What decides the always-on voice: the realtime-voice slot and the voice slot's chosen voice.
    private static func alwaysOnVoiceKey(_ config: OpenClickyConfig) -> String {
        let realtime = config.slots[.realtimeVoice].map { "\($0.provider)/\($0.model)/\($0.voice ?? "")" } ?? "-"
        return realtime + "|" + (config.slots[.voice]?.voice ?? "")
    }

    /// While always-on runs, a voice change in Settings marks its session stale (replaced at the next pause).
    private func watchVoiceSettings() {
        guard alwaysOn.isActive, !watchingVoiceSettings else { return }
        watchingVoiceSettings = true
        withObservationTracking {
            _ = model.config.slots
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingVoiceSettings = false
                guard self.alwaysOn.isActive else { return }
                let key = Self.alwaysOnVoiceKey(self.model.config)
                if key != self.alwaysOnVoiceKey {
                    self.alwaysOnVoiceKey = key
                    let config = self.model.config
                    self.alwaysOnConfig.withLock { $0 = config }
                    self.alwaysOn.voiceChanged()
                }
                self.watchVoiceSettings()
            }
        }
    }

    private func alwaysOnStateChanged(_ state: AlwaysOnState) {
        switch state {
        case .on:
            cues.play(.startListening)
            watchOutputRoute()
            watchVoiceSettings()
        case .off:
            outputWatcher = nil
            audio.alwaysOnEnded()
            cues.play(.stopListening)
        case .refused:
            outputWatcher = nil
            audio.alwaysOnEnded()
        case .failed:
            outputWatcher = nil
            audio.alwaysOnEnded()
            cues.play(.error)
        case .starting:
            break
        }
        // Off, refused or failed: the notch says so, and whether it had been running ("stopped") or never got going.
        if let notice = alwaysOn.notice(for: state, talkKeys: home.talkKeys.settings.voice.symbol, keyPhrase: model.alwaysOnKeyPhrase) {
            showNotice(notice)
        }
        updateEscapeGate()
    }

    /// Sound moving to the speakers ends always-on (or switches its echo gate when speakers are allowed).
    private func watchOutputRoute() {
        guard outputWatcher == nil else { return }
        outputWatcher = AudioDeviceWatcher(queue: .main) { [weak self] change in
            guard change == .defaultOutput else { return }
            Task { @MainActor in
                self?.alwaysOn.outputRouteChanged()
                // The audio host rebuilds for the new device first; then the cue output is warmed on it (if fresh).
                try? await Task.sleep(for: .milliseconds(600))
                self?.cues.rewarmAfterOutputChange()
            }
        }
    }

    /// Dictation's ears for the current stt slot: kept while the slot stays the same (so their warm connection and
    /// refusal switch carry over), replaced when it changes.
    private func makeDictationEars() -> VoiceEars? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let slot = model.config.slots[.stt]
        let provider = slot.flatMap { model.config.provider($0.provider) }
        let key = ((try? encoder.encode(slot)) ?? Data()).base64EncodedString() + "|" + ((try? encoder.encode(provider)) ?? Data()).base64EncodedString()
        if let existing = dictationEars, existing.key == key { return existing.ears }
        if let old = dictationEars?.ears { Task { await old.shutDown() } }
        dictationEars = nil
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        guard let built = try? VoiceEars.make(factory: factory, usage: .userDefaults(key: "openclicky.ears.dictation.lastUsedAt.v1"),
                                             language: DictationSettings.load().language) else { return nil }
        dictationEars = (key, built)
        let log = self.log
        // The warm socket only serves presses with the same language and keywords, so it opens for dictation's.
        let settings = DictationSettings.load()
        let seeds = DictationCoordinator.keytermSeeds(settings)
        Task {
            await built.setLogHandler { line in log.info("dictation \(line, privacy: .public)") }
            let keyterms = await DictationCoordinator.vocabulary.load().keyterms(seeds: seeds)
            await built.expect(language: settings.language, keywords: keyterms)
            await built.refresh(.launch)
        }
        return built
    }

    private func dictationEngines() -> DictationCoordinator.Engines {
        let current = model.config
        let catalog = model.mergedCatalog
        let credentials = model.credentials
        let ears = makeDictationEars()
        return DictationCoordinator.Engines(
            speechToText: {
                // The ears: a warm connection taken at key-down, the press kept while it opens, refusal switch and
                // fallbacks. Without them (the slot can't be built), the plain client says why at the press.
                ears ?? (try? EngineFactory(config: current, catalog: catalog, credentials: credentials).speechToText())
            },
            cleaner: {
                DictationCleanupClientResolver.makeCleaner(config: current, settings: DictationSettings.load(), catalog: catalog,
                                                           factory: AdapterModelClientFactory(), credentials: credentials)
            },
            fallbackSpeechToText: DictationCoordinator.Engines.onDeviceFallback)
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// `send_to_higher_model`'s look, gathered on the main actor by the voice loop.
struct AppRealtimeBrainLook: RealtimeBrainLooking {
    let gather: @Sendable (Bool) async -> RealtimeBrainLook

    init(_ gather: @escaping @Sendable (Bool) async -> RealtimeBrainLook) { self.gather = gather }

    func lookForBrain(includeScreen: Bool) async -> RealtimeBrainLook { await gather(includeScreen) }
}

/// Stands in until the brain slot can be built; every turn says why.
final class UnavailableBrain: BrainTurnRunning, @unchecked Sendable {
    let reason: String

    init(reason: String) { self.reason = reason }

    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        let reason = self.reason
        return AsyncThrowingStream { continuation in
            continuation.yield(.failed(spoken: "I can't answer yet, because my brain model isn't set up. Choose one in Settings, under Models.",
                                       detail: reason))
            continuation.finish()
        }
    }

    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
}

/// Screenshots without OpenClicky's own windows, and the context, through `ScreenLookService`.
@MainActor
final class ScreenLookAdapter: TurnScreenLooking {
    let service: ScreenLookService

    init(service: ScreenLookService) { self.service = service }

    func prefetch() { service.prefetchContext() }
    func cancelPrefetch() { service.cancelPrefetch() }

    func look() async -> TurnScreenLook { Self.screenLook(await service.lookForTurn()) }

    /// After a click on a walkthrough's target: waits for the screen to settle first.
    func lookAfterAction() async -> TurnScreenLook { Self.screenLook(await service.lookForTurn(afterAction: true)) }

    private static func screenLook(_ look: TurnLook) -> TurnScreenLook {
        TurnScreenLook(screenshots: look.screenshots, context: look.turnContext(), appNotes: look.appNotes,
                       captureError: look.captureError, layout: look.layout, guidedScreen: GuidedScreen(look: look))
    }
}

/// OpenClicky's interface sounds: synthesized at launch (`prewarm`), the output woken at key-down (`warmUp`) and kept
/// warm for a while after use, and warmed again after sleep or an output change while still in use.
@MainActor
final class AppCues: TurnCuePlaying {
    var enabled = true
    private var player: CuePlayer?

    private var cuePlayer: CuePlayer {
        let player = self.player ?? CuePlayer(volume: 0.6)
        self.player = player
        return player
    }

    func play(_ cue: UICue) {
        guard enabled else { return }
        cuePlayer.play(cue)
    }

    /// Synthesizes every cue now; opens no device.
    func prewarm() { cuePlayer.preload() }

    /// Wakes the output device ahead of a cue (and keeps it warm for the cue player's freshness window).
    func warmUp() {
        guard enabled else { return }
        cuePlayer.warmUp()
    }

    /// After sleep: warms the output again if cues were used within the freshness window. Never makes the player.
    func rewarmAfterWake() {
        guard enabled, let player else { return }
        player.rewarmAfterWake()
    }

    /// After the default output changed: warms the new device if cues were used within the freshness window.
    func rewarmAfterOutputChange() {
        guard enabled, let player else { return }
        player.rewarmAfterOutputChange()
    }
}
