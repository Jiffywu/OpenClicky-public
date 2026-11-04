import Foundation
import Testing
@testable import OpenClickyKit

@Suite("open_url link policy")
struct WebLinkPolicyTests {
    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "  javascript:void(0)", "file:///etc/passwd", "FILE:///Users/x",
        "data:text/html,<script>alert(1)</script>", "mailto:a@b.com", "ftp://example.com/x", "vbscript:msgbox",
        "x-apple.systempreferences:com.apple.preference.security", "spotify:track:4uLU6hMCjMI75M1A2tKUQC",
        "about:blank", "chrome://settings",
    ])
    func refusesEverySchemeButHTTPAndHTTPS(_ link: String) {
        #expect(throws: ToolArgumentError.self) { try WebLinkPolicy.normalize(link) }
        do {
            _ = try WebLinkPolicy.normalize(link)
        } catch let error as ToolArgumentError {
            #expect(error.status == .refused, "\(link)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test(arguments: ["java\nscript:alert(1)", "java\tscript:alert(1)", "https://exa mple.com", "https://example.com/\u{0}"])
    func refusesSmuggledWhitespaceAndControlCharacters(_ link: String) {
        #expect(throws: ToolArgumentError.refused("The link contains spaces or control characters.")) { try WebLinkPolicy.normalize(link) }
    }

    @Test func refusesEmbeddedCredentials() {
        #expect(throws: ToolArgumentError.refused("Links with a user name or password in them are not opened.")) {
            try WebLinkPolicy.normalize("https://example.com@evil.example/login")
        }
        #expect(throws: ToolArgumentError.self) { try WebLinkPolicy.normalize("https://user:pass@example.com") }
    }

    @Test func keepsHTTPAndHTTPSLinks() throws {
        #expect(try WebLinkPolicy.normalize("https://example.com/a?b=c#d").absoluteString == "https://example.com/a?b=c#d")
        #expect(try WebLinkPolicy.normalize("HTTP://Example.com").absoluteString == "HTTP://Example.com")
        #expect(try WebLinkPolicy.normalize("  https://example.com  ").absoluteString == "https://example.com")
    }

    @Test func bareDomainsOpenOverHTTPSAndLoopbackOverHTTP() throws {
        #expect(try WebLinkPolicy.normalize("example.com/page").absoluteString == "https://example.com/page")
        #expect(try WebLinkPolicy.normalize("docs.swift.org").absoluteString == "https://docs.swift.org")
        #expect(try WebLinkPolicy.normalize("example.com:8443/x").absoluteString == "https://example.com:8443/x")
        #expect(try WebLinkPolicy.normalize("localhost:3000").absoluteString == "http://localhost:3000")
        #expect(try WebLinkPolicy.normalize("127.0.0.1:8080/a").absoluteString == "http://127.0.0.1:8080/a")
    }

    @Test func notAWebAddressIsInvalidRatherThanRefused() {
        #expect(throws: ToolArgumentError("\"hello\" is not a web address. Give a full http or https link.")) {
            try WebLinkPolicy.normalize("hello")
        }
        #expect(throws: ToolArgumentError("Missing \"url\".")) { try WebLinkPolicy.normalize("   ") }
        #expect(throws: ToolArgumentError("The link has no website in it.")) { try WebLinkPolicy.normalize("https:///path") }
        #expect(throws: ToolArgumentError("The link is too long.")) {
            try WebLinkPolicy.normalize("https://example.com/" + String(repeating: "a", count: WebLinkPolicy.maxLength))
        }
    }

    @Test func schemeDetectionTellsPortsFromSchemes() {
        #expect(WebLinkPolicy.explicitScheme(of: "localhost:8080") == nil)
        #expect(WebLinkPolicy.explicitScheme(of: "example.com:443/x") == nil)
        #expect(WebLinkPolicy.explicitScheme(of: "https://x") == "https")
        #expect(WebLinkPolicy.explicitScheme(of: "javascript:alert(1)") == "javascript")
        #expect(WebLinkPolicy.explicitScheme(of: "javascript:80") == nil) // reads as a host and port; "javascript" has no dot, so it is still not opened
        #expect(WebLinkPolicy.explicitScheme(of: "no colon") == nil)
        #expect(throws: ToolArgumentError.self) { try WebLinkPolicy.normalize("javascript:80") }
    }
}

