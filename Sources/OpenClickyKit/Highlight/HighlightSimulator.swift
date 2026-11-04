import CoreGraphics
import CoreText
import Foundation

/// Draw-to-ask without a mouse, a talk key or permissions (`occtl highlight`, tests): hand-shaped strokes in screenshot
/// pixels are played through the real recorder at 60 Hz, then described against a screenshot.
public enum HighlightSimulator {
    /// A stroke shape in screenshot pixels (top-left origin).
    public enum Shape: Sendable, Hashable {
        case circle(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat)
        case underline(start: CGPoint, width: CGFloat)
        case line(from: CGPoint, to: CGPoint)
        case scribble(CGRect)
        case path([CGPoint])

        /// Parses `circle:cx,cy,rx[,ry]`, `underline:x,y,w`, `line:x1,y1,x2,y2`, `scribble:x,y,w,h` or
        /// `path:x,y;x,y;…`.
        public init?(_ text: String) {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0] == "path" {
                let points = parts[1].split(separator: ";").compactMap { pair -> CGPoint? in
                    let n = pair.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
                }
                guard points.count >= 2 else { return nil }
                self = .path(points)
                return
            }
            let n = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { CGFloat($0) }
            switch (parts[0], n.count) {
            case ("circle", 3): self = .circle(center: CGPoint(x: n[0], y: n[1]), radiusX: n[2], radiusY: n[2])
            case ("circle", 4): self = .circle(center: CGPoint(x: n[0], y: n[1]), radiusX: n[2], radiusY: n[3])
            case ("underline", 3): self = .underline(start: CGPoint(x: n[0], y: n[1]), width: n[2])
            case ("line", 4): self = .line(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]))
            case ("scribble", 4): self = .scribble(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
            default: return nil
            }
        }

        /// The hand's path, slightly uneven like a real one, in pixels.
        public var pixels: [CGPoint] {
            switch self {
            case .circle(let c, let rx, let ry):
                // A little more than one turn, starting at the upper left like most people do, slightly wobbly.
                return (0...96).map { i in
                    let t = CGFloat(i) / 96
                    let a = -2.4 + t * 2.15 * .pi
                    let wobble = 1 + 0.035 * sin(t * 17)
                    return CGPoint(x: c.x + rx * wobble * cos(a), y: c.y + ry * wobble * sin(a))
                }
            case .underline(let start, let width):
                return (0...40).map { i in
                    let t = CGFloat(i) / 40
                    return CGPoint(x: start.x + width * t, y: start.y + 1.5 * sin(t * 9))
                }
            case .line(let a, let b):
                return (0...40).map { i in
                    let t = CGFloat(i) / 40
                    return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + 2 * sin(t * 5))
                }
            case .scribble(let r):
                var out: [CGPoint] = []
                let passes = 8
                for k in 0..<passes {
                    let y0 = r.minY + r.height * CGFloat(k) / CGFloat(passes), y1 = r.minY + r.height * CGFloat(k + 1) / CGFloat(passes)
                    for i in 0...24 {
                        let t = CGFloat(i) / 24
                        out.append(CGPoint(x: k % 2 == 0 ? r.minX + r.width * t : r.maxX - r.width * t, y: y0 + (y1 - y0) * t))
                    }
                }
                return out
            case .path(let points):
                return points
            }
        }
    }

    /// Play shapes through the recorder as one hold of the talk key (60 Hz, a one-second pause between shapes, so
    /// each becomes its own mark). Points are mapped from `geometry`'s pixels to AppKit global points.
    public static func gesture(_ shapes: [Shape], geometry: CaptureGeometry, dwellAtEnd: TimeInterval = 0) -> HighlightGesture? {
        var recorder = HighlightRecorder()
        let paths = shapes.map { $0.pixels.map { geometry.appKitPoint(fromPixel: $0) } }
        guard let first = paths.first?.first else { return nil }
        recorder.begin(at: first, time: 0)
        var t: TimeInterval = 0
        for (index, path) in paths.enumerated() {
            for point in path {
                t += 1.0 / 60
                recorder.move(to: point, time: t)
            }
            if dwellAtEnd > 0, let last = path.last {
                // Rest on the last spot (tiny jitter, as a hand does).
                let steps = Int(dwellAtEnd * 60)
                for i in 0..<steps {
                    t += 1.0 / 60
                    recorder.move(to: CGPoint(x: last.x + CGFloat(i % 2), y: last.y), time: t)
                }
            }
            if index < paths.count - 1, let last = path.last, let next = paths[index + 1].first {
                // Pause (the mark ends), then flick quickly to the next mark's start (travel leaves no ink).
                t += 1.0
                recorder.idle(at: t)
                for step in 1...3 {
                    let f = CGFloat(step) / 3
                    t += 1.0 / 60
                    recorder.move(to: CGPoint(x: last.x + (next.x - last.x) * f, y: last.y + (next.y - last.y) * f), time: t)
                }
            }
        }
        return recorder.end(at: t + 0.05)
    }

    /// A made-up document page with real words, for OCR to read (no real screenshot needed). Returns the image and
    /// where each line was put (pixels, top-left origin).
    public static func demoScreen(width: Int = 1280, height: Int = 800) -> (image: CGImage, lines: [(String, CGRect)]) {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ hex: String, _ r: CGRect) {
            context.setFillColor(DrawingColor(hex: hex)!.cgColor)
            context.fill(CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height))
        }
        fill("#C9D3E0", CGRect(x: 0, y: 0, width: width, height: height))
        fill("#FFFFFF", CGRect(x: 60, y: 50, width: width - 120, height: height - 100))
        fill("#F1F3F6", CGRect(x: 60, y: 50, width: width - 120, height: 46))
        var placed: [(String, CGRect)] = []
        func words(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false, color: String = "#1F2328") {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): DrawingColor(hex: color)!.cgColor,
            ]))
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - y - ascent)
            CTLineDraw(line, context)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            placed.append((text, CGRect(x: x, y: y, width: w, height: ascent + descent)))
        }
        words("Quarterly report — Q3", x: 100, y: 62, size: 20, bold: true)
        words("Revenue grew 12% to $4.8 million", x: 100, y: 150, size: 30, bold: true)
        words("Most of the growth came from the new subscription plan,", x: 100, y: 220, size: 22)
        words("which now makes up 41% of all sales.", x: 100, y: 254, size: 22)
        words("Operating costs stayed flat at $3.1 million.", x: 100, y: 320, size: 22)
        words("Next steps: hire two support engineers in November.", x: 100, y: 400, size: 22)
        // A button, as an app would draw one.
        fill("#3380FF", CGRect(x: 100, y: 480, width: 170, height: 44))
        words("Export PDF", x: 128, y: 490, size: 20, bold: true, color: "#FFFFFF")
        words("Last updated October 30", x: 100, y: 700, size: 16, color: "#6E737D")
        return (context.makeImage()!, placed)
    }
}
