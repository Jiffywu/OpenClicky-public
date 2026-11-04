import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

private struct FakeAccessibility: AccessibilityContextSource {
    var isTrusted = true
    var window: FocusedWindowInfo?
    var focus: FocusedElementInfo?
    var address: String?
    var pageText: (text: String, truncated: Bool)?

    func focusedWindow(pid: Int32, layout: DesktopLayout) -> FocusedWindowInfo? { window }
    func focusedElement(pid: Int32, layout: DesktopLayout, valuePreviewCharacters: Int) -> FocusedElementInfo? { isTrusted ? focus : nil }
    func browserAddress(pid: Int32) -> String? { isTrusted ? address : nil }
    func webPageText(pid: Int32, deadline: Duration, maxCharacters: Int) -> (text: String, truncated: Bool)? { isTrusted ? pageText : nil }
}

private final class FakeFiles: DocumentFileSource, @unchecked Sendable {
    private let lock = NSLock()
    private let result: @Sendable (URL) throws -> FileDocumentText
    private let release: DispatchSemaphore?
    private(set) var reads: [URL] = []

    /// With `release`, every read blocks (like one waiting on a macOS permission prompt) until the test signals it.
    init(release: DispatchSemaphore? = nil, _ result: @escaping @Sendable (URL) throws -> FileDocumentText) {
        self.release = release
        self.result = result
    }

    func read(_ url: URL, limits: DocumentLimits) throws -> FileDocumentText {
        lock.withLock { reads.append(url) }
        // The limit only keeps a broken test from blocking this thread forever.
        _ = release?.wait(timeout: .now() + 30)
        return try result(url)
    }

    var readCount: Int { lock.withLock { reads.count } }
}

/// Ledger storage that reports every save, so a test can wait for a read finishing in the background to record its
/// folder instead of sleeping and hoping it has.
private final class ReportingFolderStorage: GuardedFolderLedgerStorage, @unchecked Sendable {
    let saves: AsyncStream<Set<String>>
    private let continuation: AsyncStream<Set<String>>.Continuation

    init() { (saves, continuation) = AsyncStream.makeStream() }

    func load() -> Set<String> { [] }
    func save(_ folders: Set<String>) { continuation.yield(folders) }
}

private let layout = DesktopLayout(displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isPrimary: true)])
private let home = GuardedFolderClassifier(homeDirectory: URL(fileURLWithPath: "/Users/sam"))
private let sep = String(BrowserPageScript.separator)

private func app(_ name: String, _ bundle: String) -> FrontAppInfo { FrontAppInfo(name: name, bundleIdentifier: bundle, processIdentifier: 4242) }

private func makeGatherer(_ ax: FakeAccessibility, runner: FakeScriptRunner = FakeScriptRunner { _ in "" }, automation: AutomationPermission = .granted,
                          files: FakeFiles = FakeFiles { _ in throw DocumentReadError.notFound },
                          ledger: GuardedFolderLedger = GuardedFolderLedger(classifier: home, storage: InMemoryGuardedFolderStorage()),
                          front: FrontAppInfo?) -> ScreenContextGatherer {
    let documents = ActiveDocumentReader(accessibility: ax, scripter: BrowserPageScripter(runner: runner, permission: { _, ask in
        automation == .notDetermined && ask ? .granted : automation
    }), files: files, ledger: ledger)
    return ScreenContextGatherer(accessibility: ax, documents: documents, layout: { layout }, cursor: { _ in CGPoint(x: 700, y: 300) },
                                 frontApp: { front }, permissions: { ContextPermissions(accessibility: ax.isTrusted, screenRecording: false) })
}

@Suite("Screen context gathering")
struct ScreenContextGathererTests {
    @Test func safariPageThroughScripting() async {
        var ax = FakeAccessibility()
        ax.window = FocusedWindowInfo(title: "Swift Testing — Docs", frame: CGRect(x: 0, y: 0, width: 1200, height: 900), source: .accessibility)
        ax.focus = FocusedElementInfo(role: "AXTextArea", roleDescription: "text area", label: "Notes", selectedText: "parameterized tests")
        let runner = FakeScriptRunner { _ in "https://www.example.com/docs/testing\(sep)Swift Testing — Docs\(sep)Write tests.\n\nRun them.\(sep)" }
        let context = await makeGatherer(ax, runner: runner, front: app("Safari", "com.apple.Safari")).gather(ScreenContextOptions(document: .noPrompts))
        let document = context.document
        #expect(document?.kind == .webPage)
        #expect(document?.source == .scripting)
        #expect(document?.reference == "https://www.example.com/docs/testing")
        #expect(document?.host == "example.com")
        #expect(document?.text == "Write tests.\n\nRun them.")
        #expect(context.notes.isEmpty)
        #expect(context.cursorDisplay?.id == 1)

        let json = context.jsonValue
        #expect(json["frontApp"]?["bundleID"]?.stringValue == "com.apple.Safari")
        #expect(json["document"]?["kind"]?.stringValue == "web_page")
        #expect(json["focus"]?["selectedText"]?.stringValue == "parameterized tests")
        #expect(json["permissions"]?["screenRecording"]?.boolValue == false)

        let prompt = context.promptText()
        #expect(prompt.contains("Front app: Safari (com.apple.Safari)"))
        #expect(prompt.contains("Page open: Swift Testing — Docs — https://www.example.com/docs/testing"))
        #expect(prompt.contains("Selected text: parameterized tests"))
        #expect(prompt.contains("Document text:\nWrite tests."))
    }

