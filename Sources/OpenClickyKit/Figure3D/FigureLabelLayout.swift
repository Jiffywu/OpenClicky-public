import CoreGraphics
import CoreText
import Foundation
import simd

/// Where one label goes: its text box beside the object and a leader line ending in a dot on the part.
public struct FigureLabelPlacement: Sendable, Equatable {
    public enum Side: String, Sendable { case left, right }
    public var id: String
    public var text: String
    public var size: CGFloat
    public var side: Side
    /// Text box in the figure rectangle (points, top-left origin).
    public var box: CGRect
    /// Where the leader leaves the text.
    public var start: CGPoint
    /// The point on the part.
    public var anchor: CGPoint
    /// 0...1, how much of the label has been written (for the pen reveal).
    public var progress: CGFloat
}

/// Lays labels out in the margins beside the object: each label goes to its requested side (or the side its part is
/// on), sits as close to its part's height as it can, and labels on one side are spread apart so none overlap.
public enum FigureLabelLayout {
    /// Labels are written in the drawings' hand font (the bundled Patrick Hand, with the system's handwriting faces as
    /// the fallback), so a figure's words match the 2D words around it.
    public static let textStyle = DrawingTextStyle.hand
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    public static func font(size: CGFloat) -> CTFont {
        DrawingFonts.font(textStyle, size: size)
    }

