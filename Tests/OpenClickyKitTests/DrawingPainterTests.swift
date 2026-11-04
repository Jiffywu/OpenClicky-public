import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

// The native painter: marks from the engine become a Core Animation layer tree with timed reveals.

/// Core Animation drops animations that look finished by real media time, so test clocks run far in the future.
private func futureClock() -> VirtualClock { VirtualClock(CACurrentMediaTime() + 100_000) }

@MainActor
private func paint(_ program: String, clock: VirtualClock = futureClock(), scale: Double = 1,
                   sink: (any FigureSink)? = nil) throws -> (DrawingPainter, [DrawingMark]) {
    let host = try DrawingEngineHost(clock: { clock.now })
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, scale: scale, pace: .now)))
    events += host.perform(.append(program))
    events += host.perform(.end)
    events += host.perform(.drain)
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832, scale: scale), figureSink: sink, clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    painter.apply(events)
    let marks = events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
    return (painter, marks)
}

private func names(_ layer: CALayer) -> [String] {
    var out: [String] = []
    func walk(_ l: CALayer) {
        if let name = l.name { out.append(name) }
        l.sublayers?.forEach(walk)
    }
    walk(layer)
    return out
}

private func find(_ layer: CALayer, _ name: String) -> CALayer? {
    if layer.name == name { return layer }
    for sub in layer.sublayers ?? [] { if let hit = find(sub, name) { return hit } }
    return nil
}

private func group(of container: CALayer) -> String? { container.superlayer?.name }

@MainActor
@Test func everyMarkKindBecomesItsOwnLayerTree() throws {
    let (painter, marks) = try paint("""
    line(100, 100, 300, 140)
    arrow([320, 160], [500, 300])
    box(520, 300, 160, 90, { fill: "butter" })
    circle(800, 200, 60, { fill: "sky" })
    dot(900, 400)
    text(100, 500, "Plain words")
    write(100, 560, "Handwritten words")
    highlight(100, 495, 200, 30)
    pill(400, 500, "Inbox")
    badge(380, 480, 2)
    region(60, 640, 300, 120)
    paper(700, 450, 420, 300, { title: "Notes", board: "grid" })
    button(720, 700, "Tell me more")
    graph(100, 100, 300, 200, { grid: true })
    """)
    let expected: [String: (group: String, parts: [String])] = [
        "line": ("main", ["stroke"]),
        "arrow": ("main", ["stroke", "head"]),
        "box": ("main", ["fill", "stroke"]),
        "circle": ("main", ["fill", "stroke"]),
        "dot": ("main", ["dot"]),
        "text": ("words", ["words", "glyphs"]),
        "highlight": ("under", ["band"]),
        "region": ("under", ["region", "tint", "frame"]),
        "pill": ("words", ["pill", "gel", "gloss", "rim", "glyphs"]),
        "badge": ("words", ["badge", "gel", "rim", "glyphs"]),
        "button": ("words", ["button", "gel", "rim", "glyphs"]),
        "paper": ("under", ["paper", "sheet", "titlebar", "lights", "title", "board"]),
        "graph": ("under", ["grid"]),
    ]
    for (kind, want) in expected {
        let mark = try #require(marks.first { $0.kind == kind }, "no \(kind) mark")
        let container = try #require(painter.layer(forMark: mark.id), "no layer for \(kind)")
        #expect(container.name == mark.id)
        #expect(group(of: container) == want.group, "\(kind) is in \(group(of: container) ?? "nothing")")
        let found = names(container)
        for part in want.parts { #expect(found.contains(part), "\(kind) lacks \(part): \(found)") }
    }
    #expect(Set(painter.markIDs) == Set(marks.filter { !$0.isFigureMark }.map(\.id)))
}

@MainActor
@Test func strokesRevealWithThePenOnTheVoiceClock() throws {
    let clock = futureClock()
    let (painter, marks) = try paint("line(100, 100, 700, 100, { tone: \"red\" })\narrow([100, 300], [700, 300])", clock: clock, scale: 2)
    let line = try #require(marks.first { $0.kind == "line" })
    let lineLayer = try #require(painter.layer(forMark: line.id))
    let stroke = try #require(find(lineLayer, "stroke") as? CAShapeLayer)
    let pen = try #require(stroke.animation(forKey: "pen") as? CABasicAnimation)
    #expect(pen.keyPath == "strokeEnd")
    let base = try #require(line.json["base"]?.doubleValue)
    #expect(abs(pen.beginTime - (base + line.start)) < 1e-6)
    #expect(abs(pen.duration - line.duration) < 1e-6)
    #expect(pen.fillMode == .backwards) // hidden until its moment comes
    // Screen ink is an even 3.5-point line whatever the canvas scale, and glows in its own colour.
    #expect(abs(stroke.lineWidth - 3.5) < 0.01)
    #expect(stroke.lineCap == .round)
    #expect(stroke.shadowColor == stroke.strokeColor)
    #expect(stroke.shadowOpacity > 0 && stroke.shadowRadius > 0)
    #expect(stroke.path?.boundingBox.maxX ?? 0 > 1300)

    // An arrow's head is drawn after its shaft.
    let arrow = try #require(marks.first { $0.kind == "arrow" })
    let container = try #require(painter.layer(forMark: arrow.id))
    let shaft = try #require(find(container, "stroke")?.animation(forKey: "pen"))
    let head = try #require(find(container, "head")?.animation(forKey: "pen"))
    #expect(head.beginTime >= shaft.beginTime + shaft.duration - 1e-6)
    #expect(head.beginTime + head.duration <= base + arrow.start + arrow.duration + 1e-6)
}

@MainActor
@Test func wordsAreSetWithCoreTextAndWrittenLeftToRight() throws {
    let (painter, marks) = try paint("write(100, 100, \"Hello\\nworld\", { size: 30 })")
    let text = try #require(marks.first { $0.kind == "text" })
    #expect(text.json["lines"]?.arrayValue?.count == 2)
    let textLayer = try #require(painter.layer(forMark: text.id))
    let words = try #require(find(textLayer, "words"))
    let glyphs = try #require(find(words, "glyphs") as? CAShapeLayer)
    let box = try #require(glyphs.path?.boundingBox)
    #expect(box.width > 40 && box.height > 40) // two lines of real outlines
    let strips = words.mask?.sublayers ?? []
    #expect(strips.count == 2)
    let first = try #require(strips[0].animation(forKey: "write"))
    let second = try #require(strips[1].animation(forKey: "write"))
    #expect(second.beginTime >= first.beginTime + first.duration - 1e-6)
}

@MainActor
@Test func editsGlideRecolourAndFadeOut() throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
    events += host.perform(.append("box(100, 100, 200, 100)\ncircle(600, 300, 40)\nmove(\"p1\", 50, 20)\nerase(\"p2\")\n"))
    events += host.perform(.end)
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    painter.apply(events)
    let boxID = try #require(painter.markIDs.first { painter.entries[$0]?.mark.kind == "box" })
    let circleID = try #require(painter.markIDs.first { painter.entries[$0]?.mark.kind == "circle" })
    let boxLayer = try #require(painter.layer(forMark: boxID))
    #expect(boxLayer.animation(forKey: "move") != nil)
    let affine = CATransform3DGetAffineTransform(boxLayer.transform)
    #expect(affine.tx == 50 && affine.ty == 20)

    let circleLayer = try #require(painter.layer(forMark: circleID))
    for _ in 0..<20 { clock.now += 0.5; painter.apply(host.perform(.drain)) }
    #expect(painter.layer(forMark: circleID) == nil)
    #expect(circleLayer.animation(forKey: "leave") != nil)
}

