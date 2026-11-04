import AppKit
import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

// PermissionsCenter over fake probes: never asked, asked and still off, granted after launch, Input Monitoring.
@Suite @MainActor struct PermissionsCenterTests {
    @MainActor final class FakeSystem {
        var readings: [PermissionKind: PermissionReading] = [:]
        var live = false
        var liveChecks = 0
        var requests: [PermissionKind] = []
        var relaunches = 0

        var probes: PermissionProbes {
            PermissionProbes(read: { [unowned self] in self.readings[$0] ?? .notGranted },
                             screenRecordingLive: { [unowned self] in self.liveChecks += 1; return self.live },
                             request: { [unowned self] in self.requests.append($0) },
                             relaunch: { [unowned self] in self.relaunches += 1 },
                             agentReach: { AgentReach(browsers: [], folders: []) })
        }
    }

    private func preferencesURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString)/app-preferences.json")
    }

    @Test func neverAskedIsNotDeterminedAndAskedIsDenied() async {
        let fake = FakeSystem()
        fake.readings = [.microphone: .granted, .screenRecording: .notGranted, .accessibility: .notGranted,
                         .speechRecognition: .notDetermined, .inputMonitoring: .notDetermined]
        let url = preferencesURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let center = PermissionsCenter(probes: fake.probes, requestLogURL: url)
        #expect(center.states[.accessibility] == .notDetermined)
        #expect(center.states[.screenRecording] == .notDetermined)
        #expect(center.states[.inputMonitoring] == .notDetermined)
        #expect(fake.liveChecks == 0, "no live Screen Recording check before OpenClicky asked")

        await center.request(.accessibility)
        #expect(fake.requests == [.accessibility])
        #expect(center.states[.accessibility] == .denied)
        // The log survives a relaunch.
        let again = PermissionsCenter(probes: fake.probes, requestLogURL: url)
        #expect(again.states[.accessibility] == .denied)
        #expect(again.states[.screenRecording] == .notDetermined)
    }

    @Test func screenRecordingGrantedAfterLaunchNeedsARestart() async {
        let fake = FakeSystem()
        fake.readings = [.screenRecording: .notGranted]
        let url = preferencesURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let center = PermissionsCenter(probes: fake.probes, requestLogURL: url)
        await center.request(.screenRecording)
        await center.checkScreenRecordingLive()
        #expect(center.states[.screenRecording] == .denied)
        // The user flips the switch in System Settings; this process's preflight still says no.
        fake.live = true
        await center.checkScreenRecordingLive()
        #expect(center.states[.screenRecording] == .restartRequired)
        #expect(center.needsRestart)
        center.quitAndReopen()
        #expect(fake.relaunches == 1)
        // After the relaunch the preflight reads granted.
        fake.readings[.screenRecording] = .granted
        center.refresh()
        #expect(center.states[.screenRecording] == .granted)
    }

    @Test func thePermissionsPageChecksWhenItOpensAndWhenOpenClickyComesBack() async {
        let fake = FakeSystem()
        fake.readings = [.accessibility: .notGranted]
        let url = preferencesURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let center = PermissionsCenter(probes: fake.probes, requestLogURL: url)
        await center.request(.accessibility)
        #expect(center.states[.accessibility] == .denied, "checked while macOS's prompt was still up")
        // The user turns it on in System Settings, then opens the page.
        fake.readings[.accessibility] = .granted
        let notifications = NotificationCenter()
        center.pageAppeared(notifications: notifications)
        #expect(center.states[.accessibility] == .granted)
        // Turned off and on again in System Settings while the page stays open: coming back to OpenClicky checks.
        fake.readings[.accessibility] = .notGranted
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(center.states[.accessibility] == .denied)
        fake.readings[.accessibility] = .granted
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(center.states[.accessibility] == .granted)
        // Closed: activations no longer check.
        center.pageDisappeared()
        fake.readings[.accessibility] = .notGranted
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(center.states[.accessibility] == .granted)
    }

    @Test func inputMonitoringUsesTheSystemsOwnAnswer() {
        let fake = FakeSystem()
        fake.readings = [.inputMonitoring: .denied]
        let center = PermissionsCenter(probes: fake.probes, requestLogURL: nil)
        #expect(center.states[.inputMonitoring] == .denied)
        #expect(PermissionKind.inputMonitoring.settingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
        fake.readings[.inputMonitoring] = .granted
        center.refresh()
        #expect(center.states[.inputMonitoring] == .granted)
        #expect(!center.allRequiredGranted, "Input Monitoring is optional; the required three aren't all on here")
    }

    @Test func fixedCentersNeverProbe() {
        let center = PermissionsCenter(fixed: [.screenRecording: .restartRequired], reach: AgentReach(browsers: [], folders: []))
        center.refresh()
        center.refreshAgentReach()
        #expect(center.states[.screenRecording] == .restartRequired)
        #expect(center.agentReach == AgentReach(browsers: [], folders: []))
    }
}
