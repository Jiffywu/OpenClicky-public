import CoreGraphics
import Foundation
import simd

public enum FigureLook: String, Sendable, CaseIterable {
    /// Photographic: PBR, soft shadows, ambient occlusion, reflections, glass.
    case studio
    /// Flat two-tone colour with an ink outline, like a hand-drawn diagram.
    case illustrated
}

/// Camera settings of a figure (docs/dsl-3d.md §1 and §7). Angles in degrees, spin in turns per minute.
public struct FigureCamera: Sendable, Equatable {
    public var tilt: Float = 18
    public var turn: Float = 0
    public var spin: Float = 2
    public var zoom: Float = 1
    public var fov: Float = 30
    public var target: SIMD3<Float>?

    public init() {}

    mutating func merge(_ json: JSONValue?, amount k: Float = 1) {
        guard let json else { return }
        if let v = json["tilt"]?.float { tilt += (v - tilt) * k }
        if let v = json["turn"]?.float { turn += (v - turn) * k }
        if let v = json["zoom"]?.float { zoom += (v - zoom) * k }
        if let v = json["fov"]?.float { fov += (v - fov) * k }
        if let v = json["spin"]?.float { spin = v }
        if let v = json["target"]?.vector3 { target = (target ?? v) + (v - (target ?? v)) * k }
    }
}

/// A motion attached to a part (spin, orbit, swing, bob, pulse) or a one-off change (glide, set, stop).
public struct FigureMotion: Sendable {
    public enum Kind: String, Sendable { case spin, orbit, swing, bob, pulse, path, glide, set, stop }
    public var kind: Kind
    public var start: Double
    public var axis: SIMD3<Float> = [0, 1, 0]
    public var period: Float = 4
    public var amount: Float = 0.1
    public var angle: Float = 25
    public var center: SIMD3<Float> = .zero
    public var pivot: SIMD3<Float>?
    public var to: SIMD3<Float>?
    public var rotation: simd_quatf?
    public var secs: Double = 0.8
    public var show: Bool?
    public var glow: Float?
    public var color: SIMD3<Float>?
    public var scale: Float?
    /// For `path`: the curve to travel along, once or round and round.
    public var path: FigureCurve?
    public var once = false

    init?(json: JSONValue, start: Double) {
        guard let kind = json["motion"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        self.start = start
        if let v = json["axis"]?.vector3, simd_length(v) > 1e-6 { axis = simd_normalize(v) }
        if let v = json["period"]?.float, abs(v) > 1e-4 { period = v }
        if let v = json["amount"]?.float { amount = v }
        if let v = json["angle"]?.float { angle = v }
        if let v = json["center"]?.vector3 { center = v }
        pivot = json["pivot"]?.vector3
        to = json["to"]?.vector3
        if let q = json["quat"]?.vector4 { rotation = simd_normalize(simd_quatf(vector: q)) }
        else if let r = json["rot"]?.vector3 { rotation = FigureMath.quaternion(eulerDegrees: r) }
        if let v = json["secs"]?.doubleValue { secs = max(0.01, v) }
        show = json["show"]?.boolValue
        glow = json["glow"]?.float
        color = json["color"]?.stringValue.flatMap(FigureColor.linear(hex:))
        scale = json["scale"]?.float
        once = json["once"]?.boolValue ?? false
        if kind == .path {
            let points = json["points"]?.arrayValue?.compactMap(\.vector3) ?? []
            guard points.count >= 2 else { return nil }
            path = FigureCurve(points: points, closed: json["closed"]?.boolValue ?? false)
        }
    }
}

/// A Catmull-Rom curve through points, walked at an even speed by arc length.
public struct FigureCurve: Sendable {
    public let points: [SIMD3<Float>]
    public let closed: Bool
    private var lengths: [Float] = [0]
    private static let samplesPerSegment = 24

    public init(points: [SIMD3<Float>], closed: Bool) {
        self.points = points
        self.closed = closed && points.count > 2
        var previous = raw(0)
        let total = segmentCount * Self.samplesPerSegment
        for k in 1...max(1, total) {
            let p = raw(Float(k) / Float(total))
            lengths.append(lengths[k - 1] + simd_distance(previous, p))
            previous = p
        }
    }

