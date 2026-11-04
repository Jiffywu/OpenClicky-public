import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests for problems found reviewing the screen-context branch.

/// Draws one pointer frame into a transparent y-down bitmap the size of `display` and returns the RGBA bytes.
private func render(_ frame: PointerFrame, display: CGRect) throws -> [UInt8] {
    let width = Int(display.width), height = Int(display.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    try pixels.withUnsafeMutableBytes { raw in
        let context = try #require(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        BuddyPointerArtist.draw(frame, in: context, display: display, canvasSize: display.size)
    }
    return pixels
}

private func paintedPixels(_ pixels: [UInt8]) -> Int {
    stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] != 0 }.count
}

@Suite("Review: pointer across displays")
struct PointerAcrossDisplaysReviewTests {
    // Two displays side by side; the buddy points at a button on the left one, far from the seam.
    private let leftDisplay = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let rightDisplay = CGRect(x: 400, y: 0, width: 400, height: 300)

    private var pointing: PointerFrame {
        let target = PointingDestination.rect(CGRect(x: 100, y: 150, width: 60, height: 24)).resolved
        let gesture = PointerGesture(from: CGPoint(x: 50, y: 50), to: target, label: "Save", hold: 3)
        return gesture.frame(at: gesture.arrivalTime + 1, cursor: CGPoint(x: 50, y: 50))
    }

    @Test func theLabelOnlyShowsOnTheDisplayWithTheTip() throws {
        let frame = pointing
        #expect(frame.phase == .pointing && frame.labelOpacity > 0.99)
        #expect(paintedPixels(try render(frame, display: leftDisplay)) > 0)
        // The other display must stay empty: no label pill pinned to its edge.
        #expect(paintedPixels(try render(frame, display: rightDisplay)) == 0)
        let bounds = BuddyPointerArtist.paintedBounds(frame, display: rightDisplay, canvasSize: rightDisplay.size)
        #expect(bounds.intersection(CGRect(origin: .zero, size: rightDisplay.size)).isNull)
    }

    @Test func aLabelNearTheSeamStillFlipsOnItsOwnDisplay() throws {
        let target = PointingDestination.point(CGPoint(x: 396, y: 150)).resolved
        let gesture = PointerGesture(from: CGPoint(x: 50, y: 50), to: target, label: "Downloads", hold: 3)
        let frame = gesture.frame(at: gesture.arrivalTime + 1, cursor: CGPoint(x: 50, y: 50))
        let tip = CGPoint(x: 396, y: 150)
        let rect = BuddyPointerArtist.labelRect("Downloads", tip: tip, canvasSize: leftDisplay.size)
        #expect(rect.maxX <= leftDisplay.width, "flipped left to stay on its display")
        #expect(paintedPixels(try render(frame, display: leftDisplay)) > 0)
    }
}

// MARK: - Prefetch ordering and staleness

private final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private let reviewLayout = DesktopLayout(displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)])
private let browser = FrontAppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 41)

@Suite("Review: context prefetch ordering")
struct PrefetchOrderingReviewTests {
    /// Gathers report the window title showing at the time and a tag naming the gather.
    private func makePrefetcher(title: Locked<String>, gathers: Locked<[String]>) -> ScreenContextPrefetcher {
        ScreenContextPrefetcher(
            gather: { options in
                let tag = "gather \(options.valuePreviewCharacters)"
                gathers.value.append(tag)
                return ScreenContext(frontApp: browser, window: FocusedWindowInfo(title: title.value, frame: nil, source: .accessibility),
                                     layout: reviewLayout, cursor: .zero, permissions: ContextPermissions(accessibility: true, screenRecording: true),
                                     notes: [tag])
            },
            frontApp: { browser },
            isCurrent: { context in context.window?.title == title.value })
    }

    private func tagged(_ tag: Int) -> ScreenContextOptions { ScreenContextOptions(valuePreviewCharacters: tag) }

