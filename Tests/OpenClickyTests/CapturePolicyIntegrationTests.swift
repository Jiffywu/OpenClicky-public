import AppKit
import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct CapturePolicyIntegrationTests {
    @Test func theNotchAndSettingsUseTheSameCapturePolicy() throws {
        let fixture = try EvidenceSnapshots.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let loop = VoiceLoopController(model: fixture.model, home: fixture.services, settingsURL: nil)
        #expect(loop.capturePolicy === fixture.model.capturePolicy)
        let window = FixtureCaptureWindow()
        loop.capturePolicy.register(window, role: .ambientChrome)
        fixture.model.capturePolicy.showInScreenRecordings = false
        #expect(window.sharingType == .none)
        #expect(loop.capturePolicy.excludedWindowNumbers.contains(window.windowNumber))
    }
}

@MainActor private final class FixtureCaptureWindow: CapturePolicyWindow {
    let windowNumber = 777
    var sharingType: NSWindow.SharingType = .readOnly
}
