import CoreGraphics
import Foundation

/// The voice turn loop: talk keys → mic and speech to text → screenshots and context → the brain → spoken lines and
/// a speech-paced drawing → deferred actions → idle. One turn at a time; a new press, Escape or a typed question cuts
/// the current one off (barge-in). See docs/turn-contract.md and docs/voice-loop.md.
///
/// Everything it touches comes through `Services`, so the same loop runs in the app (real mic, ScreenCaptureKit,
/// overlays) and headlessly in tests and `occtl turn` (a scripted transcript, a still image, an offscreen canvas).
///
///     orchestrator.pressBegan()       // talk keys down: barge-in, mic + stt open, prefetch, prewarm
///     orchestrator.pressEnded()       // keys up: transcript → capture → brain → voice and drawing
///     orchestrator.pressCancelled()   // a tap or a typed shortcut: drop the press quietly
///     orchestrator.interrupt()        // Escape: stop whatever is happening (true if there was something)
///     orchestrator.submitTyped("…")   // the text panel
///     orchestrator.runReportTurn(note: AgentReportTurn.note(for: reports))
///
/// With `Services.guidance` (draw-to-ask and guided walkthroughs, docs/guided.md) user turns carry the highlight the
/// user drew while holding the keys, answers arm the walkthrough's targets, and a click on a target (or a finished
/// manual step) starts the next turn by itself (`runGuidedTurn`, trigger `clicked_target` / `did_step`).
@MainActor
public final class TurnOrchestrator {
    public struct Settings: Sendable, Hashable {
        /// Language hint for speech to text (nil: the model decides).
        public var language: String?
        /// Words the recognizer should expect.
        public var keywords: [String]
        /// Seconds to wait for the speech connection and the final transcript after key-up.
        public var transcriptTimeout: TimeInterval
        /// Read typed answers aloud; otherwise they are shown and drawn at once.
        public var speaksTypedAnswers: Bool
        /// The drawing ink (the cursor colour).
        public var ink: String
        /// How long the start cue waits for the mic to deliver audio (a mic that can tell, `TurnMicrophoneReadiness`).
        /// A mic that isn't live by then gets no start cue.
        public var startCueTimeout: TimeInterval
        /// When a spoken answer's drawing pauses for a narration gap or stall (`NarrationPacer`).
        public var narrationPacing = NarrationPacer.Policy()

        public init(language: String? = nil, keywords: [String] = ["OpenClicky"], transcriptTimeout: TimeInterval = 4,
                    speaksTypedAnswers: Bool = false, ink: String = "#3380FF", startCueTimeout: TimeInterval = 1.5) {
            self.language = language
            self.keywords = keywords
            self.transcriptTimeout = transcriptTimeout
            self.speaksTypedAnswers = speaksTypedAnswers
            self.ink = ink
            self.startCueTimeout = startCueTimeout
        }
    }

    /// What the loop drives. Swap the whole set while idle when the settings change.
    public struct Services {
        public var microphone: (any TurnMicrophone)?
        /// The stt slot's client (`EngineFactory.speechToText()`); called at every key-down.
        public var speechToText: () throws -> any SpeechToTextClient
        public var screen: any TurnScreenLooking
        public var brain: any BrainTurnRunning
        /// The voice; nil answers silently (captions only).
        public var narrator: LineNarrator?
        public var drawings: (any TurnDrawingSurfaces)?
        public var cues: (any TurnCuePlaying)?
        /// Runs deferred actions; defaults to the brain when it can (`BrainRuntime`).
        public var deferred: (any DeferredActionPerforming)?
        /// Names the history session voice turns go into; defaults to the brain's own session.
        public var sessions: (any BrainSessionNaming)?
        /// Draw-to-ask and the guided walkthrough (nil: neither).
        public var guidance: (any TurnGuiding)?
        /// Checked before a reply is spoken: a muted or zero-volume output answers silently and the record carries the
        /// unheard reply (nil: always speak).
        public var output: (any TurnOutputChecking)?
        public var clock: @Sendable () -> Date

        public init(microphone: (any TurnMicrophone)?, speechToText: @escaping () throws -> any SpeechToTextClient,
                    screen: any TurnScreenLooking, brain: any BrainTurnRunning, narrator: LineNarrator?,
                    drawings: (any TurnDrawingSurfaces)?, cues: (any TurnCuePlaying)? = nil,
                    deferred: (any DeferredActionPerforming)? = nil, sessions: (any BrainSessionNaming)? = nil,
                    guidance: (any TurnGuiding)? = nil, output: (any TurnOutputChecking)? = nil,
                    clock: @escaping @Sendable () -> Date = Date.init) {
            self.microphone = microphone
            self.speechToText = speechToText
            self.screen = screen
            self.brain = brain
            self.narrator = narrator
            self.drawings = drawings
            self.cues = cues
            self.deferred = deferred ?? (brain as? any DeferredActionPerforming)
            self.sessions = sessions ?? (brain as? any BrainSessionNaming)
            self.guidance = guidance
            self.output = output
            self.clock = clock
        }
    }

    public var services: Services {
        didSet { connectGuidance() }
    }
    public var settings: Settings

    /// What the notch and captions show. Changes are reported to `onDisplayChange`.
    public private(set) var display = TurnDisplay() {
        didSet { if display != oldValue { onDisplayChange?(display) } }
    }
    public var onDisplayChange: ((TurnDisplay) -> Void)?
    /// Every finished turn (completed, failed, interrupted, or dropped before the brain).
    public var onTurnFinished: ((TurnRecord) -> Void)?
    /// Every voice event, on the main actor, in order (captions, `occtl turn`'s frames).
    public var onVoiceEvent: ((LineNarrator.Event, Date) -> Void)?
    /// A line for logs.
    public var onLog: ((String) -> Void)?
    /// The user's words of a voice or typed turn, before the brain sees them. Awaited, so whatever it records (a yes
    /// to a take-over offer, `TakeoverController.userReplied`) is in place when the brain answers.
    public var onUserWords: ((String) async -> Void)?
    /// Job reports the brain failed to tell (it failed or said nothing) even after a retry: the notes, for the app to
    /// show another way (a notification, the jobs panel). The notch also shows `AgentReportTurn.fallbackText`.
    public var onReportUndelivered: (([String]) -> Void)?

