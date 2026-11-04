import Foundation

/// Turns raw key events into talk-key gestures: the voice key pressed and let go, the text key, a triple tap of the
/// text key (reserved for always-on voice), the dictation key, the hands-free key, and Escape. Pure and clock-free: the
/// app's event tap feeds it modifier changes and key presses with their timestamps, and calls `tick(at:)` when
/// `pendingDeadline` passes, so every gesture is tested without a keyboard.
///
/// Every slot may be a held chord or a double tap of one modifier (`TalkKeyTrigger.Kind`):
///
/// - Voice, held: the exact chord going down is `.voicePressed` (the mic opens at once). Letting go is
///   `.voiceReleased`, or `.voiceCancelled` when it was held less than `minimumHold` (a brush of the keys) or another
///   key was pressed in that time (a shortcut such as ⌃⌥→). Voice, double tap: the second clean tap is
///   `.voicePressed`, and the next clean tap of that key is `.voiceReleased`.
/// - Text, double tap: two clean taps of the modifier (pressed alone, released quickly) are `.textTrigger`. It waits
///   `tapGap` after the second tap in case a third comes, which makes `.alwaysOnToggle` instead. Text, held: pressing
///   the exact chord and letting go without another key in between is `.textTrigger`.
/// - Dictation, held: the chord's presses and releases, and other keys while it is held, are passed on as
///   `DictationEngagementMachine` inputs (that machine owns hold, hands-free and bounce rules). Dictation, double tap:
///   each double tap is `.dictation(.handsFreeToggle)`.
/// - Hands-free dictation: a double tap of its key, or a press of its chord, is `.dictation(.handsFreeToggle)` at once.
/// - A tap that overlaps typing, another modifier or a click doesn't count.
public struct TalkKeyGestureMachine: Sendable {
    public struct Timing: Sendable, Hashable {
        /// Shorter voice holds are brushes, not questions.
        public var minimumHold: TimeInterval
        /// The longest press that still counts as a tap.
        public var maxTapDuration: TimeInterval
        /// The longest pause between taps of one double or triple tap.
        public var tapGap: TimeInterval

        public init(minimumHold: TimeInterval = 0.18, maxTapDuration: TimeInterval = 0.3, tapGap: TimeInterval = 0.32) {
            self.minimumHold = minimumHold
            self.maxTapDuration = maxTapDuration
            self.tapGap = tapGap
        }
    }

    public enum Output: Sendable, Equatable {
        case voicePressed
        case voiceReleased(held: TimeInterval)
        case voiceCancelled
        case textTrigger
        case alwaysOnToggle
        case dictation(DictationEngagementMachine.Input)
        case escape
    }

    public var keys: TalkKeySettings
    public var timing: Timing
    /// When `tick(at:)` should be called next (a double tap waiting to see whether a third tap comes).
    public private(set) var pendingDeadline: TimeInterval?

    private var held: Set<DictationModifier> = []
    private var voiceDownAt: TimeInterval?
    private var dictationDown = false
    /// The tap key went down alone at this time and nothing else happened since.
    private var tapStartedAt: TimeInterval?
    /// End times of the taps in the current run.
    private var taps: [TimeInterval] = []
    /// Double taps of the other slots' keys (voice, dictation, hands-free), by slot. The talk-key rules refuse two
    /// slots on the same double tap.
    private var tapRuns: [TalkKeyAction: TapRun] = [:]
    /// Held chords that fire on release (text and hands-free set to a chord): when each went down, and whether another
    /// key spoiled the press.
    private var chordDownAt: [TalkKeyAction: TimeInterval] = [:]
    private var spoiledChords: Set<TalkKeyAction> = []

    private struct TapRun: Sendable {
        var startedAt: TimeInterval?
        var taps: [TimeInterval] = []
    }

    public init(keys: TalkKeySettings = .defaults, timing: Timing = Timing()) {
        self.keys = keys
        self.timing = timing
    }

