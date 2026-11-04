import CoreGraphics
import Foundation
import ImageIO

// The seams the turn orchestrator drives. The app plugs in the real microphone, screen capture, overlays and cues;
// tests and `occtl turn` plug in fakes (a scripted transcript, a still image, an offscreen canvas).

/// The microphone for one press at a time.
@MainActor
public protocol TurnMicrophone: AnyObject {
    /// Opens the mic for a new press and streams PCM16 chunks in `format` until `stop()`.
    func start(format: PCMFormat) throws -> AsyncStream<Data>
    /// Ends the press: the stream delivers what is left and finishes.
    func stop()
    /// Input level 0…1 for the waveform (0 when closed).
    var level: Float { get }
}

/// A microphone that can tell when audio is really flowing for the current press, so the start cue plays only once
/// the user can be heard (a Bluetooth route switch would otherwise swallow it). `SharedMicrophone.TurnHandle` is one.
@MainActor
public protocol TurnMicrophoneReadiness: AnyObject {
    /// True once audio flows for the press now running; false if it didn't within `timeout` or the press ended.
    func waitUntilLive(timeout: TimeInterval) async -> Bool
}

/// Whether the user would hear the voice right now. When the output is muted or at zero the turn answers silently
/// (captions and drawing only) and the record carries the unheard reply (docs/audio-robustness.md).
@MainActor
public protocol TurnOutputChecking: AnyObject {
    /// Why the voice can't be heard, or nil when it can.
    func outputSilence() -> OutputSilence?
}

/// What the screen showed for one turn.
public struct TurnScreenLook: Sendable {
    public var screenshots: [TurnScreenshot]
    public var context: TurnContext
    public var appNotes: [String]
    /// Why there are no screenshots, when there aren't.
    public var captureError: String?
    /// The displays as they were for this look (screenshot frames are Quartz points in it). Draw-to-ask maps its ink
    /// with it; nil means the current layout.
    public var layout: DesktopLayout?
    /// The pointer's screenshot and the front window's controls, for placing a guided walkthrough's targets (snapped
    /// to real controls). Nil when the turn has no screenshot.
    public var guidedScreen: GuidedScreen?

    public init(screenshots: [TurnScreenshot] = [], context: TurnContext = TurnContext(), appNotes: [String] = [],
                captureError: String? = nil, layout: DesktopLayout? = nil, guidedScreen: GuidedScreen? = nil) {
        self.screenshots = screenshots
        self.context = context
        self.appNotes = appNotes
        self.captureError = captureError
        self.layout = layout
        self.guidedScreen = guidedScreen
    }

    /// The screenshot of the display under the pointer (the drawing canvas).
    public var cursorScreenshot: TurnScreenshot? { screenshots.first(where: \.isCursorScreen) ?? screenshots.first }
}

/// Screenshots and context for a turn.
@MainActor
public protocol TurnScreenLooking: AnyObject {
    /// Key-down: start reading the context (the open document) while the user talks.
    func prefetch()
    /// The press was dropped.
    func cancelPrefetch()
    /// Key-up (or a typed question): screenshots of every display, the pointer's first, and the context.
    func look() async -> TurnScreenLook
    /// The same after the user acted (clicked a walkthrough's target): waits longer for the screen to settle (a menu
    /// opening, a sheet sliding in) before capturing.
    func lookAfterAction() async -> TurnScreenLook
}

extension TurnScreenLooking {
    public func lookAfterAction() async -> TurnScreenLook { await look() }
}

/// One drawing on one display, driven by the brain's program and paced by the voice. `DrawingSession` is the real one.
@MainActor
public protocol TurnDrawing: AnyObject, SpeechPacing {
    func begin(_ options: DrawingBeginOptions)
    func append(_ text: String)
    func end()
    /// Draw everything still waiting for the voice now.
    func finishNow()
    /// Stop where it is (what is drawn stays).
    func cancel()
    /// Remove everything.
    func clear()
    var isDrawing: Bool { get }
    /// Marks as the drawing releases them (at their line's beat), from this drawing's live program only. A guided
    /// walkthrough arms its targets from them (`TurnGuiding.answerStarted`).
    var onMarks: (([DrawingMark]) -> Void)? { get set }
    /// The narration paused (between lines, or its audio stalled): hold the pen where it is.
    func pause()
    /// The narration carries on after `pause()`.
    func resume()
    /// `count` words of the answer have been heard so far (a running count across its lines).
    func wordsSpoken(_ count: Int)
}

