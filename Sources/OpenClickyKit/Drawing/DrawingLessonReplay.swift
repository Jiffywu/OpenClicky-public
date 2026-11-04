import CoreGraphics
import Foundation
import QuartzCore

/// Plays a saved drawing again: the stored program runs through the drawing engine (`DrawingEngineHost`) and the
/// painter at the pace its lines were heard (the recorded times in `lesson.json`, or an average speaking rate), with the
/// spoken lines as captions. No audio. Frames are composited offscreen over the stored screenshot, on the replay's own
/// clock, so Home can show them as they come and tests and evidence renders get exactly the same pictures.
@MainActor
public final class DrawingLessonReplay {
    public let lesson: DrawingLesson
    public let screenshot: CGImage?
    public let host: DrawingEngineHost
    public let painter: DrawingPainter
    /// When each line plays, seconds after the replay starts.
    public let schedule: [(start: TimeInterval, end: TimeInterval)]
    /// Seconds into the replay.
    public private(set) var time: TimeInterval = 0
    /// When the engine said the drawing was done.
    public private(set) var finishedAt: TimeInterval?
    public private(set) var events: [DrawingEvent] = []

    private let clock: VirtualClock
    private let origin: TimeInterval
    private var started = 0
    private var finished = 0
    private var lastEnd: TimeInterval
    private static let frame = 1.0 / 30.0

    /// Loads the program into a fresh engine; nothing is drawn until `advance(to:)`.
    public init(lesson: DrawingLesson, screenshot: CGImage?, ink: String = "#3380FF") throws {
        self.lesson = lesson
        self.screenshot = screenshot
        schedule = lesson.schedule()
        // Far in the media future, as in rehearsals: Core Animation must never think these animations are over.
        let clock = VirtualClock(CACurrentMediaTime() + 100_000)
        self.clock = clock
        origin = clock.now
        lastEnd = clock.now
        let size = CGSize(width: max(1, lesson.canvas.width), height: max(1, lesson.canvas.height))
        var luminance: DrawingEngineHost.Luminance?
        var busyness: DrawingEngineHost.Busyness?
        if let screenshot {
            let sampler = DrawingScreenSampler(image: screenshot, canvasSize: size)
            luminance = { rect in sampler.luminance(in: rect) }
            busyness = { rect in sampler.busyness(in: rect) }
        }
        host = try DrawingEngineHost(clock: { clock.now }, luminance: luminance, busyness: busyness)
        painter = DrawingPainter(canvas: .init(width: size.width, height: size.height), clock: { clock.now })
        DrawingSnapshot.adopt(painter.layer)
        painter.screen = screenshot
        take(host.perform(.begin(DrawingBeginOptions(width: size.width, height: size.height, ink: ink, pace: .speech))))
        take(host.perform(.append(lesson.program)))
        take(host.perform(.end))
    }

    /// The replay's length: the last line's end, and the drawing done.
    public var duration: TimeInterval {
        max(schedule.last.map { $0.end + 0.6 } ?? 1, (finishedAt ?? 0), lastEnd - origin)
    }

    public var isDone: Bool { finishedAt != nil && time >= max(lastEnd - origin, finishedAt ?? 0) + 0.3 }

    /// Runs the engine up to `target` seconds into the replay, a frame at a time: lines start and finish when they did.
    public func advance(to target: TimeInterval) {
        while time < target {
            time = min(target, time + Self.frame)
            while started < schedule.count, schedule[started].start <= time {
                clock.now = origin + schedule[started].start
                take(host.perform(.lineStarted(started, schedule[started].end - schedule[started].start)))
                started += 1
            }
            while finished < started, schedule[finished].end <= time {
                clock.now = origin + schedule[finished].end
                take(host.perform(.lineFinished(finished)))
                finished += 1
            }
            clock.now = origin + time
            take(host.perform(.drain))
            if finishedAt == nil, events.contains(.done) { finishedAt = time }
        }
    }

    /// Plays to the end (every line heard, everything drawn).
    public func runToEnd(limit: TimeInterval = 600) {
        advance(to: (schedule.last?.end ?? 0) + 0.1)
        while !isDone, time < limit { advance(to: time + 0.5) }
    }

    /// The line being heard at `time` (kept on screen a moment after it ends), for the caption.
    public func caption(at time: TimeInterval? = nil) -> DrawingLesson.Line? {
        let t = time ?? self.time
        guard let index = schedule.lastIndex(where: { $0.start <= t }) else { return nil }
        guard t <= schedule[index].end + 0.8 else { return nil }
        return lesson.lines.indices.contains(index) ? lesson.lines[index] : nil
    }

    /// Every mark as last released (an edited mark once, in its final form), in order of first appearance.
    public var marks: [DrawingMark] {
        var order: [String] = []
        var latest: [String: DrawingMark] = [:]
        var removed = Set<String>()
        for event in events {
            switch event {
            case .marks(let marks):
                for mark in marks {
                    if latest[mark.id] == nil { order.append(mark.id) }
                    latest[mark.id] = mark
                    removed.remove(mark.id)
                }
            case .remove(let ids):
                removed.formUnion(ids)
            default:
                break
            }
        }
        return order.compactMap { removed.contains($0) ? nil : latest[$0] }
    }

    /// The canvas at the replay's current moment over the stored screenshot, at most `maxWidth` pixels wide.
    public func frame(maxWidth: Int? = nil) throws -> CGImage {
        painter.purge()
        let size = painter.canvas.sizeInPoints
        let image = try DrawingSnapshot.render(painter.layer, size: size, at: origin + time,
                                               background: screenshot == nil ? DrawingColor(hex: "#F3F4F6")?.cgColor : nil,
                                               backdrop: screenshot)
        DrawingSnapshot.adopt(painter.layer)
        guard let maxWidth, image.width > maxWidth else { return image }
        return DrawingThumbnailer.scaled(image, toWidth: maxWidth) ?? image
    }

    private func take(_ batch: [DrawingEvent]) {
        for event in batch {
            if case .marks(let marks) = event {
                for mark in marks {
                    let base = mark.json["base"]?.doubleValue ?? clock.now
                    lastEnd = max(lastEnd, base + mark.start + mark.duration)
                }
            }
        }
        events += batch
        painter.apply(batch)
    }
}