    private var segmentCount: Int { closed ? points.count : points.count - 1 }
    public var length: Float { lengths.last ?? 0 }

    /// The point a `fraction` (0...1) of the way along the curve by distance.
    public func point(at fraction: Float) -> SIMD3<Float> {
        let target = min(1, max(0, fraction)) * length
        var lo = 0, hi = lengths.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] <= target { lo = mid } else { hi = mid }
        }
        let span = lengths[hi] - lengths[lo]
        let local = span > 0 ? (target - lengths[lo]) / span : 0
        let total = Float(lengths.count - 1)
        return raw((Float(lo) + local) / total)
    }

    /// The curve by parameter (not distance): segment i runs from point i to point i + 1.
    private func raw(_ t: Float) -> SIMD3<Float> {
        let n = points.count
        let scaled = min(1, max(0, t)) * Float(segmentCount)
        let i = min(segmentCount - 1, Int(scaled))
        let u = scaled - Float(i)
        func at(_ k: Int) -> SIMD3<Float> {
            if closed { return points[((k % n) + n) % n] }
            return points[min(n - 1, max(0, k))]
        }
        let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
        let u2 = u * u, u3 = u2 * u
        return 0.5 * ((2 * p1) + (p2 - p0) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (3 * p1 - p0 - 3 * p2 + p3) * u3)
    }
}

/// Per-frame pose written by a tick function (docs/dsl-3d.md §10).
public struct FigureTickPose: Sendable, Equatable {
    public var mask = 0
    public var position: SIMD3<Float> = .zero
    public var rotation: SIMD3<Float> = .zero
    public var scale: Float = 1
    public var glow: Float = 0
    public var shown = true
    public var color: SIMD3<Float> = .one

    public static let floatsPerPose = 12
}

/// One part (or group) of a figure.
public final class FigureNode {
    public let id: String
    /// 1-based number within the figure; also the picking id.
    public let number: Int
    public let kind: String
    public let name: String?
    public let recipe: String?
    public var mesh: FigureMesh?
    public var meshError: String?
    public var material: FigureMaterial
    /// The named material (`steel`, `glass`, …), if the part chose one.
    public let materialName: String?
    /// Cut plane in the parent's space: xyz normal toward the removed half, w offset.
    public let cut: SIMD4<Float>?
    public let parentID: String?
    public let copyOf: String?
    public let basePosition: SIMD3<Float>
    public let baseRotation: simd_quatf
    public let baseScale: Float
    /// Reflection signs of a mirrored copy; motions are reflected the same way.
    public let mirror: SIMD3<Float>
    /// When the part starts growing in. A part whose mesh arrives late starts when it arrives.
    public internal(set) var appearAt: Double
    public let growDuration: Double
    public var motions: [FigureMotion] = []
    public var tickPose = FigureTickPose()

    public var isGroup: Bool { kind == "group" }

    init(mark: DrawingMark, appearAt: Double) {
        let json = mark.json
        id = mark.id
        number = json["n"]?.intValue ?? 0
        kind = json["kind"]?.stringValue ?? "box"
        name = json["name"]?.stringValue
        recipe = json["recipe"]?.stringValue
        material = FigureMaterials.resolve(json["material"])
        materialName = json["material"]?["mat"]?.stringValue
        cut = json["cut"]?.vector4
        parentID = json["parent"]?.stringValue
        copyOf = json["copyOf"]?.stringValue
        basePosition = json["at"]?.vector3 ?? .zero
        if let q = json["quat"]?.vector4 { baseRotation = simd_normalize(simd_quatf(vector: q)) }
        else { baseRotation = FigureMath.quaternion(eulerDegrees: json["rot"]?.vector3 ?? .zero) }
        baseScale = max(0, json["scale"]?.float ?? 1)
        mirror = json["mirror"]?.vector3 ?? [1, 1, 1]
        self.appearAt = appearAt
        growDuration = max(0, mark.duration)
    }

