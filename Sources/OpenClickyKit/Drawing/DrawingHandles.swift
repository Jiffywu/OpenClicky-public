import AppKit
import QuartzCore

/// A small, invisible, non-activating panel over one part of a drawing the user can touch: a drawn button, a 3D
/// figure or a card. The overlay above everything ignores the mouse so the apps underneath keep working; these panels
/// take the pointer only where the drawing has something to click, drag or close. Clicking one never activates
/// OpenClicky or takes focus from the app the user is in.
public final class DrawingHandlePanel: NSPanel {
    public let handleView: DrawingHandleView

    public init(frame: CGRect) {
        handleView = DrawingHandleView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        // Clear to the eye, but not fully transparent: the window server sends a window the clicks over pixels that
        // aren't completely clear.
        backgroundColor = NSColor(white: 0, alpha: 1.0 / 255)
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = handleView
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// The view filling a handle panel: turns its mouse events into points on the display's drawing and hands them to the
/// display's `DrawingPointerRouter`, shows the router's cursor, and draws a card's close box while the card is hovered.
public final class DrawingHandleView: NSView {
    /// Where events go (the display's router; replaced when a new drawing starts).
    public weak var router: DrawingPointerRouter?
    /// The display's frame in global AppKit coordinates (`NSScreen.frame`): the drawing's origin is its top-left.
    public var displayFrame: CGRect = .zero
    /// Every finished press.
    public var onOutcome: ((DrawingPointerRouter.Outcome) -> Void)?
    /// Something changed under the pointer (the handles redraw close boxes).
    public var onActivity: (() -> Void)?
    /// The cursor last shown over this panel.
    public private(set) var cursorShown: DrawingPointerRouter.Cursor = .arrow
    /// The close box to draw, in this view's coordinates (y down), while its card is hovered.
    public var closeBox: CGRect? {
        didSet { if oldValue != closeBox { needsDisplay = true } }
    }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// The event's point on the display's drawing (points, origin top-left, y down).
    public func canvasPoint(for event: NSEvent) -> CGPoint {
        let screen = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        return CGPoint(x: screen.x - displayFrame.minX, y: displayFrame.maxY - screen.y)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let router else { return }
        let point = canvasPoint(for: event)
        router.pointerDown(at: point)
        show(router.hover(at: point))
        onActivity?()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let router else { return }
        let point = canvasPoint(for: event)
        router.pointerDragged(to: point)
        show(router.hover(at: point))
        onActivity?()
    }

    public override func mouseUp(with event: NSEvent) {
        guard let router else { return }
        let point = canvasPoint(for: event)
        let outcome = router.pointerUp(at: point)
        show(router.hover(at: point))
        onOutcome?(outcome)
        onActivity?()
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let router else { return }
        show(router.hover(at: canvasPoint(for: event)))
        onActivity?()
    }

    public override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    public override func mouseExited(with event: NSEvent) {
        router?.pointerExited()
        show(.arrow)
        onActivity?()
    }

    public override func cursorUpdate(with event: NSEvent) { show(cursorShown) }

    private func show(_ cursor: DrawingPointerRouter.Cursor) {
        cursorShown = cursor
        // Only while the pointer is over this panel (tests synthesize events without a window on screen).
        guard window?.isVisible == true else { return }
        switch cursor {
        case .arrow: NSCursor.arrow.set()
        case .pointingHand: NSCursor.pointingHand.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let closeBox, let context = NSGraphicsContext.current?.cgContext else { return }
        DrawingHandleArt.drawCloseBox(in: context, rect: closeBox)
    }
}

/// How handles look (only the close box shows).
public enum DrawingHandleArt {
    /// A dark round button with a white ×, in a y-down context.
    public static func drawCloseBox(in context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0.12, alpha: 0.82))
        context.fillEllipse(in: rect)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        context.setLineWidth(max(1.5, rect.width * 0.1))
        context.setLineCap(.round)
        let inset = rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)
        context.move(to: CGPoint(x: inset.minX, y: inset.minY))
        context.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
        context.move(to: CGPoint(x: inset.maxX, y: inset.minY))
        context.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
        context.strokePath()
        context.restoreGState()
    }
}

/// Keeps one handle panel over each region of each display's drawing (`DrawingPointerRouter.regions()`), moving
/// them as cards are dragged and dropping them as parts leave, and re-reads the cards a few times a second.
@MainActor
public final class DrawingHandles {
    public struct Display {
        public var id: UInt32
        /// The display's frame in global AppKit coordinates (`NSScreen.frame`).
        public var frame: CGRect
        public var router: DrawingPointerRouter?

        public init(id: UInt32, frame: CGRect, router: DrawingPointerRouter?) {
            self.id = id
            self.frame = frame
            self.router = router
        }
    }

