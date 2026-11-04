import CoreGraphics
import Foundation

/// A scripted notch session for `occtl notch simulate` and the tests: pointer moves, clicks, keys and the live-event
/// sources (calendar, jobs, dictation, a denied document, a muted reply, the window list) on a virtual clock. Runs
/// the real presenter, event sources, system-UI detector and yield limits; nothing touches the screen.
public struct NotchScript: Codable, Sendable {
    public struct Display: Codable, Sendable {
        public var id: UInt32?
        public var width: Double
        public var height: Double
        /// `[left, right, height]` of the camera housing in display points; omit for a display without one.
        public var notch: [Double]?
    }

    public struct Meeting: Codable, Sendable {
        public var id: String?
        public var title: String
        /// Seconds from this step to the start.
        public var startsIn: Double
        public var minutes: Double?
        public var url: String?
        public var location: String?
        public var notes: String?
    }

    public struct Job: Codable, Sendable {
        public var id: String
        public var title: String
        /// `queued`, `running`, `needs-you`, `done`, `failed` or `stopped`.
        public var status: String
        public var runs: Int?
        /// An approval or question waiting on the user.
        public var request: String?
    }

    public struct Report: Codable, Sendable {
        public var jobID: String
        public var run: Int?
        public var title: String
        /// `done`, `needs-you`, `failed` or `stopped`.
        public var outcome: String
        public var spoken: String
        public var question: String?
        public var file: String?
        /// The routine that started the run (its card reads as the routine's).
        public var routineID: String?
    }

    public struct Dictation: Codable, Sendable {
        public var text: String
        /// `focusLost`, `noTarget`, `clipboardFailed`, `accessibility` or `typed`.
        public var result: String
    }

    public struct Reply: Codable, Sendable {
        /// `voice`, `typed`, `report` or `guided`.
        public var kind: String?
        public var lines: [String]
        public var muted: Bool
        public var speaksTypedAnswers: Bool?
        /// The user cut the answer off with Escape (nothing is copied then).
        public var cutOff: Bool?
    }

    public struct Window: Codable, Sendable {
        public var owner: String
        public var bundleID: String?
        public var layer: Int?
        /// `[x, y, width, height]` in display points, top-left origin.
        public var frame: [Double]
        /// Belongs to the front app (for full-screen detection).
        public var front: Bool?
    }

    public struct Step: Codable, Sendable {
        public var at: Double
        public var note: String?
        /// `[x, y]` in display points, top-left origin.
        public var pointer: [Double]?
        /// `notch`, `outside`, `event`, `close`, `composer`, or `tab:home|chat|settings`.
        public var click: String?
        /// `escape`.
        public var key: String?
        /// Text sent from the chat composer.
        public var type: String?
        /// An action id on the event on screen (`join`, `settings`, `suppress`, `show`…).
        public var action: String?
        public var activity: Bool?
        public var onboarding: Bool?
        /// The on-screen window list from now on.
        public var windows: [Window]?
        public var fullscreen: Bool?
        public var meeting: Meeting?
        /// Withdraws Calendar access (`false`) or gives it back.
        public var calendarAccess: Bool?
        public var job: Job?
        public var report: Report?
        public var dictation: Dictation?
        /// A document path macOS refused to let OpenClicky read.
        public var deniedDocument: String?
        public var reply: Reply?
        /// Spending crossed a limit: `warned`, `stopped` or `passed`.
        public var usage: String?
        /// This provider couldn't be reached (a network block, as the provider layer explains it).
        public var providerDown: String?
        /// The browsers connected to the bridge from now on (bundle ids or names; empty: none).
        public var browsers: [String]?
        /// A take-over drive started on this task; `takeoverEnds` ends it.
        public var takeover: String?
        public var takeoverEnds: Bool?
        /// Always-on voice started listening (true) or stopped (false).
        public var alwaysOn: Bool?
        /// What the pill's Stop stops from now on: `voice`, `drawing`, `takeover`, `always-on` or `none`.
        public var stoppable: String?
        /// The pill's Stop was clicked.
        public var stop: Bool?
    }

    public var display: Display?
    public var settings: NotchSettings?
    public var steps: [Step]
    /// Keep ticking this long after the last step (seconds; default 2).
    public var tail: Double?

    public init(display: Display? = nil, settings: NotchSettings? = nil, steps: [Step], tail: Double? = nil) {
        self.display = display
        self.settings = settings
        self.steps = steps
        self.tail = tail
    }
}

