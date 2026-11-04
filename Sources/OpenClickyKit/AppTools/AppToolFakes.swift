import Foundation

// Scripted stand-ins for the parts of macOS the app tools touch. Tests use them so nothing opens, plays, copies or
// asks for a permission; `occtl tools call --dry-run` uses them to show what a call would do without doing it.

/// Records every URL it is asked to open or reveal and answers from fixed settings.
public final class RecordingWorkspace: AppToolWorkspace, @unchecked Sendable {
    public enum Event: Sendable, Hashable {
        case openInBrowser(URL)
        case open(URL)
        case reveal(URL)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var installed: Set<String>
    private var running: Set<String>
    private let succeeds: Bool
    private let launchesOnOpen: Bool

    /// - Parameters:
    ///   - installed: bundle ids that count as installed.
    ///   - running: bundle ids that count as running.
    ///   - succeeds: what every open and reveal returns.
    ///   - launchesOnOpen: opening a `spotify:` URL marks Spotify as running, the way the real app cold-starts.
    public init(installed: Set<String> = [AppBundleID.spotify, AppBundleID.music], running: Set<String> = [],
                succeeds: Bool = true, launchesOnOpen: Bool = true) {
        self.installed = installed
        self.running = running
        self.succeeds = succeeds
        self.launchesOnOpen = launchesOnOpen
    }

    public var events: [Event] { lock.withLock { recorded } }

    /// Synchronous `isRunning`, for scripted responders.
    public func isRunningNow(_ bundleID: String) -> Bool { lock.withLock { running.contains(bundleID) } }

    public func setRunning(_ bundleID: String, _ isRunning: Bool) {
        lock.withLock {
            if isRunning { running.insert(bundleID) } else { running.remove(bundleID) }
        }
    }

    public func openInDefaultBrowser(_ url: URL) async -> Bool {
        lock.withLock { recorded.append(.openInBrowser(url)) }
        return succeeds
    }

    public func open(_ url: URL) async -> Bool {
        lock.withLock {
            recorded.append(.open(url))
            if succeeds, launchesOnOpen, url.scheme?.lowercased() == "spotify" { running.insert(AppBundleID.spotify) }
        }
        return succeeds
    }

    public func revealInFinder(_ fileURL: URL) async -> Bool {
        lock.withLock { recorded.append(.reveal(fileURL)) }
        return succeeds
    }

    public func isInstalled(bundleID: String) async -> Bool { lock.withLock { installed.contains(bundleID) } }
    public func isRunning(bundleID: String) async -> Bool { lock.withLock { running.contains(bundleID) } }
}

/// Keeps copied text in memory.
public final class RecordingPasteboard: AppToolPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var copied: [String] = []
    private let succeeds: Bool

    public init(succeeds: Bool = true) { self.succeeds = succeeds }

    public var copies: [String] { lock.withLock { copied } }

    public func copy(_ text: String) async -> Bool {
        lock.withLock { copied.append(text) }
        return succeeds
    }
}

/// Records each AppleScript source and answers with a scripted reply. Never runs anything.
public final class ScriptedAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    /// Given the source and how many scripts ran before it, return the script's output or throw its error.
    public typealias Responder = @Sendable (_ source: String, _ index: Int) throws -> String

    private let lock = NSLock()
    private var sources: [String] = []
    private let responder: Responder

    public init(_ responder: @escaping Responder = { _, _ in "" }) { self.responder = responder }

    /// Every script that would have run, in order.
    public var scripts: [String] { lock.withLock { sources } }

    public func run(_ source: String, timeout: Duration) async throws -> String {
        let index = lock.withLock {
            sources.append(source)
            return sources.count - 1
        }
        return try responder(source, index)
    }
}

/// Calendars and events in memory, with a settable permission state.
public actor InMemoryCalendarStore: CalendarStore {
    public private(set) var authorizationState: CalendarAuthorization
    /// What a permission prompt would end in when the state is `notDetermined`.
    public var stateAfterRequest: CalendarAuthorization
    public private(set) var accessRequests = 0
    public var storedCalendars: [CalendarInfo]
    public var defaultCalendarID: String?
    public private(set) var storedEvents: [CalendarEventRecord]
    public private(set) var savedDrafts: [CalendarEventDraft] = []
    /// Thrown by `events(from:to:)` when set.
    public var fetchError: CalendarStoreError?
    /// Thrown by `save(_:)` when set.
    public var saveError: CalendarStoreError?
    /// Each fetch window, in order.
    public private(set) var fetchWindows: [DateInterval] = []

    public init(authorization: CalendarAuthorization = .fullAccess, stateAfterRequest: CalendarAuthorization = .fullAccess,
                calendars: [CalendarInfo] = [CalendarInfo(id: "cal-home", title: "Home"), CalendarInfo(id: "cal-work", title: "Work")],
                defaultCalendarID: String? = "cal-home", events: [CalendarEventRecord] = []) {
        self.authorizationState = authorization
        self.stateAfterRequest = stateAfterRequest
        self.storedCalendars = calendars
        self.defaultCalendarID = defaultCalendarID
        self.storedEvents = events
    }

    public func setAuthorization(_ state: CalendarAuthorization) { authorizationState = state }
    public func setFetchError(_ error: CalendarStoreError?) { fetchError = error }
    public func setSaveError(_ error: CalendarStoreError?) { saveError = error }
    public func add(_ event: CalendarEventRecord) { storedEvents.append(event) }

    public func authorization() async -> CalendarAuthorization { authorizationState }

    public func requestFullAccess() async -> CalendarAuthorization {
        if authorizationState == .notDetermined {
            accessRequests += 1
            authorizationState = stateAfterRequest
        }
        return authorizationState
    }

    public func calendars() async -> [CalendarInfo] { authorizationState.canRead ? storedCalendars : [] }

    public func defaultCalendar() async -> CalendarInfo? {
        guard authorizationState.canWrite else { return nil }
        return storedCalendars.first { $0.id == defaultCalendarID }
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEventRecord] {
        guard authorizationState.canRead else { throw CalendarStoreError.accessDenied }
        if let fetchError { throw fetchError }
        fetchWindows.append(DateInterval(start: start, end: max(start, end)))
        return storedEvents.filter { $0.end > start && $0.start < end }
    }

    public func save(_ draft: CalendarEventDraft) async throws -> CalendarEventRecord {
        guard authorizationState.canWrite else { throw CalendarStoreError.accessDenied }
        if let saveError { throw saveError }
        guard let calendar = draft.calendar ?? storedCalendars.first(where: { $0.id == defaultCalendarID }) else {
            throw CalendarStoreError.noWritableCalendar
        }
        savedDrafts.append(draft)
        let record = CalendarEventRecord(id: "event-\(storedEvents.count + 1)", title: draft.title, start: draft.start, end: draft.end,
                                         isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes, calendar: calendar)
        storedEvents.append(record)
        return record
    }
}
