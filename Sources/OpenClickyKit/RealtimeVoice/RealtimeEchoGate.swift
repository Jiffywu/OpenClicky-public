import Foundation

// Keeps the assistant from hearing itself (docs/re/02-voice-pipeline.md §8, "Always-on"). With headphones there is no
// echo and the provider's own voice activity detection handles barge-in. On speakers, the mic picks the reply back up,
// so while the assistant talks (and for a short ring-out after) the gate sends silence instead of the mic, and only
// opens when the user is clearly talking over it: enough loud, speech-like audio in a short window. Every committed
// user turn is also checked for real speech; a turn that was only silence or echo is dropped from the conversation.
//
// Pure value type with injected time, so the rules are tested without a microphone.

/// Where the assistant's voice comes out.
public enum AudioOutputRoute: String, Sendable, Hashable, Codable {
    case headphones
    case speakers
    case unknown

    /// The mic can hear the assistant on this route, so the echo gate has to work.
    public var leaksIntoMicrophone: Bool { self != .headphones }

    /// A best guess from the default output device. Bluetooth and USB audio devices are nearly always headsets; the
    /// built-in output is headphones only when its data source says so ("Headphones" vs "MacBook Air Speakers").
    public static func classify(transport: AudioDeviceTransport?, name: String?, dataSource: String? = nil) -> AudioOutputRoute {
        guard let transport else { return .unknown }
        let label = [name, dataSource].compactMap { $0?.lowercased() }.joined(separator: " ")
        if label.contains("headphone") || label.contains("headset") || label.contains("airpods") || label.contains("earbud") {
            return .headphones
        }
        switch transport {
        case .bluetooth, .bluetoothLE, .usb: return .headphones
        case .builtIn, .hdmi, .displayPort, .airPlay, .thunderbolt: return .speakers
        default: return .unknown
        }
    }

    public static func classify(_ device: AudioDeviceInfo?, dataSource: String? = nil) -> AudioOutputRoute {
        classify(transport: device?.transport, name: device?.name, dataSource: dataSource)
    }
}

public struct RealtimeEchoGate: Sendable {
    public struct Settings: Sendable, Hashable {
        /// A mic frame at or above this RMS level counts as speech-like.
        public var speechLevelDB: Float
        /// While the assistant talks on speakers, a frame must be at least this loud to count toward a barge-in.
        public var bargeInLevelDB: Float
        /// Loud, speech-like audio needed within `bargeInWindow` to open the gate over the assistant.
        public var bargeInSpeech: TimeInterval
        public var bargeInWindow: TimeInterval
        /// After the assistant stops, its voice can still ring in the room for this long.
        public var settleWindow: TimeInterval
        /// A committed user turn needs at least this much speech-like audio, or it's dropped as silence or echo.
        public var minimumTurnSpeech: TimeInterval
        /// Real audio kept from just before a barge-in, so the user's first word reaches the model.
        public var prefix: TimeInterval

        public init(speechLevelDB: Float = -45, bargeInLevelDB: Float = -32, bargeInSpeech: TimeInterval = 0.35,
                    bargeInWindow: TimeInterval = 0.8, settleWindow: TimeInterval = 0.5, minimumTurnSpeech: TimeInterval = 0.15,
                    prefix: TimeInterval = 0.3) {
            self.speechLevelDB = speechLevelDB
            self.bargeInLevelDB = bargeInLevelDB
            self.bargeInSpeech = bargeInSpeech
            self.bargeInWindow = bargeInWindow
            self.settleWindow = settleWindow
            self.minimumTurnSpeech = minimumTurnSpeech
            self.prefix = prefix
        }
    }

    public enum MicDecision: Sendable, Equatable {
        /// Send the frame as it is.
        case forward
        /// Send silence of the same length (keeps the provider's clock and VAD steady while the user isn't heard).
        case mute
        /// The user is talking over the assistant: stop the reply, send `prefix` and then this frame.
        case bargeIn(prefix: Data)
    }

    public enum CommitDecision: Sendable, Equatable {
        case keep
        case discard(reason: String)
    }

    public var settings: Settings
    public var route: AudioOutputRoute
    public private(set) var assistantSpeaking = false
    /// When the assistant last went quiet.
    private var quietSince: TimeInterval = -.infinity
    /// Recent frames while gated: (time, duration, loud).
    private var window: [(time: TimeInterval, duration: TimeInterval, loud: Bool)] = []
    private var prefixFrames: [(duration: TimeInterval, pcm: Data)] = []
    /// Speech-like audio the provider has heard since the last commit.
    public private(set) var turnSpeech: TimeInterval = 0