    /// The part's local transform (in its parent's space) at `time`.
    func localPose(at time: Double, includeGrow: Bool) -> (matrix: simd_float4x4, shown: Bool, glow: Float, color: SIMD3<Float>) {
        var position = basePosition
        var rotation = baseRotation
        var scale = baseScale
        var shown = true
        var glow = material.glow
        var color = material.color
        var stopTime: Double?
        for motion in motions where motion.start <= time {
            switch motion.kind {
            case .glide:
                let k = Float(FigureMath.ease((time - motion.start) / motion.secs))
                if let to = motion.to { position += (to - position) * k }
                if let q = motion.rotation { rotation = simd_slerp(rotation, q, k) }
            case .set:
                if let v = motion.show { shown = v }
                if let v = motion.glow { glow = v }
                if let v = motion.color { color = v }
                if let v = motion.scale { scale = v }
            case .stop:
                stopTime = motion.start
            default: break
            }
        }
        let det = mirror.x * mirror.y * mirror.z
        for motion in motions where motion.start <= time {
            var elapsed = Float(time - motion.start)
            if let stopTime, motion.start < stopTime { elapsed = Float(stopTime - motion.start) }
            let axis = simd_normalize(motion.axis * mirror)
            let phase = 2 * Float.pi * elapsed / motion.period
            switch motion.kind {
            case .spin, .swing:
                let angle = motion.kind == .spin ? phase : FigureMath.radians(motion.angle) * sin(phase)
                let turn = simd_quatf(angle: angle * det, axis: axis)
                let pivot = motion.pivot.map { $0 * mirror } ?? position
                position = pivot + turn.act(position - pivot)
                rotation = turn * rotation
            case .orbit:
                let turn = simd_quatf(angle: phase * det, axis: axis)
                let center = motion.center * mirror
                position = center + turn.act(position - center)
            case .bob:
                position += axis * motion.amount * sin(phase)
            case .pulse:
                scale *= 1 + motion.amount * sin(phase)
            case .path:
                guard let curve = motion.path else { break }
                let progress = elapsed / motion.period
                let fraction = motion.once ? min(1, progress) : progress - floor(progress)
                position = curve.point(at: fraction) * mirror
            default: break
            }
        }
        let pose = tickPose
        if pose.mask & 1 != 0 { position = pose.position }
        if pose.mask & 2 != 0 { rotation = FigureMath.quaternion(eulerDegrees: pose.rotation) }
        if pose.mask & 4 != 0 { scale = pose.scale }
        if pose.mask & 8 != 0 { shown = pose.shown }
        if pose.mask & 16 != 0 { glow = pose.glow }
        if pose.mask & 32 != 0 { color = pose.color }
        if includeGrow {
            if time < appearAt { scale = 0 }
            else if growDuration > 0 { scale *= Float(FigureMath.easeOutBack((time - appearAt) / growDuration)) }
        }
        let matrix = FigureMath.translation(position) * simd_float4x4(rotation) * FigureMath.scale(SIMD3(repeating: scale))
        return (matrix, shown, glow, color)
    }
}

/// Room kept free around the object (for labels), in points.
public struct FigureInsets: Sendable, Equatable {
    public var left: CGFloat
    public var right: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    public static let zero = FigureInsets()
}

/// A label beside the figure with a leader line to a part or point.
public struct FigureLabel: Sendable, Equatable {
    public var id: String
    public var text: String
    public var point: SIMD3<Float>?
    public var follow: String?
    public var side: String?
    public var size: Float
    public var start: Double
    public var duration: Double
}

/// What the renderer draws for one part this frame.
public struct FigureDrawItem: Sendable {
    public var nodeID: String
    public var mesh: FigureMesh
    public var model: simd_float4x4
    public var material: FigureMaterial
    public var pickID: UInt32
    /// World-space cut plane (normal toward the removed half, offset), if cut.
    public var cut: SIMD4<Float>?
    public var highlight: Float
    /// Distance from the eye, for sorting see-through parts.
    public var depth: Float
}