public enum NotchSimulator {
    public struct Result: Sendable {
        public var log: [String]
        public var effects: [NotchEffect]
        /// Every surface the active display showed, in order, with the time it appeared.
        public var surfaces: [(at: Double, surface: NotchSurface)]
        public var presenter: NotchPresenter
        public var folderNoticeShowCount: Int
        public var folderNoticeSuppressed: Bool
        /// What a muted reply put on the clipboard.
        public var clipboard: String?
    }

    /// A Date the simulation's virtual time starts at (fixed, so runs are reproducible).
    public static let origin = Date(timeIntervalSince1970: 1_800_000_000)
    public static let tick: Double = 0.1

    public static func run(_ script: NotchScript) async -> Result {
        let display = script.display ?? NotchScript.Display(id: 1, width: 1710, height: 1112, notch: [751, 959, 37.5])
        let displayID = display.id ?? 1
        let frame = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let notchRect = display.notch.flatMap { values -> CGRect? in
            guard values.count == 3 else { return nil }
            return CGRect(x: values[0], y: display.height - values[2], width: values[1] - values[0], height: values[2])
        }
        let geometry = NotchGeometry(screenFrame: frame, notchRect: notchRect)
        let settings = script.settings ?? NotchSettings()
        let clock = SimulatedClock(origin)
        let store = InMemoryCalendarStore()
        let calendar = CalendarService(store: store, clock: CalendarClock(now: { clock.now }))
        let monitor = MeetingCountdownMonitor(service: calendar, policy: MeetingCountdownPolicy(leadMinutes: settings.meetingLeadMinutes))
        let folderNotice = FolderAccessNotice(storage: InMemoryNoticeStorage(), classifier: GuardedFolderClassifier(homeDirectory: URL(fileURLWithPath: "/Users/you")))
        var agents = AgentLiveEvents()
        var providers = ProviderLiveEvents()
        var browsers = BrowserLiveEvents()
        var presenter = NotchPresenter(timing: NotchTiming(hoverOpens: settings.hoverOpens))
        var yields = NotchYieldCoordinator()
        let detector = SystemUIDetector()
        var windows: [SystemWindowInfo] = []
        var log: [String] = []
        var effects: [NotchEffect] = []
        var surfaces: [(at: Double, surface: NotchSurface)] = []
        var clipboard: String?
        var lastPointer: CGPoint?
        var lastMeetingPoll = -Double.infinity
        var lastLine = ""

        func stamp(_ t: Double) -> String { String(format: "%6.2fs", t) }

        func describe(_ t: Double) {
            let surface = presenter.surface(on: displayID)
            let line = "surface \(surface.name) · presentation \(presenter.presentation.name)"
            if line != lastLine {
                log.append("\(stamp(t))  \(line)")
                lastLine = line
                surfaces.append((t, surface))
            }
        }

        func feed(_ input: NotchInput, at t: Double) async {
            let now = origin.addingTimeInterval(t)
            let out = presenter.handle(input, now: now)
            for effect in out {
                effects.append(effect)
                log.append("\(stamp(t))  effect \(Self.describe(effect))")
                switch effect {
                case .dismissed(let id) where id.hasPrefix("meeting:"): await monitor.dismiss(id)
                case .suppress(.folderAccessNotice): folderNotice.suppress()
                default: break
                }
            }
            describe(t)
        }

        func pointerInput(_ point: CGPoint) -> NotchInput {
            let global = CGPoint(x: point.x, y: display.height - point.y)
            let inPanel = geometry.contentRect(for: presenter.surface(on: displayID)).contains(global)
            return .pointer(display: displayID, inHotZone: geometry.hotZone.contains(global), inPanel: inPanel)
        }

        func pollMeetings(at t: Double) async {
            lastMeetingPoll = t
            guard settings.meetingCountdown else { return }
            switch await monitor.poll() {
            case .show(let event, let replacing):
                if let replacing { await feed(.withdraw(replacing), at: t) }
                await feed(.post(event), at: t)
            case .withdraw(let id): await feed(.withdraw(id), at: t)
            case .nothing: break
            }
        }

        var ticks = 0
        func advance(to target: Double, from t: inout Double) async {
            while t + tick <= target + 1e-9 {
                t += tick
                ticks += 1
                // A long script is thousands of ticks of plain CPU work: let other tasks (parallel tests, the app's
                // main actor when occtl runs it) in now and then.
                if ticks % 64 == 0 { await Task.yield() }
                clock.now = origin.addingTimeInterval(t)
                if let lastPointer { await feed(pointerInput(lastPointer), at: t) } else { await feed(.tick, at: t) }
                if t - lastMeetingPoll >= 60 { await pollMeetings(at: t) }
                if !windows.isEmpty {
                    let active = yields.update(detector.reasons(in: windows, displays: [frame]), now: origin.addingTimeInterval(t))
                    if active != presenter.yielding { await feed(.yield(active), at: t) }
                }
            }
            t = max(t, target)
            clock.now = origin.addingTimeInterval(t)
        }

        describe(0)
        var t = 0.0
        await pollMeetings(at: 0)
        for step in script.steps.sorted(by: { $0.at < $1.at }) {
            await advance(to: step.at, from: &t)
            let now = origin.addingTimeInterval(t)
            if let note = step.note { log.append("\(stamp(t))  — \(note)") }
            if let onboarding = step.onboarding { await feed(.onboarding(pinned: onboarding), at: t) }
            if let activity = step.activity { await feed(.activity(activity), at: t) }
            if let list = step.windows {
                windows = list.enumerated().map { index, window in
                    let f = window.frame.count == 4 ? CGRect(x: window.frame[0], y: window.frame[1], width: window.frame[2], height: window.frame[3]) : .zero
                    return SystemWindowInfo(ownerName: window.owner, bundleID: window.bundleID, pid: window.front == true ? 4242 : Int32(1000 + index),
                                            layer: window.layer ?? 0, bounds: f)
                }
                let detected = detector.reasons(in: windows, displays: [frame])
                let active = yields.update(detected, now: now)
                log.append("\(stamp(t))  window list: \(windows.count) windows; system UI \(detected.isEmpty ? "none" : detected.sorted().map(\.rawValue).joined(separator: ", "))")
                await feed(.yield(active), at: t)
                let full = FullscreenDetector.fullscreenDisplays(windows: windows, displays: [frame], frontPID: 4242)
                await feed(.fullscreen(full.isEmpty ? [] : [displayID]), at: t)
            }
            if let fullscreen = step.fullscreen { await feed(.fullscreen(fullscreen ? [displayID] : []), at: t) }
            if let access = step.calendarAccess {
                await store.setAuthorization(access ? .fullAccess : .denied)
                await pollMeetings(at: t)
            }
            if let meeting = step.meeting {
                let start = now.addingTimeInterval(meeting.startsIn)
                let record = CalendarEventRecord(id: meeting.id ?? "event-\(Int(t * 10))", title: meeting.title, start: start,
                                                 end: start.addingTimeInterval((meeting.minutes ?? 30) * 60), location: meeting.location,
                                                 notes: meeting.notes, url: meeting.url.flatMap(URL.init(string:)))
                await store.add(record)
                log.append("\(stamp(t))  calendar: “\(meeting.title)” starts in \(Int(meeting.startsIn)) s")
                await pollMeetings(at: t)
            }
            if let job = step.job, settings.jobEvents {
                let status = AgentJobStatus(rawValue: job.status) ?? .running
                let runs = (0..<(job.runs ?? 1)).map { AgentRun(ask: job.title, startedAt: now.addingTimeInterval(Double(-$0))) }
                let request = job.request.map { AgentApprovalRequest(id: "req-\(Int(t * 10))", kind: .question, summary: $0) }
                let record = AgentJobRecord(id: job.id, kind: .job, title: job.title, task: job.title, harness: .claudeCode, model: nil,
                                            provider: "harness-login", status: status, createdAt: now, updatedAt: now, runs: runs,
                                            pendingRequest: request, folderPath: "/tmp/jobs/\(job.id)")
                log.append("\(stamp(t))  job \(job.id): \(status.rawValue)")
                let changes = agents.changes(for: .job(record), now: now)
                for id in changes.withdraw { await feed(.withdraw(id), at: t) }
                for event in changes.post { await feed(.post(event), at: t) }
            }
            if let report = step.report, settings.jobEvents {
                let outcome = AgentJobReport.Outcome(rawValue: report.outcome) ?? .done
                var made = AgentJobReport(jobID: report.jobID, run: report.run ?? 1, title: report.title, outcome: outcome, spoken: report.spoken,
                                          files: report.file.map { [$0] } ?? [], question: report.question, startedAt: now, finishedAt: now)
                made.routineID = report.routineID
                log.append("\(stamp(t))  job \(report.jobID) reported: \(outcome.rawValue)")
                for event in agents.changes(for: .report(made), now: now).post { await feed(.post(event), at: t) }
            }
            if let dictation = step.dictation {
                // The report the dictation controller hands over, shaped like the inserter's: what was copied and
                // whether the clipboard write worked.
                let outcome: InsertionOutcome = switch dictation.result {
                case "focusLost": .copiedToClipboard(.focusLost)
                case "noTarget": .copiedToClipboard(.noTarget)
                case "clipboardFailed": .copiedToClipboard(.pasteboardWriteFailed)
                case "accessibility": .refused(.accessibilityPermission)
                default: .inserted(.accessibilityValue)
                }
                let copied: Bool
                let result: DictationResult
                switch outcome {
                case .inserted: (copied, result) = (false, .typed(appName: "TextEdit"))
                case .copiedToClipboard(let why): (copied, result) = (why != .pasteboardWriteFailed, .copiedToClipboard(why))
                case .refused(let why): (copied, result) = (true, .refused(why))
                case .nothingToInsert: (copied, result) = (false, .nothingHeard)
                }
                let insertion = InsertionReport(outcome: outcome, attempts: [], insertedText: dictation.text, copiedToClipboard: copied, target: nil)
                let report = DictationSessionReport(rawTranscript: dictation.text, cleanup: nil, insertion: insertion, focus: nil, result: result)
                log.append("\(stamp(t))  dictation ended: \(dictation.result)")
                if let event = DictationLiveEvents.event(for: report, now: now) { await feed(.post(event), at: t) }
            }
            if let path = step.deniedDocument {
                let document = ActiveDocument(kind: .pdf, reference: path, source: .file, accessDenied: true)
                log.append("\(stamp(t))  document read refused: \(path)")
                if let event = folderNotice.event(for: document, now: now) {
                    await feed(.post(event), at: t)
                } else {
                    log.append("\(stamp(t))  folder notice not shown (\(folderNotice.isSuppressed ? "turned off" : "shown recently"))")
                }
            }
            if let reply = step.reply {
                let kind = TurnKind(rawValue: reply.kind ?? "voice") ?? .voice
                let output: OutputSoundState = reply.muted ? .muted : .audible
                let outcome: NarrationOutcome = reply.cutOff == true
                    ? .cutOff(by: .escape, heard: 0, cutLine: 0, total: reply.lines.count) : .completed
                if settings.copiesReplyWhenMuted,
                   let text = MutedReplyPolicy.textToCopy(kind: kind, spokenLines: reply.lines, speaksTypedAnswers: reply.speaksTypedAnswers ?? false,
                                                          output: output, outcome: outcome) {
                    clipboard = text
                    log.append("\(stamp(t))  reply copied to the clipboard (sound off)")
                    await feed(.post(MutedReplyPolicy.event(copied: text, lineCount: reply.lines.count, now: now)), at: t)
                } else {
                    log.append("\(stamp(t))  reply \(reply.cutOff == true ? "cut off" : "heard") (\(kind.rawValue), \(reply.muted ? "muted" : "sound on")); nothing copied")
                }
            }
            if let level = step.usage, let kind = UsageLimitAlert.Kind(rawValue: level) {
                let status = UsageLimitStatus(level: kind == .warned ? .warning : .reached, period: .day, spentUSD: kind == .warned ? 4.1 : 5.02,
                                              limitUSD: 5, stops: kind == .stopped)
                let alert = UsageLimitAlert(id: "usage:day:\(UsageFormat.day(now)):\(kind.rawValue)", kind: kind, status: status)
                log.append("\(stamp(t))  usage limit \(kind.rawValue)")
                await feed(.post(UsageLiveEvents.event(for: alert, now: now)), at: t)
            }
            if let provider = step.providerDown {
                let error = ProviderUnavailableError(diagnosis: ProviderDiagnosis(providerID: provider.lowercased(), providerName: provider,
                                                                                  host: "\(provider.lowercased()).example", purpose: .brain,
                                                                                  verdict: .networkBlocked, probe: "timed out", failure: "connect"),
                                                     underlying: "timed out")
                log.append("\(stamp(t))  provider \(provider) unreachable")
                if let event = providers.event(for: error, now: now) { await feed(.post(event), at: t) }
            }
            if let list = step.browsers {
                let peers = list.map { BrowserPeer(id: $0, session: "s", profileId: "p", origin: "chrome-extension://x", browser: $0,
                                                  extensionVersion: nil, connectedAt: now, lastSeen: now) }
                log.append("\(stamp(t))  browsers connected: \(list.isEmpty ? "none" : list.joined(separator: ", "))")
                for event in browsers.changes(peers: peers, now: now) { await feed(.post(event), at: t) }
            }
            if let task = step.takeover {
                let offer = TakeoverOffer(id: "drive-\(Int(t * 10))", brief: TakeoverBrief(task: task), offeredAt: now)
                log.append("\(stamp(t))  take-over driving: \(task)")
                if let event = TakeoverLiveEvents.event(for: .driving(offer), detail: nil, dryRun: false, now: now) { await feed(.post(event), at: t) }
                await feed(.stoppable(.takeover), at: t)
            }
            if step.takeoverEnds == true {
                log.append("\(stamp(t))  take-over ended")
                await feed(.withdraw(TakeoverLiveEvents.eventID), at: t)
                await feed(.stoppable(nil), at: t)
            }
            if let on = step.alwaysOn {
                var display = AlwaysOnDisplay(state: on ? .on : .off)
                display.voice = .listening
                log.append("\(stamp(t))  always-on \(on ? "listening" : "off")")
                if let event = AlwaysOnLiveEvents.event(for: display, hint: "Triple-tap Control ends it", now: now) {
                    await feed(.post(event), at: t)
                } else {
                    await feed(.withdraw(AlwaysOnLiveEvents.eventID), at: t)
                }
            }
            if let target = step.stoppable { await feed(.stoppable(NotchStopTarget(rawValue: target)), at: t) }
            if step.stop == true { await feed(.stop, at: t) }
            if let point = step.pointer, point.count == 2 {
                lastPointer = CGPoint(x: point[0], y: point[1])
                await feed(pointerInput(lastPointer!), at: t)
            }
            if let click = step.click {
                let current = presenter.current?.event.id
                switch click {
                case "notch": await feed(.clickNotch(display: displayID), at: t)
                case "outside": await feed(.clickOutside, at: t)
                case "composer": await feed(.openChat(display: displayID), at: t)
                case "event": if let current { await feed(.clickEvent(current), at: t) }
                case "close": if let current { await feed(.dismiss(current), at: t) }
                default:
                    if click.hasPrefix("tab:"), let tab = NotchTab(rawValue: String(click.dropFirst(4))) { await feed(.selectTab(tab), at: t) }
                }
            }
            if step.key == "escape" { await feed(.escape, at: t) }
            if let text = step.type { await feed(.submitText(text), at: t) }
            if let action = step.action, let current = presenter.current?.event.id {
                await feed(.perform(eventID: current, actionID: action), at: t)
            }
        }
        let end = (script.steps.map(\.at).max() ?? 0) + (script.tail ?? 2)
        await advance(to: end, from: &t)
        if let current = presenter.current {
            log.append("\(stamp(t))  on screen at the end: \(current.event.title) — \(current.event.subtitle(now: clock.now) ?? "")")
        }
        return Result(log: log, effects: effects, surfaces: surfaces, presenter: presenter, folderNoticeShowCount: folderNotice.showCount,
                      folderNoticeSuppressed: folderNotice.isSuppressed, clipboard: clipboard)
    }

    public static func describe(_ effect: NotchEffect) -> String {
        switch effect {
        case .openURL(let url): "open \(url.absoluteString)"
        case .openJob(let id): "show job \(id)"
        case .revealFile(let file): "reveal \(file)"
        case .suppress(let kind): "turn off \(kind.rawValue)"
        case .submit(let text): "ask “\(text)”"
        case .focusComposer: "focus the composer"
        case .openHome: "open Home"
        case .openSettings: "open Settings"
        case .openSettingsPage(let page): "open Settings → \(page)"
        case .stop(let target): "stop \(target.rawValue)"
        case .openOnboarding: "open onboarding"
        case .shown(let id): "shown \(id)"
        case .dismissed(let id): "dismissed \(id)"
        }
    }
}

/// The simulator's clock, read by the calendar service from another isolation domain.
final class SimulatedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
