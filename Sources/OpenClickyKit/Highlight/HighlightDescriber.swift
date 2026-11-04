import CoreGraphics
import Foundation

/// What the user marked while asking, in words for the brain (`TurnContext.highlightDescription`), with the text
/// and controls under each mark.
public struct HighlightDescription: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public var mark: HighlightMark
        public var harvest: HighlightHarvest
        /// The screenshot's label ("main display", "display 2 (left)") when the mark is on one.
        public var screenLabel: String?
        /// The mark's region in that screenshot's pixels (top-left origin).
        public var pixelRegion: CGRect?
        /// Where it is on the display, in words ("top right").
        public var place: String?
        public var startPlace: String?

        public init(mark: HighlightMark, harvest: HighlightHarvest, screenLabel: String? = nil, pixelRegion: CGRect? = nil,
                    place: String? = nil, startPlace: String? = nil) {
            self.mark = mark
            self.harvest = harvest
            self.screenLabel = screenLabel
            self.pixelRegion = pixelRegion
            self.place = place
            self.startPlace = startPlace
        }
    }

    public var items: [Item]
    /// True when the ink was also drawn into the screenshots sent with the turn.
    public var inkInScreenshots: Bool
    public var text: String

    public init(items: [Item], inkInScreenshots: Bool) {
        self.items = items
        self.inkInScreenshots = inkInScreenshots
        self.text = HighlightDescriber.text(items, inkInScreenshots: inkInScreenshots)
    }
}

public enum HighlightDescriber {
    /// Where a point sits on a display, in words: "top left", "top", "middle", "bottom right", …
    public static func place(of pixel: CGPoint, width: Int, height: Int) -> String {
        let fx = pixel.x / CGFloat(max(1, width)), fy = pixel.y / CGFloat(max(1, height))
        let column = fx < 1.0 / 3 ? "left" : fx > 2.0 / 3 ? "right" : nil
        let row = fy < 1.0 / 3 ? "top" : fy > 2.0 / 3 ? "bottom" : nil
        switch (row, column) {
        case (nil, nil): return "middle"
        case (let r?, nil): return r
        case (nil, let c?): return c
        case (let r?, let c?): return "\(r) \(c)"
        }
    }

    static func box(_ rect: CGRect) -> String {
        "[" + [rect.minX, rect.minY, rect.width, rect.height].map { String(Int($0.rounded())) }.joined(separator: ", ") + "]"
    }