/// Everything needed to draw one figure frame.
public struct FigureFrame: Sendable {
    public var items: [FigureDrawItem]
    public var look: FigureLook
    /// Size of the figure's rectangle in points.
    public var viewport: CGSize
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var view: simd_float4x4
    public var projection: simd_float4x4
    public var yaw: Float
    public var fovY: Float
    public var near: Float
    public var far: Float
    public var center: SIMD3<Float>
    public var radius: Float
    public var groundY: Float
    /// Ink colour, sRGB 0...1.
    public var ink: SIMD3<Float>
    /// World-space anchor of each part (centre of its bounds), for labels.
    public var anchors: [String: SIMD3<Float>]
    /// A few world-space points on each part (groups: on their members), so a label's leader can end on the edge
    /// of the part nearest the label.
    public var anchorSamples: [String: [SIMD3<Float>]] = [:]
    /// The drawn parts' projected bounds in the figure rectangle (points, top-left origin), if anything is drawn.
    public var objectBounds: CGRect?

    public var viewProjection: simd_float4x4 { projection * view }

    /// Project a world point into the figure rectangle (points, top-left origin).
    public func project(_ point: SIMD3<Float>) -> CGPoint {
        let clip = viewProjection * SIMD4(point, 1)
        let w = max(clip.w, 1e-5)
        let ndc = SIMD2(clip.x / w, clip.y / w)
        return CGPoint(x: CGFloat((ndc.x * 0.5 + 0.5)) * viewport.width, y: CGFloat((0.5 - ndc.y * 0.5)) * viewport.height)
    }

    /// Screen-space bounds of the object's framing sphere.
    public var objectScreenBounds: CGRect {
        let c = project(center)
        let distance = max(simd_length(eye - center), radius * 1.01)
        let pixelsPerUnit = CGFloat(1 / tan(fovY / 2)) * viewport.height / 2 / CGFloat(distance)
        let r = CGFloat(radius) * pixelsPerUnit
        return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }
}

/// The scene model of one figure: parts, motions, camera, labels and readouts, built from 3D marks.
public final class FigureScene {
    public let id: String
    public private(set) var rect: CGRect
    public private(set) var look: FigureLook
    public private(set) var inkHex: String
    public private(set) var title: String?
    public private(set) var card: Bool?
    public private(set) var baseCamera = FigureCamera()
    public private(set) var nodes: [FigureNode] = []
    public private(set) var labels: [FigureLabel] = []
    public private(set) var readouts: [(key: String, value: String)] = []
    /// Started ticks: id and the time their line started.
    public private(set) var ticks: [(id: String, start: Double)] = []
    public let createdAt: Double
    public let appearDuration: Double

    /// Turntable angle accumulated by `advance`, degrees.
    public var spinAngle: Float = 0
    /// Offsets from the user's drag, degrees.
    public var dragYaw: Float = 0
    public var dragTilt: Float = 0
    /// Part briefly brightened after a click, and when.
    public var highlighted: (id: String, since: Double)?

    private var nodeByID: [String: FigureNode] = [:]
    private var nodeByNumber: [Int: FigureNode] = [:]
    private var cameraMoves: [(start: Double, secs: Double, json: JSONValue)] = []
    private var lastAdvance: Double?

    public init(mark: DrawingMark, at time: Double) {
        let json = mark.json
        id = mark.id
        rect = Self.rect(json) ?? CGRect(x: 0, y: 0, width: 480, height: 400)
        look = FigureLook(rawValue: json["look"]?.stringValue ?? "") ?? .studio
        inkHex = json["ink"]?.stringValue ?? "#30333A"
        title = json["title"]?.stringValue
        card = json["card"]?.boolValue
        baseCamera.merge(json["camera"])
        createdAt = time
        appearDuration = mark.duration
    }

