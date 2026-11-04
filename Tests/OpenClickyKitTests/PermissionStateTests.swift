import Foundation
import Testing
@testable import OpenClickyKit

// Permission states: denied after a request, restart-required after a grant the process can't see, the request log in
// app-preferences.json, the relaunch command, and the agent-reach summary.

@Suite struct PermissionStateTests {
    @Test func notGrantedReadsAsNotDeterminedUntilAskedThenDenied() {
        #expect(PermissionStateMapping.state(.notGranted, askedBefore: false) == .notDetermined)
        #expect(PermissionStateMapping.state(.notGranted, askedBefore: true) == .denied)
        #expect(PermissionStateMapping.state(.notGranted, askedBefore: true, grantedLive: false) == .denied)
        #expect(PermissionStateMapping.state(.granted, askedBefore: false) == .granted)
        #expect(PermissionStateMapping.state(.denied, askedBefore: false) == .denied, "macOS's own denied stands")
        #expect(PermissionStateMapping.state(.notDetermined, askedBefore: true) == .notDetermined, "macOS's own not-asked stands")
    }

    @Test func aGrantSeenOnlyLiveNeedsARestart() {
        #expect(PermissionStateMapping.state(.notGranted, askedBefore: true, grantedLive: true) == .restartRequired)
        #expect(PermissionStateMapping.state(.granted, askedBefore: true, grantedLive: true) == .granted)
    }

    @Test func theRequestLogLivesInAppPreferencesAndKeepsOtherKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("perm-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("app-preferences.json")
        try AppPreferences(showInDock: true, dismissedInstallWarningPath: "/x.app").save(to: url)
        #expect(!PermissionRequestLog.load(from: url).askedBefore(.screenRecording))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let log = PermissionRequestLog.record(.screenRecording, at: at, in: url)
        #expect(log.askedBefore(.screenRecording) && !log.askedBefore(.accessibility))
        let saved = AppPreferences.load(from: url)
        #expect(saved.showInDock && saved.dismissedInstallWarningPath == "/x.app")
        #expect(saved.permissionRequests["screenRecording"] == at)
        // Older files without the key still load.
        try Data(#"{"showInDock":true}"#.utf8).write(to: url)
        #expect(AppPreferences.load(from: url).permissionRequests.isEmpty)
    }

    @Test func relaunchWaitsForThisProcessAndPassesPathsAsArguments() throws {
        let command = try #require(RelaunchCommand.make(pid: 4242, bundlePath: "/Applications/Open \"Clicky\".app"))
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments.count == 5)
        #expect(command.arguments[3] == "4242" && command.arguments[4] == "/Applications/Open \"Clicky\".app")
        #expect(!command.arguments[1].contains("Applications"), "the path never goes into the script text")
        #expect(RelaunchCommand.make(pid: 1, bundlePath: "relative.app") == nil)
        #expect(RelaunchCommand.make(pid: 1, bundlePath: "/usr/bin/swift") == nil)
    }

    @Test func agentReachChecksInstalledBrowsersWithoutAskingAndListsFolders() {
        let asked = LockedFlags()
        let probe = AutomationProbe { id, askIfNeeded in
            if askIfNeeded { asked.set() }
            return id == ScriptableBrowser.safari.bundleIdentifier ? .granted : .notDetermined
        }
        let ledger = GuardedFolderLedger(storage: InMemoryGuardedFolderStorage(["desktop"]))
        let reach = AgentReach.check(probe: probe, ledger: ledger) { $0 == .safari || $0 == .chrome }
        #expect(reach.browsers.map(\.browser) == [.safari, .chrome])
        #expect(reach.browsers.map(\.permission) == [.granted, .notDetermined])
        #expect(!asked.value, "the inspector never shows the Automation prompt")
        #expect(reach.folders.count == GuardedFolder.allCases.count)
        #expect(reach.folders.first { $0.folder == .desktop }?.readBefore == true)
        #expect(reach.folders.first { $0.folder == .downloads }?.readBefore == false)
        #expect(AutomationPermission.denied.label == "Not allowed")
    }
}

private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
