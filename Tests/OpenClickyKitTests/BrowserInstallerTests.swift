import Foundation
import Testing
@testable import OpenClickyKit

private func temporarySupport() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocb-support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

@Test func extensionIDFollowsChromesDerivation() throws {
    // Chrome's rule, computed independently: sha256(DER public key), first 32 hex digits, 0-f mapped to a-p.
    #expect(ChromeExtensionIdentity.extensionID == "emfgfcpifjoglbdkhjnnmokbagmgmlem")
    #expect(ChromeExtensionIdentity.isValidID(ChromeExtensionIdentity.extensionID))
    // sha256("") begins e3b0c442…; e→o, 3→d, b→l, 0→a, …
    #expect(ChromeExtensionIdentity.id(forPublicKeyDER: Data()) == "odlameecjipmbmbejkplpemijjgpljce")
    #expect(!ChromeExtensionIdentity.isValidID("com.heyclicky.browser"))
    #expect(!ChromeExtensionIdentity.isValidID("qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"))
}

@Test func manifestKeyMatchesTheBuiltInIdentity() throws {
    let manifestURL = repositoryRoot.appendingPathComponent("Extension/chrome/manifest.json")
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: manifestURL))
    #expect(manifest["key"]?.stringValue == ChromeExtensionIdentity.publicKeyBase64)
    #expect(manifest["manifest_version"] == 3)
    let permissions = manifest["permissions"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(permissions.contains("nativeMessaging"))
    // The repository holds only the public key.
    let files = try FileManager.default.subpathsOfDirectory(atPath: repositoryRoot.appendingPathComponent("Extension").path)
    #expect(!files.contains { $0.hasSuffix(".pem") || $0.hasSuffix(".key") || $0.hasSuffix(".crx") })
}

@Test func installerWritesOnlyOpenClickysManifestForInstalledBrowsers() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    // Chrome and Arc are "installed"; Chrome already has HeyClicky's manifest, which must survive untouched.
    let chromeHosts = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts")
    try FileManager.default.createDirectory(at: chromeHosts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: support.appendingPathComponent("Arc/User Data"), withIntermediateDirectories: true)
    let heyClicky = chromeHosts.appendingPathComponent("com.heyclicky.browser.json")
    let heyClickyBytes = Data(#"{"name":"com.heyclicky.browser","path":"/somewhere/else"}"#.utf8)
    try heyClickyBytes.write(to: heyClicky)

    // A path that can't exist on this Mac, even when OpenClicky is installed in /Applications.
    let host = support.appendingPathComponent("Missing OpenClicky.app/Contents/Helpers/OpenClickyBrowserHost")
    let outcomes = NativeHostInstaller.install(hostPath: host, applicationSupport: support)
    let written = outcomes.filter { $0.action == .written }.map(\.browser.id)
    #expect(Set(written) == ["chrome", "arc"])
    #expect(outcomes.first { $0.browser.id == "brave" }?.action == .browserNotFound)
    #expect(try Data(contentsOf: heyClicky) == heyClickyBytes)

    let ours = chromeHosts.appendingPathComponent("com.openclicky.browser.json")
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ours))
    #expect(manifest["name"] == "com.openclicky.browser")
    #expect(manifest["type"] == "stdio")
    #expect(manifest["path"] == .string(host.path))
    #expect(manifest["allowed_origins"] == ["chrome-extension://emfgfcpifjoglbdkhjnnmokbagmgmlem/"])
    let arc = support.appendingPathComponent("Arc/User Data/NativeMessagingHosts/com.openclicky.browser.json")
    #expect(FileManager.default.fileExists(atPath: arc.path))

    // Running again changes nothing; --all also covers browsers that aren't installed.
    #expect(NativeHostInstaller.install(hostPath: host, applicationSupport: support).filter { $0.action == .written }.isEmpty)
    let everything = NativeHostInstaller.install(hostPath: host, applicationSupport: support, includeMissing: true)
    #expect(everything.allSatisfy { $0.action == .written || $0.action == .unchanged }, "\(everything.map { "\($0.browser.id): \($0.action)" })")
    #expect(Set(NativeHostInstaller.browsers.prefix(6).map(\.id)) == ["chrome", "chromium", "brave", "edge", "arc", "vivaldi"])

    let inspection = NativeHostInstaller.inspect(applicationSupport: support)
    let chrome = try #require(inspection.first { $0.browser.id == "chrome" })
    #expect(chrome.manifestPresent && chrome.allowsOpenClickyExtension)
    #expect(!chrome.hostExecutable)  // the example path doesn't exist

    let removed = NativeHostInstaller.uninstall(applicationSupport: support)
    #expect(removed.filter { $0.action == .removed }.count == NativeHostInstaller.browsers.count)
    #expect(!FileManager.default.fileExists(atPath: ours.path))
    #expect(try Data(contentsOf: heyClicky) == heyClickyBytes)
}