    /// How many more times a report turn that failed or said nothing is tried.
    public static let reportRetries = 1

    /// While true no turn starts: presses, typed questions and the walkthrough's own turns are refused, and report turns
    /// wait until it is false again. The app holds turns while always-on voice has the mic and the voice
    /// (docs/realtime-voice.md). Holding doesn't stop a turn already running; interrupt it first.
    public var holdsTurns = false {
        didSet {
            guard holdsTurns != oldValue else { return }
            log(holdsTurns ? "turns held" : "turns released")
            if !holdsTurns { startQueuedReport() }
        }
    }

    /// Bumped by every press, typed question, report turn and interruption; a task holding an older number is stale.
    private var generation = 0
    private var press: Press?
    private var active: ActiveTurn?
    private struct QueuedReport {
        var note: String
        /// Earlier tries that failed or said nothing.
        var attempt = 0
    }

    private var reportQueue: [QueuedReport] = []
    private var reportStartScheduled = false
    /// Bumped by every turn the walkthrough cares about (a press, a typed question, its own turns), so a finished
    /// answer reports to it only when no newer one has started (a job report in between doesn't count).
    private var guidedSerial = 0
    /// The last interrupted turn's note on its way to the brain; the next request waits for it.
    private var outcomeNote: Task<Void, Never>?
    private let localSessionID = UUID().uuidString

    public init(services: Services, settings: Settings = Settings()) {
        self.services = services
        self.settings = settings
        connectGuidance()
    }

    /// The guide asks for the walkthrough's own turns and re-captures through here.
    private func connectGuidance() {
        services.guidance?.onRequest = { [weak self] request in
            switch request {
            case .turn(let guided): self?.runGuidedTurn(guided)
            case .refreshCapture: self?.refreshGuidedCapture()
            }
        }
    }

    public var phase: TurnPhase { display.phase }

    /// True while a press or a turn is running.
    public var isBusy: Bool { press != nil || active != nil }

    /// True while a press is open and still listening (not yet let go, cancelled or cut off).
    public var isListening: Bool { press.map { !$0.released && !$0.cancelled } ?? false }

    /// Whether Escape would do something (stop a turn or a walkthrough, or clear a drawing).
    public var canInterrupt: Bool {
        isBusy || services.drawings?.hasVisibleDrawing == true || services.guidance?.isWalkthroughActive == true
    }

    // MARK: - Talk keys

    /// Talk keys down: cut off whatever is running, open the mic and speech to text, start reading the context, warm
    /// the brain's cache and the voice.
    public func pressBegan() {
        guard !holdsTurns else {
            log("key down ignored: turns are held")
            return
        }
        // A walkthrough's own turn this press cuts off is asked again if the press comes to nothing.
        let cutGuided = active.flatMap { $0.kind == .guided ? $0.guided : nil }
        interruptCurrent(.newPress)
        generation += 1
        let press = Press(generation: generation, pressedAt: now())
        press.cutGuided = cutGuided
        self.press = press
        var fresh = TurnDisplay()
        fresh.phase = .listening
        fresh.kind = .voice
        fresh.usingFallbackVoice = services.narrator?.isUsingFallback ?? false
        display = fresh
        // The ink follows the pointer while the keys are held; a walkthrough's waiting step steps aside.
        guidedSerial += 1
        services.guidance?.userTurnStarted(voice: true)
        services.screen.prefetch()
        let brain = services.brain
        Task { await brain.prewarm() }
        if let narrator = services.narrator { Task { await narrator.warmUp() } }
        openEars(press)
        playStartCue(press)
        log("key down: listening")
    }

    /// The start cue says "you can talk now", so it plays once the mic really delivers audio (a Bluetooth headset
    /// switching profiles would otherwise swallow it, or the user would start before the mic did). A mic that can't
    /// tell gets the cue at once; one that never goes live gets none.
    private func playStartCue(_ press: Press) {
        guard let cues = services.cues else { return }
        guard press.setupNotice == nil else { return }
        guard let microphone = services.microphone as? any TurnMicrophoneReadiness else {
            cues.play(.startListening)
            return
        }
        let timeout = settings.startCueTimeout
        Task { [weak self] in
            let live = await microphone.waitUntilLive(timeout: timeout)
            guard let self, self.press === press, !press.released, !press.cancelled else { return }
            if live {
                cues.play(.startListening)
                self.log(String(format: "mic live after %.0f ms: start cue", self.now().timeIntervalSince(press.pressedAt) * 1000))
            } else {
                self.log("start cue skipped: the mic didn't deliver audio within \(timeout) s")
            }
        }
    }

    /// Talk keys up: finish listening and run the turn.
    public func pressEnded() {
        guard let press, press.generation == generation, !press.released else { return }
        press.released = true
        let releasedAt = now()
        services.microphone?.stop()
        services.guidance?.pressEnded()
        services.cues?.play(.stopListening)
        display.phase = .transcribing
        let turn = ActiveTurn(kind: .voice, generation: generation)
        turn.timings.pressedAt = press.pressedAt
        turn.timings.releasedAt = releasedAt
        active = turn
        // The screenshots are taken now, while the last words are transcribed, rather than after.
        startEarlyLook(turn)
        turn.task = Task { [weak self] in
            // The turn's listening, brain rounds, lines and lookups share one usage record group (docs/infra.md).
            await UsageContext.$current.withValue(.turn(.voiceTurn)) { await self?.completeVoiceTurn(press, turn) }
        }
        log(String(format: "key up after %.2f s", releasedAt.timeIntervalSince(press.pressedAt)))
    }

    /// The press was a tap or part of a typed shortcut: drop it without a message.
    public func pressCancelled() {
        guard let press, !press.released else { return }
        cancelPress(press)
        self.press = nil
        if active == nil { display = TurnDisplay() }
        log("press cancelled")
        resumeGuided(after: press)
        startQueuedReport()
    }

