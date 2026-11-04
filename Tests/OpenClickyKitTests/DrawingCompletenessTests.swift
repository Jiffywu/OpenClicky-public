import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import OpenClickyKit

// The drawing language's last pieces: a failing statement ends the program at its longest runnable prefix, the
// end-of-drawing report, onScreen(n) on a multi-display desktop, image() for a direct address and the same-page-once
// rule for photos.

private func host(_ clock: VirtualClock = VirtualClock()) throws -> DrawingEngineHost {
    try DrawingEngineHost(clock: { clock.now })
}

private func run(_ h: DrawingEngineHost, _ program: String, options: DrawingBeginOptions = DrawingBeginOptions(width: 1280, height: 832, pace: .now)) -> [DrawingEvent] {
    var events = h.perform(.begin(options))
    events += h.perform(.append(program + "\n"))
    events += h.perform(.end)
    events += h.perform(.drain)
    return events
}

private func marks(_ events: [DrawingEvent]) -> [DrawingMark] {
    events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
}
private func warnings(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .warning(let m) = $0 { m } else { nil } }
}
private func errors(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .error(let m, _) = $0 { m } else { nil } }
}
private func requests(_ events: [DrawingEvent]) -> [DrawingMediaRequest] { events.compactMap(DrawingMediaRequest.init(event:)) }

@Suite struct DrawingPrefixTests {
    static let failing = """
    step(1)
    say("Here is the server.")
    box(100, 100, 200, 100, {label: "Server"})
    step(2)
    say("It talks to the database.")
    (function () { circle(600, 150, 40); return missingHelper(); })()
    arrow([300, 150], [560, 150])
    say("And that is all.")
    dot(700, 400)
    """

    @Test func aFailingStatementEndsTheProgramAtItsLongestRunnablePrefix() throws {
        let h = try host()
        let events = run(h, Self.failing)
        #expect(errors(events).count == 1)
        #expect(errors(events).first?.contains("missingHelper") == true)
        #expect(warnings(events).contains { $0.contains("stopped at the statement that failed") })
        // The box (and its label) are drawn; the circle the failing statement made first, the arrow and the dot are not.
        let kinds = marks(events).map(\.kind)
        #expect(kinds.contains("box"))
        #expect(!kinds.contains("circle") && !kinds.contains("arrow") && !kinds.contains("dot"))
        // Every spoken line still counts, so the voice's numbering is unchanged.
        #expect(h.spokenLines() == ["Here is the server.", "It talks to the database.", "And that is all."])
    }

    @Test func continuingACutProgramReplaysExactlyWhatIsOnScreen() throws {
        let h = try host()
        let first = run(h, Self.failing)
        let kept = try #require(h.continueTurn())
        let code = try #require(kept["code"]?.stringValue)
        #expect(!code.contains("missingHelper") && !code.contains("dot(700, 400)"))
        #expect(code.contains("__turn(2, "))
        let replay = try host()
        let again = run(replay, code)
        #expect(errors(again).isEmpty, "\(errors(again))")
        let shown = marks(first).map { "\($0.id):\($0.kind)" }
        let replayed = marks(again).map { "\($0.id):\($0.kind)" }
        #expect(replayed == shown)
    }

    @Test func syntaxErrorsAndTimeLimitsCutTooAndSkippingIsAnOption() throws {
        let broken = run(try host(), "dot(10, 10)\nbox(10, 10,, 20)\ndot(20, 20)")
        #expect(errors(broken).count == 1)
        #expect(marks(broken).map(\.kind) == ["dot"])

        var limited = DrawingBeginOptions(width: 1280, height: 832, pace: .now, timeLimit: 0.15)
        let spun = run(try host(), "dot(10, 10)\nwhile (true) {}\ndot(20, 20)", options: limited)
        #expect(errors(spun).count == 1)
        #expect(marks(spun).map(\.kind) == ["dot"])

        limited.continuesAfterErrors = true
        let skipped = run(try host(), "dot(10, 10)\nnope()\ndot(20, 20)", options: limited)
        #expect(errors(skipped).count == 1)
        #expect(marks(skipped).map(\.kind) == ["dot", "dot"])
        #expect(!warnings(skipped).contains { $0.contains("stopped at the statement") })
    }
}