    public var isVoiceHeld: Bool { voiceDownAt != nil }
    public var isDictationHeld: Bool { dictationDown }

    /// The single modifier whose double tap opens the text panel (and whose triple tap toggles always-on).
    private var tapKey: DictationModifier? {
        keys.text.kind == .doubleTap && keys.text.modifiers.count == 1 ? keys.text.modifiers.first : nil
    }

    /// The single modifier a slot (other than text) double-taps, if it is set to a double tap and doesn't share the
    /// text key.
    private func doubleTapKey(_ action: TalkKeyAction) -> DictationModifier? {
        guard action != .text, let trigger = keys[action], trigger.kind == .doubleTap, trigger.modifiers.count == 1,
              let key = trigger.modifiers.first, key != tapKey else { return nil }
        return key
    }

    /// The set of held modifiers changed.
    public mutating func modifiersChanged(_ now: Set<DictationModifier>, at time: TimeInterval) -> [Output] {
        let previous = held
        held = now
        var out: [Output] = []

        // Taps of the text key.
        if let key = tapKey {
            if previous.isEmpty, now == [key] {
                // A new tap begins. A waiting double tap whose gap has passed fires first.
                if let deadline = pendingDeadline, time > deadline { out += flushPending() }
                tapStartedAt = time
            } else if now.isEmpty, previous == [key], let start = tapStartedAt {
                tapStartedAt = nil
                if time - start <= timing.maxTapDuration {
                    if let last = taps.last, start - last > timing.tapGap {
                        out += flushPending()
                        taps = []
                    }
                    taps.append(time)
                    if taps.count >= 3 {
                        taps = []
                        pendingDeadline = nil
                        out.append(.alwaysOnToggle)
                    } else if taps.count == 2 {
                        pendingDeadline = time + timing.tapGap
                    }
                } else {
                    out += flushPending()
                    taps = []
                }
            } else if !now.isEmpty, now != [key] {
                // Another modifier joined: not a tap (a chord such as ⌃⌥ starts with ⌃ alone).
                tapStartedAt = nil
                out += flushPending()
                taps = []
            }
        }

        // Double taps of the other slots: the second clean tap fires at once (no triple tap to wait for).
        for action in [TalkKeyAction.voice, .dictation, .handsFreeDictation] {
            if let key = doubleTapKey(action) { out += doubleTapStep(action, key: key, previous: previous, now: now, at: time) }
        }

        // The voice chord.
        if keys.voice.kind == .hold {
            let voiceExact = now == keys.voice.modifiers
            if voiceExact, voiceDownAt == nil {
                voiceDownAt = time
                out.append(.voicePressed)
            } else if !voiceExact, let down = voiceDownAt {
                voiceDownAt = nil
                let heldFor = time - down
                out.append(heldFor < timing.minimumHold ? .voiceCancelled : .voiceReleased(held: heldFor))
            }
        }

        // The dictation chord.
        if keys.dictation.kind == .hold {
            let dictationExact = now == keys.dictation.modifiers
            if dictationExact, !dictationDown {
                dictationDown = true
                out.append(.dictation(.chordDown(at: time)))
            } else if !dictationExact, dictationDown {
                dictationDown = false
                out.append(.dictation(.chordUp(at: time)))
            }
        }

        // Chords that fire when pressed and let go: text and hands-free set to a held chord.
        for action in [TalkKeyAction.text, .handsFreeDictation] {
            out += chordPressStep(action, now: now, at: time)
        }
        return out
    }

    /// A non-modifier key went down.
    public mutating func keyDown(isEscape: Bool, at time: TimeInterval) -> [Output] {
        var out = flushPending()
        tapStartedAt = nil
        taps = []
        tapRuns = [:]
        spoiledChords.formUnion(chordDownAt.keys)
        if isEscape, keys.voice.kind == .doubleTap, voiceDownAt != nil {
            // Escape stops a tapped-on question; the next tap of the key starts a new one rather than ending this.
            voiceDownAt = nil
        }
        if keys.voice.kind == .hold, let down = voiceDownAt, time - down < timing.minimumHold {
            // Part of a shortcut that happens to start with the voice chord.
            voiceDownAt = nil
            out.append(.voiceCancelled)
        }
        // Dictation decides whether other keys matter (they do while it is held or locked on).
        if !isEscape { out.append(.dictation(.otherKey(at: time))) }
        if isEscape { out.append(.escape) }
        return out
    }

