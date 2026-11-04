import CoreGraphics
import Foundation
import QuartzCore

// Stand-ins that let the real turn loop run without a person at the Mac: a transcript instead of the microphone, an
// image instead of screen capture, an offscreen canvas instead of the overlay, and an offline audio output written to
// a WAV file instead of the speakers. `occtl turn` and the tests use them.

// MARK: - Speech to text from a script

/// A speech-to-text "model" that hears a given sentence: as audio chunks arrive it reveals the words one at a time as
/// interim text, and `finish()` delivers the whole sentence as the final transcript.
public struct SimulatedSpeechToText: SpeechToTextClient {
    public enum Behavior: Sendable, Hashable {
        /// Hear `text`.
        case transcribe
        /// The connection fails when the session starts.
        case failToStart(String)
        /// The connection drops at the end of the press (after any interim words).
        case dropAtFinish(String)
        /// The final transcript never comes.
        case neverFinish
    }

    public var text: String
    public var behavior: Behavior
    public var inputFormat: PCMFormat
    /// Chunks of audio per revealed word.
    public var chunksPerWord: Int

    public init(text: String, behavior: Behavior = .transcribe, inputFormat: PCMFormat = .speech16k, chunksPerWord: Int = 6) {
        self.text = text
        self.behavior = behavior
        self.inputFormat = inputFormat
        self.chunksPerWord = max(1, chunksPerWord)
    }

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        if case .failToStart(let message) = behavior { throw ProviderError(provider: "simulated-stt", message: message) }
        return SimulatedSpeechSession(text: text, behavior: behavior, chunksPerWord: chunksPerWord)
    }
}

final class SimulatedSpeechSession: SpeechToTextSession, @unchecked Sendable {
    let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let words: [String]
    private let text: String
    private let behavior: SimulatedSpeechToText.Behavior
    private let chunksPerWord: Int
    private let lock = NSLock()
    private var chunks = 0
    private var revealed = 0

    init(text: String, behavior: SimulatedSpeechToText.Behavior, chunksPerWord: Int) {
        self.text = text
        self.words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        self.behavior = behavior
        self.chunksPerWord = chunksPerWord
        (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
    }

    func send(_ pcm: Data) async {
        let interim: String? = lock.withLock {
            chunks += 1
            let due = min(words.count, chunks / chunksPerWord)
            guard due > revealed else { return nil }
            revealed = due
            return words.prefix(due).joined(separator: " ")
        }
        if let interim {
            if revealed == 1 { continuation.yield(.speechStarted) }
            continuation.yield(.interim(interim))
        }
    }

    func finish() async {
        switch behavior {
        case .transcribe, .failToStart:
            if !text.isEmpty { continuation.yield(.final(text)) }
            continuation.finish()
        case .dropAtFinish(let message):
            continuation.finish(throwing: ProviderError(provider: "simulated-stt", message: message))
        case .neverFinish:
            break
        }
    }

    func cancel() async { continuation.finish() }
}

// MARK: - A microphone that only delivers silence

/// Delivers chunks of silence on a timer while "pressed", like a mic in a quiet room. Pair it with
/// `SimulatedSpeechToText`, which turns the chunk count into words.
@MainActor
public final class SilentMicrophone: TurnMicrophone {
    public let chunkDuration: TimeInterval
    public private(set) var starts = 0
    public private(set) var stops = 0
    public var failure: String?
    private var continuation: AsyncStream<Data>.Continuation?
    private var ticker: Task<Void, Never>?

    public init(chunkDuration: TimeInterval = 0.04) { self.chunkDuration = chunkDuration }