    /// The figure's rectangle in canvas points: `rect: [x, y, w, h]`, or `at: [x, y]` with `w` and `h`.
    static func rect(_ json: JSONValue) -> CGRect? {
        let r = json["rect"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        if r.count == 4 { return CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }
        let at = json["at"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        guard at.count >= 2, let w = json["w"]?.doubleValue, let h = json["h"]?.doubleValue else { return nil }
        return CGRect(x: at[0], y: at[1], width: w, height: h)
    }

    public func node(_ id: String) -> FigureNode? { nodeByID[id] }
    public func node(number: Int) -> FigureNode? { nodeByNumber[number] }
    public var hasCut: Bool { nodes.contains { $0.cut != nil } }
    public var ink: SIMD3<Float> { FigureColor.srgb(hex: inkHex) ?? SIMD3(0.19, 0.2, 0.23) }

    /// Use a different look than the program asked for (e.g. a settings override or a GPU fallback).
    public func setLook(_ look: FigureLook) { self.look = look }

    /// Apply a 3D mark that should take effect at `time`. Returns the part that needs a mesh, if any.
    @discardableResult
    public func apply(_ mark: DrawingMark, at time: Double) -> FigureNode? {
        let json = mark.json
        switch mark.kind {
        case "figure":
            if let r = Self.rect(json) { rect = r }
            if let look = json["look"]?.stringValue.flatMap(FigureLook.init(rawValue:)) { self.look = look }
            return nil
        case "part3d":
            if let existing = nodeByID[mark.id] {
                // A changed part (recolour): keep its mesh, take the new material.
                existing.material = FigureMaterials.resolve(json["material"])
                return nil
            }
            let node = FigureNode(mark: mark, appearAt: time)
            nodes.append(node)
            nodeByID[node.id] = node
            nodeByNumber[node.number] = node
            return node.isGroup ? nil : node
        case "motion3d":
            guard let motion = FigureMotion(json: json, start: time) else { return nil }
            let targets = json["targets"]?.arrayValue?.compactMap(\.stringValue) ?? [json["target"]?.stringValue].compactMap { $0 }
            // A glide of a part with copies gives each copy its own end pose (`tos` / `rots`, in `targets` order).
            let tos = json["tos"]?.arrayValue ?? [], rots = json["rots"]?.arrayValue ?? []
            for (index, target) in targets.enumerated() {
                var own = motion
                if index < tos.count, let to = tos[index].vector3 { own.to = to }
                if index < rots.count, let rot = rots[index].vector3 { own.rotation = FigureMath.quaternion(eulerDegrees: rot) }
                nodeByID[target]?.motions.append(own)
            }
        case "camera3d":
            cameraMoves.append((time, json["secs"]?.doubleValue ?? 1, json))
        case "label3d":
            labels.removeAll { $0.id == mark.id }
            labels.append(FigureLabel(
                id: mark.id, text: json["text"]?.stringValue ?? "", point: json["point"]?.vector3,
                follow: json["follow"]?.stringValue, side: json["side"]?.stringValue, size: json["size"]?.float ?? 17,
                start: time, duration: mark.duration))
        case "tick3d":
            if !ticks.contains(where: { $0.id == mark.id }) { ticks.append((mark.id, time)) }
        case "readout3d":
            if let values = json["values"]?.objectValue {
                applyReadouts(values.compactMapValues { $0.stringValue ?? $0.doubleValue.map { String($0) } })
            }
        default:
            break
        }
        return nil
    }

    /// Replace the readout panel's values (keys keep their first-seen order).
    public func applyReadouts(_ values: [String: String]) {
        readouts.removeAll { values[$0.key] == nil }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if let index = readouts.firstIndex(where: { $0.key == key }) { readouts[index].value = value }
            else { readouts.append((key, value)) }
        }
    }

    /// Apply the tick bridge's packed poses (12 floats per part). The numbers come from the program's JavaScript
    /// context, so a pose with anything non-finite or out of range is skipped rather than trusted.
    public func applyTickPoses(_ floats: [Float]) {
        let n = FigureTickPose.floatsPerPose
        for o in stride(from: 0, to: floats.count - n + 1, by: n) {
            guard floats[o..<(o + n)].allSatisfy(\.isFinite), floats[o] >= 1, floats[o] <= 1e6,
                  floats[o + 1] >= 0, floats[o + 1] < 64,
                  let node = nodeByNumber[Int(floats[o])] else { continue }
            var pose = FigureTickPose()
            pose.mask = Int(floats[o + 1])
            pose.position = SIMD3(floats[o + 2], floats[o + 3], floats[o + 4])
            pose.rotation = SIMD3(floats[o + 5], floats[o + 6], floats[o + 7])
            pose.scale = max(0, floats[o + 8])
            pose.glow = floats[o + 9]
            pose.shown = floats[o + 10] > 0.5
            pose.color = FigureColor.linear(FigureColor.srgb(rgb24: UInt32(min(0xFFFFFF, max(0, floats[o + 11])))))
            node.tickPose = pose
        }
    }

    /// Camera settings at `time`, with camera moves glided in.
    public func camera(at time: Double) -> FigureCamera {
        var camera = baseCamera
        for move in cameraMoves where move.start <= time {
            camera.merge(move.json, amount: Float(FigureMath.ease((time - move.start) / max(0.01, move.secs))))
        }
        return camera
    }

    /// Advance the turntable to `time` (call once per displayed frame; pass `paused` while the user drags).
    public func advance(to time: Double, paused: Bool = false) {
        defer { lastAdvance = time }
        guard let last = lastAdvance, !paused else { return }
        let dt = Float(min(0.25, max(0, time - last)))
        spinAngle += camera(at: time).spin * 6 * dt
    }

    /// Current turntable yaw in degrees: a full turn, or a sway around the front when the figure has a cut-away.
    public func yaw(at time: Double) -> Float {
        let camera = camera(at: time)
        let turning = hasCut ? 28 * sin(FigureMath.radians(spinAngle) * 2) : spinAngle
        return camera.turn + turning + dragYaw
    }

    /// World transforms of every node at `time`.
    func worldPoses(at time: Double, includeGrow: Bool) -> [String: (matrix: simd_float4x4, shown: Bool, glow: Float, color: SIMD3<Float>)] {
        var result: [String: (matrix: simd_float4x4, shown: Bool, glow: Float, color: SIMD3<Float>)] = [:]
        func resolve(_ node: FigureNode, depth: Int) -> (matrix: simd_float4x4, shown: Bool, glow: Float, color: SIMD3<Float>) {
            if let done = result[node.id] { return done }
            var pose = node.localPose(at: time, includeGrow: includeGrow)
            if depth < 32, let parentID = node.parentID, let parent = nodeByID[parentID], parent !== node {
                let parentPose = resolve(parent, depth: depth + 1)
                pose.matrix = parentPose.matrix * pose.matrix
                pose.shown = pose.shown && parentPose.shown
            }
            result[node.id] = pose
            return pose
        }
        for node in nodes { _ = resolve(node, depth: 0) }
        return result
    }

    /// Bounding sphere of the parts that have appeared, at full size.
    public func framing(at time: Double) -> (center: SIMD3<Float>, radius: Float)? {
        let poses = worldPoses(at: time, includeGrow: false)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var points: [SIMD3<Float>] = []
        for node in nodes where node.appearAt <= time + 0.001 {
            guard let mesh = node.mesh, let pose = poses[node.id], pose.shown else { continue }
            for sample in mesh.samples {
                let p = (pose.matrix * SIMD4(sample, 1)).xyz
                lo = simd_min(lo, p); hi = simd_max(hi, p)
                points.append(p)
            }
        }
        guard !points.isEmpty else { return nil }
        let center = (lo + hi) / 2
        var radius: Float = 0
        for p in points { radius = max(radius, simd_distance(p, center)) }
        return (center, max(radius, 0.05))
    }

    /// Build the draw list and camera for `time`.
    /// - Parameters:
    ///   - viewport: size of the figure's rectangle in points (defaults to `rect.size`).
    ///   - yawOverride: a fixed turntable angle in degrees (offscreen renders); otherwise the live turntable.
    ///   - framing: an eased framing sphere from the stage; computed fresh when nil.
    ///   - insets: room kept free for labels (points); defaults to what the figure's labels need.
    public func frame(at time: Double, viewport: CGSize? = nil, yawOverride: Float? = nil,
                      framing: (center: SIMD3<Float>, radius: Float)? = nil, insets: FigureInsets? = nil) -> FigureFrame {
        let size = viewport ?? rect.size
        let camera = camera(at: time)
        let fit = framing ?? self.framing(at: time) ?? (SIMD3<Float>.zero, 1)
        let target = camera.target ?? fit.center
        let yaw = FigureMath.radians(yawOverride ?? yaw(at: time))
        let tilt = FigureMath.radians(min(85, max(-85, camera.tilt + dragTilt)))
        let fovY = FigureMath.radians(min(70, max(15, camera.fov)))
        let width = max(1, size.width), height = max(1, size.height)
        let aspect = Float(width / height)
        // Fit the framing sphere into the part of the rectangle the labels leave free, and shift the lens so the
        // object is centred in that part.
        let room = insets ?? FigureLabelLayout.reservedInsets(for: labels, viewport: size)
        let usableX = Float(max(0.2, (width - room.left - room.right) / width)) * 0.94
        let usableY = Float(max(0.2, (height - room.top - room.bottom) / height)) * 0.88
        let halfY = atan(tan(fovY / 2) * usableY)
        let halfX = atan(tan(fovY / 2) * aspect * usableX)
        let offset = simd_distance(target, fit.center)
        var distance = (fit.radius + offset) / sin(min(halfX, halfY)) / max(0.25, camera.zoom)
        distance = max(distance, (fit.radius + offset) * 1.05)
        let direction = SIMD3(cos(tilt) * sin(yaw), sin(tilt), cos(tilt) * cos(yaw))
        let eye = target + direction * distance
        let near = max(0.01, distance - fit.radius * 2 - offset)
        let far = distance + fit.radius * 3 + offset
        let view = FigureMath.lookAt(eye: eye, target: target)
        var shift = matrix_identity_float4x4
        shift.columns.3.x = Float((room.left - room.right) / width)
        shift.columns.3.y = Float((room.bottom - room.top) / height)
        let projection = shift * FigureMath.perspective(fovY: fovY, aspect: aspect, near: near, far: far)

        let poses = worldPoses(at: time, includeGrow: true)
        var items: [FigureDrawItem] = []
        var anchors: [String: SIMD3<Float>] = [:]
        var groundY = Float.infinity
        let highlight = highlighted.map { (id: $0.id, amount: Float(max(0, 1 - (time - $0.since) / 1.2))) }
        for node in nodes {
            guard let pose = poses[node.id] else { continue }
            if let mesh = node.mesh {
                anchors[node.id] = (pose.matrix * SIMD4((mesh.boundsMin + mesh.boundsMax) / 2, 1)).xyz
            } else {
                anchors[node.id] = pose.matrix.columns.3.xyz
            }
            guard let mesh = node.mesh, pose.shown, time >= node.appearAt else { continue }
            var material = node.material
            material.glow = pose.glow
            if pose.glow > 0, material.emissive == .zero { material.emissive = pose.color }
            material.color = pose.color
            var cut: SIMD4<Float>?
            if let plane = node.cut, simd_length(plane.xyz) > 0.5 {
                let parentMatrix = node.parentID.flatMap { poses[$0]?.matrix } ?? matrix_identity_float4x4
                let n = simd_normalize((parentMatrix * SIMD4(simd_normalize(plane.xyz), 0)).xyz)
                let p = (parentMatrix * SIMD4(simd_normalize(plane.xyz) * plane.w, 1)).xyz
                cut = SIMD4(n, simd_dot(n, p))
            }
            let centerWorld = anchors[node.id] ?? .zero
            for sample in mesh.samples {
                groundY = min(groundY, (pose.matrix * SIMD4(sample, 1)).y)
            }
            items.append(FigureDrawItem(
                nodeID: node.id, mesh: mesh, model: pose.matrix, material: material, pickID: UInt32(max(1, node.number)),
                cut: cut, highlight: highlight?.id == node.id ? highlight!.amount : 0, depth: simd_distance(eye, centerWorld)))
        }
        if !groundY.isFinite { groundY = fit.center.y - fit.radius }
        // Where the object really is on screen: its projected framing samples.
        let viewProjection = projection * view
        var lo = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        for item in items {
            for sample in item.mesh.samples {
                let clip = viewProjection * (item.model * SIMD4(sample, 1))
                guard clip.w > 1e-5 else { continue }
                let x = CGFloat(clip.x / clip.w * 0.5 + 0.5) * size.width
                let y = CGFloat(0.5 - clip.y / clip.w * 0.5) * size.height
                lo = CGPoint(x: min(lo.x, x), y: min(lo.y, y))
                hi = CGPoint(x: max(hi.x, x), y: max(hi.y, y))
            }
        }
        var result = FigureFrame(
            items: items, look: look, viewport: size, eye: eye, target: target, view: view, projection: projection,
            yaw: yaw, fovY: fovY, near: near, far: far, center: fit.center, radius: fit.radius, groundY: groundY,
            ink: ink, anchors: anchors)
        if lo.x.isFinite, hi.x >= lo.x { result.objectBounds = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y) }
        let labelled = Set(labels.compactMap(\.follow))
        if !labelled.isEmpty {
            var samples: [String: [SIMD3<Float>]] = [:]
            for node in nodes {
                guard let mesh = node.mesh, let pose = poses[node.id], pose.shown else { continue }
                let step = max(1, mesh.samples.count / 48)
                let points = stride(from: 0, to: mesh.samples.count, by: step).map { (pose.matrix * SIMD4(mesh.samples[$0], 1)).xyz }
                // Credit the points to the part and every group above it.
                var owner: FigureNode? = node
                var depth = 0
                while let current = owner, depth < 32 {
                    if labelled.contains(current.id) { samples[current.id, default: []] += points }
                    owner = current.parentID.flatMap { nodeByID[$0] }
                    depth += 1
                }
            }
            result.anchorSamples = samples
        }
        return result
    }

