import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private func record(_ id: String, status: AgentJobStatus, runs: Int = 1, request: AgentApprovalRequest? = nil, name: String? = nil) -> AgentJobRecord {
    AgentJobRecord(id: id, kind: name == nil ? .job : .kept, title: "Compare flights", task: "Compare flights", agentName: name,
                   harness: .claudeCode, model: nil, provider: "harness-login", status: status, createdAt: t0, updatedAt: t0,
                   runs: (0..<runs).map { _ in AgentRun(ask: "Compare flights", startedAt: t0) }, pendingRequest: request, folderPath: "/tmp/\(id)")
}

@Suite("Notch event sources")
struct NotchEventSourceTests {
    // MARK: Meetings

    @Test func theCountdownShowsInsideTheLeadTimeWithTheRightButtons() async {
        let clock = Clock()
        let call = CalendarEventRecord(id: "e1", title: "Stand-up", start: at(4 * 60), end: at(19 * 60), location: "Room 4, 1 Main St",
                                       notes: "Join: https://acme.zoom.us/j/123456", url: URL(string: "https://calendar.example.com/e1"))
        let store = InMemoryCalendarStore(events: [call])
        let monitor = MeetingCountdownMonitor(service: CalendarService(store: store, clock: CalendarClock(now: { clock.now })),
                                              policy: MeetingCountdownPolicy(leadMinutes: 5))
        guard case .show(let event, nil) = await monitor.poll() else { Issue.record("expected a countdown"); return }
        #expect(event.id == "meeting:e1@\(Int(at(240).timeIntervalSince1970))")
        #expect(event.title == "Stand-up")
        #expect(event.subtitle(now: t0) == "Starts in 4 min")
        #expect(event.symbol == "video.fill")
        let actions = event.actions
        #expect(actions.map(\.id) == ["join", "directions", "open", "dismiss"])
        #expect(actions.first?.isPrimary == true)
        #expect(actions.filter(\.isPrimary).count == 1)
        if case .openURL(let url) = actions[0].kind { #expect(url.absoluteString == "https://acme.zoom.us/j/123456") }
        if case .openURL(let url) = actions[1].kind { #expect(url.absoluteString.hasPrefix("https://maps.apple.com/?daddr=Room%204")) }

        // Dismissed: never again for this occurrence; the next poll withdraws nothing it doesn't show.
        await monitor.dismiss(event.id)
        #expect(await monitor.poll() == .nothing)

        // A monitor restarted for a new lead time keeps what the user closed closed.
        let restarted = MeetingCountdownMonitor(service: CalendarService(store: store, clock: CalendarClock(now: { clock.now })),
                                                policy: MeetingCountdownPolicy(leadMinutes: 10), dismissed: [event.id])
        #expect(await restarted.poll() == .nothing)
    }

    @Test func tooEarlyNoAccessAndAMovedMeeting() async {
        let clock = Clock()
        let later = CalendarEventRecord(id: "e2", title: "1:1", start: at(20 * 60), end: at(50 * 60))
        let store = InMemoryCalendarStore(events: [later])
        let monitor = MeetingCountdownMonitor(service: CalendarService(store: store, clock: CalendarClock(now: { clock.now })))
        #expect(await monitor.poll() == .nothing, "20 minutes out is outside the 5-minute lead")
        clock.now = at(16 * 60)
        guard case .show(let first, nil) = await monitor.poll() else { Issue.record("expected a countdown"); return }
        // Only a place, no link: Directions leads. Without a place or a link: a Calendar button.
        #expect(MeetingCountdownPolicy.actions(for: CalendarEventRecord(id: "x", title: "Lunch", start: t0, end: t0, location: "Café Rose"))
            .map(\.id) == ["directions", "dismiss"])
        #expect(MeetingCountdownPolicy.actions(for: CalendarEventRecord(id: "y", title: "Focus", start: t0, end: t0, location: "Zoom"))
            .map(\.id) == ["calendar", "dismiss"])
        // Another meeting comes first now: the first countdown is replaced.
        await store.add(CalendarEventRecord(id: "e3", title: "Urgent sync", start: at(17 * 60), end: at(18 * 60)))
        guard case .show(let second, let replacing) = await monitor.poll() else { Issue.record("expected the new countdown"); return }
        #expect(second.title == "Urgent sync")
        #expect(replacing == first.id)
        // Access taken away: the countdown is withdrawn and the monitor never asks for access.
        await store.setAuthorization(.denied)
        #expect(await monitor.poll() == .withdraw(second.id))
        #expect(await store.accessRequests == 0)
    }

