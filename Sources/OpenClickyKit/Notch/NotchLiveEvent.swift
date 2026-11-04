import Foundation

/// How a live event reads at a glance: the colour of its icon and ring.
public enum NotchTone: String, Sendable, Hashable, Codable {
    case info
    case success
    /// Something waits on the user (a job needs an answer, a meeting is about to start).
    case attention
    case warning
}

/// What the notch's Stop can stop, through the same paths as the menu's Stop, Escape and the take-over overlay.
public enum NotchStopTarget: String, Sendable, Hashable, Codable, CaseIterable {
    /// A voice or typed answer being spoken (or still thinking).
    case voice
    /// A drawing still on screen after the answer.
    case drawing
    /// A take-over drive.
    case takeover
    /// Always-on voice.
    case alwaysOn = "always-on"

    public var title: String {
        switch self {
        case .voice: "Stop"
        case .drawing: "Clear"
        case .takeover: "Stop"
        case .alwaysOn: "Stop"
        }
    }

    /// What Stop would stop now, most urgent first: a take-over drive, then an answer in progress, then a drawing left
    /// on screen, then always-on voice. Nil when nothing is running.
    public static func current(takeoverDriving: Bool, answering: Bool, drawing: Bool, alwaysOn: Bool) -> NotchStopTarget? {
        if takeoverDriving { return .takeover }
        if answering { return .voice }
        if drawing { return .drawing }
        if alwaysOn { return .alwaysOn }
        return nil
    }
}

/// A button on a live event.
public struct NotchAction: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Open a link: a call, Maps directions, the event's page, a System Settings pane.
        case openURL(URL)
        /// Show a background job in the agent HUD.
        case openJob(String)
        /// Reveal a file in Finder (or open a web link a job produced).
        case revealFile(String)
        /// Never show this kind of notice again.
        case suppress(NotchSuppression)
        /// Stop something that is running (a take-over drive, always-on voice).
        case stop(NotchStopTarget)
        /// Open a Settings page (`openclicky://settings/<page>`).
        case openSettings(String)
        /// Just close the event.
        case dismiss
    }

    public var id: String
    public var title: String
    public var symbol: String?
    public var kind: Kind
    /// The filled button; the others are plain.
    public var isPrimary: Bool

    public init(id: String, title: String, symbol: String? = nil, kind: Kind, isPrimary: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.isPrimary = isPrimary
    }
}

/// Notices the user can turn off from the notice itself.
public enum NotchSuppression: String, Sendable, Hashable, Codable {
    case folderAccessNotice = "folder_access_notice"
}

/// How long a live event stays up once it is on screen.
public enum NotchEventExpiry: Sendable, Hashable {
    /// This many seconds of being visible (the clock stops while the notch is open, hidden or busy with a turn).
    case visibleFor(TimeInterval)
    /// Until a wall-clock time, visible or not (a meeting countdown ends when the meeting is under way).
    case at(Date)
    /// Until the user closes it or its source withdraws it.
    case untilDismissed
}