@MainActor
@Test func clicksOnDrawnButtonsAreFound() throws {
    let clock = futureClock()
    let (painter, marks) = try paint("button(400, 600, \"Why is that?\")", clock: clock, scale: 2)
    let button = try #require(marks.first { $0.kind == "button" })
    let at = try #require(button.json["at"]?.arrayValue?.compactMap { $0.doubleValue })
    let w = try #require(button.json["w"]?.doubleValue), h = try #require(button.json["h"]?.doubleValue)
    let centre = CGPoint(x: (at[0] + w / 2) * 2, y: (at[1] + h / 2) * 2)
    // Painted ahead of its moment, the button isn't on screen yet: a click there belongs to the app underneath.
    #expect(painter.beginTime(button.json) > clock.now)
    #expect(painter.buttonID(at: centre) == nil)
    clock.now = painter.beginTime(button.json)
    #expect(painter.buttonID(at: centre) == button.id)
    #expect(painter.buttonID(at: CGPoint(x: 5, y: 5)) == nil)
}

@MainActor
private final class RecordingFigureSink: FigureSink {
    var applied: [String] = []
    var removed: [String] = []
    var layers: [String: CALayer] = [:]

    func apply(_ mark: DrawingMark) {
        applied.append("\(mark.kind):\(mark.id)")
        if mark.kind == "figure", layers[mark.id] == nil { layers[mark.id] = CALayer() }
    }
    func layer(forFigure figureID: String) -> CALayer? { layers[figureID] }
    func hitTest(figure figureID: String, at point: CGPoint) -> String? { nil }
    func removeFigure(_ figureID: String) { removed.append(figureID) }
}

