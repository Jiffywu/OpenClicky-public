import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// A folder in the temporary directory, removed when the test's scope ends.
final class HomeTemporaryFolder: @unchecked Sendable {
    let url: URL

    init(_ label: String = "home") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-\(label)-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A clock the history tests can move in whole milliseconds (the history stores milliseconds).
final class HomeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    /// 2026-10-31T09:00:00Z.
    init(_ start: Date = Date(timeIntervalSince1970: 1_793_437_200)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

enum HomeHistoryFixtures {
    static func turn(_ id: String, session: String, at date: Date, words: String, lines: [String], program: String? = nil,
                     source: HistoryTurnSource = .voice) -> HistoryTurn {
        HistoryTurn(id: id, sessionID: session, startedAt: date, source: source, words: words, appNotes: ["[App] the last drawing finished"],
                    frontApp: "Safari", spokenLines: lines, program: program, canvas: program == nil ? nil : HistoryCanvas(width: 1512, height: 982),
                    statuses: ["Searching the web"], tools: ["web_search"], deferredActions: ["open_url"], model: "claude-haiku-5-5",
                    rounds: 2, usage: HistoryUsage(input: 1200, cached: 800, output: 90),
                    timings: HistoryTimings(firstEventMs: 410, firstProgramMs: 520, firstLineMs: 640, modelFirstTokenMs: 380, totalMs: 2100))
    }
}

@Test func historyRoundTripsTurnsExactly() throws {
    let folder = HomeTemporaryFolder("history")
    let clock = HomeClock()
    let store = HistoryStore(directory: folder.url, now: clock.function)
    let first = HomeHistoryFixtures.turn("t1", session: "s1", at: clock.now, words: "What's this chart showing?",
                                         lines: ["It's revenue by month.", "March is the outlier."],
                                         program: "step(1)\nsay(\"It's revenue by month.\")\nbox(10, 10, 100, 100)")
    clock.advance(30.25)
    let second = HomeHistoryFixtures.turn("t2", session: "s1", at: clock.now, words: "Why March?", lines: ["A one-off order."], source: .text)
    try store.append(first)
    try store.append(second)

    // A fresh store reads the same records from disk.
    let reread = HistoryStore(directory: folder.url)
    #expect(try reread.turns(in: "s1") == [first, second])
    let session = try #require(reread.session("s1"))
    #expect(session.turnCount == 2)
    #expect(session.title == "What's this chart showing?")
    #expect(session.preview == "A one-off order.")
    #expect(session.drawingCount == 1)
    #expect(session.updatedAt == second.startedAt)
}

@Test func historyFileIsJSONLinesWithAHeader() throws {
    let folder = HomeTemporaryFolder("history")
    let clock = HomeClock()
    let store = HistoryStore(directory: folder.url, now: clock.function)
    try store.startSession(id: "abc")
    try store.append(HomeHistoryFixtures.turn("t1", session: "abc", at: clock.now, words: "Hi", lines: ["Hello."]))
    try store.recordNarration("cut off by the user after line 1", forTurn: "t1", in: "abc")
    let text = try String(contentsOf: folder.url.appendingPathComponent("sessions/abc.jsonl"), encoding: .utf8)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    let header = try JSONValue.parse(lines[0])
    #expect(header["kind"]?.stringValue == "session")
    #expect(header["version"]?.intValue == 1)
    #expect(header["at"]?.stringValue == "2026-10-31T09:00:00.000Z")
    let turn = try JSONValue.parse(lines[1])
    #expect(turn["kind"]?.stringValue == "turn")
    #expect(turn["turn"]?["lines"]?.arrayValue?.first?.stringValue == "Hello.")
    #expect(turn["turn"]?["session"]?.stringValue == "abc")
    let narration = try JSONValue.parse(lines[2])
    #expect(narration["turn"]?.stringValue == "t1")
    #expect(try store.turns(in: "abc").first?.narration == "cut off by the user after line 1")
}

@Test func historySkipsDamagedLinesAndKeepsAppending() throws {
    let folder = HomeTemporaryFolder("history")
    let clock = HomeClock()
    let store = HistoryStore(directory: folder.url, now: clock.function)
    try store.append(HomeHistoryFixtures.turn("t1", session: "s", at: clock.now, words: "One", lines: ["1."]))
    // A crash mid-write leaves half a line with no newline.
    let url = folder.url.appendingPathComponent("sessions/s.jsonl")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"kind\":\"turn\",\"turn\":{\"id\":\"bro".utf8))
    try handle.close()
    clock.advance(5)
    try store.append(HomeHistoryFixtures.turn("t2", session: "s", at: clock.now, words: "Two", lines: ["2."]))
    #expect(try store.turns(in: "s").map(\.id) == ["t1", "t2"])
    #expect(store.damagedLineCount(in: "s") == 1)
}