@Suite struct DrawingReportTests {
    @Test func theEndOfDrawingReportNamesOffCanvasAndOverlappingWords() throws {
        let clock = VirtualClock()
        let h = try host(clock)
        var events = run(h, """
        line([1100, 200], [1400, 200])
        text(100, 400, "Overlapping words", {size: 28, place: false})
        text(110, 405, "Sitting on top", {size: 28, place: false})
        box(300, 600, 200, 80)
        """)
        // Nothing is reported until the drawing is done.
        #expect(h.report().isEmpty)
        clock.now += 10
        events += h.perform(.drain)
        #expect(events.contains(.done))
        let said = warnings(events)
        #expect(said.contains { $0.hasPrefix("line ") && $0.contains("runs off the right") })
        #expect(said.contains { $0.contains("overlap") && $0.contains("Overlapping words") && $0.contains("Sitting on top") })
        #expect(h.report().count == 2)
        // A follow-up turn is shown the problems with the card.
        let text = h.describe(drawnOnly: true, maxCharacters: 12_000)
        #expect(text.contains("Problems in this drawing"))
        #expect(text.contains("runs off the right"))
        // A clean drawing has no report.
        let cleanClock = VirtualClock()
        let clean = try host(cleanClock)
        var quiet = run(clean, "box(100, 100, 200, 100, {label: \"Fine\"})")
        cleanClock.now += 10
        quiet += clean.perform(.drain)
        #expect(quiet.contains(.done))
        #expect(!warnings(quiet).contains { $0.contains("canvas") || $0.contains("overlap") })
        #expect(clean.report().isEmpty)
        #expect(!clean.describe(drawnOnly: true, maxCharacters: 12_000).contains("Problems"))
    }
}

@Suite struct DrawingScreenChoiceTests {
    @Test func theDirectiveIsReadFromTheStartOfTheProgram() {
        typealias D = DrawingScreenDirective
        #expect(D.scan("") == .undecided)
        #expect(D.scan("  // which screen\n") == .undecided)
        #expect(D.scan("onScr") == .undecided)
        #expect(D.scan("onScreen(") == .undecided)
        #expect(D.scan("onScreen( 2") == .undecided)
        #expect(D.scan("onScreen(2)") == .screen(2))
        #expect(D.scan("/* the left one */ onScreen( 2 )\nbox(1,2,3,4)") == .screen(2))
        #expect(D.scan("step(1)\nonScreen(2)") == .none)
        #expect(D.scan("box(1, 2, 3, 4)") == .none)
        #expect(D.scan("onScreen(0)") == .none)
        #expect(D.scan("onScreenX(2)") == .none)
        #expect(D.scan("onScr", complete: true) == .none)
        #expect(D.scan("onScreen(2", complete: true) == .none)
    }

    @Test func theEngineChecksOnScreenAgainstTheScreenItWasGiven() throws {
        var options = DrawingBeginOptions(width: 1280, height: 832, pace: .now)
        options.screen = 2
        let fine = run(try host(), "onScreen(2)\ndot(10, 10)", options: options)
        #expect(warnings(fine).isEmpty && errors(fine).isEmpty)
        let wrong = run(try host(), "onScreen(3)\ndot(10, 10)", options: options)
        #expect(warnings(wrong).contains { $0.contains("no screenshot 3") })
        let late = run(try host(), "dot(10, 10)\nonScreen(2)", options: DrawingBeginOptions(width: 1280, height: 832, pace: .now))
        #expect(warnings(late).contains { $0.contains("goes first") })
        #expect(marks(late).map(\.kind) == ["dot"])
    }

    /// One offscreen canvas per display, like the overlay: a drawing goes to the canvas of the display its screenshot shows.
    @MainActor
    final class TwoDisplaySurfaces: TurnDrawingSurfaces {
        var canvases: [String: CanvasDrawingSurfaces] = [:]
        private(set) var started: [TurnScreenshot] = []
        /// Marks released by the drawings, with the display they were drawn on.
        private(set) var released: [(display: String, mark: DrawingMark)] = []