/// A short, transient surface on the notch: something happened that the user should know about now.
public struct NotchLiveEvent: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// macOS refused to let OpenClicky read the open document (Files & Folders).
        /// `showsDontShowAgain` is true from the second time the notice appears.
        case folderAccessDenied(folder: GuardedFolder?, document: String, showsDontShowAgain: Bool)
        /// The next meeting is close; counts down to its start.
        case meetingCountdown(UpcomingMeeting)
        /// A background job started (or started another run).
        case jobLaunched(jobID: String, title: String)
        /// A background job waits on the user: an approval or a question.
        case jobNeedsYou(jobID: String, title: String, detail: String?)
        /// A background job finished.
        case jobDone(jobID: String, title: String, summary: String, file: String?)
        /// A background job stopped with an error.
        case jobFailed(jobID: String, title: String, summary: String)
        /// Dictation couldn't type into the field, so the text is on the clipboard.
        case dictationCopied(preview: String?, why: String)
        /// The Mac's sound is off, so the spoken reply was copied to the clipboard instead.
        case replyCopiedMuted(preview: String, lineCount: Int)
        /// A routine's run finished.
        case routineDone(jobID: String, title: String, summary: String, file: String?)
        /// A routine's run stopped with an error.
        case routineFailed(jobID: String, title: String, summary: String)
        /// Spending crossed a limit the user set (warned, stopped, or past a warn-only limit).
        case usageLimit(UsageLimitAlert.Kind, message: String)
        /// A provider couldn't be reached or refused, explained in plain words (`ProviderUnavailableError`).
        case providerUnavailable(provider: String, purpose: String, explanation: String)
        /// The browser extension connected to OpenClicky.
        case browserConnected(browser: String)
        /// The browser extension went away.
        case browserDisconnected(browser: String)
        /// OpenClicky is clicking and typing for the user; `detail` is the step under way.
        case takeoverDriving(task: String, detail: String?, dryRun: Bool)
        /// Always-on voice is on and listening.
        case alwaysOnListening(hint: String?)
    }

    /// Stable identity: posting an event with the same id updates the one already shown or queued.
    public var id: String
    public var kind: Kind
    public var postedAt: Date

    public init(id: String, kind: Kind, postedAt: Date) {
        self.id = id
        self.kind = kind
        self.postedAt = postedAt
    }

    // MARK: Content

    public var title: String {
        switch kind {
        case .folderAccessDenied:
            return "OpenClicky can't open that document"
        case .meetingCountdown(let meeting):
            return meeting.event.title.isEmpty ? "Meeting" : meeting.event.title
        case .jobLaunched(_, let title):
            return "Started: \(title)"
        case .jobNeedsYou(_, let title, _):
            return "\(title) needs you"
        case .jobDone(_, let title, _, _):
            return "\(title) is done"
        case .jobFailed(_, let title, _):
            return "\(title) didn't finish"
        case .dictationCopied:
            return "Dictation is on the clipboard"
        case .replyCopiedMuted:
            return "Your Mac's sound is off"
        case .routineDone(_, let title, _, _):
            return "Routine done: \(title)"
        case .routineFailed(_, let title, _):
            return "Routine didn't finish: \(title)"
        case .usageLimit(let kind, _):
            switch kind {
            case .warned: return "Nearing your spending limit"
            case .stopped: return "Spending limit reached"
            case .passed: return "Past your spending limit"
            }
        case .providerUnavailable(let provider, _, _):
            return "\(provider) isn't answering"
        case .browserConnected(let browser):
            return "\(browser) is connected"
        case .browserDisconnected(let browser):
            return "\(browser) disconnected"
        case .takeoverDriving(_, _, let dryRun):
            return dryRun ? "Practising the steps" : "OpenClicky is driving"
        case .alwaysOnListening:
            return "Always-on is listening"
        }
    }

    /// The second line. For a meeting it depends on the time, so pass the current one.
    public func subtitle(now: Date) -> String? {
        switch kind {
        case .folderAccessDenied(let folder, _, _):
            let place = folder.map { "your \($0.displayName) folder" } ?? "that folder"
            return "Allow access to \(place) in Files & Folders"
        case .meetingCountdown(let meeting):
            return Self.countdownText(start: meeting.event.start, now: now)
        case .jobLaunched:
            return "Working in the background"
        case .jobNeedsYou(_, _, let detail):
            return detail ?? "It's waiting for your answer"
        case .jobDone(_, _, let summary, _), .jobFailed(_, _, let summary):
            return summary.isEmpty ? nil : summary
        case .dictationCopied(let preview, let why):
            if let preview, !preview.isEmpty { return "\(why) · ⌘V pastes “\(Self.clip(preview, 60))”" }
            return "\(why) · press ⌘V to paste"
        case .replyCopiedMuted(let preview, _):
            return "Reply copied: “\(Self.clip(preview, 80))”"
        case .routineDone(_, _, let summary, _), .routineFailed(_, _, let summary):
            return summary.isEmpty ? nil : Self.clip(summary, 120)
        case .usageLimit(_, let message):
            return message
        case .providerUnavailable(_, _, let explanation):
            return Self.clip(explanation, 140)
        case .browserConnected:
            return "Background jobs can use your browser"
        case .browserDisconnected:
            return "Jobs can't use the browser until it reconnects"
        case .takeoverDriving(let task, let detail, _):
            return Self.clip(detail ?? task, 90)
        case .alwaysOnListening(let hint):
            return ["Just talk", hint].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public var symbol: String {
        switch kind {
        case .folderAccessDenied: "folder.badge.questionmark"
        case .meetingCountdown(let meeting):
            switch meeting.action {
            case .join: "video.fill"
            case .directions: "car.fill"
            case .open, nil: "calendar"
            }
        case .jobLaunched: "paperplane.fill"
        case .jobNeedsYou: "hand.raised.fill"
        case .jobDone: "checkmark.circle.fill"
        case .jobFailed: "exclamationmark.triangle.fill"
        case .dictationCopied: "doc.on.clipboard.fill"
        case .replyCopiedMuted: "speaker.slash.fill"
        case .routineDone: "clock.badge.checkmark.fill"
        case .routineFailed: "clock.badge.exclamationmark.fill"
        case .usageLimit(let kind, _): kind == .stopped ? "dollarsign.circle.fill" : "gauge.with.dots.needle.67percent"
        case .providerUnavailable: "wifi.exclamationmark"
        case .browserConnected: "globe"
        case .browserDisconnected: "globe.badge.chevron.backward"
        case .takeoverDriving: "cursorarrow.motionlines"
        case .alwaysOnListening: "waveform"
        }
    }

    public var tone: NotchTone {
        switch kind {
        case .folderAccessDenied: .warning
        case .meetingCountdown: .attention
        case .jobLaunched: .info
        case .jobNeedsYou: .attention
        case .jobDone: .success
        case .jobFailed: .warning
        case .dictationCopied: .info
        case .replyCopiedMuted: .info
        case .routineDone: .success
        case .routineFailed: .warning
        case .usageLimit(let kind, _): kind == .warned ? .attention : .warning
        case .providerUnavailable: .warning
        case .browserConnected: .success
        case .browserDisconnected: .info
        case .takeoverDriving: .attention
        case .alwaysOnListening: .info
        }
    }

    /// Higher shows first when several wait.
    public var priority: Int {
        switch kind {
        // A drive in progress and a stopped spending limit are about what OpenClicky is doing right now.
        case .takeoverDriving: 5
        case .usageLimit(let kind, _): kind == .warned ? 2 : 4
        case .jobNeedsYou, .meetingCountdown, .replyCopiedMuted, .providerUnavailable: 3
        case .folderAccessDenied, .dictationCopied: 2
        case .jobDone, .jobFailed, .routineDone, .routineFailed: 1
        case .jobLaunched, .browserConnected, .browserDisconnected, .alwaysOnListening: 0
        }
    }

    public var expiry: NotchEventExpiry {
        switch kind {
        case .folderAccessDenied: .visibleFor(10)
        case .meetingCountdown(let meeting):
            .at(min(meeting.event.start.addingTimeInterval(MeetingCountdownPolicy.defaultGrace), meeting.event.end))
        case .jobLaunched: .visibleFor(4)
        case .jobNeedsYou: .visibleFor(14)
        case .jobDone: .visibleFor(8)
        case .jobFailed: .visibleFor(10)
        case .dictationCopied: .visibleFor(6)
        case .replyCopiedMuted: .visibleFor(7)
        case .routineDone: .visibleFor(8)
        case .routineFailed: .visibleFor(10)
        case .usageLimit(let kind, _): .visibleFor(kind == .warned ? 8 : 12)
        case .providerUnavailable: .visibleFor(10)
        case .browserConnected, .browserDisconnected: .visibleFor(4)
        // Up for as long as it runs: their sources take them down.
        case .takeoverDriving, .alwaysOnListening: .untilDismissed
        }
    }

    /// The quiet-context kind this event is offered as (held during a call or a Focus), or nil when it shows at once:
    /// notes about what the user is doing right now (a drive, a limit, a failing provider, the browser) never wait.
    public var proactiveKind: ProactiveKind? {
        switch kind {
        case .meetingCountdown: .meetingCountdown
        case .jobDone, .jobFailed, .jobNeedsYou: .jobReport
        case .routineDone, .routineFailed: .routineNotice
        default: nil
        }
    }

    /// The event's buttons, primary first.
    public var actions: [NotchAction] {
        switch kind {
        case .folderAccessDenied(_, _, let showsDontShowAgain):
            var actions = [NotchAction(id: "settings", title: "Open Settings", symbol: "gearshape", kind: .openURL(GuardedFolder.settingsURL),
                                       isPrimary: true)]
            if showsDontShowAgain {
                actions.append(NotchAction(id: "suppress", title: "Don't show again", kind: .suppress(.folderAccessNotice)))
            } else {
                actions.append(NotchAction(id: "dismiss", title: "Not now", kind: .dismiss))
            }
            return actions
        case .meetingCountdown(let meeting):
            return MeetingCountdownPolicy.actions(for: meeting.event)
        case .jobLaunched(let id, _):
            return [NotchAction(id: "show", title: "Show", symbol: "list.bullet.rectangle", kind: .openJob(id))]
        case .jobNeedsYou(let id, _, _):
            return [NotchAction(id: "show", title: "Answer", symbol: "bubble.left.fill", kind: .openJob(id), isPrimary: true)]
        case .jobDone(let id, _, _, let file):
            var actions: [NotchAction] = []
            if let file { actions.append(NotchAction(id: "file", title: "Open", symbol: "doc", kind: .revealFile(file), isPrimary: true)) }
            actions.append(NotchAction(id: "show", title: "Show", symbol: "list.bullet.rectangle", kind: .openJob(id), isPrimary: file == nil))
            return actions
        case .jobFailed(let id, _, _):
            return [NotchAction(id: "show", title: "Show", symbol: "list.bullet.rectangle", kind: .openJob(id))]
        case .dictationCopied, .replyCopiedMuted, .browserConnected, .browserDisconnected:
            return []
        case .routineDone(let id, _, _, let file):
            var actions: [NotchAction] = []
            if let file { actions.append(NotchAction(id: "file", title: "Open", symbol: "doc", kind: .revealFile(file), isPrimary: true)) }
            actions.append(NotchAction(id: "show", title: "Show", symbol: "list.bullet.rectangle", kind: .openJob(id), isPrimary: file == nil))
            return actions
        case .routineFailed(let id, _, _):
            return [NotchAction(id: "show", title: "Show", symbol: "list.bullet.rectangle", kind: .openJob(id))]
        case .usageLimit:
            return [NotchAction(id: "usage", title: "Usage", symbol: "chart.bar", kind: .openSettings("usage"), isPrimary: true)]
        case .providerUnavailable:
            return [NotchAction(id: "providers", title: "Check", symbol: "stethoscope", kind: .openSettings("developer"))]
        case .takeoverDriving:
            return [NotchAction(id: "stop", title: "Stop", symbol: "stop.fill", kind: .stop(.takeover), isPrimary: true)]
        case .alwaysOnListening:
            return [NotchAction(id: "stop", title: "Stop", symbol: "stop.fill", kind: .stop(.alwaysOn))]
        }
    }

    /// Whether the card has a row of buttons (Dismiss is the close button, not part of the row).
    public var hasButtons: Bool { actions.contains { if case .dismiss = $0.kind { false } else { true } } }

    /// What clicking the event's body (not a button) does: its primary action, or opening the notch.
    public var bodyAction: NotchAction? {
        switch kind {
        case .jobLaunched, .jobNeedsYou, .jobDone, .jobFailed, .routineDone, .routineFailed:
            return actions.first { if case .openJob = $0.kind { true } else { false } }
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// "in 4 min", "in 45 s", "now", "started 3 min ago".
    public static func countdownText(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds > 90 { return "Starts in \(Int((seconds / 60).rounded(.up))) min" }
        if seconds > 5 { return "Starts in \(Int(seconds.rounded())) s" }
        if seconds > -60 { return "Starting now" }
        let minutes = Int((-seconds / 60).rounded(.down))
        return "Started \(minutes) min ago"
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
