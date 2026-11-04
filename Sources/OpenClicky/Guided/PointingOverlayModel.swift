import AppKit
import OpenClickyKit
import OSLog
import SwiftUI

/// What the overlay shows for pointing together: the draw-to-ask ink while the talk key is held, and the guided
/// target while a walkthrough waits for a click. Owns the draw-to-ask session, the walkthrough and its pointer
/// monitor (through a `TurnPointingGuide`), and is the voice loop's `TurnGuiding`: the orchestrator calls
/// `talkKeyDown`, `talkKeyUp` and `talkCancelled` for the talk keys, attaches the highlight to the next turn, arms
/// targets from the answers' drawings, and starts the walkthrough's own turns (docs/guided.md).
@MainActor
@Observable
final class PointingOverlayModel: TurnGuiding {
    /// The current ink strokes (AppKit global points); empty when there is none.
    private(set) var inkStrokes: [[CGPoint]] = []
    /// Bumped when the ink should fade out.
    private(set) var inkFadeGeneration = 0
    /// The target waiting for the user's click, if any.
    private(set) var target: GuidedTarget?
    private(set) var status: GuidedStatus?

    /// The walkthrough and draw-to-ask without the overlay; this model adds the live ink, the ring and the monitor.
    @ObservationIgnored let guide = TurnPointingGuide(
        guided: GuidedWalkthroughController(locator: AccessibilityGuidedLocator(frontApp: { PointingOverlayModel.frontApp() })),
        pointer: { NSEvent.mouseLocation })
    var drawToAsk: DrawToAskSession { guide.drawToAsk }
    var guided: GuidedWalkthroughController { guide.guided }
    @ObservationIgnored private lazy var monitor = GuidedPointerMonitor(guided: guided)
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var lastPoint: CGPoint?
    /// A walkthrough started, moved on or ended (the voice loop updates whether Escape is swallowed).
    @ObservationIgnored var onWalkthroughChange: (() -> Void)?

    init() {
        guided.ownBundleIdentifiers = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        guide.onEffect = { [weak self] effect in self?.apply(effect) }
        // The first draw-to-ask turn shouldn't pay for loading the OCR model.
        HighlightTextRecognizer.warmUp()
    }

    /// Fly `pointer` to armed targets and pointed-at controls (docs/guided.md, "The buddy pointer").
    func attach(pointer: BuddyPointerController) {
        guide.buddy.pointer = pointer
        guide.buddy.onLog = { line in Self.log.debug("\(line, privacy: .public)") }
    }

    /// Ground targets the element list and Accessibility can't place, when the config chooses a grounding model.
    func setGrounding(factory: EngineFactory) {
        do {
            guided.grounding = try factory.elementGrounder()
        } catch {
            guided.grounding = nil
            Self.log.error("grounding off: \(String(describing: error), privacy: .public)")
        }
        guided.onGroundingLog = { line in Self.log.info("\(line, privacy: .public)") }
    }

    private static let log = Logger(subsystem: "app.openclicky", category: "pointing")

    // MARK: TurnGuiding (the voice loop's orchestrator)

    var onRequest: ((TurnGuidanceRequest) -> Void)? {
        get { guide.onRequest }
        set { guide.onRequest = newValue }
    }

    func userTurnStarted(voice: Bool) {
        if voice {
            talkKeyDown()
        } else {
            // A typed question: the waiting step steps aside, no ink.
            guide.userTurnStarted(voice: false)
            refreshWalkthrough()
        }
    }

    func pressEnded() { talkKeyUp() }

    func userTurnCancelled() { talkCancelled() }

    func prepare(_ input: inout TurnInput, look: TurnScreenLook) async {
        await guide.prepare(&input, look: look)
    }

    func answerStarted(on look: TurnScreenLook) -> (([DrawingMark]) -> Void)? { guide.answerStarted(on: look) }

    func answerFinished() {
        guide.answerFinished()
        refreshWalkthrough()
    }

    @discardableResult
    func stopWalkthrough() -> Bool {
        let stopped = guide.stopWalkthrough()
        refreshWalkthrough()
        return stopped
    }

    var isWalkthroughActive: Bool { guide.isWalkthroughActive }

