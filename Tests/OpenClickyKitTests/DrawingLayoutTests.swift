import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import Testing
@testable import OpenClickyKit

// Layout rules of the 2D drawing language (docs/dsl.md, "Layout and readable ink"): words on a card stay inside it and
// the card grows to hold them, arrow labels sit beside their arrows, loose words keep off strokes (and step aside for
// later ones), and a pill naming something on the screen sits beside it with a leader, never on it.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The marks on the canvas once every event has been applied: the latest version of each, without removed ones.
private func finalMarks(_ events: [DrawingEvent]) -> [String: JSONValue] {
    var marks: [String: JSONValue] = [:]
    for event in events {
        switch event {
        case .marks(let list): for mark in list { marks[mark.id] = mark.json }
        case .remove(let ids): for id in ids { marks[id] = nil }
        default: break
        }
    }
    return marks
}

private func xf(_ json: JSONValue) -> (k: Double, tx: Double, ty: Double) {
    guard let v = json["xf"]?.arrayValue, v.count >= 3 else { return (1, 0, 0) }
    return (v[0].doubleValue ?? 1, v[1].doubleValue ?? 0, v[2].doubleValue ?? 0)
}

/// `at` + `w` × `h` (canvas units) with the mark's move applied.
private func box(_ json: JSONValue) -> CGRect {
    let at = json["at"]?.arrayValue ?? []
    let t = xf(json)
    return CGRect(x: (at.first?.doubleValue ?? 0) * t.k + t.tx, y: (at.dropFirst().first?.doubleValue ?? 0) * t.k + t.ty,
                  width: (json["w"]?.doubleValue ?? 0) * t.k, height: (json["h"]?.doubleValue ?? 0) * t.k)
}

private func polylines(_ json: JSONValue) -> [[CGPoint]] {
    let t = xf(json)
    func pts(_ v: JSONValue?) -> [CGPoint] {
        (v?.arrayValue ?? []).compactMap { p in
            guard let a = p.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            return CGPoint(x: x * t.k + t.tx, y: y * t.k + t.ty)
        }
    }
    var out: [[CGPoint]] = []
    if let segs = json["segs"]?.arrayValue { out += segs.map { pts($0) } } else { out.append(pts(json["pts"])) }
    if json["head"] != nil { out.append(pts(json["head"])) }
    return out.filter { $0.count >= 2 }
}

private func segment(_ a: CGPoint, _ b: CGPoint, hits r: CGRect) -> Bool {
    var t0 = 0.0, t1 = 1.0
    let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
    let p = [-dx, dx, -dy, dy]
    let q = [Double(a.x - r.minX), Double(r.maxX - a.x), Double(a.y - r.minY), Double(r.maxY - a.y)]
    for i in 0..<4 {
        if p[i] == 0 { if q[i] < 0 { return false }; continue }
        let t = q[i] / p[i]
        if p[i] < 0 { if t > t1 { return false }; t0 = max(t0, t) } else { if t < t0 { return false }; t1 = min(t1, t) }
    }
    return t0 <= t1
}

private func crosses(_ line: [CGPoint], _ r: CGRect) -> Bool {
    zip(line, line.dropFirst()).contains { segment($0, $1, hits: r) }
}

/// Words (free text and labels other than a box's own label) that a line or arrow runs through.
private func wordsCrossedByStrokes(_ marks: [String: JSONValue]) -> [String] {
    let strokes = marks.values.filter { ["line", "arrow"].contains($0["do"]?.stringValue ?? "") }
    var crossed: [String] = []
    for words in marks.values where words["do"]?.stringValue == "text" {
        let r = box(words).insetBy(dx: 1, dy: 1)
        for stroke in strokes where polylines(stroke).contains(where: { crosses($0, r) }) {
            crossed.append("\(words["text"]?.stringValue ?? "?") × \(stroke["id"]?.stringValue ?? "?")")
        }
    }
    return crossed
}

/// Words that run past the card they are on (the card each text's centre or top-left corner is on).
private func wordsOffTheirCard(_ marks: [String: JSONValue]) -> [String] {
    let cards = marks.values.filter { $0["do"]?.stringValue == "paper" }.map(box)
    var off: [String] = []
    for words in marks.values where words["do"]?.stringValue == "text" {
        let r = box(words)
        let anchor = CGPoint(x: r.minX + 1, y: r.minY + 1)
        guard let card = cards.first(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) || $0.contains(anchor) }) else { continue }
        if !card.insetBy(dx: -0.5, dy: -0.5).contains(r) { off.append("\(words["text"]?.stringValue ?? "?") \(r) outside \(card)") }
    }
    return off
}