@MainActor
@Test func figureMarksAreForwardedToTheFigureSinkNotPainted() throws {
    let sink = RecordingFigureSink()
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832, scale: 2), figureSink: sink)
    DrawingSnapshot.adopt(painter.layer)
    let figure: JSONValue = ["do": "figure", "id": "f1", "step": 1, "at": [100, 120], "w": 300, "h": 200, "start": 0, "duration": 0.35]
    let part: JSONValue = ["do": "part3d", "id": "f1.piston", "figure": "f1", "step": 1, "start": 0.1, "duration": 0.65]
    let camera: JSONValue = ["do": "camera3d", "id": "c1", "figure": "f1", "step": 1, "start": 0, "duration": 0]
    painter.apply(.marks([DrawingMark(figure), DrawingMark(part), DrawingMark(camera)]))
    #expect(sink.applied == ["figure:f1", "part3d:f1.piston", "camera3d:c1"])
    #expect(painter.markIDs.isEmpty)
    let layer = try #require(sink.layers["f1"])
    #expect(layer.frame == CGRect(x: 200, y: 240, width: 600, height: 400))
    #expect(layer.superlayer?.name == "main")
    painter.apply(.remove(["f1"]))
    #expect(sink.removed == ["f1"])
    #expect(layer.superlayer == nil)
}

@MainActor
@Test func nonPaintedEventsArePassedOn() throws {
    let painter = DrawingPainter(canvas: .init(width: 100, height: 100))
    var seen: [DrawingEvent] = []
    painter.onEvent = { seen.append($0) }
    painter.apply([.step(2), .warning("w"), .ask("Why?"), .done])
    #expect(seen == [.step(2), .warning("w"), .ask("Why?"), .done])
    #expect(painter.currentStep == 2)
}

@MainActor
@Test func sessionPacesTheDrawingWithTheVoiceAndAnswersClicks() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    var seen: [DrawingEvent] = []
    session.onEvent = { seen.append($0) }

    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append("step(1)\nsay(\"Here is a box.\")\nbox(100, 100, 200, 100)\n")
    session.append("step(2)\nsay(\"And a button.\")\nbutton(400, 400, \"Why?\")\n")
    session.end()
    await session.settle()
    #expect(session.isDrawing)
    #expect(painter.markIDs.isEmpty) // held until the voice starts line 0

    let pacing: any SpeechPacing = session
    pacing.lineStarted(0, expectedDuration: 1.5)
    await session.settle()
    #expect(painter.markIDs.map { painter.entries[$0]?.mark.kind } == ["box"])

    clock.now += 2
    pacing.lineFinished(0)
    pacing.lineStarted(1, expectedDuration: 1)
    await session.settle()
    clock.now += 2
    await session.settle()
    let buttonID = try #require(painter.markIDs.first { painter.entries[$0]?.mark.kind == "button" })
    let frame = painter.rect(try #require(painter.entries[buttonID]?.mark.json))
    #expect(session.click(at: CGPoint(x: frame.midX, y: frame.midY)))
    #expect(!session.click(at: CGPoint(x: 1, y: 1)))
    await session.settle()
    #expect(seen.contains(.ask("Why?")))
    #expect(seen.contains(.step(2)))
    #expect(seen.contains(.done))
    #expect(!session.isDrawing)
}

@MainActor
@Test func aLateDoneFromACancelledDrawingDoesNotEndTheNextOne() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    var seen: [DrawingEvent] = []
    session.onEvent = { seen.append($0) }

    // The user barges in: the first drawing is cancelled and the next begins at once, before the engine's `done`
    // for the first one has reached the main queue.
    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append("say(\"One.\")\nbox(100, 100, 200, 100)\n")
    session.cancel()
    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append("say(\"Two.\")\nbox(300, 100, 200, 100)\n")
    session.end()
    await session.settle()
    #expect(session.isDrawing)
    #expect(!seen.contains(.done))

    let pacing: any SpeechPacing = session
    pacing.lineStarted(0, expectedDuration: 1)
    await session.settle()
    clock.now += 2
    pacing.lineFinished(0)
    await session.settle()
    #expect(painter.markIDs.count == 1)
    #expect(seen.filter { $0 == .done }.count == 1)
    #expect(!session.isDrawing)
}