@Test func historyListsSessionsNewestFirstAndRebuildsAMissingIndex() throws {
    let folder = HomeTemporaryFolder("history")
    let clock = HomeClock()
    let store = HistoryStore(directory: folder.url, now: clock.function)
    try store.append(HomeHistoryFixtures.turn("a1", session: "older", at: clock.now, words: "First chat", lines: ["Sure."]))
    clock.advance(3600)
    try store.append(HomeHistoryFixtures.turn("b1", session: "newer", at: clock.now, words: "Second chat", lines: ["Okay."]))
    #expect(store.sessions().map(\.id) == ["newer", "older"])

    try FileManager.default.removeItem(at: folder.url.appendingPathComponent("index.json"))
    let rebuilt = HistoryStore(directory: folder.url)
    #expect(rebuilt.sessions().map(\.id) == ["newer", "older"])
    #expect(rebuilt.sessions().first?.title == "Second chat")
    #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("index.json").path))

    // An index that disagrees with the files (a session file copied in by hand) is rebuilt too.
    let extra = folder.url.appendingPathComponent("sessions/copied.jsonl")
    try FileManager.default.copyItem(at: folder.url.appendingPathComponent("sessions/older.jsonl"), to: extra)
    #expect(Set(HistoryStore(directory: folder.url).sessions().map(\.id)).count == 2, "a copy with another session's header is skipped")
}

@Test func historyRecentTurnsDrawingsAndSearch() throws {
    let folder = HomeTemporaryFolder("history")
    let clock = HomeClock()
    let store = HistoryStore(directory: folder.url, now: clock.function)
    let program = "box(1, 2, 3, 4)"
    try store.append(HomeHistoryFixtures.turn("t1", session: "s1", at: clock.now, words: "Draw a box", lines: ["Here."], program: program))
    clock.advance(60)
    try store.append(HomeHistoryFixtures.turn("t2", session: "s2", at: clock.now, words: "Draw it again", lines: ["Again."], program: program))
    clock.advance(60)
    try store.append(HomeHistoryFixtures.turn("t3", session: "s2", at: clock.now, words: "Explain the café menu", lines: ["It lists drinks."]))

    #expect(store.recentTurns(limit: 2).map(\.id) == ["t3", "t2"])
    #expect(store.recentTurns(limit: 10).map(\.id) == ["t3", "t2", "t1"])
    // The same program twice shows once, the newest.
    let drawings = store.recentDrawings(limit: 10)
    #expect(drawings.map(\.turnID) == ["t2"])
    #expect(drawings.first?.title == "Draw it again")
    #expect(drawings.first?.canvas == HistoryCanvas(width: 1512, height: 982))
    #expect(store.search("CAFE menu").map(\.id) == ["t3"])
    #expect(store.search("drinks").map(\.id) == ["t3"])
    #expect(store.search("nothing like this").isEmpty)

    try store.deleteSession("s2")
    #expect(store.sessions().map(\.id) == ["s1"])
    #expect(store.recentDrawings(limit: 5).map(\.turnID) == ["t1"])
    try store.deleteAll()
    #expect(store.sessions().isEmpty)
}

