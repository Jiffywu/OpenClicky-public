import Foundation

// Microphone trouble, turned into something the user can act on (docs/audio-robustness.md). `MicrophoneCapture` already
// notices a dead mic (rebuild, fail over to the built-in mic, give up) and a consumer that falls behind; these types
// count dead-air presses, decide which of those deserve a notice, and say what the user can do about it.

/// A short notice about sound trouble with the buttons that fix it. The app shows it in a small clickable panel under
/// the notch; `turnNotice` is the same text for surfaces without buttons.
public struct AudioNotice: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// The capture engine is being rebuilt under a press (it delivered nothing, or only digital silence).
        case microphoneRebuilding
        /// The chosen mic went dead and capture moved to the built-in mic.
        case microphoneFailedOver
        /// Nothing left to try: the mic delivers no audio.
        case microphoneDead
        /// Several presses in a row heard nothing at all.
        case microphoneDeadAir
        /// Audio was dropped because the speech connection fell behind.
        case microphoneOverflow
        /// Microphone access is off for OpenClicky.
        case microphonePermission
        /// The reply wasn't played because the Mac is muted.
        case outputMuted
        /// The reply wasn't played because the volume is at zero.
        case outputZeroVolume
    }

    /// What a button on the notice does.
    public enum Action: Sendable, Hashable {
        /// OpenClicky's Settings, where the microphone is chosen.
        case microphoneSettings
        /// System Settings > Privacy & Security > Microphone.
        case microphonePrivacy
        /// System Settings > Sound.
        case soundSettings
        /// Turn the Mac's output mute off.
        case unmute
        /// Set the output volume to this fraction (0…1).
        case setVolume(Float)
        case dismiss

        public var label: String {
            switch self {
            case .microphoneSettings: "Microphone Settings"
            case .microphonePrivacy: "Open Privacy Settings"
            case .soundSettings: "Sound Settings"
            case .unmute: "Unmute"
            case .setVolume(let level): "Set volume to \(Int((min(max(level, 0), 1) * 100).rounded()))%"
            case .dismiss: "Dismiss"
            }
        }
    }

    public var kind: Kind
    public var tone: TurnNotice.Tone
    public var title: String
    public var detail: String?
    public var actions: [Action]
    /// Seconds the notice stays up unless the user acts on it.
    public var lifetime: TimeInterval

    public init(kind: Kind, tone: TurnNotice.Tone, title: String, detail: String? = nil, actions: [Action] = [],
                lifetime: TimeInterval = 8) {
        self.kind = kind
        self.tone = tone
        self.title = title
        self.detail = detail
        self.actions = actions
        self.lifetime = lifetime
    }

    public var id: String { "\(kind.rawValue):\(title)" }

    /// The same words for the notch pill (no buttons).
    public var turnNotice: TurnNotice { TurnNotice(tone, title, detail: detail) }

    /// One line for logs and `occtl`.
    public var summary: String {
        var line = "[\(tone.rawValue)] \(title)"
        if let detail { line += " — \(detail)" }
        if !actions.isEmpty { line += " [" + actions.map(\.label).joined(separator: " | ") + "]" }
        return line
    }
}

/// What one press's audio looked like, for dead-air counting: how long the keys were held, how many chunks came and
/// how many of them were above digital silence.
public struct MicPressSummary: Sendable, Hashable {
    /// Seconds from opening the mic to letting go.
    public var duration: TimeInterval
    public var chunks: Int
    /// Chunks whose peak was above digital silence.
    public var audibleChunks: Int
    /// Loudest sample of the press, 0…1.
    public var peak: Float

    public init(duration: TimeInterval, chunks: Int, audibleChunks: Int, peak: Float) {
        self.duration = duration
        self.chunks = chunks
        self.audibleChunks = audibleChunks
        self.peak = peak
    }

    /// Why the press was dead air, if it was: nothing arrived, or only digital zeros. Presses shorter than
    /// `minimumPress` never count (a tap ends before the mic has delivered anything).
    public func deadAir(minimumPress: TimeInterval) -> MicHealthMonitor.Problem? {
        guard duration >= minimumPress else { return nil }
        if chunks == 0 { return .noAudio }
        return audibleChunks == 0 ? .allZeros : nil
    }
}

/// Adds up one press's chunks into a `MicPressSummary`. Not thread-safe; its owner serializes.
public struct MicPressMeter: Sendable, Hashable {
    public var silenceThreshold: Float
    public private(set) var startedAt: TimeInterval
    public private(set) var chunks = 0
    public private(set) var audibleChunks = 0
    public private(set) var peak: Float = 0

    public init(startedAt: TimeInterval, silenceThreshold: Float = MicHealthMonitor.Policy().silenceThreshold) {
        self.startedAt = startedAt
        self.silenceThreshold = silenceThreshold
    }

    /// One PCM16 chunk.
    public mutating func add(pcm16: Data) {
        add(peak: AudioLevel.measure(pcm16: pcm16).peak)
    }