    @Test func aBeginThatRunsAfterItsPressWasCancelledDoesNothing() async {
        let title = Locked("Tab A"), gathers = Locked<[String]>([])
        let prefetcher = makePrefetcher(title: title, gathers: gathers)
        // The app saw key-down then a cancel, but the tasks carrying them ran the other way round.
        let press = prefetcher.keyDown()
        prefetcher.keyCancelled()
        await prefetcher.cancel()
        await prefetcher.begin(tagged(1), press: press)
        #expect(await !prefetcher.hasPending)
        // The next press (same app, seconds later) must not inherit it.
        let next = prefetcher.keyDown()
        await prefetcher.begin(tagged(2), press: next)
        #expect(await prefetcher.take(tagged(3)).notes == ["gather 2"])
    }

    @Test func aBeginThatRunsAfterKeyUpIsNotUsedByTheNextTurn() async {
        let title = Locked("Tab A"), gathers = Locked<[String]>([])
        let prefetcher = makePrefetcher(title: title, gathers: gathers)
        // Turn 1: key-up's take ran before key-down's begin.
        let first = prefetcher.keyDown()
        #expect(await prefetcher.take(tagged(9)).notes == ["gather 9"])
        await prefetcher.begin(tagged(1), press: first)
        // Turn 2, same app: its own begin hasn't run yet when its take does.
        _ = prefetcher.keyDown()
        #expect(await prefetcher.take(tagged(8)).notes == ["gather 8"], "turn 1's late read must not stand in for turn 2")
    }

    @Test func aPrefetchFromBeforeTheWindowChangedIsReadAgain() async {
        let title = Locked("Tab A"), gathers = Locked<[String]>([])
        let prefetcher = makePrefetcher(title: title, gathers: gathers)
        let press = prefetcher.keyDown()
        await prefetcher.begin(tagged(1), press: press)
        // The key-down read finishes while the key is held…
        _ = await waitUntil { !gathers.value.isEmpty }
        #expect(gathers.value == ["gather 1"])
        // …then the user switches tabs: same browser, different page.
        title.value = "Tab B"
        let context = await prefetcher.take(tagged(2))
        #expect(context.notes == ["gather 2"])
        #expect(context.window?.title == "Tab B")
    }

    @Test func anUnchangedPrefetchIsStillUsed() async {
        let title = Locked("Tab A"), gathers = Locked<[String]>([])
        let prefetcher = makePrefetcher(title: title, gathers: gathers)
        let press = prefetcher.keyDown()
        await prefetcher.begin(tagged(1), press: press)
        await prefetcher.begin(tagged(5), press: press) // a repeated begin for the same press keeps the read
        #expect(await prefetcher.take(tagged(2)).notes == ["gather 1"])
        #expect(gathers.value == ["gather 1"])
    }
}

// MARK: - Automation prompt

private struct CountingRunner: AppleScriptRunning {
    let calls = Locked(0)
    let output: String
    func run(_ source: String, timeout: Duration) async throws -> String {
        calls.value += 1
        return output
    }
}

/// Stands in for `AEDeterminePermissionToAutomateTarget` while the prompt is up: asking blocks the calling thread until
/// the test answers for the user, so the prompt is still unanswered for as long as the test needs, however slowly a
/// busy machine runs the timer that should give up on it.
private final class HeldPrompt: @unchecked Sendable {
    private let answer: AutomationPermission
    private let given = DispatchSemaphore(value: 0)
    private let answered = Locked(false)

    init(answer: AutomationPermission) { self.answer = answer }

    var permission: @Sendable (String, Bool) -> AutomationPermission {
        { [self] _, ask in
            guard ask else { return .notDetermined }
            // The limit only keeps a broken test from blocking this thread forever.
            _ = given.wait(timeout: .now() + 30)
            answered.value = true
            return answer
        }
    }

    /// Whether the user has answered yet.
    var isAnswered: Bool { answered.value }

