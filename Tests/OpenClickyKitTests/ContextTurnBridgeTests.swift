import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// The same four-display arrangement as the coordinate tests, plus a diagonal neighbour:
// a Retina main panel, a 1x monitor on its left (top edges aligned, negative x), one above and shifted left
// (negative Quartz y) and a portrait monitor on the right that hangs below the main display.
private let main = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)
private let left = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: -98, width: 1920, height: 1080), scale: 1, isPrimary: false)
private let above = DisplayGeometry(id: 3, frame: CGRect(x: -300, y: 982, width: 2560, height: 1440), scale: 1, isPrimary: false)
private let portrait = DisplayGeometry(id: 4, frame: CGRect(x: 1512, y: -938, width: 1080, height: 1920), scale: 1, isPrimary: false)
private let layout = DesktopLayout(displays: [main, left, above, portrait])

private func capture(_ display: DisplayGeometry, number: Int, count: Int, cursor: Bool) -> ScreenCapture {
    let size = CaptureSizing.pixelSize(pointSize: display.frame.size, scale: display.scale)
    return ScreenCapture(imageData: Data([0xFF, 0xD8, UInt8(number)]), screenNumber: number, screenCount: count, isCursorScreen: cursor,
                         display: display, pixelWidth: size.width, pixelHeight: size.height)
}

/// In reading order (left to right, then top to bottom): left, above, main, portrait. The pointer is on "above".
private let captures = [
    capture(left, number: 1, count: 4, cursor: false),
    capture(above, number: 2, count: 4, cursor: true),
    capture(main, number: 3, count: 4, cursor: false),
    capture(portrait, number: 4, count: 4, cursor: false),
]

private func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
}

private let app = FrontAppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes", processIdentifier: 77)

private let elements: [ElementSnapshot] = [
    ElementSnapshot(id: "e1", role: "AXButton", title: "Save", frame: CGRect(x: 500, y: 100, width: 76, height: 28)),
    ElementSnapshot(id: "e2", role: "AXStaticText", value: "Body text that is not a control", frame: CGRect(x: 40, y: 300, width: 300, height: 18)),
    ElementSnapshot(id: "e3", role: "AXHeading", value: "Quarterly report", frame: CGRect(x: 40, y: 700, width: 300, height: 30)),
    ElementSnapshot(id: "e4", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20)), // no label
    ElementSnapshot(id: "e5", role: "AXLink", value: "Pricing", frame: CGRect(x: -900, y: 400, width: 80, height: 18)), // left display
    ElementSnapshot(id: "e6", role: "AXButton", title: "Ghost", frame: CGRect(x: 5000, y: 5000, width: 40, height: 20)), // on no display
    ElementSnapshot(id: "e7", role: "AXTextField", subrole: "AXSearchField", placeholder: "Search", frame: CGRect(x: 900, y: 900, width: 200, height: 24)),
    ElementSnapshot(id: "e8", role: "AXButton", title: String(repeating: "Very long label ", count: 10), frame: CGRect(x: 600, y: 200, width: 60, height: 20)),
]

private let snapshot = WindowElementSnapshot(app: app, windowTitle: "Report", windowFrame: main.frame, elements: elements)

@Suite("Turn screenshots")
struct TurnScreenshotBridgeTests {
    @Test func displaysAreNamedByWhereTheySitAroundTheMainOne() {
        #expect(layout.placement(of: main) == nil)
        #expect(layout.placement(of: left) == "left")
        #expect(layout.placement(of: above) == "above")
        #expect(layout.placement(of: portrait) == "right")
        let diagonal = DisplayGeometry(id: 5, frame: CGRect(x: 1512, y: 982, width: 1000, height: 800), scale: 1, isPrimary: false)
        let below = DisplayGeometry(id: 6, frame: CGRect(x: 200, y: -1080, width: 1920, height: 1080), scale: 1, isPrimary: false)
        let wider = DesktopLayout(displays: [main, diagonal, below])
        #expect(wider.placement(of: diagonal) == "upper right")
        #expect(wider.placement(of: below) == "below")
    }