@Test func manifestIsReadableJSONWithUnescapedPaths() throws {
    let text = String(decoding: NativeHostInstaller.manifestData(hostPath: "/Applications/OpenClicky.app/Contents/Helpers/OpenClickyBrowserHost",
                                                                 extensionIDs: ["emfgfcpifjoglbdkhjnnmokbagmgmlem"]), as: UTF8.self)
    #expect(text.contains(#""path" : "/Applications/OpenClicky.app/Contents/Helpers/OpenClickyBrowserHost""#))
    #expect(text.hasSuffix("}\n"))
}

@Test func hostIsFoundNextToTheToolOrInTheAppsHelpersFolder() throws {
    let root = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: root) }
    // Laid out like OpenClicky.app/Contents.
    let macOS = root.appendingPathComponent("Bundle/Contents/MacOS")
    let helpers = root.appendingPathComponent("Bundle/Contents/Helpers")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let host = helpers.appendingPathComponent("OpenClickyBrowserHost")
    FileManager.default.createFile(atPath: host.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    #expect(NativeHostInstaller.locateHost(nextTo: macOS.appendingPathComponent("occtl"))?.path == host.resolvingSymlinksInPath().path)
    #expect(NativeHostInstaller.locateHost(nextTo: root.appendingPathComponent("elsewhere/occtl")) == nil)
}

@Test func extraExtensionIDsComeFromTheBridgeFolder() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    #expect(ChromeExtensionIdentity.allowedIDs(paths: paths) == [ChromeExtensionIdentity.extensionID])
    try "abcdefghijklmnopabcdefghijklmnop\nnot-an-id\n\n".write(to: paths.extraExtensionIDs, atomically: true, encoding: .utf8)
    #expect(ChromeExtensionIdentity.allowedIDs(paths: paths) == [ChromeExtensionIdentity.extensionID, "abcdefghijklmnopabcdefghijklmnop"])
}

@Test func browserToolValidatesBeforeSending() {
    #expect(BrowserTool.validate(.navigate, ["url": "https://example.com"]) == nil)
    #expect(BrowserTool.validate(.navigate, ["url": "chrome://settings"]) != nil)
    #expect(BrowserTool.validate(.navigate, ["url": "https://user:pw@example.com"]) != nil)
    #expect(BrowserTool.validate(.click, [:]) != nil)
    #expect(BrowserTool.validate(.type, ["ref": "e1"]) != nil)
    #expect(BrowserTool.validate(.type, ["ref": "e1", "text": "hi"]) == nil)
    #expect(BrowserTool.validate(.press, ["key": "F13"]) != nil)
    #expect(BrowserTool.validate(.scroll, ["direction": "down"]) == nil)
    #expect(BrowserTool.timeout(for: .waitFor, ["timeout": 500]) == 130)
    #expect(BrowserTool.Operation.screenshot.isReadOnly && !BrowserTool.Operation.click.isReadOnly)
}

@Test func pageFormattingIsCompactAndListsRefs() {
    let text = BrowserTool.formatPage([
        "tabId": 3, "title": "Shop", "url": "https://shop.example/cart", "text": "Your cart", "textTruncated": true,
        "elementsOmitted": 4,
        "elements": [
            ["ref": "e1", "role": "link", "name": "Home", "href": "https://shop.example/"],
            ["ref": "e2", "role": "combobox", "name": "Qty", "value": "1", "options": ["1", "2"]],
            ["ref": "e3", "role": "checkbox", "name": "Gift", "checked": true, "offscreen": true],
        ],
    ])
    #expect(text.contains("Tab 3: Shop"))
    #expect(text.contains("Page text (truncated):"))
    #expect(text.contains(#"[e1] link "Home" -> https://shop.example/"#))
    #expect(text.contains(#"[e2] combobox "Qty" value="1" options: 1 | 2"#))
    #expect(text.contains(#"[e3] checkbox "Gift" (checked) (off-screen)"#))
    #expect(text.contains("4 more not listed"))
}
