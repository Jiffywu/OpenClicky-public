import CoreGraphics
import CoreText
import Foundation
import QuartzCore

/// One builder per 2D mark kind (docs/dsl.md, "Marks"). Each returns a full-canvas container whose sublayers carry
/// the mark's reveal animations.
extension DrawingPainter {
    func build(_ mark: DrawingMark, begin: CFTimeInterval, duration: CFTimeInterval) -> (CALayer, Group) {
        let json = mark.json
        let container = CALayer()
        switch mark.kind {
        case "line": buildLine(json, in: container, begin: begin, duration: duration, arrow: false); return (container, .main)
        case "arrow": buildLine(json, in: container, begin: begin, duration: duration, arrow: true); return (container, .main)
        case "box", "circle": buildShape(json, kind: mark.kind, in: container, begin: begin, duration: duration); return (container, .main)
        case "dot": buildDot(json, in: container, begin: begin, duration: duration); return (container, .main)
        case "text": buildText(json, in: container, begin: begin, duration: duration); return (container, .words)
        case "highlight": buildHighlight(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "region": buildRegion(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "pill", "badge", "button": buildGel(json, kind: mark.kind, in: container, begin: begin, duration: duration); return (container, .words)
        case "paper": buildPaper(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "graph": buildGraph(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "photo", "place", "stock", "favicon", "image": buildMedia(json, kind: mark.kind, in: container, begin: begin, duration: duration); return (container, .main)
        case "spotlight": buildSpotlight(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "sticky": buildSticky(json, in: container, begin: begin, duration: duration); return (container, .under)
        case "action": return (container, .main)
        default:
            container.setValue(mark.kind, forKey: "unknownKind")
            return (container, .main)
        }
    }

    // MARK: Strokes

    private func strokeLayer(_ path: CGPath, json: JSONValue, name: String) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.name = name
        shape.frame = layer.bounds
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color(json["tone"], alpha: json["alpha"]?.doubleValue)
        shape.lineWidth = max(0.5, u(json["size"]?.doubleValue ?? 3))
        shape.lineCap = .round
        shape.lineJoin = .round
        if let dash = json["dash"]?.arrayValue, dash.count >= 2 {
            shape.lineDashPattern = [NSNumber(value: Double(u(dash[0].doubleValue))), NSNumber(value: Double(u(dash[1].doubleValue)))]
            shape.lineCap = .butt
        }
        applyGlow(shape, json: json)
        return shape
    }

    /// Ink on the screen gets a halo of the same hue (`glow: [opacity, radius in points]`).
    private func applyGlow(_ target: CALayer, json: JSONValue) {
        guard let glow = json["glow"]?.arrayValue, glow.count >= 2 else { return }
        target.shadowColor = color(json["tone"])
        target.shadowOpacity = Float(glow[0].doubleValue ?? 0.6)
        target.shadowRadius = CGFloat(glow[1].doubleValue ?? 8)
        target.shadowOffset = .zero
    }

    /// Ink along `path`, drawn on by the pen: an even stroke (the screen pen), or on paper a felt-tip outline that
    /// tapers at both ends, revealed through a mask that strokes the centreline.
    private func inkLayer(_ path: CGPath, json: JSONValue, name: String, begin: CFTimeInterval, duration: CFTimeInterval) -> CALayer {
        guard let taper = json["taper"]?.doubleValue, taper > 0, json["dash"] == nil else {
            let shape = strokeLayer(path, json: json, name: name)
            pen(shape, begin: begin, duration: duration)
            return shape
        }
        let width = max(0.5, u(json["size"]?.doubleValue ?? 3))
        let ink = CAShapeLayer()
        ink.name = name
        ink.frame = layer.bounds
        ink.path = DrawingInk.taperedOutline(DrawingInk.flatten(path), width: width * 1.2, taper: CGFloat(taper))
        ink.fillColor = color(json["tone"], alpha: json["alpha"]?.doubleValue)
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = path
        mask.fillColor = nil
        mask.strokeColor = CGColor(gray: 0, alpha: 1)
        mask.lineWidth = width * 2 + 4
        mask.lineCap = .round
        mask.lineJoin = .round
        pen(mask, begin: begin, duration: duration)
        ink.mask = mask
        return ink
    }

    /// A fill: a watercolour wash with a wandering edge for drawn shapes small enough, else a crisp fill.
    private func fillLayer(_ path: CGPath, json: JSONValue, hex: String, alpha: Double) -> CALayer {
        let fillColor = color(.string(hex))
        if json["wash"]?.boolValue != false,
           let wash = DrawingInk.wash(path, color: fillColor, alpha: CGFloat(alpha), seed: UInt32(truncatingIfNeeded: (json["id"]?.stringValue ?? "").hashValue & 0x7FFF_FFFF)) {
            let layer = CALayer()
            layer.name = "fill"
            layer.frame = wash.frame
            layer.contents = wash.image
            layer.contentsGravity = .resize
            return layer
        }
        let fill = CAShapeLayer()
        fill.name = "fill"
        fill.frame = layer.bounds
        fill.path = path
        fill.fillColor = color(.string(hex), alpha: alpha)
        return fill
    }

    private func buildLine(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval, arrow: Bool) {
        let path: CGPath
        if let segs = json["segs"]?.arrayValue, !segs.isEmpty {
            let multi = CGMutablePath()
            for seg in segs {
                let pts = points(seg)
                guard let first = pts.first else { continue }
                multi.move(to: first)
                for p in pts.dropFirst() { multi.addLine(to: p) }
            }
            path = multi
        } else {
            path = Self.path(points(json["pts"]), smooth: json["smooth"]?.boolValue == true)
        }
        let shaftDuration = arrow ? duration * 0.78 : duration
        if let fillHex = json["fill"]?.stringValue, json["closed"]?.boolValue == true {
            // A closed outline (poly, trace, a closed path) with a wash inside, faded in under the pen.
            let fill = fillLayer(path, json: json, hex: fillHex, alpha: json["fillAlpha"]?.doubleValue ?? 0.25)
            fade(fill, begin: begin + duration * 0.3, duration: max(0.25, duration * 0.6))
            container.addSublayer(fill)
        }
        if json["outline"]?.boolValue == false { return }
        let shaft = inkLayer(path, json: json, name: "stroke", begin: begin, duration: shaftDuration)
        container.addSublayer(shaft)
        guard arrow else { return }
        for key in ["head", "tail"] {
            let pts = points(json[key])
            guard pts.count == 3 else { continue }
            let head = strokeLayer(Self.path(pts, smooth: false), json: json, name: key)
            head.lineDashPattern = nil
            head.lineCap = .round
            pen(head, begin: begin + shaftDuration, duration: max(0.06, duration - shaftDuration))
            container.addSublayer(head)
        }
    }

    // MARK: Shapes

    private func buildShape(_ json: JSONValue, kind: String, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let outlined = json["outline"]?.boolValue != false
        if let fillHex = json["fill"]?.stringValue {
            let area: CGPath
            if kind == "circle" {
                let c = point(json["at"]), rx = u(json["rx"]?.doubleValue), ry = u(json["ry"]?.doubleValue)
                area = CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
            } else {
                let r = rect(json), radius = min(u(json["r"]?.doubleValue), r.width / 2, r.height / 2)
                area = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            let fill = fillLayer(area, json: json, hex: fillHex, alpha: json["fillAlpha"]?.doubleValue ?? 1)
            fade(fill, begin: outlined ? begin + duration * 0.35 : begin, duration: outlined ? max(0.25, duration * 0.6) : max(0.2, duration))
            container.addSublayer(fill)
        }
        guard outlined else { return }
        let pts = points(json["pts"])
        let path: CGPath
        if pts.count >= 3 {
            path = Self.path(pts, smooth: json["smooth"]?.boolValue != false)
        } else if kind == "circle" {
            let c = point(json["at"]), rx = u(json["rx"]?.doubleValue), ry = u(json["ry"]?.doubleValue)
            path = CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        } else {
            let r = rect(json), radius = min(u(json["r"]?.doubleValue), r.width / 2, r.height / 2)
            path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let outline = inkLayer(path, json: json, name: "stroke", begin: begin, duration: duration)
        container.addSublayer(outline)
    }

    private func buildDot(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let c = point(json["at"]), r = max(1, u(json["r"]?.doubleValue ?? 5))
        let dot = CAShapeLayer()
        dot.name = "dot"
        dot.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = color(json["tone"], alpha: json["alpha"]?.doubleValue)
        applyGlow(dot, json: json)
        pop(dot, begin: begin, duration: max(0.15, duration))
        container.addSublayer(dot)
    }

    private func buildHighlight(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let r = rect(json)
        let band = CAShapeLayer()
        band.name = "band"
        band.anchorPoint = CGPoint(x: 0, y: 0.5)
        band.frame = r
        band.path = CGPath(roundedRect: band.bounds, cornerWidth: min(r.height * 0.25, 6), cornerHeight: min(r.height * 0.25, 6), transform: nil)
        band.fillColor = color(json["tone"], alpha: json["alpha"]?.doubleValue ?? 0.4, fallback: DrawingColor(hex: "#FFD23F")!)
        // Multiplied with the screen under it, like a real highlighter: dark words stay dark and crisp. The overlay is
        // another window and can't blend with the app beneath, so the band shows the screenshot's pixels under it
        // multiplied by the ink (the drawing is cleared when that part of the screen changes).
        if json["blend"]?.stringValue == "multiply", let screen,
           let tone = DrawingColor(hex: json["tone"]?.stringValue),
           let multiplied = Self.multiply(screen, canvasRect: canvasRect(json), canvas: canvas, by: tone, strength: min(1, (json["alpha"]?.doubleValue ?? 0.5) * 1.6)) {
            band.fillColor = CGColor(gray: 0, alpha: 1)
            let shown = CALayer()
            shown.frame = band.bounds
            shown.contents = multiplied
            shown.contentsGravity = .resize
            let clip = CAShapeLayer()
            clip.frame = band.bounds
            clip.path = band.path
            shown.mask = clip
            band.addSublayer(shown)
            band.fillColor = nil
        }
        swipe(band, begin: begin, duration: max(0.15, duration))
        container.addSublayer(band)
    }

    /// `at`, `w`, `h` in canvas units.
    private func canvasRect(_ json: JSONValue) -> CGRect {
        let at = json["at"]?.arrayValue ?? []
        return CGRect(x: at.first?.doubleValue ?? 0, y: at.dropFirst().first?.doubleValue ?? 0,
                      width: json["w"]?.doubleValue ?? 0, height: json["h"]?.doubleValue ?? 0)
    }

    /// The screenshot's pixels under `canvasRect`, each channel multiplied by the ink (`strength` 0…1 of the way).
    static func multiply(_ screen: CGImage, canvasRect: CGRect, canvas: Canvas, by tone: DrawingColor, strength: Double) -> CGImage? {
        let sx = Double(screen.width) / max(1, canvas.width), sy = Double(screen.height) / max(1, canvas.height)
        let pixels = CGRect(x: canvasRect.minX * sx, y: canvasRect.minY * sy, width: canvasRect.width * sx, height: canvasRect.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, pixels.width * pixels.height <= 4_000_000,
              let crop = screen.cropping(to: pixels) else { return nil }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        let k = max(0, min(1, strength))
        let factors = [1 - k * (1 - tone.red), 1 - k * (1 - tone.green), 1 - k * (1 - tone.blue)]
        for i in stride(from: 0, to: data.count, by: 4) {
            for c in 0..<3 { data[i + c] = UInt8(max(0, min(255, Double(data[i + c]) * factors[c]))) }
            data[i + 3] = 255
        }
        return context.makeImage()
    }

    private func buildRegion(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let r = rect(json)
        let holder = CALayer()
        holder.name = "region"
        holder.anchorPoint = .zero
        holder.frame = r
        let radius = min(u(json["r"]?.doubleValue ?? 8), r.width / 2, r.height / 2)
        let outline = CGPath(roundedRect: holder.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let tint = CAShapeLayer()
        tint.name = "tint"
        tint.frame = holder.bounds
        tint.path = outline
        tint.fillColor = color(json["tone"], alpha: json["fillAlpha"]?.doubleValue ?? 0.08)
        holder.addSublayer(tint)
        let frame = strokeLayer(outline, json: json, name: "frame")
        frame.frame = holder.bounds
        holder.addSublayer(frame)
        grow(holder, begin: begin, duration: max(0.2, duration))
        container.addSublayer(holder)
    }

    // MARK: Words

    /// Lays out a text mark's lines inside `frame` and returns the glyph outlines plus each line's extent.
    private func shapeText(_ json: JSONValue) -> (path: CGPath, lines: [CGRect], frame: CGRect) {
        let style = DrawingTextStyle(name: json["style"]?.stringValue)
        let size = max(1, u(json["size"]?.doubleValue ?? 18))
        let lineHeight = max(size, u(json["lh"]?.doubleValue ?? (json["size"]?.doubleValue ?? 18) * 1.25))
        let frame = rect(json)
        let ascent = DrawingFonts.ascent(style, size: size), descent = DrawingFonts.descent(style, size: size)
        let align = json["align"]?.stringValue ?? "left"
        let path = CGMutablePath()
        var extents: [CGRect] = []
        let lines = (json["lines"]?.arrayValue?.compactMap(\.stringValue)) ?? [json["text"]?.stringValue ?? ""]
        for (index, line) in lines.enumerated() {
            let top = frame.minY + CGFloat(index) * lineHeight
            let baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent
            let width = CGFloat(DrawingFonts.width(of: line, size: Double(size), style: style))
            let x: CGFloat = align == "center" ? frame.midX - width / 2 : align == "right" ? frame.maxX - width : frame.minX
            let glyphs = DrawingFonts.glyphPath(line, style: style, size: size, origin: CGPoint(x: x, y: baseline))
            path.addPath(glyphs.path)
            extents.append(CGRect(x: x, y: top, width: width, height: lineHeight))
        }
        return (path, extents, frame)
    }

    private func buildText(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let shaped = shapeText(json)
        let words = CALayer()
        words.name = "words"
        words.frame = layer.bounds
        let size = u(json["size"]?.doubleValue ?? 18)
        if let haloHex = json["halo"]?.stringValue {
            let halo = CAShapeLayer()
            halo.name = "halo"
            halo.frame = layer.bounds
            halo.path = shaped.path
            halo.fillColor = nil
            halo.strokeColor = color(.string(haloHex), alpha: 0.55)
            halo.lineWidth = max(2, size * 0.16)
            halo.lineJoin = .round
            halo.lineCap = .round
            words.addSublayer(halo)
        }
        let glyphs = CAShapeLayer()
        glyphs.name = "glyphs"
        glyphs.frame = layer.bounds
        glyphs.path = shaped.path
        glyphs.fillColor = color(json["tone"], alpha: json["alpha"]?.doubleValue)
        let bold = DrawingFonts.syntheticBoldWidth(DrawingTextStyle(name: json["style"]?.stringValue), size: size)
        if bold > 0 {
            // A heading in handwriting: the single-weight face thickened with an outline in its own ink.
            glyphs.strokeColor = glyphs.fillColor
            glyphs.lineWidth = bold
            glyphs.lineJoin = .round
        }
        words.addSublayer(glyphs)
        if json["link"]?.stringValue != nil {
            // Linked words are underlined: they can be clicked (DrawingSession.click(at:)).
            let underline = CAShapeLayer()
            underline.name = "link"
            underline.frame = layer.bounds
            let path = CGMutablePath()
            for line in shaped.lines where line.width > 0 {
                let y = line.maxY - line.height * 0.12
                path.move(to: CGPoint(x: line.minX, y: y))
                path.addLine(to: CGPoint(x: line.maxX, y: y))
            }
            underline.path = path
            underline.strokeColor = color(json["tone"], alpha: 0.75)
            underline.lineWidth = max(1, size * 0.06)
            underline.fillColor = nil
            words.addSublayer(underline)
        }
        container.addSublayer(words)

        if json["reveal"]?.stringValue == "write" {
            // Written left to right, one line after another.
            let mask = CALayer()
            mask.frame = layer.bounds
            let total = shaped.lines.reduce(0) { $0 + $1.width }
            var elapsed: CGFloat = 0
            let pad = max(2, size * 0.2)
            for line in shaped.lines {
                let strip = CALayer()
                strip.backgroundColor = CGColor(gray: 0, alpha: 1)
                strip.anchorPoint = CGPoint(x: 0, y: 0.5)
                strip.frame = line.insetBy(dx: -pad, dy: -pad)
                let share = total > 0 ? Double(line.width / total) : 1
                let wipe = CABasicAnimation(keyPath: "bounds.size.width")
                wipe.fromValue = 0
                wipe.toValue = strip.bounds.width
                wipe.beginTime = begin + duration * Double(total > 0 ? elapsed / total : 0)
                wipe.duration = max(0.05, duration * share)
                wipe.fillMode = .backwards
                strip.add(wipe, forKey: "write")
                mask.addSublayer(strip)
                elapsed += line.width
            }
            words.mask = mask
        } else {
            fade(words, begin: begin, duration: max(0.15, duration))
        }
    }

    // MARK: Gels: pills, badges and buttons

    private func buildGel(_ json: JSONValue, kind: String, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let frame: CGRect
        if kind == "badge" {
            let c = point(json["at"]), r = u(json["r"]?.doubleValue ?? 11)
            frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        } else {
            frame = rect(json)
        }
        let gel = (DrawingColor(hex: json["tone"]?.stringValue) ?? .defaultInk).gel
        let holder = CALayer()
        holder.name = kind
        holder.frame = frame
        let bounds = holder.bounds
        let radius = min(bounds.height / 2, bounds.width / 2)
        let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if kind == "button" {
            holder.shadowColor = CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            holder.shadowOpacity = 0.28
            holder.shadowRadius = 6
            holder.shadowOffset = CGSize(width: 0, height: 2)
            holder.shadowPath = outline
        }
        let body = CAGradientLayer()
        body.name = "gel"
        body.frame = bounds
        body.colors = [gel.top.cgColor, gel.bottom.cgColor]
        body.startPoint = CGPoint(x: 0.5, y: 0)
        body.endPoint = CGPoint(x: 0.5, y: 1)
        let bodyMask = CAShapeLayer()
        bodyMask.frame = bounds
        bodyMask.path = outline
        body.mask = bodyMask
        holder.addSublayer(body)

        let gloss = CAShapeLayer()
        gloss.name = "gloss"
        gloss.frame = bounds
        let glossRect = CGRect(x: bounds.minX + radius * 0.55, y: bounds.minY + bounds.height * 0.1, width: max(0, bounds.width - radius * 1.1), height: bounds.height * 0.36)
        gloss.path = CGPath(roundedRect: glossRect, cornerWidth: glossRect.height / 2, cornerHeight: glossRect.height / 2, transform: nil)
        gloss.fillColor = gel.gloss.withAlpha(0.45).cgColor
        holder.addSublayer(gloss)

        let rim = CAShapeLayer()
        rim.name = "rim"
        rim.frame = bounds
        rim.path = outline
        rim.fillColor = nil
        rim.strokeColor = gel.rim.withAlpha(0.85).cgColor
        rim.lineWidth = 1
        holder.addSublayer(rim)

        let text = json["text"]?.stringValue ?? ""
        if !text.isEmpty {
            let size = u(json["size"]?.doubleValue ?? 13)
            let style = DrawingTextStyle.bold
            let width = CGFloat(DrawingFonts.width(of: text, size: Double(size), style: style))
            let ascent = DrawingFonts.ascent(style, size: size), descent = DrawingFonts.descent(style, size: size)
            let baseline = bounds.midY + (ascent - descent) / 2
            var x = bounds.midX - width / 2
            if kind == "badge" && text == "1" { x += size * 0.04 }
            let glyphs = CAShapeLayer()
            glyphs.name = "glyphs"
            glyphs.frame = bounds
            glyphs.path = DrawingFonts.glyphPath(text, style: style, size: size, origin: CGPoint(x: x, y: baseline)).path
            glyphs.fillColor = color(json["color"], fallback: DrawingColor(hex: "#16181D")!)
            holder.addSublayer(glyphs)
        }
        pop(holder, begin: begin, duration: max(0.2, duration))
        container.addSublayer(holder)
    }

    // MARK: Paper

    private func buildPaper(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let frame = rect(json)
        let header = u(json["header"]?.doubleValue ?? 28)
        let ink = DrawingColor(hex: json["tone"]?.stringValue) ?? .defaultInk
        let paperColor = DrawingColor(hex: json["paper"]?.stringValue) ?? DrawingColor(hex: "#FCF9F3")!
        let card = CALayer()
        card.name = "paper"
        card.frame = frame
        let bounds = card.bounds
        let radius: CGFloat = 10
        // A card that grew (edit "grow") glides out from its old size, in this card's own coordinates.
        var old: CGRect?
        if json["edit"]?.stringValue == "grow", let from = json["from"]?.arrayValue, from.count >= 4 {
            old = CGRect(x: u(from[0].doubleValue) - frame.minX, y: u(from[1].doubleValue) - frame.minY,
                         width: u(from[2].doubleValue), height: u(from[3].doubleValue))
        }
        func outline(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
        func morph(_ shape: CAShapeLayer, _ keyPath: String, _ from: CGPath?) {
            guard let from else { return }
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = from
            a.beginTime = begin
            a.duration = max(0.15, duration)
            a.fillMode = .backwards
            a.timingFunction = Self.glide
            shape.add(a, forKey: "grow-\(keyPath)")
        }

        let sheet = CAShapeLayer()
        sheet.name = "sheet"
        sheet.frame = bounds
        sheet.path = outline(bounds)
        sheet.fillColor = paperColor.cgColor
        sheet.strokeColor = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0.12).cgColor
        sheet.lineWidth = 1
        sheet.shadowColor = CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        sheet.shadowOpacity = 0.22
        sheet.shadowRadius = 14
        sheet.shadowOffset = CGSize(width: 0, height: 5)
        sheet.shadowPath = outline(bounds)
        morph(sheet, "path", old.map(outline))
        if let old {
            let shadow = CABasicAnimation(keyPath: "shadowPath")
            shadow.fromValue = outline(old)
            shadow.beginTime = begin
            shadow.duration = max(0.15, duration)
            shadow.fillMode = .backwards
            shadow.timingFunction = Self.glide
            sheet.add(shadow, forKey: "grow-shadow")
        }
        card.addSublayer(sheet)

        let inside = CALayer()
        inside.frame = bounds
        let clip = CAShapeLayer()
        clip.frame = bounds
        clip.path = outline(bounds)
        morph(clip, "path", old.map(outline))
        inside.mask = clip
        card.addSublayer(inside)

        let board = json["board"]?.stringValue ?? "plain"
        if board != "plain" {
            let pattern = CAShapeLayer()
            pattern.name = "board"
            pattern.frame = bounds
            let path = CGMutablePath()
            let gap: CGFloat = 24
            // Only as much board as the canvas can show: a card sized past the screen must not cost the main thread
            // millions of path elements.
            let width = min(bounds.width, layer.bounds.width), height = min(bounds.height, layer.bounds.height)
            if board == "grid" {
                var x = gap
                while x < width { path.move(to: CGPoint(x: x, y: header)); path.addLine(to: CGPoint(x: x, y: height)); x += gap }
                var y = header + gap
                while y < height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y)); y += gap }
                pattern.strokeColor = ink.withAlpha(0.09).cgColor
                pattern.lineWidth = 1
                pattern.fillColor = nil
            } else {
                var y = header + gap
                while y < height {
                    var x = gap
                    while x < width { path.addEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4)); x += gap }
                    y += gap
                }
                pattern.fillColor = ink.withAlpha(0.16).cgColor
            }
            pattern.path = path
            inside.addSublayer(pattern)
        }

        func barPath(_ r: CGRect) -> CGPath { CGPath(rect: CGRect(x: r.minX, y: r.minY, width: r.width, height: header), transform: nil) }
        let bar = CAShapeLayer()
        bar.name = "titlebar"
        bar.frame = bounds
        bar.path = barPath(bounds)
        morph(bar, "path", old.map(barPath))
        bar.fillColor = paperColor.mixed(with: ink, 0.07).mixed(with: .black, 0.03).cgColor
        inside.addSublayer(bar)
        func dividerPath(_ r: CGRect) -> CGPath {
            let line = CGMutablePath()
            line.move(to: CGPoint(x: r.minX, y: r.minY + header))
            line.addLine(to: CGPoint(x: r.maxX, y: r.minY + header))
            return line
        }
        let divider = CAShapeLayer()
        divider.frame = bounds
        divider.path = dividerPath(bounds)
        morph(divider, "path", old.map(dividerPath))
        divider.strokeColor = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0.1).cgColor
        divider.lineWidth = 1
        inside.addSublayer(divider)

        func lightsPath(_ r: CGRect) -> CGPath {
            let dots = CGMutablePath()
            for i in 0..<3 {
                dots.addEllipse(in: CGRect(x: r.minX + 12 + CGFloat(i) * 17, y: r.minY + header / 2 - 5.5, width: 11, height: 11))
            }
            return dots
        }
        let lights = CAShapeLayer()
        lights.name = "lights"
        lights.frame = bounds
        lights.path = lightsPath(bounds)
        morph(lights, "path", old.map(lightsPath))
        lights.fillColor = paperColor.mixed(with: .black, 0.16).cgColor
        inside.addSublayer(lights)

        let title = json["title"]?.stringValue ?? ""
        if !title.isEmpty {
            let font = DrawingFonts.titleBarFont(size: 14)
            let width = CGFloat(CTLineGetTypographicBounds(DrawingFonts.line(title, font: font), nil, nil, nil))
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            func titlePath(_ r: CGRect) -> CGPath {
                let origin = CGPoint(x: r.minX + max(70, r.width / 2 - width / 2), y: r.minY + header / 2 + (ascent - descent) / 2)
                return DrawingFonts.glyphPath(title, font: font, origin: origin).path
            }
            let glyphs = CAShapeLayer()
            glyphs.name = "title"
            glyphs.frame = bounds
            glyphs.path = titlePath(bounds)
            morph(glyphs, "path", old.map(titlePath))
            glyphs.fillColor = DrawingColor(hex: "#3A3D45")!.cgColor
            inside.addSublayer(glyphs)
        }

        if old == nil {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            opacity.toValue = 1
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.96
            settle.toValue = 1
            group([opacity, settle], on: card, key: "appear", begin: begin, duration: max(0.2, duration))
        }
        container.addSublayer(card)
    }

    // MARK: Spotlight and sticky notes

    /// The screen dimmed except one rounded hole (`hole: [x, y, w, h]`, radius `r`), faded in.
    private func buildSpotlight(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let dim = CAShapeLayer()
        dim.name = "spotlight"
        dim.frame = layer.bounds
        let path = CGMutablePath()
        path.addRect(layer.bounds)
        if let hole = json["hole"]?.arrayValue, hole.count >= 4 {
            let r = CGRect(x: u(hole[0].doubleValue), y: u(hole[1].doubleValue), width: u(hole[2].doubleValue), height: u(hole[3].doubleValue))
            let radius = min(u(json["r"]?.doubleValue ?? 10), r.width / 2, r.height / 2)
            path.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        dim.path = path
        dim.fillRule = .evenOdd
        dim.fillColor = color(json["tone"], alpha: json["alpha"]?.doubleValue ?? 0.6, fallback: DrawingColor(hex: "#0C0E12")!)
        fade(dim, begin: begin, duration: max(0.2, duration))
        container.addSublayer(dim)
    }

    /// A square note in a paper tone, tilted, with a soft shadow, a folded corner, a strip of tape and its words.
    private func buildSticky(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let frame = rect(json)
        let note = CALayer()
        note.name = "sticky"
        note.frame = frame
        let bounds = note.bounds
        let paper = DrawingColor(hex: json["paper"]?.stringValue) ?? DrawingColor(hex: "#FFE98A")!
        let fold = min(bounds.width, bounds.height) * 0.14
        let outline = CGMutablePath()
        outline.move(to: .zero)
        outline.addLine(to: CGPoint(x: bounds.maxX, y: 0))
        outline.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - fold))
        outline.addLine(to: CGPoint(x: bounds.maxX - fold, y: bounds.maxY))
        outline.addLine(to: CGPoint(x: 0, y: bounds.maxY))
        outline.closeSubpath()
        let sheet = CAShapeLayer()
        sheet.path = outline
        sheet.fillColor = paper.cgColor
        sheet.shadowColor = CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        sheet.shadowOpacity = 0.25
        sheet.shadowRadius = 8
        sheet.shadowOffset = CGSize(width: 0, height: 4)
        sheet.shadowPath = outline
        note.addSublayer(sheet)
        let corner = CAShapeLayer()
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: bounds.maxX, y: bounds.maxY - fold))
        flap.addLine(to: CGPoint(x: bounds.maxX - fold, y: bounds.maxY - fold))
        flap.addLine(to: CGPoint(x: bounds.maxX - fold, y: bounds.maxY))
        flap.closeSubpath()
        corner.path = flap
        corner.fillColor = paper.mixed(with: .black, 0.12).cgColor
        note.addSublayer(corner)
        let tape = CAShapeLayer()
        let tapeRect = CGRect(x: bounds.midX - bounds.width * 0.2, y: -8, width: bounds.width * 0.4, height: 18)
        tape.path = CGPath(rect: tapeRect, transform: nil)
        tape.fillColor = DrawingColor(red: 1, green: 1, blue: 1, alpha: 0.55).cgColor
        tape.strokeColor = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0.06).cgColor
        note.addSublayer(tape)
        if let lines = json["lines"]?.arrayValue?.compactMap(\.stringValue), !lines.isEmpty {
            let size = u(json["size"]?.doubleValue ?? 22)
            let lineHeight = u(json["lh"]?.doubleValue ?? (json["size"]?.doubleValue ?? 22) * 1.25)
            let ascent = DrawingFonts.ascent(.hand, size: size), descent = DrawingFonts.descent(.hand, size: size)
            let top = (bounds.height - CGFloat(lines.count) * lineHeight) / 2
            let path = CGMutablePath()
            for (index, line) in lines.enumerated() {
                let width = CGFloat(DrawingFonts.width(of: line, size: Double(size), style: .hand))
                let baseline = top + CGFloat(index) * lineHeight + (lineHeight - (ascent + descent)) / 2 + ascent
                path.addPath(DrawingFonts.glyphPath(line, style: .hand, size: size, origin: CGPoint(x: (bounds.width - width) / 2, y: baseline)).path)
            }
            let words = CAShapeLayer()
            words.name = "words"
            words.path = path
            words.fillColor = color(json["tone"], fallback: DrawingColor(hex: "#2A2C33")!)
            note.addSublayer(words)
        }
        let tilt = CGFloat((json["tilt"]?.doubleValue ?? -2) * .pi / 180)
        note.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        let drop = CABasicAnimation(keyPath: "transform.scale")
        drop.fromValue = 1.08
        drop.toValue = 1
        group([opacity, drop], on: note, key: "appear", begin: begin, duration: max(0.25, duration))
        container.addSublayer(note)
    }

    // MARK: Graph frame

    private func buildGraph(_ json: JSONValue, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        guard let grid = json["grid"]?.arrayValue, !grid.isEmpty else { return }
        let path = CGMutablePath()
        for seg in grid {
            guard let v = seg.arrayValue, v.count >= 4 else { continue }
            path.move(to: CGPoint(x: u(v[0].doubleValue), y: u(v[1].doubleValue)))
            path.addLine(to: CGPoint(x: u(v[2].doubleValue), y: u(v[3].doubleValue)))
        }
        let lines = CAShapeLayer()
        lines.name = "grid"
        lines.frame = layer.bounds
        lines.path = path
        lines.fillColor = nil
        lines.strokeColor = color(json["tone"], alpha: 0.28, fallback: DrawingColor(hex: "#7D828C")!)
        lines.lineWidth = 1
        fade(lines, begin: begin, duration: max(0.2, duration))
        container.addSublayer(lines)
    }

    // MARK: Animations (hidden before they begin, final values after)

    func pen(_ shape: CAShapeLayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.beginTime = begin
        a.duration = max(0.01, duration)
        a.fillMode = .backwards
        a.timingFunction = Self.penCurve
        shape.strokeEnd = 1
        shape.add(a, forKey: "pen")
    }

    func fade(_ target: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.beginTime = begin
        a.duration = max(0.01, duration)
        a.fillMode = .backwards
        a.timingFunction = Self.easeOut
        target.add(a, forKey: "fade")
    }

    func pop(_ target: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.2, 1.08, 1]
        scale.keyTimes = [0, 0.7, 1]
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = max(0.01, duration * 0.4)
        group([scale, opacity], on: target, key: "pop", begin: begin, duration: duration)
    }

    func swipe(_ target: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 0
        a.toValue = 1
        a.beginTime = begin
        a.duration = max(0.01, duration)
        a.fillMode = .backwards
        a.timingFunction = Self.easeOut
        target.add(a, forKey: "swipe")
    }

    func grow(_ target: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.04
        scale.toValue = 1
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = max(0.01, duration * 0.3)
        group([scale, opacity], on: target, key: "grow", begin: begin, duration: duration)
    }

    private func group(_ animations: [CAAnimation], on target: CALayer, key: String, begin: CFTimeInterval, duration: CFTimeInterval) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.beginTime = begin
        group.duration = max(0.01, duration)
        group.fillMode = .backwards
        for animation in animations where animation.duration == 0 { animation.duration = group.duration }
        target.add(group, forKey: key)
    }
}
