import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OpenClickyKit

// Draw-to-ask: recording the gesture, telling marks apart, region math, reading what is under a mark (a fake
// Accessibility tree and real on-device OCR), the description and the inked screenshot.

/// Pointer samples along a path at 60 Hz (AppKit global points), starting at time `t0`.
private func samples(_ points: [CGPoint], t0: TimeInterval = 0) -> [(CGPoint, TimeInterval)] {
    points.enumerated().map { ($0.element, t0 + Double($0.offset) / 60) }
}

private func circlePoints(center: CGPoint, rx: CGFloat, ry: CGFloat, turns: CGFloat = 1.1, count: Int = 90) -> [CGPoint] {
    (0...count).map { i in
        let a = CGFloat(i) / CGFloat(count) * turns * 2 * .pi + 0.4
        return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
    }
}

private func linePoints(from a: CGPoint, to b: CGPoint, count: Int = 30, wobble: CGFloat = 0) -> [CGPoint] {
    (0...count).map { i in
        let t = CGFloat(i) / CGFloat(count)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + (i % 2 == 0 ? wobble : -wobble))
    }
}

private func stroke(_ points: [CGPoint]) -> HighlightStroke {
    HighlightStroke(points: points, times: points.indices.map { Double($0) / 60 })
}

private func record(_ paths: [[CGPoint]], pauseBetween: TimeInterval = 0) -> HighlightGesture? {
    var recorder = HighlightRecorder()
    let start = paths.first?.first ?? .zero
    recorder.begin(at: start, time: 0)
    var t: TimeInterval = 0
    for path in paths {
        for p in path {
            t += 1.0 / 60
            recorder.move(to: p, time: t)
        }
        if pauseBetween > 0 {
            t += pauseBetween
            recorder.idle(at: t)
        }
    }
    return recorder.end(at: t + 0.05)
}

/// A white "screen" with words drawn in black at given top-left pixel positions.
private func screenImage(width: Int = 1280, height: Int = 800, words: [(String, CGPoint, CGFloat)]) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (text, topLeft, size) in words {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: topLeft.x, y: CGFloat(height) - topLeft.y - CTFontGetAscent(font))
        CTLineDraw(line, context)
    }
    return context.makeImage()!
}

@Suite struct HighlightGestureTests {
    @Test func holdingStillDrawsNothingAndInkStartsAfterEightPoints() {
        var recorder = HighlightRecorder()
        recorder.begin(at: CGPoint(x: 100, y: 100), time: 0)
        let talking = recorder.move(to: CGPoint(x: 104, y: 103), time: 0.1)   // 5 pt: talking, not drawing
        #expect(!talking)
        #expect(recorder.liveStrokes.isEmpty)
        let drawing = recorder.move(to: CGPoint(x: 109, y: 100), time: 0.2)
        #expect(drawing)
        #expect(recorder.liveStrokes == [[CGPoint(x: 100, y: 100), CGPoint(x: 109, y: 100)]])
        let tooClose = recorder.move(to: CGPoint(x: 110, y: 100), time: 0.22)  // closer than 1.5 pt to the last point
        #expect(!tooClose)
        var still = HighlightRecorder()
        still.begin(at: .zero, time: 0)
        still.move(to: CGPoint(x: 3, y: 3), time: 1)
        let nothing = still.end(at: 2)
        #expect(nothing == nil)
    }

    @Test func aFastFlickIsTravelNotInk() throws {
        var recorder = HighlightRecorder()
        recorder.begin(at: CGPoint(x: 0, y: 0), time: 0)
        // 300 pt in 3 frames (6000 pt/s): moving to the thing, not marking it.
        for i in 1...3 { recorder.move(to: CGPoint(x: CGFloat(i) * 100, y: 0), time: Double(i) / 60) }
        #expect(recorder.liveStrokes.isEmpty)
        // Then a slow underline from where it stopped.
        for i in 1...20 { recorder.move(to: CGPoint(x: 300 + CGFloat(i) * 6, y: 0), time: 0.05 + Double(i) / 60) }
        let ended = recorder.end(at: 1)
        let stroke = try #require(ended?.strokes.first)
        #expect(stroke.points.first == CGPoint(x: 300, y: 0))
    }