@Test func historyNotifiesFollowers() async throws {
    let folder = HomeTemporaryFolder("history")
    let store = HistoryStore(directory: folder.url)
    let changes = store.changes()
    try store.append(HomeHistoryFixtures.turn("t1", session: "s", at: Date(), words: "Hi", lines: ["Hello."]))
    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() == .turnAppended(sessionID: "s", turnID: "t1"))
}

@Test func historySessionIDsCannotEscapeTheFolder() {
    #expect(HistoryStore.safeName("../../etc/passwd") == "_.._etc_passwd")
    #expect(HistoryStore.safeName("") == "session")
    #expect(HistoryStore.safeName("A1-b_2.c") == "A1-b_2.c")
}

@Test func turnLogBuilderFoldsTheEventStream() {
    let clock = HomeClock()
    let screen = TurnScreenshot(jpeg: Data(), label: "main display", isCursorScreen: true, pixelSize: CGSize(width: 2940, height: 1912),
                                displayFrame: CGRect(x: 0, y: 0, width: 1470, height: 956))
    let input = TurnInput(words: "  Where's the export button? ", screenshots: [screen],
                          context: TurnContext(frontApp: "Keynote"), appNotes: ["[App] the user cut the last answer off"])
    var log = TurnLogBuilder(input: input, sessionID: "s", id: "t", clock: clock.function)
    clock.advance(0.2)
    log.apply(.status("Looking at Keynote"))
    clock.advance(0.1)
    log.apply(.programDelta("step(1)\nsay(\"Up here\")\n"))
    clock.advance(0.15)
    log.apply(.sayLine(index: 0, text: "It's in the File menu, up here."))
    log.apply(.toolStarted(name: "point_at", callID: "c1"))
    log.apply(.toolFinished(name: "point_at", callID: "c1", succeeded: true))
    log.apply(.deferredAction(DeferredAction(callID: "c2", name: "open_url", arguments: [:])))
    log.apply(.programDelta("arrow(10, 10, 50, 50)"))
    log.apply(.sayLine(index: 1, text: "Then choose Export."))
    log.apply(.roundFinished(1))
    clock.advance(1.05)
    log.apply(.finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: TokenUsage(inputTokens: 900, cachedInputTokens: 0, outputTokens: 60),
                                    model: "claude-haiku-5-5", firstTokenSeconds: 0.27, totalSeconds: 1.5)))
    let turn = log.finish(narration: "completed")
    #expect(turn.words == "Where's the export button?")
    #expect(turn.source == .voice)
    #expect(turn.frontApp == "Keynote")
    #expect(turn.appNotes == ["[App] the user cut the last answer off"])
    #expect(turn.canvas == HistoryCanvas(width: 1470, height: 956))
    #expect(turn.spokenLines == ["It's in the File menu, up here.", "Then choose Export."])
    #expect(turn.program == "step(1)\nsay(\"Up here\")\narrow(10, 10, 50, 50)")
    #expect(turn.statuses == ["Looking at Keynote"])
    #expect(turn.tools == ["point_at"])
    #expect(turn.deferredActions == ["open_url"])
    #expect(turn.outcome == .completed)
    #expect(turn.usage == HistoryUsage(input: 900, cached: 0, output: 60))
    #expect(turn.timings == HistoryTimings(firstEventMs: 200, firstProgramMs: 300, firstLineMs: 450, modelFirstTokenMs: 270, totalMs: 1500))
    #expect(turn.narration == "completed")
}

@Test func turnLogBuilderRecordsFailuresAndCancellations() {
    let clock = HomeClock()
    var failed = TurnLogBuilder(input: TurnInput(words: "hi", isTyped: true), sessionID: "s", clock: clock.function)
    failed.apply(.failed(spoken: "I couldn't reach the model.", detail: "HTTP 529"))
    let failure = failed.finish()
    #expect(failure.source == .text)
    #expect(failure.outcome == .failed)
    #expect(failure.replyText == "I couldn't reach the model.")
    #expect(failure.errorDetail == "HTTP 529")

    var cancelled = TurnLogBuilder(input: TurnInput(words: "", context: TurnContext(trigger: "job_report")), sessionID: "s", clock: clock.function)
    cancelled.apply(.sayLine(index: 0, text: "Your report is"))
    clock.advance(0.5)
    let cut = cancelled.finish()
    #expect(cut.source == .app)
    #expect(cut.trigger == "job_report")
    #expect(cut.outcome == .cancelled)
    #expect(cut.timings.totalMs == 500)
    #expect(cut.program == nil)
}

