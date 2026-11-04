import CoreGraphics
import Foundation
import QuartzCore

/// Paints the drawing engine's marks into a Core Animation layer tree.
///
/// Every 2D mark becomes a container layer named by the mark's id. Strokes are revealed with `strokeEnd` animations,
/// words are set with Core Text and written left to right, pills, badges and buttons pop in, and screen ink glows in
/// its own colour. Each mark's animations begin at `base + start` on the host clock (`base` is when the mark's spoken
/// line began, `start` the engine's offset into it), so the pen moves in step with the voice. 3D marks are never
/// interpreted here: they go to the `FigureSink`, and a figure's layer is placed at the figure's rectangle.
///
/// Offscreen (no window), pass the painter's layer to `DrawingSnapshot.adopt(_:)` before painting, or Core Animation
/// strips the reveal animations the next time a transaction is flushed.
@MainActor
public final class DrawingPainter {
    public struct Canvas: Sendable, Equatable {
        /// Canvas size in canvas units.
        public var width: Double
        public var height: Double
        /// Screen points per canvas unit.
        public var scale: Double

        public init(width: Double, height: Double, scale: Double = 1) {
            self.width = width
            self.height = height
            self.scale = scale
        }

        public var sizeInPoints: CGSize { CGSize(width: width * scale, height: height * scale) }
    }

    enum Group: String, CaseIterable { case under, main, words }

    struct Entry {
        var container: CALayer
        var mark: DrawingMark
        var group: Group
    }

    /// The root layer: y-down, sized to the canvas in points. Put it in the overlay (or render it offscreen).
    public let layer = CALayer()
    public let canvas: Canvas
    public weak var figureSink: (any FigureSink)?
    /// Photos, maps and icons that media marks name by key (`image`, `map`; docs/dsl-media.md). Without it, media
    /// cards show their placeholders.
    public var media: DrawingMediaStore?
    /// The screenshot the drawing is over (canvas units are its pixels, or it is scaled to the canvas). Highlights
    /// multiply its pixels with their ink, as a highlighter would; without it they are translucent bands.
    public var screen: CGImage?
    /// Events that aren't painted (`ask`, `step`, `warning`, `error`, `done`) are passed on here.
    public var onEvent: ((DrawingEvent) -> Void)?
    public private(set) var currentStep: Int?

    private var groups: [Group: CALayer] = [:]
    private(set) var entries: [String: Entry] = [:]
    private(set) var figureLayers: [String: CALayer] = [:]
    private var leaving: [(layer: CALayer, at: CFTimeInterval)] = []
    let clock: () -> CFTimeInterval

