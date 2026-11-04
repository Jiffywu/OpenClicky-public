import CoreGraphics
import Foundation

/// What the notch shows of always-on voice: the controller's state and the conversation's (listening, hearing the
/// user, thinking, speaking), the words on both sides and a tool's status. Fed every `AlwaysOnUpdate`.
public struct AlwaysOnDisplay: Sendable, Hashable {
    public var state: AlwaysOnState = .off
    /// The conversation's state while a session runs (nil before its first update).
    public var voice: RealtimeVoiceState?
    /// What the user is saying, or said last.
    public var userCaption = ""
    /// What the voice has said so far of the current reply.
    public var assistantCaption = ""
    /// A tool's label while it runs ("Looking at your screen…").
    public var status: String?
    /// A dropped session is being reopened.
    public var reconnecting = false

    public init(state: AlwaysOnState = .off) { self.state = state }

    /// On, or starting.
    public var isActive: Bool { state.isActive }

    /// On and waiting for the user: nothing heard, nothing being prepared or said, no tool at work.
    public var isIdleListening: Bool {
        state == .on && !reconnecting && status == nil && (voice == nil || voice == .listening)
    }

    /// Escape would stop something: a reply being prepared or spoken, or a tool at work.
    public var canInterrupt: Bool {
        state == .on && (voice == .thinking || voice == .speaking || status != nil)
    }

    /// The end of the reply so far, for a caption: at most `limit` characters, starting at a word.
    public func replyTail(limit: Int = 180) -> String? {
        let text = assistantCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        let start = tail.firstIndex(where: \.isWhitespace).map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[start...]
    }

    /// What the notch pill says.
    public struct Notch: Sendable, Hashable {
        public enum Icon: Sendable, Hashable {
            /// Bars following the mic.
            case listening
            case working
            case speaking
        }

        public var title: String
        public var detail: String?
        public var icon: Icon
    }

    /// The notch pill's text while always-on runs (nil when it's off; refusals and failures are notices). `stopHint`
    /// says how to turn it off ("Triple-tap Control ends it").
    public func notch(stopHint: String?) -> Notch? {
        let heard = userCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .off, .refused, .failed:
            return nil
        case .starting:
            return reconnecting ? Notch(title: "Reconnecting always-on…", detail: nil, icon: .working)
                : Notch(title: "Starting always-on…", detail: stopHint, icon: .working)
        case .on:
            switch voice {
            case nil, .listening:
                return Notch(title: "Always-on · listening", detail: ["Just talk", stopHint].compactMap { $0 }.joined(separator: " · "),
                             icon: .listening)
            case .userSpeaking:
                return Notch(title: "Always-on · hearing you", detail: heard.isEmpty ? nil : heard, icon: .listening)
            case .thinking:
                return Notch(title: status ?? "Always-on · thinking…", detail: heard.isEmpty ? nil : heard, icon: .working)
            case .speaking:
                return Notch(title: status ?? "Always-on · speaking", detail: heard.isEmpty ? nil : heard, icon: .speaking)
            case .ended:
                return Notch(title: "Reconnecting always-on…", detail: nil, icon: .working)
            }
        }
    }

    public mutating func apply(_ update: AlwaysOnUpdate) {
        switch update {
        case .state(let new):
            state = new
            switch new {
            case .on:
                reconnecting = false
                if voice == nil || voice == .ended { voice = .listening }
            case .starting:
                break
            case .off, .refused, .failed:
                self = AlwaysOnDisplay(state: new)
            }
        case .reconnecting:
            reconnecting = true
            voice = nil
            status = nil
        case .conversation(let update):
            apply(update)
        }
    }

    private mutating func apply(_ update: RealtimeConversationUpdate) {
        switch update {
        case .state(let new):
            // A new user turn replaces the last exchange's words.
            if new == .userSpeaking, voice != .userSpeaking {
                userCaption = ""
                assistantCaption = ""
            }
            voice = new
            if new == .ended { status = nil }
        case .userCaption(let text, _):
            userCaption = text
        case .assistantCaption(let text):
            assistantCaption = text
        case .status(let label):
            status = label
        case .discardedTurn:
            userCaption = ""
        case .ended:
            voice = .ended
            status = nil
        case .tool, .bargeIn, .responseFinished, .deferredActionFailed, .warning:
            break
        }
    }
}

extension TalkKeyTrigger {
    /// "Triple-tap Control": the always-on toggle that comes with a double-tap text key (nil for any other text key).
    public var tripleTapPhrase: String? {
        guard kind == .doubleTap, modifiers.count == 1, let key = modifiers.first else { return nil }
        return "Triple-tap \(Self.name(key))"
    }
}

