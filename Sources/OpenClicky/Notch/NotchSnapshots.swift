import AppKit
import OpenClickyKit
import SwiftUI

/// `OpenClicky --render-notch-snapshots <folder>`: renders the notch in each state offscreen (the folded notch and its
/// hover lip, the voice pill, every live-event card, the onboarding card, and the open Home, Chat and Settings tabs)
/// under a mock menu bar with a camera housing, driven through the real presenter. Uses the Home fixtures: no key,
/// permission, calendar or window list is touched.
@MainActor
enum NotchSnapshots {
    static func run(into folder: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fixture = try EvidenceSnapshots.Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try renderAll(fixture: fixture, into: folder)
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }

    static let canvas = NSSize(width: 1000, height: 540)
    /// A 208 × 37.5 pt housing, as on the 13" MacBook Air this was built on.
    static let geometry = NotchGeometry(screenFrame: CGRect(origin: .zero, size: canvas),
                                        notchRect: CGRect(x: (canvas.width - 208) / 2, y: canvas.height - 37.5, width: 208, height: 37.5))

    static func renderAll(fixture: EvidenceSnapshots.Fixture, into folder: URL) throws {
        func out(_ name: String) -> URL { folder.appendingPathComponent("notch-" + name + ".png") }
        let app = fixture.model
        let home = fixture.services
        let base = Date()

        func makeController() -> NotchController {
            let controller = NotchController(app: app, home: home, voiceLoop: nil, settingsURL: nil,
                                             folderNotice: FolderAccessNotice(storage: InMemoryNoticeStorage()))
            controller.model.setGeometries([1: geometry])
            controller.model.send(.pointer(display: 1, inHotZone: false, inPanel: false), now: base)
            return controller
        }
        func render(_ controller: NotchController, _ name: String) throws {
            try EvidenceSnapshots.render(screen(controller), size: canvas, to: out(name), settle: 0.5)
        }

        // Folded, and the pointer resting on the housing (60% of the dwell).
        var controller = makeController()
        try render(controller, "tucked")
        controller.model.send(.pointer(display: 1, inHotZone: true, inPanel: true), now: base)
        controller.model.send(.tick, now: base.addingTimeInterval(0.27))
        try render(controller, "hover-dwell")

        // The voice pill in the notch.
        controller = makeController()
        var listening = TurnDisplay()
        listening.phase = .listening
        listening.kind = .voice
        listening.liveTranscript = "when is my next meeting"
        app.turn = listening
        controller.model.send(.activity(true), now: base)
        try render(controller, "activity-listening")
        // The same pill with its Stop, while an answer is spoken.
        var speaking = TurnDisplay()
        speaking.phase = .speaking
        speaking.kind = .voice
        speaking.words = "when is my next meeting"
        speaking.lines = ["Your next meeting is the design stand-up at 10."]
        app.turn = speaking
        controller.model.send(.stoppable(.voice), now: base)
        try render(controller, "activity-stop-pill")
        controller.model.send(.stoppable(nil), now: base)
        app.turn = TurnDisplay()

        // Every live event, each on a fresh notch, a few seconds into its time so the ring shows.
        for (name, event) in liveEvents(now: base) {
            controller = makeController()
            controller.model.send(.post(event), now: base)
            controller.model.send(.tick, now: base.addingTimeInterval(3))
            try render(controller, "event-" + name)
        }

        // Onboarding pinned.
        controller = makeController()
        controller.model.send(.onboarding(pinned: true), now: base)
        try render(controller, "onboarding")

        // Open: Home with the next meeting and the fixture's jobs, Chat empty and answering, Settings.
        controller = makeController()
        controller.model.send(.post(liveEvents(now: base)[0].1), now: base)
        controller.model.send(.clickNotch(display: 1), now: base.addingTimeInterval(1))
        try render(controller, "open-home")
        controller.model.send(.selectTab(.chat), now: base.addingTimeInterval(2))
        controller.model.draft = "how do I change my favorite color?"
        try render(controller, "open-chat-input")
        controller.model.draft = ""
        controller.model.send(.submitText("how do I change my favorite color?"), now: base.addingTimeInterval(3))
        var typed = TurnDisplay()
        typed.kind = .typed
        typed.phase = .drawing
        typed.words = "how do I change my favorite color?"
        typed.lines = ["Open the Favorite color menu next to your name.", "Pick a color, then press Say hello to update the greeting."]
        app.turn = typed
        try render(controller, "open-chat-response")
        app.turn = TurnDisplay()
        controller.model.send(.selectTab(.settings), now: base.addingTimeInterval(4))
        try render(controller, "open-settings")
    }

