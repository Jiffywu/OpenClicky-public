import CoreGraphics
import Foundation
import QuartzCore

/// Media cards (docs/dsl-media.md): a photo print, a place card with a small map, a stock card with a sparkline, and
/// a site icon. Each is drawn in its `state` ("loading", "ready", "failed"); when the host's answer arrives the mark
/// comes back with `edit: "patch"` and is rebuilt in place: the card stays put and only the new content fades in.
extension DrawingPainter {
    static let mediaInk = DrawingColor(hex: "#25272D")!
    static let mediaGrey = DrawingColor(hex: "#6E737D")!
    static let mediaPaper = DrawingColor(hex: "#FFFFFF")!
    static let mediaWell = DrawingColor(hex: "#E8E6E1")!
    static let rising = DrawingColor(hex: "#1E9E57")!
    static let falling = DrawingColor(hex: "#D8434B")!

    func buildMedia(_ json: JSONValue, kind: String, in container: CALayer, begin: CFTimeInterval, duration: CFTimeInterval) {
        let frame = rect(json)
        guard frame.width >= 1, frame.height >= 1 else { return }
        // A patch of a card already on screen keeps the card still and fades in what arrived.
        let entering = json["edit"]?.stringValue != "patch" || begin > now() + 0.001
        let card: CALayer
        switch kind {
        case "photo": card = photoCard(json, frame: frame, begin: begin, duration: duration, entering: entering)
        case "place": card = placeCard(json, frame: frame, begin: begin, duration: duration, entering: entering)
        case "stock": card = stockCard(json, frame: frame, begin: begin, duration: duration, entering: entering)
        case "image": card = plainImage(json, frame: frame, begin: begin, duration: duration, entering: entering)
        default: card = faviconTile(json, frame: frame, begin: begin, duration: duration, entering: entering)
        }
        card.name = kind
        if entering {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0
            opacity.toValue = 1
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 0.94
            settle.toValue = 1
            let both = CAAnimationGroup()
            both.animations = [opacity, settle]
            both.beginTime = begin
            both.duration = max(0.2, duration)
            both.fillMode = .backwards
            both.timingFunction = Self.easeOut
            opacity.duration = both.duration
            settle.duration = both.duration
            card.add(both, forKey: "appear")
        }
        container.addSublayer(card)
    }

    // MARK: Photo