    public func start(format: PCMFormat) throws -> AsyncStream<Data> {
        if let failure { throw TurnMicrophoneError(message: failure) }
        stop()
        starts += 1
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        let bytes = Int(Double(format.bytesPerSecond) * chunkDuration) / 2 * 2
        let interval = chunkDuration
        ticker = Task {
            while !Task.isCancelled {
                continuation.yield(Data(count: bytes))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        stops += 1
        ticker?.cancel()
        ticker = nil
        continuation?.finish()
        continuation = nil
    }

    public var level: Float { continuation == nil ? 0 : 0.05 }
}

// MARK: - A still image instead of screen capture

/// "Captures" one fixed image as the screen under the pointer.
@MainActor
public final class StillImageScreen: TurnScreenLooking {
    public var screenshot: TurnScreenshot?
    public var context: TurnContext
    public var appNotes: [String]
    public private(set) var prefetches = 0
    public private(set) var cancelledPrefetches = 0
    public private(set) var looks = 0

    /// `pointsPerPixel` maps the image to display points (0.5 for a Retina screenshot).
    public init(imageData: Data?, label: String = "main display", pointsPerPixel: Double = 1, context: TurnContext = TurnContext(),
                appNotes: [String] = []) {
        if let imageData, let image = TurnImages.image(from: imageData) {
            let pixels = CGSize(width: image.width, height: image.height)
            screenshot = TurnScreenshot(jpeg: imageData, label: label, isCursorScreen: true, pixelSize: pixels,
                                        displayFrame: CGRect(x: 0, y: 0, width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel))
        }
        self.context = context
        self.appNotes = appNotes
    }

    public func prefetch() { prefetches += 1 }
    public func cancelPrefetch() { cancelledPrefetches += 1 }

    public private(set) var settledLooks = 0

    public func look() async -> TurnScreenLook {
        looks += 1
        var context = self.context
        context.localTime = Date()
        guard let screenshot else {
            return TurnScreenLook(context: context, appNotes: appNotes + ["[App] There is no screenshot this turn. Don't guess at what is on screen."],
                                  captureError: "no image")
        }
        return TurnScreenLook(screenshots: [screenshot], context: context, appNotes: appNotes, layout: layout,
                              guidedScreen: guidedScreen)
    }

    public func lookAfterAction() async -> TurnScreenLook {
        settledLooks += 1
        return await look()
    }

    /// One display holding the screenshot, at the origin (its Quartz and AppKit frames coincide).
    public var layout: DesktopLayout? {
        guard let screenshot else { return nil }
        return DesktopLayout(displays: [DisplayGeometry(id: 1, frame: screenshot.displayFrame, scale: 1, isPrimary: true)])
    }

    /// The screenshot's geometry and the context's elements as Accessibility would give them, so guided targets snap.
    public var guidedScreen: GuidedScreen? {
        guard let screenshot, let layout else { return nil }
        let geometry = CaptureGeometry(turnScreenshot: screenshot, layout: layout)
        let elements = context.elements.map { element in
            ElementSnapshot(id: element.id, role: Self.accessibilityRole(element.role), subrole: element.role == "password field" ? "AXSecureTextField" : nil,
                            title: element.label, frame: layout.appKitRect(fromQuartz: element.frame))
        }
        return GuidedScreen(geometry: geometry, elements: elements)
    }

    /// "button" → "AXButton", the way the element lists in evidence files name kinds.
    static func accessibilityRole(_ kind: String) -> String {
        if kind.hasPrefix("AX") { return kind }
        switch kind.lowercased() {
        case "button": return "AXButton"
        case "pop-up menu", "popup", "pop-up button": return "AXPopUpButton"
        case "text field", "password field", "field": return "AXTextField"
        case "search field": return "AXSearchField"
        case "link": return "AXLink"
        case "checkbox": return "AXCheckBox"
        case "radio button": return "AXRadioButton"
        case "menu item": return "AXMenuItem"
        case "menu bar item": return "AXMenuBarItem"
        case "tab": return "AXTab"
        default: return "AXStaticText"
        }
    }

    /// A plain light canvas as JPEG, for turns without a real screenshot.
    public static func blankCanvas(width: Int = 1280, height: Int = 800, gray: CGFloat = 0.96) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        return (try? ImageCoding.jpegData(image, quality: 0.85)) ?? Data()
    }
}

// MARK: - An offscreen canvas

/// One offscreen drawing per turn, sized to the turn's screenshot, kept in a render context so its animations can be
/// snapshotted mid-turn (`snapshot(at:)`).
@MainActor
public final class OffscreenDrawingSurfaces: TurnDrawingSurfaces {
    public private(set) var session: DrawingSession?
    public private(set) var backdrop: CGImage?
    public private(set) var canvasSize: CGSize = .zero
    public private(set) var sessionsMade = 0
    /// Events the painter doesn't draw (warnings, errors, done), for logs.
    public var onEvent: ((DrawingEvent) -> Void)?
    public var figureSink: (any FigureSink)?
    /// Looks up photos, places, quotes and site icons for the drawing's media cards (nil: they stay "loading").
    public var media: DrawingMediaResolver?

    public init() {}

    public func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        let options = TurnImages.beginOptions(for: screenshot, ink: "#3380FF", pace: .speech)
        let canvas = DrawingPainter.Canvas(width: options.width, height: options.height, scale: 1)
        let sampler = image.map { DrawingScreenSampler(image: $0, canvasSize: CGSize(width: options.width, height: options.height)) }
        guard let made = try? DrawingSession(canvas: canvas, figureSink: figureSink, screen: sampler) else { return nil }
        session?.cancel()
        session = made
        sessionsMade += 1
        backdrop = image
        canvasSize = canvas.sizeInPoints
        DrawingSnapshot.adopt(made.layer)
        made.onEvent = { [weak self] event in self?.onEvent?(event) }
        if let media {
            media.cancelAll()
            media.attach(to: made)
        }
        return OffscreenDrawing(made)
    }

