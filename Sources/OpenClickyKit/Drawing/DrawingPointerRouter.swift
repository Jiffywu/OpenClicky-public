import CoreGraphics
import Foundation
import QuartzCore

/// Routes the pointer over one display's drawing to what is under it: a drawn button asks its question, a 3D figure
/// turns when dragged and asks about a part when clicked, a card (a paper, a photo, a figure) is dragged by its body and
/// closed with its close box. The overlay itself never takes the mouse: the host puts small non-activating handle
/// panels over `regions()` and feeds their events here (`DrawingHandles` does both). Points are the drawing layer's
/// (the display's points, origin top-left, y down).
///
/// Everything here runs without a window, so tests and `occtl overlay` drive it with synthesized pointer events.
@MainActor
public final class DrawingPointerRouter {
    public struct Settings: Sendable, Hashable {
        /// Pointer travel (points) a press on a button or close box may have and still count as a click.
        public var clickSlop: CGFloat
        /// Travel (points) after which a press on a card drags it.
        public var dragStart: CGFloat
        /// The close box in a card's top-right corner: its side and inset, in points.
        public var closeBoxSize: CGFloat
        public var closeBoxInset: CGFloat

        public init(clickSlop: CGFloat = 4, dragStart: CGFloat = 4, closeBoxSize: CGFloat = 18, closeBoxInset: CGFloat = 6) {
            self.clickSlop = clickSlop
            self.dragStart = dragStart
            self.closeBoxSize = closeBoxSize
            self.closeBoxInset = closeBoxInset
        }
    }

    /// What a point on the drawing belongs to.
    public enum Target: Sendable, Hashable, CustomStringConvertible {
        case button(String)
        case closeBox(card: String)
        case figure(String)
        case card(String)

        public var description: String {
            switch self {
            case .button(let id): "button \(id)"
            case .closeBox(let card): "close box of \(card)"
            case .figure(let id): "figure \(id)"
            case .card(let id): "card \(id)"
            }
        }
    }

    /// The cursor to show over a point.
    public enum Cursor: String, Sendable, Hashable {
        case arrow, pointingHand, openHand, closedHand
    }

    /// What a press did, once it ends.
    public enum Outcome: Sendable, Equatable {
        case none
        /// A drawn button was clicked; its question arrives as the session's `ask` event.
        case asked(button: String)
        case figureClicked(FigureClick)
        case figureTurned(String)
        /// A card was dragged by this many points.
        case cardMoved(card: String, by: CGSize)
        case cardClosed(card: String)
    }

    /// A part of the overlay that takes the pointer.
    public struct Region: Sendable, Equatable {
        public var target: Target
        public var frame: CGRect
    }

    public let session: DrawingSession
    public let stage: FigureStage?
    public var settings: Settings
    /// Cards as of the last `refresh()`.
    public private(set) var cards: [DrawingSession.Card] = []
    /// The card under the pointer: its close box shows.
    public private(set) var hoveredCard: String?
    /// Every finished press, after it took effect locally (card moves and closes reach the engine a moment later).
    public var onOutcome: ((Outcome) -> Void)?

    private struct Press {
        var target: Target
        var start: CGPoint
        var travel: CGFloat = 0
        var last: CGPoint
        var dragging = false
    }

    private var press: Press?
    /// The card being dragged and how far, while the drag lasts.
    private var dragOffset: (card: String, by: CGSize)?
    /// Card moves and closes on their way to the engine; each removes itself when done.
    private var work: [Int: Task<Void, Never>] = [:]
    private var nextWork = 0

    public init(session: DrawingSession, stage: FigureStage? = nil, settings: Settings = Settings()) {
        self.session = session
        self.stage = stage
        self.settings = settings
    }

    /// Points per canvas unit.
    private var scale: CGFloat { CGFloat(session.painter.canvas.scale) }

    /// Reads the cards from the engine (after every command sent before).
    public func refresh() async {
        let fresh = await session.cards()
        cards = fresh
        if let hovered = hoveredCard, !fresh.contains(where: { $0.id == hovered }) { hoveredCard = nil }
    }

    /// Whether a press is in progress (the host doesn't move handles under it).
    public var isPressed: Bool { press != nil }

    // MARK: Where things are

    public func frame(of card: DrawingSession.Card) -> CGRect {
        var frame = CGRect(x: card.box.minX * scale, y: card.box.minY * scale, width: card.box.width * scale, height: card.box.height * scale)
        if let drag = dragOffset, drag.card == card.id { frame = frame.offsetBy(dx: drag.by.width, dy: drag.by.height) }
        return frame
    }

    /// The close box in a card's top-right corner.
    public func closeBox(of card: DrawingSession.Card) -> CGRect {
        let frame = frame(of: card)
        let side = min(settings.closeBoxSize, max(8, min(frame.width, frame.height) / 3))
        return CGRect(x: frame.maxX - settings.closeBoxInset - side, y: frame.minY + settings.closeBoxInset, width: side, height: side)
    }

    /// Everything that takes the pointer now: cards, figures and buttons that have started to appear.
    public func regions(at time: CFTimeInterval? = nil) -> [Region] {
        var out = cards.map { Region(target: .card($0.id), frame: frame(of: $0)) }
        for (id, frame) in session.painter.figureFrames.sorted(by: { $0.key < $1.key }) where frame.width > 0 && frame.height > 0 {
            out.append(Region(target: .figure(id), frame: frame))
        }
        for button in session.painter.visibleButtons(at: time) { out.append(Region(target: .button(button.id), frame: button.frame)) }
        return out
    }

