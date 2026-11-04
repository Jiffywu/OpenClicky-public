import AppKit
import OpenClickyKit

/// The app's eyes: screenshots without OpenClicky's own overlays, the context around them, and the front window's
/// elements for pointing by label. Slow work (Accessibility walks, file reads, captures) runs off the main thread.
///
/// A voice turn uses it like this:
///
///     screenLook.prefetchContext()                  // key-down: the open document is read while the user talks
///     let look = await screenLook.lookForTurn()      // key-up: screenshots + context + elements, concurrently
///     let input = TurnInput(words: transcript, screenshots: look.screenshots,
///                           context: look.turnContext(), appNotes: look.appNotes)
///     …
///     if let hit = look.destination(forElement: "e12") { await pointer.point(to: hit.destination, label: hit.element.label) }
@MainActor
final class ScreenLookService {
    let frontApps: FrontAppTracker
    let capturer: any ScreenCapturing
    let gatherer: ScreenContextGatherer
    let elementReader: AccessibilityElementReader
    let prefetcher: ScreenContextPrefetcher
    /// OpenClicky's own windows and whether its screenshots and other apps' recordings see them.
    let capturePolicy: OwnWindowCapturePolicy
    /// Window numbers to leave out of screenshots besides the registered ones (the overlay panels).
    var ownWindowNumbers: () -> [Int]
    /// The last turn's look, so a follow-up pointing request can resolve element ids from it.
    private(set) var lastLook: TurnLook?
    /// Each turn's look as it is taken (the notch shows a folder-access notice from it).
    var onLook: ((TurnLook) -> Void)?

    init(ownWindowNumbers: @escaping () -> [Int], capturer: any ScreenCapturing = ScreenCaptureKitCapturer(),
         capturePolicy: OwnWindowCapturePolicy = OwnWindowCapturePolicy()) {
        let frontApps = FrontAppTracker()
        frontApps.start()
        self.frontApps = frontApps
        self.capturer = capturer
        let gatherer = ScreenContextGatherer.live(frontApps: frontApps)
        self.gatherer = gatherer
        self.elementReader = AccessibilityElementReader()
        self.prefetcher = ScreenContextPrefetcher(gatherer: gatherer)
        self.capturePolicy = capturePolicy
        self.ownWindowNumbers = ownWindowNumbers
    }

    private var exclusion: CaptureExclusion { capturePolicy.exclusion(adding: ownWindowNumbers()) }

    /// Key-down: start reading the front app's context and open document. Shows the Automation and folder prompts when
    /// needed, since the user is at the Mac asking a question.
    func prefetchContext() {
        let prefetcher = self.prefetcher
        // Numbered here, in key order, so a begin task that runs late can tell it is stale.
        let press = prefetcher.keyDown()
        Task.detached(priority: .userInitiated) { await prefetcher.begin(press: press) }
    }

    /// The press was cancelled: drop the prefetched context.
    func cancelPrefetch() {
        let prefetcher = self.prefetcher
        prefetcher.keyCancelled()
        Task { await prefetcher.cancel() }
    }

    /// Key-up: screenshots of every display (after a short settle), the context (prefetched when available) and the
    /// front window's elements, gathered concurrently. `afterAction` waits longer for the screen to settle (after the
    /// user clicked a guided target).
    func lookForTurn(displays: ScreenCaptureOptions.Displays = .all, afterAction: Bool = false, includeElements: Bool = true) async -> TurnLook {
        let captureOptions = ScreenCaptureOptions(displays: displays, exclusion: exclusion, settle: afterAction ? .afterAction : .quick)
        let looker = TurnLooker.live(frontApps: frontApps, capturer: capturer, prefetcher: prefetcher, gatherer: gatherer, elementReader: elementReader)
        let look = await Task.detached(priority: .userInitiated) {
            await looker.look(capture: captureOptions, includeElements: includeElements)
        }.value
        lastLook = look
        onLook?(look)
        return look
    }

    /// Screenshots only: every display, the pointer's flagged, after a short settle.
    func captureTurn(displays: ScreenCaptureOptions.Displays = .all, afterAction: Bool = false) async throws -> [ScreenCapture] {
        let options = ScreenCaptureOptions(displays: displays, exclusion: exclusion, settle: afterAction ? .afterAction : .quick)
        let capturer = self.capturer
        return try await Task.detached(priority: .userInitiated) { try await capturer.capture(options) }.value
    }

    /// Front app, window, focus, selection and document.
    func context(includeDocumentText: Bool = true) async -> ScreenContext {
        var options = ScreenContextOptions()
        options.document.includeText = includeDocumentText
        let gatherer = self.gatherer
        return await Task.detached(priority: .userInitiated) { await gatherer.gather(options) }.value
    }

    /// The front window's controls, for pointing by label or element id.
    func elements() async -> WindowElementSnapshot? {
        guard let app = frontApps.current else { return nil }
        let reader = elementReader
        return await Task.detached(priority: .userInitiated) { reader.snapshot(of: app) }.value
    }

    /// Points the buddy at an element the brain named by id ("e12") or label in the last turn's look, falling back to
    /// a fresh snapshot of the front window. False when nothing matched.
    @discardableResult
    func point(atElement query: String, with pointer: BuddyPointerController, label: String? = nil, hold: TimeInterval? = 2.4) async -> Bool {
        if let hit = lastLook?.destination(forElement: query) {
            await pointer.point(to: hit.destination, label: label ?? hit.element.label, hold: hold)
            return true
        }
        return await point(atLabel: query, with: pointer, label: label, hold: hold)
    }

    /// Points the buddy at the control `query` names in the front window. False when nothing matched.
    @discardableResult
    func point(atLabel query: String, with pointer: BuddyPointerController, label: String? = nil, hold: TimeInterval? = 2.4) async -> Bool {
        guard let snapshot = await elements() else { return false }
        return await pointer.point(toLabel: query, in: snapshot, label: label, hold: hold)
    }

    /// Points at a pixel a model named, snapping to the real control there when one is close, so the ring outlines
    /// the button rather than a guessed circle.
    func point(atPixel pixel: CGPoint, screen: Int?, in captures: [ScreenCapture], with pointer: BuddyPointerController, label: String?,
               hold: TimeInterval? = 2.4) async {
        guard let capture = captures.capture(screen: screen) else { return }
        let global = capture.geometry.appKitPoint(fromPixel: pixel)
        if let snapshot = await elements(), let element = ElementSnapper.snap(global, in: snapshot.elements) {
            await pointer.point(toElement: element, label: label, hold: hold)
        } else {
            await pointer.point(toGlobal: global, label: label, hold: hold)
        }
    }

    /// Points at a pixel of a turn screenshot the brain named by label ("display 2 (left)") or number.
    func point(atPixel pixel: CGPoint, screenshot name: String?, with pointer: BuddyPointerController, label: String?,
               hold: TimeInterval? = 2.4) async {
        guard let look = lastLook, let capture = look.capture(named: name) else { return }
        await point(atPixel: pixel, screen: capture.screenNumber, in: look.captures, with: pointer, label: label, hold: hold)
    }
}