/// Always-on voice in the voice loop: triple-tap Control turns it on and off (`toggle()`), and while it runs the turn
/// orchestrator holds its turns, so the one-shot loop never listens or speaks over it. It shares the loop's mic
/// (`SharedMicrophone`) and voice (`SpeechPlayer`, through `SpeechPlayerRealtimeOutput`), with the conversation's echo
/// gate between them.
///
/// - Start: a turn still running is stopped first, turns are held, `willStart` runs (the app stops a walkthrough and
///   releases its narrator from the shared player), then a fresh `AlwaysOnVoiceController` opens a session on the
///   realtime-voice slot. Turns are released once always-on is off again, refused (no headphones) or failed.
/// - The talk keys interrupt it: their press stops the reply and any tools (barge-in) and starts no turn of its own;
///   the user just keeps talking. While it only listens (or hears the user) the press changes nothing.
/// - Escape stops a reply or tool the same way; with nothing to stop it passes on. Typed questions go into the
///   conversation and are answered aloud.
/// - Muted output: when a reply starts while the Mac is muted or at zero volume (`mutedGuard`), the reply is copied
///   to the clipboard once it is finished and `onUnheardReply` shows the same Unmute / Set volume notice push-to-talk
///   uses.
/// - A voice change (`voiceChanged()`) marks the session stale; it is replaced at the next pause.
@MainActor
public final class AlwaysOnVoiceLoop {
    public let orchestrator: TurnOrchestrator
    private let makeController: @MainActor () throws -> AlwaysOnVoiceController

    /// Runs just before a session opens, after the running turn was stopped and turns were held.
    public var willStart: (() -> Void)?
    /// Every change to what the notch shows.
    public var onDisplayChange: ((AlwaysOnDisplay) -> Void)?
    /// Every state the controller reports (the app turns refusals and failures into notices).
    public var onStateChange: ((AlwaysOnState) -> Void)?
    /// Every update from the running controller, in order (the app's `AlwaysOnRecorder` reads them).
    public var onUpdate: ((AlwaysOnUpdate) -> Void)?
    /// A typed question went into the conversation.
    public var onTyped: ((String) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Checks the output before always-on speaks, and copies a reply that went unheard (nil: never checked).
    public var mutedGuard: MutedOutputGuard?
    /// A reply went unheard: show this notice (it has the Unmute or Set volume button).
    public var onUnheardReply: ((AudioNotice) -> Void)?
    /// Why the reply now playing can't be heard, checked when it started to speak.
    private var unheardSilence: OutputSilence?

    public private(set) var display = AlwaysOnDisplay() {
        didSet { if display != oldValue { onDisplayChange?(display) } }
    }

    /// Whether the current (or last) run got as far as `.on`. A refusal or failure after that stopped always-on; one
    /// before it kept always-on from starting (the notices say which).
    public private(set) var reachedOn = false

    private var controller: AlwaysOnVoiceController?
    private var relay: Task<Void, Never>?
    /// Bumped for every controller, so updates from an older one are ignored.
    private var serial = 0

    /// `makeController` builds a controller for the current settings (the realtime-voice slot's client, the toolbox,
    /// the shared mic and voice); it throws when the slot can't be built, which is reported as `.failed`.
    public init(orchestrator: TurnOrchestrator, makeController: @escaping @MainActor () throws -> AlwaysOnVoiceController) {
        self.orchestrator = orchestrator
        self.makeController = makeController
    }

    /// On or starting.
    public var isActive: Bool { display.isActive }

    /// Triple-tap Control.
    public func toggle() {
        if isActive { stop() } else { start() }
    }

    public func start() {
        guard !isActive else { return }
        reachedOn = false
        if orchestrator.isBusy { orchestrator.interrupt() }
        orchestrator.holdsTurns = true
        willStart?()
        let controller: AlwaysOnVoiceController
        do {
            controller = try makeController()
        } catch {
            orchestrator.holdsTurns = false
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            log("always-on not started: \(reason)")
            report(.failed("Always-on voice can't start: \(reason)"))
            return
        }
        serial += 1
        let serial = serial
        self.controller = controller
        display = AlwaysOnDisplay(state: .starting)
        relay?.cancel()
        relay = Task { [weak self] in
            for await update in controller.updates {
                guard let self else { return }
                self.apply(update, serial: serial)
            }
        }
        log("always-on starting")
        Task { await controller.start() }
    }

    /// Turns it off (the state goes to `.off` once the session is closed; turns are released then).
    public func stop() {
        guard let controller else { return }
        log("always-on stopping")
        Task { await controller.stop() }
    }

    /// The talk keys went down. True when always-on took the press: no turn starts, and a reply or tool at work stops.
    /// With nothing to stop the press changes nothing, so words the user is already saying aren't thrown away.
    public func talkKeysPressed() -> Bool {
        guard isActive else { return false }
        if display.canInterrupt {
            log("talk keys: always-on reply interrupted")
            interruptReply()
        }
        return true
    }

    /// Escape. True when it stopped a reply or a tool.
    public func escape() -> Bool {
        guard display.canInterrupt else { return false }
        log("escape: always-on reply interrupted")
        interruptReply()
        return true
    }

    /// A typed question while always-on runs goes into the conversation and is answered aloud; one typed while the
    /// session is still opening (or reopening) goes in once it is on. False when always-on isn't running (the voice
    /// loop takes it).
    public func submitTyped(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !words.isEmpty else { return false }
        guard let controller else { return true }
        onTyped?(words)
        Task { [weak self] in
            if await !controller.addText(words, respond: true) { self?.log("typed question dropped: always-on ended") }
        }
        return true
    }

    /// A note for the running conversation that asks for no reply (a `[Skill update]`). Dropped when always-on is off:
    /// the next session's instructions carry the current state.
    public func addNote(_ text: String) {
        guard let controller, isActive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await controller.addText(text, respond: false) }
    }