    public static func measure(_ text: String, size: CGFloat) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [fontKey: font(size: size)]))
        let bounds = CTLineGetTypographicBounds(line, nil, nil, nil)
        return CGSize(width: ceil(bounds) + 2, height: ceil(size * 1.3))
    }

    static let gap: CGFloat = 18
    static let margin: CGFloat = 6

    /// Room to keep free beside the object so every label fits: a label with a `side` needs room on that side; one
    /// without may go either way as the figure turns, so it reserves both (which also keeps the zoom steady).
    public static func reservedInsets(for labels: [FigureLabel], viewport: CGSize,
                                      measure: (String, CGFloat) -> CGSize = FigureLabelLayout.measure) -> FigureInsets {
        guard !labels.isEmpty else { return .zero }
        var left: CGFloat = 0, right: CGFloat = 0
        for label in labels {
            let width = measure(label.text, CGFloat(label.size)).width + gap + margin
            if label.side != "right" { left = max(left, width) }
            if label.side != "left" { right = max(right, width) }
        }
        let cap = viewport.width * 0.34
        return FigureInsets(left: min(left, cap), right: min(right, cap))
    }

    public static func layout(_ labels: [FigureLabel], frame: FigureFrame, time: Double,
                              measure: (String, CGFloat) -> CGSize = FigureLabelLayout.measure) -> [FigureLabelPlacement] {
        let viewport = CGRect(origin: .zero, size: frame.viewport)
        let drawn = frame.objectBounds ?? frame.objectScreenBounds
        let object = drawn.intersection(viewport.insetBy(dx: 4, dy: 4))
        let objectBox = object.isNull ? viewport.insetBy(dx: viewport.width * 0.25, dy: viewport.height * 0.1) : object
        let gap = Self.gap
        let margin = Self.margin
        var placements: [FigureLabelPlacement] = []
        for label in labels where time >= label.start {
            let world: SIMD3<Float>? = label.follow.flatMap { frame.anchors[$0] } ?? label.point
            guard let world else { continue }
            var anchor = frame.project(world)
            let side: FigureLabelPlacement.Side = label.side == "left" ? .left : label.side == "right" ? .right
                : (anchor.x < objectBox.midX ? .left : .right)
            if let follow = label.follow, let samples = frame.anchorSamples[follow], !samples.isEmpty {
                // End the leader on the part's edge facing the label, near the part's middle height.
                let center = anchor
                let projected = samples.map(frame.project)
                let score: (CGPoint) -> CGFloat = { p in
                    (side == .left ? p.x : -p.x) + 0.6 * abs(p.y - center.y)
                }
                if let edge = projected.min(by: { score($0) < score($1) }) {
                    let inward: CGFloat = 3
                    anchor = CGPoint(x: edge.x + (side == .left ? inward : -inward), y: edge.y)
                }
            }
            let size = CGFloat(label.size)
            let textSize = measure(label.text, size)
            var x: CGFloat
            if side == .left {
                x = max(margin, objectBox.minX - gap - textSize.width)
            } else {
                x = min(viewport.maxX - margin - textSize.width, objectBox.maxX + gap)
            }
            x = max(margin, x)
            let box = CGRect(x: x, y: anchor.y - textSize.height / 2, width: textSize.width, height: textSize.height)
            let progress = label.duration > 0 ? CGFloat(min(1, max(0, (time - label.start) / label.duration))) : 1
            placements.append(FigureLabelPlacement(id: label.id, text: label.text, size: size, side: side, box: box,
                                                   start: .zero, anchor: anchor, progress: progress))
        }
        for side in [FigureLabelPlacement.Side.left, .right] {
            let indices = placements.indices.filter { placements[$0].side == side }.sorted { placements[$0].box.midY < placements[$1].box.midY }
            spread(&placements, indices: indices, low: margin, high: viewport.height - margin, gap: 4)
        }
        for i in placements.indices {
            let box = placements[i].box
            placements[i].start = CGPoint(x: placements[i].side == .left ? box.maxX + 3 : box.minX - 3, y: box.midY)
        }
        return placements
    }

    /// One-dimensional de-overlap: push boxes down past their upper neighbour, then back up from the bottom edge.
    static func spread(_ placements: inout [FigureLabelPlacement], indices: [Int], low: CGFloat, high: CGFloat, gap: CGFloat) {
        var floor = low
        for i in indices {
            if placements[i].box.minY < floor { placements[i].box.origin.y = floor }
            floor = placements[i].box.maxY + gap
        }
        var ceiling = high
        for i in indices.reversed() {
            if placements[i].box.maxY > ceiling { placements[i].box.origin.y = ceiling - placements[i].box.height }
            ceiling = placements[i].box.minY - gap
        }
    }

    /// Draw labels, leaders and the readout panel with Core Graphics. `context` is in points with a top-left origin
    /// (flipped), covering the figure rectangle.
    public static func draw(_ placements: [FigureLabelPlacement], readouts: [(key: String, value: String)], ink: CGColor,
                            halo: CGColor?, in context: CGContext) {
        for p in placements {
            let end = CGPoint(x: p.start.x + (p.anchor.x - p.start.x) * p.progress, y: p.start.y + (p.anchor.y - p.start.y) * p.progress)
            context.saveGState()
            context.setLineCap(.round)
            if let halo {
                context.setStrokeColor(halo)
                context.setLineWidth(4)
                context.move(to: p.start); context.addLine(to: end); context.strokePath()
            }
            context.setStrokeColor(ink)
            context.setLineWidth(1.6)
            context.move(to: p.start); context.addLine(to: end); context.strokePath()
            if p.progress >= 1 {
                if let halo {
                    context.setFillColor(halo)
                    context.fillEllipse(in: CGRect(x: p.anchor.x - 4.5, y: p.anchor.y - 4.5, width: 9, height: 9))
                }
                context.setFillColor(ink)
                context.fillEllipse(in: CGRect(x: p.anchor.x - 3, y: p.anchor.y - 3, width: 6, height: 6))
            }
            let shown = String(p.text.prefix(Int((CGFloat(p.text.count) * min(1, p.progress * 1.4)).rounded(.up))))
            drawText(shown, at: CGPoint(x: p.box.minX, y: p.box.minY), size: p.size, color: ink, in: context)
            context.restoreGState()
        }
        guard !readouts.isEmpty else { return }
        let size: CGFloat = 13
        let rows = readouts.map { "\($0.key)  \($0.value)" }
        let width = (rows.map { measure($0, size: size).width }.max() ?? 0) + 20
        let height = CGFloat(rows.count) * size * 1.45 + 14
        let panel = CGRect(x: 8, y: 8, width: width, height: height)
        context.saveGState()
        context.setFillColor(halo ?? CGColor(gray: 1, alpha: 0.8))
        context.addPath(CGPath(roundedRect: panel, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.fillPath()
        context.setStrokeColor(ink.copy(alpha: 0.35) ?? ink)
        context.setLineWidth(1)
        context.addPath(CGPath(roundedRect: panel, cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.strokePath()
        for (i, row) in rows.enumerated() {
            drawText(row, at: CGPoint(x: panel.minX + 10, y: panel.minY + 7 + CGFloat(i) * size * 1.45), size: size, color: ink, in: context)
        }
        context.restoreGState()
    }

    /// Draw one line of text with its top-left at `origin` in a flipped (top-left origin) context.
    static func drawText(_ text: String, at origin: CGPoint, size: CGFloat, color: CGColor, in context: CGContext) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [fontKey: font(size: size), colorKey: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + ascent + size * 0.1)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