    static func quote(_ text: String, max: Int = 160) -> String {
        let one = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let cut = one.count > max ? String(one.prefix(max - 1)) + "…" : one
        return "\"" + cut.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    /// One sentence per mark plus what was found under it, written for the brain.
    public static func text(_ items: [HighlightDescription.Item], inkInScreenshots: Bool) -> String {
        guard !items.isEmpty else { return "" }
        var out = ["While asking, the user marked the screen with the highlighter. Take it as what they mean by \"this\", \"that\" or \"here\"."]
        let several = items.count > 1
        if several { out.append("They made \(items.count) marks, in this order:") }
        for (index, item) in items.enumerated() {
            var sentence = several ? "\(index + 1). " : ""
            let on = item.screenLabel.map { " of the \($0)" } ?? ""
            let at = item.place.map { "at the \($0)\(on)" } ?? "on the screen"
            switch item.mark.kind {
            case .circle: sentence += "They circled an area \(at)"
            case .underline: sentence += "They underlined something \(at)"
            case .scribble: sentence += "They scribbled over an area \(at)"
            case .line:
                let from = item.startPlace.map { "the \($0)" } ?? "one spot"
                let to = item.place.map { "the \($0)\(on)" } ?? "another"
                sentence += "They drew a line from \(from) toward \(to)"
            }
            if let pixels = item.pixelRegion { sentence += " (screenshot box \(box(pixels)))" }
            if item.mark.dwellSeconds >= 0.35 { sentence += String(format: ", pausing there about %.1f s", item.mark.dwellSeconds) }
            sentence += "."
            out.append(sentence)
            let lines = item.harvest.lines.prefix(8).map { quote($0.text) }
            if !lines.isEmpty {
                let source = item.harvest.lines.allSatisfy { $0.source == .ocr } ? " (read from the screenshot)" : ""
                out.append("   Text there\(source): " + lines.joined(separator: " / "))
            }
            let controls = item.harvest.controls.prefix(6).map { control -> String in
                var words = control.kind
                if let label = control.label { words += " " + quote(label, max: 60) }
                if let value = control.value { words += " (value " + quote(value, max: 60) + ")" }
                if let url = control.url { words += " (links to \(url.prefix(200)))" }
                return words
            }
            if !controls.isEmpty { out.append("   Controls there: " + controls.joined(separator: "; ")) }
        }
        if items.contains(where: { !$0.harvest.isEmpty }) { out.append("Use those exact words and links when you refer to them.") }
        if inkInScreenshots { out.append("The yellow highlighter strokes in the screenshot are the user's marks, not part of the app.") }
        return out.joined(separator: "\n")
    }
}

/// Draw-to-ask from key-down to the turn: record the strokes while the talk key is held, then describe them against
/// the turn's screenshots and attach the result to that turn.
///
///     drawToAsk.keyDown(at: NSEvent.mouseLocation, time: now)       // with the talk key
///     drawToAsk.pointerMoved(to: NSEvent.mouseLocation, time: now)  // ~60 Hz while held; ink.update(drawToAsk.liveStrokes)
///     drawToAsk.keyUp(time: now)                                    // ink.fadeOut()
///     var input = TurnInput(words: transcript, screenshots: look.screenshots, context: look.turnContext())
///     await drawToAsk.attach(to: &input, layout: look.layout)       // highlightDescription + inked screenshots
@MainActor
public final class DrawToAskSession {
    public private(set) var recorder: HighlightRecorder
    public var harvester: HighlightHarvester
    public var inkStyle: HighlightInkStyle
    /// Draw the ink into the turn's screenshots (the overlay itself is left out of captures).
    public var inkScreenshots = true
    /// The finished gesture waiting for the turn it belongs to.
    public private(set) var pending: HighlightGesture?
    private var pendingAt: TimeInterval = 0

    public init(settings: HighlightRecorder.Settings = .init(), harvester: HighlightHarvester = .live, inkStyle: HighlightInkStyle = .init()) {
        self.recorder = HighlightRecorder(settings: settings)
        self.harvester = harvester
        self.inkStyle = inkStyle
    }

    public func keyDown(at point: CGPoint, time: TimeInterval) {
        pending = nil
        recorder.begin(at: point, time: time)
    }

    /// A pointer sample while the key is held. Returns true when the ink changed.
    @discardableResult
    public func pointerMoved(to point: CGPoint, time: TimeInterval) -> Bool { recorder.move(to: point, time: time) }

    /// The pointer stayed still (lets long pauses end a stroke).
    public func pointerIdle(time: TimeInterval) { recorder.idle(at: time) }

    public var liveStrokes: [[CGPoint]] { recorder.liveStrokes }

    /// The key went up. Returns the gesture (also kept as `pending` for the turn), or nil when nothing was drawn.
    @discardableResult
    public func keyUp(time: TimeInterval) -> HighlightGesture? {
        pending = recorder.end(at: time)
        pendingAt = time
        return pending
    }

    /// A finished gesture recorded elsewhere (`HighlightSimulator`, `occtl turn --highlight`), kept for the next turn
    /// as if the key had just gone up with it.
    public func adopt(_ gesture: HighlightGesture, time: TimeInterval) {
        pending = gesture
        pendingAt = time
    }

    /// The press was cancelled (a tap, no transcript): forget the marks.
    public func cancel() {
        _ = recorder.end(at: 0)
        pending = nil
    }

