import Foundation
import Testing
@testable import OpenClickyKit

/// Answers AppleScript with canned output and records what it was asked.
final class FakeScriptRunner: AppleScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let respond: @Sendable (String) throws -> String
    private(set) var scripts: [String] = []

    init(_ respond: @escaping @Sendable (String) throws -> String) { self.respond = respond }

    func run(_ source: String, timeout: Duration) async throws -> String {
        lock.withLock { scripts.append(source) }
        return try respond(source)
    }

    var count: Int { lock.withLock { scripts.count } }
}

private let sep = String(BrowserPageScript.separator)

@Suite("Browser scripting")
struct BrowserScriptingTests {
    @Test func knowsTheScriptableBrowsers() {
        #expect(ScriptableBrowser(bundleIdentifier: "com.apple.Safari") == .safari)
        #expect(ScriptableBrowser(bundleIdentifier: "company.thebrowser.Browser")?.family == .chromium)
        #expect(ScriptableBrowser(bundleIdentifier: "com.microsoft.edgemac")?.family == .chromium)
        #expect(ScriptableBrowser(bundleIdentifier: "com.brave.Browser") == .brave)
        #expect(ScriptableBrowser(bundleIdentifier: "org.mozilla.firefox") == nil)
        #expect(ScriptableBrowser(bundleIdentifier: nil) == nil)
        #expect(BrowserCatalog.isBrowser("org.mozilla.firefox"))
        #expect(BrowserCatalog.isBrowser("com.google.Chrome"))
        #expect(!BrowserCatalog.isBrowser("com.apple.TextEdit"))
    }

    @Test func safariScriptReadsTheTabText() {
        let source = BrowserPageScript.source(for: .safari, includeText: true, maxCharacters: 5000)
        #expect(source.contains("tell application id \"com.apple.Safari\""))
        #expect(source.contains("current tab of front window"))
        #expect(source.contains("text of theTab"))
        #expect(!source.contains("javascript"))
        let noText = BrowserPageScript.source(for: .safari, includeText: false, maxCharacters: 5000)
        #expect(!noText.contains("text of theTab"))
    }

    @Test func chromiumScriptRunsCappedJavaScript() {
        let source = BrowserPageScript.source(for: .arc, includeText: true, maxCharacters: 5000)
        #expect(source.contains("application id \"company.thebrowser.Browser\""))
        #expect(source.contains("active tab of front window"))
        #expect(source.contains("execute javascript"))
        #expect(source.contains("title of theTab"))
        // One more than the limit, so a cut page can be told apart.
        #expect(source.contains("5001"))
    }

    @Test func appleScriptLiteralsEscape() {
        #expect(BrowserPageScript.literal("plain") == "\"plain\"")
        #expect(BrowserPageScript.literal("say \"hi\"\\now\n") == "\"say \\\"hi\\\"\\\\now\\n\"")
    }

    @Test func parsesURLTitleAndText() throws {
        let output = "https://example.com/a?b=1\(sep)Example — Docs\(sep)  Heading\n\n\n\nBody   text \(sep)\n"
        let info = try #require(BrowserPageScript.parse(output, maxCharacters: 1000))
        #expect(info.url == "https://example.com/a?b=1")
        #expect(info.title == "Example — Docs")
        #expect(info.text == "Heading\n\nBody text")
        #expect(info.textError == nil)
        #expect(!info.textTruncated)
    }

    @Test func parsesTextErrorsAndMissingValues() throws {
        let output = "https://news.example.org/\(sep)missing value\(sep)\(sep)Executing JavaScript through AppleScript is turned off."
        let info = try #require(BrowserPageScript.parse(output, maxCharacters: 1000))
        #expect(info.title == nil)
        #expect(info.text == nil)
        #expect(info.textError?.hasPrefix("Executing JavaScript") == true)
    }

    @Test func noWindowOrBlankTabIsNoPage() {
        #expect(BrowserPageScript.parse("", maxCharacters: 100) == nil)
        #expect(BrowserPageScript.parse("\n", maxCharacters: 100) == nil)
        #expect(BrowserPageScript.parse("missing value\(sep)\(sep)\(sep)", maxCharacters: 100) == nil)
    }

    @Test func longPagesAreCutAndFlagged() throws {
        let text = String(repeating: "word ", count: 400)
        let info = try #require(BrowserPageScript.parse("https://x.test/\(sep)T\(sep)\(text)\(sep)", maxCharacters: 100))
        #expect(info.textTruncated)
        #expect((info.text?.count ?? 0) <= 100)
        #expect(info.text?.hasSuffix("word") == true)
    }

    @Test func titlesMayContainSeparatorsOfOtherKinds() throws {
        let info = try #require(BrowserPageScript.parse("https://a.test/\(sep)A | B — C\tD\(sep)x\(sep)", maxCharacters: 10))
        #expect(info.title == "A | B — C\tD")
    }

    @Test func osascriptErrorCodesAreParsed() {
        let denied = AppleScriptError(osascriptStderr: "152:200: execution error: Not authorized to send Apple events to Safari. (-1743)\n")
        #expect(denied.code == -1743)
        #expect(denied.isPermissionDenied)
        let other = AppleScriptError(osascriptStderr: "execution error: Can’t get window 1. Invalid index. (-1719)")
        #expect(other.code == -1719)
        #expect(!other.isPermissionDenied)
        #expect(AppleScriptError(osascriptStderr: "something odd").code == nil)
    }

    @Test func scripterChecksPermissionBeforeSendingAnything() async {
        let runner = FakeScriptRunner { _ in "https://a.test/\(sep)A\(sep)\(sep)" }
        let scripter = BrowserPageScripter(runner: runner, permission: { _, ask in ask ? .granted : .notDetermined })
        let outcome = await scripter.read(.safari, includeText: true, maxCharacters: 100, allowPrompt: false)
        #expect(outcome == .permission(.notDetermined))
        #expect(runner.count == 0)
        let allowed = await scripter.read(.safari, includeText: true, maxCharacters: 100, allowPrompt: true)
        #expect(allowed == .page(BrowserPageInfo(url: "https://a.test/", title: "A")))
        #expect(runner.count == 1)
    }

    @Test func scripterMapsDeniedErrorsAndFailures() async {
        let denied = BrowserPageScripter(runner: FakeScriptRunner { _ in throw AppleScriptError(code: -1743, message: "nope (-1743)") },
                                         permission: { _, _ in .granted })
        #expect(await denied.read(.chrome, includeText: false, maxCharacters: 10, allowPrompt: false) == .permission(.denied))
        let broken = BrowserPageScripter(runner: FakeScriptRunner { _ in throw AppleScriptError.timedOut }, permission: { _, _ in .granted })
        #expect(await broken.read(.chrome, includeText: false, maxCharacters: 10, allowPrompt: false) == .failed("The browser didn't answer in time."))
        let empty = BrowserPageScripter(runner: FakeScriptRunner { _ in "" }, permission: { _, _ in .granted })
        #expect(await empty.read(.edge, includeText: false, maxCharacters: 10, allowPrompt: false) == .noPage)
    }

    @Test func osascriptRunnerRunsMultiLineScripts() async throws {
        // Plain AppleScript with no app targets: needs no permission.
        let output = try await OsascriptRunner().run("set a to \"one\"\nset b to \"two\"\nreturn a & (character id 30) & b", timeout: .seconds(10))
        #expect(output == "one\(sep)two\n")
        await #expect(throws: AppleScriptError.self) { try await OsascriptRunner().run("error \"boom\" number -42", timeout: .seconds(10)) }
    }
}
