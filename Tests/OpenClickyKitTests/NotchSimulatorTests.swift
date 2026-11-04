import Foundation
import Testing
@testable import OpenClickyKit

@Suite("Notch simulator")
struct NotchSimulatorTests {
    /// docs/examples/notch-script.json, the script `occtl notch simulate` evidence runs use.
    static func exampleScript() throws -> NotchScript {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/examples/notch-script.json")
        return try JSONDecoder().decode(NotchScript.self, from: Data(contentsOf: url))
    }

    @Test func theExampleSessionRunsEveryEventSourceThroughThePresenter() async throws {
        let result = await NotchSimulator.run(try Self.exampleScript())
        let names = result.surfaces.map(\.surface.name)
        func shown(_ prefix: String) -> Bool { result.effects.contains { if case .shown(let id) = $0 { id.hasPrefix(prefix) } else { false } } }

        #expect(shown("meeting:standup@"))
        #expect(shown("job:j1:launched:1"))
        #expect(names.contains("open(home)"), "resting on the notch opened it")
        #expect(names.contains("open(chat)"))
        #expect(result.effects.contains(.submit("what's on my screen?")))
        #expect(shown("job:j1:request:"))
        #expect(result.effects.contains(.openJob("j1")), "clicking the needs-you card opens the job")
        #expect(shown("folder-access:/Users/you/Desktop/Lease.pdf"))
        #expect(names.contains("activity"))
        #expect(shown("muted-reply:"))
        #expect(result.clipboard == "Your lease renews on March 1st. The notice period is sixty days.")
        #expect(shown("dictation:"))
        #expect(names.contains("hidden(spotlight)"))
        #expect(names.contains("hidden(fullscreen)"))
        #expect(shown("job:j1:report:1"))
        // Shown at 15 s, skipped at 70 s, shown again at 700 s with Don't show again, which was used.
        #expect(result.folderNoticeShowCount == 2)
        #expect(result.folderNoticeSuppressed)
        #expect(result.effects.contains(.suppress(.folderAccessNotice)))
        #expect(result.log.contains { $0.contains("folder notice not shown (shown recently)") })
        #expect(result.log.contains { $0.contains("folder notice not shown (turned off)") })
        #expect(result.presenter.pendingEvents.isEmpty)
    }

    @Test func theMeetingCountdownSurvivesShortEventsAndJoinOpensTheCall() async throws {
        let script = NotchScript(steps: [
            .init(at: 0, meeting: .init(id: "m", title: "Board call", startsIn: 120, url: "https://meet.google.com/aaa-bbbb-ccc")),
            .init(at: 1, dictation: .init(text: "hello", result: "noTarget")),
            .init(at: 10, action: "join"),
        ], tail: 1)
        let result = await NotchSimulator.run(script)
        let order = result.effects.compactMap { effect -> String? in if case .shown(let id) = effect { id } else { nil } }
        #expect(order.count == 2)
        #expect(order.first?.hasPrefix("meeting:m@") == true)
        #expect(order.last?.hasPrefix("dictation:") == true)
        #expect(result.effects.contains(.openURL(URL(string: "https://meet.google.com/aaa-bbbb-ccc")!)))
        #expect(result.presenter.current == nil, "joined: the countdown is gone and doesn't come back on the next poll")
    }

    @Test func nothingIsAnnouncedThatDidNotHappen() async {
        // A dictation whose clipboard write failed, and a muted answer the user cut off with Escape.
        var cut = NotchScript.Step(at: 2)
        cut.reply = NotchScript.Reply(kind: "voice", lines: ["One.", "Two."], muted: true, speaksTypedAnswers: nil, cutOff: true)
        let script = NotchScript(steps: [.init(at: 1, dictation: .init(text: "hello", result: "clipboardFailed")), cut], tail: 1)
        let result = await NotchSimulator.run(script)
        #expect(!result.effects.contains { if case .shown = $0 { true } else { false } })
        #expect(result.clipboard == nil)
        #expect(result.log.contains { $0.contains("reply cut off (voice, muted); nothing copied") })
    }

    @Test func screenshotUIYieldIsCappedByItsHardLimit() async {
        let capture = NotchScript.Window(owner: "screencaptureui", bundleID: "com.apple.screencaptureui", layer: 25, frame: [500, 980, 700, 60])
        let script = NotchScript(steps: [.init(at: 0, windows: [capture]), .init(at: 50, note: "still up")], tail: 1)
        let result = await NotchSimulator.run(script)
        let names = result.surfaces.map(\.surface.name)
        #expect(names.contains("hidden(screenshot_ui)"))
        #expect(names.last == "tucked", "after 45 s OpenClicky comes back even though the capture UI is still listed")
    }
}

extension NotchScript.Step {
    init(at: Double, note: String? = nil, click: String? = nil, action: String? = nil, windows: [NotchScript.Window]? = nil,
         meeting: NotchScript.Meeting? = nil, dictation: NotchScript.Dictation? = nil) {
        self.init(at: at, note: note, pointer: nil, click: click, key: nil, type: nil, action: action, activity: nil, onboarding: nil,
                  windows: windows, fullscreen: nil, meeting: meeting, calendarAccess: nil, job: nil, report: nil, dictation: dictation,
                  deniedDocument: nil, reply: nil)
    }
}

extension NotchScript.Meeting {
    init(id: String, title: String, startsIn: Double, url: String) {
        self.init(id: id, title: title, startsIn: startsIn, minutes: nil, url: url, location: nil, notes: nil)
    }
}
