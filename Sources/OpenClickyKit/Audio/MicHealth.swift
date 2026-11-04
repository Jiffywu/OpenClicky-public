import Foundation

/// Decides when live capture has gone dead. A microphone can open "successfully" and then deliver nothing (a stalled
/// device) or only digital zeros (a dead route, a muted aggregate, a revoked permission). Real rooms are never
/// digitally silent, so a whole window without a single audible chunk means the capture should be rebuilt; repeated
/// failures fail over to the built-in mic, and after that the problem is surfaced to the user.
///
/// Pure logic over timestamps; `MicrophoneCapture` feeds it chunks and asks for a verdict on a timer.
public struct MicHealthMonitor: Sendable, Hashable {
    public struct Policy: Sendable, Hashable {
        /// Seconds without an audible chunk before acting.
        public var silentWindow: TimeInterval = 2.5
        /// Peak amplitude (0…1) at or below which a chunk counts as digital silence. One LSB of 16-bit audio is
        /// about 3e-5; any live microphone's noise floor is well above 2 LSB.
        public var silenceThreshold: Float = 2.0 / 32768
        /// Rebuilds of the capture engine before failing over.
        public var maxRebuilds = 2
        /// Whether failing over to the built-in microphone is allowed.
        public var allowFailover = true

        public init() {}
    }

    public enum Problem: String, Sendable, Hashable {
        /// No chunks at all arrived in the window.
        case noAudio
        /// Chunks arrived but every one was digital silence.
        case allZeros
    }

    public enum Verdict: Sendable, Hashable {
        case rebuild(Problem)
        case failover(Problem)
        case irrecoverable(Problem)
    }

    public var policy: Policy
    private var windowStart: TimeInterval = 0
    private var lastChunk: TimeInterval?
    private var lastAudible: TimeInterval?
    public private(set) var rebuilds = 0
    public private(set) var failedOver = false
    public private(set) var gaveUp = false

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// A capture (or a rebuilt one) started at `now`.
    public mutating func started(at now: TimeInterval) {
        windowStart = now
        lastChunk = nil
        lastAudible = nil
    }

    /// A new press: forget earlier failures but keep a failover pin decision to the caller.
    public mutating func reset(at now: TimeInterval) {
        started(at: now)
        rebuilds = 0
        failedOver = false
        gaveUp = false
    }

    public mutating func observe(peak: Float, at now: TimeInterval) {
        lastChunk = now
        if peak > policy.silenceThreshold {
            lastAudible = now
            // Healthy audio again: later trouble starts a fresh ladder.
            rebuilds = 0
        }
    }

    /// What to do now, if anything. Each verdict also restarts the window.
    public mutating func check(at now: TimeInterval) -> Verdict? {
        guard !gaveUp else { return nil }
        let reference = max(lastAudible ?? windowStart, windowStart)
        guard now - reference >= policy.silentWindow else { return nil }
        let problem: Problem = (lastChunk.map { $0 > reference } ?? false) ? .allZeros : .noAudio
        windowStart = now
        if rebuilds < policy.maxRebuilds {
            rebuilds += 1
            return .rebuild(problem)
        }
        if policy.allowFailover && !failedOver {
            failedOver = true
            rebuilds = 0
            return .failover(problem)
        }
        gaveUp = true
        return .irrecoverable(problem)
    }
}

/// When the microphone is actually open. Bluetooth headsets switch to their call profile when their microphone opens
/// and back when it closes, which takes a second or more and degrades the audio both ways; so after a press on a
/// Bluetooth input the capture stays open with deliveries muted for a grace period, and a new press within it resumes
/// instantly.
public struct MicLifecycle: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case closed
        case capturing
        /// Open but muted until this time.
        case holding(until: TimeInterval)
    }

    public enum Action: Sendable, Hashable {
        /// Open the device and start delivering.
        case open
        /// Already open (held): start delivering again.
        case resume
        /// Stop delivering but keep the device open.
        case mute
        /// Close the device.
        case close
        case none
    }

    public private(set) var state: State = .closed
    /// Seconds to hold a Bluetooth input open after a press; 0 disables holding.
    public var bluetoothHold: TimeInterval

    public init(bluetoothHold: TimeInterval = 8) {
        self.bluetoothHold = bluetoothHold
    }

    public var isOpen: Bool { state != .closed }
    public var isDelivering: Bool { state == .capturing }

    public mutating func start() -> Action {
        switch state {
        case .closed:
            state = .capturing
            return .open
        case .holding:
            state = .capturing
            return .resume
        case .capturing:
            return .none
        }
    }

    public mutating func stop(at now: TimeInterval, inputIsBluetooth: Bool, allowHold: Bool = true) -> Action {
        guard state == .capturing else { return .none }
        if allowHold && inputIsBluetooth && bluetoothHold > 0 {
            state = .holding(until: now + bluetoothHold)
            return .mute
        }
        state = .closed
        return .close
    }

    /// Call periodically (or when the hold timer fires).
    public mutating func tick(at now: TimeInterval) -> Action {
        if case .holding(let until) = state, now >= until {
            state = .closed
            return .close
        }
        return .none
    }

    /// Close regardless of state.
    public mutating func close() -> Action {
        guard state != .closed else { return .none }
        state = .closed
        return .close
    }
}
