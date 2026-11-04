import AppKit
import Foundation
import Testing
@testable import OpenClickyKit

// Settings → General: preferences, the first-launch login item, the install location, window capture roles, saved
// keys and Reset local data. Nothing here touches the real login items, Keychain or support folder.

private func scratch(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func appPreferencesKeepDefaultsForMissingKeysAndRoundTrip() throws {
    let folder = try scratch("prefs")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("app-preferences.json")
    #expect(AppPreferences.load(from: url) == AppPreferences())
    #expect(AppPreferences().showInScreenRecordings && !AppPreferences().showInDock)
    try #"{"showInDock": true}"#.write(to: url, atomically: true, encoding: .utf8)
    let loaded = AppPreferences.load(from: url)
    #expect(loaded.showInDock && loaded.showInScreenRecordings && !loaded.loginItemFirstLaunchHandled)
    var changed = loaded
    changed.showInScreenRecordings = false
    changed.dismissedInstallWarningPath = "/Users/me/Downloads/OpenClicky.app"
    try changed.save(to: url)
    #expect(AppPreferences.load(from: url) == changed)
    try "not json".write(to: url, atomically: true, encoding: .utf8)
    #expect(AppPreferences.load(from: url) == AppPreferences())
}

@Test func installLocationsAreClassified() {
    let home = URL(fileURLWithPath: "/Users/me")
    func kind(_ path: String) -> InstallLocation.Kind { InstallLocation.classify(bundleURL: URL(fileURLWithPath: path), home: home).kind }
    #expect(kind("/Applications/OpenClicky.app") == .applications)
    #expect(kind("/Users/me/Applications/OpenClicky.app") == .userApplications)
    #expect(kind("/private/var/folders/xy/T/AppTranslocation/0E3C-11/d/OpenClicky.app") == .translocated)
    #expect(kind("/Volumes/OpenClicky 0.1/OpenClicky.app") == .diskImage)
    #expect(kind("/Users/me/Downloads/OpenClicky.app") == .downloads)
    #expect(kind("/Users/me/Desktop/OpenClicky.app") == .downloads)
    #expect(kind("/Users/me/Developer/OpenClicky/dist/OpenClicky.app") == .elsewhere)
    #expect(kind("/Users/me/Developer/OpenClicky/.build/debug") == .development)

    let translocated = InstallLocation.classify(bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/OpenClicky.app"), home: home)
    #expect(translocated.advice?.contains("Applications") == true)
    #expect(!translocated.allowsLoginItem && !translocated.isInstalled)
    #expect(InstallLocation(kind: .applications, bundlePath: "/Applications/OpenClicky.app").advice == nil)
    #expect(InstallLocation(kind: .elsewhere, bundlePath: "/x/OpenClicky.app").allowsLoginItem)
}

private final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemStatus = .notRegistered
    private(set) var registrations = 0
    var failing = false

    var status: LoginItemStatus { lock.withLock { _status } }
    func register() throws {
        try lock.withLock {
            if failing { throw CocoaError(.featureUnsupported) }
            registrations += 1
            _status = .requiresApproval
        }
    }
    func unregister() throws { lock.withLock { _status = .notRegistered } }
}

@Test func theLoginItemIsRegisteredOnTheFirstLaunchFromApplicationsOnly() {
    let installed = InstallLocation(kind: .applications, bundlePath: "/Applications/OpenClicky.app")
    let item = FakeLoginItem()
    var prefs = AppPreferences()

    // A copy in Downloads (or a build folder): not registered, and the first launch from Applications still will be.
    let (afterDownloads, line1) = LoginItemPolicy.applyOnLaunch(preferences: prefs, location: InstallLocation(kind: .downloads, bundlePath: "/Users/me/Downloads/OpenClicky.app"),
                                                                service: item, environment: [:])
    #expect(item.registrations == 0 && !afterDownloads.loginItemFirstLaunchHandled)
    #expect(line1.contains("not registered"))

    // The opt-out used by development and evidence runs.
    #expect(LoginItemPolicy.firstLaunchDecision(preferences: prefs, location: installed, environment: ["OPENCLICKY_NO_LOGIN_ITEM": "1"])
            == .skip("OPENCLICKY_NO_LOGIN_ITEM is set"))

    let (afterFirst, line2) = LoginItemPolicy.applyOnLaunch(preferences: prefs, location: installed, service: item, environment: [:])
    #expect(item.registrations == 1 && afterFirst.loginItemFirstLaunchHandled)
    #expect(line2.contains("registered on first launch") && line2.contains("requiresApproval"))
    prefs = afterFirst

    // The user switched it off: later launches leave it alone.
    try? item.unregister()
    let (afterSecond, _) = LoginItemPolicy.applyOnLaunch(preferences: prefs, location: installed, service: item, environment: [:])
    #expect(item.registrations == 1 && afterSecond == prefs && item.status == .notRegistered)

    // A failed registration is recorded as handled too (no retry loop at every launch).
    let failing = FakeLoginItem()
    failing.failing = true
    let (afterFailure, line3) = LoginItemPolicy.applyOnLaunch(preferences: AppPreferences(), location: installed, service: failing, environment: [:])
    #expect(afterFailure.loginItemFirstLaunchHandled && line3.contains("failed"))
}

@MainActor
private final class StandInWindow: CapturePolicyWindow {
    let windowNumber: Int
    var sharingType: NSWindow.SharingType = .readOnly
    init(_ number: Int) { windowNumber = number }
}

