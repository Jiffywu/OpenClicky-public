import CoreGraphics
import Foundation
import QuartzCore

/// Plays a drawing program against a simulated voice on a virtual clock and renders the canvas at a chosen moment.
///
/// It drives the real pipeline (engine host, speech pacing, painter, offscreen compositor): the program streams in,
/// `SayLineExtractor` finds the spoken lines, each line "starts" at the time a voice would reach it (at an average
/// speaking rate), the host is drained at 30 frames a second, and the layer tree is composited at the requested time.
/// Used by `occtl draw`, tests and evidence renders. Never touches the real screen.
@MainActor
public enum DrawingRehearsal {
    /// What the drawing is composited over.
    public enum Backdrop {
        case none
        case color(String)
        /// Light left half, dark right half: shows the readable-ink rule.
        case split
        /// A synthetic app window on a desktop (not a real screenshot).
        case mockScreen(dark: Bool)
        case image(CGImage)
    }

    public struct Options {
        public var width: Double = 1280
        public var height: Double = 832
        public var scale: Double = 1
        public var ink: String = "#3380FF"
        /// Seconds after the program starts; nil renders once everything has been drawn.
        public var at: TimeInterval?
        public var backdrop: Backdrop = .color("#F3F4F6")
        public var wordsPerSecond: Double = 2.6
        /// When the voice starts the first line, after the program begins.
        public var voiceLatency: TimeInterval = 0.6
        public var lineGap: TimeInterval = 0.3
        /// Program text arrives in chunks of this many characters (all before the voice starts).
        public var chunkSize: Int = 24
        public var figureSink: (any FigureSink)?
        /// Answers for media pieces (photos, places, quotes), looked up beforehand; see `DrawingRehearsalMedia`.
        public var media: DrawingRehearsalMedia?

        public init() {}
    }

    public struct Result {
        public var image: CGImage
        /// The moment rendered, in seconds after the program started.
        public var time: TimeInterval
        /// When the engine reported `done`, if it did.
        public var finishedAt: TimeInterval?
        public var events: [DrawingEvent]
        public var lines: [SayLineExtractor.Line]
        public var painter: DrawingPainter
        public var host: DrawingEngineHost
        /// Host-clock time when the program began (event times such as a sound's `at` are on the same clock).
        public var startedAt: TimeInterval = 0

        public var warnings: [String] { events.compactMap { if case .warning(let m) = $0 { m } else { nil } } }
        public var errors: [String] { events.compactMap { if case .error(let m, _) = $0 { m } else { nil } } }
        public var markCount: Int { events.reduce(0) { if case .marks(let ms) = $1 { $0 + ms.count } else { $0 } } }
        public var actions: [DrawingAction] { events.compactMap { if case .action(let a) = $0 { a } else { nil } } }
        public var notes: [(kind: String, text: String)] { events.compactMap { if case .note(let k, let t) = $0 { (k, t) } else { nil } } }
        public var sounds: [DrawingSoundRecipe] { events.compactMap { if case .sound(let r) = $0 { r } else { nil } } }

        /// The drawing's sounds mixed onto one track (24 kHz PCM16 WAV), from the start to the moment rendered.
        public func soundtrackWAV(sampleRate: Int = 24_000) -> Data {
            let samples = DrawingSounds.mix(sounds, from: startedAt, duration: time + 1, sampleRate: Double(sampleRate))
            return WAVEncoder.encode(PCMConverter.pcm16(fromFloats: samples), format: PCMFormat(sampleRate: sampleRate))
        }
    }

