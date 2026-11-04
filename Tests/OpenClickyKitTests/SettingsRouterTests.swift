import Foundation
import Testing
@testable import OpenClickyKit

// openclicky:// links: the browser host's settings link, Settings pages, Home, jobs, routines and in-app links, and
// everything that must be refused.

@Test func browserHostLinkOpensTheBrowserPage() {
    // The exact link OpenClickyBrowserHost opens when the extension's "Open OpenClicky" is pressed.
    let parse = OpenClickyURLRouter.parse("openclicky://settings/browser")
    #expect(parse.route == .settings(.browser))
    #expect(parse.logLine == "openclicky link openclicky://settings/browser → Settings › browser")
}

@Test func everySettingsPageHasALinkAndAliasesWork() {
    for page in SettingsPageID.allCases {
        #expect(OpenClickyURLRouter.parse("openclicky://settings/\(page.rawValue)").route == .settings(page))
        let link = OpenClickyURLRouter.link(for: .settings(page))
        #expect(link.map { OpenClickyURLRouter.parse($0).route } == .settings(page))
    }
    #expect(OpenClickyURLRouter.parse("openclicky://settings/talk-keys").route == .settings(.talkKeys))
    #expect(OpenClickyURLRouter.parse("openclicky://settings/connected-apps").route == .settings(.connectedApps))
    #expect(OpenClickyURLRouter.parse("openclicky://settings/chrome").route == .settings(.browser))
    #expect(OpenClickyURLRouter.parse("openclicky://Settings/Microphone").route == .settings(.microphone))
    #expect(OpenClickyURLRouter.parse("openclicky://settings").route == .settings(nil))
    #expect(OpenClickyURLRouter.parse("openclicky://preferences/agents/").route == .settings(.agents))
    // Usage and Developer, which links used to refuse, and their aliases.
    #expect(OpenClickyURLRouter.parse("openclicky://settings/usage").route == .settings(.usage))
    #expect(OpenClickyURLRouter.parse("openclicky://settings/developer").route == .settings(.developer))
    #expect(OpenClickyURLRouter.parse("openclicky://settings/limits").route == .settings(.usage))
    #expect(OpenClickyURLRouter.parse("openclicky:settings/dev").route == .settings(.developer))
    #expect(OpenClickyURLRouter.parse("openclicky://settings/flags").route == .settings(.developer))
    #expect(SettingsPageID.allCases.count == 17)
}

@Test func agentInstructionsNameTheInAppLinks() {
    let record = AgentJobRecord(id: "j1", kind: .job, title: "T", task: "T", harness: .codex, model: nil, provider: "x", status: .queued,
                                createdAt: Date(), updatedAt: Date(), folderPath: "/tmp/oc/agents/projects/j1")
    let text = AgentInstructions.developer(for: record)
    #expect(text.contains("openclicky:job/<id>"))
    #expect(text.contains("openclicky://settings/<page>"))
    #expect(text.contains("openclicky://file?path="))
}

@Test func inAppLinksParseLikeExternalOnes() {
    #expect(OpenClickyURLRouter.parse("openclicky:settings/routines").route == .settings(.routines))
    #expect(OpenClickyURLRouter.parse("openclicky:job/pricing-articles-3f2a91c0de").route == .job("pricing-articles-3f2a91c0de"))
    #expect(OpenClickyURLRouter.parse("openclicky://job/pricing-articles-3f2a91c0de").route == .job("pricing-articles-3f2a91c0de"))
    #expect(OpenClickyURLRouter.parse("openclicky:home/agents").route == .home("agents"))
    #expect(OpenClickyURLRouter.parse("openclicky://home").route == .home(nil))
    #expect(OpenClickyURLRouter.parse("openclicky://routine/1a2b3c4d").route == .routine("1a2b3c4d"))
    #expect(OpenClickyURLRouter.parse("openclicky://routines").route == .settings(.routines))
    #expect(OpenClickyURLRouter.parse("openclicky://onboarding").route == .onboarding)
    #expect(OpenClickyURLRouter.link(for: .job("abc"), inApp: true)?.absoluteString == "openclicky:job/abc")
}