    @Test func pausesBecomeDwellsAndLongOnesSplitMarks() throws {
        var recorder = HighlightRecorder()
        recorder.begin(at: CGPoint(x: 0, y: 0), time: 0)
        var t = 0.0
        for p in linePoints(from: .zero, to: CGPoint(x: 200, y: 0)) { t += 1.0 / 60; recorder.move(to: p, time: t) }
        // Rest near the end for 0.5 s (a dwell, not a break).
        for i in 0..<30 { t += 1.0 / 60; recorder.move(to: CGPoint(x: 200 + CGFloat(i % 3), y: 1), time: t) }
        for p in linePoints(from: CGPoint(x: 200, y: 0), to: CGPoint(x: 260, y: 0), count: 10) { t += 1.0 / 60; recorder.move(to: p, time: t) }
        // Then stop for a second: the mark ends.
        t += 1.0
        recorder.idle(at: t)
        for p in linePoints(from: CGPoint(x: 260, y: 0), to: CGPoint(x: 260, y: 200)) { t += 1.0 / 60; recorder.move(to: p, time: t) }
        let ended = recorder.end(at: t + 0.1)
        let gesture = try #require(ended)
        #expect(gesture.strokes.count == 2)
        let dwell = try #require(gesture.strokes[0].dwells.first)
        #expect(dwell.duration >= 0.45 && dwell.duration <= 0.7)   // the rest, plus arriving and leaving within the circle
        #expect(dwell.point.x >= 199 && dwell.point.x <= 202)
    }
}

@Suite struct HighlightRegionTests {
    @Test func aLoopIsACircleAndItsRegionIsInsideIt() {
        let mark = HighlightClassifier.classify(stroke(circlePoints(center: CGPoint(x: 400, y: 300), rx: 120, ry: 50)))
        #expect(mark.kind == .circle)
        #expect(abs(mark.region.midX - 400) < 8 && abs(mark.region.midY - 300) < 8)
        #expect(abs(mark.region.width - 248) < 10 && abs(mark.region.height - 108) < 10)
        // A loop that falls short (about 300°) still counts as circling.
        #expect(HighlightClassifier.classify(stroke(circlePoints(center: .zero, rx: 80, ry: 60, turns: 0.83))).kind == .circle)
    }

    @Test func aLevelStrokeUnderlinesTheWordsAboveIt() {
        let mark = HighlightClassifier.classify(stroke(linePoints(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 340, y: 504), wobble: 1.5)))
        #expect(mark.kind == .underline)
        // AppKit y grows upward: the region reaches 30 pt above the stroke and a little below it.
        #expect(abs(mark.region.minY - (498.5 - 6)) < 1.5)
        #expect(abs(mark.region.maxY - (505.5 + 30)) < 1.5)
        #expect(mark.region.minX <= 96.1 && mark.region.maxX >= 343.9)
    }

    @Test func aSlantedStrokePointsAtItsEnd() {
        let mark = HighlightClassifier.classify(stroke(linePoints(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 400))))
        #expect(mark.kind == .line)
        #expect(mark.focus == CGPoint(x: 500, y: 400))
        #expect(mark.region.contains(CGPoint(x: 500, y: 400)) && !mark.region.contains(CGPoint(x: 100, y: 100)))
        #expect(mark.region.size == HighlightClassifier.lineEndBox)
        // A short flick covers itself.
        let flick = HighlightClassifier.classify(stroke(linePoints(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 50))))
        #expect(flick.region.contains(CGPoint(x: 10, y: 10)) && flick.region.contains(CGPoint(x: 40, y: 50)))
    }

    @Test func backAndForthIsAScribble() {
        var zigzag: [CGPoint] = []
        for i in 0..<8 {
            zigzag += linePoints(from: CGPoint(x: i % 2 == 0 ? 0 : 160, y: CGFloat(i) * 6), to: CGPoint(x: i % 2 == 0 ? 160 : 0, y: CGFloat(i) * 6 + 6), count: 12)
        }
        let mark = HighlightClassifier.classify(stroke(zigzag))
        #expect(mark.kind == .scribble)
        #expect(mark.region.width >= 160 && mark.region.height >= 48)
    }

    @Test func placesAreThirdsOfTheScreen() {
        #expect(HighlightDescriber.place(of: CGPoint(x: 100, y: 50), width: 1280, height: 800) == "top left")
        #expect(HighlightDescriber.place(of: CGPoint(x: 640, y: 400), width: 1280, height: 800) == "middle")
        #expect(HighlightDescriber.place(of: CGPoint(x: 1200, y: 400), width: 1280, height: 800) == "right")
        #expect(HighlightDescriber.place(of: CGPoint(x: 640, y: 780), width: 1280, height: 800) == "bottom")
    }
}