    public static func run(program: String, options: Options = Options()) throws -> Result {
        // Core Animation retires finished animations by real media time when a transaction commits, so the virtual
        // clock runs far in the real future: nothing it schedules can look finished before the snapshot.
        let clock = VirtualClock(CACurrentMediaTime() + 100_000)
        let t0 = clock.now
        let canvasSize = CGSize(width: options.width, height: options.height)
        let backdrop = makeBackdrop(options.backdrop, size: canvasSize)
        let sampler = backdrop.image.map { DrawingScreenSampler(image: $0, canvasSize: canvasSize) }
        var luminance: DrawingEngineHost.Luminance?
        var busyness: DrawingEngineHost.Busyness?
        if let sampler {
            luminance = { rect in sampler.luminance(in: rect) }
            busyness = { rect in sampler.busyness(in: rect) }
        }
        let host = try DrawingEngineHost(clock: { clock.now }, luminance: luminance, busyness: busyness)
        let painter = DrawingPainter(canvas: .init(width: options.width, height: options.height, scale: options.scale),
                                     figureSink: options.figureSink, clock: { clock.now })
        // Outside a render context Core Animation would strip the painter's animations before the snapshot.
        DrawingSnapshot.adopt(painter.layer)
        painter.media = options.media?.store
        painter.screen = backdrop.image
        // Media answers waiting for their moment on the virtual clock: (due, ref, fields).
        var patches: [(due: TimeInterval, ref: String, fields: JSONValue)] = []
        var events: [DrawingEvent] = []
        var lastEnd = t0
        // `done` can come back from any command (the end of a program that draws nothing, the last line finishing),
        // not only from the frame drains.
        var sawDone = false
        func take(_ batch: [DrawingEvent]) {
            if batch.contains(.done) { sawDone = true }
            for event in batch {
                if case .marks(let marks) = event {
                    for mark in marks {
                        let base = mark.json["base"]?.doubleValue ?? clock.now
                        lastEnd = max(lastEnd, base + mark.start + mark.duration)
                    }
                }
                if let media = options.media, let request = DrawingMediaRequest(event: event), let fields = media.answers[request.cacheKey] {
                    patches.append((clock.now + media.delay, request.ref, fields))
                }
            }
            events += batch
            painter.apply(batch)
        }

        take(host.perform(.begin(DrawingBeginOptions(width: options.width, height: options.height, scale: options.scale, ink: options.ink))))
        var extractor = SayLineExtractor()
        var lines: [SayLineExtractor.Line] = []
        var index = program.startIndex
        let chunk = max(1, options.chunkSize)
        while index < program.endIndex {
            let end = program.index(index, offsetBy: chunk, limitedBy: program.endIndex) ?? program.endIndex
            let piece = String(program[index..<end])
            lines += extractor.feed(piece)
            take(host.perform(.append(piece)))
            index = end
        }
        take(host.perform(.end))

        // When a voice speaking at an average rate would start and finish each line.
        var voice: [(start: TimeInterval, end: TimeInterval)] = []
        var cursor = options.voiceLatency
        for line in lines {
            let words = line.text.split(whereSeparator: \.isWhitespace).count
            let seconds = max(0.6, Double(words) / options.wordsPerSecond + 0.25)
            voice.append((cursor, cursor + seconds))
            cursor += seconds + options.lineGap
        }

        let frame = 1.0 / 30.0
        var now = 0.0, started = 0, finished = 0
        var doneAt: TimeInterval?
        let horizon = max(options.at ?? 0, cursor + 60)
        while true {
            while started < voice.count, voice[started].start <= now {
                clock.now = t0 + voice[started].start
                take(host.perform(.lineStarted(started, voice[started].end - voice[started].start)))
                started += 1
            }
            while finished < started, voice[finished].end <= now {
                clock.now = t0 + voice[finished].end
                take(host.perform(.lineFinished(finished)))
                finished += 1
            }
            clock.now = t0 + now
            while let next = patches.firstIndex(where: { $0.due <= clock.now }) {
                let patch = patches.remove(at: next)
                take(host.perform(.patch(ref: patch.ref, fields: patch.fields)))
            }
            take(host.perform(.drain))
            if doneAt == nil, sawDone { doneAt = now }
            if let at = options.at {
                if now >= at { break }
            } else if let doneAt, now >= max(doneAt, lastEnd - t0) + 0.3, patches.isEmpty {
                break
            }
            if now > horizon { break }
            now += frame
        }
        let time = options.at ?? now
        clock.now = t0 + time
        painter.purge()
        let background: CGColor? = {
            if case .color(let hex) = options.backdrop { return DrawingColor(hex: hex)?.cgColor }
            return nil
        }()
        let image = try DrawingSnapshot.render(painter.layer, size: painter.canvas.sizeInPoints, at: t0 + time,
                                               background: background, backdrop: backdrop.drawn)
        var result = Result(image: image, time: time, finishedAt: doneAt, events: events, lines: lines, painter: painter, host: host)
        result.startedAt = t0
        return result
    }