    /// Escape: stops the press or turn in progress and any walkthrough, or clears a drawing left on screen. False when
    /// there was nothing to stop (let the key through).
    @discardableResult
    public func interrupt() -> Bool {
        if isBusy {
            interruptCurrent(.escape)
            generation += 1
            display = TurnDisplay()
            if services.guidance?.stopWalkthrough() == true { log("escape: walkthrough stopped") }
            log("escape: stopped")
            startQueuedReport()
            return true
        }
        if services.guidance?.stopWalkthrough() == true {
            log("escape: walkthrough stopped")
            if services.drawings?.hasVisibleDrawing == true { services.drawings?.clearAll() }
            return true
        }
        if services.drawings?.hasVisibleDrawing == true {
            services.drawings?.clearAll()
            log("escape: drawing cleared")
            return true
        }
        return false
    }

    /// The Stop walkthrough control (the menu): ends the walkthrough and cuts off its own turn if one is being prepared
    /// or said, so that answer can't arm the next step again. A turn the user asked for goes on. True when a
    /// walkthrough was running.
    @discardableResult
    public func stopWalkthrough() -> Bool {
        if let turn = active, turn.kind == .guided {
            interruptCurrent(.stoppedWalkthrough)
            display = TurnDisplay()
        }
        let stopped = services.guidance?.stopWalkthrough() == true
        if stopped { log("walkthrough stopped") }
        startQueuedReport()
        return stopped
    }

    // MARK: - Typed and app turns

    /// A typed question (the text panel or a drawn button's ask). Cuts off whatever is running.
    public func submitTyped(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        guard !holdsTurns else {
            log("typed question ignored: turns are held")
            return
        }
        interruptCurrent(.typed)
        guidedSerial += 1
        services.guidance?.userTurnStarted(voice: false)
        startTurn(kind: .typed, words: words, trigger: nil, notes: [])
    }

    /// A guided walkthrough's next step (the user clicked the target or did a manual step): a turn with no words, the
    /// walkthrough's trigger and notes, captured once the screen has settled. Cuts off an answer still speaking (the
    /// user went ahead); dropped while the user is holding the talk keys.
    public func runGuidedTurn(_ request: GuidedTurnRequest) {
        guard press == nil else {
            log("guided \(request.trigger.rawValue) ignored: the user is talking")
            return
        }
        guard !holdsTurns else {
            log("guided \(request.trigger.rawValue) ignored: turns are held")
            return
        }
        interruptCurrent(.steppedAhead)
        startTurn(kind: .guided, words: "", trigger: request.trigger.rawValue, notes: request.notes, guided: request)
    }

    /// The user kept working while the walkthrough's next turn was being prepared: if nothing of it has been heard yet,
    /// start it again on a fresh screenshot and tell the brain to trust the new one.
    public func refreshGuidedCapture() {
        guard !holdsTurns, let turn = active, turn.kind == .guided, var request = turn.guided, !turn.refreshed,
              turn.timings.firstLineHeardAt == nil, turn.lines.isEmpty else { return }
        request.notes.append(GuidedWalkthrough.freshnessNote)
        log("guided: the user kept going; capturing again")
        interruptCurrent(.steppedAhead)
        startTurn(kind: .guided, words: "", trigger: request.trigger.rawValue, notes: request.notes, guided: request, refreshed: true)
    }

    /// A press cut off the walkthrough's own turn and then came to nothing (brushed, nothing heard, no speech
    /// connection): if the walkthrough still waits for that answer (no step was armed before the cut), ask for it again
    /// rather than leave it "working out the next step" with no turn running.
    private func resumeGuided(after press: Press) {
        guard var request = press.cutGuided, !isBusy, !holdsTurns, services.guidance?.isAwaitingNextStep == true else { return }
        // The screen has had time to settle since the click.
        request.settle = false
        log("guided: the press came to nothing; asking for the next step again")
        startTurn(kind: .guided, words: "", trigger: request.trigger.rawValue, notes: request.notes, guided: request)
    }

    /// An `[App]` note for the brain's next turn (a take-over's report), after any cut-off note already on its way.
    public func noteForNextTurn(_ note: String) {
        let brain = services.brain
        let previous = outcomeNote
        outcomeNote = Task {
            await previous?.value
            await brain.recordOutcome(note)
        }
    }

    /// Background jobs came back (`AgentReportTurn.note(for:)`): the brain tells the user. Waits while the user is
    /// talking or another turn runs; reports that waited are told together in one turn.
    public func runReportTurn(note: String) {
        reportQueue.append(QueuedReport(note: note))
        guard !isBusy, !holdsTurns else { return }
        startReportTurn()
    }

    private func startReportTurn() {
        let queued = reportQueue
        reportQueue.removeAll()
        guard !queued.isEmpty else { return }
        let attempt = queued.map(\.attempt).max() ?? 0
        var notes = queued.map(\.note)
        if attempt > 0 { notes.append(Self.reportRetryNote) }
        startTurn(kind: .report, words: "", trigger: "job_report", notes: notes, reportNotes: queued.map(\.note), reportAttempt: attempt)
    }

    static let reportRetryNote = "[App] The last try at telling the user about these jobs didn't reach them (it failed or said nothing). Say one short line about each job now."

    /// A report turn that ended without telling the user anything: tried once more, then handed to
    /// `onReportUndelivered` with a notice built from the reports' own lines.
    private func reportDidNotLand(_ turn: ActiveTurn, failed: Bool) {
        guard !turn.reportNotes.isEmpty else { return }
        if turn.reportAttempt < Self.reportRetries {
            log("report turn \(failed ? "failed" : "said nothing"); trying once more")
            reportQueue.insert(contentsOf: turn.reportNotes.map { QueuedReport(note: $0, attempt: turn.reportAttempt + 1) }, at: 0)
            return
        }
        log("report turn \(failed ? "failed" : "said nothing") again; showing the reports instead")
        if turn.generation == generation, let text = AgentReportTurn.fallbackText(notes: turn.reportNotes) {
            display.notice = TurnNotice(.info, text)
        }
        onReportUndelivered?(turn.reportNotes)
    }

    // MARK: - Listening