    public init(route: AudioOutputRoute, settings: Settings = Settings()) {
        self.route = route
        self.settings = settings
    }

    /// The mic is replaced with silence right now.
    public func isGated(at time: TimeInterval) -> Bool {
        route.leaksIntoMicrophone && (assistantSpeaking || time - quietSince < settings.settleWindow)
    }

    public mutating func assistantStartedSpeaking(at time: TimeInterval) {
        assistantSpeaking = true
    }

    /// The reply finished playing (or was stopped).
    public mutating func assistantStoppedSpeaking(at time: TimeInterval) {
        guard assistantSpeaking else { return }
        assistantSpeaking = false
        quietSince = time
    }

    /// Decides what to do with one mic frame (PCM16 mono in `format`) captured at `time`.
    public mutating func process(_ pcm: Data, format: PCMFormat, at time: TimeInterval) -> MicDecision {
        let duration = Double(pcm.count) / Double(max(format.bytesPerSecond, 1))
        let level = AudioLevel.measure(pcm16: pcm)
        let speechLike = level.rmsDB >= settings.speechLevelDB
        guard isGated(at: time) else {
            window.removeAll()
            prefixFrames.removeAll()
            if speechLike { turnSpeech += duration }
            return .forward
        }
        let loud = level.rmsDB >= settings.bargeInLevelDB
        window.append((time, duration, loud))
        window.removeAll { $0.time < time - settings.bargeInWindow }
        let loudSpeech = window.filter(\.loud).reduce(0) { $0 + $1.duration }
        if loudSpeech >= settings.bargeInSpeech {
            let prefix = prefixFrames.reduce(into: Data()) { $0.append($1.pcm) }
            turnSpeech += loudSpeech
            window.removeAll()
            prefixFrames.removeAll()
            assistantSpeaking = false
            quietSince = -.infinity
            return .bargeIn(prefix: prefix)
        }
        prefixFrames.append((duration, pcm))
        var kept = prefixFrames.reduce(0) { $0 + $1.duration }
        while kept > settings.prefix, let first = prefixFrames.first {
            kept -= first.duration
            prefixFrames.removeFirst()
        }
        return .mute
    }

    /// The provider committed a user turn: keep it only if real speech went into it. Starts counting the next turn.
    public mutating func evaluateCommit() -> CommitDecision {
        defer { turnSpeech = 0 }
        if turnSpeech < settings.minimumTurnSpeech {
            return .discard(reason: String(format: "only %.2f s of speech-like audio", turnSpeech))
        }
        return .keep
    }
}

/// Counts quick taps of one modifier key (press and release with no other key in between), for the triple-tap-Control
/// always-on toggle. The app feeds it flag changes and other key presses; it reports each completed tap's count, and
/// `settle(at:)` reports the final count once the sequence has gone quiet, so a double tap (type a question) and a
/// triple tap (always-on) on the same key can be told apart.
public struct ModifierTapCounter: Sendable, Hashable {
    /// Longest a key may be held and still count as a tap.
    public var maxHold: TimeInterval
    /// Longest gap between taps of one sequence.
    public var maxGap: TimeInterval

    public private(set) var count = 0
    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    public init(maxHold: TimeInterval = 0.3, maxGap: TimeInterval = 0.4) {
        self.maxHold = maxHold
        self.maxGap = maxGap
    }

    /// The modifier went down (alone).
    public mutating func keyDown(at time: TimeInterval) {
        if let last = lastTapAt, time - last > maxGap { count = 0 }
        downAt = time
    }

    /// The modifier came up. Returns the tap count so far when this was a tap, nil otherwise.
    @discardableResult
    public mutating func keyUp(at time: TimeInterval) -> Int? {
        defer { downAt = nil }
        guard let down = downAt, time - down <= maxHold else {
            reset()
            return nil
        }
        count += 1
        lastTapAt = time
        return count
    }

    /// Any other key, mouse button or modifier: the sequence is broken.
    public mutating func interrupted() { reset() }

    /// Once `maxGap` has passed since the last tap, the sequence's final count (then it starts over); nil while a
    /// sequence may still grow or when there was none.
    public mutating func settle(at time: TimeInterval) -> Int? {
        guard let last = lastTapAt, downAt == nil, time - last > maxGap, count > 0 else { return nil }
        defer { reset() }
        return count
    }

    public mutating func reset() {
        count = 0
        downAt = nil
        lastTapAt = nil
    }
}