    @Test func chromeWithoutJavaScriptFallsBackToAccessibilityText() async {
        var ax = FakeAccessibility()
        ax.pageText = ("Text from the web area", false)
        let runner = FakeScriptRunner { _ in "https://a.test/\(sep)A\(sep)\(sep)Executing JavaScript through AppleScript is turned off." }
        let context = await makeGatherer(ax, runner: runner, front: app("Google Chrome", "com.google.Chrome")).gather(ScreenContextOptions(document: .noPrompts))
        #expect(context.document?.source == .scripting)
        #expect(context.document?.text == "Text from the web area")
        #expect(context.notes.contains { $0.contains("Allow JavaScript from Apple Events") })
        #expect(context.notes.contains { $0.contains("Accessibility tree") })
    }

    @Test func noAutomationConsentMeansNoPromptAndAnAddressBarFallback() async {
        var ax = FakeAccessibility()
        ax.address = "https://github.com/apple/swift"
        ax.window = FocusedWindowInfo(title: "apple/swift", frame: nil, source: .accessibility)
        let runner = FakeScriptRunner { _ in Issue.record("must not script without consent"); return "" }
        let context = await makeGatherer(ax, runner: runner, automation: .notDetermined, front: app("Brave Browser", "com.brave.Browser"))
            .gather(ScreenContextOptions(document: .noPrompts))
        #expect(runner.count == 0)
        #expect(context.document?.source == .accessibility)
        #expect(context.document?.reference == "https://github.com/apple/swift")
        #expect(context.document?.title == "apple/swift")
        #expect(context.notes.contains { $0.contains("hasn't been asked for yet") })
    }

    @Test func allowingPromptsLetsTheScriptRun() async {
        let runner = FakeScriptRunner { _ in "https://b.test/\(sep)B\(sep)\(sep)" }
        var options = ScreenContextOptions(document: .noPrompts)
        options.document.allowAutomationPrompt = true
        let context = await makeGatherer(FakeAccessibility(), runner: runner, automation: .notDetermined, front: app("Arc", "company.thebrowser.Browser"))
            .gather(options)
        #expect(runner.count == 1)
        #expect(context.document?.reference == "https://b.test/")
    }

    @Test func unscriptableBrowsersUseAccessibility() async {
        var ax = FakeAccessibility()
        ax.address = "https://mozilla.org/"
        ax.pageText = ("Firefox page", true)
        let context = await makeGatherer(ax, front: app("Firefox", "org.mozilla.firefox")).gather(ScreenContextOptions(document: .noPrompts))
        #expect(context.document?.reference == "https://mozilla.org/")
        #expect(context.document?.text == "Firefox page")
        #expect(context.document?.isTruncated == true)
    }

    @Test func firstReadFromAGuardedFolderIsSkippedWhenPromptsAreOff() async {
        var ax = FakeAccessibility()
        ax.window = FocusedWindowInfo(title: "plan.pdf", frame: nil, documentURL: URL(fileURLWithPath: "/Users/sam/Documents/plan.pdf"), source: .accessibility)
        let files = FakeFiles { _ in FileDocumentText(kind: .pdf, text: "Plan", isTruncated: false, pageCount: 1, byteCount: 10) }
        let context = await makeGatherer(ax, files: files, front: app("Preview", "com.apple.Preview")).gather(ScreenContextOptions(document: .noPrompts))
        #expect(files.readCount == 0)
        #expect(context.document?.kind == .pdf)
        #expect(context.document?.reference == "/Users/sam/Documents/plan.pdf")
        #expect(context.document?.awaitingFolderAccess == .documents)
        #expect(context.document?.text == nil)
        #expect(context.promptText().contains("Documents access hasn't been granted yet"))
    }