    private final class Press {
        let generation: Int
        let pressedAt: Date
        var released = false
        var cancelled = false
        var pump: Task<Void, Never>?
        var listener: Task<Void, Never>?
        var session: (any SpeechToTextSession)?
        var pumpDone = false
        var eventsEnded = false
        var finals = ""
        var interim = ""
        var error: Error?
        /// Why listening never started (no mic, stt not set up).
        var setupNotice: TurnNotice?
        /// The walkthrough's own turn this press cut off (asked again if the press comes to nothing).
        var cutGuided: GuidedTurnRequest?

        init(generation: Int, pressedAt: Date) {
            self.generation = generation
            self.pressedAt = pressedAt
        }

        var heard: String { finals + interim }
    }

    private func openEars(_ press: Press) {
        let client: any SpeechToTextClient
        do {
            client = try services.speechToText()
        } catch {
            press.setupNotice = .listeningNotSetUp(Self.describe(error))
            press.pumpDone = true
            return
        }
        guard let microphone = services.microphone else {
            press.setupNotice = .microphoneUnavailable("There's no microphone to listen with.")
            press.pumpDone = true
            return
        }
        let chunks: AsyncStream<Data>
        do {
            // The mic opens now; its chunks wait in the stream until the speech session is ready.
            chunks = try microphone.start(format: client.inputFormat)
        } catch {
            press.setupNotice = .microphoneUnavailable(Self.describe(error))
            press.pumpDone = true
            return
        }
        let language = settings.language, keywords = settings.keywords
        press.pump = Task { [weak self, press] in
            _ = self
            defer { press.pumpDone = true }
            do {
                let session = try await client.startSession(language: language, keywords: keywords)
                if press.cancelled {
                    await session.cancel()
                    return
                }
                press.session = session
                press.listener = Task { [weak self, press] in
                    do {
                        for try await event in session.events {
                            switch event {
                            case .interim(let text): press.interim = text
                            case .final(let text):
                                press.finals += text
                                press.interim = ""
                            case .speechStarted, .utteranceEnd: continue
                            }
                            self?.showHeard(press)
                        }
                    } catch {
                        if !(error is CancellationError) { press.error = error }
                    }
                    press.eventsEnded = true
                }
                for await chunk in chunks {
                    if press.cancelled { break }
                    await session.send(chunk)
                }
            } catch {
                if !(error is CancellationError) { press.error = error }
            }
        }
    }

    private func showHeard(_ press: Press) {
        guard self.press === press else { return }
        display.liveTranscript = press.heard.trimmingCharacters(in: .whitespaces)
    }

    private enum Heard {
        case words(String)
        case nothing
        case failed(TurnNotice)
    }

