import AppKit
import OpenClickyKit
import os

/// Sound trouble and quiet moments for the voice loop (docs/audio-robustness.md):
///
/// - Microphone trouble: the shared mic's rebuild, failover, dead-mic and overflow events and dead-air presses become a
///   notice card with a Microphone Settings button; picking a mic in Settings drops the failover pin.
/// - Muted output: a reply into a muted or silent Mac is answered with captions, copied to the clipboard, and the card
///   offers Unmute or Set volume to 50% (the only place the volume is ever changed, and only on that click).
/// - Echo cancellation: before always-on runs on speakers, the duplex router probes the voice-processing engine (cached
///   per device combination) and moves the mic and the voice onto it; a deaf or dying engine is demoted.
/// - Quiet contexts: during a call, another app recording, or a Focus, job and routine reports, meeting countdowns and
///   the onboarding prompt wait until it's over.
@MainActor
final class AudioRobustness {
    let router: DuplexAudioRouter
    let mutedGuard: MutedOutputGuard
    let quiet: QuietHold
    private(set) var micTrouble: MicTroubleMonitor?
    private let panel = AudioNoticePanelController()
    private let log = Logger(subsystem: "app.openclicky", category: "audio")

    /// The echo-cancellation setting (Settings > Voice > Microphone).
    var echoSetting: EchoCancellationMode = .automatic
    /// The chosen input (nil: the system default).
    var microphoneUID: String?
    /// Opens OpenClicky's Settings where the microphone is chosen.
    var openMicrophoneSettings: (() -> Void)?
    /// The echo-cancelling engine came up deaf or died during always-on.
    var onEchoCancellationLost: ((String) -> Void)?
    /// Proactive items that waited for the quiet to end, to show now.
    var onRelease: (([ProactiveItem]) -> Void)?
    private var deliveries: [String: () -> Void] = [:]

    init(router: DuplexAudioRouter = DuplexAudioRouter(), mutedGuard: MutedOutputGuard = MutedOutputGuard(),
         quiet: QuietHold = QuietHold()) {
        self.router = router
        self.mutedGuard = mutedGuard
        self.quiet = quiet
        quiet.onRelease = { [weak self] items in
            guard let self else { return }
            var remaining: [ProactiveItem] = []
            for item in items {
                if let deliver = self.deliveries.removeValue(forKey: item.id) { deliver() }
                else { remaining.append(item) }
            }
            if !remaining.isEmpty { self.onRelease?(remaining) }
        }
        quiet.onDrop = { [weak self] items in
            for item in items { self?.deliveries[item.id] = nil }
        }
    }

    /// The overlay windows screen capture leaves out.
    var windowNumbers: [Int] { [panel.windowNumber].compactMap { $0 } }

    func start(microphone: SharedMicrophone) {
        startMicTrouble(microphone: microphone)
        quiet.monitor.sources.ownCaptureActive = { [microphone] in microphone.holder != nil }
        quiet.onLog = { [weak self] line in self?.log.info("\(line, privacy: .public)") }
        quiet.start()
    }

    /// Listens to the shared mic's trouble (also used alone by the Settings snapshot, which starts nothing else).
    func startMicTrouble(microphone: SharedMicrophone) {
        let monitor = MicTroubleMonitor(microphone: microphone)
        monitor.onNotice = { [weak self] notice in self?.show(notice) }
        monitor.onLog = { [weak self] line in self?.log.info("\(line, privacy: .public)") }
        monitor.onCaptureEvent = { [weak self] event in
            guard let self, self.router.captureEvent(event) else { return }
            let reason = "\(event)"
            self.log.error("echo cancellation demoted: \(reason, privacy: .public)")
            self.onEchoCancellationLost?(reason)
        }
        monitor.start()
        micTrouble = monitor
    }

    func stop() {
        micTrouble?.stop()
        quiet.stop()
        panel.hide()
    }

    // MARK: Notices

    func show(_ notice: AudioNotice) {
        log.info("notice: \(notice.summary, privacy: .public)")
        panel.show(notice) { [weak self] action in self?.perform(action) }
    }

    func perform(_ action: AudioNotice.Action) {
        switch action {
        case .microphoneSettings:
            openMicrophoneSettings?()
        case .microphonePrivacy:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .soundSettings:
            open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
        case .unmute, .setVolume:
            do {
                try mutedGuard.perform(action)
                log.info("output changed by the user: \(action.label, privacy: .public)")
            } catch {
                show(AudioNotice(kind: .outputMuted, tone: .warning, title: "I couldn't change the volume.",
                                 detail: "\(error) Use the volume keys or Control Center instead.", actions: [.soundSettings], lifetime: 8))
            }
        case .dismiss:
            break
        }
    }

    private func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// A turn ended. True when it showed a card (so the notch pill's own notice can stay quiet).
    func turnFinished(_ record: TurnRecord) -> Bool {
        if let unheard = record.unheardReply, let notice = mutedGuard.replyWasUnheard(unheard) {
            show(notice)
            return true
        }
        if record.notice?.title == TurnNotice.microphoneUnavailable("").title,
           let notice = MicTroubleTracker.permissionNotice(MicrophoneCapture.authorization) {
            show(notice)
            return true
        }
        return false
    }

    /// The user picked a microphone in Settings (the same one again too: that retries it after a failover).
    func microphoneChosen(uid: String?) {
        microphoneUID = uid
        micTrouble?.microphoneChosen(uid: uid)
    }

    /// Capture is pinned to the built-in mic after the chosen one went dead: (from, to) names for Settings.
    var failover: (from: String?, to: String)? {
        guard let tracker = micTrouble?.tracker, let to = tracker.failedOverTo else { return nil }
        return (tracker.failedOverFrom, to)
    }

    // MARK: Always-on and echo cancellation

    /// Before always-on runs on a route that leaks into the mic.
    func prepareAlwaysOn(route: AudioOutputRoute) async -> AlwaysOnRoutePlan {
        let decision = await router.prepare(route: route, setting: echoSetting, inputUID: microphoneUID)
        log.info("always-on echo cancellation: \(decision.summary, privacy: .public)")
        return decision.mode == .echoCancelled ? .echoCancelled : .plain
    }

    /// Always-on is off, refused or failed: the mic and voice go back to their own engines.
    func alwaysOnEnded() { router.release() }

    // MARK: Quiet

    /// Whether a proactive item may show now; held ones come back through `onRelease`.
    func offer(_ item: ProactiveItem, deliver: @escaping () -> Void) {
        switch quiet.offer(item) {
        case .deliver:
            deliveries[item.id] = nil
            deliver()
        case .hold: deliveries[item.id] = deliver
        case .drop: withdraw(item.id)
        }
    }

    func withdraw(_ id: String) {
        deliveries[id] = nil
        quiet.withdraw(id)
    }

    func offer(_ item: ProactiveItem) -> Bool {
        switch quiet.offer(item) {
        case .deliver: return true
        case .hold, .drop: return false
        }
    }
}