@Test func fileLinksNeedAPlainAbsolutePathAndAreRedactedInLogs() {
    let good = OpenClickyURLRouter.parse("openclicky://file?path=/Users/me/Library/Application%20Support/OpenClicky/projects/jobs/a/output/report.md")
    #expect(good.route == .revealFile("/Users/me/Library/Application Support/OpenClicky/projects/jobs/a/output/report.md"))
    #expect(!good.logLine.contains("/Users/me"))
    #expect(good.logLine.contains("path=(hidden)"))

    for bad in ["openclicky://file?path=relative/report.md", "openclicky://file?path=/Users/me/../../etc/passwd",
                "openclicky://file?path=/a&path=/b", "openclicky://file", "openclicky://file/extra?path=/a"] {
        #expect(OpenClickyURLRouter.parse(bad).route == nil, "\(bad)")
    }
    // A built link round-trips, spaces and all.
    let link = OpenClickyURLRouter.link(for: .revealFile("/tmp/a b/c.md"))
    #expect(link.map { OpenClickyURLRouter.parse($0).route } == .revealFile("/tmp/a b/c.md"))
}

@Test func fileLinksOnlyRevealInsideTheAgentFolders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-router-\(UUID().uuidString)")
    let projects = root.appendingPathComponent("projects")
    let output = projects.appendingPathComponent("jobs/a/output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inside = output.appendingPathComponent("report.md")
    try "hi".write(to: inside, atomically: true, encoding: .utf8)
    #expect(OpenClickyURLRouter.isInside(inside.path, roots: [projects]))
    #expect(!OpenClickyURLRouter.isInside(root.appendingPathComponent("projects-other/x").path, roots: [projects]))
    // A symlink inside the folder that points out of it doesn't count as inside.
    let escape = output.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: URL(fileURLWithPath: "/etc"))
    #expect(!OpenClickyURLRouter.isInside(escape.appendingPathComponent("hosts").path, roots: [projects]))
}

@Test func everythingElseIsRefusedWithAReason() {
    let cases: [(String, OpenClickyURLError)] = [
        ("https://example.com/settings/browser", .wrongScheme("https")),
        ("heyclicky://settings/browser", .wrongScheme("heyclicky")),
        ("openclicky://settings/nope", .unknownSettingsPage("nope")),
        ("openclicky://settings/browser/extra", .unknownRoute("settings/browser/extra")),
        ("openclicky://home/billing", .unknownHomeSection("billing")),
        ("openclicky://checkout-complete", .unknownRoute("checkout-complete")),
        ("openclicky://user:secret@settings/general", .hasCredentialsOrPort),
        ("openclicky://settings:8080/general", .hasCredentialsOrPort),
        ("openclicky://settings/browser?next=https://evil.example", .unexpectedQuery("settings")),
        ("openclicky://job/..", .badIdentifier("..")),
        ("openclicky://job/a%20b", .badIdentifier("a b")),
        ("openclicky://job", .unknownRoute("job")),
        ("openclicky://", .unknownRoute("")),
    ]
    for (text, expected) in cases {
        let parse = OpenClickyURLRouter.parse(text)
        #expect(parse.route == nil, "\(text)")
        if case .failure(let error) = parse.result { #expect(error == expected, "\(text)") }
        #expect(parse.logLine.contains("refused"), "\(text)")
        #expect(!parse.logLine.contains("secret"))
    }
    let long = "openclicky://job/" + String(repeating: "a", count: 3000)
    #expect(OpenClickyURLRouter.parse(long).result == .failure(.tooLong(long.count)))
    #expect(OpenClickyURLRouter.parse("openclicky://job/" + String(repeating: "b", count: 129)).route == nil)
}