@Suite struct HighlightHarvestTests {
    struct FakeAX: HighlightAccessibilitySource {
        var layout: DesktopLayout
        var isAvailable: Bool { true }
        func probe(atQuartz point: CGPoint) -> HighlightAXProbe? {
            let p = layout.appKitPoint(fromQuartz: point)
            if CGRect(x: 100, y: 600, width: 300, height: 24).contains(p) {
                return HighlightAXProbe(role: "AXStaticText", value: "Quarterly revenue grew 12%", frame: layout.quartzRect(fromAppKit: CGRect(x: 100, y: 600, width: 300, height: 24)),
                                        line: "Quarterly revenue grew 12%", lineFrame: layout.quartzRect(fromAppKit: CGRect(x: 100, y: 600, width: 300, height: 24)))
            }
            if CGRect(x: 100, y: 560, width: 80, height: 28).contains(p) {
                return HighlightAXProbe(role: "AXButton", label: "Export", frame: layout.quartzRect(fromAppKit: CGRect(x: 100, y: 560, width: 80, height: 28)))
            }
            if CGRect(x: 200, y: 560, width: 120, height: 20).contains(p) {
                return HighlightAXProbe(role: "AXLink", value: "Learn more", url: "https://example.com/more",
                                        frame: layout.quartzRect(fromAppKit: CGRect(x: 200, y: 560, width: 120, height: 20)))
            }
            return HighlightAXProbe(role: "AXGroup", frame: layout.quartzRect(fromAppKit: CGRect(x: 0, y: 0, width: 1280, height: 800)))
        }
    }