extension TurnDrawing {
    // Drawings that pace by line starts alone (simple fakes) ignore the finer beats.
    public func pause() {}
    public func resume() {}
    public func wordsSpoken(_ count: Int) {}
}

extension DrawingSession: TurnDrawing {}

/// Where drawings go: one canvas per display.
@MainActor
public protocol TurnDrawingSurfaces: AnyObject {
    /// The canvas for the display `screenshot` shows (sized to the screenshot's pixels), ready for a new program.
    /// `image` is the decoded screenshot, for readable ink. Nil when there is nowhere to draw.
    func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)?
    /// Whether anything drawn is still on screen (Escape clears it).
    var hasVisibleDrawing: Bool { get }
    func clearAll()
    /// The drawing for the user's follow-up: the one still on that display, continued (`keep` true: begin it with
    /// `DrawingBeginOptions.keep`) when it fits the new screenshot; otherwise a new one, like `drawing(for:image:)`.
    func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)?
    /// What the drawing a follow-up on `screenshot` would continue shows, for that turn's notes
    /// (`TurnContext.drawingOnScreen`): its parts by id, kind, words and box, and each 3D figure's parts. Nil when
    /// `continuingDrawing(for:image:)` would start a new drawing there (nothing drawn, another display or canvas size),
    /// so the brain is never shown a drawing its program can't edit.
    func describeOnScreen(for screenshot: TurnScreenshot) -> String?
}

extension TurnDrawingSurfaces {
    public func continuingDrawing(for screenshot: TurnScreenshot, image: CGImage?) -> (drawing: any TurnDrawing, keep: Bool)? {
        drawing(for: screenshot, image: image).map { ($0, false) }
    }

    public func describeOnScreen(for screenshot: TurnScreenshot) -> String? { nil }
}

/// Interface sounds at the moments the user can't see.
@MainActor
public protocol TurnCuePlaying: AnyObject {
    func play(_ cue: UICue)
}

/// Runs an action the brain deferred until the narration was heard. `BrainRuntime` does.
public protocol DeferredActionPerforming: Sendable {
    /// Runs it and returns its result (the brain notes failures for the next turn itself).
    func performDeferred(_ action: DeferredAction) async -> JSONValue
}

extension BrainRuntime: DeferredActionPerforming {}

/// The brain's conversation id, so voice turns land in the same history session as the brain's thread.
public protocol BrainSessionNaming: Sendable {
    func currentSessionID() async -> String
}

extension BrainRuntime: BrainSessionNaming {
    public func currentSessionID() async -> String { currentSession.id }
}

/// The microphone couldn't open, in words for the notch.
public struct TurnMicrophoneError: Error, LocalizedError, Sendable, Hashable {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Real microphone

/// The app's microphone: `MicrophoneCapture` in the stt slot's format, rebuilt when the format changes.
@MainActor
public final class CaptureTurnMicrophone: TurnMicrophone {
    private var capture: MicrophoneCapture?
    private let deviceUID: String?

    public init(deviceUID: String? = nil) { self.deviceUID = deviceUID }

    public func start(format: PCMFormat) throws -> AsyncStream<Data> {
        if capture?.options.format != format {
            capture?.close()
            capture = MicrophoneCapture(options: MicrophoneCapture.Options(format: format, deviceUID: deviceUID))
        }
        guard let capture else { return AsyncStream { $0.finish() } }
        let chunks = try capture.start()
        return AsyncStream { continuation in
            let pump = Task {
                for await chunk in chunks { continuation.yield(chunk.pcm) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func stop() { capture?.stop() }

    public var level: Float { capture?.level ?? 0 }
}

// MARK: - Image helpers

public enum TurnImages {
    /// Decodes a screenshot's JPEG (or PNG) bytes.
    public static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The drawing options for a turn whose canvas is `screenshot`: canvas units are its pixels, and `scale` maps them
    /// to the display's points.
    public static func beginOptions(for screenshot: TurnScreenshot, ink: String, pace: DrawingBeginOptions.Pace) -> DrawingBeginOptions {
        let width = max(1, Double(screenshot.pixelSize.width)), height = max(1, Double(screenshot.pixelSize.height))
        let scale = screenshot.displayFrame.width > 0 ? Double(screenshot.displayFrame.width) / width : 1
        return DrawingBeginOptions(width: width, height: height, scale: scale, ink: ink, screenshotSize: screenshot.pixelSize, pace: pace)
    }
}