@Test func historyDecodesRecordsWithMissingFields() throws {
    let json = """
    {"id":"x","session":"s","at":"2026-10-31T09:00:00.000Z","words":"hey"}
    """
    let turn = try HistoryStore.decoder().decode(HistoryTurn.self, from: Data(json.utf8))
    #expect(turn.spokenLines.isEmpty)
    #expect(turn.outcome == .completed)
    #expect(turn.source == .voice)
    #expect(turn.timings == HistoryTimings())
}

@MainActor
@Test func thumbnailsRenderSavedProgramsWithTheDrawingEngineAndCacheThem() async throws {
    let folder = HomeTemporaryFolder("thumbs")
    let thumbnailer = DrawingThumbnailer(cacheDirectory: folder.url, pixelWidth: 320)
    let program = "box(200, 200, 600, 300, { tone: \"#E5484D\", fill: \"#E5484D\", fillAlpha: 1, glow: false })"
    let image = try thumbnailer.thumbnail(for: program, canvas: HistoryCanvas(width: 1280, height: 832))
    #expect(image.width == 320)
    #expect(image.height == 208)
    // The box's middle (x 500, y 350 on the canvas) is red at a quarter scale.
    let pixel = DrawingSnapshot.pixel(image, x: 125, y: 87)
    #expect(pixel.r > 150 && pixel.g < 140 && pixel.b < 140)
    let cached = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
    #expect(cached.count == 1 && cached[0].hasSuffix(".png"))
    await Task.yield()
    // A second thumbnailer reads the PNG instead of rendering.
    let again = try DrawingThumbnailer(cacheDirectory: folder.url, pixelWidth: 320).thumbnail(for: program, canvas: HistoryCanvas(width: 1280, height: 832))
    #expect(again.width == 320)
    #expect(DrawingThumbnailer.clamped(HistoryCanvas(width: 0, height: 0)) == DrawingThumbnailer.defaultCanvas)
    #expect(DrawingThumbnailer.clamped(HistoryCanvas(width: 6016, height: 3384)).width == 1920)
}

// MARK: - Saved drawings (lessons)

enum LessonFixtures {
    static let program = """
    step(1)
    say("Here is the panel.")
    box(200, 200, 600, 300, { tone: "#E5484D", fill: "#E5484D", fillAlpha: 1, glow: false })
    step(2)
    say("And its title.")
    text(240, 260, "Settings", {size: 40})
    """