    private func photoCard(_ json: JSONValue, frame: CGRect, begin: CFTimeInterval, duration: CFTimeInterval, entering: Bool) -> CALayer {
        let print = cardLayer(frame: frame, radius: 3, color: DrawingColor(hex: "#FCFBF8")!, shadow: 0.26)
        let bounds = print.bounds
        let pad = max(5, min(bounds.width, bounds.height) * 0.045)
        let caption = json["caption"]?.stringValue ?? ""
        let subtitle = json["subtitle"]?.stringValue ?? ""
        let captionHeight: CGFloat = caption.isEmpty && subtitle.isEmpty ? pad * 2.2 : max(24, min(bounds.height * 0.17, 40))
        let well = CGRect(x: pad, y: pad, width: bounds.width - 2 * pad, height: max(10, bounds.height - pad - captionHeight))
        let state = json["state"]?.stringValue ?? "loading"
        let image = json["image"]?.stringValue.flatMap { media?.image($0) }

        let picture = CALayer()
        picture.name = "picture"
        picture.frame = well
        picture.masksToBounds = true
        picture.backgroundColor = Self.mediaWell.cgColor
        if let image {
            let shown = CALayer()
            shown.name = "image"
            shown.frame = picture.bounds
            shown.contents = image
            shown.contentsGravity = .resizeAspectFill
            picture.addSublayer(shown)
            if !entering { fade(shown, begin: begin, duration: max(0.3, duration)) }
        } else {
            let note = state == "failed" ? "no photo found" : "finding a photo…"
            picture.addSublayer(words(note, style: .ui, size: min(12, well.height * 0.14), color: Self.mediaGrey, in: picture.bounds, align: .center))
        }
        print.addSublayer(picture)

        let captionBox = CGRect(x: pad, y: well.maxY, width: well.width, height: bounds.height - well.maxY)
        if !caption.isEmpty {
            let size = min(captionBox.height * (subtitle.isEmpty ? 0.62 : 0.5), 22)
            var line = captionBox
            if !subtitle.isEmpty { line.size.height *= 0.62 }
            print.addSublayer(words(caption, style: .hand, size: size, color: Self.mediaInk, in: line, align: .center))
        }
        if !subtitle.isEmpty {
            let line = CGRect(x: captionBox.minX, y: captionBox.minY + (caption.isEmpty ? 0 : captionBox.height * 0.52),
                              width: captionBox.width, height: captionBox.height * (caption.isEmpty ? 1 : 0.42))
            print.addSublayer(words(subtitle, style: .ui, size: min(line.height * 0.6, 11), color: Self.mediaGrey, in: line, align: .center))
        }
        // Where the photo came from, small, under the print: public pictures carry their credit.
        if state == "ready", let source = json["source"]?.stringValue, frame.width >= 140 {
            let credit = [json["license"]?.stringValue, source].compactMap { $0 }.joined(separator: " · ")
            let line = CGRect(x: 0, y: bounds.height + 2, width: bounds.width, height: 12)
            let creditLayer = words(credit, style: .ui, size: 8.5, color: Self.mediaGrey.withAlpha(0.85), in: line, align: .right)
            creditLayer.name = "credit"
            if !entering { fade(creditLayer, begin: begin, duration: max(0.3, duration)) }
            print.addSublayer(creditLayer)
        }
        // A strip of tape holding the print to the screen.
        let tape = CAShapeLayer()
        tape.name = "tape"
        let tapeSize = CGSize(width: min(70, bounds.width * 0.3), height: min(16, bounds.height * 0.09))
        tape.frame = CGRect(x: bounds.midX - tapeSize.width / 2, y: -tapeSize.height * 0.45, width: tapeSize.width, height: tapeSize.height)
        tape.path = CGPath(rect: tape.bounds, transform: nil)
        tape.fillColor = DrawingColor(hex: "#EFE3BF")!.withAlpha(0.78).cgColor
        tape.setAffineTransform(CGAffineTransform(rotationAngle: 0.05))
        print.addSublayer(tape)

        let tilt = CGFloat(json["tilt"]?.doubleValue ?? -2) * .pi / 180
        print.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        return print
    }

    // MARK: Place