/// Review fix: an action due on a line that was released just before the user barged in must not type, open or hand
/// off once the drawing is cancelled; a button clicked on a finished drawing still acts.
@MainActor
@Test func lineActionsFromACancelledDrawingDoNotActButClicksStillDo() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    var actions: [DrawingAction] = []
    session.onEvent = { if case .action(let action) = $0 { actions.append(action) } }
    let program = "say(\"Typing it for you.\")\nbox(100, 100, 300, 200)\ntypeText(400, 300, \"hello\")\n"
    let pacing: any SpeechPacing = session

    // Heard to its moment, the line types.
    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append(program)
    session.end()
    await session.settle()
    pacing.lineStarted(0, expectedDuration: 2)
    await session.settle()
    clock.now += 5
    session.tick()
    await session.settle()
    #expect(actions.map(\.role) == [.type] && actions.first?.text == "hello")
    actions.removeAll()

    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append(program)
    session.end()
    await session.settle()
    pacing.lineStarted(0, expectedDuration: 2)
    await session.settle()
    #expect(actions.isEmpty, "the typing waits for its moment in the line")
    // Its moment comes on the engine's queue (a drain), and the user barges in before that reaches the main actor.
    clock.now += 5
    session.tick()
    session.cancel()
    await session.settle()
    #expect(actions.isEmpty)
    #expect(!session.isDrawing)

    // A drawn copy button, clicked once its drawing is finished, still copies.
    session.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now))
    session.append("button(400, 400, \"Copy it\", {copy: \"abc\"})\n")
    session.end()
    await session.settle()
    clock.now += 10
    await session.settle()
    #expect(!session.isDrawing)
    let buttonID = try #require(painter.markIDs.first { painter.entries[$0]?.mark.kind == "button" })
    let frame = painter.rect(try #require(painter.entries[buttonID]?.mark.json))
    #expect(session.click(at: CGPoint(x: frame.midX, y: frame.midY)))
    await session.settle()
    #expect(actions.map(\.role) == [.copy] && actions.first?.fromClick == true && actions.first?.text == "abc")
}

@MainActor
@Test func clearRemovesMarksThatWereStillOnTheirWay() async throws {
    let clock = futureClock()
    let host = try DrawingEngineHost(clock: { clock.now })
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832), clock: { clock.now })
    DrawingSnapshot.adopt(painter.layer)
    let session = DrawingSession(host: host, painter: painter)
    session.begin(DrawingBeginOptions(width: 1280, height: 832))
    session.append("say(\"Here.\")\nbox(100, 100, 200, 100)\ncircle(600, 300, 50)\n")
    session.end()
    await session.settle()
    #expect(painter.markIDs.isEmpty)

    // The voice starts the line (its marks are released on the engine's queue) just as the user dismisses the drawing.
    let pacing: any SpeechPacing = session
    pacing.lineStarted(0, expectedDuration: 1)
    session.clear()
    await session.settle()
    #expect(painter.markIDs.isEmpty)
    #expect(!session.isDrawing)
}

@MainActor
@Test func aCardBiggerThanTheScreenOnlyGetsTheBoardTheScreenShows() throws {
    let painter = DrawingPainter(canvas: .init(width: 1280, height: 832))
    DrawingSnapshot.adopt(painter.layer)
    let paper: JSONValue = ["do": "paper", "id": "m1", "step": 0, "at": [0, 0], "w": 100_000, "h": 100_000, "board": "dots",
                            "start": 0, "duration": 0.3]
    let started = Date()
    painter.apply(.marks([DrawingMark(paper)]))
    #expect(Date().timeIntervalSince(started) < 1)
    let container = try #require(painter.layer(forMark: "m1"))
    let board = try #require(find(container, "board") as? CAShapeLayer)
    let extent = try #require(board.path?.boundingBox)
    #expect(extent.maxX <= 1282 && extent.maxY <= 834)
}

/// The 2D engine ⇄ 3D contract end to end: the 3D milestone's figure-api.js loads into the real engine (sealed and
/// locked down), and the painter hands its marks to the live FigureStage.
@MainActor
@Test func figureProgramsRunInTheRealEngineAndReachTheLiveStage() async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/Drawing/3d/gear-train.js")
    let stage = FigureStage(drivesItself: false)
    var options = DrawingRehearsal.Options()
    options.backdrop = .none
    options.figureSink = stage
    let result = try DrawingRehearsal.run(program: try String(contentsOf: url, encoding: .utf8), options: options)
    #expect(result.host.loadedScripts.contains("figure-api.js"))
    #expect(result.errors.isEmpty, "\(result.errors)")
    #expect(result.warnings.isEmpty, "\(result.warnings)")
    #expect(result.finishedAt != nil)
    let figureMarks = result.events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
        .filter(\.isFigureMark)
    let figureID = try #require(figureMarks.first { $0.kind == "figure" }?.id)
    #expect(figureMarks.contains { $0.kind == "part3d" })
    let scene = try #require(stage.scene(figureID))
    #expect(scene.nodes.count >= 4) // the plate and three gears
    let layer = try #require(stage.layer(forFigure: figureID))
    #expect(layer.superlayer?.name == "main")
    #expect(layer.superlayer?.superlayer === result.painter.layer)
    // Nothing a figure program draws is painted as a 2D mark.
    #expect(result.painter.markIDs.allSatisfy { !(result.painter.entries[$0]?.mark.isFigureMark ?? true) })
    await stage.settle()
}
