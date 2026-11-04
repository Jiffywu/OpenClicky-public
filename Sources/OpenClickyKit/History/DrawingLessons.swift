import CoreGraphics
import Foundation
import ImageIO

// Saved drawings ("lessons"): when `drawing.saves-lessons` is on, each drawing is kept with the screenshot it was drawn
// on, a poster of the finished drawing and `lesson.json` (the program, its spoken lines and when each was heard), in
// `<history>/lessons/<turn id>/`. Home's Drawings page replays them (`DrawingLessonReplay`) and draws their thumbnails
// over the stored screenshot. See docs/home.md.

/// `lesson.json`.
public struct DrawingLesson: Codable, Sendable, Hashable {
    public struct Line: Codable, Sendable, Hashable {
        public var index: Int
        public var text: String
        /// Seconds after the drawing began when the line started being heard; nil when it wasn't spoken (typed answers).
        public var start: TimeInterval?
        /// Seconds it was heard for.
        public var duration: TimeInterval?

        public init(index: Int, text: String, start: TimeInterval? = nil, duration: TimeInterval? = nil) {
            self.index = index
            self.text = text
            self.start = start
            self.duration = duration
        }
    }

    public static let fileName = "lesson.json"
    public static let screenshotName = "screenshot.jpg"
    public static let posterName = "poster.png"

    public var version = 1
    public var turnID: String
    public var sessionID: String
    public var createdAt: Date
    /// What the user asked.
    public var question: String
    public var program: String
    /// The canvas the program was laid out on (the screenshot's pixels).
    public var canvas: HistoryCanvas
    public var lines: [Line]
    /// The display it was drawn on ("main display").
    public var screen: String?
    /// File names in the lesson folder (nil when that file wasn't written).
    public var screenshot: String?
    public var poster: String?

    public init(turnID: String, sessionID: String, createdAt: Date, question: String, program: String, canvas: HistoryCanvas,
                lines: [Line], screen: String? = nil, screenshot: String? = nil, poster: String? = nil) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.question = question
        self.program = program
        self.canvas = canvas
        self.lines = lines
        self.screen = screen
        self.screenshot = screenshot
        self.poster = poster
    }

    /// When each line plays in a replay: the recorded times, or (for lines never heard) an average speaking rate after
    /// the line before. Seconds after the replay starts.
    public func schedule(wordsPerSecond: Double = 2.6, lead: TimeInterval = 0.4, gap: TimeInterval = 0.25) -> [(start: TimeInterval, end: TimeInterval)] {
        var out: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor = lead
        let offset = lines.compactMap(\.start).min().map { max(0, $0 - lead) } ?? 0
        for line in lines {
            let words = Double(line.text.split(whereSeparator: \.isWhitespace).count)
            let estimate = max(0.6, words / max(0.5, wordsPerSecond) + 0.25)
            let start = line.start.map { max(cursor, $0 - offset) } ?? cursor
            let length = line.duration.map { max(0.2, $0) } ?? estimate
            out.append((start: start, end: start + length))
            cursor = start + length + gap
        }
        return out
    }
}

/// What the turn orchestrator knows about a drawing when its turn ends: the screenshot it was drawn on and when each
/// line was heard. `TurnRecord.lesson`; the app turns it into a lesson folder when `drawing.saves-lessons` is on.
public struct DrawingLessonDraft: Sendable {
    public var screenshot: TurnScreenshot
    public var lines: [DrawingLesson.Line]

    public init(screenshot: TurnScreenshot, lines: [DrawingLesson.Line]) {
        self.screenshot = screenshot
        self.lines = lines
    }
}

/// The lesson folders under a history folder.
public struct DrawingLessonStore: Sendable {
    public let directory: URL

    /// `historyDirectory`/lessons.
    public init(historyDirectory: URL = HistoryStore.defaultDirectory) {
        directory = historyDirectory.appendingPathComponent("lessons", isDirectory: true)
    }

    public func folder(for turnID: String) -> URL {
        directory.appendingPathComponent(HistoryStore.safeName(turnID), isDirectory: true)
    }

    public func exists(_ turnID: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: turnID).appendingPathComponent(DrawingLesson.fileName).path)
    }

    /// Writes the folder: lesson.json, the screenshot JPEG and the poster PNG. Returns the folder.
    @discardableResult
    public func save(_ lesson: DrawingLesson, screenshotJPEG: Data?, poster: CGImage?) throws -> URL {
        let folder = folder(for: lesson.turnID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lesson = lesson
        if let screenshotJPEG {
            try screenshotJPEG.write(to: folder.appendingPathComponent(DrawingLesson.screenshotName), options: .atomic)
            lesson.screenshot = DrawingLesson.screenshotName
        }
        if let poster {
            try Self.writePNG(poster, to: folder.appendingPathComponent(DrawingLesson.posterName))
            lesson.poster = DrawingLesson.posterName
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lesson).write(to: folder.appendingPathComponent(DrawingLesson.fileName), options: .atomic)
        return folder
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    public func load(_ turnID: String) -> DrawingLesson? { load(folder: folder(for: turnID)) }

    public func load(folder: URL) -> DrawingLesson? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(DrawingLesson.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DrawingLesson.self, from: data)
    }

    /// The stored screenshot, decoded.
    public func screenshot(_ turnID: String) -> CGImage? { screenshot(folder: folder(for: turnID)) }

    public func screenshot(folder: URL) -> CGImage? {
        guard let lesson = load(folder: folder), let name = lesson.screenshot,
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Every lesson, newest first.
    public func all() -> [DrawingLesson] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { load(folder: $0) }.sorted { ($0.createdAt, $0.turnID) > ($1.createdAt, $1.turnID) }
    }

    public func delete(_ turnID: String) throws {
        let folder = folder(for: turnID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}

/// Writes a lesson folder for a finished turn: the program and lines from the history record, the screenshot and line
/// times from the orchestrator's draft, and a poster rendered over the screenshot by the drawing engine.
@MainActor
public enum DrawingLessonRecorder {
    @discardableResult
    public static func record(_ draft: DrawingLessonDraft, turn: HistoryTurn, store: DrawingLessonStore,
                              ink: String = "#3380FF") throws -> URL? {
        guard let program = turn.program, !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let shot = draft.screenshot
        let canvas = HistoryCanvas(width: Double(shot.pixelSize.width), height: Double(shot.pixelSize.height))
        var lines = draft.lines
        // Lines the record has that the draft didn't time (a typed answer) still go in, untimed.
        for (index, text) in turn.spokenLines.enumerated() where !lines.contains(where: { $0.index == index }) {
            lines.append(DrawingLesson.Line(index: index, text: text))
        }
        lines.sort { $0.index < $1.index }
        let lesson = DrawingLesson(turnID: turn.id, sessionID: turn.sessionID, createdAt: turn.startedAt, question: turn.words,
                                   program: program, canvas: canvas, lines: lines, screen: shot.label)
        let image = TurnImages.image(from: shot.jpeg)
        var poster: CGImage?
        if canvas.width >= 1, canvas.height >= 1 {
            var options = DrawingRehearsal.Options()
            options.width = canvas.width
            options.height = canvas.height
            options.ink = ink
            options.backdrop = image.map { .image($0) } ?? .color("#F3F4F6")
            poster = try? DrawingRehearsal.run(program: program, options: options).image
        }
        return try store.save(lesson, screenshotJPEG: shot.jpeg.isEmpty ? nil : shot.jpeg, poster: poster)
    }
}
