import CoreGraphics
import Foundation

/// Why an app-started turn began (`TurnContext.trigger`).
public enum GuidedTrigger: String, Sendable, Hashable, Codable {
    /// The user clicked (or rested the pointer on) the control the last answer asked for.
    case clickedTarget = "clicked_target"
    /// The user did something on screen after a step the app can't watch (typing, dragging, scrolling) and paused.
    case didStep = "did_step"
}

/// Why a walkthrough stopped.
public enum GuidedEndReason: String, Sendable, Hashable {
    /// An answer gave no next step: the task is done.
    case completed
    /// The user pressed stop or Escape.
    case stopped
    /// The user clicked somewhere other than the target: they are doing something else (no nagging).
    case offTarget = "off_target"
    /// Nobody clicked for a long time.
    case expired
    /// The walkthrough used up its automatic steps.
    case maxRounds = "max_rounds"
    /// The user switched apps or Spaces while a target was waiting.
    case steppedAway = "stepped_away"
}

/// What the walkthrough watches: the user's pointer, keys and focus, in AppKit global points.
public enum GuidedInput: Sendable, Hashable {
    case mouseDown(CGPoint)
    case mouseMoved(CGPoint)
    /// The pointer moved with a button held (dragging a slider, a file, a selection): work on a manual step.
    case mouseDragged(CGPoint)
    case scroll
    case keyDown
    case appChanged(String?)
    case spaceChanged
    case escape
}

/// A turn the walkthrough wants started (the orchestrator's hook): capture the screen, then run the brain with
/// `TurnContext.trigger` set and these notes, and no words from the user.
public struct GuidedTurnRequest: Sendable, Hashable {
    public var trigger: GuidedTrigger
    /// Steps completed so far, this one included.
    public var step: Int
    /// Automatic steps left after this turn; at 0 the answer should finish with words only.
    public var remainingRounds: Int
    /// "[App] …" notes for the brain: what just happened and the walkthrough so far.
    public var notes: [String]
    public var targetLabel: String?
    /// Wait for the screen to settle before capturing (a click often opens a menu, a sheet or a page).
    public var settle: Bool

    public init(trigger: GuidedTrigger, step: Int, remainingRounds: Int, notes: [String], targetLabel: String? = nil, settle: Bool = true) {
        self.trigger = trigger
        self.step = step
        self.remainingRounds = remainingRounds
        self.notes = notes
        self.targetLabel = targetLabel
        self.settle = settle
    }

    /// Fill in an app-started turn: no words, the trigger, and the notes ahead of any others.
    public func apply(to input: inout TurnInput) {
        input.words = ""
        input.isTyped = false
        input.context.trigger = trigger.rawValue
        input.appNotes = notes + input.appNotes
    }
}

/// What the walkthrough asks the app to do.
public enum GuidedEffect: Sendable, Hashable {
    /// Ring the target (control outline when snapped) and wait.
    case showTarget(GuidedTarget)
    case clearTarget
    /// Start the next turn by itself.
    case startTurn(GuidedTurnRequest)
    /// The user kept going while the follow-up was being prepared: capture the screen again before answering, and
    /// tell the brain the new screenshot is the one to trust (`GuidedWalkthrough.freshnessNote`).
    case refreshCapture
    case ended(GuidedEndReason)
}

/// One line of the walkthrough's history, shown to the brain on follow-up turns.
public struct GuidedLogEntry: Sendable, Hashable {
    public var time: TimeInterval
    public var line: String
}

/// For the HUD: what the walkthrough is doing, its step counter, and whether there is something to stop.
public struct GuidedStatus: Sendable, Hashable {
    public var isActive: Bool
    public var task: String?
    /// The step the user is on (1-based).
    public var step: Int
    public var maxRounds: Int
    /// "Click Export", "Waiting for you", "Thinking about the next step"…
    public var caption: String
}