private func makeHost(_ clock: VirtualClock = VirtualClock(), busy: DrawingEngineHost.Busyness? = nil) throws -> DrawingEngineHost {
    try DrawingEngineHost(clock: { clock.now }, busyness: busy)
}

private func run(_ host: DrawingEngineHost, _ program: String, pace: DrawingBeginOptions.Pace = .now,
                 width: Double = 1280, height: Double = 832) -> [DrawingEvent] {
    var events = host.perform(.begin(DrawingBeginOptions(width: width, height: height, pace: pace)))
    events += host.perform(.append(program))
    events += host.perform(.end)
    events += host.perform(.drain)
    return events
}

private func warnings(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .warning(let m) = $0 { m } else { nil } }
}

// MARK: Words on cards

@Test func handwritingOnACardWrapsToTheCardAndTheCardHoldsIt() throws {
    // The gyroscope card from the brain-runtime evidence: four lines that were too wide for a 260-unit card.
    let host = try makeHost()
    let events = run(host, """
    const card = paper(40, 150, 260, 300, {title: "Why it stays up", board: "plain"});
    write(card.x + 10, card.y + 40, "Spin = angular momentum.\\nTipping force makes it\\nprecess sideways, not fall.\\nFriction slowly slows it.")
    """)
    let marks = finalMarks(events)
    let paper = try #require(marks.values.first { $0["do"]?.stringValue == "paper" })
    let text = try #require(marks.values.first { $0["do"]?.stringValue == "text" })
    let inner = box(paper).insetBy(dx: 18, dy: 0)
    #expect(box(text).maxX <= inner.maxX + 0.5, "the words run past the card's writing area: \(box(text)) vs \(inner)")
    #expect((text["lines"]?.arrayValue?.count ?? 0) > 4, "the long lines should have wrapped")
    #expect(wordsOffTheirCard(marks).isEmpty, "\(wordsOffTheirCard(marks))")
}

@Test func wordsWrittenBelowACardsLastRowGrowTheCard() throws {
    let host = try makeHost()
    let events = run(host, """
    const card = paper(140, 100, 1000, 500, {title: "Fridge", board: "grid"})
    const evap = box(card.x + 60, card.y + 330, 220, 110, {label: "Evaporator"})
    text(evap.x, evap.bottom + 14, "Food heat is absorbed here", {size: 16, tone: "sky"})
    """)
    let marks = finalMarks(events)
    let paper = try #require(marks.values.first { $0["do"]?.stringValue == "paper" })
    #expect((paper["h"]?.doubleValue ?? 0) > 500, "the card should have grown")
    #expect(wordsOffTheirCard(marks).isEmpty, "\(wordsOffTheirCard(marks))")
}

@Test func aCardAlreadyOnScreenGlidesToItsNewSize() throws {
    let clock = VirtualClock()
    let host = try makeHost(clock)
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech)))
    events += host.perform(.append("step(1)\nsay(\"A card.\")\nconst card = paper(100, 100, 400, 200, {title: \"Notes\"})\nstep(2)\nsay(\"More words.\")\n"))
    events += host.perform(.lineStarted(0, 1.5))
    clock.now += 2
    events += host.perform(.drain)
    events += host.perform(.lineFinished(0))
    // The card is on screen; now words arrive that reach below it.
    events += host.perform(.append("text(card.x, card.y + card.h - 20, \"A long note written right at the bottom of the card, long enough to wrap twice\", {size: 18})\n"))
    events += host.perform(.end)
    events += host.perform(.lineStarted(1, 3))
    clock.now += 4
    events += host.perform(.drain)
    let grown = events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
        .filter { $0.kind == "paper" && $0.json["edit"]?.stringValue == "grow" }
    let grow = try #require(grown.last, "no grow edit for the card")
    #expect(grow.json["from"]?.arrayValue?.map { $0.doubleValue ?? 0 } == [100, 100, 400, 200])
    #expect((grow.json["h"]?.doubleValue ?? 0) > 200)
    #expect(wordsOffTheirCard(finalMarks(events)).isEmpty)
}

