import Foundation
import Testing
@testable import OpenClickyKit

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

/// An instant from ISO 8601 text with an offset.
private func at(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)!
}

/// Tuesday 3 November 2026, 10:00 in Los Angeles (PST, UTC-8), weeks starting on Sunday.
private let now = at("2026-11-03T10:00:00-08:00")
private let clock = CalendarClock(now: { now }, timeZone: losAngeles, firstWeekday: 1)

private let work = CalendarInfo(id: "cal-work", title: "Work")
private let home = CalendarInfo(id: "cal-home", title: "Home")
private let shared = CalendarInfo(id: "cal-holidays", title: "US Holidays", isWritable: false)

private func event(_ id: String, _ title: String, _ start: String, _ end: String, allDay: Bool = false, location: String? = nil,
                   notes: String? = nil, url: URL? = nil, calendar: CalendarInfo = work, attendees: [CalendarAttendee] = [],
                   cancelled: Bool = false) -> CalendarEventRecord {
    CalendarEventRecord(id: id, title: title, start: at(start), end: at(end), isAllDay: allDay, location: location, notes: notes,
                        url: url, calendar: calendar, attendees: attendees, isCancelled: cancelled)
}

private let sampleEvents: [CalendarEventRecord] = [
    event("standup", "Team standup", "2026-11-03T09:30:00-08:00", "2026-11-03T10:15:00-08:00", location: "https://meet.google.com/abc-defg-hij"),
    event("review", "Design review with Sam", "2026-11-03T14:00:00-08:00", "2026-11-03T15:00:00-08:00",
          attendees: [CalendarAttendee(name: "Sam Lee", email: "sam@example.com"), CalendarAttendee(name: "Me", isCurrentUser: true, response: .accepted)]),
    event("dentist", "Dentist", "2026-11-04T09:00:00-08:00", "2026-11-04T10:00:00-08:00", location: "1 Main St, Springfield", calendar: home),
    event("holiday", "Veterans Day", "2026-11-11T00:00:00-08:00", "2026-11-12T00:00:00-08:00", allDay: true, calendar: shared),
    event("cancelled", "Old sync", "2026-11-03T16:00:00-08:00", "2026-11-03T16:30:00-08:00", cancelled: true),
    event("hike", "Hike", "2026-11-07T08:00:00-08:00", "2026-11-07T12:00:00-08:00", calendar: home),
]

private func rig(_ store: InMemoryCalendarStore = InMemoryCalendarStore(calendars: [home, work, shared], events: sampleEvents)) -> AppToolRig {
    AppToolRig(calendar: store, clock: clock)
}