    /// What the point belongs to: a close box, then a button, a figure, the smallest card under it.
    public func target(at point: CGPoint, time: CFTimeInterval? = nil) -> Target? {
        if let card = cards.last(where: { closeBox(of: $0).contains(point) }) { return .closeBox(card: card.id) }
        if let button = session.painter.visibleButtons(at: time).last(where: { $0.frame.contains(point) }) { return .button(button.id) }
        if let figure = session.painter.figureFrames.first(where: { $0.value.contains(point) }) { return .figure(figure.key) }
        if let card = card(at: point) { return .card(card.id) }
        return nil
    }

    private func card(at point: CGPoint) -> DrawingSession.Card? {
        cards.filter { frame(of: $0).contains(point) }.min { frame(of: $0).width * frame(of: $0).height < frame(of: $1).width * frame(of: $1).height }
    }

    private func card(_ id: String) -> DrawingSession.Card? { cards.first { $0.id == id } }

    private func local(_ point: CGPoint, inFigure id: String) -> CGPoint {
        let origin = session.painter.figureFrames[id]?.origin ?? .zero
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    // MARK: The pointer

    /// The pointer moved without a button held: which cursor to show (and which card's close box).
    @discardableResult
    public func hover(at point: CGPoint) -> Cursor {
        if let press { return press.dragging ? .closedHand : cursor(for: press.target, at: point) }
        hoveredCard = card(at: point)?.id
        guard let target = target(at: point) else { return .arrow }
        return cursor(for: target, at: point)
    }

    private func cursor(for target: Target, at point: CGPoint) -> Cursor {
        switch target {
        case .button, .closeBox:
            return .pointingHand
        case .figure(let id):
            switch stage?.hover(figure: id, at: local(point, inFigure: id)) ?? .figure {
            case .part: return .pointingHand
            case .figure: return .openHand
            case .none: return .arrow
            }
        case .card(let id):
            return card(id)?.isDraggable == true ? .openHand : .arrow
        }
    }

    /// The pointer left every handle.
    public func pointerExited() {
        if press == nil { hoveredCard = nil }
    }

    public func pointerDown(at point: CGPoint) {
        guard let target = target(at: point) else {
            press = nil
            return
        }
        press = Press(target: target, start: point, last: point)
        if case .figure(let id) = target { stage?.pointerDown(figure: id, at: local(point, inFigure: id)) }
    }

    public func pointerDragged(to point: CGPoint) {
        guard var current = press else { return }
        current.travel += hypot(point.x - current.last.x, point.y - current.last.y)
        current.last = point
        switch current.target {
        case .figure(let id):
            stage?.pointerDragged(figure: id, to: local(point, inFigure: id))
            if current.travel > (stage?.settings.clickSlop ?? settings.clickSlop) { current.dragging = true }
        case .card(let id):
            guard let card = card(id), card.isDraggable else { break }
            if current.travel > settings.dragStart { current.dragging = true }
            if current.dragging {
                let by = CGSize(width: point.x - current.start.x, height: point.y - current.start.y)
                dragOffset = (id, by)
                session.painter.previewOffset(card.marks, by: by)
            }
        case .button, .closeBox:
            break
        }
        press = current
    }

    /// Ends a press and does what it meant.
    @discardableResult
    public func pointerUp(at point: CGPoint) -> Outcome {
        guard let current = press else { return .none }
        press = nil
        let outcome: Outcome
        switch current.target {
        case .button(let id):
            let still = session.painter.visibleButtons().first { $0.id == id }?.frame.contains(point) == true
            outcome = still && current.travel <= settings.clickSlop && session.click(at: point) ? .asked(button: id) : .none
        case .closeBox(let id):
            if let card = card(id), current.travel <= settings.clickSlop, closeBox(of: card).contains(point) {
                cards.removeAll { $0.id == id }
                if hoveredCard == id { hoveredCard = nil }
                track { [session] in
                    await session.closeCard(card)
                    await self.refresh()
                }
                outcome = .cardClosed(card: id)
            } else {
                outcome = .none
            }
        case .figure(let id):
            if let click = stage?.pointerUp(figure: id, at: local(point, inFigure: id)) {
                outcome = .figureClicked(click)
            } else {
                outcome = current.dragging ? .figureTurned(id) : .none
            }
        case .card(let id):
            if current.dragging, card(id) == nil, let drag = dragOffset, drag.card == id {
                // The card went while it was dragged (closed, or the screen changed): nothing is left to preview.
                dragOffset = nil
            }
            if current.dragging, let card = card(id) {
                let by = CGSize(width: point.x - current.start.x, height: point.y - current.start.y)
                let units = CGSize(width: by.width / scale, height: by.height / scale)
                track { [session] in
                    await session.moveCard(card, by: units)
                    await self.refresh()
                    if self.dragOffset?.card == id { self.dragOffset = nil }
                }
                outcome = .cardMoved(card: id, by: by)
            } else {
                outcome = .none
            }
        }
        onOutcome?(outcome)
        return outcome
    }

    /// Waits until card moves and closes have reached the engine and the cards are read again.
    public func settle() async {
        while let task = work.values.first { await task.value }
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        let id = nextWork
        nextWork += 1
        work[id] = Task {
            await body()
            self.work[id] = nil
        }
    }
}