    /// Ends the speech session and collects the transcript (bounded by `transcriptTimeout`).
    private func transcript(of press: Press) async -> Heard {
        if let notice = press.setupNotice { return .failed(notice) }
        let timeout = settings.transcriptTimeout
        // The mic has stopped, so the pump ends once the session is open and the buffered audio is sent.
        guard await waitUntil(timeout, { press.pumpDone }) else {
            press.pump?.cancel()
            return .failed(.connectionDropped("The speech connection didn't open in time."))
        }
        guard let session = press.session else {
            if let error = press.error { return .failed(.listeningFailed(error)) }
            return .nothing
        }
        await session.finish()
        let ended = await waitUntil(timeout, { press.eventsEnded })
        if !ended {
            press.listener?.cancel()
            await session.cancel()
        }
        let words = press.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            if let error = press.error { return .failed(.listeningFailed(error)) }
            if !ended { return .failed(.connectionDropped("No transcript came back.")) }
            return .nothing
        }
        return .words(words)
    }

    private func completeVoiceTurn(_ press: Press, _ turn: ActiveTurn) async {
        let heard = await transcript(of: press)
        if let ears = press.session as? any EarsPressReporting {
            let report = await ears.pressReport()
            turn.timings.ears = report
            log(report.logLine(heldMs: turn.timings.heldMs, releaseToWordsMs: turn.timings.releaseToWordsMs))
        }
        guard isCurrent(turn) else { return }
        if self.press === press { self.press = nil }
        turn.timings.transcriptAt = now()
        switch heard {
        case .words(let words):
            turn.words = words
            display.words = words
            display.liveTranscript = words
            log("heard: \(words)")
            await run(turn, isTyped: false, trigger: nil, notes: [])
        case .nothing:
            turn.earlyLook?.cancel()
            services.screen.cancelPrefetch()
            services.guidance?.userTurnCancelled()
            finish(turn, outcome: .notStarted, notice: .nothingHeard)
            resumeGuided(after: press)
        case .failed(let notice):
            turn.earlyLook?.cancel()
            services.screen.cancelPrefetch()
            services.guidance?.userTurnCancelled()
            services.cues?.play(.error)
            finish(turn, outcome: .notStarted, notice: notice)
            resumeGuided(after: press)
        }
    }

    /// Takes the voice turn's screenshots and context at key-up, alongside the final transcript.
    private func startEarlyLook(_ turn: ActiveTurn) {
        let screen = services.screen
        turn.timings.captureStartedAt = now()
        turn.earlyLook = Task { [weak self, weak turn] in
            let look = await screen.look()
            if let self, let turn { turn.timings.captureFinishedAt = self.now() }
            return look
        }
    }

    private func cancelPress(_ press: Press) {
        press.cancelled = true
        if !press.released {
            services.microphone?.stop()
            // The ink stops and a walkthrough's step comes back (Escape or a new turn may then end or replace it).
            services.guidance?.userTurnCancelled()
        }
        press.pump?.cancel()
        press.listener?.cancel()
        if let session = press.session { Task { await session.cancel() } }
        services.screen.cancelPrefetch()
    }

    // MARK: - The turn

    private final class ActiveTurn {
        let kind: TurnKind
        let generation: Int
        var words = ""
        /// Report turns: the job notes it tells, and how many tries came before it.
        var reportNotes: [String] = []
        var reportAttempt = 0
        var timings: TurnTimings
        var task: Task<Void, Never>?
        var log: TurnLogBuilder?
        var screenshot: TurnScreenshot?
        var speaks = false
        var narration: Narration?
        let pacing = PacingRelay()
        /// Pauses the drawing in narration gaps and stalls and reports the words heard (spoken turns only).
        var pacer: NarrationPacer?
        var drawing: (any TurnDrawing)?
        var drawingStarted = false
        /// Program text held back until it is clear whether it starts with `onScreen(n)`.
        var heldProgram = ""
        /// Which screenshot (index into the look's) is this turn's canvas.
        var canvasIndex: Int?
        /// When the drawing began and when each line was heard (for the saved lesson).
        var drawingBeganAt: Date?
        var lineTimes: [Int: (start: Date, end: Date?)] = [:]
        var lines: [Int: String] = [:]
        var deferred: [DeferredAction] = []
        var failure: (spoken: String, detail: String)?
        /// What the turn's screen looked like (the drawing's canvas, where guided targets are placed).
        var look: TurnScreenLook?
        /// Capture after the screen settles (the user just clicked a walkthrough's target).
        var settle = false
        /// The walkthrough's request this turn answers.
        var guided: GuidedTurnRequest?
        /// Already captured again once for this step.
        var refreshed = false
        /// The user's highlight (if any) was attached; before that, a voice turn that is cut off still owns it.
        var prepared = false
        /// A voice turn's screenshots, started at key-up so they are ready when the words are.
        var earlyLook: Task<TurnScreenLook, Never>?
        /// The output was muted or at zero, so the answer wasn't spoken.
        var unheard: OutputSilence?

        init(kind: TurnKind, generation: Int) {
            self.kind = kind
            self.generation = generation
            timings = TurnTimings(kind: kind)
        }

        var orderedLines: [String] { lines.keys.sorted().compactMap { lines[$0] } }
    }

    private func startTurn(kind: TurnKind, words: String, trigger: String?, notes: [String], guided: GuidedTurnRequest? = nil,
                           refreshed: Bool = false, reportNotes: [String] = [], reportAttempt: Int = 0) {
        generation += 1
        if kind == .guided { guidedSerial += 1 }
        let turn = ActiveTurn(kind: kind, generation: generation)
        turn.words = words
        turn.reportNotes = reportNotes
        turn.reportAttempt = reportAttempt
        turn.guided = guided
        turn.settle = guided?.settle ?? false
        turn.refreshed = refreshed
        turn.timings.sentAt = now()
        active = turn
        var fresh = TurnDisplay()
        fresh.kind = kind
        fresh.phase = .capturing
        fresh.words = words.isEmpty ? nil : words
        fresh.usingFallbackVoice = services.narrator?.isUsingFallback ?? false
        display = fresh
        turn.task = Task { [weak self] in
            await UsageContext.$current.withValue(.turn(.forTurn(kind))) { await self?.run(turn, isTyped: kind == .typed, trigger: trigger, notes: notes) }
        }
        log("\(kind.rawValue) turn: \(words.isEmpty ? (trigger ?? "") : words)")
    }

    private func isCurrent(_ turn: ActiveTurn) -> Bool { active === turn && turn.generation == generation }

    private func run(_ turn: ActiveTurn, isTyped: Bool, trigger: String?, notes: [String]) async {
        display.phase = .capturing
        let look: TurnScreenLook
        if let early = turn.earlyLook {
            look = await early.value
        } else {
            turn.timings.captureStartedAt = now()
            look = turn.settle ? await services.screen.lookAfterAction() : await services.screen.look()
            turn.timings.captureFinishedAt = now()
        }
        guard isCurrent(turn) else { return }
        turn.look = look
        var context = look.context
        if let trigger { context.trigger = trigger }
        // The drawing still on screen (what the last answer drew, as far as it got): the user's follow-up continues it,
        // so it can see and edit it. Turns that start a new drawing (a walkthrough step, a job report) aren't shown it.
        // It is shown on its own display's screenshot, which becomes the canvas even when the pointer is on another one.
        var canvasIndex: Int?
        if Self.continuesDrawing(turn.kind), context.drawingOnScreen == nil, let surfaces = services.drawings {
            let cursor = look.cursorScreenshot
            let order = look.screenshots.indices.sorted { a, b in
                (look.screenshots[a] == cursor ? 0 : 1, a) < (look.screenshots[b] == cursor ? 0 : 1, b)
            }
            for index in order {
                guard let drawn = surfaces.describeOnScreen(for: look.screenshots[index]) else { continue }
                context.drawingOnScreen = drawn
                if look.screenshots[index] != cursor {
                    canvasIndex = index
                    log("drawing: the drawing on screen \(index + 1) is this follow-up's canvas")
                }
                break
            }
        }
        // The walkthrough's notes (what the user just did, the steps so far) go ahead of the screen's own notes.
        var input = TurnInput(words: turn.words, isTyped: isTyped, screenshots: look.screenshots, context: context,
                              appNotes: turn.kind == .guided ? notes + look.appNotes : look.appNotes + notes)
        input.canvasIndex = canvasIndex
        if turn.kind == .voice || turn.kind == .typed {
            // What the user circled or underlined while holding the keys rides with their words.
            if let guidance = services.guidance {
                await guidance.prepare(&input, look: look)
                guard isCurrent(turn) else { return }
            }
            turn.prepared = true
            if let onUserWords, !turn.words.isEmpty {
                await onUserWords(turn.words)
                guard isCurrent(turn) else { return }
            }
        }
        // A cut-off note from the turn before goes in first.
        if let pending = outcomeNote { await pending.value }
        guard isCurrent(turn) else { return }
        turn.screenshot = BrainTurnNotes.canvasScreenshot(for: input)
        turn.canvasIndex = turn.screenshot.flatMap { look.screenshots.firstIndex(of: $0) }
        let sessionID = await services.sessions?.currentSessionID() ?? localSessionID
        guard isCurrent(turn) else { return }
        let canvas = turn.screenshot.map { HistoryCanvas(width: Double($0.pixelSize.width), height: Double($0.pixelSize.height)) }
        turn.log = TurnLogBuilder(input: input, sessionID: sessionID, source: Self.historySource(turn.kind), canvas: canvas,
                                  clock: services.clock)
        display.phase = .requesting
        if services.narrator != nil, turn.kind != .typed || settings.speaksTypedAnswers, let silence = services.output?.outputSilence() {
            // Nobody would hear it: answer with captions and the drawing, and hand the words over afterwards.
            turn.unheard = silence
            log("voice skipped: the output is \(silence == .muted ? "muted" : "at zero volume")")
        } else if let narrator = services.narrator, turn.kind != .typed || settings.speaksTypedAnswers {
            turn.speaks = true
            let clock = services.clock
            let generation = turn.generation
            turn.narration = narrator.begin(pacing: turn.pacing) { [weak self] event in
                let at = clock()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceEvent(event, at: at, generation: generation) } }
            }
            let player = narrator.player
            let pacer = NarrationPacer(policy: settings.narrationPacing, position: { player.position() },
                                       now: { clock().timeIntervalSinceReferenceDate })
            pacer.onBeat = { [weak self] beat in self?.log("pacing: \(beat)") }
            turn.pacer = pacer
            pacer.run()
        }
        turn.timings.requestStartedAt = now()
        do {
            for try await event in services.brain.run(input) {
                guard isCurrent(turn) else { break }
                handle(event, in: turn)
            }
        } catch {
            if isCurrent(turn), !(error is CancellationError) {
                handle(.failed(spoken: "Something went wrong with that answer. Try asking again.", detail: Self.describe(error)), in: turn)
            }
        }
        guard isCurrent(turn) else { return }
        turn.timings.brainFinishedAt = now()
        // A program short enough that its start never settled whether it names a screen.
        if !turn.drawingStarted, !turn.heldProgram.isEmpty {
            startDrawing(turn, DrawingScreenDirective.scan(turn.heldProgram, complete: true))
        }
        turn.drawing?.end()
        turn.narration?.close()
        if turn.narration.map({ !$0.snapshot().queued.isEmpty }) == true {
            display.phase = .speaking
        } else if turn.drawing?.isDrawing == true {
            display.phase = .drawing
        }
        let report = await turn.narration?.waitUntilDone()
        guard isCurrent(turn) else { return }
        turn.timings.narrationFinishedAt = now()
        turn.pacer?.finish()
        if let pacer = turn.pacer, pacer.spoken > 0 { log("pacing: \(pacer.spoken) word(s) heard") }
        // The voice is done (or never said a line the marks wait for: a program without say(), a line nothing could
        // speak): whatever the drawing still holds is drawn now rather than left waiting for a line that won't come.
        if turn.speaks, let drawing = turn.drawing, drawing.isDrawing {
            drawing.finishNow()
            log("drawing: the voice is done; drawing the rest now")
        }
        // Actions held for the narration (open a link, show a result) run now, in order.
        var results: [DeferredActionResult] = []
        var heldBackNote: String?
        for action in turn.deferred {
            guard isCurrent(turn) else { break }
            let result = await performResult(action)
            let succeeded = result.map(BrainToolResults.succeeded) ?? false
            if let note = result.flatMap(ConnectedAppsReadGuard.note(in:)) { heldBackNote = note }
            results.append(DeferredActionResult(action: action, succeeded: succeeded))
            log("deferred \(action.name): \(succeeded ? "done" : heldBackNote != nil ? "held back after a connected-apps read" : "failed")")
        }
        // A turn that read the user's apps doesn't act; say so, once, after the answer.
        if let heldBackNote, isCurrent(turn) {
            if turn.speaks, let narrator = services.narrator {
                let narration = narrator.begin()
                narration.say(0, heldBackNote)
                narration.close()
                _ = await narration.waitUntilDone()
            } else {
                display.notice = TurnNotice(.info, heldBackNote)
            }
        }
        guard isCurrent(turn) else { return }
        let outcome: NarrationOutcome = turn.failure.map { .failed($0.spoken) } ?? .completed
        if turn.kind == .report, turn.failure != nil || (turn.lines.isEmpty && turn.deferred.isEmpty) {
            reportDidNotLand(turn, failed: turn.failure != nil)
        }
        let unheard = turn.unheard.flatMap { silence -> UnheardReply? in
            let text = turn.orderedLines.joined(separator: " ")
            return text.isEmpty ? nil : UnheardReply(silence: silence, text: text, kind: turn.kind)
        }
        finish(turn, outcome: outcome, narration: report, deferred: results,
               notice: unheard.map { TurnNotice.unheard($0.silence, copied: true) }, unheard: unheard)
        answerFinished(turn)
    }

    /// Tells the walkthrough the answer is over once its drawing has released every mark (a target armed by the last
    /// beat counts). Skipped when another turn has started meanwhile: that turn's own answer reports instead.
    private func answerFinished(_ turn: ActiveTurn) {
        guard turn.kind != .report, let guidance = services.guidance else { return }
        let drawing = turn.drawing
        let serial = guidedSerial
        Task { [weak self] in
            if let drawing, let self { _ = await self.waitUntil(2) { !drawing.isDrawing } }
            guard let self, self.guidedSerial == serial, self.press == nil else { return }
            guidance.answerFinished()
        }
    }

    private func handle(_ event: TurnEvent, in turn: ActiveTurn) {
        turn.log?.apply(event)
        switch event {
        case .programDelta(let text):
            markFirstToken(turn)
            if turn.drawingStarted {
                turn.drawing?.append(text)
            } else {
                // Held until its start says which screen it draws on (`onScreen(n)` first, or not).
                turn.heldProgram += text
                let scan = DrawingScreenDirective.scan(turn.heldProgram)
                if scan != .undecided { startDrawing(turn, scan) }
            }
        case .sayLine(let index, let text):
            markFirstToken(turn)
            if turn.timings.firstLineAt == nil { turn.timings.firstLineAt = now() }
            ensureDrawing(turn)
            turn.lines[index] = text
            turn.pacer?.line(index, text)
            display.lines = turn.orderedLines
            if let narration = turn.narration {
                narration.say(index, text)
            } else {
                display.caption = text
                display.captionIndex = index
            }
        case .status(let text):
            display.status = text.isEmpty ? nil : text
        case .deferredAction(let action):
            turn.deferred.append(action)
        case .finished(let summary):
            turn.timings.modelFirstTokenSeconds = summary.firstTokenSeconds
            turn.timings.model = summary.model.isEmpty ? nil : summary.model
            turn.timings.usage = summary.usage
            turn.timings.requestBodyBytes = summary.requestBytes
            display.status = nil
        case .failed(let spoken, let detail):
            turn.failure = (spoken, detail)
            display.status = nil
            log("brain failed: \(detail)")
            // A report turn that fails is tried again (or shown another way) instead of telling the user to "ask again",
            // since they never asked.
            if turn.kind == .report { return }
            display.notice = TurnNotice(.error, spoken)
            services.cues?.play(.error)
            // Said aloud after whatever was already said.
            let index = (turn.lines.keys.max() ?? -1) + 1
            turn.lines[index] = spoken
            turn.pacer?.line(index, spoken)
            display.lines = turn.orderedLines
            if let narration = turn.narration {
                narration.say(index, spoken)
            } else {
                display.caption = spoken
                display.captionIndex = index
            }
        case .toolStarted, .toolFinished, .roundFinished:
            break
        }
    }

    private func markFirstToken(_ turn: ActiveTurn) {
        if turn.timings.firstTokenAt == nil { turn.timings.firstTokenAt = now() }
    }

    /// A line arrived: the drawing must be running by now (held program text decides its screen as it stands).
    @discardableResult
    private func ensureDrawing(_ turn: ActiveTurn) -> (any TurnDrawing)? {
        if turn.drawingStarted { return turn.drawing }
        let scan = DrawingScreenDirective.scan(turn.heldProgram)
        startDrawing(turn, scan == .undecided ? .none : scan)
        return turn.drawing
    }

    /// Starts the drawing with the program text held so far: on the screenshot `onScreen(n)` named, or on the turn's
    /// canvas (the screen under the pointer, or the one a follow-up's drawing is on), sized to that screenshot.
    private func startDrawing(_ turn: ActiveTurn, _ scan: DrawingScreenDirective.Scan) {
        guard !turn.drawingStarted else { return }
        let held = turn.heldProgram
        turn.heldProgram = ""
        if let drawing = beginDrawing(turn, scan), !held.isEmpty { drawing.append(held) }
    }

    private func beginDrawing(_ turn: ActiveTurn, _ scan: DrawingScreenDirective.Scan) -> (any TurnDrawing)? {
        if turn.drawingStarted { return turn.drawing }
        turn.drawingStarted = true
        guard let surfaces = services.drawings, var shot = turn.screenshot else { return nil }
        var number = (turn.canvasIndex ?? 0) + 1
        var elsewhere = false
        if case .screen(let wanted) = scan, let look = turn.look {
            if let chosen = DrawingScreenDirective.screenshot(wanted, in: look.screenshots) {
                elsewhere = chosen != shot
                shot = chosen
                number = wanted
                if elsewhere { log("drawing: onScreen(\(wanted)) draws on the \(chosen.label)") }
            } else {
                log("drawing: onScreen(\(wanted)) names no screenshot; drawing on screen \(number)")
            }
        }
        if turn.screenshot != shot {
            turn.log?.useCanvas(HistoryCanvas(width: Double(shot.pixelSize.width), height: Double(shot.pixelSize.height)))
        }
        turn.screenshot = shot
        let image = TurnImages.image(from: shot.jpeg)
        // The user's own follow-ups continue the drawing on screen; the walkthrough's and job reports' turns, and a
        // program that moves to another screen, start anew.
        guard let (drawing, keep) = Self.continuesDrawing(turn.kind) && !elsewhere ? surfaces.continuingDrawing(for: shot, image: image)
                : surfaces.drawing(for: shot, image: image).map({ ($0, false) }) else { return nil }
        // The answer's targets, tasks and manual steps arm the walkthrough as their lines are heard (on the pointer's
        // screen, where the walkthrough places them).
        if turn.kind != .report, let guidance = services.guidance, let look = turn.look, shot == look.cursorScreenshot {
            drawing.onMarks = guidance.answerStarted(on: look)
        }
        var options = TurnImages.beginOptions(for: shot, ink: settings.ink, pace: turn.speaks ? .speech : .now)
        options.keep = keep
        options.screen = number
        if keep { log("drawing: continuing the drawing on screen") }
        drawing.begin(options)
        turn.drawingBeganAt = now()
        turn.drawing = drawing
        turn.pacing.target = drawing
        turn.pacer?.drawing = drawing
        return drawing
    }

    private func voiceEvent(_ event: LineNarrator.Event, at: Date, generation: Int) {
        guard let turn = active, turn.generation == generation, isCurrent(turn) else { return }
        switch event {
        case .firstAudio:
            if turn.timings.firstAudioAt == nil { turn.timings.firstAudioAt = at }
        case .lineStarted(let index, _):
            turn.pacer?.lineStarted(index)
            turn.lineTimes[index] = (at, nil)
            if turn.timings.firstLineHeardAt == nil { turn.timings.firstLineHeardAt = at }
            display.phase = .speaking
            display.caption = turn.lines[index]
            display.captionIndex = index
        case .lineFinished(let index):
            turn.pacer?.lineFinished(index)
            turn.lineTimes[index]?.end = at
            if display.captionIndex == index, turn.lines[index + 1] == nil, turn.timings.brainFinishedAt != nil {
                display.caption = nil
                display.captionIndex = nil
            }
        case .fellBack:
            display.usingFallbackVoice = true
        case .drained:
            if turn.timings.brainFinishedAt != nil {
                display.caption = nil
                display.captionIndex = nil
            }
        case .lineCut, .reopened, .lineFailed:
            break
        }
        if case .reopened(let index, let reason) = event { log("voice reopened on line \(index): \(reason)") }
        if case .fellBack(let index, let reason) = event { log("voice fell back from line \(index): \(reason)") }
        if case .lineFailed(let index, let reason) = event { log("line \(index) not spoken: \(reason)") }
        onVoiceEvent?(event, at)
    }

    private func performResult(_ action: DeferredAction) async -> JSONValue? {
        guard let runner = services.deferred else { return nil }
        return await runner.performDeferred(action)
    }

    // MARK: - Ending turns

    /// Stops the press and the turn in progress and reports how far the narration got.
    private func interruptCurrent(_ reason: NarrationOutcome.Interruption) {
        if let press {
            cancelPress(press)
            self.press = nil
        }
        guard let turn = active else { return }
        generation += 1
        // A voice turn cut off before its highlight was attached: drop the ink's gesture (and put back the step).
        if turn.kind == .voice, !turn.prepared { services.guidance?.userTurnCancelled() }
        turn.task?.cancel()
        turn.earlyLook?.cancel()
        let report = turn.narration?.stop()
        // The pen is never left held on a drawing that stops here.
        turn.pacer?.finish()
        turn.drawing?.cancel()
        let outcome: NarrationOutcome
        if let report, !report.started.isEmpty {
            outcome = .cutOff(by: reason, heard: report.finished.count, cutLine: report.cutLine, total: turn.lines.count)
        } else if turn.timings.requestStartedAt != nil {
            outcome = .droppedBeforeFirstLine(reason)
        } else {
            outcome = .notStarted
        }
        if !turn.deferred.isEmpty { log("dropped \(turn.deferred.count) deferred action(s): a new turn started first") }
        finish(turn, outcome: outcome, narration: report,
               deferred: turn.deferred.map { DeferredActionResult(action: $0, succeeded: nil) })
    }

    private func finish(_ turn: ActiveTurn, outcome: NarrationOutcome, narration: NarrationReport? = nil,
                        deferred: [DeferredActionResult] = [], notice: TurnNotice? = nil, unheard: UnheardReply? = nil) {
        turn.timings.finishedAt = now()
        let history = turn.log?.finish(narration: outcome == .completed ? nil : outcome.label)
        var record = TurnRecord(kind: turn.kind, words: turn.words, history: history, timings: turn.timings,
                                narration: narration ?? turn.narration?.snapshot(), outcome: outcome, deferred: deferred,
                                notice: notice, failure: turn.failure, unheardReply: unheard)
        record.lesson = Self.lessonDraft(turn)
        if active === turn { active = nil }
        if let note = outcome.note(lines: turn.orderedLines) {
            let brain = services.brain
            let previous = outcomeNote
            outcomeNote = Task {
                await previous?.value
                await brain.recordOutcome(note)
            }
        }
        if turn.generation == generation {
            display.phase = .idle
            display.status = nil
            display.caption = nil
            display.captionIndex = nil
            if let notice { display.notice = notice }
        }
        log("turn finished: \(outcome.label)")
        onTurnFinished?(record)
        startQueuedReport()
    }

    /// Starts the reports that waited, once the loop is idle. Called wherever a press or turn ends (finished, brushed,
    /// stopped with Escape), so a report that arrived meanwhile is never left waiting for some later turn.
    private func startQueuedReport() {
        guard !isBusy, !holdsTurns, !reportQueue.isEmpty, !reportStartScheduled else { return }
        reportStartScheduled = true
        // Let the turn that just ended settle on screen first.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.reportStartScheduled = false
            // Busy (or held) again: whatever started ends through one of the paths above, which calls this again.
            guard !self.isBusy, !self.holdsTurns else { return }
            self.startReportTurn()
        }
    }

    // MARK: - Helpers

    private func now() -> Date { services.clock() }

    private func log(_ text: String) { onLog?(text) }

    /// What a saved lesson needs from a turn that drew: its screenshot and when each line was heard, in seconds after
    /// the drawing began.
    private static func lessonDraft(_ turn: ActiveTurn) -> DrawingLessonDraft? {
        guard turn.drawing != nil, let shot = turn.screenshot, let began = turn.drawingBeganAt else { return nil }
        let lines = turn.lines.keys.sorted().map { index -> DrawingLesson.Line in
            let heard = turn.lineTimes[index]
            let start = heard.map { max(0, $0.start.timeIntervalSince(began)) }
            let duration = heard.flatMap { times in times.end.map { max(0, $0.timeIntervalSince(times.start)) } }
            return DrawingLesson.Line(index: index, text: turn.lines[index] ?? "", start: start, duration: duration)
        }
        return DrawingLessonDraft(screenshot: shot, lines: lines)
    }

    /// Whether a turn of this kind continues the drawing on screen (the user's own questions) or starts a new one.
    private static func continuesDrawing(_ kind: TurnKind) -> Bool { kind == .voice || kind == .typed }

    private static func historySource(_ kind: TurnKind) -> HistoryTurnSource {
        switch kind {
        case .voice: .voice
        case .typed: .text
        case .report, .guided: .app
        }
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes; returns whether it held.
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline || Task.isCancelled { return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }
}