    /// The app's tapped-on question is over without the voice key ending it: the app ignored the press (always-on or
    /// dictation had the mic, turns were held) or stopped it another way (Escape, a typed question). With the voice key
    /// set to a double tap nothing physical tells the machine, so without this the next clean tap would end a question
    /// that no longer exists and the double tap after it would need a third tap. A held chord resyncs on its release,
    /// so this does nothing for it.
    public mutating func voicePressEnded() {
        guard keys.voice.kind == .doubleTap else { return }
        voiceDownAt = nil
    }

    /// A click or scroll: taps around it don't count.
    public mutating func otherActivity(at time: TimeInterval) -> [Output] {
        let out = flushPending()
        tapStartedAt = nil
        taps = []
        tapRuns = [:]
        return out
    }

    /// One modifier change for a slot set to a double tap. A clean tap is the key pressed alone and let go within
    /// `maxTapDuration`; two within `tapGap` of each other fire the slot. While a tapped-on question is open, the next
    /// clean tap of the voice key ends it.
    private mutating func doubleTapStep(_ action: TalkKeyAction, key: DictationModifier, previous: Set<DictationModifier>,
                                        now: Set<DictationModifier>, at time: TimeInterval) -> [Output] {
        var run = tapRuns[action] ?? TapRun()
        defer { tapRuns[action] = run }
        if previous.isEmpty, now == [key] {
            run.startedAt = time
        } else if now.isEmpty, previous == [key], let start = run.startedAt {
            run.startedAt = nil
            guard time - start <= timing.maxTapDuration else {
                run.taps = []
                return []
            }
            if action == .voice, let down = voiceDownAt {
                voiceDownAt = nil
                run.taps = []
                return [.voiceReleased(held: time - down)]
            }
            if let last = run.taps.last, start - last > timing.tapGap { run.taps = [] }
            run.taps.append(time)
            guard run.taps.count >= 2 else { return [] }
            run.taps = []
            switch action {
            case .voice:
                voiceDownAt = time
                return [.voicePressed]
            case .dictation, .handsFreeDictation:
                return [.dictation(.handsFreeToggle)]
            case .text:
                return []
            }
        } else if !now.isEmpty, now != [key] {
            run.startedAt = nil
            run.taps = []
        }
        return []
    }

    /// One modifier change for text or hands-free set to a held chord: the exact chord pressed, then let go (keys
    /// released, none added) with no other key in between, fires the slot.
    private mutating func chordPressStep(_ action: TalkKeyAction, now: Set<DictationModifier>, at time: TimeInterval) -> [Output] {
        guard let trigger = keys[action], trigger.kind == .hold else { return [] }
        let exact = now == trigger.modifiers
        if exact, chordDownAt[action] == nil {
            chordDownAt[action] = time
            spoiledChords.remove(action)
        } else if !exact, chordDownAt[action] != nil {
            chordDownAt[action] = nil
            let spoiled = spoiledChords.remove(action) != nil
            guard !spoiled, now.isSubset(of: trigger.modifiers) else { return [] }
            return [action == .text ? .textTrigger : .dictation(.handsFreeToggle)]
        }
        return []
    }

    /// Call when `pendingDeadline` passes: a waiting double tap becomes `.textTrigger`.
    public mutating func tick(at time: TimeInterval) -> [Output] {
        guard let deadline = pendingDeadline, time >= deadline else { return [] }
        return flushPending()
    }

    private mutating func flushPending() -> [Output] {
        guard pendingDeadline != nil else { return [] }
        pendingDeadline = nil
        taps = []
        return [.textTrigger]
    }
}