    /// A solid-colour JPEG screenshot.
    static func screenshot(_ hex: String, width: Int = 1280, height: Int = 832) -> TurnScreenshot {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(DrawingColor(hex: hex)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let jpeg = try! ImageCoding.jpegData(context.makeImage()!, quality: 0.9)
        return TurnScreenshot(jpeg: jpeg, label: "main display", isCursorScreen: true, pixelSize: CGSize(width: width, height: height),
                              displayFrame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func turn(_ id: String = "turn-lesson", at date: Date = Date(timeIntervalSince1970: 1_793_437_200)) -> HistoryTurn {
        HistoryTurn(id: id, sessionID: "s-lessons", startedAt: date, source: .voice, words: "What is this panel?",
                    spokenLines: ["Here is the panel.", "And its title."], program: program, canvas: HistoryCanvas(width: 1280, height: 832))
    }
}

@MainActor
@Test func aLessonFolderKeepsTheScreenshotPosterAndLessonJSON() throws {
    let folder = HomeTemporaryFolder("lessons")
    let history = HistoryStore(directory: folder.url)
    let turn = LessonFixtures.turn()
    try history.append(turn)
    let draft = DrawingLessonDraft(screenshot: LessonFixtures.screenshot("#1E6FD9"),
                                   lines: [DrawingLesson.Line(index: 0, text: "Here is the panel.", start: 0.8, duration: 1.6),
                                           DrawingLesson.Line(index: 1, text: "And its title.", start: 2.7, duration: 1.2)])
    let store = DrawingLessonStore(historyDirectory: folder.url)
    let saved = try #require(try DrawingLessonRecorder.record(draft, turn: turn, store: store))
    #expect(saved == store.folder(for: turn.id))
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: saved.path))
    #expect(files == ["lesson.json", "screenshot.jpg", "poster.png"])

    // lesson.json round trip.
    let lesson = try #require(store.load(turn.id))
    #expect(lesson.turnID == turn.id && lesson.sessionID == "s-lessons")
    #expect(lesson.program == LessonFixtures.program)
    #expect(lesson.canvas == HistoryCanvas(width: 1280, height: 832))
    #expect(lesson.lines == draft.lines)
    #expect(lesson.screenshot == "screenshot.jpg" && lesson.poster == "poster.png" && lesson.screen == "main display")
    #expect(lesson.createdAt == turn.startedAt)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.appendingPathComponent("lesson.json"))) as? [String: Any]
    #expect(json?["program"] as? String == LessonFixtures.program)
    #expect((json?["lines"] as? [[String: Any]])?.first?["start"] as? Double == 0.8)
    // Recorded line times drive the replay; untimed lines follow at a speaking rate.
    let schedule = lesson.schedule(lead: 0.4)
    #expect(abs(schedule[0].start - 0.4) < 0.001 && abs(schedule[1].start - 2.3) < 0.001 && abs(schedule[1].end - 3.5) < 0.001)
    var untimed = lesson
    untimed.lines = lesson.lines.map { DrawingLesson.Line(index: $0.index, text: $0.text) }
    #expect(untimed.schedule()[1].start > untimed.schedule()[0].end)

    // The stored screenshot decodes at its full size.
    let stored = try #require(store.screenshot(turn.id))
    #expect(stored.width == 1280)
    // The history lists the drawing with its lesson folder.
    let drawing = try #require(history.recentDrawings(limit: 5).first)
    #expect(drawing.lessonFolder == saved)
    try store.delete(turn.id)
    #expect(!store.exists(turn.id))
}

@MainActor
@Test func aSavedDrawingsThumbnailIsDrawnOverItsStoredScreenshot() throws {
    let folder = HomeTemporaryFolder("lesson-thumbs")
    let history = HistoryStore(directory: folder.url)
    let turn = LessonFixtures.turn()
    try history.append(turn)
    let thumbnailer = DrawingThumbnailer(cacheDirectory: folder.path("thumbnails"), pixelWidth: 320)
    // Without a lesson: the plain light card around the drawing.
    let plain = try thumbnailer.thumbnail(for: try #require(history.recentDrawings(limit: 1).first))
    let plainCorner = DrawingSnapshot.pixel(plain, x: 8, y: 8)
    #expect(plainCorner.r > 200 && plainCorner.g > 200 && plainCorner.b > 200, "\(plainCorner)")

    let draft = DrawingLessonDraft(screenshot: LessonFixtures.screenshot("#1E6FD9"), lines: [])
    try DrawingLessonRecorder.record(draft, turn: turn, store: DrawingLessonStore(historyDirectory: folder.url))
    let drawing = try #require(history.recentDrawings(limit: 1).first)
    #expect(drawing.lessonFolder != nil)
    let image = try thumbnailer.thumbnail(for: drawing)
    #expect(image.width == 320 && image.height == 208)
    // The corner shows the stored screenshot (blue); the panel's middle is still the drawing's red.
    let corner = DrawingSnapshot.pixel(image, x: 8, y: 8)
    #expect(corner.b > 160 && corner.r < 90, "\(corner)")
    let middle = DrawingSnapshot.pixel(image, x: 125, y: 87)
    #expect(middle.r > 150 && middle.b < 140, "\(middle)")
}

@MainActor
@Test func deletingAConversationRemovesItsLessonsScreenshotsAndLessonThumbnails() throws {
    let folder = HomeTemporaryFolder("lesson-delete")
    let history = HistoryStore(directory: folder.url)
    let store = DrawingLessonStore(historyDirectory: folder.url)
    let turn = LessonFixtures.turn()
    var other = LessonFixtures.turn("turn-kept")
    other.sessionID = "s-other"
    other.program = LessonFixtures.program.replacingOccurrences(of: "Settings", with: "General")
    try history.append(turn)
    try history.append(other)
    let draft = DrawingLessonDraft(screenshot: LessonFixtures.screenshot("#1E6FD9"), lines: [])
    try DrawingLessonRecorder.record(draft, turn: turn, store: store)
    try DrawingLessonRecorder.record(draft, turn: other, store: store)
    // The app's thumbnail cache sits in <history>/thumbnails.
    let thumbnailer = DrawingThumbnailer(cacheDirectory: folder.path("thumbnails"), pixelWidth: 160)
    for drawing in history.recentDrawings(limit: 5) { _ = try thumbnailer.thumbnail(for: drawing) }
    let lessonThumbs = { (turnID: String) in
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path("thumbnails").path)) ?? [])
            .filter { $0.hasSuffix("-lesson-\(turnID).png") }
    }
    #expect(lessonThumbs(turn.id).count == 1 && lessonThumbs(other.id).count == 1)

    try history.deleteSession(turn.sessionID)
    // The deleted conversation's screenshot, poster and lesson.json are gone, and so is its screenshot thumbnail.
    #expect(!FileManager.default.fileExists(atPath: store.folder(for: turn.id).path))
    #expect(lessonThumbs(turn.id).isEmpty)
    // Other conversations keep theirs.
    #expect(store.exists(other.id))
    #expect(lessonThumbs(other.id).count == 1)
    #expect(store.all().map(\.turnID) == [other.id])
}

