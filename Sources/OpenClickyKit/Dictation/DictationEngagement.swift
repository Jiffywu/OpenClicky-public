import Foundation

/// How the user is holding dictation open.
public enum DictationEngagement: String, Sendable, Equatable {
    case idle
    /// Dictating while the chord is held; releasing it finishes.
    case holding
    /// Locked on by a double tap; the next tap finishes.
    case handsFreeLocked
}

/// Turns chord presses and releases into dictation actions. Pure and clock-free: callers pass timestamps and
/// deliver the timers it asks for, so every gesture can be tested exactly.
///
/// - Hold: press, speak, release. Releases shorter than `minimumHold` are taps.
/// - Hands-free: tap, then press again within `doubleTapWindow`. Dictation stays on after letting go; the next
///   press finishes it (its release is swallowed).
/// - A single stray tap is discarded once the double-tap window passes.
/// - Key bounce: a release followed by a press within `bounceGrace` is ignored and the hold continues.
/// - Pressing another key during the first moments of a hold means the user is typing a shortcut: discard.
public struct DictationEngagementMachine: Sendable {
    public struct Timing: Sendable, Equatable {
        public var minimumHold: TimeInterval
        public var doubleTapWindow: TimeInterval
        public var bounceGrace: TimeInterval

        public init(minimumHold: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.4, bounceGrace: TimeInterval = 0.06) {
            self.minimumHold = minimumHold
            self.doubleTapWindow = doubleTapWindow
            self.bounceGrace = bounceGrace
        }
    }

    public enum Timer: String, Sendable, Hashable {
        case bounce, doubleTap
    }

    public enum Input: Sendable, Equatable {
        case chordDown(at: TimeInterval)
        case chordUp(at: TimeInterval)
        /// A non-modifier key went down while dictation was engaged.
        case otherKey(at: TimeInterval)
        /// A dedicated hands-free shortcut fired.
        case handsFreeToggle
        case timerFired(Timer)
        /// Escape or an explicit cancel.
        case cancel
    }

    public enum Effect: Sendable, Equatable {
        /// Start listening (capture focus, open the mic and the speech session).
        case startCapture
        /// Stop listening and type the result.
        case commit
        /// Stop listening and throw the audio away.
        case discard
        case engagementChanged(DictationEngagement)
        case schedule(Timer, after: TimeInterval)
        case cancelTimer(Timer)
    }

    private enum Phase: Sendable, Equatable {
        case idle(swallowRelease: Bool)
        case pressed(since: TimeInterval)
        case releasePending(since: TimeInterval)
        case awaitingSecondTap
        case locked(ignoreRelease: Bool)
    }

    public var timing: Timing
    /// When false, quick taps never lock dictation on; they are discarded.
    public var allowsDoubleTapLock: Bool
    private var phase: Phase = .idle(swallowRelease: false)

    public init(timing: Timing = Timing(), allowsDoubleTapLock: Bool = true) {
        self.timing = timing
        self.allowsDoubleTapLock = allowsDoubleTapLock
    }

    public var engagement: DictationEngagement {
        switch phase {
        case .idle: .idle
        case .pressed, .releasePending, .awaitingSecondTap: .holding
        case .locked: .handsFreeLocked
        }
    }

    public var isCapturing: Bool { engagement != .idle }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch (phase, input) {
        // Idle
        case (.idle, .chordDown(let t)):
            phase = .pressed(since: t)
            return [.startCapture, .engagementChanged(.holding)]
        case (.idle, .handsFreeToggle):
            phase = .locked(ignoreRelease: false)
            return [.startCapture, .engagementChanged(.handsFreeLocked)]
        case (.idle(true), .chordUp):
            phase = .idle(swallowRelease: false)
            return []

        // Holding
        case (.pressed(let since), .chordUp(let t)):
            if t - since >= timing.minimumHold {
                phase = .releasePending(since: since)
                return [.schedule(.bounce, after: timing.bounceGrace)]
            }
            guard allowsDoubleTapLock else { return finish(.discard) }
            phase = .awaitingSecondTap
            return [.schedule(.doubleTap, after: timing.doubleTapWindow)]
        case (.pressed(let since), .otherKey(let t)):
            return t - since < timing.minimumHold ? finish(.discard) : []
        case (.pressed, .handsFreeToggle):
            phase = .locked(ignoreRelease: true)
            return [.engagementChanged(.handsFreeLocked)]
        case (.pressed, .cancel):
            return finish(.discard)

        // Released after a real hold; waiting out key bounce
        case (.releasePending(let since), .chordDown):
            phase = .pressed(since: since)
            return [.cancelTimer(.bounce)]
        case (.releasePending, .timerFired(.bounce)):
            return finish(.commit)
        case (.releasePending, .cancel):
            return [.cancelTimer(.bounce)] + finish(.discard)

        // One quick tap so far
        case (.awaitingSecondTap, .chordDown):
            phase = .locked(ignoreRelease: true)
            return [.cancelTimer(.doubleTap), .engagementChanged(.handsFreeLocked)]
        case (.awaitingSecondTap, .timerFired(.doubleTap)):
            return finish(.discard)
        case (.awaitingSecondTap, .otherKey), (.awaitingSecondTap, .cancel):
            return [.cancelTimer(.doubleTap)] + finish(.discard)
        case (.awaitingSecondTap, .handsFreeToggle):
            phase = .locked(ignoreRelease: false)
            return [.cancelTimer(.doubleTap), .engagementChanged(.handsFreeLocked)]

        // Hands-free
        case (.locked(true), .chordUp):
            phase = .locked(ignoreRelease: false)
            return []
        case (.locked, .chordDown):
            phase = .idle(swallowRelease: true)
            return [.commit, .engagementChanged(.idle)]
        case (.locked, .handsFreeToggle):
            return finish(.commit)
        case (.locked, .cancel):
            return finish(.discard)

        default:
            return []
        }
    }

    private mutating func finish(_ effect: Effect) -> [Effect] {
        phase = .idle(swallowRelease: false)
        return [effect, .engagementChanged(.idle)]
    }
}