    /// Describe the pending gesture for this turn and put it on the turn: `context.highlightDescription`, and the
    /// ink drawn into the matching screenshots. Consumes the gesture; returns the description (nil when none).
    @discardableResult
    public func attach(to input: inout TurnInput, layout: DesktopLayout, maximumAge: TimeInterval = 120, now: TimeInterval? = nil) async -> HighlightDescription? {
        guard let gesture = pending else { return nil }
        pending = nil
        if let now, now - pendingAt > maximumAge { return nil }
        let result = await Self.describe(gesture, screenshots: input.screenshots, layout: layout, harvester: harvester,
                                         inkScreenshots: inkScreenshots, style: inkStyle)
        input.context.highlightDescription = result.description.text
        input.screenshots = result.screenshots
        return result.description
    }

    /// Classify each stroke, find its screenshot, read what is under it, and word it. With `inkScreenshots`, the
    /// returned screenshots carry the ink (JPEG); otherwise they are the ones given.
    public nonisolated static func describe(_ gesture: HighlightGesture, screenshots: [TurnScreenshot], layout: DesktopLayout,
                                            harvester: HighlightHarvester, inkScreenshots: Bool = true,
                                            style: HighlightInkStyle = HighlightInkStyle()) async -> (description: HighlightDescription, screenshots: [TurnScreenshot]) {
        let geometries = screenshots.map { CaptureGeometry(turnScreenshot: $0, layout: layout) }
        var decoded: [Int: DrawingMediaImage] = [:]
        func image(_ index: Int) -> DrawingMediaImage? {
            if let done = decoded[index] { return done }
            let made = DrawingMediaImage(encoded: screenshots[index].jpeg)
            decoded[index] = made
            return made
        }
        func screen(for point: CGPoint) -> Int? {
            geometries.firstIndex { $0.displayFrame.insetBy(dx: -1, dy: -1).contains(point) }
        }
        // One time budget for the whole turn, however many marks it has.
        let deadlines = harvester.deadlines()
        var items: [HighlightDescription.Item] = []
        for mark in HighlightClassifier.marks(gesture) {
            var item = HighlightDescription.Item(mark: mark, harvest: HighlightHarvest())
            let index = screen(for: mark.focus) ?? screen(for: CGPoint(x: mark.region.midX, y: mark.region.midY))
            if let index {
                let g = geometries[index]
                item.screenLabel = screenshots.count > 1 ? screenshots[index].label : nil
                if let visible = g.visiblePixelRect(g.pixelRect(fromAppKitRect: mark.region)) {
                    item.pixelRegion = visible
                    item.place = HighlightDescriber.place(of: CGPoint(x: visible.midX, y: visible.midY), width: g.pixelWidth, height: g.pixelHeight)
                }
                if mark.kind == .line, let start = g.pixel(fromAppKit: mark.start) {
                    item.startPlace = HighlightDescriber.place(of: start, width: g.pixelWidth, height: g.pixelHeight)
                }
                item.harvest = await harvester.harvest(region: mark.region, layout: layout, screenshot: image(index), geometry: g, deadlines: deadlines)
            } else {
                item.harvest = await harvester.harvest(region: mark.region, layout: layout, deadlines: deadlines)
            }
            items.append(item)
        }
        var shots = screenshots
        var inked = false
        if inkScreenshots {
            for (index, g) in geometries.enumerated() where gesture.strokes.contains(where: { $0.points.contains { g.displayFrame.contains($0) } }) {
                guard let original = image(index), let marked = HighlightInk.composite(gesture, onto: original.image, geometry: g, style: style),
                      let jpeg = try? ImageCoding.jpegData(marked, quality: 0.8) else { continue }
                shots[index].jpeg = jpeg
                inked = true
            }
        }
        return (HighlightDescription(items: items, inkInScreenshots: inked), shots)
    }
}
