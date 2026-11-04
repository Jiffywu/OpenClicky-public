import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Colors and sizes of the buddy pointer.
public struct BuddyPointerStyle: Sendable, Hashable {
    public struct RGBA: Sendable, Hashable {
        public var red, green, blue, alpha: Double
        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        func cgColor(alpha scale: Double = 1) -> CGColor {
            CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha * scale)
        }
    }

    public var body: RGBA
    public var outline: RGBA
    public var halo: RGBA
    public var labelFill: RGBA
    public var labelText: RGBA
    /// Multiplies the buddy's drawn size.
    public var size: Double
    /// Ring radius around a bare point (no element frame).
    public var ringRadius: Double
    public var labelFontSize: Double

    public init(body: RGBA = RGBA(0.16, 0.47, 1.0), outline: RGBA = RGBA(1, 1, 1), halo: RGBA = RGBA(0.16, 0.47, 1.0),
                labelFill: RGBA = RGBA(0.11, 0.38, 0.92, 0.96), labelText: RGBA = RGBA(1, 1, 1), size: Double = 1.15,
                ringRadius: Double = 24, labelFontSize: Double = 13) {
        self.body = body
        self.outline = outline
        self.halo = halo
        self.labelFill = labelFill
        self.labelText = labelText
        self.size = size
        self.ringRadius = ringRadius
        self.labelFontSize = labelFontSize
    }

    public static let standard = BuddyPointerStyle()
}

/// Draws pointer frames with Core Graphics into a y-down context whose origin is a display's top-left corner. The app's
/// overlay and the offscreen renders used in tests and evidence share this one renderer.
public enum BuddyPointerArtist {
    /// Draws one frame. `display` is the display's AppKit global frame; `canvasSize` is the drawable area (the
    /// display's size in points for a full overlay).
    public static func draw(_ frame: PointerFrame, in context: CGContext, display: CGRect, canvasSize: CGSize, style: BuddyPointerStyle = .standard) {
        guard frame.phase != .finished else { return }
        let tip = local(frame.position, display)
        if frame.haloOpacity > 0.001, frame.haloProgress > 0.001 {
            drawHalo(target: frame.target, display: display, progress: frame.haloProgress, pulse: frame.haloPulse,
                     opacity: frame.haloOpacity, in: context, style: style)
        }
        if frame.opacity > 0.001 {
            drawBuddy(tip: tip, rotation: frame.rotation, scale: frame.scale, opacity: frame.opacity, in: context, style: style)
        }
        if let label = frame.label, frame.labelOpacity > 0.001, showsLabel(tip: tip, canvasSize: canvasSize) {
            drawLabel(label, tip: tip, canvasSize: canvasSize, opacity: frame.labelOpacity * frame.opacity, in: context, style: style)
        }
    }

    /// Only the display the tip is on draws the label. `labelRect` keeps the pill inside its canvas, so a display
    /// that drew it for a tip elsewhere would pin a second copy to its own edge.
    static func showsLabel(tip: CGPoint, canvasSize: CGSize) -> Bool {
        CGRect(origin: .zero, size: canvasSize).contains(tip)
    }

    /// The display-local rectangle a frame paints (padded for glow), so a view can redraw only that much.
    public static func paintedBounds(_ frame: PointerFrame, display: CGRect, canvasSize: CGSize, style: BuddyPointerStyle = .standard) -> CGRect {
        guard frame.phase != .finished else { return .null }
        let tip = local(frame.position, display)
        let reach = 34 * style.size * max(frame.scale, 1)
        var bounds = CGRect(x: tip.x - reach, y: tip.y - reach, width: reach * 2, height: reach * 2)
        if frame.haloOpacity > 0.001 { bounds = bounds.union(haloRect(frame.target, display: display, style: style).insetBy(dx: -22, dy: -22)) }
        if let label = frame.label, frame.labelOpacity > 0.001, showsLabel(tip: tip, canvasSize: canvasSize) {
            bounds = bounds.union(labelRect(label, tip: tip, canvasSize: canvasSize, style: style).insetBy(dx: -10, dy: -10))
        }
        return bounds
    }

    static func local(_ global: CGPoint, _ display: CGRect) -> CGPoint {
        CGPoint(x: global.x - display.minX, y: display.maxY - global.y)
    }

    // MARK: Buddy

    public static func buddyPath(tip: CGPoint, rotation: Double, scale: Double, style: BuddyPointerStyle) -> CGPath {
        let path = CGMutablePath()
        let points = BuddyPointerGeometry.outline
        let transform = CGAffineTransform(translationX: tip.x, y: tip.y).rotated(by: rotation).scaledBy(x: scale * style.size, y: scale * style.size)
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }

    static func drawBuddy(tip: CGPoint, rotation: Double, scale: Double, opacity: Double, in context: CGContext, style: BuddyPointerStyle) {
        let path = buddyPath(tip: tip, rotation: rotation, scale: scale, style: style)
        context.saveGState()
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        // Soft colored glow under the body.
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 9, color: style.body.cgColor(alpha: 0.55))
        context.addPath(path)
        context.setFillColor(style.body.cgColor())
        context.setLineJoin(.round)
        context.setLineWidth(3.2)
        context.setStrokeColor(style.outline.cgColor())
        context.drawPath(using: .fillStroke)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        // Fill again so the outline's inner half doesn't eat the body.
        context.addPath(path)
        context.setFillColor(style.body.cgColor())
        context.fillPath()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: Halo