    /// How a click on `nodeID` is described to the brain. It uses the first of these that exists: a label on the part,
    /// on the part it was copied from or on a group it belongs to; its `name` or program variable
    /// (`variableName`); else its material and kind ("this brass gear").
    public func clickName(for nodeID: String, variableName: ((String) -> String?)? = nil) -> (name: String, isLabelled: Bool) {
        guard let node = nodeByID[nodeID] else { return ("this part", false) }
        var chain: [(node: FigureNode, relation: Int)] = []  // 0 itself, 1 copied from, 2 a group it is in
        var current: FigureNode? = node
        var relation = 0
        while let part = current, chain.count < 32 {
            chain.append((part, relation))
            if let source = part.copyOf.flatMap({ nodeByID[$0] }) { chain.append((source, relation == 0 ? 1 : 2)) }
            current = part.parentID.flatMap { nodeByID[$0] }
            relation = 2
        }
        for (candidate, relation) in chain {
            guard let label = labels.first(where: { $0.follow == candidate.id }) else { continue }
            switch relation {
            case 0: return ("the part labelled \"\(label.text)\"", true)
            case 1: return ("one of the parts labelled \"\(label.text)\"", true)
            default: return ("a piece of the part labelled \"\(label.text)\"", true)
            }
        }
        for (candidate, relation) in chain {
            guard let name = candidate.name ?? variableName?(candidate.id) else { continue }
            return (relation == 2 ? "a piece of the \(name)" : "the \(name)", false)
        }
        let nouns = ["box": "block", "sphere": "ball", "cylinder": "cylinder", "cone": "cone", "tube": "tube", "torus": "ring",
                     "capsule": "capsule", "pipe": "pipe", "spring": "spring", "gear": "gear", "extrude": "piece",
                     "blob": "blob", "poly": "gem", "arrow": "arrow", "lathe": "turned piece"]
        let noun = nouns[node.kind] ?? "part"
        if let mat = node.materialName, mat != "gloss", mat != "plastic" { return ("this \(mat) \(noun)", false) }
        return ("this \(noun)", false)
    }
}
