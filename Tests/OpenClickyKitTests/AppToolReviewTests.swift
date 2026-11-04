import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests for problems found in review: a draft id sent with changed details, two confirmations of one
// draft, cancellation by a newer turn, the Spotify market code and the clock's time zone.

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let now: Date = {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: "2026-11-03T10:00:00-08:00")!
}()
private let fixedClock = CalendarClock(now: { now }, timeZone: losAngeles, firstWeekday: 1)
private let home = CalendarInfo(id: "cal-home", title: "Home")
private let work = CalendarInfo(id: "cal-work", title: "Work")

private func toolbox(_ store: some CalendarStore, clock: CalendarClock = fixedClock) -> AppToolbox {
    AppToolbox.standard(AppToolEnvironment(workspace: RecordingWorkspace(), pasteboard: RecordingPasteboard(),
                                           appleScript: ScriptedAppleScriptRunner(), calendar: store,
                                           homeDirectory: URL(fileURLWithPath: "/Users/tester"), clock: clock, sleep: { _ in }))
}

private func create(_ toolbox: AppToolbox, _ arguments: String) async -> AppToolResult {
    await toolbox.call(name: "calendar_create_event", arguments: arguments)
}

@Suite("calendar_create_event drafts under review")
struct CalendarDraftReviewTests {
    @Test func changedDetailsSentWithADraftIDAreNeverSaved() async throws {
        let store = InMemoryCalendarStore(calendars: [home, work])
        let tools = toolbox(store)
        let first = await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00","duration_minutes":45}"#)
        let oldID = try #require(first.details["draft_id"]?.stringValue)

        // The user said "make it 8 instead" and the model sent the old draft id with the new time and confirmed.
        let changed = await create(tools, #"{"draft_id":"\#(oldID)","confirmed":true,"title":"Gym","start":"2026-11-06T08:00","duration_minutes":45}"#)
        #expect(changed.status == .needsConfirmation)
        #expect(await store.savedDrafts.isEmpty, "the 7:00 draft the user did not approve was saved")
        let newID = try #require(changed.details["draft_id"]?.stringValue)
        #expect(newID != oldID)
        #expect(changed.details["replaces_draft_id"]?.stringValue == oldID)
        #expect(changed.details["draft"]?["start"] == "2026-11-06T08:00:00-08:00")

        // The replaced draft can no longer be saved; the new one can.
        #expect(await create(tools, #"{"draft_id":"\#(oldID)","confirmed":true}"#).status == .notFound)
        let saved = await create(tools, #"{"draft_id":"\#(newID)","confirmed":true}"#)
        #expect(saved.status == .created)
        #expect(await store.savedDrafts.map(\.start) == [ISO8601DateFormatter().date(from: "2026-11-06T08:00:00-08:00")!])
    }

    @Test func echoedDetailsSentWithADraftIDSaveTheApprovedDraft() async throws {
        let store = InMemoryCalendarStore(calendars: [home, work])
        let tools = toolbox(store)
        let first = await create(tools, #"{"title":"Lunch with Ana","start":"2026-11-05T12:30","location":"Cafe"}"#)
        let id = try #require(first.details["draft_id"]?.stringValue)
        let draft = try #require(first.details["draft"])
        let start = try #require(draft["start"]?.stringValue), end = try #require(draft["end"]?.stringValue)

        // Echoing the draft back as it was read (its own timestamps and calendar name) saves that draft.
        let echo = #"{"draft_id":"\#(id)","confirmed":true,"title":"Lunch with Ana","start":"\#(start)","end":"\#(end)","location":"Cafe","calendar":"Home"}"#
        let saved = await create(tools, echo)
        #expect(saved.status == .created)
        #expect(await store.savedDrafts.count == 1)
    }

    @Test func blankDetailsWithADraftIDCountAsAbsent() async throws {
        let store = InMemoryCalendarStore(calendars: [home])
        let tools = toolbox(store)
        let id = try #require(await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00"}"#).details["draft_id"]?.stringValue)
        let saved = await create(tools, #"{"draft_id":"\#(id)","confirmed":true,"location":"","notes":null}"#)
        #expect(saved.status == .created)
        #expect(await store.savedDrafts.count == 1)
    }

    @Test func partialDetailsWithADraftIDAreTurnedAway() async throws {
        let store = InMemoryCalendarStore(calendars: [home])
        let tools = toolbox(store)
        let id = try #require(await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00"}"#).details["draft_id"]?.stringValue)
        let result = await create(tools, #"{"draft_id":"\#(id)","confirmed":true,"start":"2026-11-06T09:00"}"#)
        #expect(result.status == .invalidRequest)
        #expect(result.message?.contains("send only draft_id") == true)
        #expect(await store.savedDrafts.isEmpty)
    }

    @Test func aRepeatedConfirmationSaysSavedAndAddsNothing() async throws {
        let store = InMemoryCalendarStore(calendars: [home])
        let tools = toolbox(store)
        let id = try #require(await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00"}"#).details["draft_id"]?.stringValue)
        #expect(await create(tools, #"{"draft_id":"\#(id)","confirmed":true}"#).status == .created)
        let again = await create(tools, #"{"draft_id":"\#(id)","confirmed":true}"#)
        #expect(again.status == .created)
        #expect(again.details["already_saved"] == true)
        #expect(await store.savedDrafts.count == 1)
    }

    @Test func twoConfirmationsInFlightSaveTheDraftOnce() async throws {
        let inner = InMemoryCalendarStore(calendars: [home])
        let store = GatedSaveStore(inner)
        let tools = toolbox(store)
        let id = try #require(await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00"}"#).details["draft_id"]?.stringValue)
        let confirm = #"{"draft_id":"\#(id)","confirmed":true}"#

        let first = Task { await create(tools, confirm) }
        #expect(await store.waitForSaves(1))
        // The first save is held. A second confirmation now must be answered without reaching the store; one that
        // wrongly waits on the store shows up as a second save once the store lets go.
        let secondAnswered = LockedFlag()
        let second = Task {
            let result = await create(tools, confirm)
            secondAnswered.set()
            return result
        }
        #expect(await waitUntil { secondAnswered.isSet }, "the second confirmation waited on the first save")
        await store.release()
        let results = [await first.value, await second.value]

        #expect(await store.saveCalls == 1)
        #expect(await inner.savedDrafts.count == 1)
        #expect(results[0].status == .created)
        #expect(results[1].status == .invalidRequest)
    }

    @Test func aFailedSaveLeavesTheDraftToTryAgain() async throws {
        let store = InMemoryCalendarStore(calendars: [home])
        let tools = toolbox(store)
        let id = try #require(await create(tools, #"{"title":"Gym","start":"2026-11-06T07:00"}"#).details["draft_id"]?.stringValue)
        await store.setSaveError(.saveFailed("busy"))
        #expect(await create(tools, #"{"draft_id":"\#(id)","confirmed":true}"#).status == .failed)
        await store.setSaveError(nil)
        #expect(await create(tools, #"{"draft_id":"\#(id)","confirmed":true}"#).status == .created)
        #expect(await store.savedDrafts.count == 1)
    }

    @Test func draftBookClaimsOnce() async {
        let book = CalendarDraftBook()
        let draft = CalendarEventDraft(title: "x", start: now, end: now.addingTimeInterval(60), timeZone: losAngeles)
        let id = await book.add(draft, now: now)
        #expect(await book.claim(id, now: now) == .waiting(draft))
        #expect(await book.claim(id, now: now) == .beingSaved(draft))
        await book.finishSaving(id, saved: false, now: now)
        #expect(await book.state(id, now: now) == .waiting(draft))
        #expect(await book.claim(id, now: now) == .waiting(draft))
        await book.finishSaving(id, saved: true, now: now)
        #expect(await book.claim(id, now: now) == .saved(draft))
        #expect(await book.state(id, now: now.addingTimeInterval(31 * 60)) == .missing)
    }
}

@Suite("Calendar time zone under review")
struct CalendarZoneReviewTests {
    @Test func theDefaultClockFollowsTheMacsZone() {
        // A fixed snapshot (TimeZone.current) would keep the old zone for the whole app session after the user travels.
        #expect(CalendarClock().calendar.timeZone == TimeZone.autoupdatingCurrent)
        #expect(AppToolEnvironment(workspace: RecordingWorkspace(), pasteboard: RecordingPasteboard(),
                                   appleScript: ScriptedAppleScriptRunner(), calendar: InMemoryCalendarStore())
            .clock.timeZone == TimeZone.autoupdatingCurrent)
    }

    @Test func savedEventsGetAFixedZone() async {
        let store = InMemoryCalendarStore(calendars: [home])
        let clock = CalendarClock(now: { now })
        let result = await create(toolbox(store, clock: clock), #"{"title":"x","start":"2026-11-05T09:00","confirmed":true}"#)
        #expect(result.status == .created)
        let zone = await store.savedDrafts.first?.timeZone
        #expect(zone?.identifier == TimeZone.autoupdatingCurrent.identifier)
        #expect(zone != TimeZone.autoupdatingCurrent)
    }
}

@Suite("Cancellation by a newer turn")
struct AppToolCancellationTests {
    @Test func aCancelledDeferredActionRunsNothing() async {
        let workspace = RecordingWorkspace()
        let tools = AppToolbox.standard(AppToolEnvironment(workspace: workspace, pasteboard: RecordingPasteboard(),
                                                           appleScript: ScriptedAppleScriptRunner(), calendar: InMemoryCalendarStore(),
                                                           sleep: { _ in }))
        let action = DeferredAction(callID: "c", name: "open_url", arguments: ["url": "https://example.com"])
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await tools.run(action)
        }.value
        #expect(result.status == .cancelled)
        #expect(!result.succeeded)
        #expect(workspace.events.isEmpty)
    }

    @Test func cancellingWhileSpotifyIsAskedStartsNothingMore() async throws {
        let workspace = RecordingWorkspace(running: [AppBundleID.spotify])
        let scripts = ScriptedAppleScriptRunner { source, _ in
            if source.contains("play track") {
                // The user starts a new turn while Spotify is being told to play.
                withUnsafeCurrentTask { $0?.cancel() }
                return ""
            }
            return "paused"
        }
        let player = MusicPlayer(workspace: workspace, scripts: scripts, sleep: { _ in })
        let uri = try #require(SpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        let result = await Task { await player.play(MusicPlayRequest(uri: uri)) }.value
        #expect(result.status == .cancelled)
        #expect(workspace.events.isEmpty, "the spotify: URI was opened after the turn was cancelled")
    }

    @Test func cancellationStopsTheSpotifySearchFallback() async {
        let workspace = RecordingWorkspace(running: [AppBundleID.spotify])
        let player = MusicPlayer(workspace: workspace, scripts: ScriptedAppleScriptRunner(), sleep: { _ in })
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await player.play(MusicPlayRequest(query: "Hey Jude"))
        }.value
        #expect(result.status == .cancelled)
        #expect(workspace.events.isEmpty)
    }
}

@Suite("reveal_in_finder dispatch under review")
struct RevealDispatchReviewTests {
    @Test func aMissingItemIsAnsweredAtOnceNotQueuedAsRevealed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oc-review-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("hi".utf8).write(to: home.appendingPathComponent("Documents/notes.txt"))
        let workspace = RecordingWorkspace()
        let tools = AppToolbox.standard(AppToolEnvironment(workspace: workspace, pasteboard: RecordingPasteboard(),
                                                           appleScript: ScriptedAppleScriptRunner(), calendar: InMemoryCalendarStore(),
                                                           homeDirectory: home, sleep: { _ in }))

        guard case .finished(let missing) = tools.prepare(ToolCall(id: "a", name: "reveal_in_finder", arguments: #"{"path":"~/Documents/nope.txt"}"#))
        else { Issue.record("a missing item was queued; the model would be told it was revealed"); return }
        #expect(missing.status == .notFound)

        guard case .deferUntilNarrationEnds(_, let queued) = tools.prepare(ToolCall(id: "b", name: "reveal_in_finder",
                                                                                    arguments: #"{"path":"~/Documents/notes.txt"}"#))
        else { Issue.record("an existing item was not queued"); return }
        #expect(queued.status == .revealed)
        #expect(workspace.events.isEmpty)
    }
}

@Suite("Spotify market under review")
struct SpotifyMarketReviewTests {
    @Test(arguments: [("419", "US"), ("001", "US"), (nil, "US"), ("", "US"), ("gb", "GB"), ("DE", "DE"), ("USA", "US")] as [(String?, String)])
    func marketIsATwoLetterCountry(_ region: String?, _ expected: String) {
        #expect(SpotifyWebAPICatalog.marketCode(region) == expected)
    }

    @Test func searchRequestsNeverSendAnAreaCode() throws {
        let catalog = SpotifyWebAPICatalog(clientID: "id", clientSecret: "secret", market: "419")
        let request = catalog.searchRequest(SpotifySearchQuery(text: "Hey Jude"), token: "t")
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "market" }?.value == "US")
    }
}

/// A calendar store whose saves wait until released, so a test can line up two confirmations at once.
private actor GatedSaveStore: CalendarStore {
    let inner: InMemoryCalendarStore
    private(set) var saveCalls = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ inner: InMemoryCalendarStore) { self.inner = inner }

    func release() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// Waits until `count` saves have started; false on timeout (a hang guard; a busy machine can be slow).
    func waitForSaves(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while saveCalls < count {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func authorization() async -> CalendarAuthorization { await inner.authorization() }
    func requestFullAccess() async -> CalendarAuthorization { await inner.requestFullAccess() }
    func calendars() async -> [CalendarInfo] { await inner.calendars() }
    func defaultCalendar() async -> CalendarInfo? { await inner.defaultCalendar() }
    func events(from start: Date, to end: Date) async throws -> [CalendarEventRecord] { try await inner.events(from: start, to: end) }

    func save(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        saveCalls += 1
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return try await inner.save(draft)
    }
}