        private func watch(_ drawing: (any TurnDrawing)?, _ screenshot: TurnScreenshot) -> (any TurnDrawing)? {
            let key = Self.key(screenshot)
            drawing?.onMarks = { [weak self] marks in self?.released += marks.map { (key, $0) } }
            return drawing
        }

        func surfaces(for screenshot: TurnScreenshot) -> CanvasDrawingSurfaces {
            if let existing = canvases[Self.key(screenshot)] { return existing }
            let made = CanvasDrawingSurfaces()
            canvases[Self.key(screenshot)] = made
            return made
        }

        func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
            started.append(screenshot)
            return watch(surfaces(for: screenshot).drawing(for: screenshot, image: image), screenshot)
        }

        func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)? {
            started.append(screenshot)
            guard let (drawing, keep) = surfaces(for: screenshot).continuingDrawing(for: screenshot, image: image) else { return nil }
            _ = watch(drawing, screenshot)
            return (drawing, keep)
        }

        func describeOnScreen(for screenshot: TurnScreenshot) -> String? {
            canvases[Self.key(screenshot)]?.describeOnScreen(for: screenshot)
        }

        var hasVisibleDrawing: Bool { canvases.values.contains { $0.hasVisibleDrawing } }
        static func key(_ shot: TurnScreenshot) -> String { "\(shot.displayFrame)" }
        func clearAll() { canvases.values.forEach { $0.clearAll() } }
    }

    /// Two displays: the pointer's (1440×900 points, 1280×800 pixels) and one to its right (1920×1080 points, 1280×720 pixels).
    @MainActor
    final class TwoScreens: TurnScreenLooking {
        static var left: TurnScreenshot { TurnScreenshot(jpeg: StillImageScreen.blankCanvas(width: 1280, height: 800), label: "main display", isCursorScreen: true,
                                         pixelSize: CGSize(width: 1280, height: 800), displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)) }
        static var right: TurnScreenshot { TurnScreenshot(jpeg: StillImageScreen.blankCanvas(width: 1280, height: 720), label: "display 2 (right)", isCursorScreen: false,
                                          pixelSize: CGSize(width: 1280, height: 720), displayFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)) }
        var cursorOnRight = false

        func prefetch() {}
        func cancelPrefetch() {}
        func look() async -> TurnScreenLook {
            var left = Self.left, right = Self.right
            left.isCursorScreen = !cursorOnRight
            right.isCursorScreen = cursorOnRight
            return TurnScreenLook(screenshots: [left, right], context: TurnContext(frontApp: "Finder"))
        }
    }

    @MainActor
    @Test func onScreenDrawsOnTheNamedDisplayInItsOwnPixels() async throws {
        let program = "onScreen(2)\nbox(100, 50, 200, 100, {name: \"panel\"})\n"
        let steps = [ScriptedBrain.Step(delay: 0.01, event: .programDelta("onScr")),
                     ScriptedBrain.Step(delay: 0.01, event: .programDelta(String(program.dropFirst(5)))),
                     ScriptedBrain.Step(delay: 0.01, event: .finished(TurnSummary(program: program, spokenLines: [], rounds: 1, usage: nil,
                                                                                   model: "scripted", firstTokenSeconds: 0, totalSeconds: 0)))]
        let rig = VoiceLoopRig(scripts: [steps])
        let screens = TwoScreens()
        let surfaces = TwoDisplaySurfaces()
        rig.orchestrator.services.screen = screens
        rig.orchestrator.services.drawings = surfaces
        var log: [String] = []
        rig.orchestrator.onLog = { log.append($0) }
        rig.orchestrator.submitTyped("draw it on the other screen")
        #expect(await rig.waitForRecords(1))
        // The drawing went to the right-hand display, sized to its screenshot.
        #expect(surfaces.started.map(\.label) == ["display 2 (right)"])
        let right = try #require(surfaces.canvases[TwoDisplaySurfaces.key(TwoScreens.right)])
        #expect(surfaces.canvases[TwoDisplaySurfaces.key(TwoScreens.left)] == nil)
        let session = try #require(right.session)
        #expect(await waitUntil { !session.isDrawing })
        #expect(session.painter.canvas.width == 1280 && session.painter.canvas.height == 720)
        #expect(log.contains { $0.contains("onScreen(2) draws on the display 2 (right)") })
        // The box's corner (100, 50) in that screenshot's pixels is at 1440 + 100 × 1.5, 50 × 1.5 on the desktop.
        let text = try #require(right.describeOnScreen())
        #expect(text.contains("\"panel\"") && text.contains("box"))
        let box = try #require(surfaces.released.first { $0.mark.kind == "box" })
        #expect(box.display == TwoDisplaySurfaces.key(TwoScreens.right))
        let at = box.mark.json["at"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        #expect(at == [100, 50])
        let corner = DrawingScreenDirective.globalPoint(CGPoint(x: 100, y: 50), on: TwoScreens.right)
        #expect(corner == CGPoint(x: 1590, y: 75))
        // The history keeps the canvas it was drawn on.
        #expect(rig.records.first?.history?.canvas == HistoryCanvas(width: 1280, height: 720))
    }

    @MainActor
    @Test func aFollowUpIsShownTheDrawingOnItsOwnScreenAndContinuesItThere() async throws {
        let first = "onScreen(2)\nbox(100, 50, 200, 100, {name: \"panel\"})\n"
        let second = "recolor(\"panel\", \"red\")\n"
        func script(_ program: String) -> [ScriptedBrain.Step] {
            [ScriptedBrain.Step(delay: 0.01, event: .programDelta(program)),
             ScriptedBrain.Step(delay: 0.01, event: .finished(TurnSummary(program: program, spokenLines: [], rounds: 1, usage: nil,
                                                                           model: "scripted", firstTokenSeconds: 0, totalSeconds: 0)))]
        }
        let rig = VoiceLoopRig(scripts: [script(first), script(second)])
        let screens = TwoScreens()
        let surfaces = TwoDisplaySurfaces()
        rig.orchestrator.services.screen = screens
        rig.orchestrator.services.drawings = surfaces
        rig.orchestrator.submitTyped("draw it on the other screen")
        #expect(await rig.waitForRecords(1))
        let right = try #require(surfaces.canvases[TwoDisplaySurfaces.key(TwoScreens.right)]?.session)
        #expect(await waitUntil { !right.isDrawing })

        // The pointer is still on the left display: the follow-up's canvas is the right one, where the drawing is.
        rig.orchestrator.submitTyped("make it red")
        #expect(await rig.waitForRecords(2))
        let input = try #require(rig.brain.inputs.last)
        #expect(input.canvasIndex == 1)
        #expect(input.context.drawingOnScreen?.contains("\"panel\"") == true)
        #expect(BrainTurnNotes.canvasScreenshot(for: input)?.label == "display 2 (right)")
        let notes = BrainTurnNotes.notes(for: input)
        #expect(notes.contains("Canvas: W = 1280, H = 720: screenshot 2, the display 2 (right), where your drawing is"))
        #expect(notes.contains("1: main display 1280×800"))
        // The follow-up continued the same drawing on the right display; the left one never got a canvas.
        #expect(surfaces.started.map(\.label) == ["display 2 (right)", "display 2 (right)"])
        #expect(surfaces.canvases[TwoDisplaySurfaces.key(TwoScreens.left)] == nil)
        #expect(await waitUntil { !right.isDrawing })
        let after = try #require(surfaces.canvases[TwoDisplaySurfaces.key(TwoScreens.right)]?.describeOnScreen())
        #expect(after.contains("\"panel\""))
    }
}