    /// The voice settings changed: the running session is replaced, with the conversation carried over, at its next
    /// pause.
    public func voiceChanged() {
        guard let controller, isActive else { return }
        log("voice changed: always-on session marked stale")
        Task { await controller.voiceChanged() }
    }

    /// The default output device changed.
    public func outputRouteChanged() {
        guard let controller, isActive else { return }
        Task { await controller.outputRouteChanged() }
    }

    /// The echo-cancelling engine under the session came up deaf or died (`DuplexAudioRouter.captureEvent`).
    public func echoCancellationLost(_ reason: String) {
        guard let controller, isActive else { return }
        log("echo cancellation lost: \(reason)")
        Task { await controller.echoCancellationLost(reason) }
    }

    /// The notch's notice for a state always-on reported (nil while it starts or runs). `talkKeys` names the voice
    /// loop's keys ("⌃⌥"), `keyPhrase` how always-on is turned on ("Triple-tap Control"; nil: only the menu does).
    public func notice(for state: AlwaysOnState, talkKeys: String, keyPhrase: String?) -> TurnNotice? {
        let title = reachedOn ? "Always-on voice stopped." : "Always-on voice didn't start."
        switch state {
        case .starting, .on:
            return nil
        case .off:
            return TurnNotice(.info, "Always-on voice is off.",
                              detail: "Hold \(talkKeys) to talk. \(keyPhrase ?? "The menu") turns it back on.")
        case .refused(let why):
            return TurnNotice(.info, title, detail: why)
        case .failed(let why):
            return TurnNotice(.error, title, detail: why)
        }
    }

    private func interruptReply() {
        guard let controller else { return }
        Task { await controller.interrupt() }
    }

    private func apply(_ update: AlwaysOnUpdate, serial: Int) {
        guard serial == self.serial else { return }
        let wasSpeaking = display.voice == .speaking
        display.apply(update)
        onUpdate?(update)
        checkOutput(update, wasSpeaking: wasSpeaking)
        guard case .state(let state) = update else { return }
        log("always-on \(Self.describe(state))")
        if state == .on { reachedOn = true }
        onStateChange?(state)
        if !state.isActive { ended() }
    }

    /// Before a reply is heard, whether it can be: a muted or silent output means the finished reply is copied and the
    /// notice shown (the voice still plays, into the silent output, so the conversation carries on as usual).
    private func checkOutput(_ update: AlwaysOnUpdate, wasSpeaking: Bool) {
        guard let mutedGuard, case .conversation(let event) = update else { return }
        switch event {
        case .state(.speaking) where !wasSpeaking:
            if unheardSilence == nil, let silence = mutedGuard.outputSilence() {
                unheardSilence = silence
                log("always-on reply into a \(silence.rawValue) output")
            }
        case .responseFinished(let summary):
            guard let silence = unheardSilence else { return }
            let text = summary.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // A reply that only called a tool has nothing to copy yet; its follow-up reply carries the words.
            guard !text.isEmpty else { return }
            unheardSilence = nil
            if let notice = mutedGuard.replyWasUnheard(UnheardReply(silence: silence, text: text, kind: .voice)) {
                onUnheardReply?(notice)
            }
        case .bargeIn, .ended:
            unheardSilence = nil
        default:
            break
        }
    }