    // MARK: Folder notice

    @Test func theFolderNoticeCountsRepeatsAndCanBeTurnedOff() {
        let storage = InMemoryNoticeStorage()
        let notice = FolderAccessNotice(storage: storage, classifier: GuardedFolderClassifier(homeDirectory: URL(fileURLWithPath: "/Users/me")),
                                        repeatAfter: 600)
        let denied = ActiveDocument(kind: .pdf, reference: "/Users/me/Desktop/Plan.pdf", source: .file, accessDenied: true)
        let first = notice.event(for: denied, now: t0)
        guard case .folderAccessDenied(let folder, let document, let dontShow)? = first?.kind else { Issue.record("expected a notice"); return }
        #expect(folder == .desktop)
        #expect(document == "Plan.pdf")
        #expect(!dontShow, "the first notice offers Not now, not Don't show again")
        #expect(first?.subtitle(now: t0) == "Allow access to your Desktop folder in Files & Folders")
        #expect(first?.actions.first?.kind == .openURL(GuardedFolder.settingsURL))
        #expect(GuardedFolder.settingsURL.absoluteString.hasSuffix("Privacy_FilesAndFolders"))
        #expect(notice.showCount == 1)
        #expect(notice.event(for: denied, now: at(60)) == nil, "the same document isn't nagged about again for ten minutes")
        let second = notice.event(for: denied, now: at(601))
        guard case .folderAccessDenied(_, _, let offered)? = second?.kind else { Issue.record("expected a second notice"); return }
        #expect(offered)
        #expect(storage.integer(forKey: FolderAccessNotice.showCountKey) == 2)
        notice.suppress()
        #expect(notice.event(for: denied, now: at(5000)) == nil)
        #expect(storage.bool(forKey: FolderAccessNotice.suppressedKey))
        notice.reset()
        #expect(notice.event(for: denied, now: at(5001)) != nil)
        // Readable documents and web pages never raise it.
        #expect(notice.event(for: ActiveDocument(kind: .pdf, reference: "/tmp/a.pdf", source: .file), now: at(9000)) == nil)
        #expect(notice.event(for: ActiveDocument(kind: .webPage, reference: "https://x.com", source: .scripting, accessDenied: true),
                             now: at(9000)) == nil)
    }

    // MARK: Jobs

    @Test func aRunsClosingQuestionIsTakenBackOnceAnswered() {
        var mapper = AgentLiveEvents()
        mapper.seed([record("j2", status: .running)])
        let report = AgentJobReport(jobID: "j2", run: 1, title: "Book a table", outcome: .needsYou, spoken: "Which night?",
                                    files: [], question: "Which night?", startedAt: t0, finishedAt: t0)
        #expect(mapper.changes(for: .report(report), now: t0).post.map(\.id) == ["job:j2:report:1"])
        #expect(mapper.changes(for: .job(record("j2", status: .needsYou)), now: t0).withdraw.isEmpty, "still waiting")
        #expect(mapper.changes(for: .job(record("j2", status: .running, runs: 2)), now: t0).withdraw == ["job:j2:report:1"])
    }

    @Test func jobsAnnounceLaunchNeedsYouAndDone() {
        var mapper = AgentLiveEvents()
        mapper.seed([record("old", status: .running)])
        // A job that was already running at launch is not announced again.
        #expect(mapper.apply(.job(record("old", status: .running)), now: t0).isEmpty)

        let launched = mapper.apply(.job(record("j1", status: .queued)), now: t0)
        #expect(launched.map(\.id) == ["job:j1:launched:1"])
        #expect(launched.first?.title == "Started: Compare flights")
        #expect(mapper.apply(.job(record("j1", status: .running)), now: t0).isEmpty, "queued then running is one launch")

        let question = AgentApprovalRequest(id: "q1", kind: .question, summary: "Which airport, SFO or OAK?")
        let needs = mapper.apply(.job(record("j1", status: .needsYou, request: question)), now: t0)
        #expect(needs.map(\.id) == ["job:j1:request:q1"])
        #expect(needs.first?.subtitle(now: t0) == "Which airport, SFO or OAK?")
        #expect(needs.first?.tone == .attention)
        #expect(mapper.apply(.job(record("j1", status: .needsYou, request: question)), now: t0).isEmpty, "the same request once")
        // Answered (in the HUD or by voice): back to running is not a new launch, and the waiting card is taken back.
        let answered = mapper.changes(for: .job(record("j1", status: .running)), now: t0)
        #expect(answered.post.isEmpty)
        #expect(answered.withdraw == ["job:j1:request:q1"])
        #expect(mapper.changes(for: .job(record("j1", status: .running)), now: t0).withdraw.isEmpty, "taken back once")

        let report = AgentJobReport(jobID: "j1", run: 1, title: "Compare flights", outcome: .done, spoken: "The 9:40 from SFO is cheapest.",
                                    files: ["/tmp/j1/flights.md"], startedAt: t0, finishedAt: t0)
        let finished = mapper.apply(.report(report), now: t0)
        #expect(finished.first?.title == "Compare flights is done")
        #expect(finished.first?.actions.map(\.id) == ["file", "show"])
        #expect(mapper.apply(.job(record("j1", status: .done)), now: t0).isEmpty)

        // A follow-up run of a finished job is announced as a new launch.
        #expect(mapper.apply(.job(record("j1", status: .running, runs: 2)), now: t0).map(\.id) == ["job:j1:launched:2"])

        var failed = report
        failed.run = 2
        failed.outcome = .failed
        failed.error = "The harness exited."
        #expect(mapper.apply(.report(failed), now: t0).first?.title == "Compare flights didn't finish")
        failed.outcome = .stopped
        #expect(mapper.apply(.report(failed), now: t0).isEmpty, "the user stopped it; nothing to announce")
        // Kept agents go by their name.
        #expect(mapper.apply(.job(record("k1", status: .running, name: "Scout")), now: t0).first?.title == "Started: Scout")
    }

    // MARK: Dictation and the muted reply

    @Test func dictationOnTheClipboardBecomesAnEvent() {
        func report(_ outcome: InsertionOutcome, _ result: DictationResult, text: String = "send the deck to Maya", copied: Bool = true)
            -> DictationSessionReport {
            DictationSessionReport(rawTranscript: "send the deck to maya", cleanup: nil,
                                   insertion: InsertionReport(outcome: outcome, attempts: [], insertedText: text, copiedToClipboard: copied, target: nil),
                                   focus: nil, result: result)
        }
        // The preview is the text actually on the clipboard (after cleanup), not the raw transcript.
        let event = DictationLiveEvents.event(for: report(.copiedToClipboard(.focusLost), .copiedToClipboard(.focusLost)), now: t0)
        #expect(event?.title == "Dictation is on the clipboard")
        #expect(event?.subtitle(now: t0) == "The field lost focus · ⌘V pastes “send the deck to Maya”")
        let noAX = report(.refused(.accessibilityPermission), .refused(.accessibilityPermission), text: "")
        #expect(DictationLiveEvents.event(for: noAX, now: t0)?.subtitle(now: t0) == "Typing needs Accessibility · press ⌘V to paste")
        // Only when the text really is on the clipboard.
        #expect(DictationLiveEvents.event(for: report(.refused(.accessibilityPermission), .refused(.accessibilityPermission), copied: false),
                                          now: t0) == nil, "the salvage copy failed")
        #expect(DictationLiveEvents.event(for: report(.copiedToClipboard(.pasteboardWriteFailed), .copiedToClipboard(.pasteboardWriteFailed),
                                                      copied: false), now: t0) == nil)
        #expect(DictationLiveEvents.event(for: report(.inserted(.paste), .typed(appName: "Notes"), copied: false), now: t0) == nil)
        #expect(DictationLiveEvents.event(for: report(.refused(.secureField), .refused(.secureField), text: "", copied: false), now: t0) == nil)
        #expect(DictationLiveEvents.event(for: DictationSessionReport(rawTranscript: "", cleanup: nil, insertion: nil, focus: nil,
                                                                      result: .nothingHeard), now: t0) == nil)
    }

    @Test func aMutedReplyIsCopiedOnlyWhenItWasMeantToBeHeard() {
        let lines = ["Your next train leaves at 6:12.", "  ", "It's on platform 3."]
        #expect(MutedReplyPolicy.textToCopy(kind: .voice, spokenLines: lines, speaksTypedAnswers: false, output: .muted)
            == "Your next train leaves at 6:12. It's on platform 3.")
        #expect(MutedReplyPolicy.textToCopy(kind: .voice, spokenLines: lines, speaksTypedAnswers: false, output: .audible) == nil)
        #expect(MutedReplyPolicy.textToCopy(kind: .report, spokenLines: lines, speaksTypedAnswers: false,
                                            output: OutputSoundState(isMuted: false, volume: 0)) != nil, "volume at zero counts as muted")
        #expect(MutedReplyPolicy.textToCopy(kind: .typed, spokenLines: lines, speaksTypedAnswers: false, output: .muted) == nil,
                "typed answers are already on screen")
        #expect(MutedReplyPolicy.textToCopy(kind: .typed, spokenLines: lines, speaksTypedAnswers: true, output: .muted) != nil)
        #expect(MutedReplyPolicy.textToCopy(kind: .voice, spokenLines: [], speaksTypedAnswers: false, output: .muted) == nil)
        // Only a whole answer: one cut off with Escape or a failed turn leaves the clipboard alone.
        #expect(MutedReplyPolicy.textToCopy(kind: .voice, spokenLines: lines, speaksTypedAnswers: false, output: .muted,
                                            outcome: .cutOff(by: .escape, heard: 1, cutLine: 1, total: 2)) == nil)
        #expect(MutedReplyPolicy.textToCopy(kind: .voice, spokenLines: lines, speaksTypedAnswers: false, output: .muted,
                                            outcome: .failed("Sorry, that didn't work.")) == nil)
        #expect(OutputSoundState(isMuted: nil, volume: nil).isSilent == false, "an output without controls is assumed audible")
        let event = MutedReplyPolicy.event(copied: "Your next train leaves at 6:12.", lineCount: 2, now: t0)
        #expect(event.title == "Your Mac's sound is off")
        #expect(event.subtitle(now: t0) == "Reply copied: “Your next train leaves at 6:12.”")
    }

    @Test func settingsDecodeWithDefaultsAndClampTheLead() throws {
        let settings = try JSONDecoder().decode(NotchSettings.self, from: Data(#"{"hoverOpens": false, "meetingLeadMinutes": 600}"#.utf8))
        #expect(!settings.hoverOpens)
        #expect(settings.meetingLeadMinutes == 60)
        #expect(settings.interactive && settings.meetingCountdown && settings.jobEvents && settings.copiesReplyWhenMuted)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.save(to: url)
        #expect(NotchSettings.load(from: url) == settings)
    }
}