private func ids(_ result: AppToolResult) -> [String] {
    (result.details["events"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
}

@Suite("Calendar dates and ranges")
struct CalendarTimeTests {
    @Test func parsesTheFormsModelsWrite() {
        let cal = clock.calendar
        #expect(CalendarDateParser.parse("2026-11-03", calendar: cal) == CalendarDateInput(date: at("2026-11-03T00:00:00-08:00"), isDateOnly: true))
        #expect(CalendarDateParser.parse("2026-11-03T14:00", calendar: cal)?.date == at("2026-11-03T14:00:00-08:00"))
        #expect(CalendarDateParser.parse("2026-11-03 14:00:30", calendar: cal)?.date == at("2026-11-03T14:00:30-08:00"))
        #expect(CalendarDateParser.parse("2026-11-03T14:00:00.250-05:00", calendar: cal)?.date == at("2026-11-03T14:00:00-05:00"))
        #expect(CalendarDateParser.parse("2026-11-03T22:00:00Z", calendar: cal)?.date == at("2026-11-03T14:00:00-08:00"))
        #expect(CalendarDateParser.parse("2026-07-01T09:00", calendar: cal)?.date == at("2026-07-01T09:00:00-07:00")) // summer time
    }

    @Test(arguments: ["2026-02-30", "2026-13-01", "2026-11-03T24:00", "2026-11-03T10:60", "tomorrow", "11/03/2026", "2026-11-03T10:00+25:00", ""])
    func rejectsWhatIsNotADate(_ text: String) {
        #expect(CalendarDateParser.parse(text, calendar: clock.calendar) == nil)
    }

    @Test func namedRangesFollowTheUsersZoneAndWeek() {
        let cal = clock.calendar
        func range(_ name: CalendarRangeName) -> DateInterval { name.interval(now: now, calendar: cal) }
        #expect(range(.today) == DateInterval(start: at("2026-11-03T00:00:00-08:00"), end: at("2026-11-04T00:00:00-08:00")))
        #expect(range(.restOfToday) == DateInterval(start: now, end: at("2026-11-04T00:00:00-08:00")))
        #expect(range(.tomorrow) == DateInterval(start: at("2026-11-04T00:00:00-08:00"), end: at("2026-11-05T00:00:00-08:00")))
        #expect(range(.thisWeek) == DateInterval(start: at("2026-11-03T00:00:00-08:00"), end: at("2026-11-08T00:00:00-08:00")))
        #expect(range(.nextWeek) == DateInterval(start: at("2026-11-08T00:00:00-08:00"), end: at("2026-11-15T00:00:00-08:00")))
        #expect(range(.next7Days) == DateInterval(start: now, end: at("2026-11-10T10:00:00-08:00")))
        #expect(range(.thisWeekend) == DateInterval(start: at("2026-11-07T00:00:00-08:00"), end: at("2026-11-09T00:00:00-08:00")))
        #expect(range(.thisMonth) == DateInterval(start: at("2026-11-03T00:00:00-08:00"), end: at("2026-12-01T00:00:00-08:00")))
    }

    @Test func formatsWithTheUsersOffsetAndWeekday() {
        #expect(CalendarTimeFormat.timestamp(now, timeZone: losAngeles) == "2026-11-03T10:00:00-08:00")
        #expect(CalendarTimeFormat.day(now, timeZone: losAngeles) == "2026-11-03")
        #expect(CalendarTimeFormat.weekday(now, timeZone: losAngeles) == "Tuesday")
        #expect(CalendarTimeFormat.timestamp(at("2026-11-03T10:00:00+05:30"), timeZone: TimeZone(identifier: "Asia/Kolkata")!)
            == "2026-11-03T10:00:00+05:30")
    }
}

@Suite("calendar_find_events")
struct CalendarFindTests {
    @Test func todayByDefaultSkippingCancelledAndIncludingInProgress() async {
        let result = await rig().toolbox.call(name: "calendar_find_events", arguments: "{}")
        #expect(result.status == .ok)
        #expect(ids(result) == ["standup", "review"])
        #expect(result.details["range"]?["name"] == "today")
        let standup = result.details["events"]?.arrayValue?.first
        #expect(standup?["start"] == "2026-11-03T09:30:00-08:00")
        #expect(standup?["weekday"] == "Tuesday")
        #expect(standup?["starts_in_minutes"] == -30)
        #expect(standup?["meeting_url"] == "https://meet.google.com/abc-defg-hij")
        let review = result.details["events"]?.arrayValue?.last
        #expect(review?["attendees"] == ["Sam Lee"]) // not the user themself
    }

    @Test func namedRangeAndAllDayFilter() async {
        let toolbox = rig().toolbox
        let week = await toolbox.call(name: "calendar_find_events", arguments: #"{"range":"next_week"}"#)
        #expect(ids(week) == ["holiday"])
        let holiday = week.details["events"]?.arrayValue?.first
        #expect(holiday?["all_day"] == true)
        #expect(holiday?["start"] == "2026-11-11")
        #expect(holiday?["end"] == "2026-11-11") // the last day covered, not the midnight after
        let timedOnly = await toolbox.call(name: "calendar_find_events", arguments: #"{"range":"next_week","include_all_day":false}"#)
        #expect(ids(timedOnly).isEmpty)
        #expect(timedOnly.message == "No events in that time range.")
    }

    @Test func queryAloneSearchesTheNextThirtyDays() async {
        let result = await rig().toolbox.call(name: "calendar_find_events", arguments: #"{"query":"the dentist"}"#)
        #expect(ids(result) == ["dentist"])
        #expect(result.details["range"]?["name"] == "next_30_days")
        #expect(result.details["match"] == "all_words")
    }

    @Test func queryMatchesAttendeesAccentsAndFallsBackToPartialMatches() async {
        let toolbox = rig().toolbox
        #expect(ids(await toolbox.call(name: "calendar_find_events", arguments: #"{"query":"sam@example.com","range":"this_week"}"#)) == ["review"])
        #expect(ids(await toolbox.call(name: "calendar_find_events", arguments: #"{"query":"DÉSIGN","range":"this_week"}"#)) == ["review"])
        let partial = await toolbox.call(name: "calendar_find_events", arguments: #"{"query":"hike with Priya","range":"this_week"}"#)
        #expect(ids(partial) == ["hike"])
        #expect(partial.details["match"] == "partial")
    }

    @Test func startEndCalendarAndLimit() async {
        let toolbox = rig().toolbox
        let homeOnly = await toolbox.call(name: "calendar_find_events", arguments: #"{"start":"2026-11-03","end":"2026-11-07","calendar":"home"}"#)
        #expect(ids(homeOnly) == ["dentist", "hike"]) // a plain end date includes that whole day
        let limited = await toolbox.call(name: "calendar_find_events", arguments: #"{"range":"this_week","limit":2}"#)
        #expect(ids(limited) == ["standup", "review"])
        #expect(limited.details["total"] == 4)
        #expect(limited.details["truncated"] == true)
    }

    @Test(arguments: [
        #"{"range":"today","start":"2026-11-03"}"#, #"{"start":"2026-11-05","end":"2026-11-04"}"#, #"{"start":"next tuesday"}"#,
        #"{"range":"fortnight"}"#, #"{"limit":0}"#, #"{"limit":500}"#, #"{"start":"2026-01-01","end":"2027-06-01"}"#,
        #"{"include_all_day":"sometimes"}"#,
    ])
    func invalidArgumentsNeverTouchTheStore(_ arguments: String) async {
        let store = InMemoryCalendarStore(events: sampleEvents)
        let result = await rig(store).toolbox.call(name: "calendar_find_events", arguments: arguments)
        #expect(result.status == .invalidRequest, "\(arguments)")
        #expect(await store.fetchWindows.isEmpty)
        #expect(await store.accessRequests == 0)
    }

    @Test func deniedAccessIsAResultNotACrash() async {
        for state in [CalendarAuthorization.denied, .restricted, .writeOnly] {
            let store = InMemoryCalendarStore(authorization: state, events: sampleEvents)
            let result = await rig(store).toolbox.call(name: "calendar_find_events", arguments: "{}")
            #expect(result.status == .permissionDenied, "\(state)")
            #expect(result.details["permission"] == .string(state.rawValue))
            #expect(result.details["settings_url"] == .string(CalendarService.privacySettingsURL))
            #expect(await store.fetchWindows.isEmpty)
            #expect(await store.accessRequests == 0) // only an undecided state asks
        }
    }

    @Test func undecidedAccessAsksOnceThenReads() async {
        let store = InMemoryCalendarStore(authorization: .notDetermined, stateAfterRequest: .fullAccess, events: sampleEvents)
        let result = await rig(store).toolbox.call(name: "calendar_find_events", arguments: "{}")
        #expect(result.status == .ok)
        #expect(await store.accessRequests == 1)

        let refused = InMemoryCalendarStore(authorization: .notDetermined, stateAfterRequest: .denied)
        #expect(await rig(refused).toolbox.call(name: "calendar_find_events", arguments: "{}").status == .permissionDenied)

        // A process that cannot show the prompt (occtl) stays undecided.
        let cannotAsk = InMemoryCalendarStore(authorization: .notDetermined, stateAfterRequest: .notDetermined)
        let unavailable = await rig(cannotAsk).toolbox.call(name: "calendar_find_events", arguments: "{}")
        #expect(unavailable.status == .unavailable)
    }

    @Test func storeFailuresAreReported() async {
        let store = InMemoryCalendarStore(events: sampleEvents)
        await store.setFetchError(.fetchFailed("disk"))
        let result = await rig(store).toolbox.call(name: "calendar_find_events", arguments: "{}")
        #expect(result.status == .failed)
    }
}

@Suite("calendar_create_event")
struct CalendarCreateTests {
    @Test func withoutConfirmationOnlyADraftIsMade() async throws {
        let store = InMemoryCalendarStore(calendars: [home, work])
        let toolbox = rig(store).toolbox
        let result = await toolbox.call(name: "calendar_create_event",
                                        arguments: #"{"title":"Lunch with Ana","start":"2026-11-05T12:30","location":"Cafe"}"#)
        #expect(result.status == .needsConfirmation)
        #expect(await store.savedDrafts.isEmpty)
        let draft = try #require(result.details["draft"])
        #expect(draft["title"] == "Lunch with Ana")
        #expect(draft["start"] == "2026-11-05T12:30:00-08:00")
        #expect(draft["end"] == "2026-11-05T13:30:00-08:00") // one hour by default
        #expect(draft["weekday"] == "Thursday")
        #expect(draft["calendar"] == "Home")
        #expect(draft["time_zone"] == "America/Los_Angeles")
        #expect(result.details["draft_id"]?.stringValue?.hasPrefix("draft-") == true)
    }

    @Test func confirmingTheDraftSavesItOnce() async throws {
        let store = InMemoryCalendarStore(calendars: [home, work])
        let toolbox = rig(store).toolbox
        let draft = await toolbox.call(name: "calendar_create_event", arguments: #"{"title":"Gym","start":"2026-11-06T07:00","duration_minutes":45}"#)
        let id = try #require(draft.details["draft_id"]?.stringValue)

        let notYet = await toolbox.call(name: "calendar_create_event", arguments: #"{"draft_id":"\#(id)"}"#)
        #expect(notYet.status == .needsConfirmation)
        #expect(await store.savedDrafts.isEmpty)

        let saved = await toolbox.call(name: "calendar_create_event", arguments: #"{"draft_id":"\#(id)","confirmed":true}"#)
        #expect(saved.status == .created)
        #expect(saved.details["event"]?["end"] == "2026-11-06T07:45:00-08:00")
        #expect(await store.savedDrafts.count == 1)

        let again = await toolbox.call(name: "calendar_create_event", arguments: #"{"draft_id":"\#(id)","confirmed":true}"#)
        #expect(again.status == .created) // said to be saved already, and nothing more is added
        #expect(again.details["already_saved"] == true)
        #expect(await store.savedDrafts.count == 1)
    }

    @Test func alreadyApprovedEventsAreSavedDirectly() async {
        let store = InMemoryCalendarStore(calendars: [home, work])
        let result = await rig(store).toolbox.call(name: "calendar_create_event",
                                                   arguments: #"{"title":"Call mom","start":"2026-11-08T18:00","end":"2026-11-08T18:30","confirmed":true,"calendar":"work"}"#)
        #expect(result.status == .created)
        let saved = await store.savedDrafts
        #expect(saved.count == 1)
        #expect(saved.first?.calendar == work)
        #expect(saved.first?.timeZone == losAngeles)
    }

    @Test func allDayEventsCoverWholeDays() async {
        let store = InMemoryCalendarStore(calendars: [home])
        let result = await rig(store).toolbox.call(name: "calendar_create_event",
                                                   arguments: #"{"title":"Trip","start":"2026-12-20","end":"2026-12-22","confirmed":true}"#)
        #expect(result.status == .created)
        let saved = await store.savedDrafts.first
        #expect(saved?.isAllDay == true)
        #expect(saved?.start == at("2026-12-20T00:00:00-08:00"))
        #expect(saved?.end == at("2026-12-23T00:00:00-08:00")) // exclusive: the midnight after the last day
        #expect(result.details["event"]?["end"] == "2026-12-22")
    }

    @Test func unknownCalendarListsTheWritableOnes() async {
        let store = InMemoryCalendarStore(calendars: [home, work, shared])
        let result = await rig(store).toolbox.call(name: "calendar_create_event", arguments: #"{"title":"x","start":"2026-11-05T09:00","calendar":"holidays"}"#)
        #expect(result.status == .invalidRequest)
        #expect(result.details["calendars"] == ["Home", "Work"])
    }

    @Test func expiredDraftsAreNotFound() async {
        let store = InMemoryCalendarStore()
        let result = await rig(store).toolbox.call(name: "calendar_create_event", arguments: #"{"draft_id":"draft-unknown","confirmed":true}"#)
        #expect(result.status == .notFound)
        #expect(await store.savedDrafts.isEmpty)
    }

    @Test func draftsExpireAfterTheirLifetime() async {
        let book = CalendarDraftBook(lifetime: 60, capacity: 2)
        let draft = CalendarEventDraft(title: "x", start: now, end: now.addingTimeInterval(60), timeZone: losAngeles)
        let id = await book.add(draft, now: now)
        #expect(await book.draft(id, now: now.addingTimeInterval(59)) == draft)
        #expect(await book.draft(id, now: now.addingTimeInterval(61)) == nil)
        let a = await book.add(draft, now: now)
        _ = await book.add(draft, now: now.addingTimeInterval(1))
        _ = await book.add(draft, now: now.addingTimeInterval(2))
        #expect(await book.draft(a, now: now.addingTimeInterval(2)) == nil) // the oldest made room
    }

    @Test func writeOnlyAccessCanStillAddToTheDefaultCalendar() async {
        let store = InMemoryCalendarStore(authorization: .writeOnly, calendars: [home, work])
        let result = await rig(store).toolbox.call(name: "calendar_create_event",
                                                   arguments: #"{"title":"x","start":"2026-11-05T09:00","calendar":"work","confirmed":true}"#)
        #expect(result.status == .created)
        #expect(result.details["note"] != nil)
        #expect(await store.savedDrafts.first?.calendar == home)
    }

    @Test func deniedAccessSavesNothing() async {
        let store = InMemoryCalendarStore(authorization: .denied)
        let result = await rig(store).toolbox.call(name: "calendar_create_event", arguments: #"{"title":"x","start":"2026-11-05T09:00","confirmed":true}"#)
        #expect(result.status == .permissionDenied)
        #expect(await store.savedDrafts.isEmpty)
    }

    @Test(arguments: [
        #"{"start":"2026-11-05T09:00"}"#, #"{"title":"x"}"#, #"{"title":"x","start":"2026-11-05T09:00","end":"2026-11-05T08:00"}"#,
        #"{"title":"x","start":"2026-11-05T09:00","end":"2026-11-05T10:00","duration_minutes":30}"#,
        #"{"title":"x","start":"2026-11-05","all_day":false}"#, #"{"title":"x","start":"2026-11-05T09:00","end":"2026-11-30T09:00"}"#,
        #"{"title":"x","start":"1999-11-05T09:00"}"#, #"{"title":"x","start":"2026-11-05T09:00","confirmed":"yes please"}"#,
        #"{"title":"x","start":"2026-11-05T09:00","end":"2026-11-06"}"#,
    ])
    func invalidEventsAreRejectedBeforeAnything(_ arguments: String) async {
        let store = InMemoryCalendarStore()
        let result = await rig(store).toolbox.call(name: "calendar_create_event", arguments: arguments)
        #expect(result.status == .invalidRequest, "\(arguments)")
        #expect(await store.savedDrafts.isEmpty)
        #expect(await store.accessRequests == 0)
    }

    @Test func saveFailuresAreReported() async {
        let store = InMemoryCalendarStore()
        await store.setSaveError(.saveFailed("read-only calendar"))
        let result = await rig(store).toolbox.call(name: "calendar_create_event", arguments: #"{"title":"x","start":"2026-11-05T09:00","confirmed":true}"#)
        #expect(result.status == .failed)
    }
}

@Suite("Meeting countdown")
struct MeetingCountdownTests {
    @Test func nextMeetingWithinTheWindow() {
        let events = [
            event("later", "Later", "2026-11-03T11:00:00-08:00", "2026-11-03T11:30:00-08:00"),
            event("soon", "Soon", "2026-11-03T10:12:00-08:00", "2026-11-03T10:30:00-08:00", location: "https://zoom.us/j/123"),
        ]
        let meeting = MeetingCountdown.next(in: events, now: now, withinMinutes: 15)
        #expect(meeting?.event.id == "soon")
        #expect(meeting?.minutesUntilStart == 12)
        #expect(meeting?.hasStarted == false)
        #expect(meeting?.action == .join(URL(string: "https://zoom.us/j/123")!))
        #expect(MeetingCountdown.next(in: events, now: now, withinMinutes: 5) == nil)
    }

    @Test func skipsAllDayCancelledDeclinedAndFinishedEvents() {
        let declined = [CalendarAttendee(name: "Me", isCurrentUser: true, response: .declined)]
        let events = [
            event("allday", "Holiday", "2026-11-03T00:00:00-08:00", "2026-11-04T00:00:00-08:00", allDay: true),
            event("cancelled", "Cancelled", "2026-11-03T10:05:00-08:00", "2026-11-03T10:30:00-08:00", cancelled: true),
            event("declined", "Declined", "2026-11-03T10:05:00-08:00", "2026-11-03T10:30:00-08:00", attendees: declined),
            event("over", "Over", "2026-11-03T09:00:00-08:00", "2026-11-03T09:58:00-08:00"),
        ]
        #expect(MeetingCountdown.next(in: events, now: now, withinMinutes: 30) == nil)
    }

    @Test func justStartedMeetingsStayForLatecomers() {
        let started = event("started", "Started", "2026-11-03T09:57:00-08:00", "2026-11-03T10:30:00-08:00")
        let meeting = MeetingCountdown.next(in: [started], now: now, withinMinutes: 10)
        #expect(meeting?.hasStarted == true)
        #expect(meeting?.minutesUntilStart == 0)
        let longAgo = event("old", "Old", "2026-11-03T09:00:00-08:00", "2026-11-03T11:00:00-08:00")
        #expect(MeetingCountdown.next(in: [longAgo], now: now, withinMinutes: 10) == nil)
    }

    @Test func aCallLinkWinsATie() {
        let events = [
            event("room", "A room", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", location: "Room 4"),
            event("call", "B call", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", notes: "Join: https://acme.zoom.us/j/9."),
        ]
        let meeting = MeetingCountdown.next(in: events, now: now, withinMinutes: 15)
        #expect(meeting?.event.id == "call")
        #expect(meeting?.action == .join(URL(string: "https://acme.zoom.us/j/9")!))
    }

    @Test func actionsJoinThenDirectionsThenOpen() {
        let place = event("p", "Coffee", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", location: "Blue Bottle, 1 Ferry Building")
        #expect(MeetingCountdown.primaryAction(for: place)?.kind == "directions")
        #expect(MeetingCountdown.primaryAction(for: place)?.url.absoluteString == "https://maps.apple.com/?daddr=Blue%20Bottle,%201%20Ferry%20Building")

        let virtualPlace = event("v", "Sync", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", location: "Microsoft Teams Meeting")
        #expect(MeetingCountdown.primaryAction(for: virtualPlace) == nil)

        let linked = event("l", "Doc", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", url: URL(string: "https://calendar.example.com/e/1"))
        #expect(MeetingCountdown.primaryAction(for: linked) == .open(URL(string: "https://calendar.example.com/e/1")!))

        let teams = event("t", "T", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00", url: URL(string: "https://teams.microsoft.com/l/meetup-join/x"))
        #expect(MeetingCountdown.primaryAction(for: teams)?.kind == "join")
    }

    @Test func meetingLinkDetection() {
        #expect(MeetingLinkDetector.isMeetingLink(URL(string: "https://us02web.zoom.us/j/1")!))
        #expect(!MeetingLinkDetector.isMeetingLink(URL(string: "https://notzoom.us/j/1")!))
        #expect(!MeetingLinkDetector.isMeetingLink(URL(string: "zoommtg://zoom.us/join")!))
        #expect(MeetingLinkDetector.links(in: "See (https://a.com/x), then https://b.com/y.").map(\.absoluteString) == ["https://a.com/x", "https://b.com/y"])
    }

    @Test func serviceNeverAsksForPermissionOnATimer() async {
        let undecided = InMemoryCalendarStore(authorization: .notDetermined)
        let service = CalendarService(store: undecided, clock: clock)
        #expect(await service.upcomingMeeting(withinMinutes: 15) == .noAccess(.notDetermined))
        #expect(await undecided.accessRequests == 0)

        let store = InMemoryCalendarStore(events: sampleEvents + [
            event("next", "1:1", "2026-11-03T10:10:00-08:00", "2026-11-03T10:40:00-08:00"),
        ])
        let live = CalendarService(store: store, clock: clock)
        guard case .upcoming(let meeting) = await live.upcomingMeeting(withinMinutes: 15) else {
            Issue.record("expected a meeting"); return
        }
        #expect(meeting.event.id == "next") // the standup started 30 minutes ago, past the grace period
        #expect(await CalendarService(store: InMemoryCalendarStore(), clock: clock).upcomingMeeting(withinMinutes: 15) == .nothingSoon)
    }
}

@Suite("EventKit mapping")
struct EventKitMappingTests {
    @Test func authorizationStatesMap() {
        #expect(EventKitCalendarStore.map(.fullAccess) == .fullAccess)
        #expect(EventKitCalendarStore.map(.writeOnly) == .writeOnly)
        #expect(EventKitCalendarStore.map(.denied) == .denied)
        #expect(EventKitCalendarStore.map(.restricted) == .restricted)
        #expect(EventKitCalendarStore.map(.notDetermined) == .notDetermined)
    }

    @Test func aProcessWithoutAUsageDescriptionNeverAsks() async {
        // The test runner has no NSCalendarsFullAccessUsageDescription, so asking would terminate it; the store must
        // return the current state instead. (Reads the real authorization state; shows no prompt.)
        let store = EventKitCalendarStore()
        let before = await store.authorization()
        #expect(await store.requestFullAccess() == before)
    }
}