@MainActor
@Test func aGrownCardKeepsItsPlaceUnderWhatIsDrawnOnIt() throws {
    let clock = VirtualClock(CACurrentMediaTime() + 100_000)
    let painter = DrawingPainter(canvas: .init(width: 800, height: 600), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let base = clock.now
    let paper: JSONValue = ["id": "m1", "do": "paper", "at": [100, 100], "w": 300, "h": 200, "header": 28, "pad": 18,
                            "title": "Notes", "board": "plain", "start": 0, "duration": 0.4, "base": .number(base)]
    let region: JSONValue = ["id": "m2", "do": "region", "at": [120, 140], "w": 100, "h": 60, "r": 8, "start": 0.5, "duration": 0.3,
                             "base": .number(base), "tone": "#3380FF"]
    painter.apply([DrawingEvent.marks([DrawingMark(paper), DrawingMark(region)])])
    var fields = paper.objectValue ?? [:]
    fields["h"] = 320
    fields["edit"] = "grow"
    fields["from"] = [100, 100, 300, 200]
    fields["start"] = 2
    fields["duration"] = 0.3
    painter.apply([DrawingEvent.marks([DrawingMark(.object(fields))])])
    let under = try #require(painter.layer.sublayers?.first { $0.name == "under" })
    let names = under.sublayers?.map { $0.name ?? "" } ?? []
    // The new card sits where the old one was: below the region drawn on it.
    let cardIndex = try #require(names.lastIndex(of: "m1")), regionIndex = try #require(names.firstIndex(of: "m2"))
    #expect(cardIndex < regionIndex, "\(names)")
    let shown = try DrawingSnapshot.render(painter.layer, size: CGSize(width: 800, height: 600), at: clock.now + 5,
                                           background: CGColor(gray: 1, alpha: 1))
    // Below the old bottom edge (y 300) the grown card's sheet is painted.
    let pixel = DrawingSnapshot.pixel(shown, x: 250, y: 380)
    #expect(pixel.r < 254 || pixel.g < 254 || pixel.b < 254, "the grown card isn't painted below its old edge: \(pixel)")
}

// MARK: Labels and loose words

@Test func arrowLabelsSitBesideTheirArrowsNotOnThem() throws {
    let host = try makeHost()
    let events = run(host, """
    const card = paper(140, 100, 1000, 500, {title: "Loop", board: "grid"})
    arrow([600, 200], [900, 200], {label: "hot gas"})
    arrow([988, 230], [988, 450], {label: "warm liquid"})
    arrow([330, 450], [330, 240], {label: "cool vapour"})
    """)
    let marks = finalMarks(events)
    #expect(wordsCrossedByStrokes(marks).isEmpty, "\(wordsCrossedByStrokes(marks))")
    let label = try #require(marks.values.first { $0["text"]?.stringValue == "hot gas" })
    #expect(box(label).maxY <= 200, "a flat arrow's label goes above it: \(box(label))")
    #expect(wordsOffTheirCard(marks).isEmpty)
}

@Test func looseWordsKeepOffStrokesAlreadyDrawn() throws {
    let host = try makeHost()
    let events = run(host, """
    line([100, 300], [700, 300])
    text(300, 290, "Heat leaves here", {size: 16})
    """)
    let marks = finalMarks(events)
    #expect(wordsCrossedByStrokes(marks).isEmpty, "\(wordsCrossedByStrokes(marks))")
}

@Test func aLaterArrowMovesLooseWordsOutOfItsWay() throws {
    // The fridge diagram: "Heat leaves here" is written under the condenser; the next beat's arrow starts there.
    let host = try makeHost()
    let events = run(host, """
    const card = paper(140, 100, 1000, 500, {title: "Fridge", board: "grid"})
    const cond = box(card.x + 720, card.y + 70, 220, 110, {label: "Condenser"})
    text(cond.x, cond.bottom + 10, "Heat leaves here", {size: 16, tone: "red"})
    arrow([cond.cx, cond.bottom + 8], [cond.cx, cond.bottom + 150], {label: "warm liquid"})
    """)
    let marks = finalMarks(events)
    #expect(wordsCrossedByStrokes(marks).isEmpty, "\(wordsCrossedByStrokes(marks))")
    let words = try #require(marks.values.first { $0["text"]?.stringValue == "Heat leaves here" })
    #expect(words["xf"] != nil, "the words should have stepped aside")
    #expect(wordsOffTheirCard(marks).isEmpty)
}

@Test func aBoxLabelTooWideForItsBoxShrinksToFit() throws {
    let host = try makeHost()
    let events = run(host, "box(100, 100, 90, 60, {label: \"Thermodynamics\"})\n")
    let marks = finalMarks(events)
    let shape = try #require(marks.values.first { $0["do"]?.stringValue == "box" })
    let label = try #require(marks.values.first { $0["do"]?.stringValue == "text" })
    #expect(box(shape).contains(box(label)), "\(box(label)) is not inside \(box(shape))")
}

// MARK: Names beside what they name

/// A screen whose busy parts are these rectangles (text and controls), as the screen sampler would report.
private func screen(_ controls: [CGRect]) -> DrawingEngineHost.Busyness {
    { rect in
        let area = max(1, rect.width * rect.height)
        let covered = controls.reduce(0.0) { sum, control in
            let i = control.intersection(rect)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        return min(1, Double(covered / area))
    }
}

@Test func aNamePillSitsBesideTheButtonItNamesWithALeader() throws {
    // The bridge test page's "Say hello" button and the rows around it.
    let button = CGRect(x: 32, y: 217, width: 71, height: 21)
    let controls = [button, CGRect(x: 32, y: 186, width: 227, height: 21), CGRect(x: 32, y: 254, width: 560, height: 40)]
    let host = try makeHost(busy: screen(controls))
    let events = run(host, "point(67, 227, \"Say hello\")\n", width: 1200, height: 661)
    let marks = finalMarks(events)
    let pill = try #require(marks.values.first { $0["do"]?.stringValue == "pill" })
    #expect(!box(pill).intersects(button), "the pill covers the button: \(box(pill))")
    let leader = marks.values.first { $0["role"]?.stringValue == "leader" }
    #expect(leader != nil, "no leader from the button to its pill")
}

@Test func aNamePillMovesAsideForALaterCallout() throws {
    let field = CGRect(x: 106, y: 186, width: 153, height: 21)
    let host = try makeHost(busy: screen([field]))
    let events = run(host, """
    point(182, 196, "Password")
    callout(270, 196, "Type here", {side: "right"})
    """, width: 1200, height: 661)
    let marks = finalMarks(events)
    let pill = try #require(marks.values.first { $0["text"]?.stringValue == "Password" })
    let spot = CGRect(x: 270 - 11, y: 196 - 11, width: 22, height: 22)
    #expect(!box(pill).intersects(spot), "the earlier pill still covers the callout's spot: \(box(pill))")
    #expect(!box(pill).intersects(field))
}

@Test func aRegionsNameStaysOffWhatTheRegionHolds() throws {
    let greeting = CGRect(x: 44, y: 264, width: 214, height: 20)
    let host = try makeHost(busy: screen([greeting, CGRect(x: 32, y: 217, width: 71, height: 21)]))
    let events = run(host, "region(33, 255, 558, 38, \"Greeting\")\n", width: 1200, height: 661)
    let marks = finalMarks(events)
    let pill = try #require(marks.values.first { $0["do"]?.stringValue == "pill" })
    #expect(!box(pill).intersects(greeting), "the name covers the greeting: \(box(pill))")
}

// MARK: The screen sampler

@MainActor
@Test func theScreenSamplerReadsTheScreenshotTopDown() throws {
    // Dark top half, light bottom half (a menu bar over a page, say).
    let image = try #require(DrawingRehearsal.paint(size: CGSize(width: 200, height: 200)) { context, rect in
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        // Drawing coordinates are bottom-up: the top half is y 100…200.
        context.fill(CGRect(x: 0, y: 100, width: 200, height: 100))
    })
    let sampler = DrawingScreenSampler(image: image, canvasSize: CGSize(width: 200, height: 200))
    let top = try #require(sampler.luminance(in: CGRect(x: 10, y: 10, width: 50, height: 50)))
    let bottom = try #require(sampler.luminance(in: CGRect(x: 10, y: 140, width: 50, height: 50)))
    #expect(top < 0.1 && bottom > 0.9, "top \(top), bottom \(bottom)")
    // The edge between them is busy; the plain halves are not.
    #expect((sampler.busyness(in: CGRect(x: 0, y: 92, width: 200, height: 16)) ?? 0) > 0.3)
    #expect((sampler.busyness(in: CGRect(x: 0, y: 140, width: 200, height: 40)) ?? 1) == 0)
}

