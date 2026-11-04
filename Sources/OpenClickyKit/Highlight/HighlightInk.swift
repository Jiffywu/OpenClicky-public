import CoreGraphics
import Foundation
import QuartzCore

/// The highlighter ink of draw-to-ask: a wide, translucent yellow stroke that follows the pointer while the talk key
/// is held and fades about a second after it is let go. The same strokes are drawn into the turn's screenshot so the
/// brain sees exactly what was marked.
public struct HighlightInkStyle: Sendable, Hashable {
    public var color: DrawingColor = DrawingColor(hex: "#FFD60A")!
    /// Points.
    public var width: CGFloat = 8
    public var alpha: Double = 0.55
    /// Seconds the ink takes to fade after the key goes up.
    public var fade: CFTimeInterval = 1.0

    public init() {}
}

public enum HighlightInk {
    /// A smooth path through stroke points, in a display's top-left local points (`display` is the display's AppKit
    /// global frame).
    public static func path(_ points: [CGPoint], display: CGRect) -> CGPath {
        smooth(points.map { CGPoint(x: $0.x - display.minX, y: display.maxY - $0.y) })
    }

    /// A Catmull-Rom curve through every point (straight segments for two points).
    public static func smooth(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        func at(_ i: Int) -> CGPoint { pts[min(max(i, 0), pts.count - 1)] }
        for i in 0..<(pts.count - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }

    /// The ink drawn into a screenshot of the display `geometry` describes, as a highlighter does: multiplied, so the
    /// words under it stay readable. Strokes on other displays are left out.
    public static func composite(_ gesture: HighlightGesture, onto image: CGImage, geometry: CaptureGeometry, style: HighlightInkStyle = HighlightInkStyle()) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Pixel space with a top-left origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setBlendMode(.multiply)
        context.setStrokeColor(style.color.withAlpha(min(1, style.alpha + 0.2)).cgColor)
        context.setLineWidth(style.width / max(0.01, min(geometry.pointsPerPixelX, geometry.pointsPerPixelY)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in gesture.strokes {
            let pixels = stroke.points.compactMap { geometry.pixel(fromAppKit: $0) }
            guard pixels.count >= 2 else { continue }
            context.addPath(smooth(pixels))
            context.strokePath()
        }
        return context.makeImage()
    }
}

/// The live ink over one display: update it with the recorder's strokes while the key is held, then fade it.
@MainActor
public final class HighlightInkLayer {
    public let layer = CALayer()
    public let display: CGRect
    public var style: HighlightInkStyle
    private var shapes: [CAShapeLayer] = []

    /// `display` is the display's AppKit global frame; the layer is its size, y down.
    public init(display: CGRect, style: HighlightInkStyle = HighlightInkStyle()) {
        self.display = display
        self.style = style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.name = "highlight-ink"
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: display.size)
        layer.position = .zero
        layer.isGeometryFlipped = true
        CATransaction.commit()
    }

    /// Show these strokes (AppKit global points), one shape per stroke.
    public func update(_ strokes: [[CGPoint]]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = 1
        while shapes.count < strokes.count {
            let shape = CAShapeLayer()
            shape.frame = layer.bounds
            shape.fillColor = nil
            shape.strokeColor = style.color.withAlpha(style.alpha).cgColor
            shape.lineWidth = style.width
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
            shapes.append(shape)
        }
        while shapes.count > strokes.count { shapes.removeLast().removeFromSuperlayer() }
        for (shape, points) in zip(shapes, strokes) { shape.path = HighlightInk.path(points, display: display) }
        CATransaction.commit()
    }

    /// Fade the ink out, starting at `begin` (media time), then clear it.
    public func fadeOut(begin: CFTimeInterval = CACurrentMediaTime()) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = begin
        fade.duration = style.fade
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fade")
    }

    public func clear() { update([]) }
}
