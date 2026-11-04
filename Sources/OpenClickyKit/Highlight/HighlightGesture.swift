import CoreGraphics
import Foundation

// Draw-to-ask (03 §5.4): while the talk key is held, moving the mouse paints highlighter ink; the marks are described
// in words, the text and controls under them are read (Accessibility, else on-device OCR), and the description rides
// with the turn (`TurnContext.highlightDescription`). Everything here is in AppKit global points (y up).

/// A pause in a stroke: the pointer stayed within a small circle for a while.
public struct HighlightDwell: Sendable, Hashable {
    public var point: CGPoint
    public var start: TimeInterval
    public var duration: TimeInterval
}

/// One continuous mark.
public struct HighlightStroke: Sendable, Hashable {
    public var points: [CGPoint]
    public var times: [TimeInterval]
    public var dwells: [HighlightDwell]

    public init(points: [CGPoint], times: [TimeInterval], dwells: [HighlightDwell] = []) {
        self.points = points
        self.times = times
        self.dwells = dwells
    }

    public var bounds: CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    public var length: CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    public var startTime: TimeInterval { times.first ?? 0 }
    public var endTime: TimeInterval { times.last ?? 0 }
    /// The longest pause on this stroke.
    public var longestDwell: HighlightDwell? { dwells.max { $0.duration < $1.duration } }
}

/// Everything drawn during one hold of the talk key, in order.
public struct HighlightGesture: Sendable, Hashable {
    public var strokes: [HighlightStroke]

    public init(strokes: [HighlightStroke]) { self.strokes = strokes }

    public var isEmpty: Bool { strokes.isEmpty }
}

/// Turns pointer samples (about 60 a second while the key is held) into strokes.
///
/// Ink starts only once the pointer has moved `activationDistance` from where the hold began, so holding the key
/// still to talk draws nothing, and only at drawing speed: a fast move between marks is travel and leaves no ink. Samples closer than `minimumSpacing` to the last one are dropped. A pause within
/// `dwellRadius` for `dwellMinimum` is a dwell ("pausing on…"); a pause longer than `strokeBreak` ends the stroke, and
/// moving on again starts the next one ("drew 2 marks").
public struct HighlightRecorder: Sendable {
    public struct Settings: Sendable, Hashable {
        public var activationDistance: CGFloat = 8
        public var minimumSpacing: CGFloat = 1.5
        public var dwellRadius: CGFloat = 12
        public var dwellMinimum: TimeInterval = 0.35
        public var strokeBreak: TimeInterval = 0.9
        /// Between marks, the pointer moving faster than this (points per second) is travelling to the next thing,
        /// not drawing: ink starts where it slows down.
        public var travelSpeed: CGFloat = 2600
        /// Points kept per stroke (about 40 s at 60 Hz).
        public var maximumPoints = 2_400
        public var maximumStrokes = 8

        public init() {}
    }

    public var settings: Settings
    public private(set) var strokes: [HighlightStroke] = []
    public private(set) var isHolding = false

    private var anchor: CGPoint?
    private var current: HighlightStroke?
    /// Where the pointer has been resting, and since when.
    private var rest: (point: CGPoint, since: TimeInterval)?
    private var lastSample: (point: CGPoint, time: TimeInterval)?

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// The talk key went down with the pointer at `point`.
    public mutating func begin(at point: CGPoint, time: TimeInterval) {
        strokes = []
        current = nil
        isHolding = true
        anchor = point
        rest = (point, time)
        lastSample = (point, time)
    }

    /// A pointer sample. Returns true when the ink changed (for the live overlay).
    @discardableResult
    public mutating func move(to point: CGPoint, time: TimeInterval) -> Bool {
        guard isHolding, point.x.isFinite, point.y.isFinite else { return false }
        defer { lastSample = (point, time) }
        // Leaving the resting circle closes the pause (a dwell if it was long enough) and starts watching anew.
        if let resting = rest {
            if hypot(point.x - resting.point.x, point.y - resting.point.y) > settings.dwellRadius {
                closeRest(endingAt: time)
                rest = (point, time)
            }
        } else {
            rest = (point, time)
        }
        if current == nil {
            if let last = lastSample, time > last.time,
               hypot(point.x - last.point.x, point.y - last.point.y) / CGFloat(time - last.time) > settings.travelSpeed {
                anchor = point
                return false
            }
            guard let anchor, hypot(point.x - anchor.x, point.y - anchor.y) >= settings.activationDistance else { return false }
            guard strokes.count < settings.maximumStrokes else { return false }
            // Start the stroke where the pointer left the anchor, so the ink touches what it began on.
            current = HighlightStroke(points: [anchor, point], times: [lastSample?.time ?? time, time])
            return true
        }
        guard var stroke = current, let last = stroke.points.last else { return false }
        guard hypot(point.x - last.x, point.y - last.y) >= settings.minimumSpacing, stroke.points.count < settings.maximumPoints else { return false }
        stroke.points.append(point)
        stroke.times.append(time)
        current = stroke
        return true
    }

    /// Time passes without movement (the poller calls this when the pointer is still): long pauses end the stroke.
    public mutating func idle(at time: TimeInterval) {
        guard isHolding else { return }
        // The pointer was still until now: the next move's speed is measured from here.
        if let last = lastSample { lastSample = (last.point, max(last.time, time)) }
        guard let resting = rest, current != nil, time - resting.since >= settings.strokeBreak else { return }
        finishStroke(at: time)
        anchor = resting.point
    }

    /// The key went up: everything drawn, or nil when nothing was (the user only talked).
    public mutating func end(at time: TimeInterval) -> HighlightGesture? {
        guard isHolding else { return nil }
        if current != nil { finishStroke(at: time) }
        isHolding = false
        anchor = nil
        rest = nil
        return strokes.isEmpty ? nil : HighlightGesture(strokes: strokes)
    }

    /// The strokes to draw right now (finished ones and the one in progress).
    public var liveStrokes: [[CGPoint]] { strokes.map(\.points) + (current.map { [$0.points] } ?? []) }

    private mutating func closeRest(endingAt time: TimeInterval) {
        guard let resting = rest, var stroke = current else { return }
        let duration = time - resting.since
        guard duration >= settings.dwellMinimum else { return }
        stroke.dwells.append(HighlightDwell(point: resting.point, start: resting.since, duration: duration))
        current = stroke
    }

    private mutating func finishStroke(at time: TimeInterval) {
        guard var stroke = current else { return }
        // A pause at the very end counts as a dwell (but not past the stroke break).
        if let resting = rest {
            let duration = min(time, resting.since + settings.strokeBreak) - resting.since
            if duration >= settings.dwellMinimum, stroke.dwells.last?.start != resting.since {
                stroke.dwells.append(HighlightDwell(point: resting.point, start: resting.since, duration: duration))
            }
        }
        if stroke.points.count >= 2 { strokes.append(stroke) }
        current = nil
    }
}