/// Forwards line starts and finishes to the drawing once it exists. Lines heard before the drawing began are held and
/// replayed in order. Called from the audio queue.
final class PacingRelay: SpeechPacing, @unchecked Sendable {
    private enum Call {
        case started(Int, TimeInterval?)
        case finished(Int)
    }

    private let lock = NSLock()
    private weak var _target: (any SpeechPacing)?
    private var held: [Call] = []

    var target: (any SpeechPacing)? {
        get { lock.withLock { _target } }
        set {
            let replay: [Call] = lock.withLock {
                _target = newValue
                defer { held.removeAll() }
                return newValue == nil ? [] : held
            }
            guard let newValue else { return }
            for call in replay {
                switch call {
                case .started(let index, let seconds): newValue.lineStarted(index, expectedDuration: seconds)
                case .finished(let index): newValue.lineFinished(index)
                }
            }
        }
    }

    func lineStarted(_ index: Int, expectedDuration: TimeInterval?) {
        let target: (any SpeechPacing)? = lock.withLock {
            if _target == nil { held.append(.started(index, expectedDuration)) }
            return _target
        }
        target?.lineStarted(index, expectedDuration: expectedDuration)
    }

    func lineFinished(_ index: Int) {
        let target: (any SpeechPacing)? = lock.withLock {
            if _target == nil { held.append(.finished(index)) }
            return _target
        }
        target?.lineFinished(index)
    }
}
