import Foundation

/// What macOS lets OpenClicky do with the user's calendars.
public enum CalendarAuthorization: String, Sendable, Hashable, CaseIterable {
    case fullAccess = "full_access"
    /// Can add events but not read any (macOS 14's write-only grant).
    case writeOnly = "write_only"
    case denied
    /// Blocked by a device profile or parental controls; the user cannot change it.
    case restricted
    case notDetermined = "not_determined"

    public var canRead: Bool { self == .fullAccess }
    public var canWrite: Bool { self == .fullAccess || self == .writeOnly }
}

public struct CalendarInfo: Sendable, Hashable {
    public var id: String
    public var title: String
    public var isWritable: Bool
    /// The account it belongs to ("iCloud", "Google", "On My Mac"…).
    public var source: String?

    public init(id: String, title: String, isWritable: Bool = true, source: String? = nil) {
        self.id = id
        self.title = title
        self.isWritable = isWritable
        self.source = source
    }
}

public struct CalendarAttendee: Sendable, Hashable {
    public enum Response: String, Sendable, Hashable { case accepted, declined, tentative, pending, unknown }

    public var name: String?
    public var email: String?
    public var isCurrentUser: Bool
    public var response: Response

    public init(name: String?, email: String? = nil, isCurrentUser: Bool = false, response: Response = .unknown) {
        self.name = name
        self.email = email
        self.isCurrentUser = isCurrentUser
        self.response = response
    }
}

/// One event as the tools see it, independent of EventKit.
public struct CalendarEventRecord: Sendable, Hashable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var url: URL?
    public var calendar: CalendarInfo?
    public var attendees: [CalendarAttendee]
    public var isCancelled: Bool

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
                notes: String? = nil, url: URL? = nil, calendar: CalendarInfo? = nil, attendees: [CalendarAttendee] = [],
                isCancelled: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.calendar = calendar
        self.attendees = attendees
        self.isCancelled = isCancelled
    }

    /// The user said no to this invitation.
    public var declinedByMe: Bool { attendees.contains { $0.isCurrentUser && $0.response == .declined } }
}

/// An event to create. `end` is exclusive; all-day events start and end at midnight in `timeZone`.
public struct CalendarEventDraft: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    /// Nil: the user's default calendar for new events.
    public var calendar: CalendarInfo?
    public var timeZone: TimeZone

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
                calendar: CalendarInfo? = nil, timeZone: TimeZone) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.calendar = calendar
        self.timeZone = timeZone
    }
}

public enum CalendarStoreError: Error, Sendable, Hashable, CustomStringConvertible {
    case accessDenied
    case noWritableCalendar
    case saveFailed(String)
    case fetchFailed(String)

    public var description: String {
        switch self {
        case .accessDenied: "Calendar access is not allowed."
        case .noWritableCalendar: "There is no calendar that can take new events."
        case .saveFailed(let reason): "Saving the event failed: \(reason)"
        case .fetchFailed(let reason): "Reading the calendar failed: \(reason)"
        }
    }
}

/// The user's calendars. Production: `EventKitCalendarStore`. Tests: `InMemoryCalendarStore`.
public protocol CalendarStore: Sendable {
    func authorization() async -> CalendarAuthorization
    /// Asks macOS for full access when it has not been decided. Returns the state afterwards. Must not crash when
    /// the process cannot ask (no usage description); it then returns the current state.
    func requestFullAccess() async -> CalendarAuthorization
    /// Every event calendar, writable or not. Empty without full access.
    func calendars() async -> [CalendarInfo]
    func defaultCalendar() async -> CalendarInfo?
    /// Events overlapping `start..<end`, including all-day and cancelled ones; callers filter.
    func events(from start: Date, to end: Date) async throws -> [CalendarEventRecord]
    func save(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord
}