    // MARK: Backdrops

    /// `image` feeds the readable-ink sampler; `drawn` is composited under the drawing.
    static func makeBackdrop(_ backdrop: Backdrop, size: CGSize) -> (image: CGImage?, drawn: CGImage?) {
        switch backdrop {
        case .none: return (nil, nil)
        case .color(let hex):
            let color = DrawingColor(hex: hex) ?? .white
            let image = paint(size: CGSize(width: 16, height: 16)) { context, rect in
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
            return (image, nil)
        case .split:
            let image = paint(size: size) { context, rect in
                context.setFillColor(DrawingColor(hex: "#F4F5F7")!.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height))
                context.setFillColor(DrawingColor(hex: "#1D1F25")!.cgColor)
                context.fill(CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height))
            }
            return (image, image)
        case .mockScreen(let dark):
            let image = mockScreen(size: size, dark: dark)
            return (image, image)
        case .image(let image):
            return (image, image)
        }
    }

    /// A plain, made-up app window so evidence renders have something to point at. Drawn with flat shapes only.
    static func mockScreen(size: CGSize, dark: Bool) -> CGImage? {
        paint(size: size) { context, rect in
            // Top-left origin for readability.
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            let desk = dark ? DrawingColor(hex: "#23262E")! : DrawingColor(hex: "#C9D3E0")!
            context.setFillColor(desk.cgColor)
            context.fill(rect)
            let window = CGRect(x: rect.width * 0.04, y: rect.height * 0.06, width: rect.width * 0.92, height: rect.height * 0.88)
            let body = dark ? DrawingColor(hex: "#2C2F37")! : DrawingColor(hex: "#FFFFFF")!
            let side = dark ? DrawingColor(hex: "#262930")! : DrawingColor(hex: "#F1F3F6")!
            let line = dark ? DrawingColor(hex: "#4A4F5A")! : DrawingColor(hex: "#D9DDE3")!
            context.setFillColor(body.cgColor)
            context.addPath(CGPath(roundedRect: window, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
            let bar = CGRect(x: window.minX, y: window.minY, width: window.width, height: 52)
            context.setFillColor(side.cgColor)
            context.fill(bar)
            context.fill(CGRect(x: window.minX, y: bar.maxY, width: 220, height: window.height - bar.height))
            for (i, color) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                context.setFillColor(DrawingColor(hex: color)!.cgColor)
                context.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 20, y: window.minY + 20, width: 12, height: 12))
            }
            context.setFillColor(line.cgColor)
            for i in 0..<9 { context.fill(CGRect(x: window.minX + 24, y: bar.maxY + 28 + CGFloat(i) * 36, width: 150 - CGFloat(i % 3) * 25, height: 10)) }
            let content = window.minX + 260
            for i in 0..<12 { context.fill(CGRect(x: content, y: bar.maxY + 40 + CGFloat(i) * 30, width: CGFloat(520 - (i * 37) % 180), height: 9)) }
            // A toolbar button near the top right.
            let accent = DrawingColor(hex: "#3380FF")!
            context.setFillColor(accent.withAlpha(dark ? 0.9 : 1).cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: window.maxX - 130, y: window.minY + 12, width: 96, height: 28), cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.fillPath()
            context.setFillColor(line.cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: window.maxX - 210, y: window.minY + 12, width: 64, height: 28), cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.fillPath()
        }
    }

    static func paint(size: CGSize, _ draw: (CGContext, CGRect) -> Void) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// A clock tests and rehearsals set by hand. Read from the engine's queue, written on the main actor.
public final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    public init(_ start: TimeInterval = 1000) { value = start }

    public var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