    @Test func labelsAndQuartzFrames() {
        let shots = captures.map { $0.turnScreenshot(in: layout) }
        #expect(shots.map(\.label) == ["display 1 (left)", "display 2 (above)", "main display", "display 4 (right)"])
        // Quartz: top-left of the main display, y down. The left display's top is level with the main display's.
        #expect(shots[0].displayFrame == CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        #expect(shots[1].displayFrame == CGRect(x: -300, y: -1440, width: 2560, height: 1440))
        #expect(shots[2].displayFrame == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(shots[3].displayFrame == CGRect(x: 1512, y: 0, width: 1080, height: 1920))
        #expect(shots[2].pixelSize == CGSize(width: 1280, height: 831))
        #expect(shots[3].pixelSize == CGSize(width: 720, height: 1280))
        #expect(shots[1].jpeg == captures[1].imageData)

        let single = DesktopLayout(displays: [main])
        #expect(capture(main, number: 1, count: 1, cursor: true).turnLabel(in: single) == "main display")
    }

    @Test func thePointersScreenGoesFirst() {
        let shots = captures.turnScreenshots(in: layout)
        #expect(shots.map(\.label) == ["display 2 (above)", "display 1 (left)", "main display", "display 4 (right)"])
        #expect(shots.first?.isCursorScreen == true)
        #expect(shots.dropFirst().allSatisfy { !$0.isCursorScreen })
    }

    @Test func pixelAnswersMapBackThroughTheTurnScreenshot() {
        for capture in captures {
            let shot = capture.turnScreenshot(in: layout)
            let fromTurn = CaptureGeometry(turnScreenshot: shot, layout: layout)
            #expect(fromTurn == capture.geometry)
            for pixel in [CGPoint(x: 0, y: 0), CGPoint(x: 333, y: 211), CGPoint(x: CGFloat(capture.pixelWidth), y: CGFloat(capture.pixelHeight))] {
                #expect(close(fromTurn.appKitPoint(fromPixel: pixel), capture.geometry.appKitPoint(fromPixel: pixel)))
                let resolved = PointingDestination.pixel(pixel, in: shot, layout: layout).resolved.point
                #expect(close(resolved, capture.geometry.appKitPoint(fromPixel: pixel)))
            }
        }
        // The top-left pixel of the display above the main one is AppKit (-300, 2422): negative x, far above y = 0.
        let shot = captures[1].turnScreenshot(in: layout)
        #expect(close(CaptureGeometry(turnScreenshot: shot, layout: layout).appKitPoint(fromPixel: .zero), CGPoint(x: -300, y: 2422)))
    }

    @Test func screenshotsAreFoundByLabelOrNumber() {
        let shots = captures.turnScreenshots(in: layout)
        #expect(shots.screenshot(named: nil)?.label == "display 2 (above)")
        #expect(shots.screenshot(named: "")?.label == "display 2 (above)")
        #expect(shots.screenshot(named: "Main Display")?.label == "main display")
        #expect(shots.screenshot(named: "main")?.label == "main display")
        #expect(shots.screenshot(named: "display 4 (right)")?.label == "display 4 (right)")
        #expect(shots.screenshot(named: "screen 1")?.label == "display 1 (left)")
        #expect(shots.screenshot(named: "4")?.label == "display 4 (right)")
        #expect(shots.screenshot(named: "display 9")?.label == "display 2 (above)")
        #expect(shots.screenshot(named: "the moon")?.label == "display 2 (above)")
    }
}

@Suite("Turn elements")
struct TurnElementBridgeTests {
    @Test func elementsBecomeQuartzHandlesWithFriendlyRoles() throws {
        let save = try #require(elements[0].turnElement(in: layout))
        #expect(save.id == "e1")
        #expect(save.role == "button")
        #expect(save.label == "Save")
        // AppKit y 100…128 on a 982-pt-high main display is Quartz y 854…882.
        #expect(save.frame == CGRect(x: 500, y: 854, width: 76, height: 28))
        #expect(save.appKitFrame(in: layout) == elements[0].frame)
        #expect(elements[3].turnElement(in: layout) == nil)
        let long = try #require(elements[7].turnElement(in: layout))
        #expect(long.label.count == 80)
        #expect(long.label.hasSuffix("…"))
    }

    @Test func onlyLabeledControlsAndHeadingsOnSomeDisplay() {
        let turn = snapshot.turnElements(in: layout)
        #expect(turn.map(\.id) == ["e1", "e3", "e5", "e7", "e8"])
        #expect(turn.first { $0.id == "e5" }?.frame.minX == -900)
        #expect(turn.first { $0.id == "e7" }?.role == "search field")
        #expect(snapshot.turnElements(in: layout, limit: 2).map(\.id) == ["e1", "e3"])
    }