    let layout = DesktopLayout(displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2, isPrimary: true)])

    @Test func accessibilityGivesExactWordsControlsAndLinksOnce() async {
        let harvester = HighlightHarvester(accessibility: FakeAX(layout: layout), recognizer: nil)
        let harvest = await harvester.harvest(region: CGRect(x: 90, y: 550, width: 330, height: 80), layout: layout)
        #expect(harvest.lines.map(\.text) == ["Quarterly revenue grew 12%"])
        #expect(harvest.lines.first?.source == .accessibility)
        #expect(harvest.controls.map(\.kind) == ["button", "link"])
        #expect(harvest.controls[0].label == "Export")
        #expect(harvest.controls[1].label == "Learn more" && harvest.controls[1].url == "https://example.com/more")
    }

    @Test func withoutAccessibilityTheScreenshotIsRead() async throws {
        let image = screenImage(words: [("Quarterly revenue", CGPoint(x: 200, y: 300), 36), ("Unrelated footer", CGPoint(x: 200, y: 700), 36)])
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        let harvester = HighlightHarvester(accessibility: nil, recognizer: HighlightTextRecognizer(timeout: 120))   // the first run in a process loads the model
        // Circle the first line: pixels (180…560, 280…350) → AppKit.
        let region = geometry.appKitRect(fromPixelRect: CGRect(x: 180, y: 280, width: 380, height: 70))
        let harvest = await harvester.harvest(region: region, layout: layout, screenshot: DrawingMediaImage(image), geometry: geometry)
        let words = harvest.lines.map(\.text).joined(separator: " ")
        #expect(words.contains("Quarterly"))
        #expect(!words.contains("footer"))
        #expect(harvest.lines.allSatisfy { $0.source == .ocr })
    }

    @MainActor @Test func aTurnGetsTheDescriptionAndAnInkedScreenshot() async throws {
        let image = screenImage(words: [("Quarterly revenue", CGPoint(x: 200, y: 300), 36)])
        let jpeg = try ImageCoding.jpegData(image, quality: 0.9)
        let shot = TurnScreenshot(jpeg: jpeg, label: "main display", isCursorScreen: true, pixelSize: CGSize(width: 1280, height: 800),
                                  displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800))
        let session = DrawToAskSession(harvester: HighlightHarvester(accessibility: nil, recognizer: HighlightTextRecognizer(timeout: 120)))
        // Circle the words: centre at pixel (380, 318) → AppKit y = 800 - 318.
        let loop = circlePoints(center: CGPoint(x: 380, y: 482), rx: 210, ry: 45)
        session.keyDown(at: loop[0], time: 0)
        for (p, t) in samples(loop) { session.pointerMoved(to: p, time: t) }
        #expect(session.liveStrokes.count == 1)
        #expect(session.keyUp(time: 2) != nil)
        var input = TurnInput(words: "what does this mean?", screenshots: [shot])
        let attached = await session.attach(to: &input, layout: layout)
        let description = try #require(attached)
        let text = try #require(input.context.highlightDescription)
        #expect(text == description.text)
        #expect(text.contains("They circled an area at the top left") || text.contains("They circled an area at the left") || text.contains("They circled an area at the middle"))
        #expect(text.contains("screenshot box ["))
        #expect(text.contains("Quarterly"))
        #expect(text.contains("yellow highlighter strokes"))
        #expect(input.screenshots[0].jpeg != jpeg)
        // The ink is in the screenshot: yellow under the stroke's leftmost point (pixel 170, 318).
        let inked = try ImageCoding.decode(input.screenshots[0].jpeg)
        let px = DrawingSnapshot.pixel(inked, x: 170, y: 318)
        #expect(px.r > 200 && px.g > 170 && px.b < 120)
        // Consumed: the next turn gets nothing.
        var next = TurnInput(words: "and this?", screenshots: [shot])
        let again = await session.attach(to: &next, layout: layout)
        #expect(again == nil)
        #expect(next.context.highlightDescription == nil)
    }

    @Test func descriptionsNameEachMarkInOrder() {
        let circle = HighlightClassifier.classify(stroke(circlePoints(center: CGPoint(x: 200, y: 600), rx: 80, ry: 30)))
        let line = HighlightClassifier.classify(stroke(linePoints(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 1100, y: 700))))
        let items = [
            HighlightDescription.Item(mark: circle, harvest: HighlightHarvest(lines: [HighlightTextLine(text: "Total: $1,240", frame: .zero, source: .accessibility)],
                                                                             controls: [HighlightControl(kind: "button", label: "Pay now", frame: .zero)]),
                                      screenLabel: nil, pixelRegion: CGRect(x: 116, y: 166, width: 168, height: 68), place: "top left"),
            HighlightDescription.Item(mark: line, harvest: HighlightHarvest(), pixelRegion: CGRect(x: 1055, y: 76, width: 90, height: 48),
                                      place: "top right", startPlace: "bottom left"),
        ]
        let text = HighlightDescriber.text(items, inkInScreenshots: false)
        #expect(text.contains("They made 2 marks, in this order:"))
        #expect(text.contains("1. They circled an area at the top left (screenshot box [116, 166, 168, 68])."))
        #expect(text.contains("Text there: \"Total: $1,240\""))
        #expect(text.contains("Controls there: button \"Pay now\""))
        #expect(text.contains("2. They drew a line from the bottom left toward the top right (screenshot box [1055, 76, 90, 48])."))
        #expect(!text.contains("yellow"))
    }
}

