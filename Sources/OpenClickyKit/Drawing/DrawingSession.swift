import CoreGraphics
import Foundation
import QuartzCore

/// One live drawing: the engine host and the painter wired together, the way the overlay uses them.
///
/// Feed it the brain's program text as it streams (`begin`, `append`, `end`) and hand it to the voice as the
/// contract's `SpeechPacing`. Program text and voice timings go to the engine's queue in order; the resulting events
/// are painted on the main actor. While a drawing is in progress the session drains the engine about 60 times a
/// second, so held marks are released when their moment comes. Put `layer` in the overlay.
@MainActor
public final class DrawingSession: SpeechPacing {
    public let host: DrawingEngineHost
    public let painter: DrawingPainter
    /// Events the painter doesn't draw: `step`, `warning`, `error`, `ask` (a clicked button's question), `request`
    /// (a plugin wants data; see `DrawingMediaResolver`) and `done`. Actions due on a line arrive only from the live
    /// drawing (not after `cancel()`, `clear()` or a newer `begin`); clicked buttons and links always arrive.
    public var onEvent: ((DrawingEvent) -> Void)?
    /// Marks as the engine releases them, just before they are painted. Hosts that act on marks at their beat use it
    /// (guided targets arm when their line is heard; see `GuidedWalkthroughController`). Marks that arrive after
    /// `cancel()`, `clear()` or a newer `begin` are painted (until cleared) but not passed here.
    public var onMarks: (([DrawingMark]) -> Void)?
    /// True between `begin` and the engine's `done` (or `cancel`).
    public private(set) var isDrawing = false

    private var ticker: Task<Void, Never>?
    private let tickInterval: TimeInterval
    /// `begin`s sent to the engine whose events haven't come back yet.
    private var pendingBegins = 0
    /// The engine's number for the program this session began last (see `DrawingEngineHost.send(_:deliverWithProgram:)`).
    private var currentProgram: Int?
    /// The program the events being painted right now came from.
    private var deliveringProgram: Int?