    /// The user answers.
    func answerNow() { given.signal() }
}

@Suite("Review: Automation prompt")
struct AutomationPromptReviewTests {
    /// Stands in for `AEDeterminePermissionToAutomateTarget`: asking blocks the calling thread until the user answers,
    /// which here takes `answerAfter` seconds.
    private func permission(answerAfter seconds: Double, answer: AutomationPermission) -> @Sendable (String, Bool) -> AutomationPermission {
        { _, ask in
            guard ask else { return .notDetermined }
            Thread.sleep(forTimeInterval: seconds)
            return answer
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnansweredPromptDoesNotHoldUpTheTurn() async {
        let runner = CountingRunner(output: "https://a.test/\u{1E}A\u{1E}\u{1E}")
        let prompt = HeldPrompt(answer: .granted)
        defer { prompt.answerNow() }
        let scripter = BrowserPageScripter(runner: runner, permission: prompt.permission)
        let outcome = await scripter.read(.safari, includeText: true, maxCharacters: 100, allowPrompt: true, timeout: .seconds(3),
                                          promptTimeout: .milliseconds(200))
        #expect(!prompt.isAnswered, "the turn went on while the prompt was still up")
        #expect(outcome == .awaitingPrompt)
        #expect(runner.calls.value == 0, "no Apple Event before the user allowed it")
    }

    @Test func aPromptAnsweredInTimeReadsThePage() async {
        // Prompt timeouts far longer than the answer takes, so a busy machine can't make an answer given in time late.
        let runner = CountingRunner(output: "https://a.test/\u{1E}A\u{1E}\u{1E}")
        let scripter = BrowserPageScripter(runner: runner, permission: permission(answerAfter: 0.05, answer: .granted))
        let outcome = await scripter.read(.safari, includeText: false, maxCharacters: 100, allowPrompt: true, promptTimeout: .seconds(30))
        #expect(outcome == .page(BrowserPageInfo(url: "https://a.test/", title: "A")))
        let refused = BrowserPageScripter(runner: runner, permission: permission(answerAfter: 0.05, answer: .denied))
        #expect(await refused.read(.safari, includeText: false, maxCharacters: 100, allowPrompt: true, promptTimeout: .seconds(30))
            == .permission(.denied))
    }

    @Test func theDocumentReaderFallsBackToAccessibilityWhileThePromptIsUp() async {
        struct AddressOnly: AccessibilityContextSource {
            var isTrusted: Bool { true }
            func focusedWindow(pid: Int32, layout: DesktopLayout) -> FocusedWindowInfo? { nil }
            func focusedElement(pid: Int32, layout: DesktopLayout, valuePreviewCharacters: Int) -> FocusedElementInfo? { nil }
            func browserAddress(pid: Int32) -> String? { "https://a.test/page" }
            func webPageText(pid: Int32, deadline: Duration, maxCharacters: Int) -> (text: String, truncated: Bool)? { ("Hello", false) }
        }
        let prompt = HeldPrompt(answer: .granted)
        defer { prompt.answerNow() }
        let scripter = BrowserPageScripter(runner: CountingRunner(output: ""), permission: prompt.permission)
        let reader = ActiveDocumentReader(accessibility: AddressOnly(), scripter: scripter,
                                          ledger: GuardedFolderLedger(storage: InMemoryGuardedFolderStorage()))
        var options = ActiveDocumentOptions()
        options.automationPromptTimeout = .milliseconds(200)
        let result = await reader.read(app: browser, window: nil, options: options)
        #expect(!prompt.isAnswered)
        #expect(result.document?.reference == "https://a.test/page")
        #expect(result.document?.source == .accessibility)
        #expect(result.notes.contains { $0.contains("Automation prompt") })
    }
}

// MARK: - Special files

@Suite("Review: document files that aren't regular files")
struct SpecialDocumentFileReviewTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(.timeLimit(.minutes(1)))
    func aNamedPipeIsNotOpened() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = directory.appendingPathComponent("notes")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        // Opening a FIFO for reading blocks until a writer appears; an app's AXDocument could name one.
        let read = Task.detached { try? DocumentFileReader.read(pipe) }
        // A hang guard: a reader that doesn't block returns at once, however busy the machine.
        let result = await ActiveDocumentReader.value(of: read, timeout: .seconds(10))
        if result == nil {
            // Unblock the stuck reader so the test process can finish.
            let writer = open(pipe.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        let text = try #require(result, "the read blocked on the pipe")
        #expect(text?.text == nil)
    }

    @Test func aDeviceIsNotStreamed() throws {
        let result = try DocumentFileReader.read(URL(fileURLWithPath: "/dev/zero"))
        #expect(result.text == nil)
        #expect(result.kind == .file)
    }

    @Test func aSymlinkToARegularFileIsStillRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.txt")
        try "linked notes".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try DocumentFileReader.read(link)
        #expect(result.text == "linked notes")
        #expect(result.kind == .textFile)
        #expect(result.byteCount == 12)
    }
}

