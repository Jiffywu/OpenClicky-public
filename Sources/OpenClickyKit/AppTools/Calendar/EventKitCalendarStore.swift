import EventKit
import Foundation

/// The user's calendars through EventKit (every account in Calendar.app: iCloud, Google, Exchange, local).
///
/// Permission rules this follows so it never crashes or hangs:
/// - macOS terminates an app that requests calendar access without an `NSCalendarsFullAccessUsageDescription`
///   in its Info.plist. `requestFullAccess()` checks for the key first and, without it, returns the current
///   state instead of asking (this is the case for the `occtl` command-line tool).
/// - Reads and writes check the authorization first and throw `CalendarStoreError.accessDenied` rather than
///   touching the store without permission.
/// - The `EKEventStore` is created lazily and only used on one serial queue.
public final class EventKitCalendarStore: CalendarStore, @unchecked Sendable {
    public static let fullAccessUsageKey = "NSCalendarsFullAccessUsageDescription"

    private let queue = DispatchQueue(label: "com.openclicky.app-tools.eventkit")
    private var storage: EKEventStore?
    private let canAskForAccess: Bool

    /// - Parameter canAskForAccess: Whether this process may show the calendar permission prompt. Defaults to
    ///   whether the main bundle declares the usage description.
    public init(canAskForAccess: Bool = Bundle.main.object(forInfoDictionaryKey: EventKitCalendarStore.fullAccessUsageKey) != nil) {
        self.canAskForAccess = canAskForAccess
    }

    /// Call only on `queue`.
    private var store: EKEventStore {
        if let storage { return storage }
        let created = EKEventStore()
        storage = created
        return created
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    public func authorization() async -> CalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestFullAccess() async -> CalendarAuthorization {
        let current = await authorization()
        guard current == .notDetermined, canAskForAccess else { return current }
        let store: EKEventStore? = try? await onQueue { [self] in UncheckedBox(self.store) }.value
        guard let store else { return current }
        let _: Bool = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
        return await authorization()
    }

    public func calendars() async -> [CalendarInfo] {
        guard await authorization().canRead else { return [] }
        return (try? await onQueue { [self] in self.store.calendars(for: .event).map(Self.info) }) ?? []
    }

    public func defaultCalendar() async -> CalendarInfo? {
        guard await authorization().canWrite else { return nil }
        return try? await onQueue { [self] in self.store.defaultCalendarForNewEvents.map(Self.info) }
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEventRecord] {
        guard await authorization().canRead else { throw CalendarStoreError.accessDenied }
        return try await onQueue { [self] in
            let predicate = self.store.predicateForEvents(withStart: start, end: end, calendars: nil)
            return self.store.events(matching: predicate).map(Self.record)
        }
    }

    public func save(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        guard await authorization().canWrite else { throw CalendarStoreError.accessDenied }
        return try await onQueue { [self] in
            let store = self.store
            let event = EKEvent(eventStore: store)
            event.title = draft.title
            event.isAllDay = draft.isAllDay
            event.timeZone = draft.isAllDay ? nil : draft.timeZone
            event.startDate = draft.start
            // EventKit treats an all-day event's end as the last day it covers, not the midnight after it.
            event.endDate = draft.isAllDay ? draft.end.addingTimeInterval(-1) : draft.end
            event.location = draft.location
            event.notes = draft.notes
            let target = draft.calendar.flatMap { store.calendar(withIdentifier: $0.id) } ?? store.defaultCalendarForNewEvents
            guard let target else { throw CalendarStoreError.noWritableCalendar }
            event.calendar = target
            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarStoreError.saveFailed(error.localizedDescription)
            }
            var saved = Self.record(event)
            saved.end = draft.end
            return saved
        }
    }

    // MARK: Mapping

    static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorization {
        switch status {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        default: .fullAccess // `.authorized`, the pre-macOS 14 spelling of full access.
        }
    }

    static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, isWritable: calendar.allowsContentModifications,
                     source: calendar.source?.title)
    }

    static func record(_ event: EKEvent) -> CalendarEventRecord {
        let attendees = (event.attendees ?? []).map { participant in
            CalendarAttendee(
                name: participant.name,
                email: participant.url.absoluteString.lowercased().hasPrefix("mailto:")
                    ? String(participant.url.absoluteString.dropFirst("mailto:".count)) : nil,
                isCurrentUser: participant.isCurrentUser,
                response: response(participant.participantStatus))
        }
        let identifier: String? = event.eventIdentifier
        return CalendarEventRecord(
            id: identifier ?? event.calendarItemIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url,
            calendar: event.calendar.map(info),
            attendees: attendees,
            isCancelled: event.status == .canceled)
    }

    static func response(_ status: EKParticipantStatus) -> CalendarAttendee.Response {
        switch status {
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        default: .unknown
        }
    }
}

/// Carries a non-Sendable EventKit object out of the serial queue for one call that EventKit documents as
/// thread-safe (`requestFullAccessToEvents`).
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
