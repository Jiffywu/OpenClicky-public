import Foundation

// The services that already exist, turned into notch live events. Each source is a small value or class with no UI,
// so the app, `occtl notch` and the tests drive the same code.

// MARK: - Meeting countdown

/// When the next meeting shows on the notch, and with which buttons.
public struct MeetingCountdownPolicy: Sendable, Hashable {
    /// How long "Join" stays up after the start, for latecomers.
    public static let defaultGrace: TimeInterval = 5 * 60

    /// Show the countdown from this many minutes before the start.
    public var leadMinutes: Int
    public var grace: TimeInterval

    public init(leadMinutes: Int = 5, grace: TimeInterval = MeetingCountdownPolicy.defaultGrace) {
        self.leadMinutes = max(1, leadMinutes)
        self.grace = grace
    }

    /// One id per meeting occurrence, so dismissing today's stand-up doesn't hide tomorrow's.
    public static func eventID(for event: CalendarEventRecord) -> String {
        "meeting:\(event.id)@\(Int(event.start.timeIntervalSince1970))"
    }

    /// The live event for a countdown state, or nil when nothing should show (no access, nothing soon, dismissed).
    public func event(for state: MeetingCountdownState, dismissed: Set<String>, now: Date) -> NotchLiveEvent? {
        guard case .upcoming(let meeting) = state else { return nil }
        let id = Self.eventID(for: meeting.event)
        guard !dismissed.contains(id), meeting.secondsUntilStart <= TimeInterval(leadMinutes) * 60,
              meeting.secondsUntilStart > -grace else { return nil }
        return NotchLiveEvent(id: id, kind: .meetingCountdown(meeting), postedAt: now)
    }

    /// Join the call, directions to the place, the event's own page; whichever apply, the best one filled. Without any,
    /// a button that opens Calendar. Always ends with Dismiss.
    public static func actions(for event: CalendarEventRecord) -> [NotchAction] {
        var actions: [NotchAction] = []
        let join = MeetingLinkDetector.meetingURL(in: event)
        if let join {
            actions.append(NotchAction(id: "join", title: "Join", symbol: "video.fill", kind: .openURL(join)))
        }
        if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), MeetingCountdown.isPlace(location),
           let directions = MeetingCountdown.directionsURL(to: location) {
            actions.append(NotchAction(id: "directions", title: "Directions", symbol: "car.fill", kind: .openURL(directions)))
        }
        if let url = event.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url != join {
            actions.append(NotchAction(id: "open", title: "Open", symbol: "safari", kind: .openURL(url)))
        }
        if actions.isEmpty {
            actions.append(NotchAction(id: "calendar", title: "Calendar", symbol: "calendar",
                                       kind: .openURL(URL(fileURLWithPath: "/System/Applications/Calendar.app"))))
        }
        actions[0].isPrimary = true
        actions.append(NotchAction(id: "dismiss", title: "Dismiss", kind: .dismiss))
        return actions
    }
}

/// Polls the calendar for the next meeting and says what the notch should do. Never asks for Calendar access (it runs
/// on a timer); without access it stays quiet.
public actor MeetingCountdownMonitor {
    public enum Update: Sendable, Hashable {
        /// Show (or refresh) this countdown; `replacing` is an earlier one to take down first (the meeting moved, or
        /// another one is now next).
        case show(NotchLiveEvent, replacing: String?)
        /// The meeting shown earlier is gone (moved away, cancelled, declined or over).
        case withdraw(String)
        case nothing
    }

    public let service: CalendarService
    public let policy: MeetingCountdownPolicy
    private var dismissed: Set<String> = []
    private var shownID: String?

    /// `dismissed`: countdowns the user already closed (a monitor restarted for a new lead time keeps them closed).
    public init(service: CalendarService, policy: MeetingCountdownPolicy = MeetingCountdownPolicy(), dismissed: Set<String> = []) {
        self.service = service
        self.policy = policy
        self.dismissed = dismissed
    }

    public func dismiss(_ id: String) {
        dismissed.insert(id)
        if shownID == id { shownID = nil }
    }

    public func poll() async -> Update {
        let state = await service.upcomingMeeting(withinMinutes: policy.leadMinutes, inProgressGrace: policy.grace)
        if let event = policy.event(for: state, dismissed: dismissed, now: service.clock.now()) {
            let previous = shownID
            shownID = event.id
            return .show(event, replacing: previous == event.id ? nil : previous)
        }
        guard let previous = shownID else { return .nothing }
        shownID = nil
        return .withdraw(previous)
    }

    /// Polls every `interval` seconds until the task is cancelled, handing each change to `deliver`.
    public func run(interval: TimeInterval = 60, deliver: @escaping @Sendable (Update) async -> Void) async {
        while !Task.isCancelled {
            let update = await poll()
            if update != .nothing { await deliver(update) }
            try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
        }
    }
}