// MARK: - Web text collection cost

@Suite("Review: web text collection")
struct WebTextCollectorReviewTests {
    @Test func checkingFullnessAfterEveryRunStaysCheap() {
        // A long non-English page: thousands of text runs, checked after each one as the Accessibility walk does.
        var collector = WebTextCollector(maxCharacters: 1_000_000)
        // CPU time, not the wall clock: a busy machine parking this thread mustn't count as the collector's cost.
        let start = threadCPUTime()
        for index in 0..<6_000 {
            collector.add("Überraschung – café déjà vu \(index)", top: CGFloat(index * 20))
            #expect(!collector.isFull)
        }
        #expect(threadCPUTime() - start < .milliseconds(500), "the walk's 1.5 s deadline is for reading the tree, not recounting text")
        #expect(collector.characterCount == collector.text.count)
    }

    @Test func fullnessAndLineJoining() {
        var collector = WebTextCollector(maxCharacters: 10)
        collector.add("  Hello ", top: 10)
        collector.add("wörld", top: 11)
        #expect(collector.text == "Hello wörld")
        #expect(collector.characterCount == 11)
        #expect(collector.isFull)
        collector.add("👩‍👩‍👧", top: 40)
        #expect(collector.text == "Hello wörld\n👩‍👩‍👧")
        #expect(collector.characterCount == collector.text.count)
    }
}

// MARK: - Bounded tree search

@Suite("Review: bounded Accessibility search")
struct BoundedTreeSearchReviewTests {
    /// A wide tree (node n has children 10n+1 … 10n+10) where every visit costs `cost`, like Accessibility calls
    /// waiting out the messaging timeout on a busy app.
    private func children(_ node: Int) -> [Int] { (1...10).map { node * 10 + $0 } }

    @Test func theDeadlineStopsASlowSearch() {
        // Simulated time, so a busy machine can't stretch a visit: each one costs exactly 10 ms.
        let visits = Locked(0)
        let start = ContinuousClock.now
        let now = Locked(start)
        let found = BoundedTreeSearch.breadthFirst(from: 0, maxNodes: 600, maxDepth: 14, until: start + .milliseconds(150),
                                                   now: { now.value }) { node in
            visits.value += 1
            now.value = now.value + .milliseconds(10)
            return .descend(children(node))
        }
        #expect(found == nil)
        // Visits start at 0, 10, …, 140 ms; the deadline stops the search before a 16th, with hundreds of nodes queued.
        #expect(visits.value == 15)
    }