    static func haloRect(_ target: ResolvedPointingTarget, display: CGRect, style: BuddyPointerStyle) -> CGRect {
        if let frame = target.frame {
            let topLeft = local(CGPoint(x: frame.minX, y: frame.maxY), display)
            return CGRect(x: topLeft.x, y: topLeft.y, width: frame.width, height: frame.height).insetBy(dx: -5, dy: -5)
        }
        let center = local(target.point, display)
        let r = style.ringRadius
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    static func haloPath(_ rect: CGRect, isElement: Bool) -> CGPath {
        if isElement {
            let radius = min(10, rect.height / 2, rect.width / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        return CGPath(ellipseIn: rect, transform: nil)
    }

    static func drawHalo(target: ResolvedPointingTarget, display: CGRect, progress: Double, pulse: Double, opacity: Double,
                         in context: CGContext, style: BuddyPointerStyle) {
        let rect = haloRect(target, display: display, style: style)
        let isElement = target.frame != nil
        let path = haloPath(rect, isElement: isElement)
        let perimeter = isElement ? 2 * (rect.width + rect.height) : .pi * rect.width
        context.saveGState()
        context.setAlpha(opacity)
        // A faint wash inside the target.
        context.addPath(path)
        context.setFillColor(style.halo.cgColor(alpha: 0.10 * progress))
        context.fillPath()
        // The breathing outer ring.
        if progress >= 0.999 {
            let grow = 4 + 9 * pulse
            let outer = haloPath(rect.insetBy(dx: -grow, dy: -grow), isElement: isElement)
            context.addPath(outer)
            context.setStrokeColor(style.halo.cgColor(alpha: 0.45 * (1 - pulse)))
            context.setLineWidth(2)
            context.strokePath()
        }
        // The ring itself, drawn on progressively.
        context.addPath(path)
        context.setShadow(offset: .zero, blur: 6, color: style.halo.cgColor(alpha: 0.6))
        context.setStrokeColor(style.halo.cgColor())
        context.setLineWidth(3)
        context.setLineCap(.round)
        if progress < 0.999 { context.setLineDash(phase: 0, lengths: [perimeter * progress, perimeter * 2]) }
        context.strokePath()
        context.restoreGState()
    }

    // MARK: Label

    static func font(_ style: BuddyPointerStyle) -> CTFont {
        NSFont.systemFont(ofSize: style.labelFontSize, weight: .semibold) as CTFont
    }

    static func line(_ text: String, style: BuddyPointerStyle, maxWidth: Double) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.labelText.cgColor(),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth else { return line }
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, maxWidth, .end, ellipsis) ?? line
    }

    static let labelHeight: CGFloat = 26
    static let labelPadding: CGFloat = 11
    static let labelMaxTextWidth: Double = 300

    /// Where the label pill goes: below and to the right of the buddy, flipped left or up near the canvas edges.
    public static func labelRect(_ text: String, tip: CGPoint, canvasSize: CGSize, style: BuddyPointerStyle = .standard) -> CGRect {
        let width = CGFloat(CTLineGetTypographicBounds(line(text, style: style, maxWidth: labelMaxTextWidth), nil, nil, nil)) + labelPadding * 2
        let offset = CGPoint(x: 20 * style.size, y: 24 * style.size)
        var x = tip.x + offset.x
        var y = tip.y + offset.y
        if x + width > canvasSize.width - 8 { x = tip.x - offset.x - width }
        if y + labelHeight > canvasSize.height - 8 { y = tip.y - offset.y - labelHeight }
        return CGRect(x: max(x, 8), y: max(y, 8), width: width, height: labelHeight)
    }

    static func drawLabel(_ text: String, tip: CGPoint, canvasSize: CGSize, opacity: Double, in context: CGContext, style: BuddyPointerStyle) {
        let rect = labelRect(text, tip: tip, canvasSize: canvasSize, style: style)
        let textLine = line(text, style: style, maxWidth: labelMaxTextWidth)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(textLine, &ascent, &descent, nil)
        context.saveGState()
        context.setAlpha(opacity)
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        context.setFillColor(style.labelFill.cgColor())
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        // The context is y-down; flip glyphs so text stands upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: rect.minX + labelPadding, y: rect.midY + (ascent - descent) / 2)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }

    // MARK: Offscreen rendering

    /// Renders frames into one PNG, one panel per frame, each over `background`. For tests and visual evidence.
    public static func renderFilmstrip(frames: [(caption: String, frame: PointerFrame)], display: CGRect, columns: Int = 3, scale: Double = 1,
                                       style: BuddyPointerStyle = .standard,
                                       background: (CGContext, CGSize) -> Void) throws -> Data {
        let columns = max(1, min(columns, frames.count))
        let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
        let captionHeight: CGFloat = 26
        let panel = CGSize(width: display.width, height: display.height + captionHeight)
        let gap: CGFloat = 12
        let size = CGSize(width: CGFloat(columns) * panel.width + CGFloat(columns + 1) * gap,
                          height: CGFloat(rows) * panel.height + CGFloat(rows + 1) * gap)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageCoding.Failure.resizeFailed }
        // y-down, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for (index, item) in frames.enumerated() {
            let origin = CGPoint(x: gap + CGFloat(index % columns) * (panel.width + gap), y: gap + CGFloat(index / columns) * (panel.height + gap))
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            drawCaption(item.caption, in: context, width: panel.width)
            context.translateBy(x: 0, y: captionHeight)
            context.clip(to: CGRect(origin: .zero, size: display.size))
            background(context, display.size)
            draw(item.frame, in: context, display: display, canvasSize: display.size, style: style)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ImageCoding.Failure.resizeFailed }
        return try ImageCoding.pngData(image)
    }

    private static func drawCaption(_ text: String, in context: CGContext, width: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.2, green: 0.2, blue: 0.25, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: 4, y: 18)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
