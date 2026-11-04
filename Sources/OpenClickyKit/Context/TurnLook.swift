import CoreGraphics
import Foundation

/// Starts gathering the screen context when the talk key goes down, so the open document is read (and any one-time
/// permission prompt answered) while the user is still speaking. At key-up the turn takes the result, or gathers
/// afresh when the user switched apps or windows in between or the prefetch is too old.
///
/// The app reports key-down and cancel synchronously with `keyDown()` / `keyCancelled()` where the key event arrives,
/// then starts `begin(press:)` in a task. Tasks don't run in the order they were made, so the press numbers decide:
/// a `begin` that runs after its press was cancelled or taken, or after a newer key-down, does nothing, and `take`
/// only uses a prefetch made for the current press.
public actor ScreenContextPrefetcher {
    public typealias Gather = @Sendable (ScreenContextOptions) async -> ScreenContext

    private struct Pending {
        var task: Task<ScreenContext, Never>
        var pid: Int32?
        var startedAt: ContinuousClock.Instant
        var press: Int?
    }

    private let gather: Gather
    private let frontApp: @Sendable () -> FrontAppInfo?
    /// Refreshes what moves while the key is held (the pointer, the display arrangement) on a prefetched context.
    private let refresh: @Sendable (inout ScreenContext) -> Void
    /// Whether a prefetched context still describes the screen at key-up (same window and document); false gathers again.
    private let isCurrent: @Sendable (ScreenContext) -> Bool
    private let now: @Sendable () -> ContinuousClock.Instant
    public let maximumAge: Duration
    private var pending: Pending?
    private nonisolated let presses = PressOrder()

    public init(gather: @escaping Gather, frontApp: @escaping @Sendable () -> FrontAppInfo?,
                refresh: @escaping @Sendable (inout ScreenContext) -> Void = { _ in },
                isCurrent: @escaping @Sendable (ScreenContext) -> Bool = { _ in true }, maximumAge: Duration = .seconds(45),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.gather = gather
        self.frontApp = frontApp
        self.refresh = refresh
        self.isCurrent = isCurrent
        self.maximumAge = maximumAge
        self.now = now
    }

    public init(gatherer: ScreenContextGatherer, maximumAge: Duration = .seconds(45)) {
        self.init(gather: { await gatherer.gather($0) }, frontApp: gatherer.frontApp, refresh: { context in
            let layout = gatherer.layout()
            context.layout = layout
            context.cursor = gatherer.cursor(layout)
        }, isCurrent: { context in
            // A browser tab switch or another document window keeps the app but changes the window's title or file.
            guard let app = context.frontApp, let before = context.window else { return true }
            let now = gatherer.accessibility.focusedWindow(pid: app.processIdentifier, layout: context.layout)
            return now?.title == before.title && now?.documentURL == before.documentURL
        }, maximumAge: maximumAge)
    }

    /// Key-down, called where the key event arrives (any thread). Pass the number to `begin(_:press:)`.
    public nonisolated func keyDown() -> Int { presses.open() }

    /// The press was dropped, called where that was decided. A `begin` for it that runs later does nothing.
    public nonisolated func keyCancelled() { presses.close() }

    /// Key-down: start reading. A prefetch already running for the same press (or, without press numbers, the same
    /// app) is kept.
    public func begin(_ options: ScreenContextOptions = ScreenContextOptions(), press: Int? = nil) {
        if let press, !presses.isLive(press) { return }
        let pid = frontApp()?.processIdentifier
        if let pending, pending.press == press, pending.pid == pid, now() - pending.startedAt < maximumAge { return }
        let gather = self.gather
        pending = Pending(task: Task { await gather(options) }, pid: pid, startedAt: now(), press: press)
    }

    /// Whether a prefetch is waiting to be taken.
    public var hasPending: Bool { pending != nil }

    /// Key-up: the prefetched context when it was made for this press, the same app and window are still in front and
    /// it is fresh enough, else a new gather.
    public func take(_ options: ScreenContextOptions = ScreenContextOptions()) async -> ScreenContext {
        let pid = frontApp()?.processIdentifier
        let usable = pending.map { ($0.press.map(presses.isLive) ?? true) && $0.pid == pid && now() - $0.startedAt <= maximumAge } ?? false
        let taken = usable ? pending : nil
        pending = nil
        // A begin for this press that hasn't run yet must not leave a prefetch behind for the next turn.
        presses.close()
        if let taken {
            var context = await taken.task.value
            if isCurrent(context) {
                refresh(&context)
                return context
            }
        }
        return await gather(options)
    }

    /// Forget the prefetch (the press was cancelled). A read in flight finishes in the background. A prefetch made for
    /// a newer, still-open press is kept.
    public func cancel() {
        if let press = pending?.press, presses.isLive(press) { return }
        pending = nil
    }
}

/// Press numbers, updated synchronously where key events arrive so late-running tasks can tell they are stale.
final class PressOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    private var closed = 0

    /// A new press; every earlier one is over.
    func open() -> Int { lock.withLock { latest += 1; return latest } }

    /// The current press was cancelled or taken.
    func close() { lock.withLock { closed = latest } }

    /// The newest press, not yet cancelled or taken.
    func isLive(_ press: Int) -> Bool { lock.withLock { press == latest && press > closed } }
}