@MainActor
@Test func replayingALessonDrawsTheSameMarksAsTheStoredDrawingAtItsLinesPace() throws {
    let screen = LessonFixtures.screenshot("#F4F1EA")
    let lesson = DrawingLesson(turnID: "t1", sessionID: "s1", createdAt: Date(), question: "What is this panel?", program: LessonFixtures.program,
                               canvas: HistoryCanvas(width: 1280, height: 832),
                               lines: [DrawingLesson.Line(index: 0, text: "Here is the panel.", start: 1.0, duration: 1.5),
                                       DrawingLesson.Line(index: 1, text: "And its title.", start: 3.0, duration: 1.0)])
    let image = try #require(TurnImages.image(from: screen.jpeg))
    let replay = try DrawingLessonReplay(lesson: lesson, screenshot: image)
    // Before the first line nothing is drawn; the caption follows the lines.
    replay.advance(to: 0.3)
    #expect(replay.marks.isEmpty)
    #expect(replay.caption() == nil)
    replay.advance(to: 1.2)
    #expect(replay.caption()?.text == "Here is the panel.")
    #expect(replay.marks.contains { $0.kind == "box" })
    #expect(!replay.marks.contains { $0.kind == "text" })
    replay.advance(to: 2.6)
    #expect(replay.caption()?.text == "And its title.")
    replay.runToEnd()
    #expect(replay.isDone && replay.finishedAt != nil)

    // The stored drawing, as the thumbnailer and poster render it: the same marks, in the same places.
    var options = DrawingRehearsal.Options()
    options.backdrop = .image(image)
    let stored = try DrawingRehearsal.run(program: LessonFixtures.program, options: options)
    let storedMarks = stored.events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
    func shape(_ m: DrawingMark) -> String { "\(m.id) \(m.kind) \(m.json["at"]?.jsonString() ?? "") \(m.json["text"]?.stringValue ?? "")" }
    #expect(replay.marks.map(shape) == storedMarks.map(shape))
    // And the final frame looks like it: the panel's middle is red over the screenshot.
    let frame = try replay.frame()
    let middle = DrawingSnapshot.pixel(frame, x: 500, y: 350)
    #expect(middle.r > 150 && middle.g < 140, "\(middle)")
}
