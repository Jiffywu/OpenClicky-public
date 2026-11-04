import Foundation

/// Where one calendar draft stands.
public enum CalendarDraftState: Sendable, Hashable {
    /// Waiting for the user's yes.
    case waiting(CalendarEventDraft)
    /// Another call has claimed it and is saving it now.
    case beingSaved(CalendarEventDraft)
    /// Saved already (remembered for the draft lifetime, so a repeated confirmation does not add it twice).
    case saved(CalendarEventDraft)
    /// Never made, or expired.
    case missing

    public var draft: CalendarEventDraft? {
        switch self {
        case .waiting(let draft), .beingSaved(let draft), .saved(let draft): draft
        case .missing: nil
        }
    }
}

/// Drafts made by `calendar_create_event` that wait for the user's yes. Kept for `lifetime`, at most `capacity`.
///
/// Saving goes through `claim` and `finishSaving`, so two confirmations of the same draft (a model that repeats a
/// call, or sends two at once) save it once: the second sees `beingSaved` or `saved` instead of the draft.
public actor CalendarDraftBook {
    private var drafts: [String: (draft: CalendarEventDraft, made: Date)] = [:]
    private var saving: [String: (draft: CalendarEventDraft, made: Date)] = [:]
    private var saved: [String: (draft: CalendarEventDraft, made: Date)] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int

    public init(lifetime: TimeInterval = 30 * 60, capacity: Int = 20) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public func add(_ draft: CalendarEventDraft, now: Date) -> String {
        prune(now: now)
        if drafts.count >= capacity, let oldest = drafts.min(by: { $0.value.made < $1.value.made })?.key {
            drafts.removeValue(forKey: oldest)
        }
        let id = "draft-" + UUID().uuidString.prefix(8).lowercased()
        drafts[id] = (draft, now)
        return id
    }

    /// The draft while it waits for the user's yes.
    public func draft(_ id: String, now: Date) -> CalendarEventDraft? {
        prune(now: now)
        return drafts[id]?.draft
    }

    public func state(_ id: String, now: Date) -> CalendarDraftState {
        prune(now: now)
        if let entry = drafts[id] { return .waiting(entry.draft) }
        if let entry = saving[id] { return .beingSaved(entry.draft) }
        if let entry = saved[id] { return .saved(entry.draft) }
        return .missing
    }

    /// Takes a waiting draft for saving. Returns `.waiting(draft)` to the one caller that got it; every other caller
    /// sees `beingSaved`, `saved` or `missing`. Follow with `finishSaving`.
    public func claim(_ id: String, now: Date) -> CalendarDraftState {
        let current = state(id, now: now)
        if case .waiting = current, let entry = drafts.removeValue(forKey: id) { saving[id] = entry }
        return current
    }

    /// Ends a claim: remembered as saved, or put back to wait for another try.
    public func finishSaving(_ id: String, saved didSave: Bool, now: Date) {
        guard let entry = saving.removeValue(forKey: id) else { return }
        if didSave { saved[id] = (entry.draft, now) } else { drafts[id] = entry }
    }

    public func remove(_ id: String) { drafts.removeValue(forKey: id) }

    private func prune(now: Date) {
        drafts = drafts.filter { now.timeIntervalSince($0.value.made) < lifetime }
        saved = saved.filter { now.timeIntervalSince($0.value.made) < lifetime }
    }
}

/// Calendar lookups, event creation with confirmation, and the meeting countdown, on top of a `CalendarStore`.
public struct CalendarService: Sendable {
    public let store: any CalendarStore
    public let clock: CalendarClock
    public let drafts: CalendarDraftBook

    public static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    public init(store: any CalendarStore, clock: CalendarClock = CalendarClock(), drafts: CalendarDraftBook = CalendarDraftBook()) {
        self.store = store
        self.clock = clock
        self.drafts = drafts
    }

    var timeZone: TimeZone { clock.timeZone }

    /// The zone right now as a fixed value, for events saved to the calendar (the clock's zone may follow the Mac's
    /// setting as it changes).
    var fixedTimeZone: TimeZone { TimeZone(identifier: clock.timeZone.identifier) ?? clock.timeZone }

    // MARK: Access

    /// The current authorization, asking macOS once if it was never decided. Nil when the needed access is there;
    /// otherwise the result to hand back to the model.
    func ensureAccess(toRead: Bool) async -> AppToolResult? {
        var state = await store.authorization()
        if state == .notDetermined { state = await store.requestFullAccess() }
        if toRead ? state.canRead : state.canWrite { return nil }
        return Self.accessProblem(state)
    }