extension UpcomingMeeting {
    /// The countdown for an event as of `now` (its button picked the usual way).
    public init(event: CalendarEventRecord, now: Date) {
        self.init(event: event, secondsUntilStart: event.start.timeIntervalSince(now), action: MeetingCountdown.primaryAction(for: event))
    }
}

// MARK: - Folder access notice

/// Where the notice's show counter and "don't show again" live.
public protocol NotchNoticeStorage: AnyObject, Sendable {
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func set(_ value: Int, forKey key: String)
    func set(_ value: Bool, forKey key: String)
}

public final class UserDefaultsNoticeStorage: NotchNoticeStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
}

public final class InMemoryNoticeStorage: NotchNoticeStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    public init() {}
    public func integer(forKey key: String) -> Int { lock.withLock { values[key] as? Int ?? 0 } }
    public func bool(forKey key: String) -> Bool { lock.withLock { values[key] as? Bool ?? false } }
    public func set(_ value: Int, forKey key: String) { lock.withLock { values[key] = value } }
    public func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
}

/// The "OpenClicky can't open that document" notice: shown when macOS denied reading the front document, at most once
/// per document every `repeatAfter`, counted, and silenced for good by "Don't show again" (offered from the second
/// time on).
public final class FolderAccessNotice: @unchecked Sendable {
    public static let showCountKey = "openclicky.documentAccess.noticeShowCount.v1"
    public static let suppressedKey = "openclicky.documentAccess.noticeSuppressed.v1"

    private let storage: any NotchNoticeStorage
    private let classifier: GuardedFolderClassifier
    private let repeatAfter: TimeInterval
    private let lock = NSLock()
    private var lastShown: [String: Date] = [:]

    public init(storage: any NotchNoticeStorage = UserDefaultsNoticeStorage(), classifier: GuardedFolderClassifier = GuardedFolderClassifier(),
                repeatAfter: TimeInterval = 10 * 60) {
        self.storage = storage
        self.classifier = classifier
        self.repeatAfter = repeatAfter
    }

    public var showCount: Int { storage.integer(forKey: Self.showCountKey) }
    public var isSuppressed: Bool { storage.bool(forKey: Self.suppressedKey) }

    /// The notice for this turn's document, or nil. Counts the showing when it returns one.
    public func event(for document: ActiveDocument?, now: Date) -> NotchLiveEvent? {
        guard let document, document.accessDenied, document.kind != .webPage, !isSuppressed else { return nil }
        let reference = document.reference
        let allowed: Bool = lock.withLock {
            if let last = lastShown[reference], now.timeIntervalSince(last) < repeatAfter { return false }
            lastShown[reference] = now
            return true
        }
        guard allowed else { return nil }
        let count = showCount
        storage.set(count + 1, forKey: Self.showCountKey)
        let url = reference.hasPrefix("file://") ? URL(string: reference) : URL(fileURLWithPath: reference)
        let folder = url.flatMap { classifier.folder(for: $0) }
        let name = document.title ?? url?.lastPathComponent ?? reference
        return NotchLiveEvent(id: "folder-access:\(reference)",
                              kind: .folderAccessDenied(folder: folder, document: name, showsDontShowAgain: count >= 1), postedAt: now)
    }

    public func suppress() { storage.set(true, forKey: Self.suppressedKey) }

    /// Shows the notice again (Settings' reset).
    public func reset() {
        storage.set(false, forKey: Self.suppressedKey)
        storage.set(0, forKey: Self.showCountKey)
        lock.withLock { lastShown.removeAll() }
    }
}

// MARK: - Background jobs

/// Folds the agent manager's updates into launch, needs-you, done and failed events. Seed it with the jobs that
/// already exist so restarting the app doesn't announce them again.
public struct AgentLiveEvents: Sendable {
    /// What one update changes on the notch: events to post, and earlier "needs you" events to take back because the
    /// job no longer waits on that answer (it was given in the HUD or by voice, or the job was stopped).
    public struct Changes: Sendable, Hashable {
        public var post: [NotchLiveEvent] = []
        public var withdraw: [String] = []
    }

    private var statuses: [String: AgentJobStatus] = [:]
    private var announcedRequests: Set<String> = []
    /// The "needs you" event up for each job, and the approval request it is about (nil for a run's closing question).
    private var waiting: [String: (eventID: String, requestID: String?)] = [:]

