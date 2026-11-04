import Foundation
import Testing
@testable import OpenClickyKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ id: String, _ kind: NotchLiveEvent.Kind, at seconds: Double = 0) -> NotchLiveEvent {
    NotchLiveEvent(id: id, kind: kind, postedAt: at(seconds))
}

private let done = NotchLiveEvent.Kind.jobDone(jobID: "j1", title: "Research", summary: "Found three options.", file: nil)
private let launched = NotchLiveEvent.Kind.jobLaunched(jobID: "j2", title: "Inbox sweep")

private func meeting(startsIn seconds: Double, now: Double = 0, url: String? = "https://meet.google.com/abc-defg-hij") -> NotchLiveEvent {
    let start = at(now + seconds)
    let record = CalendarEventRecord(id: "m1", title: "Design review", start: start, end: start.addingTimeInterval(1800),
                                     url: url.flatMap(URL.init(string:)))
    let upcoming = UpcomingMeeting(event: record, secondsUntilStart: seconds, action: MeetingCountdown.primaryAction(for: record))
    return NotchLiveEvent(id: MeetingCountdownPolicy.eventID(for: record), kind: .meetingCountdown(upcoming), postedAt: at(now))
}

@Suite("Notch presenter")
struct NotchPresenterTests {
    @Test func hoverDwellOpensAndLeavingFoldsIt() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        #expect(presenter.surface == .tucked)
        #expect(presenter.dwellProgress(now: at(0.2))! > 0.4)
        presenter.handle(.tick, now: at(0.3))
        #expect(!presenter.isExpanded)
        presenter.handle(.tick, now: at(0.5))
        #expect(presenter.surface == .open(.home))
        #expect(presenter.openedBy == .hover)
        // Moving down into the open panel keeps it open; leaving it folds it after the grace.
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: true), now: at(0.8))
        presenter.handle(.tick, now: at(2))
        #expect(presenter.isExpanded)
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(2.1))
        presenter.handle(.tick, now: at(2.5))
        #expect(presenter.isExpanded)
        presenter.handle(.tick, now: at(2.8))
        #expect(presenter.surface == .tucked)
    }

    @Test func foldingWithThePointerOnTheNotchDoesNotBounceItOpen() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        presenter.handle(.tick, now: at(0.5))
        #expect(presenter.isExpanded)
        presenter.handle(.escape, now: at(1))
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(1.1))
        presenter.handle(.tick, now: at(3))
        #expect(!presenter.isExpanded, "the pointer never left the housing")
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(3.1))
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(3.2))
        presenter.handle(.tick, now: at(3.7))
        #expect(presenter.isExpanded, "back on the housing after leaving it opens it again")
    }

    @Test func leavingBeforeTheDwellEndsResetsIt() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(0.3))
        #expect(presenter.dwellProgress(now: at(0.3)) == nil)
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0.4))
        presenter.handle(.tick, now: at(0.7))
        #expect(!presenter.isExpanded)
        presenter.handle(.tick, now: at(0.9))
        #expect(presenter.isExpanded)
    }

    @Test func hoverCanBeTurnedOffAndDoesNotOpenDuringATurn() {
        var off = NotchPresenter(timing: NotchTiming(hoverOpens: false))
        off.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        off.handle(.tick, now: at(2))
        #expect(!off.isExpanded)

        var busy = NotchPresenter()
        busy.handle(.activity(true), now: at(0))
        busy.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        busy.handle(.tick, now: at(2))
        #expect(busy.surface == .activity)
        // A click still opens it.
        busy.handle(.clickNotch(display: 1), now: at(2.1))
        #expect(busy.surface == .open(.home))
    }

    @Test func clickOpensAndOnlyAnOutsideClickOrEscapeFoldsIt() {
        var presenter = NotchPresenter()
        presenter.handle(.clickNotch(display: 1), now: at(0))
        #expect(presenter.openedBy == .click)
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(0.1))
        presenter.handle(.tick, now: at(5))
        #expect(presenter.isExpanded, "a clicked-open notch stays open when the pointer wanders off")
        #expect(presenter.wantsEscape)
        presenter.handle(.clickOutside, now: at(5.1))
        #expect(!presenter.isExpanded)
        presenter.handle(.clickNotch(display: 1), now: at(6))
        presenter.handle(.escape, now: at(6.1))
        #expect(!presenter.isExpanded)
        #expect(!presenter.wantsEscape)
        // Clicking the open notch again folds it too.
        presenter.handle(.clickNotch(display: 1), now: at(7))
        presenter.handle(.clickNotch(display: 1), now: at(7.1))
        #expect(!presenter.isExpanded)
    }

    @Test func tabsAndTheChatPresentations() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(0))
        presenter.handle(.tick, now: at(0.5))
        #expect(presenter.presentation == .idle)
        let focus = presenter.handle(.selectTab(.chat), now: at(1))
        #expect(focus == [.focusComposer])
        #expect(presenter.presentation == .textInput)
        #expect(presenter.openedBy == .click, "choosing a tab pins a hover-opened notch")
        let sent = presenter.handle(.submitText("  what's on my screen?  "), now: at(2))
        #expect(sent == [.submit("what's on my screen?")])
        #expect(presenter.presentation == .textResponse)
        presenter.handle(.selectTab(.settings), now: at(3))
        #expect(presenter.surface == .open(.settings))
        #expect(presenter.presentation == .idle)
        // The text key opens a fresh composer.
        presenter.handle(.clickOutside, now: at(4))
        presenter.handle(.openChat(display: 1), now: at(5))
        #expect(presenter.presentation == .textInput)
        #expect(presenter.openedBy == .textKey)
        #expect(presenter.handle(.submitText("   "), now: at(6)).isEmpty)
    }

    @Test func liveEventsShowOneAtATimeAndExpire() {
        var presenter = NotchPresenter()
        let first = presenter.handle(.post(event("a", done)), now: at(0))
        #expect(first == [.shown("a")])
        presenter.handle(.post(event("b", launched, at: 0.1)), now: at(0.1))
        #expect(presenter.presentation == .liveEvent(event("a", done)))
        // Done lasts 8 s on screen, then the launch note gets its 4 s.
        presenter.handle(.tick, now: at(7.9))
        #expect(presenter.current?.event.id == "a")
        let next = presenter.handle(.tick, now: at(8.05))
        #expect(next == [.shown("b")])
        presenter.handle(.tick, now: at(12.2))
        #expect(presenter.surface == .tucked)
    }

    @Test func anEventsClockStopsWhileItIsNotOnScreen() {
        var presenter = NotchPresenter()
        presenter.handle(.post(event("a", launched)), now: at(0))
        presenter.handle(.tick, now: at(1))
        // A voice turn takes the notch for 10 s; the note keeps its remaining 3 s.
        presenter.handle(.activity(true), now: at(1))
        presenter.handle(.tick, now: at(11))
        #expect(presenter.surface == .activity)
        presenter.handle(.activity(false), now: at(11))
        #expect(presenter.current?.event.id == "a")
        presenter.handle(.tick, now: at(13.5))
        #expect(presenter.current?.event.id == "a")
        presenter.handle(.tick, now: at(14.1))
        #expect(presenter.current == nil)
        // Posted while open: waits until the notch folds.
        presenter.handle(.clickNotch(display: 1), now: at(20))
        presenter.handle(.post(event("c", launched)), now: at(20))
        #expect(presenter.surface == .open(.home))
        presenter.handle(.tick, now: at(40))
        presenter.handle(.clickOutside, now: at(40))
        #expect(presenter.surface == .liveEvent(event("c", launched)))
    }

    @Test func aMeetingCountdownStepsBackForShortEventsAndEndsOnTime() {
        var presenter = NotchPresenter()
        let countdown = meeting(startsIn: 240)
        presenter.handle(.post(countdown), now: at(0))
        #expect(presenter.current?.event.id == countdown.id)
        presenter.handle(.post(event("done", done, at: 30)), now: at(30))
        #expect(presenter.current?.event.id == "done")
        presenter.handle(.tick, now: at(38.1))
        #expect(presenter.current?.event.id == countdown.id, "the countdown comes back after the short event")
        // Gone five minutes after the start (the latecomers' grace).
        presenter.handle(.tick, now: at(240 + 299))
        #expect(presenter.current != nil)
        presenter.handle(.tick, now: at(240 + 301))
        #expect(presenter.current == nil)
    }

    @Test func aMoreUrgentEventStepsInFrontAndTheOtherKeepsItsTime() {
        var presenter = NotchPresenter()
        presenter.handle(.post(event("done", done)), now: at(0))
        presenter.handle(.tick, now: at(3))
        let question = event("ask", .jobNeedsYou(jobID: "j1", title: "Research", detail: "Which city?"), at: 3)
        #expect(presenter.handle(.post(question), now: at(3)) == [.shown("ask")])
        presenter.handle(.dismiss("ask"), now: at(5))
        #expect(presenter.current?.event.id == "done")
        presenter.handle(.tick, now: at(9.9))
        #expect(presenter.current?.event.id == "done", "it had 5 of its 8 seconds left")
        presenter.handle(.tick, now: at(10.1))
        #expect(presenter.current == nil)
        // Equal priority waits its turn.
        presenter.handle(.post(event("d1", .dictationCopied(preview: nil, why: "x"))), now: at(20))
        presenter.handle(.post(event("d2", .dictationCopied(preview: nil, why: "y"), at: 21)), now: at(21))
        #expect(presenter.current?.event.id == "d1")
    }

    @Test func repostingUpdatesInPlaceAndWithdrawRemoves() {
        var presenter = NotchPresenter()
        presenter.handle(.post(meeting(startsIn: 240)), now: at(0))
        // The next poll sees the same occurrence a minute closer, under a new title.
        var renamed = meeting(startsIn: 180, now: 60)
        if case .meetingCountdown(var upcoming) = renamed.kind {
            upcoming.event.title = "Design review (moved rooms)"
            renamed.kind = .meetingCountdown(upcoming)
        }
        presenter.handle(.post(renamed), now: at(60))
        #expect(presenter.pendingEvents.count == 1)
        #expect(presenter.current?.event.title == "Design review (moved rooms)")
        presenter.handle(.withdraw(renamed.id), now: at(61))
        #expect(presenter.current == nil)
    }

    @Test func actionsProduceEffectsAndDismissTheEvent() throws {
        var presenter = NotchPresenter()
        let countdown = meeting(startsIn: 120)
        presenter.handle(.post(countdown), now: at(0))
        let join = presenter.handle(.perform(eventID: countdown.id, actionID: "join"), now: at(1))
        #expect(join == [.openURL(URL(string: "https://meet.google.com/abc-defg-hij")!), .dismissed(countdown.id)])
        #expect(presenter.current == nil)

        let notice = event("folder", .folderAccessDenied(folder: .desktop, document: "Plan.pdf", showsDontShowAgain: true))
        presenter.handle(.post(notice), now: at(2))
        let suppress = presenter.handle(.perform(eventID: "folder", actionID: "suppress"), now: at(3))
        #expect(suppress == [.suppress(.folderAccessNotice), .dismissed("folder")])

        presenter.handle(.post(event("job", done)), now: at(4))
        let body = presenter.handle(.clickEvent("job"), now: at(5))
        #expect(body == [.openJob("j1"), .dismissed("job")])

        presenter.handle(.post(event("dict", .dictationCopied(preview: "hello", why: "The field lost focus"))), now: at(6))
        // No body action: a click opens the notch instead, and the event waits.
        #expect(presenter.handle(.clickEvent("dict"), now: at(7)).isEmpty)
        #expect(presenter.isExpanded)
        #expect(presenter.handle(.dismiss("dict"), now: at(8)) == [.dismissed("dict")])
        #expect(presenter.pendingEvents.isEmpty)
        #expect(presenter.handle(.perform(eventID: "missing", actionID: "join"), now: at(9)).isEmpty)
    }

    @Test func systemUIAndFullscreenHideTheNotch() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(0))
        presenter.handle(.clickNotch(display: 1), now: at(0))
        presenter.handle(.yield([.spotlight]), now: at(1))
        #expect(presenter.surface == .hidden(.yielding(.spotlight)))
        #expect(!presenter.isExpanded, "stepping aside folds the open notch")
        // Hovering while hidden does nothing.
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: false), now: at(1.1))
        presenter.handle(.tick, now: at(3))
        #expect(!presenter.isExpanded)
        presenter.handle(.yield([]), now: at(4))
        #expect(presenter.surface == .tucked)

        presenter.handle(.fullscreen([1]), now: at(5))
        #expect(presenter.surface == .hidden(.fullscreen))
        #expect(presenter.surface(on: 2) == .tucked)
        presenter.handle(.clickNotch(display: 1), now: at(5.1))
        #expect(!presenter.isExpanded)
        // An event posted meanwhile waits with its clock stopped.
        presenter.handle(.post(event("a", launched)), now: at(6))
        presenter.handle(.tick, now: at(30))
        presenter.handle(.fullscreen([]), now: at(30))
        #expect(presenter.surface == .liveEvent(event("a", launched)))
    }

    @Test func overAFullScreenAppOnlyAVoiceTurnsPillShows() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(0))
        presenter.handle(.fullscreen([1]), now: at(0))
        presenter.handle(.post(event("a", done)), now: at(0))
        #expect(presenter.surface == .hidden(.fullscreen))
        // The talk keys over a full-screen video: the pill is the only sign they were heard.
        presenter.handle(.activity(true), now: at(1))
        #expect(presenter.surface == .activity)
        #expect(presenter.surface(on: 1) == .activity)
        #expect(presenter.surface(on: 2) == .tucked, "only the display being used shows it")
        presenter.handle(.clickNotch(display: 1), now: at(2))
        #expect(!presenter.isExpanded, "nothing opens over a full-screen app")
        presenter.handle(.activity(false), now: at(9))
        #expect(presenter.surface == .hidden(.fullscreen))
        #expect(presenter.current?.event.id == "a", "the event waited with its clock stopped")
        presenter.handle(.tick, now: at(30))
        presenter.handle(.fullscreen([]), now: at(30))
        #expect(presenter.surface == .liveEvent(event("a", done)))
        // System UI still hides even the pill.
        presenter.handle(.activity(true), now: at(31))
        presenter.handle(.yield([.missionControl]), now: at(31))
        #expect(presenter.surface == .hidden(.yielding(.missionControl)))
    }

    @Test func onboardingPinsTheNotch() {
        var presenter = NotchPresenter()
        presenter.handle(.clickNotch(display: 1), now: at(0))
        presenter.handle(.onboarding(pinned: true), now: at(1))
        #expect(presenter.presentation == .onboardingPinned)
        #expect(presenter.surface == .onboarding)
        presenter.handle(.clickOutside, now: at(2))
        presenter.handle(.clickNotch(display: 1), now: at(2))
        presenter.handle(.pointer(display: 1, inHotZone: true, inPanel: true), now: at(3))
        presenter.handle(.tick, now: at(5))
        #expect(presenter.surface == .onboarding)
        presenter.handle(.activity(true), now: at(6))
        #expect(presenter.surface == .activity, "a voice turn during setup still shows")
        presenter.handle(.activity(false), now: at(7))
        presenter.handle(.onboarding(pinned: false), now: at(8))
        #expect(presenter.surface == .tucked)
    }

    @Test func otherDisplaysKeepOnlyTheirNotch() {
        var presenter = NotchPresenter()
        presenter.handle(.pointer(display: 2, inHotZone: false, inPanel: false), now: at(0))
        presenter.handle(.post(event("a", done)), now: at(0))
        #expect(presenter.surface(on: 2) == .liveEvent(event("a", done)))
        #expect(presenter.surface(on: 1) == .tucked)
        presenter.handle(.clickNotch(display: 2), now: at(1))
        // While open the notch stays on its display even if the pointer crosses over.
        presenter.handle(.pointer(display: 1, inHotZone: false, inPanel: false), now: at(1.1))
        #expect(presenter.activeDisplay == 2)
    }

    @Test func countdownWording() {
        #expect(NotchLiveEvent.countdownText(start: at(600), now: at(0)) == "Starts in 10 min")
        #expect(NotchLiveEvent.countdownText(start: at(95), now: at(0)) == "Starts in 2 min")
        #expect(NotchLiveEvent.countdownText(start: at(45), now: at(0)) == "Starts in 45 s")
        #expect(NotchLiveEvent.countdownText(start: at(2), now: at(0)) == "Starting now")
        #expect(NotchLiveEvent.countdownText(start: at(0), now: at(200)) == "Started 3 min ago")
    }
}