    static func accessProblem(_ state: CalendarAuthorization) -> AppToolResult {
        let details: [String: JSONValue] = ["permission": .string(state.rawValue), "settings_url": .string(privacySettingsURL)]
        switch state {
        case .writeOnly:
            return AppToolResult(.permissionDenied, """
                OpenClicky may add events but not read the calendar. The user can allow full access in System \
                Settings > Privacy & Security > Calendars.
                """, details: details)
        case .denied:
            return AppToolResult(.permissionDenied, """
                Calendar access is off for OpenClicky. The user can turn it on in System Settings > Privacy & \
                Security > Calendars.
                """, details: details)
        case .restricted:
            return AppToolResult(.permissionDenied, "Calendar access is blocked on this Mac by a device policy.", details: details)
        case .notDetermined:
            return AppToolResult(.unavailable, """
                OpenClicky has not been given calendar access yet and cannot ask from here. Open the OpenClicky app \
                and allow Calendars.
                """, details: details)
        case .fullAccess:
            return AppToolResult(.failed, "Calendar access looked fine but the request still failed.", details: details)
        }
    }

    // MARK: Countdown

    /// The meeting for the notch countdown. Never asks for permission (it runs on a timer).
    public func upcomingMeeting(withinMinutes minutes: Int, inProgressGrace: TimeInterval = 5 * 60) async -> MeetingCountdownState {
        let state = await store.authorization()
        guard state.canRead else { return .noAccess(state) }
        let now = clock.now()
        let events = (try? await store.events(from: now.addingTimeInterval(-inProgressGrace),
                                              to: now.addingTimeInterval(TimeInterval(minutes) * 60))) ?? []
        guard let next = MeetingCountdown.next(in: events, now: now, withinMinutes: minutes, inProgressGrace: inProgressGrace)
        else { return .nothingSoon }
        return .upcoming(next)
    }

    // MARK: JSON for the model

    func json(_ event: CalendarEventRecord, now: Date) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(event.id),
            "title": .string(event.title.isEmpty ? "(no title)" : event.title),
            "all_day": .bool(event.isAllDay),
            "weekday": .string(CalendarTimeFormat.weekday(event.start, timeZone: timeZone)),
        ]
        if event.isAllDay {
            object["start"] = .string(CalendarTimeFormat.day(event.start, timeZone: timeZone))
            // Show the last day covered, not the midnight after it.
            let lastDay = event.end.addingTimeInterval(-1)
            object["end"] = .string(CalendarTimeFormat.day(max(lastDay, event.start), timeZone: timeZone))
        } else {
            object["start"] = .string(CalendarTimeFormat.timestamp(event.start, timeZone: timeZone))
            object["end"] = .string(CalendarTimeFormat.timestamp(event.end, timeZone: timeZone))
            let minutes = event.start.timeIntervalSince(now) / 60
            if minutes > -24 * 60, minutes < 24 * 60 { object["starts_in_minutes"] = .number(minutes.rounded()) }
        }
        if let location = event.location, !location.isEmpty { object["location"] = .string(location) }
        if let calendar = event.calendar { object["calendar"] = .string(calendar.title) }
        if let link = MeetingLinkDetector.meetingURL(in: event) { object["meeting_url"] = .string(link.absoluteString) }
        let others = event.attendees.filter { !$0.isCurrentUser }.compactMap { $0.name ?? $0.email }
        if !others.isEmpty { object["attendees"] = .array(others.prefix(12).map { .string($0) }) }
        if event.declinedByMe { object["declined"] = true }
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            object["notes"] = .string(notes.count > 280 ? String(notes.prefix(280)) + "…" : notes)
        }
        return .object(object)
    }

    func json(_ draft: CalendarEventDraft) -> JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(draft.title),
            "all_day": .bool(draft.isAllDay),
            "weekday": .string(CalendarTimeFormat.weekday(draft.start, timeZone: timeZone)),
            "time_zone": .string(timeZone.identifier),
            "calendar": .string(draft.calendar?.title ?? "default calendar"),
        ]
        if draft.isAllDay {
            object["start"] = .string(CalendarTimeFormat.day(draft.start, timeZone: timeZone))
            object["end"] = .string(CalendarTimeFormat.day(draft.end.addingTimeInterval(-1), timeZone: timeZone))
        } else {
            object["start"] = .string(CalendarTimeFormat.timestamp(draft.start, timeZone: timeZone))
            object["end"] = .string(CalendarTimeFormat.timestamp(draft.end, timeZone: timeZone))
        }
        if let location = draft.location { object["location"] = .string(location) }
        if let notes = draft.notes { object["notes"] = .string(notes) }
        if draft.start < clock.now() { object["starts_in_past"] = true }
        return .object(object)
    }
}
