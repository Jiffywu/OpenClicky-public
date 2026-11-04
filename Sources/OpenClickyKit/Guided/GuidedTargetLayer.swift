import CoreGraphics
import Foundation
import QuartzCore

/// How a waiting guided target looks over one display: the snapped control's outline (with its corner radius), or a
/// ring when nothing was snapped, plus a soft pulse that keeps inviting the click and the target's name in a pill.
/// Core Animation only, so the overlay and offscreen evidence renders draw the same thing.
@MainActor
public enum GuidedTargetLayer {
    public struct Style: Sendable, Hashable {
        public var ink: DrawingColor = .defaultInk
        public var lineWidth: CGFloat = 3
        /// Seconds per pulse.
        public var pulsePeriod: CFTimeInterval = 1.4
        public var showsLabel = true

        public init() {}
    }

    /// The layer for `target` on a display whose frame is `display` (AppKit global points). The layer is the size of
    /// the display, y down, ready to add to that display's overlay. `begin` starts the animations (media time).
    public static func make(for target: GuidedTarget, display: CGRect, style: Style = Style(), begin: CFTimeInterval = CACurrentMediaTime()) -> CALayer {
        let root = CALayer()
        root.name = "guided-target"
        root.anchorPoint = .zero
        root.bounds = CGRect(origin: .zero, size: display.size)
        root.position = .zero
        root.isGeometryFlipped = true
        // AppKit global (y up) → this display's top-left points.
        let f = target.frame
        let local = CGRect(x: f.minX - display.minX, y: display.maxY - f.maxY, width: f.width, height: f.height)
        let shape: CGPath
        if target.isControlOutline {
            let pad: CGFloat = 4
            let box = local.insetBy(dx: -pad, dy: -pad)
            let corner = min(box.height / 2, max(6, min(box.width, box.height) * 0.25))
            shape = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        } else {
            let r = target.radius
            shape = CGPath(ellipseIn: CGRect(x: local.midX - r, y: local.midY - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        let center = CGPoint(x: local.midX, y: local.midY)

        let halo = CAShapeLayer()
        halo.name = "pulse"
        halo.frame = root.bounds
        halo.path = shape
        halo.fillColor = style.ink.withAlpha(0.14).cgColor
        halo.strokeColor = style.ink.withAlpha(0.45).cgColor
        halo.lineWidth = style.lineWidth * 2.5
        // Scale around the target's centre.
        halo.anchorPoint = CGPoint(x: center.x / max(1, root.bounds.width), y: center.y / max(1, root.bounds.height))
        halo.frame = root.bounds
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.18
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = style.pulsePeriod
        grow.duration = style.pulsePeriod
        fade.duration = style.pulsePeriod
        pulse.beginTime = begin
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(pulse, forKey: "pulse")
        root.addSublayer(halo)

        let ring = CAShapeLayer()
        ring.name = target.isControlOutline ? "outline" : "ring"
        ring.frame = root.bounds
        ring.path = shape
        ring.fillColor = nil
        ring.strokeColor = style.ink.cgColor
        ring.lineWidth = style.lineWidth
        ring.shadowColor = style.ink.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = begin
        draw.duration = 0.45
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.05, 0.45, 1)
        ring.add(draw, forKey: "draw")
        root.addSublayer(ring)

        if style.showsLabel, let name = target.name, !name.isEmpty {
            root.addSublayer(pill(name, below: shape.boundingBoxOfPath, in: root.bounds, ink: style.ink))
        }
        return root
    }

    /// The target's name in a gel pill under it (above it near the bottom of the screen).
    static func pill(_ text: String, below box: CGRect, in bounds: CGRect, ink: DrawingColor) -> CALayer {
        let size: CGFloat = 13
        let shown = text.count > 40 ? String(text.prefix(39)) + "…" : text
        let width = CGFloat(DrawingFonts.width(of: shown, size: Double(size), style: .bold)) + 22
        let height: CGFloat = 26
        var origin = CGPoint(x: box.midX - width / 2, y: box.maxY + 10)
        if origin.y + height > bounds.maxY - 4 { origin.y = box.minY - 10 - height }
        origin.x = min(max(4, origin.x), bounds.maxX - width - 4)
        let pill = CALayer()
        pill.name = "label"
        pill.frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let gel = ink.gel
        let body = CAGradientLayer()
        body.frame = pill.bounds
        body.colors = [gel.top.cgColor, gel.bottom.cgColor]
        body.cornerRadius = height / 2
        body.borderColor = gel.rim.withAlpha(0.8).cgColor
        body.borderWidth = 1
        pill.addSublayer(body)
        let words = CAShapeLayer()
        words.frame = pill.bounds
        let ascent = DrawingFonts.ascent(.bold, size: size), descent = DrawingFonts.descent(.bold, size: size)
        words.path = DrawingFonts.glyphPath(shown, style: .bold, size: size, origin: CGPoint(x: 11, y: height / 2 + (ascent - descent) / 2)).path
        words.fillColor = DrawingColor(hex: "#16181D")!.cgColor
        pill.addSublayer(words)
        return pill
    }
}