    public init() {}

    public mutating func seed(_ records: [AgentJobRecord]) {
        for record in records { statuses[record.id] = record.status }
    }

    public mutating func apply(_ update: AgentManagerUpdate, now: Date) -> [NotchLiveEvent] {
        changes(for: update, now: now).post
    }

    public mutating func changes(for update: AgentManagerUpdate, now: Date) -> Changes {
        var changes = Changes()
        switch update {
        case .job(let record):
            let previous = statuses[record.id]
            statuses[record.id] = record.status
            if let open = waiting[record.id] {
                let stillWaiting = record.status == .needsYou && (open.requestID == nil || record.pendingRequest?.id == open.requestID)
                if !stillWaiting {
                    changes.withdraw.append(open.eventID)
                    waiting[record.id] = nil
                }
            }
            let name = Self.name(record)
            let wasRunning = previous == .running || previous == .queued
            if record.status == .running || record.status == .queued, !wasRunning, previous != .needsYou {
                let run = record.runs.count
                changes.post.append(NotchLiveEvent(id: "job:\(record.id):launched:\(run)", kind: .jobLaunched(jobID: record.id, title: name),
                                                   postedAt: now))
            }
            if record.status == .needsYou, let request = record.pendingRequest, !announcedRequests.contains("\(record.id)#\(request.id)") {
                announcedRequests.insert("\(record.id)#\(request.id)")
                let id = "job:\(record.id):request:\(request.id)"
                waiting[record.id] = (id, request.id)
                changes.post.append(NotchLiveEvent(id: id, kind: .jobNeedsYou(jobID: record.id, title: name, detail: request.summary), postedAt: now))
            }
        case .report(let report):
            let name = report.agentName ?? report.title
            let id = "job:\(report.jobID):report:\(report.run)"
            // A routine's run reads as the routine's, and waits in a quiet context as a routine notice.
            if report.routineID != nil, report.outcome == .done || report.outcome == .failed {
                let kind: NotchLiveEvent.Kind = report.outcome == .done
                    ? .routineDone(jobID: report.jobID, title: name, summary: report.spoken, file: report.files.first)
                    : .routineFailed(jobID: report.jobID, title: name, summary: report.error ?? report.spoken)
                changes.post = [NotchLiveEvent(id: id, kind: kind, postedAt: now)]
                return changes
            }
            switch report.outcome {
            case .done:
                changes.post = [NotchLiveEvent(id: id, kind: .jobDone(jobID: report.jobID, title: name, summary: report.spoken,
                                                                      file: report.files.first), postedAt: now)]
            case .needsYou:
                waiting[report.jobID] = (id, nil)
                changes.post = [NotchLiveEvent(id: id, kind: .jobNeedsYou(jobID: report.jobID, title: name, detail: report.question ?? report.spoken),
                                               postedAt: now)]
            case .failed:
                changes.post = [NotchLiveEvent(id: id, kind: .jobFailed(jobID: report.jobID, title: name, summary: report.error ?? report.spoken),
                                               postedAt: now)]
            case .stopped:
                break
            }
        case .event, .launched:
            break
        }
        return changes
    }

    static func name(_ record: AgentJobRecord) -> String {
        let name = record.agentName ?? record.title
        return name.isEmpty ? "Your job" : name
    }
}

// MARK: - Dictation

public enum DictationLiveEvents {
    /// The notch event for a finished dictation that left its text on the clipboard; nil otherwise. Reads the
    /// session's report, the only place that says whether the clipboard write worked and what text it holds (the
    /// HUD's `.done` status carries neither).
    public static func event(for report: DictationSessionReport, now: Date) -> NotchLiveEvent? {
        guard let insertion = report.insertion, insertion.copiedToClipboard else { return nil }
        let why: String
        switch report.result {
        case .copiedToClipboard(.focusLost): why = "The field lost focus"
        case .copiedToClipboard(.pasteboardWriteFailed): return nil
        case .copiedToClipboard: why = "Couldn't type here"
        case .refused(.accessibilityPermission): why = "Typing needs Accessibility"
        default: return nil
        }
        let copied = insertion.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotchLiveEvent(id: "dictation:\(Int(now.timeIntervalSince1970 * 1000))",
                              kind: .dictationCopied(preview: copied.isEmpty ? nil : copied, why: why), postedAt: now)
    }
}

// MARK: - Muted reply