    public var displays: () -> [Display]
    /// Put panels on screen (the app). Off, they are made and placed but never shown (tests).
    public let showsPanels: Bool
    /// How often the cards are read again from the engine.
    public var cardRefreshInterval: CFTimeInterval = 0.3
    /// Every finished press, with its display.
    public var onOutcome: ((UInt32, DrawingPointerRouter.Outcome) -> Void)?
    public private(set) var panels: [String: DrawingHandlePanel] = [:]
    /// The overlay stepped aside for system UI (Mission Control, the screenshot UI, a window picker): the panels go off
    /// screen with it, so invisible handles never take clicks meant for that UI. They are still kept in place.
    public var isHidden = false {
        didSet {
            guard isHidden != oldValue else { return }
            for panel in panels.values {
                if showsOnScreen { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
            }
        }
    }
    /// Whether the panels are on screen now (shown, and not stepped aside).
    public var showsOnScreen: Bool { showsPanels && !isHidden }
    /// Panels taken away during the last pass, kept until the next one: the one being clicked may be among them (a
    /// closed card), and it must outlive the event it is handling.
    private var retiring: [DrawingHandlePanel] = []
    private var timer: Timer?
    private var refreshedAt: [ObjectIdentifier: CFTimeInterval] = [:]
    private var refreshing: Set<ObjectIdentifier> = []

    public init(showsPanels: Bool = true, displays: @escaping () -> [Display]) {
        self.showsPanels = showsPanels
        self.displays = displays
    }

    /// Syncs the panels `rate` times a second.
    public func start(rate: Double = 10) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / max(1, rate), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for panel in panels.values { panel.orderOut(nil) }
        retiring += panels.values
        panels.removeAll()
    }

    /// The panels' window numbers, so screen capture leaves them out.
    public var windowNumbers: [Int] { panels.values.map(\.windowNumber).filter { $0 > 0 } }

    /// The panel over a region (tests and tools).
    public func panel(display: UInt32, target: DrawingPointerRouter.Target) -> DrawingHandlePanel? { panels[key(display, target)] }

    /// One pass: re-read cards now and then, and keep exactly one panel over each region.
    public func sync(at time: CFTimeInterval? = nil) {
        retiring.removeAll()
        var wanted: Set<String> = []
        var pressed: Set<UInt32> = []
        for display in displays() {
            guard let router = display.router else { continue }
            if router.isPressed { pressed.insert(display.id) } else { refreshIfDue(router) }
            for region in router.regions(at: time) {
                let name = key(display.id, region.target)
                wanted.insert(name)
                // Windows sit on whole points: round outwards so the panel covers all of the region.
                let frame = CGRect(x: display.frame.minX + region.frame.minX, y: display.frame.maxY - region.frame.maxY,
                                   width: region.frame.width, height: region.frame.height).integral
                let panel = panels[name] ?? makePanel(name, frame: frame, display: display.id)
                if panel.frame != frame { panel.setFrame(frame, display: false) }
                let view = panel.handleView
                view.router = router
                view.displayFrame = display.frame
                view.frame = CGRect(origin: .zero, size: frame.size)
                if case .card(let id) = region.target, router.hoveredCard == id, let card = router.cards.first(where: { $0.id == id }) {
                    // In the view (y down from the panel's top-left, which is the region's, rounded).
                    let box = router.closeBox(of: card)
                    let top = display.frame.maxY - frame.maxY, left = frame.minX - display.frame.minX
                    view.closeBox = box.offsetBy(dx: -left, dy: -top)
                } else {
                    view.closeBox = nil
                }
            }
        }
        for (name, panel) in panels where !wanted.contains(name) {
            // Never pull a panel out from under a press in progress.
            if let id = UInt32(name.split(separator: "|").first ?? ""), pressed.contains(id) { continue }
            panel.orderOut(nil)
            panels[name] = nil
            retiring.append(panel)
        }
    }

    private func makePanel(_ name: String, frame: CGRect, display: UInt32) -> DrawingHandlePanel {
        let panel = DrawingHandlePanel(frame: frame)
        panel.handleView.onOutcome = { [weak self] outcome in self?.onOutcome?(display, outcome) }
        panel.handleView.onActivity = { [weak self] in self?.sync() }
        panels[name] = panel
        if showsOnScreen { panel.orderFrontRegardless() }
        return panel
    }

    private func refreshIfDue(_ router: DrawingPointerRouter) {
        let id = ObjectIdentifier(router)
        let now = CACurrentMediaTime()
        guard !refreshing.contains(id), now - (refreshedAt[id] ?? 0) >= cardRefreshInterval else { return }
        refreshing.insert(id)
        refreshedAt[id] = now
        Task { [weak self] in
            await router.refresh()
            self?.refreshing.remove(id)
        }
    }

    private func key(_ display: UInt32, _ target: DrawingPointerRouter.Target) -> String { "\(display)|\(target)" }
}