    private func placeCard(_ json: JSONValue, frame: CGRect, begin: CFTimeInterval, duration: CFTimeInterval, entering: Bool) -> CALayer {
        let card = cardLayer(frame: frame, radius: 12, color: Self.mediaPaper, shadow: 0.22)
        let bounds = card.bounds
        let inner = CALayer()
        inner.frame = bounds
        inner.cornerRadius = 12
        inner.masksToBounds = true
        card.addSublayer(inner)
        let state = json["state"]?.stringValue ?? "loading"
        // The words need about 80 points; the map takes the rest (at least half the card).
        let mapBox = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height * 0.5, bounds.height - 84))

        let map = CALayer()
        map.name = "map"
        map.frame = mapBox
        map.masksToBounds = true
        drawMapPlaceholder(in: map)
        if let key = json["map"]?.stringValue, let image = media?.image(key) {
            let shown = CALayer()
            shown.name = "image"
            shown.frame = map.bounds
            shown.contents = image
            shown.contentsGravity = .resizeAspectFill
            map.addSublayer(shown)
            if !entering { fade(shown, begin: begin, duration: max(0.3, duration)) }
        }
        inner.addSublayer(map)
        if state == "ready" {
            let pin = pinLayer(at: CGPoint(x: mapBox.midX, y: mapBox.midY), size: min(30, mapBox.height * 0.3))
            if !entering { pop(pin, begin: begin + 0.1, duration: 0.3) }
            inner.addSublayer(pin)
        }

        let pad: CGFloat = 12
        let textBox = CGRect(x: pad, y: mapBox.maxY + 8, width: bounds.width - 2 * pad, height: bounds.height - mapBox.maxY - 14)
        let query = json["query"]?.stringValue ?? ""
        let title: String, detail: String
        switch state {
        case "ready":
            title = json["title"]?.stringValue ?? query
            detail = [json["category"]?.stringValue, json["address"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
        case "failed":
            title = query
            detail = "couldn't find this place"
        default:
            title = query
            detail = "looking it up…"
        }
        let titleSize = min(16, max(11, textBox.height * 0.3))
        let titleLayer = words(title, style: .bold, size: titleSize, color: Self.mediaInk,
                               in: CGRect(x: textBox.minX, y: textBox.minY, width: textBox.width, height: titleSize * 1.35), align: .left)
        let detailSize = min(12, max(9, textBox.height * 0.2))
        let detailLayer = words(detail, style: .ui, size: detailSize, color: Self.mediaGrey,
                                in: CGRect(x: textBox.minX, y: textBox.minY + titleSize * 1.4, width: textBox.width,
                                           height: max(detailSize * 1.3, textBox.height - titleSize * 1.4)),
                                align: .left, maxLines: 2, top: true)
        if !entering { fade(titleLayer, begin: begin, duration: 0.3); fade(detailLayer, begin: begin, duration: 0.35) }
        card.addSublayer(titleLayer)
        card.addSublayer(detailLayer)
        return card
    }

    private func drawMapPlaceholder(in map: CALayer) {
        map.backgroundColor = DrawingColor(hex: "#EDEAE0")!.cgColor
        let roads = CAShapeLayer()
        roads.frame = map.bounds
        let path = CGMutablePath()
        let b = map.bounds
        // A few quiet streets, the same every time.
        for (x0, y0, x1, y1) in [(0.0, 0.32, 1.0, 0.24), (0.0, 0.74, 1.0, 0.82), (0.28, 0.0, 0.36, 1.0), (0.7, 0.0, 0.62, 1.0)] {
            path.move(to: CGPoint(x: b.width * x0, y: b.height * y0))
            path.addLine(to: CGPoint(x: b.width * x1, y: b.height * y1))
        }
        roads.path = path
        roads.strokeColor = DrawingColor.white.cgColor
        roads.lineWidth = max(3, b.height * 0.05)
        roads.fillColor = nil
        map.addSublayer(roads)
    }

    private func pinLayer(at point: CGPoint, size: CGFloat) -> CALayer {
        let pin = CAShapeLayer()
        pin.name = "pin"
        let w = size * 0.72
        pin.bounds = CGRect(x: 0, y: 0, width: w, height: size)
        pin.anchorPoint = CGPoint(x: 0.5, y: 1)
        pin.position = point
        let path = CGMutablePath()
        let r = w / 2
        // A round head over a point (y down: the tip is at the bottom).
        path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .pi * 0.8, endAngle: .pi * 0.2, clockwise: false)
        path.addLine(to: CGPoint(x: r, y: size))
        path.closeSubpath()
        pin.path = path
        pin.fillColor = DrawingColor(hex: "#E5484D")!.cgColor
        pin.strokeColor = DrawingColor.white.cgColor
        pin.lineWidth = 1.5
        pin.shadowOpacity = 0.3
        pin.shadowRadius = 2
        pin.shadowOffset = CGSize(width: 0, height: 1)
        let dot = CAShapeLayer()
        dot.frame = pin.bounds
        dot.path = CGPath(ellipseIn: CGRect(x: r - r * 0.38, y: r - r * 0.38, width: r * 0.76, height: r * 0.76), transform: nil)
        dot.fillColor = DrawingColor.white.cgColor
        pin.addSublayer(dot)
        return pin
    }

    // MARK: Stock

    private func stockCard(_ json: JSONValue, frame: CGRect, begin: CFTimeInterval, duration: CFTimeInterval, entering: Bool) -> CALayer {
        let card = cardLayer(frame: frame, radius: 12, color: Self.mediaPaper, shadow: 0.22)
        let bounds = card.bounds
        let pad = max(10, min(16, bounds.width * 0.05))
        let state = json["state"]?.stringValue ?? "loading"
        let symbol = json["symbol"]?.stringValue ?? ""
        let range = (json["range"]?.stringValue ?? "1d").uppercased()
        var parts: [CALayer] = []

        let headSize = min(15, max(11, bounds.height * 0.12))
        parts.append(words(symbol, style: .bold, size: headSize, color: Self.mediaInk,
                           in: CGRect(x: pad, y: pad, width: bounds.width * 0.4, height: headSize * 1.3), align: .left))
        parts.append(words(range, style: .bold, size: headSize * 0.78, color: Self.mediaGrey,
                           in: CGRect(x: bounds.width - pad - 50, y: pad, width: 50, height: headSize * 1.3), align: .right))
        guard state == "ready", let price = json["price"]?.doubleValue else {
            let note = state == "failed" ? "no quote available" : "getting a quote…"
            parts.append(words(note, style: .ui, size: min(12, headSize * 0.9), color: Self.mediaGrey,
                               in: CGRect(x: pad, y: bounds.midY - 10, width: bounds.width - 2 * pad, height: 20), align: .left))
            parts.forEach(card.addSublayer)
            return card
        }
        if let name = json["company"]?.stringValue {
            parts.append(words(name, style: .ui, size: headSize * 0.78, color: Self.mediaGrey,
                               in: CGRect(x: pad, y: pad + headSize * 1.3, width: bounds.width - 2 * pad, height: headSize * 1.1), align: .left))
        }
        let currency = json["currency"]?.stringValue
        let priceSize = min(30, max(16, bounds.height * 0.22))
        let priceTop = pad + headSize * 2.5
        let priceText = Self.money(price, currency: currency)
        parts.append(words(priceText, style: .bold, size: priceSize, color: Self.mediaInk,
                           in: CGRect(x: pad, y: priceTop, width: bounds.width * 0.62, height: priceSize * 1.25), align: .left))
        let change = json["change"]?.doubleValue
        let percent = json["changePercent"]?.doubleValue
        let up = (change ?? percent ?? 0) >= 0
        let tone = up ? Self.rising : Self.falling
        if change != nil || percent != nil {
            var text = up ? "▲ " : "▼ "
            if let change { text += String(format: "%.2f", abs(change)) }
            if let percent { text += change == nil ? String(format: "%.2f%%", abs(percent)) : String(format: " (%.2f%%)", abs(percent)) }
            parts.append(words(text, style: .bold, size: priceSize * 0.5, color: tone,
                               in: CGRect(x: bounds.width * 0.55, y: priceTop + priceSize * 0.3, width: bounds.width * 0.45 - pad, height: priceSize),
                               align: .right))
        }
        let closes = (json["closes"]?.arrayValue ?? []).compactMap(\.doubleValue).filter(\.isFinite)
        let chart = CGRect(x: pad, y: priceTop + priceSize * 1.35, width: bounds.width - 2 * pad, height: bounds.height - priceTop - priceSize * 1.35 - pad)
        if closes.count >= 2, chart.height >= 12 {
            let basis = json["basis"]?.doubleValue
            let line = Self.sparkline(closes, basis: basis, in: chart)
            let fill = CAShapeLayer()
            fill.name = "area"
            fill.frame = bounds
            fill.path = line.area
            fill.fillColor = tone.withAlpha(0.1).cgColor
            let stroke = CAShapeLayer()
            stroke.name = "sparkline"
            stroke.frame = bounds
            stroke.path = line.path
            stroke.strokeColor = tone.cgColor
            stroke.fillColor = nil
            stroke.lineWidth = 2
            stroke.lineJoin = .round
            stroke.lineCap = .round
            if let baseline = line.baseline {
                let dash = CAShapeLayer()
                dash.name = "basis"
                dash.frame = bounds
                dash.path = baseline
                dash.strokeColor = Self.mediaGrey.withAlpha(0.6).cgColor
                dash.lineWidth = 1
                dash.lineDashPattern = [3, 3]
                parts.append(dash)
            }
            parts.append(fill)
            parts.append(stroke)
            pen(stroke, begin: entering ? begin + duration * 0.4 : begin, duration: max(0.4, duration))
            fade(fill, begin: (entering ? begin + duration * 0.4 : begin) + 0.2, duration: 0.4)
        }
        for part in parts where !entering && part.name != "sparkline" && part.name != "area" { fade(part, begin: begin, duration: 0.3) }
        parts.forEach(card.addSublayer)
        return card
    }

    /// The price line through `closes` scaled into `box` (y down), the area under it, and the dashed basis line.
    nonisolated static func sparkline(_ closes: [Double], basis: Double?, in box: CGRect) -> (path: CGPath, area: CGPath, baseline: CGPath?) {
        var low = closes.min() ?? 0, high = closes.max() ?? 1
        if let basis, basis.isFinite { low = min(low, basis); high = max(high, basis) }
        if high - low < 1e-9 { high += 1; low -= 1 }
        let pad = (high - low) * 0.08
        low -= pad; high += pad
        func y(_ v: Double) -> CGFloat { box.maxY - CGFloat((v - low) / (high - low)) * box.height }
        let step = box.width / CGFloat(max(1, closes.count - 1))
        let path = CGMutablePath()
        for (i, v) in closes.enumerated() {
            let p = CGPoint(x: box.minX + CGFloat(i) * step, y: y(v))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        let area = CGMutablePath()
        area.addPath(path)
        area.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        area.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        area.closeSubpath()
        var baseline: CGPath?
        if let basis, basis.isFinite {
            let line = CGMutablePath()
            line.move(to: CGPoint(x: box.minX, y: y(basis)))
            line.addLine(to: CGPoint(x: box.maxX, y: y(basis)))
            baseline = line
        }
        return (path, area, baseline)
    }

    nonisolated static func money(_ value: Double, currency: String?) -> String {
        let digits = abs(value) >= 1000 ? 0 : 2
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.locale = Locale(identifier: "en_US")
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        switch currency?.uppercased() {
        case nil, "USD": return "$" + number
        case "EUR": return "€" + number
        case "GBP": return "£" + number
        case "JPY": return "¥" + number
        case let code?: return number + " " + code
        }
    }

    // MARK: Image

    /// `image()`: the picture itself in rounded corners, cropped to fill its box; a grey well while it loads.
    private func plainImage(_ json: JSONValue, frame: CGRect, begin: CFTimeInterval, duration: CFTimeInterval, entering: Bool) -> CALayer {
        let radius = CGFloat(json["radius"]?.doubleValue ?? 8)
        let tile = cardLayer(frame: frame, radius: radius, color: Self.mediaWell, shadow: 0.18)
        let well = CALayer()
        well.name = "picture"
        well.frame = tile.bounds
        well.cornerRadius = radius
        well.masksToBounds = true
        if let key = json["image"]?.stringValue, let image = media?.image(key) {
            let shown = CALayer()
            shown.name = "image"
            shown.frame = well.bounds
            shown.contents = image
            shown.contentsGravity = .resizeAspectFill
            well.addSublayer(shown)
            if !entering { fade(shown, begin: begin, duration: max(0.3, duration)) }
        } else {
            let note = json["state"]?.stringValue == "failed" ? "image unavailable" : "loading image…"
            well.addSublayer(words(note, style: .ui, size: min(12, frame.height * 0.14), color: Self.mediaGrey, in: well.bounds, align: .center))
        }
        tile.addSublayer(well)
        return tile
    }

    // MARK: Favicon

    private func faviconTile(_ json: JSONValue, frame: CGRect, begin: CFTimeInterval, duration: CFTimeInterval, entering: Bool) -> CALayer {
        let tile = CALayer()
        tile.frame = frame
        tile.cornerRadius = min(frame.width, frame.height) * 0.22
        tile.masksToBounds = true
        if let key = json["image"]?.stringValue, let image = media?.image(key) {
            tile.contents = image
            tile.contentsGravity = .resizeAspect
            if !entering { fade(tile, begin: begin, duration: max(0.25, duration)) }
        } else {
            tile.backgroundColor = Self.mediaWell.withAlpha(json["state"]?.stringValue == "failed" ? 0.5 : 0.9).cgColor
        }
        return tile
    }

    // MARK: Shared pieces

    private func cardLayer(frame: CGRect, radius: CGFloat, color: DrawingColor, shadow: Float) -> CALayer {
        let card = CALayer()
        card.frame = frame
        card.backgroundColor = color.cgColor
        card.cornerRadius = radius
        card.borderColor = DrawingColor(red: 0, green: 0, blue: 0, alpha: 0.08).cgColor
        card.borderWidth = 0.5
        card.shadowColor = CGColor(srgbRed: 0.1, green: 0.11, blue: 0.13, alpha: 1)
        card.shadowOpacity = shadow
        card.shadowRadius = 10
        card.shadowOffset = CGSize(width: 0, height: 4)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        return card
    }

    enum MediaAlign { case left, center, right }

    /// Words set with Core Text inside `box` (y down), shortened with "…" to fit; `maxLines` wraps at word breaks.
    func words(_ text: String, style: DrawingTextStyle, size: CGFloat, color: DrawingColor, in box: CGRect, align: MediaAlign,
               maxLines: Int = 1, top alignTop: Bool = false) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = CGRect(x: 0, y: 0, width: max(box.maxX, 1), height: max(box.maxY, 1))
        layer.fillColor = color.cgColor
        let size = max(4, size)
        let lineHeight = size * 1.28
        let lines = Self.wrap(text, style: style, size: size, width: box.width, maxLines: max(1, maxLines))
        let ascent = DrawingFonts.ascent(style, size: size), descent = DrawingFonts.descent(style, size: size)
        let total = lineHeight * CGFloat(lines.count)
        let path = CGMutablePath()
        for (i, line) in lines.enumerated() {
            let width = CGFloat(DrawingFonts.width(of: line, size: Double(size), style: style))
            let x: CGFloat = switch align {
            case .left: box.minX
            case .center: box.midX - width / 2
            case .right: box.maxX - width
            }
            let top = box.minY + (alignTop ? 0 : max(0, (box.height - total) / 2)) + CGFloat(i) * lineHeight
            let baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent
            path.addPath(DrawingFonts.glyphPath(line, style: style, size: size, origin: CGPoint(x: x, y: baseline)).path)
        }
        layer.path = path
        return layer
    }

    /// Lines of at most `width` points, the last one ending in "…" when the text doesn't fit.
    nonisolated static func wrap(_ text: String, style: DrawingTextStyle, size: CGFloat, width: CGFloat, maxLines: Int) -> [String] {
        func fits(_ s: String) -> Bool { CGFloat(DrawingFonts.width(of: s, size: Double(size), style: style)) <= width }
        let wordsIn = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var current = ""
        var index = 0
        while index < wordsIn.count {
            let candidate = current.isEmpty ? wordsIn[index] : current + " " + wordsIn[index]
            if fits(candidate) || current.isEmpty && lines.count == maxLines - 1 {
                current = candidate
                index += 1
            } else if current.isEmpty {
                current = wordsIn[index]
                index += 1
            } else {
                lines.append(current)
                current = ""
                if lines.count == maxLines { break }
            }
        }
        if !current.isEmpty, lines.count < maxLines { lines.append(current) }
        let cut = index < wordsIn.count
        guard var last = lines.popLast() else { return [] }
        if cut || !fits(last) {
            while !last.isEmpty, !fits(last + "…") { last.removeLast() }
            last = last.trimmingCharacters(in: .whitespaces) + "…"
        }
        lines.append(last)
        return lines
    }
}
