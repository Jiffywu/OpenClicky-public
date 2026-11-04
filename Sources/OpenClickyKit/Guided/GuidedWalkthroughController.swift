import CoreGraphics
import Foundation

/// A guided-step marker from a drawing (`Resources/js/guided-api.js`, docs/dsl-guided.md).
public enum GuidedMarker: Sendable, Hashable {
    case task(String)
    case target(GuidedTargetRequest)
    case wait(String?)

    /// The marker a released drawing mark carries, or nil for ordinary marks. Boxes are in canvas units, which are
    /// the pixels of the screenshot the brain saw.
    public init?(mark: DrawingMark) {
        let json = mark.json
        switch mark.kind {
        case "task":
            guard let label = json["label"]?.stringValue, !label.isEmpty else { return nil }
            self = .task(label)
        case "wait":
            self = .wait(json["note"]?.stringValue)
        case "target", "hover":
            let label = json["label"]?.stringValue
            let instruction = json["instruction"]?.stringValue ?? json["say"]?.stringValue
            let place: GuidedTargetRequest.Place
            if let element = json["element"]?.stringValue {
                place = .element(element)
            } else if let ring = json["ring"]?.doubleValue, let at = json["at"]?.arrayValue, at.count == 2,
                      let x = at[0].doubleValue, let y = at[1].doubleValue {
                place = .pixelRing(center: CGPoint(x: x, y: y), radius: CGFloat(ring))
            } else if let box = json["box"]?.arrayValue, box.count == 4, let x = box[0].doubleValue, let y = box[1].doubleValue,
                      let w = box[2].doubleValue, let h = box[3].doubleValue {
                place = .pixelRect(CGRect(x: x, y: y, width: w, height: h))
            } else {
                return nil
            }
            self = .target(GuidedTargetRequest(place, label: label, instruction: instruction, isHover: mark.kind == "hover"))
        default:
            return nil
        }
    }
}

/// Runs a guided walkthrough for the app: places what the brain asks for on the screen (snapped to real controls),
/// watches the pointer, keys and focus it is handed, keeps time, and asks the orchestrator for the next turn.
///
/// The orchestrator's side of the loop:
///
///     guided.onTurnRequest = { request in           // a click on the target, or a manual step done
///         var input = TurnInput(words: "", screenshots: …, context: …)
///         request.apply(to: &input)                   // trigger "clicked_target" / "did_step" and the notes
///         startTurn(input, settle: request.settle)
///     }
///     guided.screen = GuidedScreen(look: look)        // before each answer's drawing starts
///     session.onMarks = { guided.apply(marks: $0) }   // targets arm when their line is heard
///     // key-down: guided.userTurnStarted()  · press cancelled / nothing heard: guided.userTurnCancelled()
///     // answer finished: guided.answerFinished()  · Esc: guided.stop()
///
/// The app's pointer monitor calls `handle(_:)`; its overlay draws `onEffect`'s `.showTarget` / `.clearTarget`.
@MainActor
public final class GuidedWalkthroughController {
    public private(set) var walkthrough: GuidedWalkthrough
    /// The screen the current answer is about. Set it before feeding that answer's drawing marks.
    public var screen: GuidedScreen?
    /// Asks Accessibility what is under a point when the element list has nothing near the brain's box.
    public var locator: (any GuidedElementLocating)?
    /// The last resort (03 §6.8): asks a computer-use model where the target is on the screenshot, when the brain named
    /// an element the list doesn't have, or when neither the list nor `locator` found a control at its box. Nil: off.
    public var grounding: (any GuidedTargetGrounding)?
    /// One line per grounding attempt (logs, tests).
    public var onGroundingLog: ((String) -> Void)?
    /// Bundle identifiers whose activation is not "stepping away" (OpenClicky itself).
    public var ownBundleIdentifiers: Set<String> = []
    /// Show or clear the target, the walkthrough ended, a re-capture is needed.
    public var onEffect: ((GuidedEffect) -> Void)?
    /// The orchestrator's hook: start the next turn with this trigger and these notes.
    public var onTurnRequest: ((GuidedTurnRequest) -> Void)?
    /// Every effect, in order (logs, the simulator, tests).
    public private(set) var history: [(time: TimeInterval, effect: GuidedEffect)] = []

    private let clock: () -> TimeInterval
    private let tickInterval: TimeInterval
    private var ticker: Task<Void, Never>?
    private var nextID = 1
    private var streamContinuations: [UUID: AsyncStream<GuidedTurnRequest>.Continuation] = [:]
    /// Grounding requests in flight, by serial; a newer request, the user's own turn or a stop makes older ones stale.
    private var groundingTasks: [Int: Task<Void, Never>] = [:]
    private var groundingSerial = 0
    /// The answer finished while a target was still being grounded: finish it once grounding is done.
    private var answerFinishPending = false
    /// The grounding request in flight (the newest one).
    private var currentGrounding: (request: GuidedTargetRequest, screen: GuidedScreen, armed: GuidedTarget?, serial: Int)?
    /// Grounding a talk-key press cut off after its answer had finished: asked again if that press comes to nothing.
    private var interruptedGrounding: (request: GuidedTargetRequest, screen: GuidedScreen, armed: GuidedTarget?)?
    /// Counts walkthrough endings, so a grounding answer can tell "ended before I was asked" (arm restarts it) from
    /// "ended while I was out" (drop the answer).
    private var endings = 0
    /// Grounding answers handled so far, stale ones included (tests).
    private(set) var groundingAnswers = 0

