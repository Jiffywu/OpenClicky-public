import AppKit
import OpenClickyKit
import QuartzCore
import SwiftUI

/// The drawing canvases in the overlay: one `DrawingDisplayCanvas` per display (the live `DrawingSession`, its
/// `FigureStage` and the pointer router). Canvas units are screenshot pixels, scaled to the display's points, and ink is
/// made readable from that screenshot. The overlay view for a display shows `layer(for:)`.
///
/// A user's follow-up continues the drawing on screen, and its notes describe it (`describeOnScreen`). Small handle
/// panels (`DrawingHandles`) sit over drawn buttons, figures and cards so they can be clicked, turned, dragged and
/// closed while the rest of the overlay lets the mouse through. The stale watch (`DrawingStaleMonitor`) takes the
/// drawing's screen marks away when the screen changes under them: the window moves or is covered, the user scrolls
/// it or switches apps or Spaces. See docs/overlay-interaction.md.
@MainActor
@Observable
final class OverlayDrawingSurfaces: TurnDrawingSurfaces {
    private(set) var layers: [CGDirectDisplayID: CALayer] = [:]
    @ObservationIgnored private var canvases: [CGDirectDisplayID: DrawingDisplayCanvas] = [:]
    /// The display drawn on last: the stale watch watches it.
    @ObservationIgnored private var lastDisplay: CGDirectDisplayID?
    /// A drawn button or a figure part was clicked: its question becomes a typed turn.
    @ObservationIgnored var onAsk: ((String) -> Void)?
    @ObservationIgnored var onProblem: ((String) -> Void)?
    /// What the user did to a drawing and what the stale watch did, for the log.
    @ObservationIgnored var onLog: ((String) -> Void)?
    /// Looks up the drawings' photo, place, quote and site-icon cards (docs/dsl-media.md); nil leaves them loading.
    @ObservationIgnored var media: DrawingMediaResolver? {
        didSet { canvases.values.forEach { $0.media = media } }
    }
    @ObservationIgnored let handles: DrawingHandles
    @ObservationIgnored let staleWatch = DrawingStaleMonitor()

    init() {
        handles = DrawingHandles(displays: { [] })
        handles.displays = { [weak self] in self?.handleDisplays() ?? [] }
        handles.onOutcome = { [weak self] _, outcome in self?.log(outcome) }
        staleWatch.onStale = { [weak self] reason in self?.screenChanged(reason) }
    }
    /// Types, copies, opens pages and hands off for the drawings' actions and clicked buttons and links.
    @ObservationIgnored var actions: DrawingActionPerformer?
    /// Plays the drawings' pen, pop and paper sounds as they are drawn.
    @ObservationIgnored var sounds: DrawingSoundPlayer?
    /// What a drawing noted for the app: ("seen" | "noted" | "lesson", words).
    @ObservationIgnored var onNote: ((String, String) -> Void)?

    func layer(for screen: NSScreen) -> CALayer? { screen.displayID.flatMap { layers[$0] } }

    /// The handle panels' window numbers, so screen capture leaves them out.
    var handleWindowNumbers: [Int] { handles.windowNumbers }