    public mutating func add(peak chunkPeak: Float) {
        chunks += 1
        if chunkPeak > silenceThreshold { audibleChunks += 1 }
        peak = max(peak, chunkPeak)
    }

    public func summary(endedAt: TimeInterval) -> MicPressSummary {
        MicPressSummary(duration: max(0, endedAt - startedAt), chunks: chunks, audibleChunks: audibleChunks, peak: peak)
    }
}

/// Which input the capture asks for: the user's choice, unless a dead mic made it fail over to the built-in one. A new
/// choice by the user drops the failover pin, so the mic they picked is tried again.
public struct MicInputPin: Sendable, Hashable {
    /// The user's choice (nil: the system default input).
    public private(set) var selected: String?
    /// The built-in mic, pinned after the chosen mic went dead.
    public private(set) var failover: String?

    public init(selected: String? = nil, failover: String? = nil) {
        self.selected = selected
        self.failover = failover
    }

    /// The input to open.
    public var effective: String? { failover ?? selected }
    public var isFailedOver: Bool { failover != nil }

    /// The user picked a mic (in Settings). Drops the failover pin. Returns whether the input to open changed.
    @discardableResult
    public mutating func select(_ uid: String?) -> Bool {
        let before = effective
        selected = uid
        failover = nil
        return effective != before
    }

    /// The chosen mic is dead: use `uid` (the built-in mic) until the user picks again.
    public mutating func failOver(to uid: String) {
        failover = uid
    }
}

/// Decides which microphone problems the user hears about. Feed it `MicrophoneCapture` events and one summary per
/// press; it returns a notice when one is due. Pure value type: the app owns one and tests drive it directly.
public struct MicTroubleTracker: Sendable, Hashable {
    public struct Policy: Sendable, Hashable {
        /// Dead-air presses in a row before the trouble notice.
        public var deadAirPresses: Int
        /// Presses shorter than this never count as dead air.
        public var minimumPress: TimeInterval
        /// Dropped chunks in one press before saying anything (a few are inaudible).
        public var overflowNoticeAt: Int

        public init(deadAirPresses: Int = 2, minimumPress: TimeInterval = 0.8, overflowNoticeAt: Int = 25) {
            self.deadAirPresses = deadAirPresses
            self.minimumPress = minimumPress
            self.overflowNoticeAt = overflowNoticeAt
        }
    }

    public var policy: Policy
    public private(set) var consecutiveDeadAir = 0
    /// The mic capture failed over to (cleared when the user picks a mic).
    public private(set) var failedOverTo: String?
    /// The device that went dead before the failover.
    public private(set) var failedOverFrom: String?
    private var overflowReported = false

    public init(policy: Policy = Policy()) { self.policy = policy }

    /// A press ended. Returns the dead-air notice once `deadAirPresses` presses in a row heard nothing.
    public mutating func pressEnded(_ summary: MicPressSummary) -> AudioNotice? {
        overflowReported = false
        guard summary.duration >= policy.minimumPress else { return nil }
        guard let problem = summary.deadAir(minimumPress: policy.minimumPress) else {
            consecutiveDeadAir = 0
            return nil
        }
        consecutiveDeadAir += 1
        guard consecutiveDeadAir >= policy.deadAirPresses else { return nil }
        let presses = consecutiveDeadAir
        let detail = switch problem {
        case .noAudio:
            "The last \(presses) times you held the keys, no sound came from the microphone. Check it's connected, or pick another one."
        case .allZeros:
            "The last \(presses) times you held the keys, the microphone sent only silence. Check it isn't muted, or pick another one."
        }
        return AudioNotice(kind: .microphoneDeadAir, tone: .warning, title: "Your microphone isn't picking anything up.",
                           detail: detail, actions: [.microphoneSettings, .soundSettings], lifetime: 12)
    }

    /// A capture event. Returns a notice when the user should know.
    public mutating func handle(_ event: MicrophoneCapture.Event) -> AudioNotice? {
        switch event {
        case .rebuilding(let problem):
            let detail = problem == .noAudio ? "It stopped sending audio." : "It was sending only silence."
            return AudioNotice(kind: .microphoneRebuilding, tone: .info, title: "Reconnecting the microphone…", detail: detail,
                               lifetime: 3)
        case .failedOver(let from, let to):
            failedOverFrom = from
            failedOverTo = to
            let lost = from.map { "\($0) stopped sending audio" } ?? "The microphone stopped sending audio"
            return AudioNotice(kind: .microphoneFailedOver, tone: .warning, title: "Switched to \(to).",
                               detail: "\(lost), so I'm listening with \(to) for now. Pick a microphone in Settings to try it again.",
                               actions: [.microphoneSettings], lifetime: 10)
        case .irrecoverable(let problem):
            let detail = problem == .noAudio
                ? "No audio is coming from it, even after reconnecting. Check it's plugged in, or pick another one."
                : "It sends only silence, even after reconnecting. Check its mute switch, or pick another one."
            return AudioNotice(kind: .microphoneDead, tone: .error, title: "The microphone isn't working.", detail: detail,
                               actions: [.microphoneSettings, .soundSettings], lifetime: 15)
        case .overflow(let dropped):
            guard !overflowReported, dropped >= policy.overflowNoticeAt else { return nil }
            overflowReported = true
            return AudioNotice(kind: .microphoneOverflow, tone: .warning, title: "Some of what you said was dropped.",
                               detail: "The speech connection fell behind the microphone. If I got it wrong, ask again.", lifetime: 6)
        case .failed(let message):
            return AudioNotice(kind: .microphoneDead, tone: .error, title: "The microphone stopped.", detail: message,
                               actions: [.microphoneSettings, .soundSettings], lifetime: 12)
        case .running, .routeChanged, .holdingBluetooth, .closed:
            return nil
        }
    }