    @Test func theBrainCanNameAnElementByIDOrLabel() throws {
        let turn = snapshot.turnElements(in: layout)
        #expect(turn.element(idOrLabel: "e5")?.label == "Pricing")
        #expect(turn.element(idOrLabel: " e1 ")?.id == "e1")
        #expect(turn.element(idOrLabel: "the Save button")?.id == "e1")
        #expect(turn.element(idOrLabel: "pricing link")?.id == "e5")
        #expect(turn.element(idOrLabel: "search field")?.id == "e7")
        #expect(turn.element(idOrLabel: "nothing like this") == nil)

        let save = try #require(turn.first { $0.id == "e1" })
        let target = PointingDestination.element(save, in: layout).resolved
        #expect(target.frame == elements[0].frame)
        #expect(target.point == PointingDestination.aimPoint(for: elements[0].frame))
        #expect(PointingDestination.quartzPoint(CGPoint(x: 10, y: 0), in: layout).resolved.point == CGPoint(x: 10, y: 982))
        #expect(PointingDestination.quartzRect(save.frame, in: layout).resolved.frame == elements[0].frame)
    }

    @Test func friendlyRolesMapBackToAXRoles() {
        for role in ["AXButton", "AXLink", "AXCheckBox", "AXTab", "AXTextArea", "AXSearchField", "AXHeading", "AXCell", "AXSlider"] {
            #expect(ElementRoles.axRole(forKindName: ElementRoles.friendlyName(role: role, subrole: nil)) == role)
        }
        #expect(ElementRoles.axRole(forKindName: "color well") == "AXColorWell")
    }
}

@Suite("Turn context")
struct TurnContextBridgeTests {
    private func context(document: ActiveDocument?, focus: FocusedElementInfo? = nil) -> ScreenContext {
        ScreenContext(frontApp: app, window: FocusedWindowInfo(title: "Report", frame: main.frame, source: .accessibility), focus: focus,
                      document: document, layout: layout, cursor: CGPoint(x: 700, y: 300),
                      permissions: ContextPermissions(accessibility: true, screenRecording: true))
    }

    @Test func webPagesAndFilesFillTheDocumentFields() {
        let page = ActiveDocument(kind: .webPage, reference: "https://example.com/pricing", title: "Pricing", text: "Plans start at $5.",
                                  source: .scripting)
        let web = context(document: page).turnContext(localTime: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(web.frontApp == "Notes")
        #expect(web.frontAppBundleID == "com.apple.Notes")
        #expect(web.windowTitle == "Report")
        #expect(web.documentURL == "https://example.com/pricing")
        #expect(web.documentTitle == "Pricing")
        #expect(web.documentText == "Plans start at $5.")
        #expect(web.documentTruncated == false)
        #expect(web.timeZone.identifier == "America/New_York")
        #expect(web.elements.isEmpty)

        let file = ActiveDocument(kind: .textFile, reference: "/Users/sam/Documents/My Notes.txt", title: "My Notes.txt",
                                  text: String(repeating: "word ", count: 100), isTruncated: true, source: .file)
        let local = context(document: file).turnContext(documentCharacters: 50)
        #expect(local.documentURL == "file:///Users/sam/Documents/My%20Notes.txt")
        #expect((local.documentText?.count ?? 0) <= 51)
        #expect(local.documentTruncated)

        let short = ActiveDocument(kind: .textFile, reference: "/tmp/a.txt", text: "tiny", isTruncated: true, source: .file)
        #expect(context(document: short).turnContext().documentTruncated, "a cut made while reading the file still counts")
        #expect(context(document: nil).turnContext().documentURL == nil)
    }

    @Test func selectionsComeAlongButNeverFromPasswordFields() {
        let selected = FocusedElementInfo(role: "AXTextArea", selectedText: "the chosen words")
        #expect(context(document: nil, focus: selected).turnContext().selectedText == "the chosen words")
        let secure = FocusedElementInfo(role: "AXTextField", subrole: "AXSecureTextField", selectedText: "hunter2", isSecure: true)
        #expect(context(document: nil, focus: secure).turnContext().selectedText == nil)
        let blank = FocusedElementInfo(role: "AXTextArea", selectedText: "  \n ")
        #expect(context(document: nil, focus: blank).turnContext().selectedText == nil)
        let huge = FocusedElementInfo(role: "AXTextArea", selectedText: String(repeating: "a", count: 10_000))
        #expect((context(document: nil, focus: huge).turnContext(selectionCharacters: 100).selectedText?.count ?? 0) <= 101)
    }

    @Test func elementsRideAlongWhenGiven() {
        let turn = context(document: nil).turnContext(elements: snapshot, elementLimit: 3)
        #expect(turn.elements.map(\.id) == ["e1", "e3", "e5"])
    }

    @Test func documentProblemsBecomeAppNotes() {
        let denied = ActiveDocument(kind: .pdf, reference: "/Users/sam/Desktop/a.pdf", source: .file, accessDenied: true)
        #expect(context(document: denied).turnAppNotes.count == 1)
        #expect(context(document: denied).turnAppNotes[0].hasPrefix("[App] "))
        let waiting = ActiveDocument(kind: .file, reference: "/Users/sam/Downloads/b.txt", source: .file, awaitingFolderAccess: .downloads)
        #expect(context(document: waiting).turnAppNotes.first?.contains("Downloads") == true)
        #expect(context(document: nil).turnAppNotes.isEmpty)
    }

    @Test func jsonForOcctlAndLogs() {
        let page = ActiveDocument(kind: .webPage, reference: "https://example.com", title: "Example", source: .accessibility)
        let json = TurnContractJSON.context(context(document: page).turnContext(elements: snapshot))
        #expect(json["frontApp"]?.stringValue == "Notes")
        #expect(json["documentURL"]?.stringValue == "https://example.com")
        #expect(json["selectedText"] == nil)
        #expect(json["elements"]?.arrayValue?.first?["id"]?.stringValue == "e1")
        #expect(json["elements"]?.arrayValue?.first?["frame"]?["y"]?.doubleValue == 854)
        let shot = TurnContractJSON.screenshot(captures[0].turnScreenshot(in: layout))
        #expect(shot["jpegBytes"]?.intValue == 3)
        #expect(shot["label"]?.stringValue == "display 1 (left)")
        #expect(shot["jpeg"] == nil)
    }
}

// MARK: - Prefetch and look

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func plainContext(_ app: FrontAppInfo?, note: String) -> ScreenContext {
    ScreenContext(frontApp: app, layout: layout, cursor: .zero, permissions: ContextPermissions(accessibility: true, screenRecording: true), notes: [note])
}

@Suite("Context prefetch")
struct ContextPrefetchTests {
    private let other = FrontAppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 88)