    @Test func findsBreadthFirstWithinLimits() {
        var order: [Int] = []
        let found = BoundedTreeSearch.breadthFirst(from: 0, maxNodes: 600, maxDepth: 14, until: .now + .seconds(5)) { node in
            order.append(node)
            if node == 22 { return .found }
            return node == 1 ? .skip : .descend(children(node))
        }
        #expect(found == 22)
        // Level by level; the skipped node's children (11…20) are never queued.
        #expect(order.prefix(11) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(!order.contains(11))
        // Depth and node limits.
        var deepest = 0
        _ = BoundedTreeSearch.breadthFirst(from: 0, maxNodes: 10_000, maxDepth: 2, until: .now + .seconds(5)) { node in
            deepest = max(deepest, node)
            return .descend(children(node))
        }
        #expect(deepest == 110, "depth 2 reaches 1…10 and 11…110, nothing deeper")
        var count = 0
        _ = BoundedTreeSearch.breadthFirst(from: 0, maxNodes: 25, maxDepth: 14, until: .now + .seconds(5)) { node in
            count += 1
            return .descend(children(node))
        }
        #expect(count == 25)
    }

    @Test func cyclesAreVisitedOnce() {
        var visits: [Int: Int] = [:]
        _ = BoundedTreeSearch.breadthFirst(from: 0, maxNodes: 600, maxDepth: 14, until: .now + .seconds(5)) { node in
            visits[node, default: 0] += 1
            return .descend([(node + 1) % 3, 0])
        }
        #expect(visits == [0: 1, 1: 1, 2: 1])
    }
}

// MARK: - Redaction

@Suite("Review: context redaction")
struct ContextRedactionReviewTests {
    @Test func notesKeepTheirWordsButLoseNamesPathsAndAddresses() throws {
        // What a failed read of a user's file really puts in the notes: NSError's description quotes the file name.
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                             userInfo: [NSLocalizedDescriptionKey: "The file “Q3 layoffs.docx” couldn’t be opened because it isn’t in the correct format.",
                                        NSFilePathErrorKey: "/Users/sam/Documents/Q3 layoffs.docx"])
        let note = DocumentFileReader.classify(denied).description
        #expect(note.contains("Q3 layoffs"), "the raw note carries the name; redaction must remove it")
        var context = ScreenContext(frontApp: FrontAppInfo(name: "Pages", bundleIdentifier: "com.apple.iWork.Pages", processIdentifier: 9),
                                    window: FocusedWindowInfo(title: "Q3 layoffs", frame: nil, source: .accessibility),
                                    document: ActiveDocument(kind: .richText, reference: "/Users/sam/Documents/Q3 layoffs.docx", title: "Q3 layoffs.docx",
                                                             text: "Confidential", source: .file),
                                    layout: reviewLayout, cursor: .zero, permissions: ContextPermissions(accessibility: true, screenRecording: true))
        context.notes = [
            note,
            "Asking Safari for its page failed: Safari got an error: Can’t open https://intranet.example.com/plan?id=7 now.",
            "Couldn't read /Users/sam/Desktop/plan.txt (denied) or ~/notes.md.",
            "Automation permission for Google Chrome hasn't been asked for yet; not prompting now.",
        ]
        let redacted = ContextRedaction.redact(context.jsonValue)
        let printed = redacted.jsonString()
        for secret in ["Q3 layoffs", "Confidential", "intranet.example.com", "plan.txt", "notes.md", "/Users/sam"] {
            #expect(!printed.contains(secret), "\(secret) leaked")
        }
        let notes = redacted["notes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        try #require(notes.count == 4)
        #expect(notes[0].hasPrefix("The file couldn't be read: The file “<name>” couldn’t be opened"))
        #expect(notes[1].contains("Can’t open <address> now."))
        #expect(notes[2] == "Couldn't read <path> (denied) or <path>")
        #expect(notes[3] == "Automation permission for Google Chrome hasn't been asked for yet; not prompting now.")
        // App identity and structure stay.
        #expect(redacted["frontApp"]?["name"]?.stringValue == "Pages")
        #expect(redacted["document"]?["kind"]?.stringValue == "rich_text")
        #expect(redacted["window"]?["title"]?.stringValue == "<10 chars>")
    }
}