    static let penCurve = CAMediaTimingFunction(controlPoints: 0.4, 0.05, 0.45, 1)
    static let easeOut = CAMediaTimingFunction(name: .easeOut)
    static let glide = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.5, 0.95)

    public init(canvas: Canvas, figureSink: (any FigureSink)? = nil, clock: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.canvas = canvas
        self.figureSink = figureSink
        self.clock = clock
        withoutActions {
            layer.name = "drawing"
            layer.anchorPoint = .zero
            layer.bounds = CGRect(origin: .zero, size: canvas.sizeInPoints)
            layer.position = .zero
            layer.isGeometryFlipped = true
            for group in Group.allCases {
                let sub = CALayer()
                sub.name = group.rawValue
                sub.anchorPoint = .zero
                sub.frame = layer.bounds
                layer.addSublayer(sub)
                groups[group] = sub
            }
        }
    }

    // MARK: Time

    /// True between `pause()` and `resume()`: every animation holds where it is.
    public private(set) var isPaused = false
    private var pausedAt: CFTimeInterval = 0
    /// Seconds spent paused so far: the drawing's time runs this far behind the host clock (the engine keeps the same).
    public private(set) var pausedTotal: CFTimeInterval = 0

    /// The drawing's time: the host clock less the time spent paused, frozen while paused. Marks' `base + start` are on it.
    public func now() -> CFTimeInterval { (isPaused ? pausedAt : clock()) - pausedTotal }

    /// Hold every stroke where it is (the engine holds the marks still to come; `DrawingSession.pause()` does both).
    public func pause() {
        guard !isPaused else { return }
        pausedAt = clock()
        isPaused = true
        withoutActions {
            layer.timeOffset = pausedAt - pausedTotal
            layer.speed = 0
        }
    }

    /// Carry on from where `pause()` held: the drawing's time picks up where it stopped.
    public func resume() {
        guard isPaused else { return }
        pausedTotal += max(0, clock() - pausedAt)
        isPaused = false
        withoutActions {
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = pausedTotal
        }
    }

    // MARK: Events

    public func apply(_ events: [DrawingEvent]) {
        withoutActions {
            purge()
            for event in events { applyOne(event) }
        }
    }

    public func apply(_ event: DrawingEvent) { apply([event]) }

    private func applyOne(_ event: DrawingEvent) {
        switch event {
        case .marks(let marks):
            for mark in marks { paint(mark) }
        case .remove(let ids):
            for id in ids { remove(id) }
        case .step(let step):
            currentStep = step
            onEvent?(event)
        default:
            onEvent?(event)
        }
    }

    /// Ids of the marks on the canvas, in no particular order.
    public var markIDs: [String] { Array(entries.keys) }

    /// The container layer of a painted mark.
    public func layer(forMark id: String) -> CALayer? { entries[id]?.container }

    /// The button under a point in this layer's coordinates (points, y down), for click-to-ask. A button counts once
    /// it has started to appear: marks arrive ahead of their moment in the voice, and a click on a spot where a button
    /// is about to pop up belongs to the app underneath.
    public func buttonID(at point: CGPoint) -> String? {
        let now = self.now()
        for (id, entry) in entries where entry.mark.kind == "button" && beginTime(entry.mark.json) <= now {
            let affine = CATransform3DGetAffineTransform(entry.container.transform)
            if rect(entry.mark.json).applying(affine).contains(point) { return id }
        }
        return nil
    }

    /// The button or linked words under a point (points, y down), once they have started to appear.
    public func clickableID(at point: CGPoint) -> String? {
        if let button = buttonID(at: point) { return button }
        let now = self.now()
        for (id, entry) in entries where entry.mark.kind == "text" && entry.mark.json["link"] != nil && beginTime(entry.mark.json) <= now {
            let affine = CATransform3DGetAffineTransform(entry.container.transform)
            if rect(entry.mark.json).insetBy(dx: -4, dy: -4).applying(affine).contains(point) { return id }
        }
        return nil
    }

    /// Remove everything at once (no fade).
    public func clear() {
        withoutActions {
            for entry in entries.values { entry.container.removeFromSuperlayer() }
            for (id, figure) in figureLayers { figure.removeFromSuperlayer(); figureSink?.removeFigure(id) }
            for item in leaving { item.layer.removeFromSuperlayer() }
            entries.removeAll()
            figureLayers.removeAll()
            leaving.removeAll()
            currentStep = nil
        }
    }

    /// Drop layers whose fade-out has finished.
    public func purge() {
        let now = self.now()
        leaving.removeAll { item in
            guard item.at <= now else { return false }
            item.layer.removeFromSuperlayer()
            return true
        }
    }

    // MARK: Painting

    private func paint(_ mark: DrawingMark) {
        if mark.isFigureMark { forwardFigure(mark); return }
        let json = mark.json
        let begin = beginTime(json)
        let duration = max(0, mark.duration)
        var below: CALayer?
        if let existing = entries[mark.id] {
            if json["edit"]?.stringValue == "move" {
                glide(existing.container, to: transform(json), begin: begin, duration: max(duration, 0.2))
                entries[mark.id]?.mark = mark
                return
            }
            if json["edit"]?.stringValue == "grow" {
                // A card grew to hold what is drawn on it: the new card takes the old one's place in the stack (so
                // what was drawn on it stays on top) and glides out from the old size at `begin`.
                let (container, group) = build(mark, begin: begin, duration: duration)
                container.name = mark.id
                container.anchorPoint = .zero
                container.frame = layer.bounds
                container.transform = transform(json)
                Self.hideUntil(container, begin: begin)
                groups[group]?.insertSublayer(container, above: existing.container)
                retire(existing.container, at: begin, fade: 0.01)
                entries[mark.id] = Entry(container: container, mark: mark, group: group)
                return
            }
            // The host filled in a mark it was asked about (a photo arrived): swap it in place, no fade-out.
            if json["edit"]?.stringValue == "patch" { below = existing.container } else { retire(existing.container, at: begin) }
        }
        let (container, group) = build(mark, begin: begin, duration: duration)
        container.name = mark.id
        container.anchorPoint = .zero
        container.frame = layer.bounds
        container.transform = transform(json)
        if let below, below.superlayer === groups[group] {
            groups[group]?.insertSublayer(container, above: below)
            below.removeFromSuperlayer()
        } else if mark.kind == "spotlight" {
            // The dimmed screen goes under everything drawn, cards included.
            below?.removeFromSuperlayer()
            groups[group]?.insertSublayer(container, at: 0)
        } else {
            below?.removeFromSuperlayer()
            groups[group]?.addSublayer(container)
        }
        entries[mark.id] = Entry(container: container, mark: mark, group: group)
    }

    /// Keep a layer invisible until `begin` on the media clock.
    static func hideUntil(_ target: CALayer, begin: CFTimeInterval) {
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.beginTime = begin
        show.duration = 0.001
        // Held at 0 before it begins; the model value (1) afterwards.
        show.fillMode = .backwards
        target.add(show, forKey: "hideUntil")
    }

    private func remove(_ id: String) {
        if let figure = figureLayers.removeValue(forKey: id) {
            figure.removeFromSuperlayer()
            figureSink?.removeFigure(id)
            return
        }
        guard let entry = entries.removeValue(forKey: id) else { return }
        retire(entry.container, at: now())
    }

    /// Fade a layer out from `time` and drop it afterwards.
    private func retire(_ container: CALayer, at time: CFTimeInterval, fade length: CFTimeInterval = 0.35) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = container.opacity
        fade.toValue = 0
        fade.beginTime = time
        fade.duration = length
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        fade.timingFunction = Self.easeOut
        container.add(fade, forKey: "leave")
        leaving.append((container, time + length + 0.05))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(length + 0.1, time + length + 0.1 - now())) { [weak self] in
            MainActor.assumeIsolated { self?.purge() }
        }
    }

    private func glide(_ container: CALayer, to target: CATransform3D, begin: CFTimeInterval, duration: CFTimeInterval) {
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: container.transform)
        move.toValue = NSValue(caTransform3D: target)
        move.beginTime = begin
        move.duration = duration
        move.fillMode = .backwards
        move.timingFunction = Self.glide
        container.transform = target
        container.add(move, forKey: "move")
    }

    private func forwardFigure(_ mark: DrawingMark) {
        guard let sink = figureSink else { return }
        sink.apply(mark)
        guard mark.kind == "figure", let figure = sink.layer(forFigure: mark.id) else { return }
        figure.frame = rect(mark.json)
        if figure.superlayer !== groups[.main] { groups[.main]?.addSublayer(figure) }
        figureLayers[mark.id] = figure
    }

    // MARK: Geometry helpers

    func beginTime(_ json: JSONValue) -> CFTimeInterval {
        let base = json["base"]?.doubleValue ?? now()
        return base + (json["start"]?.doubleValue ?? 0)
    }

    func u(_ value: Double?) -> CGFloat { CGFloat((value ?? 0) * canvas.scale) }

    func point(_ json: JSONValue?) -> CGPoint {
        guard let pair = json?.arrayValue, pair.count >= 2 else { return .zero }
        return CGPoint(x: u(pair[0].doubleValue), y: u(pair[1].doubleValue))
    }

    func points(_ json: JSONValue?) -> [CGPoint] { (json?.arrayValue ?? []).map(point) }

    /// `at` + `w` × `h`, in points.
    func rect(_ json: JSONValue) -> CGRect {
        let origin = point(json["at"])
        return CGRect(x: origin.x, y: origin.y, width: u(json["w"]?.doubleValue), height: u(json["h"]?.doubleValue))
    }

    func color(_ json: JSONValue?, alpha: Double? = nil, fallback: DrawingColor = .defaultInk) -> CGColor {
        var c = DrawingColor(hex: json?.stringValue) ?? fallback
        if let alpha { c = c.withAlpha(c.alpha * alpha) }
        return c.cgColor
    }

    func transform(_ json: JSONValue) -> CATransform3D {
        guard let xf = json["xf"]?.arrayValue, xf.count >= 3 else { return CATransform3DIdentity }
        let k = CGFloat(xf[0].doubleValue ?? 1)
        return CATransform3DMakeAffineTransform(CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: u(xf[1].doubleValue), ty: u(xf[2].doubleValue)))
    }

    /// A path through points: straight segments, or a smooth Catmull-Rom curve through every point.
    static func path(_ pts: [CGPoint], smooth: Bool, closed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if !smooth || pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
        } else {
            let n = pts.count
            func at(_ i: Int) -> CGPoint {
                if closed { return pts[(i % n + n) % n] }
                return pts[min(max(i, 0), n - 1)]
            }
            let segments = closed ? n : n - 1
            for i in 0..<segments {
                let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        if closed { path.closeSubpath() }
        return path
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
