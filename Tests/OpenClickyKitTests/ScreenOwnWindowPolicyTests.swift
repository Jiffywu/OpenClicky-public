import AppKit
import Testing
@testable import OpenClickyKit

@MainActor
private final class FakeWindow: CapturePolicyWindow {
    let windowNumber: Int
    var sharingType: NSWindow.SharingType = .readOnly
    var sharingChanges = 0

    init(_ number: Int) { windowNumber = number }
}

@MainActor
@Suite("Own window capture policy")
struct OwnWindowCapturePolicyTests {
    @Test func overlaysAreLeftOutOfOwnCapturesButWindowsAreNot() {
        let policy = OwnWindowCapturePolicy()
        let pointer = FakeWindow(11), notch = FakeWindow(12), settings = FakeWindow(13)
        policy.register(pointer, role: .hiddenFromOwnCaptures)
        policy.register(notch, role: .ambientChrome)
        policy.register(settings, role: .standalone)
        #expect(policy.excludedWindowNumbers == [11, 12])
        #expect(policy.exclusion(adding: [40, 0, -1]).windowNumbers == [11, 12, 40])
        policy.unregister(notch)
        #expect(policy.excludedWindowNumbers == [11])
    }

    @Test func theRecordingsSettingDrivesSharingType() {
        let policy = OwnWindowCapturePolicy(showInScreenRecordings: false)
        let pointer = FakeWindow(21), settings = FakeWindow(22)
        policy.register(pointer, role: .hiddenFromOwnCaptures)
        policy.register(settings, role: .standalone)
        #expect(pointer.sharingType == .none)
        #expect(settings.sharingType == .readOnly)
        policy.showInScreenRecordings = true
        #expect(pointer.sharingType == .readOnly)
        #expect(settings.sharingType == .readOnly)
        policy.showInScreenRecordings = false
        #expect(pointer.sharingType == .none)
    }

    @Test func closedWindowsAreForgotten() {
        let policy = OwnWindowCapturePolicy()
        var window: FakeWindow? = FakeWindow(31)
        policy.register(window!, role: .hiddenFromOwnCaptures)
        #expect(policy.registeredCount == 1)
        window = nil
        #expect(policy.registeredCount == 0)
        #expect(policy.excludedWindowNumbers.isEmpty)
    }

    @Test func windowsWithoutANumberYetAreSkipped() {
        let policy = OwnWindowCapturePolicy()
        let unshown = FakeWindow(0)
        policy.register(unshown, role: .hiddenFromOwnCaptures)
        #expect(policy.excludedWindowNumbers.isEmpty)
    }
}
