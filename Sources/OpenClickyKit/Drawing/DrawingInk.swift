import CoreGraphics
import Foundation
import QuartzCore

/// The felt-tip pen and the watercolour wash: the two looks that make a drawing on paper read as drawn by hand.
///
/// - A tapered stroke is a filled outline whose width follows the pen's pressure (fine at the start, full in the
///   middle, fine again at the end, with a slight swell), revealed by a mask that strokes the centreline from start to
///   end, so the pen still draws it on.
/// - A wash is a fill whose edge is pushed about by smooth noise (two octaves of value noise), with a little pigment
///   granulation, rendered once to a bitmap.
enum DrawingInk {
    // MARK: Tapered strokes

    /// Points along a path, curves flattened (about every 3 points of length).
    static func flatten(_ path: CGPath) -> [CGPoint] {
        var out: [CGPoint] = []
        var current = CGPoint.zero, start = CGPoint.zero
        func add(_ p: CGPoint) { if out.last != p { out.append(p) } }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; start = current; add(current)
            case .addLineToPoint:
                current = e.points[0]; add(current)
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                let n = max(2, Int(hypot(end.x - current.x, end.y - current.y) / 3))
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    add(CGPoint(x: u * u * current.x + 2 * u * t * c.x + t * t * end.x, y: u * u * current.y + 2 * u * t * c.y + t * t * end.y))
                }
                current = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                let n = max(2, Int(hypot(end.x - current.x, end.y - current.y) / 3))
                for k in 1...n {
                    let t = CGFloat(k) / CGFloat(n), u = 1 - t
                    let x = u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
                    let y = u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                    add(CGPoint(x: x, y: y))
                }
                current = end
            case .closeSubpath:
                add(start); current = start
            @unknown default: break
            }
        }
        return out
    }

    /// The outline of a felt-tip stroke along `points` (width `width` at full pressure; `taper` 0…1 how much the ends
    /// thin out), with round ends.
    static func taperedOutline(_ points: [CGPoint], width: CGFloat, taper: CGFloat) -> CGPath {
        let path = CGMutablePath()
        // Drop near-duplicates so the normals are stable.
        var pts: [CGPoint] = []
        for p in points where pts.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.5 }) ?? true { pts.append(p) }
        guard pts.count >= 2 else {
            if let p = points.first { path.addEllipse(in: CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width)) }
            return path
        }
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = max(lengths.last ?? 1, 0.001)
        let ramp = max(0.001, min(total * 0.3, width * 5))
        func half(_ s: CGFloat) -> CGFloat {
            let edge = min(s, total - s)
            var p: CGFloat = 1
            if edge < ramp {
                let t = edge / ramp
                p = 1 - taper * 0.65 * (1 - t * t * (3 - 2 * t))
            }
            let swell = 1 + 0.03 * sin(2 * .pi * s / 44)
            return width / 2 * p * swell
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<pts.count {
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            dx /= len; dy /= len
            let h = half(lengths[i])
            left.append(CGPoint(x: pts[i].x - dy * h, y: pts[i].y + dx * h))
            right.append(CGPoint(x: pts[i].x + dy * h, y: pts[i].y - dx * h))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        // Round end: a half circle from the left edge to the right edge around the last point.
        cap(path, around: pts[pts.count - 1], from: left[left.count - 1], to: right[right.count - 1])
        for p in right.reversed().dropFirst() { path.addLine(to: p) }
        cap(path, around: pts[0], from: right[0], to: left[0])
        path.closeSubpath()
        return path
    }

    private static func cap(_ path: CGMutablePath, around c: CGPoint, from a: CGPoint, to b: CGPoint) {
        let r = hypot(a.x - c.x, a.y - c.y)
        guard r > 0.05 else { path.addLine(to: b); return }
        let start = atan2(a.y - c.y, a.x - c.x)
        for k in 1...6 {
            let angle = start - .pi * CGFloat(k) / 6
            path.addLine(to: CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
        }
        path.addLine(to: b)
    }

    // MARK: Washes

    /// Fills larger than this (in points², about 245 × 245) stay crisp: a wash there would cost too much and show little.
    static let washMaxArea: CGFloat = 60_000

    /// A watercolour wash of `path` (in the canvas's points): its bitmap, and where it goes. Nil when too big or empty.
    static func wash(_ path: CGPath, color: CGColor, alpha: CGFloat, seed: UInt32) -> (image: CGImage, frame: CGRect)? {
        let box = path.boundingBoxOfPath
        guard box.width > 1, box.height > 1, box.width * box.height <= washMaxArea else { return nil }
        let margin: CGFloat = 6
        let frame = box.insetBy(dx: -margin, dy: -margin).integral
        let width = Int(frame.width), height = Int(frame.height)
        // The fill's coverage, one byte per point.
        var coverage = [UInt8](repeating: 0, count: width * height)
        guard let gray = CGContext(data: &coverage, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        // Memory rows run top-down; flip so the y-down path lands the right way up.
        gray.translateBy(x: 0, y: CGFloat(height))
        gray.scaleBy(x: 1, y: -1)
        gray.translateBy(x: -frame.minX, y: -frame.minY)
        gray.setFillColor(gray: 1, alpha: 1)
        gray.addPath(path)
        gray.fillPath()

        let rgba = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        let r = rgba.count > 0 ? rgba[0] : 0, g = rgba.count > 1 ? rgba[1] : 0, b = rgba.count > 2 ? rgba[2] : 0
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let noise = ValueNoise(seed: seed)
        func coverageAt(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            guard xi >= 0, yi >= 0, xi < width, yi < height else { return 0 }
            return CGFloat(coverage[yi * width + xi]) / 255
        }
        for y in 0..<height {
            for x in 0..<width {
                let fx = CGFloat(x + Int(frame.minX)), fy = CGFloat(y + Int(frame.minY))
                // The edge wanders by up to ~3.5 points; the pigment pools a little.
                let dx = noise.turbulence(fx * 0.045, fy * 0.045) * 3.5
                let dy = noise.turbulence(fx * 0.045 + 31.7, fy * 0.045 + 17.3) * 3.5
                let c = coverageAt(CGFloat(x) + dx, CGFloat(y) + dy)
                guard c > 0 else { continue }
                let grain = 0.9 + 0.14 * noise.value(fx * 0.32, fy * 0.32)
                let a = min(1, c * alpha * grain)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(max(0, min(255, r * a * 255)))
                pixels[i + 1] = UInt8(max(0, min(255, g * a * 255)))
                pixels[i + 2] = UInt8(max(0, min(255, b * a * 255)))
                pixels[i + 3] = UInt8(max(0, min(255, a * 255)))
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return (image, frame)
    }

    /// Smooth value noise on a hashed lattice: `value` in 0…1, `turbulence` (two octaves) in −1…1.
    struct ValueNoise {
        let seed: UInt32
        private func hash(_ x: Int, _ y: Int) -> CGFloat {
            var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263) &+ seed &* 2654435761
            h = (h ^ (h >> 13)) &* 1274126177
            h ^= h >> 16
            return CGFloat(h & 0xFFFF) / 65535
        }
        func value(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let tx = x - floor(x), ty = y - floor(y)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let a = hash(x0, y0), b = hash(x0 + 1, y0), c = hash(x0, y0 + 1), d = hash(x0 + 1, y0 + 1)
            return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
        }
        func turbulence(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            (value(x, y) - 0.5) * 1.4 + (value(x * 2.1, y * 2.1) - 0.5) * 0.6
        }
    }
}