/// Lookups for image() that hand back a fixed picture and count addresses.
private final class AddressLookups: DrawingMediaLookups, @unchecked Sendable {
    let lock = NSLock()
    var addresses: [URL] = []

    func photo(_ query: PhotoQuery) async throws -> DrawingPhoto { throw DrawingMediaError.noUsablePhoto }
    func place(_ query: PlaceQuery) async throws -> Place { throw LookupError.notFound("none") }
    func map(around coordinate: PlaceCoordinate, size: CGSize) async -> DrawingMediaImage? { nil }
    func quote(symbol: String, range: QuoteRange) async throws -> MarketQuote { throw LookupError.notFound("none") }
    func favicon(host: String) async throws -> DrawingMediaImage { throw DrawingMediaError.notPublic }
    func image(at url: URL) async throws -> DrawingMediaImage {
        lock.withLock { addresses.append(url) }
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(DrawingColor(hex: "#2E9E5B")!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return DrawingMediaImage(context.makeImage()!)
    }
}

@Suite struct DrawingImageTests {
    @Test func imageShowsADirectAddressOnceAndRefusesOthers() throws {
        let events = run(try host(), """
        image(40, 40, 300, 200, "https://upload.example.org/pictures/bridge.jpg", {alt: "The bridge"})
        image(400, 40, 300, 200, "https://upload.example.org/pictures/bridge.jpg")
        image(40, 300, 100, 100, "http://upload.example.org/plain.jpg")
        image(40, 300, 100, 100, "Golden Gate Bridge")
        """)
        let asked = requests(events)
        #expect(asked.map(\.kind) == [.image])
        #expect(asked.first?.url?.absoluteString == "https://upload.example.org/pictures/bridge.jpg")
        let shown = marks(events).filter { $0.kind == "image" }
        #expect(shown.count == 1)
        #expect(shown.first?.json["state"]?.stringValue == "loading")
        #expect(shown.first?.json["text"]?.stringValue == "The bridge")
        let said = warnings(events)
        #expect(said.contains { $0.contains("shown once per drawing") })
        #expect(said.filter { $0.contains("direct https address") }.count == 1)
    }

