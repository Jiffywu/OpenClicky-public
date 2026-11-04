import CoreGraphics
import Foundation

// Draw-to-ask and guided walkthroughs around the voice loop's turns (docs/guided.md, docs/voice-loop.md). The turn
// orchestrator calls a `TurnGuiding` at fixed points of every user turn; the guide asks the orchestrator for turns of
// its own when the user clicks a walkthrough's target or finishes a manual step.

/// What a guide asks of the turn loop.
public enum TurnGuidanceRequest: Sendable, Hashable {
    /// Start the walkthrough's next turn by itself (`clicked_target` or `did_step`, with the walkthrough's notes).
    case turn(GuidedTurnRequest)
    /// The user kept going while that turn was being prepared: capture the screen again before answering.
    case refreshCapture
}

/// The pointing side of each turn: the highlighter ink drawn while the talk keys are held (draw-to-ask) and the guided
/// walkthrough whose targets the answers arm.
///
/// The orchestrator calls, in order:
///
///     userTurnStarted(voice:)   talk keys down (voice: the ink starts) or a typed question
///     pressEnded()              talk keys up; the press goes on to become a turn
///     userTurnCancelled()       the press came to nothing (a brushed chord, nothing heard, no speech connection)
///     prepare(&input, look:)    before the request: the highlight description and the inked screenshots
///     answerStarted(on:)        the answer's drawing begins; its marks arm targets, name the task, ask for manual steps
///     answerFinished()          the answer was heard and drawn: a walkthrough with no new step is complete
///     stopWalkthrough()         Escape
///
/// Report turns (job reports) never touch the guide.
@MainActor
public protocol TurnGuiding: AnyObject {
    /// Set by the orchestrator: turns the walkthrough starts by itself, and re-captures.
    var onRequest: ((TurnGuidanceRequest) -> Void)? { get set }
    /// The user started a turn of their own: talk keys down (`voice`) or a typed question. A step waiting for its
    /// click steps aside (it comes back if the turn comes to nothing).
    func userTurnStarted(voice: Bool)
    /// The talk keys went up and the press goes on to become a turn: the ink stops and waits for that turn.
    func pressEnded()
    /// The user's turn came to nothing: drop the ink and put back the step it interrupted.
    func userTurnCancelled()
    /// Just before the brain request of a user turn: attach what belongs to it (draw-to-ask's description and the
    /// screenshots with the ink drawn in).
    func prepare(_ input: inout TurnInput, look: TurnScreenLook) async
    /// The answer's drawing begins over `look`'s screen. The returned handler receives the marks it releases.
    func answerStarted(on look: TurnScreenLook) -> (([DrawingMark]) -> Void)?
    /// The answer was heard and drawn in full (or failed and said so).
    func answerFinished()
    /// Escape or the Stop menu item. Returns true when a walkthrough was running.
    @discardableResult
    func stopWalkthrough() -> Bool
    /// A walkthrough is under way (Escape stops it).
    var isWalkthroughActive: Bool { get }
    /// The walkthrough waits for an answer to give its next step (its own follow-up turn, or the user's turn), with no
    /// step armed.
    var isAwaitingNextStep: Bool { get }
}

/// The guide over a `GuidedWalkthroughController` and a `DrawToAskSession`, with no overlay of its own: `occtl turn`
/// and the tests use it directly, and the app's `PointingOverlayModel` wraps it with the live ink, the target ring and
/// the pointer monitor.
@MainActor
public final class TurnPointingGuide: TurnGuiding {
    public let guided: GuidedWalkthroughController
    public let drawToAsk: DrawToAskSession
    /// Flies the buddy pointer to armed targets and pointed-at controls (set its `pointer` to the app's buddy).
    public let buddy = BuddyGuidance()
    /// Where the pointer is, in AppKit global points (the ink starts there at key down).
    public var pointer: () -> CGPoint
    public var clock: () -> TimeInterval
    /// Every walkthrough effect, after the guide has acted on it (the app's overlay, `occtl turn`'s log).
    public var onEffect: ((GuidedEffect) -> Void)?
    public var onRequest: ((TurnGuidanceRequest) -> Void)?
    /// A gesture to use for the next user turn instead of what the pointer drew (a simulator: `occtl turn
    /// --highlight`, tests). Taken when the keys go up, or by the next typed question.
    public var scriptedGesture: HighlightGesture?
    /// How many user turns had a highlight attached (logs, tests).
    public private(set) var highlightsAttached = 0
    /// The last description attached to a turn.
    public private(set) var lastHighlight: HighlightDescription?

    public init(guided: GuidedWalkthroughController = GuidedWalkthroughController(), drawToAsk: DrawToAskSession = DrawToAskSession(),
                pointer: @escaping () -> CGPoint = { .zero }, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.guided = guided
        self.drawToAsk = drawToAsk
        self.pointer = pointer
        self.clock = clock
        guided.onEffect = { [weak self] effect in self?.handle(effect) }
    }

    private func handle(_ effect: GuidedEffect) {
        buddy.handle(effect)
        switch effect {
        case .startTurn(let request): onRequest?(.turn(request))
        case .refreshCapture: onRequest?(.refreshCapture)
        case .showTarget, .clearTarget, .ended: break
        }
        onEffect?(effect)
    }

    public func userTurnStarted(voice: Bool) {
        buddy.userTurnStarted()
        guided.userTurnStarted()
        if voice { drawToAsk.keyDown(at: pointer(), time: clock()) }
    }

    public func pressEnded() {
        drawToAsk.keyUp(time: clock())
        adoptScriptedGesture()
    }

    public func userTurnCancelled() {
        drawToAsk.cancel()
        guided.userTurnCancelled()
    }

    private func adoptScriptedGesture() {
        guard let gesture = scriptedGesture else { return }
        scriptedGesture = nil
        drawToAsk.adopt(gesture, time: clock())
    }

    public func prepare(_ input: inout TurnInput, look: TurnScreenLook) async {
        adoptScriptedGesture()
        guard drawToAsk.pending != nil else { return }
        let description = await drawToAsk.attach(to: &input, layout: look.layout ?? .current(), now: clock())
        if let description {
            highlightsAttached += 1
            lastHighlight = description
        }
    }

    public func answerStarted(on look: TurnScreenLook) -> (([DrawingMark]) -> Void)? {
        var screen = look.guidedScreen
        // The canvas screenshot rides along for grounding a target the element list and Accessibility can't place.
        if screen?.screenshot == nil { screen?.screenshot = look.cursorScreenshot?.jpeg }
        guided.screen = screen
        return { [weak self] marks in
            guard let self else { return }
            self.guided.apply(marks: marks)
            self.buddy.marksReleased(marks, screen: screen)
        }
    }

    public func answerFinished() { guided.answerFinished() }

    @discardableResult
    public func stopWalkthrough() -> Bool {
        // Escape and Stop also send away a buddy still pointing at a control from the answer.
        buddy.stop()
        // A first target still being grounded has armed nothing yet; its answer must not bring the buddy back.
        guided.cancelGrounding()
        guard guided.walkthrough.isActive else { return false }
        guided.stop()
        return true
    }

    public var isWalkthroughActive: Bool { guided.walkthrough.isActive }

    public var isAwaitingNextStep: Bool { guided.walkthrough.phase == .followingUp }
}