@Suite struct HighlightSimulatorTests {
    @Test func shapesParseAndPlayAsSeparateMarks() throws {
        #expect(HighlightSimulator.Shape("circle:100,120,40") == .circle(center: CGPoint(x: 100, y: 120), radiusX: 40, radiusY: 40))
        #expect(HighlightSimulator.Shape("underline:10,20,300") == .underline(start: CGPoint(x: 10, y: 20), width: 300))
        #expect(HighlightSimulator.Shape("path:1,2;3,4;5,6") == .path([CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4), CGPoint(x: 5, y: 6)]))
        #expect(HighlightSimulator.Shape("circle:1,2") == nil && HighlightSimulator.Shape("star:1,2,3") == nil)
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        let gesture = try #require(HighlightSimulator.gesture([.circle(center: CGPoint(x: 330, y: 170), radiusX: 250, radiusY: 40),
                                                               .underline(start: CGPoint(x: 100, y: 345), width: 400),
                                                               .line(from: CGPoint(x: 900, y: 650), to: CGPoint(x: 300, y: 420)),
                                                               .scribble(CGRect(x: 700, y: 100, width: 200, height: 80))], geometry: geometry))
        let kinds = HighlightClassifier.marks(gesture).map(\.kind)
        #expect(kinds == [.circle, .underline, .line, .scribble], "\(kinds) \(gesture.strokes.map { HighlightPathMetrics($0.points) })")
    }

    @Test func aSlowRecognitionDoesNotHoldTheTurn() async {
        let screen = HighlightSimulator.demoScreen()
        let started = Date()
        let lines = await HighlightTextRecognizer(timeout: 0.001).lines(in: DrawingMediaImage(screen.image), pixelRect: CGRect(x: 0, y: 0, width: 1280, height: 800))
        #expect(lines.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

/// Review fix: one time budget for reading under all of a turn's marks, not one per mark.
@Suite struct HighlightBudgetTests {
    /// An app that answers every Accessibility probe slowly and says nothing useful.
    struct SlowAX: HighlightAccessibilitySource {
        var isAvailable: Bool { true }
        func probe(atQuartz point: CGPoint) -> HighlightAXProbe? {
            Thread.sleep(forTimeInterval: 0.05)
            return nil
        }
    }

    let layout = DesktopLayout(displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2, isPrimary: true)])

    @Test func slowAccessibilityCannotHoldATurnOfManyMarks() async {
        // Four big loops: 31 probes each at 50 ms would take over 6 s without the turn's budget.
        let strokes = (0..<4).map { i in
            stroke(circlePoints(center: CGPoint(x: 200 + CGFloat(i) * 260, y: 400), rx: 120, ry: 100))
        }
        var harvester = HighlightHarvester(accessibility: SlowAX(), recognizer: nil)
        harvester.accessibilityBudget = 0.3
        let started = Date()
        let result = await DrawToAskSession.describe(HighlightGesture(strokes: strokes), screenshots: [], layout: layout, harvester: harvester)
        #expect(result.description.items.count == 4)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func noTimeLeftMeansNoRecognition() async {
        let image = screenImage(words: [("Quarterly revenue", CGPoint(x: 200, y: 300), 36)])
        let geometry = CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 800), pixelWidth: 1280, pixelHeight: 800)
        let harvester = HighlightHarvester(accessibility: nil, recognizer: HighlightTextRecognizer(timeout: 120))
        let spent = HighlightHarvester.Deadlines(accessibility: 0, overall: ProcessInfo.processInfo.systemUptime - 1)
        let started = Date()
        let harvest = await harvester.harvest(region: geometry.appKitRect(fromPixelRect: CGRect(x: 180, y: 280, width: 380, height: 70)),
                                              layout: layout, screenshot: DrawingMediaImage(image), geometry: geometry, deadlines: spent)
        #expect(harvest.lines.isEmpty)
        #expect(Date().timeIntervalSince(started) < 0.5)
        // A fresh turn's deadlines: probing first, then the recognizer's timeout.
        let fresh = harvester.deadlines(from: 100)
        #expect(fresh.accessibility == 101.5 && fresh.overall == 221.5)
    }
}