// MARK: The recorded live answers

private struct EvidenceProgram {
    var path: String
    var size: CGSize
    var backdrop: String
}

private let evidencePrograms: [EvidenceProgram] = [
    .init(path: "Tests/Fixtures/Drawing/brain/1-bridge-page.js", size: CGSize(width: 1200, height: 661), backdrop: "bridge-page.jpg"),
    .init(path: "Tests/Fixtures/Drawing/brain/1-bridge-page-first-try.js", size: CGSize(width: 1200, height: 661), backdrop: "bridge-page.jpg"),
    .init(path: "Tests/Fixtures/Drawing/brain/2-hash-table.js", size: CGSize(width: 1280, height: 832), backdrop: "blank-canvas.png"),
    .init(path: "Tests/Fixtures/Drawing/brain/3-hash-collisions.js", size: CGSize(width: 1280, height: 832), backdrop: "blank-canvas.png"),
    .init(path: "Tests/Fixtures/Drawing/brain/6-growth-graph.js", size: CGSize(width: 1280, height: 832), backdrop: "blank-canvas.png"),
    .init(path: "Tests/Fixtures/Drawing/voice/1-voice-bridge-page/program.js", size: CGSize(width: 1200, height: 661), backdrop: "bridge-page.jpg"),
    .init(path: "Tests/Fixtures/Drawing/voice/2-voice-diagram-blank-canvas/program.js", size: CGSize(width: 1280, height: 800), backdrop: "blank-canvas.png"),
    .init(path: "Tests/Fixtures/Drawing/voice/3-typed-read-aloud/program.js", size: CGSize(width: 1200, height: 661), backdrop: "bridge-page.jpg"),
    .init(path: "Tests/Fixtures/Drawing/voice/review/R1-voice-password-field/program.js", size: CGSize(width: 1200, height: 661), backdrop: "bridge-page.jpg"),
]

