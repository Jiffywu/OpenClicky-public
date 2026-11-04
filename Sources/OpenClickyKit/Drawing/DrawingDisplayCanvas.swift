import CoreGraphics
import Foundation
import QuartzCore
import os

/// One display's drawing as the overlay shows it: the live `DrawingSession`, the `FigureStage` its figures play on, the
/// pointer router for its buttons, figures and cards, and the photo and place cards' lookups.
///
/// A user's follow-up continues the drawing already on screen (`begin` with `keep`), so the brain can see it
/// (`describeOnScreen(for:)`) and edit it by part id; a turn that doesn't fit it (another screenshot size) starts a new
/// one. Each new session gets its own engine: a new answer never inherits the last one's program state. The app's
/// overlay keeps one per display; `occtl overlay` and tests drive one offscreen.
@MainActor
public final class DrawingDisplayCanvas {
    public let stage: FigureStage
    public private(set) var session: DrawingSession?
    public private(set) var router: DrawingPointerRouter?
    public var routerSettings = DrawingPointerRouter.Settings() {
        didSet { router?.settings = routerSettings }
    }
    /// Looks up the drawings' photo, place, quote and site-icon cards; nil leaves them loading.
    public var media: DrawingMediaResolver? {
        didSet { session?.painter.media = media?.store }
    }
    /// A drawn button or a figure part was clicked: its question becomes the user's next (typed) turn.
    public var onAsk: ((String) -> Void)?
    public var onProblem: ((String) -> Void)?
    /// Every event the painter doesn't draw, for logs.
    public var onEvent: ((DrawingEvent) -> Void)?
    /// Draw at this many points per canvas unit whatever the turn says (offscreen: 1, one point per screenshot pixel).
    public var fixedScale: Double?
    /// Keep animations alive without a window (offscreen hosts render the layer with `DrawingSnapshot`).
    public var offscreen = false
    /// The media clock the drawing animates on (tests use a virtual one).
    public var clock: @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }
    /// How many sessions were made (a continued drawing doesn't make one).
    public private(set) var sessionsMade = 0
    private var canvas: DrawingPainter.Canvas?
    private var screenSampler: OSAllocatedUnfairLock<DrawingScreenSampler?>?
    /// The screen changed while the answer was still drawing: its screen marks went, and once it finishes whatever it
    /// added meanwhile is settled the same way (`screenChanged`).
    private var staleWhileDrawing = false
    /// Counts answers drawn here (new or continued), so work for an earlier answer can tell it has been overtaken.
    private var answers = 0

    public init(stage: FigureStage = FigureStage()) {
        self.stage = stage
    }

    /// The layer to show (nil before the first drawing).
    public var layer: CALayer? { session?.layer }

    /// Whether anything drawn (marks or figures) is on screen.
    public var hasVisibleDrawing: Bool {
        guard let session else { return false }
        return !session.painter.markIDs.isEmpty || !session.painter.figureFrames.isEmpty
    }

    /// The drawing for a turn whose canvas is `screenshot`. With `continuing`, the drawing on screen is kept and
    /// continued (`keep` true: begin it with `keep`) when it is still showing and has the same canvas; otherwise a new
    /// session replaces it. `image` is the decoded screenshot, for readable ink. Nil when the engine can't load.
    public func drawing(for screenshot: TurnScreenshot, image: CGImage?, continuing: Bool) -> (session: DrawingSession, keep: Bool)? {
        // A new answer is drawn for the screen as it is now: a stale screen from before is no longer this drawing's.
        staleWhileDrawing = false
        answers += 1
        let next = canvas(for: screenshot)
        let nextSampler = image.map { DrawingScreenSampler(image: $0, canvasSize: CGSize(width: next.width, height: next.height)) }
        if continuing, let session, continues(screenshot) {
            if session.isDrawing { session.cancel() }
            screenSampler?.withLock { $0 = nextSampler }
            session.painter.screen = image
            return (session, true)
        }
        let sampler = OSAllocatedUnfairLock(initialState: nextSampler)
        let made: DrawingSession
        do {
            let luminance: DrawingEngineHost.Luminance = { rect in sampler.withLock { $0?.luminance(in: rect) } }
            let busyness: DrawingEngineHost.Busyness = { rect in sampler.withLock { $0?.busyness(in: rect) } }
            let host = try DrawingEngineHost(clock: clock, luminance: luminance, busyness: busyness)
            made = DrawingSession(host: host, painter: DrawingPainter(canvas: next, figureSink: stage, clock: clock))
        } catch {
            onProblem?("The drawing engine didn't load: \(error)")
            return nil
        }
        made.painter.screen = image
        if offscreen { DrawingSnapshot.adopt(made.layer) }
        // Figures pose their parts from the program's ticks, run on this session's engine; clicked parts are named
        // after the program's variables.
        let host = made.host
        stage.tickProvider = { figure, ticks, dt in
            host.withContext { FigureTickBridge(context: $0).runTicks(figure: figure, ticks: ticks, dt: dt) }
        }
        stage.readoutProvider = { host.withContext { FigureTickBridge(context: $0).takeReadouts() } }
        stage.variableName = { part in host.withContext { FigureTickBridge(context: $0).nameOf(part: part) } }
        stage.onPartClicked = { [weak self] click in self?.onAsk?(click.question) }
        made.onEvent = { [weak self, weak made] event in
            if let media = self?.media {
                _ = media.handle(event) { [weak made] ref, fields in made?.patch(ref, fields: fields) }
            }
            switch event {
            case .ask(let text): self?.onAsk?(text)
            case .error(let message, _): self?.onProblem?("drawing: \(message)")
            case .done: if let self, let made, self.session === made { self.drawingFinished() }
            default: break
            }
            self?.onEvent?(event)
        }
        if let media {
            // A new answer: lookups the last one started are no longer wanted.
            media.cancelAll()
            made.painter.media = media.store
        }
        session?.cancel()
        stage.removeAll()
        session = made
        screenSampler = sampler
        canvas = next
        sessionsMade += 1
        router = DrawingPointerRouter(session: made, stage: stage, settings: routerSettings)
        return (made, false)
    }

    /// The canvas a turn on `screenshot` draws on.
    private func canvas(for screenshot: TurnScreenshot) -> DrawingPainter.Canvas {
        var options = TurnImages.beginOptions(for: screenshot, ink: "#3380FF", pace: .speech)
        if let fixedScale { options.scale = fixedScale }
        return DrawingPainter.Canvas(width: options.width, height: options.height, scale: options.scale)
    }

    /// Whether a follow-up on `screenshot` would continue the drawing on screen: something is drawn, on the same canvas.
    public func continues(_ screenshot: TurnScreenshot) -> Bool {
        session != nil && hasVisibleDrawing && canvas == canvas(for: screenshot)
    }

    /// What the drawing on screen shows, for the next turn's notes; nil when nothing is drawn.
    public func describeOnScreen(maxCharacters: Int = 12_000) -> String? {
        guard hasVisibleDrawing else { return nil }
        return session?.describeOnScreen(maxCharacters: maxCharacters)
    }

    /// What a follow-up on `screenshot` would be shown: the drawing it continues, or nil when it would start anew.
    public func describeOnScreen(for screenshot: TurnScreenshot, maxCharacters: Int = 12_000) -> String? {
        continues(screenshot) ? describeOnScreen(maxCharacters: maxCharacters) : nil
    }

    /// Remove everything at once (Escape).
    public func clear() {
        staleWhileDrawing = false
        media?.cancelAll()
        session?.clear()
        stage.removeAll()
        Task { [router] in await router?.refresh() }
    }

    /// What lies under the drawing changed (`DrawingStaleWatch`): marks that point at the screen go and cards stay.
    /// A finished drawing with no card left goes altogether. An answer still being drawn goes on (its voice is still
    /// talking): only its screen marks go now, and when it finishes the same rule runs again over what it added.
    /// Returns how many cards are left.
    @discardableResult
    public func screenChanged() async -> Int {
        guard let session, hasVisibleDrawing || session.isDrawing else { return 0 }
        let answer = answers
        let (kept, _) = await session.dropScreenMarks()
        // A new answer started meanwhile: it is drawn for the screen as it is now.
        guard self.session === session, answers == answer else { return kept }
        if session.isDrawing {
            staleWhileDrawing = true
            await router?.refresh()
        } else if kept == 0 {
            clear()
        } else {
            await router?.refresh()
        }
        return kept
    }

    /// The live session's answer is fully drawn (or was stopped).
    private func drawingFinished() {
        guard staleWhileDrawing else { return }
        staleWhileDrawing = false
        let answer = answers
        Task {
            guard self.answers == answer else { return }
            await self.screenChanged()
        }
    }
}