    var isAwaitingNextStep: Bool { guide.isAwaitingNextStep }

    // MARK: Draw-to-ask (the talk key's hold)

    func talkKeyDown() {
        guide.userTurnStarted(voice: true)
        refreshWalkthrough()   // a manual step has no target to clear, so no effect would update the pill
        lastPoint = NSEvent.mouseLocation
        inkStrokes = []
        sampler?.invalidate()
        // NSEvent.mouseLocation needs no permission, so the ink works even before the global monitors are allowed.
        sampler = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func talkKeyUp() {
        stopSampling()
        guide.pressEnded()
        guard drawToAsk.pending != nil else { inkStrokes = []; return }
        inkFadeGeneration += 1
        let generation = inkFadeGeneration
        let fade = drawToAsk.inkStyle.fade
        // Once faded, drop the strokes so a later redraw of the overlay can't bring them back.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade + 0.1))
            guard let self, self.inkFadeGeneration == generation, self.sampler == nil else { return }
            self.inkStrokes = []
        }
    }

    func talkCancelled() {
        stopSampling()
        inkStrokes = []
        // A brushed chord (a tap, or a shortcut typed with it), nothing heard, or a dropped speech connection is not a
        // turn: forget the marks and put back the step it interrupted.
        guide.userTurnCancelled()
        refreshWalkthrough()
    }

    private func sample() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if point == lastPoint {
            drawToAsk.pointerIdle(time: now)
        } else if drawToAsk.pointerMoved(to: point, time: now) {
            inkStrokes = drawToAsk.liveStrokes
        }
        lastPoint = point
    }

    private func stopSampling() {
        sampler?.invalidate()
        sampler = nil
    }

    // MARK: Guided targets

    private func apply(_ effect: GuidedEffect) {
        switch effect {
        case .showTarget(let shown): target = shown
        case .clearTarget: target = nil
        case .ended: target = nil
        case .startTurn, .refreshCapture: break
        }
        refreshWalkthrough()
    }

    private func refreshWalkthrough() {
        status = guided.status.isActive ? guided.status : nil
        // Also while a follow-up is prepared: acting then asks for a fresh capture, and Escape still stops.
        monitor.setActive(guided.walkthrough.isActive)
        onWalkthroughChange?()
    }

    private nonisolated static func frontApp() -> FrontAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontAppInfo(name: app.localizedName, bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }
}

/// The ink and the guided target over one display, as Core Animation layers in the overlay panel.
struct PointingOverlayLayer: NSViewRepresentable {
    /// The display's frame in AppKit global points.
    let screenFrame: CGRect
    let model: PointingOverlayModel

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView(display: screenFrame)
        update(view)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) { update(view) }

    private func update(_ view: LayerHostView) {
        view.show(ink: model.inkStrokes, fadeGeneration: model.inkFadeGeneration)
        view.show(target: model.target)
    }

    final class LayerHostView: NSView {
        let ink: HighlightInkLayer
        private var targetLayer: CALayer?
        private var shownTargetID: Int?
        private var fadeGeneration = 0
        private let display: CGRect

        init(display: CGRect) {
            self.display = display
            ink = HighlightInkLayer(display: display)
            super.init(frame: CGRect(origin: .zero, size: display.size))
            wantsLayer = true
            layer?.addSublayer(ink.layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(ink strokes: [[CGPoint]], fadeGeneration generation: Int) {
            // Only the strokes on this display are drawn here; the others belong to their own panels.
            ink.update(strokes.filter { stroke in stroke.contains { display.insetBy(dx: -20, dy: -20).contains($0) } })
            if generation != fadeGeneration {
                fadeGeneration = generation
                ink.fadeOut()
            }
        }

        func show(target: GuidedTarget?) {
            guard target?.id != shownTargetID else { return }
            targetLayer?.removeFromSuperlayer()
            targetLayer = nil
            shownTargetID = target?.id
            guard let target, display.insetBy(dx: -40, dy: -40).intersects(target.frame) else { return }
            let made = GuidedTargetLayer.make(for: target, display: display)
            layer?.addSublayer(made)
            targetLayer = made
        }
    }
}