private func loadImage(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The answers recorded in earlier live runs (brain runtime, voice loop) lay out cleanly now: no words run past their
/// card, no stroke crosses words, and no name pill covers the control it names (the page's real element frames).
/// Runs the engine alone over each screenshot (no painter), off the main actor, so it doesn't hold up other suites.
@Test func recordedLiveAnswersLayOutCleanly() async throws {
    let inputs = repoRoot.appendingPathComponent("Tests/Fixtures/Drawing/brain/inputs")
    let elements = try JSONValue.parse(String(contentsOf: inputs.appendingPathComponent("bridge-page-elements.json"), encoding: .utf8))
    let frames: [CGRect] = (elements.arrayValue ?? []).compactMap { element in
        guard let f = element["frame"]?.arrayValue, f.count == 4 else { return nil }
        return CGRect(x: f[0].doubleValue ?? 0, y: f[1].doubleValue ?? 0, width: f[2].doubleValue ?? 0, height: f[3].doubleValue ?? 0)
    }
    for program in evidencePrograms {
        let sampler = DrawingScreenSampler(image: try loadImage(inputs.appendingPathComponent(program.backdrop)), canvasSize: program.size)
        let host = try DrawingEngineHost(luminance: { sampler.luminance(in: $0) }, busyness: { sampler.busyness(in: $0) })
        let source = try String(contentsOf: repoRoot.appendingPathComponent(program.path), encoding: .utf8)
        var events = host.perform(.begin(DrawingBeginOptions(width: program.size.width, height: program.size.height, pace: .now)))
        events += host.perform(.append(source))
        events += host.perform(.end)
        events += host.perform(.drain)
        let name = program.path
        let errors = events.compactMap { if case .error(let m, _) = $0 { m } else { nil } }
        #expect(errors.isEmpty, "\(name): \(errors)")
        let marks = finalMarks(events)
        #expect(wordsOffTheirCard(marks).isEmpty, "\(name): \(wordsOffTheirCard(marks))")
        #expect(wordsCrossedByStrokes(marks).isEmpty, "\(name): \(wordsCrossedByStrokes(marks))")
        if program.backdrop == "bridge-page.jpg" {
            // A pill never covers a control or line of text it was placed next to.
            for pill in marks.values where pill["do"]?.stringValue == "pill" {
                for frame in frames where box(pill).intersects(frame.insetBy(dx: 2, dy: 2)) {
                    Issue.record("\(name): pill \(pill["text"]?.stringValue ?? "?") at \(box(pill)) covers \(frame)")
                }
            }
        }
    }
}