    @Test func readsAndRecordsTheFolderWhenAllowed() async {
        var ax = FakeAccessibility()
        ax.window = FocusedWindowInfo(title: "plan.pdf", frame: nil, documentURL: URL(fileURLWithPath: "/Users/sam/Documents/plan.pdf"), source: .accessibility)
        let files = FakeFiles { _ in FileDocumentText(kind: .pdf, text: "The plan", isTruncated: false, pageCount: 3, byteCount: 1234) }
        let ledger = GuardedFolderLedger(classifier: home, storage: InMemoryGuardedFolderStorage())
        let gatherer = makeGatherer(ax, files: files, ledger: ledger, front: app("Preview", "com.apple.Preview"))
        let context = await gatherer.gather(ScreenContextOptions())
        #expect(context.document?.text == "The plan")
        #expect(context.document?.pageCount == 3)
        #expect(context.document?.byteCount == 1234)
        #expect(ledger.hasRead(from: .documents))
        // Next time the folder is known, so even the no-prompt policy reads it.
        let again = await gatherer.gather(ScreenContextOptions(document: .noPrompts))
        #expect(again.document?.text == "The plan")
        #expect(files.readCount == 2)
    }

    @Test func aSlowReadTimesOutButStillRecordsWhenItFinishes() async throws {
        var ax = FakeAccessibility()
        ax.window = FocusedWindowInfo(title: "big.txt", frame: nil, documentURL: URL(fileURLWithPath: "/Users/sam/Desktop/big.txt"), source: .accessibility)
        // The read can't finish until the test lets it, so the timeout always wins, however late its timer runs.
        let release = DispatchSemaphore(value: 0)
        let files = FakeFiles(release: release) { _ in FileDocumentText(kind: .textFile, text: "late", isTruncated: false, pageCount: nil, byteCount: 4) }
        let storage = ReportingFolderStorage()
        let ledger = GuardedFolderLedger(classifier: home, storage: storage)
        var options = ScreenContextOptions()
        options.document.fileReadTimeout = .milliseconds(50)
        let context = await makeGatherer(ax, files: files, ledger: ledger, front: app("TextEdit", "com.apple.TextEdit")).gather(options)
        #expect(context.document?.text == nil)
        #expect(context.notes.contains { $0.contains("took too long") && $0.contains("Desktop") })
        #expect(!ledger.hasRead(from: .desktop))
        // The read finishes after the turn went on without it, and still records the folder.
        release.signal()
        let saved = try await withTimeout(.seconds(10)) {
            for await folders in storage.saves { return folders }
            return []
        }
        #expect(!saved.isEmpty)
        #expect(ledger.hasRead(from: .desktop))
    }

    @Test func deniedReadsAreReported() async {
        var ax = FakeAccessibility()
        ax.window = FocusedWindowInfo(title: "x", frame: nil, documentURL: URL(fileURLWithPath: "/Users/sam/Downloads/x.txt"), source: .accessibility)
        let ledger = GuardedFolderLedger(classifier: home, storage: InMemoryGuardedFolderStorage(["downloads"]))
        let files = FakeFiles { _ in throw DocumentReadError.accessDenied }
        let context = await makeGatherer(ax, files: files, ledger: ledger, front: app("TextEdit", "com.apple.TextEdit")).gather(ScreenContextOptions())
        #expect(context.document?.accessDenied == true)
        #expect(!ledger.hasRead(from: .downloads))
        #expect(context.promptText().contains("macOS denied reading this file"))
    }

    @Test func withoutAccessibilityThereIsStillAnAppAndANote() async {
        var ax = FakeAccessibility()
        ax.isTrusted = false
        ax.window = FocusedWindowInfo(title: nil, frame: CGRect(x: 10, y: 10, width: 500, height: 400), source: .windowList)
        let context = await makeGatherer(ax, front: app("Xcode", "com.apple.dt.Xcode")).gather()
        #expect(context.frontApp?.name == "Xcode")
        #expect(context.window?.source == .windowList)
        #expect(context.focus == nil)
        #expect(context.document == nil)
        #expect(context.notes.first?.contains("Accessibility permission is off") == true)
    }

    @Test func noFrontApp() async {
        let context = await makeGatherer(FakeAccessibility(), front: nil).gather()
        #expect(context.frontApp == nil)
        #expect(context.notes.contains("Couldn't tell which app is in front."))
    }

    @Test func secureFieldsStayOutOfThePrompt() {
        var context = ScreenContext(layout: layout, cursor: .zero, permissions: ContextPermissions(accessibility: true, screenRecording: true))
        context.focus = FocusedElementInfo(role: "AXTextField", subrole: "AXSecureTextField", label: "Password", isSecure: true)
        #expect(!context.promptText().contains("Password"))
        #expect(context.jsonValue["focus"]?["isSecure"]?.boolValue == true)
    }
}
