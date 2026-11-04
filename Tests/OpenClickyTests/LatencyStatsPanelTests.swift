import AppKit
import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

/// The floating latency stats panel (#32) is left out of OpenClicky's own screenshots.
@Suite @MainActor struct LatencyStatsPanelTests {
    @Test func thePanelRegistersAsHiddenFromOwnCaptures() throws {
        _ = NSApplication.shared
        let controller = LatencyStatsPanelController()
        let panel = controller.makePanel()
        defer { panel.close() }
        let traits = WindowTraits(className: String(describing: type(of: panel)), isTitled: panel.styleMask.contains(.titled),
                                  ignoresMouseEvents: panel.ignoresMouseEvents)
        #expect(WindowCaptureRoles.role(for: traits) == .hiddenFromOwnCaptures)

        // Through the app's registrar, as every OpenClicky window is.
        let policy = OwnWindowCapturePolicy(showInScreenRecordings: false)
        let registrar = WindowCaptureRegistrar(policy: policy)
        registrar.sweep()
        #expect(panel.windowNumber > 0)
        #expect(policy.excludedWindowNumbers.contains(panel.windowNumber))
        #expect(panel.sharingType == .none)  // the hidden role, with recordings switched off
        #expect(!panel.canBecomeKey)

        // The controller's own hook registers it the moment it is made.
        let direct = OwnWindowCapturePolicy()
        let second = LatencyStatsPanelController()
        second.register = { window in
            let traits = WindowTraits(className: String(describing: type(of: window)), isTitled: window.styleMask.contains(.titled),
                                      ignoresMouseEvents: window.ignoresMouseEvents)
            if let role = WindowCaptureRoles.role(for: traits) { direct.register(window, role: role) }
        }
        let made = second.makePanel()
        defer { made.close() }
        #expect(direct.excludedWindowNumbers.contains(made.windowNumber))
    }

    @Test func theHUDShowsTheLastTurnAndTheSession() {
        let content = LatencyHUDContent.make(timings: LatencyHUDSnapshots.sampleTimings(), stats: LatencyHUDSnapshots.sampleStats())
        #expect(content.title == "Voice turn · claude-haiku-5-5")
        #expect(content.rows.contains(LatencyHUDContent.Row("release → first line heard", "1850 ms", emphasized: true)))
        #expect(content.rows.contains { $0.label == "cache" && $0.value.hasPrefix("hit, 86%") })
        #expect(content.rows.contains(LatencyHUDContent.Row("request body", "412 KB")))
        #expect(content.footer == "thread 23 items (3 screenshots) · 6 turns · 1 compaction")
        #expect(LatencyHUDContent.make(timings: nil, stats: nil).rows == [LatencyHUDContent.Row("Last turn", "none yet")])
    }
}