    /// Each gather is tagged with the options it ran with, so a test can tell the key-down read from a key-up one.
    private func makePrefetcher(front: Box<FrontAppInfo?>, gathers: Counter, clock: Box<ContinuousClock.Instant>,
                                maximumAge: Duration = .seconds(45)) -> ScreenContextPrefetcher {
        ScreenContextPrefetcher(
            gather: { options in
                _ = gathers.next()
                return plainContext(front.value, note: "tag \(options.valuePreviewCharacters)")
            },
            frontApp: { front.value },
            refresh: { $0.cursor = CGPoint(x: 1, y: 2) },
            maximumAge: maximumAge,
            now: { clock.value })
    }

    private func tagged(_ tag: Int) -> ScreenContextOptions { ScreenContextOptions(valuePreviewCharacters: tag) }

    @Test func keyUpTakesWhatKeyDownStarted() async {
        let front = Box<FrontAppInfo?>(app), gathers = Counter(), clock = Box(ContinuousClock.now)
        let prefetcher = makePrefetcher(front: front, gathers: gathers, clock: clock)
        await prefetcher.begin(tagged(1))
        await prefetcher.begin(tagged(2)) // a repeated key-down keeps the running read
        #expect(await prefetcher.hasPending)
        let context = await prefetcher.take(tagged(3))
        #expect(context.notes == ["tag 1"])
        #expect(context.cursor == CGPoint(x: 1, y: 2), "the pointer is re-read at key-up")
        #expect(gathers.count == 1)
        #expect(await !prefetcher.hasPending)
        // Nothing prefetched: a fresh gather.
        #expect(await prefetcher.take(tagged(4)).notes == ["tag 4"])
    }

    @Test func switchingAppsGathersAgain() async {
        let front = Box<FrontAppInfo?>(app), gathers = Counter(), clock = Box(ContinuousClock.now)
        let prefetcher = makePrefetcher(front: front, gathers: gathers, clock: clock)
        await prefetcher.begin(tagged(1))
        front.value = other
        let switched = await prefetcher.take(tagged(2))
        #expect(switched.notes == ["tag 2"])
        #expect(switched.frontApp?.processIdentifier == 88)
    }