/// The guided-walkthrough state machine (03 §6.4, 02 §5.3 auto-advance). Pure and clock-driven: feed it inputs and
/// ticks with explicit times and act on the effects it returns. `GuidedWalkthroughController` runs it for the app.
///
///     idle ── arm ──▶ armed ── click on target / hover rest ──▶ followingUp (startTurn clicked_target)
///                       │── click elsewhere ──▶ ended(off_target)
///                       │── app or Space switch ──▶ ended(stepped_away)        ── lifetime ──▶ ended(expired)
///     idle ── manual ─▶ manual ── activity, then quiet ──▶ followingUp (startTurn did_step)
///     armed / manual ── the user's own turn ──▶ followingUp ── that turn is cancelled ──▶ back to armed / manual
///     followingUp ── the answer arms / asks for manual work ──▶ armed / manual
///                 ── the answer finishes with neither ──▶ ended(completed)
///                 ── no answer for `followUpLimit` ──▶ ended(expired)
///     any ── stop / Escape ──▶ ended(stopped)
public struct GuidedWalkthrough: Sendable {
    public struct Settings: Sendable, Hashable {
        /// Automatic follow-up turns in one walkthrough (HeyClicky gets its limit from the server; 03 §6.4).
        public var maxRounds: Int = 12
        /// How long a target waits for its click.
        public var targetLifetime: TimeInterval = 180
        /// How long the pointer must rest on a hover target.
        public var hoverRest: TimeInterval = 0.6
        /// Clicks and keys right after a hit belong to the hit (double clicks, a menu opening), not to a new step.
        public var grace: TimeInterval = 0.6
        /// A manual step waits this long for the user to start.
        public var manualWindow: TimeInterval = 120
        /// After the user's last action on a manual step, this much quiet means they are done.
        public var manualQuiet: TimeInterval = 1.2
        /// Points around a snapped control that still count as on it.
        public var hitSlop: CGFloat = 6
        /// A click elsewhere ends the walkthrough (HeyClicky: "no nag"). Off: such clicks are ignored.
        public var offTargetEnds: Bool = true
        /// A follow-up turn that never reports back (its answer failed, nobody called `answerFinished`) ends the
        /// walkthrough after this long instead of leaving it waiting forever.
        public var followUpLimit: TimeInterval = 120

        public init() {}
    }

    public enum Phase: Sendable, Hashable {
        case idle
        /// Waiting for a click on (or a rest over) the target.
        case armed
        /// Waiting for manual work the app can't watch.
        case manual
        /// A follow-up turn is being prepared or answered.
        case followingUp
        case ended(GuidedEndReason)
    }

    public var settings: Settings
    public private(set) var phase: Phase = .idle
    public private(set) var target: GuidedTarget?
    public private(set) var task: String?
    /// Steps completed in this walkthrough.
    public private(set) var completedSteps = 0
    /// Turns started by the walkthrough itself.
    public private(set) var automaticTurns = 0
    public private(set) var log: [GuidedLogEntry] = []
    /// What the current manual step asked for.
    public private(set) var manualNote: String?

    private var armedAt: TimeInterval = 0
    private var hoverSince: TimeInterval?
    private var graceUntil: TimeInterval = -.infinity
    private var manualSince: TimeInterval = 0
    private var lastActivity: TimeInterval?
    private var refreshed = false
    private var followUpSince: TimeInterval = 0
    /// What a user turn interrupted, kept until that turn is known to go ahead (`userTurnCancelled` restores it).
    private var suspended: (target: GuidedTarget?, manualNote: String?)?
    private static let askedInstead = "The user asked something instead of doing the step"

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// A walkthrough is under way (a step armed, manual work awaited, or a follow-up in flight).
    public var isActive: Bool {
        switch phase {
        case .armed, .manual, .followingUp: true
        case .idle, .ended: false
        }
    }

    public var remainingRounds: Int { max(0, settings.maxRounds - automaticTurns) }

    // MARK: What the brain asks for

    /// Name the how-to (`task()` in a drawing). Starts a new walkthrough when none is under way.
    public mutating func setTask(_ name: String) {
        if !isActive { reset() }
        task = name
    }

    /// Wait for the user to click (or hover) `target`. A walkthrough with no automatic steps left can't wait for a
    /// click that would start another turn, so it ends instead.
    public mutating func arm(_ target: GuidedTarget, at now: TimeInterval) -> [GuidedEffect] {
        if !isActive { reset(keepTask: true) }
        guard remainingRounds > 0 else { return end(.maxRounds, at: now) }
        suspended = nil
        self.target = target
        phase = .armed
        armedAt = now
        hoverSince = nil
        refreshed = false
        return [.showTarget(target)]
    }

    /// The user does the coming step by hand (`waitForUser()`): start the next turn once they have acted and paused.
    public mutating func expectManualStep(_ note: String? = nil, at now: TimeInterval) -> [GuidedEffect] {
        if !isActive { reset(keepTask: true) }
        let hadTarget = target != nil
        target = nil
        suspended = nil
        manualNote = note
        guard remainingRounds > 0 else { return (hadTarget ? [.clearTarget] : []) + end(.maxRounds, at: now) }
        phase = .manual
        manualSince = now
        lastActivity = nil
        refreshed = false
        return hadTarget ? [.clearTarget] : []
    }

