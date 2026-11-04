import CoreGraphics
import Foundation

/// Answers "how bright is the screen here?" (the readable-ink rule) and "how busy is it?" (where pills and buttons go)
/// from a screenshot.
///
/// The screenshot is reduced once to a small grid of cells. Brightness averages the cells' relative luminance under a
/// canvas rectangle; busyness is the share of those cells that sit on an edge (text, controls, borders). Thread-safe
/// and immutable, so the engine host can call it from its own queue.
public final class DrawingScreenSampler: Sendable {
    private let cells: [Float]
    private let edges: [Bool]
    private let columns: Int
    private let rows: Int
    private let canvasSize: CGSize

    /// - Parameters:
    ///   - image: the screenshot the program draws over.
    ///   - canvasSize: the canvas the program draws in (usually the screenshot's size as sent to the brain).
    ///   - cellSize: approximate size of one sampling cell, in canvas units.
    public init(image: CGImage, canvasSize: CGSize, cellSize: CGFloat = 8) {
        let columns = max(1, Int((canvasSize.width / cellSize).rounded(.up)))
        let rows = max(1, Int((canvasSize.height / cellSize).rounded(.up)))
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let context = CGContext(data: &pixels, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        func linear(_ v: UInt8) -> Float {
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var cells = [Float](repeating: 0, count: columns * rows)
        var luma = [Float](repeating: 0, count: columns * rows)
        // A bitmap context's memory starts with the image's top row (drawing coordinates are bottom-up, its memory is
        // not), which is already canvas order: y down.
        for row in 0..<rows {
            for column in 0..<columns {
                let i = (row * columns + column) * 4
                cells[row * columns + column] = 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
                luma[row * columns + column] = (0.2126 * Float(pixels[i]) + 0.7152 * Float(pixels[i + 1]) + 0.0722 * Float(pixels[i + 2])) / 255
            }
        }
        // A cell is on an edge when its neighbour to the right or below looks clearly different.
        var edges = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let here = luma[row * columns + column]
                let right = column + 1 < columns ? luma[row * columns + column + 1] : here
                let below = row + 1 < rows ? luma[(row + 1) * columns + column] : here
                edges[row * columns + column] = max(abs(here - right), abs(here - below)) > Self.edgeStep
            }
        }
        self.cells = cells
        self.edges = edges
        self.columns = columns
        self.rows = rows
        self.canvasSize = canvasSize
    }

    /// Brightness difference (0…1, gamma-encoded) between neighbouring cells that counts as an edge.
    static let edgeStep: Float = 0.06

    /// Mean relative luminance (0…1) under a canvas rectangle, or nil when it lies off the screenshot.
    public func luminance(in rect: CGRect) -> Double? {
        guard let range = cellRange(rect) else { return nil }
        var total: Float = 0
        for row in range.rows { for column in range.columns { total += cells[row * columns + column] } }
        return Double(total / Float(range.rows.count * range.columns.count))
    }

    /// How busy the screen is under a canvas rectangle: the share (0…1) of it covered by edges such as text and
    /// controls, or nil when it lies off the screenshot.
    public func busyness(in rect: CGRect) -> Double? {
        guard let range = cellRange(rect) else { return nil }
        var count = 0
        for row in range.rows { for column in range.columns where edges[row * columns + column] { count += 1 } }
        return Double(count) / Double(range.rows.count * range.columns.count)
    }

    private func cellRange(_ rect: CGRect) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let sx = CGFloat(columns) / canvasSize.width, sy = CGFloat(rows) / canvasSize.height
        let c0 = max(0, Int(clipped.minX * sx)), c1 = min(columns - 1, Int((clipped.maxX * sx).rounded(.up)) - 1)
        let r0 = max(0, Int(clipped.minY * sy)), r1 = min(rows - 1, Int((clipped.maxY * sy).rounded(.up)) - 1)
        guard c0 <= c1, r0 <= r1 else { return nil }
        return (r0...r1, c0...c1)
    }
}