    @Test func anOldPrefetchIsNotUsed() async {
        let front = Box<FrontAppInfo?>(app), gathers = Counter(), clock = Box(ContinuousClock.now)
        let prefetcher = makePrefetcher(front: front, gathers: gathers, clock: clock, maximumAge: .seconds(10))
        await prefetcher.begin(tagged(1))
        clock.value = clock.value + .seconds(11)
        #expect(await prefetcher.take(tagged(2)).notes == ["tag 2"])
    }

    @Test func aCancelledPressDropsThePrefetch() async {
        let front = Box<FrontAppInfo?>(app), gathers = Counter(), clock = Box(ContinuousClock.now)
        let prefetcher = makePrefetcher(front: front, gathers: gathers, clock: clock)
        await prefetcher.begin(tagged(1))
        await prefetcher.cancel()
        #expect(await !prefetcher.hasPending)
        #expect(await prefetcher.take(tagged(2)).notes == ["tag 2"])
    }

    @Test func aStaleRunningPrefetchIsReplacedOnTheNextKeyDown() async {
        let front = Box<FrontAppInfo?>(app), gathers = Counter(), clock = Box(ContinuousClock.now)
        let prefetcher = makePrefetcher(front: front, gathers: gathers, clock: clock, maximumAge: .seconds(10))
        await prefetcher.begin(tagged(1))
        clock.value = clock.value + .seconds(20)
        await prefetcher.begin(tagged(2))
        #expect(await prefetcher.take(tagged(3)).notes == ["tag 2"])
    }
}

private struct FakeCapturer: ScreenCapturing {
    var result: Result<[ScreenCapture], ScreenCaptureError>
    func capture(_ options: ScreenCaptureOptions) async throws -> [ScreenCapture] {
        try await Task.sleep(for: .milliseconds(20))
        return try result.get()
    }
}

@Suite("Turn look")
struct TurnLookTests {
    private func looker(capture: Result<[ScreenCapture], ScreenCaptureError>, elementsApp: FrontAppInfo = app) -> TurnLooker {
        TurnLooker(capturer: FakeCapturer(result: capture),
                   gatherContext: { _ in
                       try? await Task.sleep(for: .milliseconds(20))
                       return ScreenContext(frontApp: app, window: FocusedWindowInfo(title: "Report", frame: main.frame, source: .accessibility),
                                            layout: layout, cursor: CGPoint(x: 0, y: 1500),
                                            permissions: ContextPermissions(accessibility: true, screenRecording: true))
                   },
                   readElements: {
                       WindowElementSnapshot(app: elementsApp, windowTitle: "Report", windowFrame: main.frame, elements: elements)
                   },
                   layout: { layout })
    }

    @Test func screenshotsContextAndElementsTogether() async throws {
        let look = await looker(capture: .success(captures)).look()
        #expect(look.captureError == nil)
        #expect(look.screenshots.count == 4)
        #expect(look.screenshots.first?.label == "display 2 (above)")
        #expect(look.appNotes.isEmpty)
        let context = look.turnContext()
        #expect(context.windowTitle == "Report")
        #expect(context.elements.map(\.id) == ["e1", "e3", "e5", "e7", "e8"])

        let hit = try #require(look.destination(forElement: "e5"))
        #expect(hit.element.label == "Pricing")
        #expect(hit.destination.resolved.frame == elements[4].frame)
        #expect(look.destination(forElement: "Save")?.element.id == "e1")
        #expect(look.destination(forElement: "e6") == nil, "an element on no display can't be pointed at")

        #expect(look.capture(named: nil)?.screenNumber == 2)
        #expect(look.capture(named: "main display")?.display.id == main.id)
        #expect(look.capture(named: "display 4")?.display.id == portrait.id)
    }

    @Test func aFailedCaptureStillGivesContextAndSaysSo() async {
        let look = await looker(capture: .failure(.permissionDenied)).look()
        #expect(look.captures.isEmpty)
        #expect(look.captureError?.contains("Screen Recording") == true)
        #expect(look.appNotes.count == 1)
        #expect(look.appNotes[0].hasPrefix("[App] There is no screenshot"))
        #expect(look.turnContext().frontApp == "Notes")
        #expect(look.capture(named: nil) == nil)
    }

    @Test func elementsFromAnotherAppAreDropped() async {
        let other = FrontAppInfo(name: "Finder", bundleIdentifier: "com.apple.finder", processIdentifier: 5)
        let look = await looker(capture: .success(captures), elementsApp: other).look()
        #expect(look.elements == nil)
        #expect(look.turnContext().elements.isEmpty)
        let without = await looker(capture: .success(captures)).look(includeElements: false)
        #expect(without.elements == nil)
    }
}