    /// The user picked a microphone: start counting afresh and forget the failover.
    public mutating func microphoneChosen() {
        consecutiveDeadAir = 0
        failedOverTo = nil
        failedOverFrom = nil
        overflowReported = false
    }

    /// The notice for a mic that couldn't open because access is off (nil when access isn't the problem).
    public static func permissionNotice(_ authorization: MicrophoneCapture.Authorization) -> AudioNotice? {
        switch authorization {
        case .denied:
            return AudioNotice(kind: .microphonePermission, tone: .warning, title: "OpenClicky can't use the microphone.",
                               detail: "Microphone access is off. Turn on OpenClicky in Privacy & Security > Microphone.",
                               actions: [.microphonePrivacy], lifetime: 15)
        case .restricted:
            return AudioNotice(kind: .microphonePermission, tone: .warning, title: "The microphone is blocked on this Mac.",
                               detail: "A device policy doesn't allow microphone access.", lifetime: 10)
        case .authorized, .notDetermined:
            return nil
        }
    }
}

/// The voice loop's microphone trouble in one place: listens to the shared mic's capture events and per-press
/// summaries, keeps the tracker, and reports each notice due (on the main actor, in order). The app shows the notice
/// with its buttons; `occtl soundcheck mic` drives the same class with a scripted device.
@MainActor
public final class MicTroubleMonitor {
    public private(set) var tracker: MicTroubleTracker
    public let microphone: SharedMicrophone
    /// A notice the user should see.
    public var onNotice: ((AudioNotice) -> Void)?
    /// Every capture event, after the tracker saw it (the duplex router listens here too).
    public var onCaptureEvent: ((MicrophoneCapture.Event) -> Void)?
    public var onLog: ((String) -> Void)?

    public init(microphone: SharedMicrophone, policy: MicTroubleTracker.Policy = .init()) {
        self.microphone = microphone
        tracker = MicTroubleTracker(policy: policy)
    }

    /// Starts listening (replaces the shared mic's handlers).
    public func start() {
        microphone.onCaptureEvent = { [weak self] event in Self.onMain { self?.handle(event) } }
        microphone.onStreamEnded = { [weak self] user, summary in
            guard user == .turns else { return }
            Self.onMain { self?.pressEnded(summary) }
        }
    }

    public func stop() {
        microphone.onCaptureEvent = nil
        microphone.onStreamEnded = nil
    }

    /// The user picked a microphone in Settings: the capture drops its failover pin and the counts start over.
    public func microphoneChosen(uid: String?) {
        microphone.selectDevice(uid: uid)
        tracker.microphoneChosen()
        onLog?("microphone chosen: \(uid ?? "system default"); failover pin dropped")
    }

    public func handle(_ event: MicrophoneCapture.Event) {
        if let line = Self.describe(event) { onLog?(line) }
        if let notice = tracker.handle(event) { onNotice?(notice) }
        onCaptureEvent?(event)
    }

    public func pressEnded(_ summary: MicPressSummary) {
        if let problem = summary.deadAir(minimumPress: tracker.policy.minimumPress) {
            onLog?(String(format: "dead-air press (%@): %.1f s held, %d chunk(s), none audible", problem.rawValue, summary.duration, summary.chunks))
        }
        if let notice = tracker.pressEnded(summary) { onNotice?(notice) }
    }

    static func describe(_ event: MicrophoneCapture.Event) -> String? {
        switch event {
        case .rebuilding(let problem): "mic rebuilding (\(problem.rawValue))"
        case .failedOver(let from, let to): "mic failed over from \(from ?? "?") to \(to)"
        case .irrecoverable(let problem): "mic irrecoverable (\(problem.rawValue))"
        case .overflow(let dropped): "mic overflow: \(dropped) chunk(s) dropped"
        case .failed(let message): "mic failed: \(message)"
        case .routeChanged(let reason): "mic route changed: \(reason)"
        case .running, .holdingBluetooth, .closed: nil
        }
    }

    /// FIFO onto the main actor (a `Task` per event could reorder them).
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
