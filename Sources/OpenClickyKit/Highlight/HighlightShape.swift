import CoreGraphics
import Foundation

/// What a highlighter stroke was.
public enum HighlightMarkKind: String, Sendable, Hashable, CaseIterable {
    /// A loop around something.
    case circle
    /// A mostly level stroke under (or through) a line of words.
    case underline
    /// A stroke from one place toward another.
    case line
    /// Back and forth over something.
    case scribble
}

/// One stroke, understood: its kind and the area of the screen it is about (AppKit global points).
public struct HighlightMark: Sendable, Hashable {
    public var kind: HighlightMarkKind
    public var stroke: HighlightStroke
    /// What the mark is about: inside a loop, the words over an underline, the end of a line, under a scribble.
    public var region: CGRect
    /// The spot the mark singles out: a loop's centre, a line's end.
    public var focus: CGPoint
    public var start: CGPoint
    public var end: CGPoint
    /// The longest pause on the stroke, in seconds (0 when it never paused).
    public var dwellSeconds: Double

    public init(kind: HighlightMarkKind, stroke: HighlightStroke, region: CGRect, focus: CGPoint, start: CGPoint, end: CGPoint, dwellSeconds: Double) {
        self.kind = kind
        self.stroke = stroke
        self.region = region
        self.focus = focus
        self.start = start
        self.end = end
        self.dwellSeconds = dwellSeconds
    }
}

/// Measures of a stroke's path used to tell circles, underlines, lines and scribbles apart.
public struct HighlightPathMetrics: Sendable, Hashable {
    public var bounds: CGRect
    public var length: CGFloat
    /// Distance from start to end over the bounds' diagonal: near 0 for a closed loop.
    public var closure: CGFloat
    /// Distance from start to end over the path length: 1 for a straight stroke.
    public var straightness: CGFloat
    /// Total signed turning along the path, in radians (±2π for one full loop).
    public var turning: CGFloat
    /// How many times the stroke reversed direction horizontally plus vertically.
    public var reversals: Int

    public init(_ points: [CGPoint]) {
        let first = points.first ?? .zero, last = points.last ?? .zero
        var box = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        bounds = box
        let lengthValue = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        length = lengthValue
        let diagonal = max(1, hypot(box.width, box.height))
        let chord = hypot(last.x - first.x, last.y - first.y)
        closure = chord / diagonal
        straightness = chord / max(1, lengthValue)
        // Resample at an even spacing so jitter between 60 Hz samples doesn't count as turning.
        let even = Self.resample(points, spacing: max(4, lengthValue / 120))
        var turn: CGFloat = 0
        var previous: CGFloat?
        var signX = 0, signY = 0, flips = 0
        for (a, b) in zip(even, even.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            guard hypot(dx, dy) > 0.01 else { continue }
            let angle = atan2(dy, dx)
            if let previous {
                var delta = angle - previous
                while delta > .pi { delta -= 2 * .pi }
                while delta < -.pi { delta += 2 * .pi }
                turn += delta
            }
            previous = angle
            let sx = abs(dx) < 1.5 ? 0 : (dx > 0 ? 1 : -1), sy = abs(dy) < 1.5 ? 0 : (dy > 0 ? 1 : -1)
            if sx != 0 { if signX != 0, sx != signX { flips += 1 }; signX = sx }
            if sy != 0 { if signY != 0, sy != signY { flips += 1 }; signY = sy }
        }
        turning = turn
        reversals = flips
    }

    static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var last = points.first else { return [] }
        var out = [last]
        var carry: CGFloat = 0
        for p in points.dropFirst() {
            var segment = hypot(p.x - last.x, p.y - last.y)
            var from = last
            while carry + segment >= spacing, segment > 0 {
                let t = (spacing - carry) / segment
                let q = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
                out.append(q)
                segment = hypot(p.x - q.x, p.y - q.y)
                from = q
                carry = 0
            }
            carry += segment
            last = p
        }
        if let end = points.last, out.last != end { out.append(end) }
        return out
    }
}

public enum HighlightClassifier {
    /// How far above an underline the words it marks may reach (points).
    public static let underlineReach: CGFloat = 30
    /// The box a line's end is taken to point at (points).
    public static let lineEndBox = CGSize(width: 90, height: 48)

    public static func classify(_ stroke: HighlightStroke) -> HighlightMark {
        let points = stroke.points
        let m = HighlightPathMetrics(points)
        let b = m.bounds
        let start = points.first ?? .zero, end = points.last ?? .zero
        let loop = abs(m.turning)
        let kind: HighlightMarkKind
        if (loop >= 1.5 * .pi && m.closure <= 0.45) || loop >= 1.8 * .pi {
            kind = .circle
        } else if m.reversals >= 4, m.length >= 2.5 * max(1, hypot(b.width, b.height)) {
            kind = .scribble
        } else if m.straightness >= 0.8, b.width >= 16, b.height <= max(0.2 * b.width, 12) {
            kind = .underline
        } else if loop >= 1.1 * .pi, m.closure <= 0.6 {
            kind = .circle
        } else {
            kind = .line
        }
        let region: CGRect
        let focus: CGPoint
        switch kind {
        case .circle, .scribble:
            region = b.insetBy(dx: -4, dy: -4)
            focus = CGPoint(x: b.midX, y: b.midY)
        case .underline:
            // AppKit y grows upward: the words sit above the stroke. A little below counts too (strike-through).
            region = CGRect(x: b.minX - 4, y: b.minY - 6, width: b.width + 8, height: b.height + 6 + underlineReach)
            focus = CGPoint(x: region.midX, y: region.midY)
        case .line:
            region = b.width < 60 && b.height < 60
                ? b.insetBy(dx: -12, dy: -12)
                : CGRect(x: end.x - lineEndBox.width / 2, y: end.y - lineEndBox.height / 2, width: lineEndBox.width, height: lineEndBox.height)
            focus = end
        }
        return HighlightMark(kind: kind, stroke: stroke, region: region, focus: focus, start: start, end: end,
                             dwellSeconds: stroke.longestDwell?.duration ?? 0)
    }

    public static func marks(_ gesture: HighlightGesture) -> [HighlightMark] { gesture.strokes.map(classify) }
}