    @Test func theSamePageGivesOnePhotoAndTheNextLooksItsSubjectUp() throws {
        let events = run(try host(), """
        photo(40, 40, 260, 200, "Swift", "Swift", {page: "https://www.swift.org/blog/"})
        photo(340, 40, 260, 200, "Swift logo", "Again", {page: "https://www.swift.org/blog/#top"})
        photo(640, 40, 260, 200, "https://www.swift.org/blog/")
        """)
        let asked = requests(events)
        #expect(asked.count == 2)
        #expect(asked[0].query == "page: https://www.swift.org/blog/ :: Swift")
        #expect(asked[1].query == "Swift logo")
        #expect(warnings(events).filter { $0.contains("each page is shown once") }.count == 2)
    }

    @MainActor
    @Test func imageRequestsResolveThroughTheGuardedLoaderAndPaint() async throws {
        let request = try #require(DrawingMediaRequest(ref: "q1", mark: "m1", json: ["kind": "image", "url": "https://upload.example.org/a.png"]))
        #expect(request.cacheKey == "image|https://upload.example.org/a.png")
        #expect(DrawingMediaRequest(ref: "q2", mark: "m2", json: ["kind": "image", "url": "http://upload.example.org/a.png"]) == nil)
        let lookups = AddressLookups()
        let answer = await request.resolve(with: lookups)
        #expect(answer.isReady)
        #expect(answer.fields["source"]?.stringValue == "upload.example.org")
        #expect(lookups.addresses.map(\.absoluteString) == ["https://upload.example.org/a.png"])
        // A private address never reaches the lookups.
        let local = try #require(DrawingMediaRequest(ref: "q3", mark: "m3", json: ["kind": "image", "url": "https://192.168.1.4/a.png"]))
        #expect(await local.resolve(with: lookups).fields["state"]?.stringValue == "failed")
        #expect(lookups.addresses.count == 1)

        // Painted: the picture fills its rounded box.
        var options = DrawingRehearsal.Options()
        options.width = 400
        options.height = 300
        options.backdrop = .color("#FFFFFF")
        let media = DrawingRehearsalMedia(store: DrawingMediaStore(), answers: ["image|https://upload.example.org/a.png": answer.fields])
        for (key, image) in answer.images { media.store.put(image, for: key) }
        options.media = media
        let result = try DrawingRehearsal.run(program: "image(50, 50, 300, 200, \"https://upload.example.org/a.png\")", options: options)
        let middle = DrawingSnapshot.pixel(result.image, x: 200, y: 150)
        #expect(middle.g > 120 && middle.r < 90, "\(middle)")
    }
}