    /// Off, refused or failed: the voice loop gets its turns back.
    private func ended() {
        controller = nil
        relay?.cancel()
        relay = nil
        orchestrator.holdsTurns = false
    }

    private func report(_ state: AlwaysOnState) {
        display = AlwaysOnDisplay(state: state)
        onStateChange?(state)
    }

    private func log(_ text: String) { onLog?(text) }

    static func describe(_ state: AlwaysOnState) -> String {
        switch state {
        case .off: "off"
        case .starting: "starting"
        case .on: "on"
        case .refused(let why): "refused: \(why)"
        case .failed(let why): "failed: \(why)"
        }
    }
}

/// Shows what the brain draws for `send_to_higher_model` on the screenshot it was asked about.
///
/// The realtime voice says the answer in its own words, so there are no lines to start beats on. With `playback` set
/// (the shared player's position) the drawing is paced by the reply as it is heard: seconds of reply audio played
/// become a running word count (`TurnDrawing.wordsSpoken`), which starts the program's lines in turn, and whatever is
/// left is drawn once the reply has been heard (or none came). Without it the drawing appears at once.
///
/// Wrap the toolbox's screen source with `screen(_:)` (each capture becomes the canvas for the brain's next drawing)
/// and pass `observer` as the toolbox's `brainObserver`.
@MainActor
public final class RealtimeBrainDrawing {
    /// How the reply's playback paces the drawing.
    public struct Pacing: Sendable, Hashable {
        /// Speaking rate that turns seconds heard into words.
        public var wordsPerSecond: Double
        /// After the brain is done: draw the rest if no reply audio has started by then.
        public var replyTimeout: TimeInterval
        /// The reply counts as heard once playback has been idle this long.
        public var quietAfterReply: TimeInterval
        public var tickInterval: TimeInterval

        public init(wordsPerSecond: Double = 2.6, replyTimeout: TimeInterval = 6, quietAfterReply: TimeInterval = 0.6,
                    tickInterval: TimeInterval = 0.04) {
            self.wordsPerSecond = wordsPerSecond
            self.replyTimeout = replyTimeout
            self.quietAfterReply = quietAfterReply
            self.tickInterval = tickInterval
        }
    }

    private let surfaces: any TurnDrawingSurfaces
    private let ink: String
    private let latest = LockedValue<TurnScreenshot?>(nil)
    private var drawing: (any TurnDrawing)?
    /// The last drawing whose program has ended, while it may still be animating on screen.
    private weak var ending: (any TurnDrawing)?
    /// Where the shared player is in the line it plays (`SpeechPlayer.position()`); nil draws at once.
    public var playback: (() -> SpeechPlayer.Position?)?
    public var pacing: Pacing
    /// Words reported to the drawing being paced, in order (tests and logs).
    public private(set) var spokenCounts: [Int] = []
    public var onLog: ((String) -> Void)?
    private var paced: PacedReply?

    public init(surfaces: any TurnDrawingSurfaces, ink: String = "#3380FF", pacing: Pacing = Pacing()) {
        self.surfaces = surfaces
        self.ink = ink
        self.pacing = pacing
    }

    /// `source`, noting each capture as the canvas for the next drawing (and ending a drawing left open by a call
    /// that was cut short).
    public nonisolated func screen(_ source: any RealtimeScreenSource) -> any RealtimeScreenSource {
        CapturingScreen(source: source) { [weak self] shot in
            self?.latest.set(shot)
            Self.onMain { self?.newCapture() }
        }
    }

    /// `source`, noting the pointer's screenshot of each look as the canvas for the brain's next drawing.
    public nonisolated func look(_ source: any RealtimeBrainLooking) -> any RealtimeBrainLooking {
        CapturingLook(source: source) { [weak self] shot in
            self?.latest.set(shot)
            Self.onMain { self?.newCapture() }
        }
    }

    /// The brain's events, from any thread; handled on the main actor in order.
    public nonisolated var observer: @Sendable (TurnEvent) -> Void {
        { [weak self] event in
            switch event {
            case .programDelta, .finished, .failed: Self.onMain { self?.handle(event) }
            default: break
            }
        }
    }

    /// Whether a drawing is being played right now (a paced one until its reply has been heard).
    public var isDrawing: Bool { drawing != nil || paced != nil }

    /// A drawing is still arriving, still being paced by its reply, or still animating on screen: `capture_screen`
    /// takes no picture then.
    public var isPlaying: Bool { drawing != nil || paced != nil || ending?.isDrawing == true }