    func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        start(screenshot, image: image, continuing: false)?.drawing
    }

    func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)? {
        start(screenshot, image: image, continuing: true)
    }

    /// The display a screenshot shows.
    private func displayID(for screenshot: TurnScreenshot) -> CGDirectDisplayID? {
        Self.displayID(showing: screenshot.displayFrame, layout: DesktopLayout.current(),
                       screens: NSScreen.screens.map { (id: $0.displayID, frame: $0.frame) })
    }

    /// The screen whose frame (AppKit global points) is nearest a screenshot's display frame (Quartz global points).
    static func displayID(showing quartzFrame: CGRect, layout: DesktopLayout,
                          screens: [(id: CGDirectDisplayID?, frame: CGRect)]) -> CGDirectDisplayID? {
        let frame = layout.appKitRect(fromQuartz: quartzFrame)
        return screens.min(by: { distance($0.frame, frame) < distance($1.frame, frame) })?.id
    }

    private func start(_ screenshot: TurnScreenshot, image: CGImage?, continuing: Bool) -> (drawing: any TurnDrawing, keep: Bool)? {
        guard let id = displayID(for: screenshot) else { return nil }
        let canvas = canvases[id] ?? makeCanvas(id)
        guard let (session, keep) = canvas.drawing(for: screenshot, image: image, continuing: continuing) else { return nil }
        actions?.newAnswer()
        sounds?.stopAll()
        layers[id] = session.layer
        lastDisplay = id
        // Watch the screen as it is now: the drawing belongs to it.
        staleWatch.arm(area: screenshot.displayFrame)
        handles.start()
        return (session, keep)
    }

    private func makeCanvas(_ id: CGDirectDisplayID) -> DrawingDisplayCanvas {
        let canvas = DrawingDisplayCanvas()
        // Figures on this display draw from its display link.
        canvas.stage.displayID = id
        canvas.stage.onWarning = { [weak self, weak canvas] text in
            if let stage = canvas?.stage { FigureAvailability.shared.record(stage) }
            self?.onProblem?("3D: \(text)")
        }
        canvas.media = media
        canvas.onAsk = { [weak self] question in self?.onAsk?(question) }
        canvas.onProblem = { [weak self] text in self?.onProblem?(text) }
        canvas.onEvent = { [weak self, weak canvas] event in
            switch event {
            case .action(let action):
                guard let performer = self?.actions else { return }
                Task { @MainActor in
                    let outcome = await performer.perform(action)
                    if !outcome.succeeded { self?.onProblem?("drawing \(action.role.rawValue): \(outcome.result)") }
                }
            case .sound(let recipe):
                if let session = canvas?.session { self?.sounds?.schedule(recipe, now: session.painter.now()) }
            case .note(let kind, let text): self?.onNote?(kind, text)
            default: break
            }
        }
        canvases[id] = canvas
        return canvas
    }

    var hasVisibleDrawing: Bool { canvases.values.contains { $0.hasVisibleDrawing } }

    /// The beat being heard on this display's drawing, for the debug caption chips.
    func beats(for screen: NSScreen) -> DrawingBeats? {
        guard let id = screen.displayID, let session = canvases[id]?.session, session.isDrawing else { return nil }
        return session.beats()
    }

    func clearAll() {
        staleWatch.disarm()
        sounds?.stopAll()
        for canvas in canvases.values { canvas.clear() }
    }

    /// The drawing a follow-up on that display would continue (another display or canvas size starts a new one).
    func describeOnScreen(for screenshot: TurnScreenshot) -> String? {
        guard let id = displayID(for: screenshot) else { return nil }
        return canvases[id]?.describeOnScreen(for: screenshot)
    }

    private func screenChanged(_ reason: DrawingStaleReason) {
        guard let id = lastDisplay, let canvas = canvases[id], canvas.hasVisibleDrawing || canvas.session?.isDrawing == true else { return }
        let drawing = canvas.session?.isDrawing == true
        Task { [weak self] in
            let kept = await canvas.screenChanged()
            let result = drawing ? "loose marks removed, the answer goes on"
                : kept > 0 ? "loose marks removed, \(kept) card(s) kept" : "drawing cleared"
            self?.onLog?("stale drawing (\(reason)): \(result)")
        }
    }

    private func handleDisplays() -> [DrawingHandles.Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, let canvas = canvases[id], canvas.hasVisibleDrawing else { return nil }
            return DrawingHandles.Display(id: id, frame: screen.frame, router: canvas.router)
        }
    }

    private func log(_ outcome: DrawingPointerRouter.Outcome) {
        switch outcome {
        case .none: break
        case .asked(let button): onLog?("drawing: button \(button) clicked")
        case .figureClicked(let click): onLog?("figure part \(click.partID) clicked (\(click.name))")
        case .figureTurned(let figure): onLog?("3D figure \(figure) turned by hand")
        case .cardMoved(let card, let by): onLog?("drawing: card \(card) dragged by \(Int(by.width)), \(Int(by.height)) points")
        case .cardClosed(let card): onLog?("drawing: card \(card) closed")
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

/// Hosts a drawing's layer in a SwiftUI overlay. Never takes clicks (handle panels over buttons, figures and cards do).
struct DrawingCanvasView: NSViewRepresentable {
    let layer: CALayer?

    func makeNSView(context: Context) -> CanvasHostView { CanvasHostView() }

    func updateNSView(_ view: CanvasHostView, context: Context) { view.show(layer) }
}

final class CanvasHostView: NSView {
    private weak var shown: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ content: CALayer?) {
        guard shown !== content else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown?.removeFromSuperlayer()
        if let content {
            content.position = .zero
            layer?.addSublayer(content)
        }
        CATransaction.commit()
        shown = content
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