/// `TurnDrawingSurfaces` over one offscreen `DrawingDisplayCanvas`: follow-ups continue the drawing, buttons and
/// figures answer synthesized clicks through its router, and `snapshot(at:)` renders it over the screenshot. Used by
/// `occtl overlay` and tests.
@MainActor
public final class CanvasDrawingSurfaces: TurnDrawingSurfaces {
    public let canvas: DrawingDisplayCanvas
    public private(set) var backdrop: CGImage?
    public private(set) var canvasSize: CGSize = .zero
    /// Whether follow-ups continue the drawing on screen (true) or always start a new one.
    public var continuesDrawings = true

    public init(canvas: DrawingDisplayCanvas = DrawingDisplayCanvas(stage: FigureStage(drivesItself: false))) {
        self.canvas = canvas
        canvas.offscreen = true
        canvas.fixedScale = 1
    }

    public var session: DrawingSession? { canvas.session }

    public func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        start(screenshot, image: image, continuing: false)?.drawing
    }

    public func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)? {
        start(screenshot, image: image, continuing: continuesDrawings)
    }

    private func start(_ screenshot: TurnScreenshot, image: CGImage?, continuing: Bool) -> (drawing: any TurnDrawing, keep: Bool)? {
        guard let (session, keep) = canvas.drawing(for: screenshot, image: image, continuing: continuing) else { return nil }
        backdrop = image
        canvasSize = session.painter.canvas.sizeInPoints
        return (FixedScaleDrawing(session), keep)
    }

    public var hasVisibleDrawing: Bool { canvas.hasVisibleDrawing }

    public func clearAll() { canvas.clear() }

    /// What is drawn now, whatever the next turn's screenshot (`occtl overlay`'s state text).
    public func describeOnScreen() -> String? { canvas.describeOnScreen() }

    public func describeOnScreen(for screenshot: TurnScreenshot) -> String? {
        continuesDrawings ? canvas.describeOnScreen(for: screenshot) : nil
    }

    /// The canvas as it looks at media time `time` (now by default), over the screenshot.
    public func snapshot(at time: CFTimeInterval = CACurrentMediaTime()) throws -> CGImage? {
        guard let session = canvas.session else { return nil }
        let image = try DrawingSnapshot.render(session.layer, size: canvasSize, at: time, backdrop: backdrop)
        DrawingSnapshot.adopt(session.layer)
        return image
    }
}

/// A session whose `begin` keeps the canvas's own scale (offscreen: one point per screenshot pixel).
@MainActor
final class FixedScaleDrawing: TurnDrawing {
    let session: DrawingSession

    init(_ session: DrawingSession) { self.session = session }

    func begin(_ options: DrawingBeginOptions) {
        var options = options
        options.scale = session.painter.canvas.scale
        session.begin(options)
    }

    func append(_ text: String) { session.append(text) }
    func end() { session.end() }
    func finishNow() { session.finishNow() }
    func cancel() { session.cancel() }
    func clear() { session.clear() }
    var isDrawing: Bool { session.isDrawing }
    var onMarks: (([DrawingMark]) -> Void)? {
        get { session.onMarks }
        set { session.onMarks = newValue }
    }

    nonisolated func lineStarted(_ index: Int, expectedDuration: TimeInterval?) { session.lineStarted(index, expectedDuration: expectedDuration) }
    nonisolated func lineFinished(_ index: Int) { session.lineFinished(index) }
    func pause() { session.pause() }
    func resume() { session.resume() }
    func wordsSpoken(_ count: Int) { session.wordsSpoken(count) }
}