    static func liveEvents(now: Date) -> [(String, NotchLiveEvent)] {
        let start = now.addingTimeInterval(4 * 60 + 20)
        let record = CalendarEventRecord(id: "standup", title: "Design stand-up", start: start, end: start.addingTimeInterval(1800),
                                         location: "Room 4, 1 Main St", notes: "Join at https://acme.zoom.us/j/555123")
        let meeting = UpcomingMeeting(event: record, now: now)
        let countdown = MeetingCountdownPolicy().event(for: .upcoming(meeting), dismissed: [], now: now)!
        func event(_ id: String, _ kind: NotchLiveEvent.Kind) -> NotchLiveEvent { NotchLiveEvent(id: id, kind: kind, postedAt: now) }
        return [
            ("meeting", countdown),
            ("job-launched", event("l", .jobLaunched(jobID: "j1", title: "Compare flights"))),
            ("job-needs-you", event("n", .jobNeedsYou(jobID: "j1", title: "Compare flights", detail: "Which airport, SFO or OAK?"))),
            ("job-done", event("d", .jobDone(jobID: "j1", title: "Compare flights", summary: "The 9:40 from SFO is the cheapest at $212.",
                                             file: "/tmp/jobs/j1/flights.md"))),
            ("job-failed", event("f", .jobFailed(jobID: "j2", title: "Inbox sweep", summary: "Claude Code exited before it finished."))),
            ("folder-denied", event("fa1", .folderAccessDenied(folder: .desktop, document: "Lease.pdf", showsDontShowAgain: false))),
            ("folder-denied-again", event("fa2", .folderAccessDenied(folder: .documents, document: "Budget.xlsx", showsDontShowAgain: true))),
            ("dictation-copied", event("dc", .dictationCopied(preview: "send the deck to Maya by Friday", why: "The field lost focus"))),
            ("muted-reply", event("mr", .replyCopiedMuted(preview: "Your lease renews on March 1st. The notice period is sixty days.", lineCount: 2))),
            ("routine-done", event("rd", .routineDone(jobID: "j3", title: "Morning brief", summary: "Three meetings today; the 2 pm moved to 3.",
                                                      file: "/tmp/jobs/j3/brief.md"))),
            ("routine-failed", event("rf", .routineFailed(jobID: "j4", title: "Weekly invoices", summary: "Codex couldn't sign in."))),
            ("usage-warned", event("uw", .usageLimit(.warned, message: "You've used $4.12 of your $5.00 limit today."))),
            ("usage-stopped", event("us", .usageLimit(.stopped, message:
                "You've reached your $5.00 limit today, so OpenClicky has stopped calling paid models. Raise it in Settings → Usage."))),
            ("provider-unavailable", event("pu", .providerUnavailable(provider: "OpenRouter", purpose: "brain",
                                                                       explanation: "OpenRouter didn't answer: something on this network may be blocking it."))),
            ("browser-connected", event("bc", .browserConnected(browser: "Google Chrome"))),
            ("browser-disconnected", event("bd", .browserDisconnected(browser: "Google Chrome"))),
            ("takeover-driving", event(TakeoverLiveEvents.eventID, .takeoverDriving(task: "Rename the three screenshots on the Desktop",
                                                                                   detail: "Click Rename", dryRun: false))),
            ("always-on-listening", event(AlwaysOnLiveEvents.eventID, .alwaysOnListening(hint: "Triple-tap Control ends it"))),
        ]
    }

    /// The notch over a mock desktop: wallpaper, a menu bar and the camera housing.
    private static func screen(_ controller: NotchController) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.32, green: 0.45, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Image(systemName: "apple.logo")
                    Text("Preview").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Sat 9:41 AM")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 37.5)
                .background(.black.opacity(0.25))
                Spacer()
            }
            // The housing itself (black, where the screen has no pixels).
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: 208, height: 37.5)
            NotchRootView(display: 1, controller: controller)
                .environment(controller.model)
                .environment(controller.appModel)
                .environment(controller.homeServices)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}
