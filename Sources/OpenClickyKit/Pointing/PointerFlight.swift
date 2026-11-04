import CoreGraphics
import Foundation

/// The curved path the buddy pointer flies from one spot to another: a quadratic Bézier arc that bows upward on
/// screen, flown at a steady speed with eased ends. Works in AppKit global points (y up).
public struct PointerFlightPath: Sendable, Hashable {
    /// Cruise speed in points per second, and the clamp on how long any flight takes.
    public static let speed: Double = 800
    public static let shortestFlight: TimeInterval = 0.35
    public static let longestFlight: TimeInterval = 1.4
    /// How far the arc bows out: a fraction of the distance, capped.
    public static let arcFraction: Double = 0.2
    public static let maximumArc: Double = 80

    public var start: CGPoint
    public var control: CGPoint
    public var end: CGPoint
    public var duration: TimeInterval

    public init(from start: CGPoint, to end: CGPoint, duration: TimeInterval? = nil) {
        self.start = start
        self.end = end
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        self.duration = duration ?? Self.duration(forDistance: distance)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard distance > 0.5 else {
            control = mid
            return
        }
        let arc = min(Self.arcFraction * distance, Self.maximumArc)
        // Perpendicular to the chord, turned to point up on screen (+y in AppKit space).
        var nx = -dy / distance, ny = dx / distance
        if ny < 0 || (abs(ny) < 1e-9 && nx < 0) { nx = -nx; ny = -ny }
        // A quadratic curve bows half as far as its control point sits off the chord.
        control = CGPoint(x: mid.x + CGFloat(nx * arc * 2), y: mid.y + CGFloat(ny * arc * 2))
    }

    public static func duration(forDistance distance: Double) -> TimeInterval {
        min(longestFlight, max(shortestFlight, distance / speed))
    }

    /// Position at curve parameter `t` (0…1).
    public func position(at t: Double) -> CGPoint {
        let t = CGFloat(min(max(t, 0), 1)), u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }

    /// Direction of travel at curve parameter `t` (not normalized).
    public func velocity(at t: Double) -> CGVector {
        let t = CGFloat(min(max(t, 0), 1))
        return CGVector(dx: 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x),
                        dy: 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y))
    }

    /// The curve parameter reached `elapsed` seconds into the flight (eased in and out).
    public func progress(atTime elapsed: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return Self.easeInOut(elapsed / duration)
    }

    /// Cubic ease-in-out on 0…1.
    public static func easeInOut(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Mid-flight pose: where the tip is, how far the body turns toward the direction of travel (clockwise radians on
    /// screen, relative to the resting tilt) and how much it swells.
    public func pose(atTime elapsed: TimeInterval) -> (position: CGPoint, rotation: Double, scale: Double) {
        let linear = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
        let t = progress(atTime: elapsed)
        let v = velocity(at: t)
        var rotation = 0.0
        if abs(v.dx) + abs(v.dy) > 1e-6 {
            // Screen angles grow clockwise, so flip AppKit's y.
            let travel = atan2(-Double(v.dy), Double(v.dx))
            let turn = Self.wrap(travel - BuddyPointerGeometry.restingTipAngle)
            // Turn toward the heading early in the flight and settle back to rest before landing.
            let weight = Self.smoothstep(0, 0.22, linear) * (1 - Self.smoothstep(0.72, 1, linear))
            rotation = turn * weight
        }
        let scale = 1 + 0.22 * sin(Double.pi * linear)
        return (position(at: t), rotation, scale)
    }

    static func wrap(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a <= -.pi { a += 2 * .pi }
        return a
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// The buddy's drawn shape, shared by the renderer and the flight math.
public enum BuddyPointerGeometry {
    /// The resting tip points up and to the left, like the system arrow: the screen angle (clockwise from +x) of
    /// the direction from the body's center to the tip.
    public static let restingTipAngle: Double = {
        let cx = outline.map { Double($0.x) }.reduce(0, +) / Double(outline.count)
        let cy = outline.map { Double($0.y) }.reduce(0, +) / Double(outline.count)
        return atan2(-cy, -cx)
    }()

    /// The outline with the tip at the origin, in y-down points, before scaling: an arrowhead with a notched tail.
    public static let outline: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 17.5, y: 11.5), CGPoint(x: 9.6, y: 12.4), CGPoint(x: 6.2, y: 20.6),
    ]
}

/// One rendered moment of a pointing gesture.
public struct PointerFrame: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable { case appearing, flying, pointing, returning, vanishing, finished }

    public var phase: Phase
    /// Where the buddy's tip is (AppKit global points).
    public var position: CGPoint
    /// Clockwise radians on screen relative to the resting tilt.
    public var rotation: Double
    public var scale: Double
    public var opacity: Double
    public var target: ResolvedPointingTarget
    /// 0…1: how much of the ring around the target is drawn.
    public var haloProgress: Double
    /// 0…1, repeating: the breathing pulse while pointing.
    public var haloPulse: Double
    public var haloOpacity: Double
    public var label: String?
    public var labelOpacity: Double
}