/// Everything OpenClicky saw for one turn: the screenshots, the context and the front window's elements.
public struct TurnLook: Sendable {
    public var layout: DesktopLayout
    /// Every captured display; empty when capturing failed.
    public var captures: [ScreenCapture]
    /// Why there are no screenshots, in plain words.
    public var captureError: String?
    public var context: ScreenContext
    /// The front window's elements (nil without Accessibility or when the front app changed during the look).
    public var elements: WindowElementSnapshot?
    public var elapsed: Duration

    public init(layout: DesktopLayout, captures: [ScreenCapture], captureError: String? = nil, context: ScreenContext,
                elements: WindowElementSnapshot? = nil, elapsed: Duration = .zero) {
        self.layout = layout
        self.captures = captures
        self.captureError = captureError
        self.context = context
        self.elements = elements
        self.elapsed = elapsed
    }

    /// The captures in the order the turn sends them: the pointer's display first, then reading order.
    public var orderedCaptures: [ScreenCapture] { captures.filter(\.isCursorScreen) + captures.filter { !$0.isCursorScreen } }

    /// The turn's screenshots, the pointer's display first.
    public var screenshots: [TurnScreenshot] { orderedCaptures.map { $0.turnScreenshot(in: layout) } }

    public func turnContext(documentCharacters: Int = 20_000, elementLimit: Int = 150, localTime: Date = Date(),
                            timeZone: TimeZone = .current) -> TurnContext {
        context.turnContext(elements: elements, documentCharacters: documentCharacters, elementLimit: elementLimit,
                            localTime: localTime, timeZone: timeZone)
    }

    /// "[App] …" notes for the brain about what it can't see this turn.
    public var appNotes: [String] {
        var notes = context.turnAppNotes
        if captures.isEmpty {
            var reason = captureError ?? "the screen couldn't be captured"
            while reason.hasSuffix(".") { reason.removeLast() }
            notes.append("[App] There is no screenshot this turn (\(reason)). Don't guess at what is on screen.")
        }
        return notes
    }

    /// The capture the brain means by a screenshot label or number, for mapping its pixel answers back.
    public func capture(named name: String?) -> ScreenCapture? {
        let shots = screenshots
        guard let shot = shots.screenshot(named: name),
              let index = shots.firstIndex(where: { $0.label == shot.label && $0.displayFrame == shot.displayFrame }) else { return nil }
        return orderedCaptures[index]
    }

    /// Resolve an element id (or label) the brain named to a pointing destination.
    public func destination(forElement query: String) -> (element: TurnElement, destination: PointingDestination)? {
        guard let snapshot = elements else { return nil }
        let candidates = snapshot.turnElements(in: layout, limit: .max)
        guard let element = candidates.element(idOrLabel: query) else { return nil }
        return (element, .element(element, in: layout))
    }
}

/// Takes one turn's look: capture (with the settle wait), context and the element snapshot run concurrently.
public struct TurnLooker: Sendable {
    public var capturer: any ScreenCapturing
    public var gatherContext: @Sendable (ScreenContextOptions) async -> ScreenContext
    /// Reads the front window's elements for the app in front right now, or nil.
    public var readElements: @Sendable () -> WindowElementSnapshot?
    public var layout: @Sendable () -> DesktopLayout

    public init(capturer: any ScreenCapturing, gatherContext: @escaping @Sendable (ScreenContextOptions) async -> ScreenContext,
                readElements: @escaping @Sendable () -> WindowElementSnapshot?, layout: @escaping @Sendable () -> DesktopLayout = { .current() }) {
        self.capturer = capturer
        self.gatherContext = gatherContext
        self.readElements = readElements
        self.layout = layout
    }

    /// The real thing. Pass the prefetcher started at key-down so the document read overlaps the user's speech.
    public static func live(frontApps: FrontAppTracker, capturer: any ScreenCapturing = ScreenCaptureKitCapturer(),
                            prefetcher: ScreenContextPrefetcher? = nil, gatherer: ScreenContextGatherer? = nil,
                            elementReader: AccessibilityElementReader = AccessibilityElementReader()) -> TurnLooker {
        let gatherer = gatherer ?? .live(frontApps: frontApps)
        return TurnLooker(
            capturer: capturer,
            gatherContext: { options in
                if let prefetcher { return await prefetcher.take(options) }
                return await gatherer.gather(options)
            },
            readElements: {
                guard let app = frontApps.current else { return nil }
                return elementReader.snapshot(of: app)
            })
    }

    public func look(capture options: ScreenCaptureOptions = ScreenCaptureOptions(), context contextOptions: ScreenContextOptions = ScreenContextOptions(),
                     includeElements: Bool = true) async -> TurnLook {
        let clock = ContinuousClock()
        let start = clock.now
        let capturer = self.capturer, readElements = self.readElements, gatherContext = self.gatherContext
        async let captured = Self.captureResult(capturer, options)
        async let snapshot: WindowElementSnapshot? = includeElements ? readElements() : nil
        let context = await gatherContext(contextOptions)
        var elements = await snapshot
        // Elements from a different app than the context's would point at the wrong window.
        if let app = elements?.app, app.processIdentifier != context.frontApp?.processIdentifier { elements = nil }
        var look = TurnLook(layout: layout(), captures: [], context: context, elements: elements)
        switch await captured {
        case .success(let captures): look.captures = captures
        case .failure(let error): look.captureError = String(describing: error)
        }
        look.elapsed = clock.now - start
        return look
    }

    private static func captureResult(_ capturer: any ScreenCapturing, _ options: ScreenCaptureOptions) async -> Result<[ScreenCapture], Error> {
        do { return .success(try await capturer.capture(options)) } catch { return .failure(error) }
    }
}