    func handle(_ event: TurnEvent) {
        switch event {
        case .programDelta(let delta):
            if drawing == nil {
                // Only a capture made for this request is a canvas; no picture, no drawing.
                guard let shot = latest.get() else { return }
                latest.set(nil)
                guard let fresh = surfaces.drawing(for: shot, image: TurnImages.image(from: shot.jpeg)) else { return }
                // The reply that follows is a new answer: a drawing still waiting for the last one is drawn out.
                settlePaced()
                fresh.begin(TurnImages.beginOptions(for: shot, ink: ink, pace: playback == nil ? .now : .speech))
                drawing = fresh
                if let playback { startPacing(fresh, playback: playback) }
            }
            drawing?.append(delta)
        case .finished:
            drawing?.end()
            ending = drawing
            paced?.brainDone(at: clock())
            drawing = nil
        case .failed:
            drawing?.cancel()
            drawing = nil
            stopPacing()
        default:
            break
        }
    }

    private func newCapture() {
        drawing?.end()
        drawing = nil
        settlePaced()
    }

    // MARK: Pacing by the reply's playback

    private final class PacedReply {
        let drawing: any TurnDrawing
        let startedAt: TimeInterval
        /// The player's line when the drawing began (a reply still playing then isn't this answer).
        let firstLine: Int?
        var currentLine: Int?
        var heardBefore: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var spoken = 0
        var brainDoneAt: TimeInterval?
        var lastAudioAt: TimeInterval?
        var ticker: Task<Void, Never>?

        init(drawing: any TurnDrawing, startedAt: TimeInterval, firstLine: Int?) {
            self.drawing = drawing
            self.startedAt = startedAt
            self.firstLine = firstLine
        }

        var heard: TimeInterval { heardBefore + elapsed }
        func brainDone(at time: TimeInterval) { if brainDoneAt == nil { brainDoneAt = time } }
    }

    private func clock() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func startPacing(_ drawing: any TurnDrawing, playback: @escaping () -> SpeechPlayer.Position?) {
        let reply = PacedReply(drawing: drawing, startedAt: clock(), firstLine: playback()?.lineIndex)
        paced = reply
        spokenCounts = []
        let interval = pacing.tickInterval
        reply.ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// Reads the playback once: reply audio heard becomes words; a reply heard out (or none at all) draws the rest.
    func tick() {
        guard let reply = paced, let playback else { return }
        let now = clock()
        if let at = playback(), at.lineIndex != reply.firstLine {
            if at.lineIndex != reply.currentLine {
                reply.heardBefore += reply.elapsed
                reply.elapsed = 0
                reply.currentLine = at.lineIndex
            }
            reply.elapsed = max(reply.elapsed, at.elapsed)
            reply.lastAudioAt = now
            let words = Int(reply.heard * pacing.wordsPerSecond)
            if words > reply.spoken {
                reply.spoken = words
                spokenCounts.append(words)
                reply.drawing.wordsSpoken(words)
            }
            return
        }
        // Nothing of this reply playing right now.
        if let last = reply.lastAudioAt, reply.brainDoneAt != nil, now - last >= pacing.quietAfterReply {
            finishPaced("the reply was heard")
        } else if reply.lastAudioAt == nil, let done = reply.brainDoneAt, now - done >= pacing.replyTimeout {
            finishPaced("no reply was heard")
        }
    }

    /// Draws what a paced drawing still holds and stops pacing it.
    private func settlePaced() {
        guard paced != nil else { return }
        finishPaced("a new answer began")
    }

    private func finishPaced(_ why: String) {
        guard let reply = paced else { return }
        reply.ticker?.cancel()
        paced = nil
        reply.drawing.finishNow()
        onLog?("always-on drawing: \(why); \(reply.spoken) word(s) paced it")
    }

    private func stopPacing() {
        paced?.ticker?.cancel()
        paced = nil
    }

    /// FIFO onto the main actor (a `Task` per event could reorder them).
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private struct CapturingScreen: RealtimeScreenSource {
        let source: any RealtimeScreenSource
        let captured: @Sendable (TurnScreenshot) -> Void

        func captureCursorScreen() async throws -> TurnScreenshot {
            let shot = try await source.captureCursorScreen()
            captured(shot)
            return shot
        }

        var displayCount: Int { source.displayCount }
    }

    private struct CapturingLook: RealtimeBrainLooking {
        let source: any RealtimeBrainLooking
        let captured: @Sendable (TurnScreenshot) -> Void

        func lookForBrain(includeScreen: Bool) async -> RealtimeBrainLook {
            let look = await source.lookForBrain(includeScreen: includeScreen)
            if let canvas = BrainTurnNotes.canvasScreenshot(look.screenshots) { captured(canvas) }
            return look
        }
    }
}