    public init(host: DrawingEngineHost, painter: DrawingPainter, tickInterval: TimeInterval = 1.0 / 60) {
        self.host = host
        self.painter = painter
        self.tickInterval = tickInterval
        painter.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// A session on the media clock. `screen` (a sampler over the screenshot the brain saw) makes ink readable and
    /// keeps pills off busy parts of the screen.
    public convenience init(canvas: DrawingPainter.Canvas, figureSink: (any FigureSink)? = nil,
                            screen: DrawingScreenSampler? = nil, screenImage: CGImage? = nil) throws {
        var luminance: DrawingEngineHost.Luminance?
        var busyness: DrawingEngineHost.Busyness?
        if let screen {
            luminance = { rect in screen.luminance(in: rect) }
            busyness = { rect in screen.busyness(in: rect) }
        }
        let host = try DrawingEngineHost(luminance: luminance, busyness: busyness)
        self.init(host: host, painter: DrawingPainter(canvas: canvas, figureSink: figureSink))
        painter.screen = screenImage
    }

    /// The layer to show: y-down, sized to the canvas in points.
    public var layer: CALayer { painter.layer }

    // MARK: The program

    /// Start a drawing. Unless `options.keep` is set, what was drawn before fades out.
    public func begin(_ options: DrawingBeginOptions) {
        isDrawing = true
        pendingBegins += 1
        host.send(.begin(options), deliverWithProgram: { [weak self] events, number in
            guard let self else { return }
            self.pendingBegins -= 1
            self.currentProgram = number
            self.deliver(events, program: number)
        })
        startTicking()
    }

    /// More program text arrived from the brain.
    public func append(_ text: String) { send(.append(text)) }

    /// The program is complete.
    public func end() { send(.end) }

    /// Draw everything still waiting for the voice, right away (the voice was cut off or skipped).
    public func finishNow() { send(.finishNow) }

    /// Stop the drawing where it is.
    public func cancel() {
        send(.cancel)
        isDrawing = false
        stopTicking()
    }

    /// Remove everything from the canvas at once.
    public func clear() {
        cancel()
        painter.clear()
        // Events the engine produced just before (a line the voice started a moment ago) are still on their way to
        // the main queue and would paint over the cleared canvas: clear again once they have landed.
        host.send(.drain, deliverWithProgram: { [weak self] events, number in
            self?.deliver(events, program: number)
            self?.painter.clear()
        })
    }

    /// The host's answer to a `request` event (a photo, a place, a quote arrived): the engine merges `fields` into the
    /// mark and repaints it. Answers for a card that has since been replaced are ignored.
    public func patch(_ ref: String, fields: JSONValue) { send(.patch(ref: ref, fields: fields)) }

    /// A click at a point in `layer` (points, y down). Returns true when it hit a drawn button or linked words; the
    /// button's question then arrives as an `ask` event, its other actions (open, copy, hand off) and links as `action`.
    @discardableResult
    public func click(at point: CGPoint) -> Bool {
        guard let id = painter.clickableID(at: point) else { return false }
        send(.click(id))
        return true
    }

    /// Hold the pen where it is: strokes under way stop, marks still to come wait (program text keeps arriving).
    public func pause() {
        send(.pause)
        painter.pause()
    }

    /// Carry on after `pause()`, as if no time had passed.
    public func resume() {
        send(.resume)
        painter.resume()
    }

    /// The voice has spoken `count` words of the answer so far, for voices that report a running word count rather
    /// than line by line: lines start and finish as the count passes them.
    public nonisolated func wordsSpoken(_ count: Int) {
        host.send(.spoken(count), deliverWithProgram: { [weak self] events, number in
            self?.deliver(events, program: number)
        })
    }

    /// Keep this card for a follow-up turn (`DrawingEngineHost.continueTurn()`); begin the next program with `keep: true`.
    public func continueTurn() -> JSONValue? { host.continueTurn() }

    /// The beat being heard and its statements' progress, for the debug captions.
    public func beats() -> DrawingBeats? { host.beats() }

    // MARK: SpeechPacing (called by the voice from any thread)

    public nonisolated func lineStarted(_ index: Int, expectedDuration: TimeInterval?) {
        host.send(.lineStarted(index, expectedDuration), deliverWithProgram: { [weak self] events, number in
            self?.deliver(events, program: number)
        })
    }

    public nonisolated func lineFinished(_ index: Int) {
        host.send(.lineFinished(index), deliverWithProgram: { [weak self] events, number in
            self?.deliver(events, program: number)
        })
    }

    // MARK: Draining

    /// Drain the engine once (the session does this about 60 times a second while drawing).
    public func tick() { send(.drain) }

    /// Wait until every command sent so far has run and its events have been painted.
    public func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            host.send(.drain, deliverWithProgram: { [weak self] events, number in
                self?.deliver(events, program: number)
                continuation.resume()
            })
        }
    }

    private func send(_ command: DrawingEngineHost.Command) {
        host.send(command, deliverWithProgram: { [weak self] events, number in self?.deliver(events, program: number) })
    }

    func deliver(_ events: [DrawingEvent], program number: Int) {
        deliveringProgram = number
        defer { deliveringProgram = nil }
        // Only the live drawing's marks: ones still arriving from a cancelled or replaced program (a barge-in) must not
        // act, e.g. arm a guided target during the user's new turn.
        let live = isDrawing && pendingBegins == 0 && number == currentProgram
        if let onMarks, live {
            let released = events.flatMap { event -> [DrawingMark] in if case .marks(let marks) = event { marks } else { [] } }
            if !released.isEmpty { onMarks(released) }
        }
        // The same goes for actions due on a line (type, open, hand off): only a click (a button or link the user
        // pressed on a drawing still showing) acts once its program has stopped.
        var events = events
        if !live {
            events.removeAll { event in
                if case .action(let action) = event { !action.fromClick } else { false }
            }
        }
        painter.apply(events)
    }

    private func handle(_ event: DrawingEvent) {
        if event == .done {
            // A `done` from a program this session has since replaced (cancel, then begin) must not stop the new one.
            guard pendingBegins == 0, let current = currentProgram, deliveringProgram == current else { return }
            isDrawing = false
            stopTicking()
        }
        onEvent?(event)
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let interval = tickInterval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}