    public init(settings: GuidedWalkthrough.Settings = .init(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                locator: (any GuidedElementLocating)? = nil, tickInterval: TimeInterval = 0.05) {
        self.walkthrough = GuidedWalkthrough(settings: settings)
        self.clock = clock
        self.locator = locator
        self.tickInterval = tickInterval
    }

    /// Turn requests as an async sequence, for orchestrators that prefer to loop.
    public func turnRequests() -> AsyncStream<GuidedTurnRequest> {
        let id = UUID()
        return AsyncStream { continuation in
            streamContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.streamContinuations[id] = nil } }
        }
    }

    public var status: GuidedStatus { walkthrough.status }
    public var target: GuidedTarget? { walkthrough.target }

    // MARK: From the brain

    /// Guided markers from released drawing marks (wire `DrawingSession.onMarks` here).
    public func apply(marks: [DrawingMark]) {
        for marker in marks.compactMap(GuidedMarker.init(mark:)) { apply(marker) }
    }

    public func apply(_ marker: GuidedMarker) {
        switch marker {
        case .task(let name): walkthrough.setTask(name)
        case .target(let request):
            let screen = self.screen
            dropGrounding()
            let endingsBefore = endings
            let armed = arm(request)
            // The walkthrough had no automatic rounds left, so arming ended it (`.maxRounds`). Grounding the target
            // would arm it again later, which starts the walkthrough over with a fresh round count.
            guard endings == endingsBefore else { return }
            if let screen, armed == nil || armed?.snap == GuidedSnap.Reason.none { ground(request, on: screen, replacing: armed) }
        case .wait(let note):
            dropGrounding()
            dispatch(walkthrough.expectManualStep(note, at: clock()))
        }
    }

    // MARK: Grounding

    /// Asks `grounding` where `request` is. A request that couldn't be placed at all is armed when the answer comes;
    /// an unsnapped target moves only when the grounded point lies outside the brain's box (they disagree, and the
    /// grounding model looked for the control itself).
    private func ground(_ request: GuidedTargetRequest, on screen: GuidedScreen, replacing armed: GuidedTarget?) {
        guard let grounding, screen.screenshot != nil, let question = Self.question(for: request) else { return }
        groundingSerial += 1
        let serial = groundingSerial
        let endingsAtStart = endings
        currentGrounding = (request, screen, armed, serial)
        onGroundingLog?("grounding \"\(question)\"" + (armed == nil ? " (the brain's element isn't on screen)" : " (no control at the brain's box)"))
        let task = Task { [weak self] in
            let found = await grounding.locate(question, on: screen)
            guard let self else { return }
            self.groundingTasks[serial] = nil
            self.finishGrounding(found, request: request, screen: screen, replacing: armed, serial: serial, endingsAtStart: endingsAtStart)
        }
        groundingTasks[serial] = task
    }

    private func finishGrounding(_ found: GroundingResult?, request: GuidedTargetRequest, screen: GuidedScreen, replacing armed: GuidedTarget?,
                                 serial: Int, endingsAtStart: Int) {
        groundingAnswers += 1
        defer {
            if groundingTasks.isEmpty, answerFinishPending {
                answerFinishPending = false
                dispatch(walkthrough.answerFinished(at: clock()))
            }
        }
        // Stale: a newer step, the user's own turn, or a stop came first.
        guard serial == groundingSerial else { return }
        guard let found, let point = found.point else {
            if case .noElement(let text) = found { onGroundingLog?("grounding found no element: \(text)") } else { onGroundingLog?("grounding failed") }
            return
        }
        if let armed {
            guard walkthrough.phase == .armed, walkthrough.target?.id == armed.id else { return }
            guard !armed.requestedFrame.insetBy(dx: -4, dy: -4).contains(point) else {
                onGroundingLog?("grounding agrees with the brain's box; kept it")
                return
            }
        } else if walkthrough.phase == .armed || walkthrough.phase == .manual || endings != endingsAtStart {
            // Something else was armed meanwhile, or the walkthrough ended while grounding was out. One that had
            // already ended before this answer named its target starts again, as an ordinary target would.
            return
        }
        let radius: CGFloat = 16
        var placed = request
        placed.place = .globalRect(CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        guard var target = screen.target(for: placed, id: nextID, locator: locator, minimumRadius: 28) else { return }
        if target.element == nil { target.snap = .grounded }
        nextID += 1
        onGroundingLog?("grounding placed \"\(target.name ?? "target")\" at (\(Int(point.x)), \(Int(point.y)))" + (target.element.map { ", on \($0.id)" } ?? ""))
        dispatch(walkthrough.arm(target, at: clock()))
    }

    /// What to ask the grounding model for a request: its sentence, else "Click <label>".
    static func question(for request: GuidedTargetRequest) -> String? {
        if let instruction = request.instruction?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty { return instruction }
        guard let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return (request.isHover ? "Point at " : "Click ") + label
    }

    /// Forget grounding in flight without ending anything (Escape or Stop before the first target armed). True when a
    /// request was in flight.
    @discardableResult
    public func cancelGrounding() -> Bool {
        let wasGrounding = !groundingTasks.isEmpty
        dropGrounding()
        return wasGrounding
    }

    /// Forget grounding in flight (a new step, the user's own turn, a stop).
    private func dropGrounding() {
        groundingSerial += 1
        for task in groundingTasks.values { task.cancel() }
        groundingTasks.removeAll()
        answerFinishPending = false
        currentGrounding = nil
        interruptedGrounding = nil
    }

    /// Waits until no grounding is in flight (tests, the simulator).
    public func groundingSettled() async {
        while let task = groundingTasks.values.first { await task.value }
    }

    public var isGrounding: Bool { !groundingTasks.isEmpty }

    /// Waits until `count` grounding answers have been handled, stale ones included (tests: a dropped request is no
    /// longer in flight, but its answer still comes back).
    func groundingAnswersHandled(_ count: Int) async {
        for _ in 0..<10_000 where groundingAnswers < count { await Task.yield() }
    }

    /// Place `request` on `screen` (snapping it to a control) and wait for it. Returns the target, or nil when the
    /// request names an element the screen doesn't have.
    @discardableResult
    public func arm(_ request: GuidedTargetRequest, on screen: GuidedScreen? = nil) -> GuidedTarget? {
        guard let screen = screen ?? self.screen,
              let target = screen.target(for: request, id: nextID, locator: locator, minimumRadius: 28) else { return nil }
        nextID += 1
        dispatch(walkthrough.arm(target, at: clock()))
        return walkthrough.target
    }

    /// Wait for a click on a target already placed in global points (tests, the simulator, the classic tag grammar).
    public func arm(_ target: GuidedTarget) {
        dispatch(walkthrough.arm(target, at: clock()))
    }

    // MARK: From the user and the orchestrator

    public func handle(_ input: GuidedInput) {
        if case .appChanged(let bundle) = input, let bundle, ownBundleIdentifiers.contains(bundle) { return }
        dispatch(walkthrough.handle(input, at: clock()))
    }

    /// The user started a turn of their own (talk key, typed question).
    public func userTurnStarted() {
        // An answer that already finished was only waiting for its target to be grounded. Nothing else would ask
        // for that step again if this press comes to nothing, so remember the request.
        let held = answerFinishPending ? currentGrounding.flatMap { groundingTasks[$0.serial] == nil ? nil : $0 } : nil
        dropGrounding()
        interruptedGrounding = held.map { ($0.request, $0.screen, $0.armed) }
        dispatch(walkthrough.userTurnStarted(at: clock()))
    }

    /// That turn didn't go ahead (a brushed talk key, nothing heard): the interrupted step comes back, and so does
    /// grounding the press cut off.
    public func userTurnCancelled() {
        let interrupted = interruptedGrounding
        interruptedGrounding = nil
        dispatch(walkthrough.userTurnCancelled(at: clock()))
        guard let interrupted else { return }
        ground(interrupted.request, on: interrupted.screen, replacing: interrupted.armed)
        if isGrounding { answerFinishPending = true } else { answerFinished() }
    }

    /// The current answer's narration and drawing are done. While its target is still being grounded, the walkthrough
    /// waits for that before deciding the answer gave no next step.
    public func answerFinished() {
        interruptedGrounding = nil
        if !groundingTasks.isEmpty {
            answerFinishPending = true
            return
        }
        dispatch(walkthrough.answerFinished(at: clock()))
    }

    public func stop() {
        dropGrounding()
        dispatch(walkthrough.stop(.stopped, at: clock()))
    }

    /// Advance time by hand (tests and the simulator); the controller also ticks itself while a walkthrough is active.
    public func tick() { dispatch(walkthrough.tick(at: clock())) }

    // MARK: Effects

    private func dispatch(_ effects: [GuidedEffect]) {
        let now = clock()
        for effect in effects {
            history.append((now, effect))
            if case .ended = effect { endings += 1 }
            if history.count > 500 { history.removeFirst(history.count - 500) }
            if case .startTurn(let request) = effect {
                onTurnRequest?(request)
                for continuation in streamContinuations.values { continuation.yield(request) }
            }
            onEffect?(effect)
        }
        updateTicker()
    }

    private func updateTicker() {
        // Follow-ups tick too, so one whose answer never comes expires (`Settings.followUpLimit`).
        let waiting = walkthrough.isActive
        if waiting, ticker == nil {
            let interval = tickInterval
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self, !Task.isCancelled else { return }
                    self.tick()
                }
            }
        } else if !waiting, let ticker {
            ticker.cancel()
            self.ticker = nil
        }
    }
}
