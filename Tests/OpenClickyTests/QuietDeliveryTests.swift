import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct QuietDeliveryTests {
    @Test func notchDeliveriesAndReportNotesShareTheGateWithoutReplacingCallbacks() {
        let focus = FixedFocusStatus(.manuallyEnabled(mode: "Fixture"))
        let quiet = QuietHold(monitor: QuietContextMonitor(sources: .init(focus: focus, calls: nil)))
        let audio = AudioRobustness(quiet: quiet)
        quiet.start()
        defer { quiet.stop() }
        var shown: [String] = []
        var notes: [String] = []
        audio.onRelease = { notes += $0.map(\.payload) }
        let now = Date()
        audio.offer(ProactiveItem(id: "notch:meeting", kind: .meetingCountdown, title: "Meeting", createdAt: now)) { shown.append("meeting") }
        audio.offer(ProactiveItem(id: "notch:answered", kind: .jobReport, title: "Answered", createdAt: now)) { shown.append("answered") }
        audio.withdraw("notch:answered")
        #expect(!audio.offer(ProactiveItem(id: "report", kind: .jobReport, title: "Report", payload: "Tell the user", createdAt: now)))
        #expect(shown.isEmpty && notes.isEmpty)
        focus.set(nil)
        quiet.refresh()
        #expect(shown == ["meeting"])
        #expect(notes == ["Tell the user"])
        #expect(quiet.held.isEmpty)
        quiet.refresh()
        #expect(shown == ["meeting"] && notes == ["Tell the user"])
    }
}