/// The whole choreography of one "point at this": appear at the user's pointer, fly along an arc to the target, ring
/// it and show the label, hold, then fly back to wherever the user's pointer is now and fade into it.
public struct PointerGesture: Sendable, Hashable {
    public struct Timing: Sendable, Hashable {
        public var appear: TimeInterval = 0.18
        public var haloReveal: TimeInterval = 0.45
        public var labelFade: TimeInterval = 0.22
        public var pulsePeriod: TimeInterval = 1.6
        public var leaveFade: TimeInterval = 0.25
        public var vanish: TimeInterval = 0.2

        public init() {}
    }

    public var origin: CGPoint
    public var target: ResolvedPointingTarget
    public var label: String?
    public var outbound: PointerFlightPath
    public var timing: Timing
    /// Fade in and out in place instead of flying (Reduce Motion).
    public var reduceMotion: Bool
    /// Seconds from the start when the buddy heads back; nil holds until `release(at:)`.
    public private(set) var releaseTime: TimeInterval?
    public private(set) var returnDuration: TimeInterval

    public init(from origin: CGPoint, to target: ResolvedPointingTarget, label: String?, hold: TimeInterval? = 2.4,
                reduceMotion: Bool = false, timing: Timing = Timing()) {
        self.origin = origin
        self.target = target
        self.label = label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.timing = timing
        self.reduceMotion = reduceMotion
        outbound = PointerFlightPath(from: origin, to: target.point, duration: reduceMotion ? 0 : nil)
        returnDuration = reduceMotion ? 0 : outbound.duration
        if let hold { releaseTime = timing.appear + outbound.duration + max(hold, 0) }
    }

    public var arrivalTime: TimeInterval { timing.appear + outbound.duration }
    public var returnStart: TimeInterval? { releaseTime.map { max($0, arrivalTime) } }
    /// When the gesture is over, once the release time is known.
    public var endTime: TimeInterval? { returnStart.map { $0 + returnDuration + timing.vanish } }

    /// Start heading back at `elapsed` (or on arrival, if it hasn't arrived yet). A no-op once already released earlier.
    public mutating func release(at elapsed: TimeInterval) {
        if let releaseTime, releaseTime <= elapsed { return }
        releaseTime = elapsed
    }

    /// The frame `elapsed` seconds in. `cursor` is the user's pointer now (AppKit global): the return flight ends there.
    public func frame(at elapsed: TimeInterval, cursor: CGPoint) -> PointerFrame {
        var frame = PointerFrame(phase: .appearing, position: origin, rotation: 0, scale: 1, opacity: 1, target: target, haloProgress: 0,
                                 haloPulse: 0, haloOpacity: 0, label: label, labelOpacity: 0)
        let t = max(elapsed, 0)
        if t < timing.appear {
            let k = PointerFlightPath.easeInOut(t / timing.appear)
            frame.position = reduceMotion ? target.point : origin
            frame.opacity = k
            frame.scale = 0.55 + 0.45 * k
            return frame
        }
        if t < arrivalTime {
            let pose = outbound.pose(atTime: t - timing.appear)
            frame.phase = .flying
            frame.position = pose.position
            frame.rotation = pose.rotation
            frame.scale = pose.scale
            return frame
        }
        let pointingSince = t - arrivalTime
        frame.position = target.point
        frame.haloProgress = PointerFlightPath.easeInOut(pointingSince / timing.haloReveal)
        frame.haloPulse = (1 - cos(2 * .pi * pointingSince / timing.pulsePeriod)) / 2
        frame.haloOpacity = 1
        frame.labelOpacity = label == nil ? 0 : min(pointingSince / timing.labelFade, 1)
        guard let returnStart, t >= returnStart else {
            frame.phase = .pointing
            return frame
        }
        let leaving = t - returnStart
        let fade = max(0, 1 - leaving / timing.leaveFade)
        frame.haloOpacity = fade
        frame.labelOpacity *= fade
        if leaving < returnDuration {
            let back = PointerFlightPath(from: target.point, to: cursor, duration: returnDuration)
            let pose = back.pose(atTime: leaving)
            frame.phase = .returning
            frame.position = pose.position
            frame.rotation = pose.rotation
            frame.scale = pose.scale
            return frame
        }
        let vanishing = leaving - returnDuration
        frame.position = reduceMotion ? target.point : cursor
        frame.haloOpacity = 0
        frame.labelOpacity = 0
        if vanishing < timing.vanish {
            let k = PointerFlightPath.easeInOut(vanishing / timing.vanish)
            frame.phase = .vanishing
            frame.opacity = 1 - k
            frame.scale = 1 - 0.4 * k
            return frame
        }
        frame.phase = .finished
        frame.opacity = 0
        return frame
    }
}