    /// The user pressed the talk key (or typed a question): their turn replaces whatever was armed, but the
    /// walkthrough continues if the answer gives another step.
    public mutating func userTurnStarted(at now: TimeInterval) -> [GuidedEffect] {
        guard phase == .armed || phase == .manual else { return [] }
        let hadTarget = target != nil
        suspended = (target, phase == .manual ? manualNote : nil)
        target = nil
        phase = .followingUp
        followUpSince = now
        refreshed = true  // the user's own turn captures a fresh screen anyway
        record(Self.askedInstead, at: now)
        return hadTarget ? [.clearTarget] : []
    }

    /// The user's turn didn't go ahead (the talk keys were only brushed, nothing was heard): put back the step it
    /// interrupted, so a stray press neither loses the target nor leaves the walkthrough waiting for an answer.
    public mutating func userTurnCancelled(at now: TimeInterval) -> [GuidedEffect] {
        guard phase == .followingUp, let interrupted = suspended else { return [] }
        suspended = nil
        if log.last?.line == Self.askedInstead { log.removeLast() }
        refreshed = false
        if let target = interrupted.target {
            self.target = target
            phase = .armed
            armedAt = now
            hoverSince = nil
            return [.showTarget(target)]
        }
        phase = .manual
        manualNote = interrupted.manualNote
        manualSince = now
        lastActivity = nil
        return []
    }

    /// A turn's answer finished. If it armed no target and asked for no manual work, the walkthrough is complete.
    public mutating func answerFinished(at now: TimeInterval) -> [GuidedEffect] {
        guard phase == .followingUp else { return [] }
        return end(.completed, at: now)
    }

    public mutating func stop(_ reason: GuidedEndReason = .stopped, at now: TimeInterval) -> [GuidedEffect] {
        guard isActive else { return [] }
        return end(reason, at: now)
    }

    // MARK: What the user does

    public mutating func handle(_ input: GuidedInput, at now: TimeInterval) -> [GuidedEffect] {
        if input == .escape { return stop(.stopped, at: now) }
        switch phase {
        case .armed:
            guard let target else { return [] }
            switch input {
            case .mouseDown(let point):
                guard now >= graceUntil else { return [] }
                if target.contains(point, slop: settings.hitSlop) { return hit(target, hovered: false, at: now) }
                record("Clicked away from \(quoted(target.name)) instead", at: now)
                return settings.offTargetEnds ? end(.offTarget, at: now) : []
            case .mouseMoved(let point), .mouseDragged(let point):
                guard target.isHover else { return [] }
                if target.contains(point, slop: settings.hitSlop) { hoverSince = hoverSince ?? now } else { hoverSince = nil }
                return []
            case .appChanged, .spaceChanged:
                return end(.steppedAway, at: now)
            case .scroll, .keyDown, .escape:
                return []
            }
        case .manual:
            switch input {
            case .mouseDown, .mouseDragged, .scroll, .keyDown, .appChanged, .spaceChanged:
                lastActivity = now
            case .mouseMoved, .escape:
                break
            }
            return []
        case .followingUp:
            // The user kept going while the next step was being worked out: the screenshot may be stale.
            guard now >= graceUntil, !refreshed else { return [] }
            switch input {
            case .mouseDown, .mouseDragged, .scroll, .keyDown, .appChanged, .spaceChanged:
                refreshed = true
                return [.refreshCapture]
            case .mouseMoved, .escape:
                return []
            }
        case .idle, .ended:
            return []
        }
    }

    /// Time passes: hover rests complete, manual steps settle, targets and stalled follow-ups expire.
    public mutating func tick(at now: TimeInterval) -> [GuidedEffect] {
        switch phase {
        case .armed:
            guard let target else { return [] }
            if target.isHover, let since = hoverSince, now - since >= settings.hoverRest { return hit(target, hovered: true, at: now) }
            if now - armedAt >= settings.targetLifetime { return end(.expired, at: now) }
            return []
        case .manual:
            if let last = lastActivity {
                guard now - last >= settings.manualQuiet else { return [] }
                completedSteps += 1
                automaticTurns += 1
                record("Did the manual step\(manualNote.map { ": \($0)" } ?? "")", at: now)
                phase = .followingUp
                followUpSince = now
                graceUntil = now + settings.grace
                refreshed = false
                return [.startTurn(request(.didStep, label: nil))]
            }
            if now - manualSince >= settings.manualWindow { return end(.expired, at: now) }
            return []
        case .followingUp:
            return now - followUpSince >= settings.followUpLimit ? end(.expired, at: now) : []
        case .idle, .ended:
            return []
        }
    }