    public var hasVisibleDrawing: Bool { session.map { !$0.painter.markIDs.isEmpty } ?? false }

    public func clearAll() { session?.clear() }

    /// The canvas as it looks at media time `time` (now by default), over the screenshot.
    public func snapshot(at time: CFTimeInterval = CACurrentMediaTime()) throws -> CGImage? {
        guard let session else { return nil }
        let image = try DrawingSnapshot.render(session.layer, size: canvasSize, at: time, backdrop: backdrop)
        DrawingSnapshot.adopt(session.layer)
        return image
    }
}

/// Draws offscreen at one canvas unit per point: the screenshot's pixels are the canvas, whatever the display's scale.
@MainActor
final class OffscreenDrawing: TurnDrawing {
    let session: DrawingSession

    init(_ session: DrawingSession) { self.session = session }

    func begin(_ options: DrawingBeginOptions) {
        var options = options
        options.scale = 1
        session.begin(options)
    }

    func append(_ text: String) { session.append(text) }
    func end() { session.end() }
    func finishNow() { session.finishNow() }
    func cancel() { session.cancel() }
    func clear() { session.clear() }
    var isDrawing: Bool { session.isDrawing }
    var onMarks: (([DrawingMark]) -> Void)? {
        get { session.onMarks }
        set { session.onMarks = newValue }
    }

    nonisolated func lineStarted(_ index: Int, expectedDuration: TimeInterval?) { session.lineStarted(index, expectedDuration: expectedDuration) }
    nonisolated func lineFinished(_ index: Int) { session.lineFinished(index) }
    func pause() { session.pause() }
    func resume() { session.resume() }
    func wordsSpoken(_ count: Int) { session.wordsSpoken(count) }
}

// MARK: - Offline speakers

/// A `SpeechPlayer` on an offline audio engine whose output is rendered in real time into a WAV file: what the user
/// would have heard, written instead of played (the Mac stays silent).
public final class OfflineSpeakers: @unchecked Sendable {
    public let player: SpeechPlayer
    public let url: URL
    public let sampleRate: Int
    private let host: AudioEngineHost
    private let writer: WAVFileWriter
    private let lock = NSLock()
    private var rendered = 0
    private var peak: Float = 0
    private var pump: Task<Void, Never>?
    private var failure: String?
    /// Held while a slice is rendered and written, and while the file is closed, so the two never overlap.
    private let fileLock = NSLock()
    private var closed = false

    public init(url: URL, sampleRate: Int = 24_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        host = AudioEngineHost(offlineSampleRate: Double(sampleRate))
        player = SpeechPlayer(sampleRate: sampleRate, host: host)
        writer = try WAVFileWriter(url: url, format: PCMFormat(sampleRate: sampleRate))
    }

    /// Starts rendering at real-time pace (every `tick` seconds).
    public func start(tick: TimeInterval = 0.01) {
        guard pump == nil else { return }
        let started = Date()
        pump = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let due = Int(Date().timeIntervalSince(started) * Double(self.sampleRate))
                let frames = due - self.lock.withLock { self.rendered }
                if frames > 0 { self.render(frames) }
                try? await Task.sleep(for: .seconds(tick))
            }
        }
    }

    private func render(_ frames: Int) {
        let wrote: Bool = fileLock.withLock {
            guard !closed else { return false }
            do {
                let buffer = try host.renderOffline(frames: frames)
                let samples = PCMConverter.monoFloats(from: buffer)
                try writer.append(PCMConverter.pcm16(fromFloats: samples))
                let loudest = samples.reduce(Float(0)) { max($0, abs($1)) }
                lock.withLock {
                    rendered += Int(buffer.frameLength)
                    peak = max(peak, loudest)
                }
                return true
            } catch {
                lock.withLock { failure = "\(error)" }
                return false
            }
        }
        if wrote { player.poll() }
    }

    /// Seconds rendered so far.
    public var seconds: TimeInterval { Double(lock.withLock { rendered }) / Double(sampleRate) }
    public var peakLevel: Float { lock.withLock { peak } }
    public var renderError: String? { lock.withLock { failure } }

    /// Stops rendering and closes the WAV file. A slice being written when this is called finishes first; nothing is
    /// written after.
    public func finish() throws {
        pump?.cancel()
        pump = nil
        try fileLock.withLock {
            guard !closed else { return }
            closed = true
            try writer.finish()
        }
    }
}