public enum MutedReplyPolicy {
    /// The reply to put on the clipboard because nobody could hear it, or nil. Only answers that were meant to be
    /// heard count: voice, guided and job-report turns, and typed ones when Settings reads typed answers aloud. Only
    /// a whole answer counts: one the user cut off (Escape, a new press) or a brain failure leaves the clipboard alone.
    public static func textToCopy(kind: TurnKind, spokenLines: [String], speaksTypedAnswers: Bool, output: OutputSoundState,
                                  outcome: NarrationOutcome = .completed) -> String? {
        guard output.isSilent, outcome == .completed else { return nil }
        if kind == .typed, !speaksTypedAnswers { return nil }
        let lines = spokenLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " ")
    }

    public static func event(copied text: String, lineCount: Int, now: Date) -> NotchLiveEvent {
        NotchLiveEvent(id: "muted-reply:\(Int(now.timeIntervalSince1970 * 1000))",
                       kind: .replyCopiedMuted(preview: text, lineCount: lineCount), postedAt: now)
    }
}

// MARK: - Spending limits

public enum UsageLiveEvents {
    /// The notch event for a limit crossing (one per period and level, like the notification).
    public static func event(for alert: UsageLimitAlert, now: Date) -> NotchLiveEvent {
        NotchLiveEvent(id: alert.id, kind: .usageLimit(alert.kind, message: alert.body), postedAt: now)
    }
}

// MARK: - Providers

/// Provider failures, said once per provider and verdict within `repeatAfter` (a flapping connection doesn't fill the
/// notch).
public struct ProviderLiveEvents: Sendable {
    public var repeatAfter: TimeInterval
    private var lastShown: [String: Date] = [:]

    public init(repeatAfter: TimeInterval = 5 * 60) { self.repeatAfter = repeatAfter }

    public mutating func event(for error: ProviderUnavailableError, now: Date) -> NotchLiveEvent? {
        let diagnosis = error.diagnosis
        let id = "provider:\(diagnosis.providerID):\(diagnosis.verdict.rawValue)"
        if let last = lastShown[id], now.timeIntervalSince(last) < repeatAfter { return nil }
        lastShown[id] = now
        return NotchLiveEvent(id: id, kind: .providerUnavailable(provider: diagnosis.providerName, purpose: diagnosis.purpose.rawValue,
                                                                 explanation: diagnosis.explanation), postedAt: now)
    }
}

// MARK: - Browser

/// The browser extension coming and going, from the bridge's list of connected browsers.
public struct BrowserLiveEvents: Sendable {
    private var connected: Set<String> = []

    public init() {}

    /// Events for the browsers that connected or left since the last list.
    public mutating func changes(peers: [BrowserPeer], now: Date) -> [NotchLiveEvent] {
        let names = Set(peers.map(\.browserName))
        let stamp = Int(now.timeIntervalSince1970)
        var events: [NotchLiveEvent] = []
        for browser in names.subtracting(connected).sorted() {
            events.append(NotchLiveEvent(id: "browser:\(browser):connected:\(stamp)", kind: .browserConnected(browser: browser), postedAt: now))
        }
        for browser in connected.subtracting(names).sorted() {
            events.append(NotchLiveEvent(id: "browser:\(browser):disconnected:\(stamp)", kind: .browserDisconnected(browser: browser), postedAt: now))
        }
        connected = names
        return events
    }
}

// MARK: - Take-over and always-on

public enum TakeoverLiveEvents {
    public static let eventID = "takeover:driving"

    /// The driving card while a drive runs (its Stop goes through the take-over's own stop path), updated as steps
    /// happen; nil when nothing drives (the source withdraws `eventID` then).
    public static func event(for phase: TakeoverPhase, detail: String?, dryRun: Bool, now: Date) -> NotchLiveEvent? {
        switch phase {
        case .driving(let offer):
            return NotchLiveEvent(id: eventID, kind: .takeoverDriving(task: offer.brief.task, detail: detail, dryRun: dryRun), postedAt: now)
        case .stopping(let offer, _):
            return NotchLiveEvent(id: eventID, kind: .takeoverDriving(task: offer.brief.task, detail: "Stopping…", dryRun: dryRun), postedAt: now)
        case .idle, .offered, .approved:
            return nil
        }
    }
}

public enum AlwaysOnLiveEvents {
    public static let eventID = "always-on:listening"

    /// The listening card while always-on waits for the user (nil otherwise: starting, hearing, thinking and speaking
    /// show in the pill).
    public static func event(for display: AlwaysOnDisplay, hint: String?, now: Date) -> NotchLiveEvent? {
        guard display.isIdleListening else { return nil }
        return NotchLiveEvent(id: eventID, kind: .alwaysOnListening(hint: hint), postedAt: now)
    }
}