    // MARK: Status and notes

    public var status: GuidedStatus {
        let step = completedSteps + 1
        let caption: String
        switch phase {
        case .idle: caption = ""
        case .armed: caption = target.map { ($0.isHover ? "Point at " : "Click ") + ($0.name ?? "the highlighted control") } ?? ""
        case .manual: caption = manualNote ?? "Your turn: say “continue” when you're done"
        case .followingUp: caption = "Working out the next step"
        case .ended(let reason): caption = reason == .completed ? "Done" : ""
        }
        return GuidedStatus(isActive: isActive, task: task, step: step, maxRounds: settings.maxRounds, caption: caption)
    }

    /// For the turn after `.refreshCapture`.
    public static let freshnessNote = "[App] The user kept working while the next step was prepared, so the screenshot was taken again just now. Trust it over anything earlier."

    // MARK: Internals

    private mutating func hit(_ target: GuidedTarget, hovered: Bool, at now: TimeInterval) -> [GuidedEffect] {
        completedSteps += 1
        automaticTurns += 1
        record((hovered ? "Pointed at " : "Clicked ") + quoted(target.name), at: now)
        self.target = nil
        phase = .followingUp
        followUpSince = now
        graceUntil = now + settings.grace
        hoverSince = nil
        refreshed = false
        return [.clearTarget, .startTurn(request(.clickedTarget, label: target.name, hovered: hovered))]
    }

    private func request(_ trigger: GuidedTrigger, label: String?, hovered: Bool = false) -> GuidedTurnRequest {
        let walkthrough = task.map { "Guided walkthrough \"\($0)\"" } ?? "Guided walkthrough"
        var notes: [String] = []
        switch trigger {
        case .clickedTarget:
            notes.append("[App] \(walkthrough): the user \(hovered ? "rested the pointer on" : "clicked") \(quoted(label)), finishing step \(completedSteps). "
                + "This turn started on its own. Look at the new screenshot and give the next step, or say briefly that the task is done.")
        case .didStep:
            notes.append("[App] \(walkthrough): the user worked on step \(completedSteps) (a step the app can't watch) and then paused. "
                + "This turn started on its own. If the new screenshot shows the step done, give the next one; if not, help them finish it.")
        }
        let left = remainingRounds
        notes.append(left > 0
            ? "[App] \(left) more automatic step\(left == 1 ? "" : "s") can follow. Use one target() or waitForUser() per answer; leave both out when the task is done."
            : "[App] No automatic steps are left: finish in words, with no target() or waitForUser().")
        let history = log.suffix(10).enumerated().map { "\($0.offset + 1). \($0.element.line)" }
        if !history.isEmpty { notes.append("[App] The walkthrough so far, oldest first:\n" + history.joined(separator: "\n")) }
        return GuidedTurnRequest(trigger: trigger, step: completedSteps, remainingRounds: left, notes: notes, targetLabel: label)
    }

    private mutating func end(_ reason: GuidedEndReason, at now: TimeInterval) -> [GuidedEffect] {
        let hadTarget = target != nil
        target = nil
        suspended = nil
        hoverSince = nil
        lastActivity = nil
        phase = .ended(reason)
        record("Walkthrough ended: \(reason.rawValue.replacingOccurrences(of: "_", with: " "))", at: now)
        return (hadTarget ? [.clearTarget] : []) + [.ended(reason)]
    }

    private mutating func reset(keepTask: Bool = false) {
        let name = keepTask && phase == .idle ? task : nil
        phase = .idle
        target = nil
        task = name
        completedSteps = 0
        automaticTurns = 0
        log = []
        manualNote = nil
        hoverSince = nil
        lastActivity = nil
        graceUntil = -.infinity
        refreshed = false
        suspended = nil
    }

    private mutating func record(_ line: String, at now: TimeInterval) {
        log.append(GuidedLogEntry(time: now, line: line))
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    private func quoted(_ text: String?) -> String { text.map { "\"\($0)\"" } ?? "the highlighted control" }
}