@Suite("Link, clipboard and Finder tools")
struct LinkToolsTests {
    @Test func openURLOpensInTheDefaultBrowserOnly() async {
        let rig = AppToolRig()
        let result = await rig.toolbox.call(name: "open_url", arguments: #"{"url":"example.com"}"#)
        #expect(result.status == .opened)
        #expect(result.details["url"] == "https://example.com")
        #expect(rig.workspace.events == [.openInBrowser(URL(string: "https://example.com")!)])
    }

    @Test func refusedLinksNeverReachTheWorkspace() async {
        let rig = AppToolRig()
        for link in ["javascript:alert(1)", "file:///etc/hosts", "data:,hi"] {
            let result = await rig.toolbox.call(name: "open_url", arguments: JSONValue.object(["url": .string(link)]).jsonString())
            #expect(result.status == .refused, "\(link)")
        }
        #expect(rig.workspace.events.isEmpty)
    }

    @Test func openURLReportsABrowserThatDidNotOpen() async {
        let rig = AppToolRig(workspace: RecordingWorkspace(succeeds: false))
        let result = await rig.toolbox.call(name: "open_url", arguments: #"{"url":"https://example.com"}"#)
        #expect(result.status == .failed)
    }

    @Test func openURLNeedsAStringURL() async {
        let toolbox = AppToolRig().toolbox
        #expect(await toolbox.call(name: "open_url", arguments: "{}").status == .invalidRequest)
        #expect(await toolbox.call(name: "open_url", arguments: #"{"url":42}"#).status == .invalidRequest)
    }

    @Test func copyKeepsTheTextExactly() async {
        let rig = AppToolRig()
        let text = "  def f():\n\treturn \"x\"\n"
        let result = await rig.toolbox.call(name: "copy_to_clipboard", arguments: JSONValue.object(["text": .string(text)]).jsonString())
        #expect(result.status == .copied)
        #expect(result.details["characters"] == .number(Double(text.count)))
        #expect(rig.pasteboard.copies == [text])
    }

    @Test func copyRefusesEmptyAndHugeText() async {
        let rig = AppToolRig()
        #expect(await rig.toolbox.call(name: "copy_to_clipboard", arguments: #"{"text":"   "}"#).status == .invalidRequest)
        #expect(await rig.toolbox.call(name: "copy_to_clipboard", arguments: "{}").status == .invalidRequest)
        let huge = String(repeating: "x", count: LinkTools.maxClipboardCharacters + 1)
        #expect(await rig.toolbox.call(name: "copy_to_clipboard", arguments: JSONValue.object(["text": .string(huge)]).jsonString())
            .status == .invalidRequest)
        #expect(rig.pasteboard.copies.isEmpty)
    }

    @Test func copyReportsAPasteboardThatRefused() async {
        let pasteboard = RecordingPasteboard(succeeds: false)
        let toolbox = AppToolbox([LinkTools.copyToClipboard(pasteboard: pasteboard)])
        #expect(await toolbox.call(name: "copy_to_clipboard", arguments: #"{"text":"a"}"#).status == .failed)
    }
}

@Suite("reveal_in_finder home-folder policy")
struct HomePathPolicyTests {
    /// A throwaway home folder with a file, a sub-folder, and a link that points outside it.
    final class FakeHome {
        let root: URL
        let home: URL
        let outside: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-home-\(UUID().uuidString)")
            home = root.appendingPathComponent("tester")
            outside = root.appendingPathComponent("elsewhere")
            let fm = FileManager.default
            try fm.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("hi".utf8).write(to: home.appendingPathComponent("Documents/notes.txt"))
            try Data("secret".utf8).write(to: outside.appendingPathComponent("other.txt"))
            try fm.createSymbolicLink(at: home.appendingPathComponent("escape"), withDestinationURL: outside)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func resolvesTildeAndAbsolutePathsInsideHome() throws {
        let fake = try FakeHome()
        let viaTilde = try HomePathPolicy.resolve("~/Documents/notes.txt", home: fake.home)
        let absolute = try HomePathPolicy.resolve(fake.home.path + "/Documents/notes.txt", home: fake.home)
        #expect(viaTilde == absolute)
        #expect(viaTilde.lastPathComponent == "notes.txt")
        #expect(try HomePathPolicy.resolve("~", home: fake.home) == HomePathPolicy.canonical(fake.home))
        #expect(try HomePathPolicy.resolve("file://" + fake.home.path + "/Documents", home: fake.home).lastPathComponent == "Documents")
    }

    @Test func refusesPathsOutsideHome() throws {
        let fake = try FakeHome()
        for path in ["/etc/hosts", "/", fake.outside.path + "/other.txt", "~/../elsewhere/other.txt", "~/Documents/../../elsewhere",
                     "~root/.ssh", fake.home.path + "x/file"] {
            #expect(throws: ToolArgumentError.self, "\(path)") { try HomePathPolicy.resolve(path, home: fake.home) }
            do {
                _ = try HomePathPolicy.resolve(path, home: fake.home)
            } catch let error as ToolArgumentError {
                #expect(error.status == .refused, "\(path)")
            }
        }
    }

    @Test func refusesSymbolicLinksThatLeaveHome() throws {
        let fake = try FakeHome()
        #expect(throws: ToolArgumentError.refused("Only files and folders inside your home folder can be shown in Finder.")) {
            try HomePathPolicy.resolve("~/escape/other.txt", home: fake.home)
        }
    }

    @Test func relativeAndEmptyPathsAreInvalid() throws {
        let fake = try FakeHome()
        #expect(throws: ToolArgumentError("Give a full path (starting with / or ~/), not a relative one.")) {
            try HomePathPolicy.resolve("Documents/notes.txt", home: fake.home)
        }
        #expect(throws: ToolArgumentError("Missing \"path\".")) { try HomePathPolicy.resolve(" ", home: fake.home) }
    }

    @Test func missingItemsInsideHomeAreNotFoundNotRefused() async throws {
        let fake = try FakeHome()
        let rig = AppToolRig(home: fake.home)
        let missing = await rig.toolbox.call(name: "reveal_in_finder", arguments: #"{"path":"~/Documents/nope.txt"}"#)
        #expect(missing.status == .notFound)
        #expect(rig.workspace.events.isEmpty)
    }

    @Test func revealShowsTheResolvedItem() async throws {
        let fake = try FakeHome()
        let rig = AppToolRig(home: fake.home)
        let result = await rig.toolbox.call(name: "reveal_in_finder", arguments: #"{"path":"~/Documents/notes.txt"}"#)
        #expect(result.status == .revealed)
        #expect(rig.workspace.events.count == 1)
        guard case .reveal(let url) = rig.workspace.events.first else { Issue.record("nothing revealed"); return }
        #expect(url.lastPathComponent == "notes.txt")

        let outside = await rig.toolbox.call(name: "reveal_in_finder", arguments: JSONValue.object(["path": .string(fake.outside.path)]).jsonString())
        #expect(outside.status == .refused)
        #expect(rig.workspace.events.count == 1)
    }
}