@MainActor
@Test func windowsGetRolesAndTheRecordingsSwitchReachesThem() {
    #expect(WindowCaptureRoles.role(for: WindowTraits(className: "OverlayPanel", isTitled: false, ignoresMouseEvents: true)) == .hiddenFromOwnCaptures)
    #expect(WindowCaptureRoles.role(for: WindowTraits(className: "NSPanel", isTitled: false, ignoresMouseEvents: false)) == .ambientChrome)
    #expect(WindowCaptureRoles.role(for: WindowTraits(className: "AppKitWindow", isTitled: true, ignoresMouseEvents: false)) == .standalone)
    #expect(WindowCaptureRoles.role(for: WindowTraits(className: "NSStatusBarWindow", isTitled: false, ignoresMouseEvents: false)) == nil)
    #expect(WindowCaptureRoles.role(for: WindowTraits(className: "NSMenuWindowManagerWindow", isTitled: false, ignoresMouseEvents: false)) == nil)

    let policy = OwnWindowCapturePolicy(showInScreenRecordings: true)
    let overlay = StandInWindow(11), hud = StandInWindow(12), settings = StandInWindow(13)
    policy.register(overlay, role: .hiddenFromOwnCaptures)
    policy.register(hud, role: .ambientChrome)
    policy.register(settings, role: .standalone)
    #expect(policy.excludedWindowNumbers == [11, 12])
    #expect([overlay, hud, settings].allSatisfy { $0.sharingType == .readOnly })
    policy.showInScreenRecordings = false
    #expect(overlay.sharingType == NSWindow.SharingType.none && hud.sharingType == NSWindow.SharingType.none)
    #expect(settings.sharingType == .readOnly)
    policy.showInScreenRecordings = true
    #expect(overlay.sharingType == .readOnly)
}

@Test func savedKeysListWhatUsesThem() {
    let config = OpenClickyConfig(providers: [
        ProviderConfig(id: "anthropic", dialect: .anthropicMessages, credential: "anthropic"),
        ProviderConfig(id: "openai", dialect: .openAIResponses, credential: "openai"),
        ProviderConfig(id: "openai-realtime", dialect: .openAIRealtime, credential: "openai"),
    ], slots: [:])
    let keys = SavedKey.inventory(stored: ["anthropic", "brave", "openai"], config: config, extraUses: ["brave": ["web search"]],
                                  environmentNames: ["elevenlabs"])
    #expect(keys.map(\.name) == ["anthropic", "brave", "elevenlabs", "openai"])
    #expect(keys.first { $0.name == "openai" }?.usedBy == ["openai", "openai-realtime"])
    #expect(keys.first { $0.name == "brave" }?.usedBy == ["web search"])
    #expect(keys.first { $0.name == "elevenlabs" }?.fromEnvironment == true)
    #expect(KeychainCredentialStore.environmentNames(["OPENCLICKY_KEY_ELEVENLABS": "x", "OPENCLICKY_KEY_TWELVE_DATA": "y",
                                                      "OPENCLICKY_KEY_EMPTY": "", "PATH": "/bin"]) == ["elevenlabs", "twelve-data"])
}

@Test func resetLocalDataDeletesTheSupportFolderAndKeysButKeepsACustomAgentFolder() throws {
    let support = try scratch("reset")
    defer { try? FileManager.default.removeItem(at: support) }
    for file in ["config.json", "talk-keys.json", "routines.json"] {
        try "{}".write(to: support.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }
    for folder in ["History/sessions", "Memory", "projects/jobs/a", "BrowserBridge"] {
        try FileManager.default.createDirectory(at: support.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let outside = try scratch("custom-agents")
    defer { try? FileManager.default.removeItem(at: outside) }
    try "keep".write(to: outside.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    let credentials = InMemoryCredentialStore(["anthropic": "k1", "brave": "k2"])

    let plan = LocalDataReset.plan(supportFolder: support, credentials: credentials, keep: [outside])
    #expect(plan.items.map(\.lastPathComponent) == ["BrowserBridge", "History", "Memory", "config.json", "projects", "routines.json", "talk-keys.json"])
    #expect(plan.credentialNames == ["anthropic", "brave"])
    #expect(plan.summary.contains("7 files and folders") && plan.summary.contains("2 saved keys"))
    // Planning touched nothing.
    #expect(try credentials.secret(named: "anthropic") == "k1")

    let report = LocalDataReset.perform(plan, credentials: credentials)
    #expect(report.succeeded)
    #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
    #expect(try credentials.storedNames().isEmpty)
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("notes.md").path))

    // A kept folder inside the support folder survives with its parent.
    try FileManager.default.createDirectory(at: support.appendingPathComponent("projects/mine"), withIntermediateDirectories: true)
    try "{}".write(to: support.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let second = LocalDataReset.plan(supportFolder: support, credentials: credentials, keep: [support.appendingPathComponent("projects/mine")])
    #expect(second.items.map(\.lastPathComponent) == ["config.json"])

    // Entries not directly in the support folder are never deleted, whatever the plan says.
    var forged = second
    forged.items = [outside.appendingPathComponent("notes.md")]
    let refused = LocalDataReset.perform(forged, credentials: credentials)
    #expect(!refused.succeeded && FileManager.default.fileExists(atPath: outside.appendingPathComponent("notes.md").path))
}
