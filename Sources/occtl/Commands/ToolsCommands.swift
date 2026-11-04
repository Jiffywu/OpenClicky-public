import Foundation
import OpenClickyKit

/// `occtl tools …`: list the local app tools and call one by hand.
enum ToolsCommands {
    static let usage = """
    Usage:
      occtl tools list [--json]                                 every app tool, its flags and status label
      occtl tools call [--dry-run] [--spotify-web-api] <name> [json]
                                                                run one tool now and print its JSON result
      occtl tools upcoming [--dry-run] [minutes]                the meeting the countdown would show (default 15)
      occtl tools status                                        calendar permission and music apps on this Mac

      --dry-run          use in-memory fakes: nothing opens, plays, copies or reads your calendar; prints the
                         AppleScript and URLs a real call would use. Calendar results come from sample events.
      --spotify-web-api  resolve song names with Spotify's Web API, using your own client id and secret
                         (occtl key set spotify-client-id / spotify-client-secret). Off by default.
    """

    static let tools = OcctlCommand(name: "tools", usage: "tools <list|call|upcoming|status>  local app tools the brain can call") { args in
        guard let sub = args.first else { fail(usage) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": list(rest)
        case "call": await call(rest)
        case "upcoming": await upcoming(rest)
        case "status": await status()
        default: fail(usage)
        }
    }

    // MARK: list

    static func list(_ args: [String]) {
        let toolbox = AppToolbox.standard(.live())
        if args.contains("--json") {
            let entries: [JSONValue] = toolbox.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.spec.description),
                    "parameters": tool.spec.parameters,
                    "defers_until_narration_ends": .bool(tool.defersUntilNarrationEnds),
                    "needs_follow_up_round": .bool(tool.needsFollowUpRound),
                    "read_only": .bool(tool.isReadOnly),
                    "status_label": .string(tool.statusLabel),
                ]
            }
            print(pretty(.array(entries)))
            return
        }
        let width = toolbox.tools.map(\.name.count).max() ?? 0
        for tool in toolbox.tools {
            var flags: [String] = []
            if tool.defersUntilNarrationEnds { flags.append("deferred until narration ends") }
            if tool.needsFollowUpRound { flags.append("model reads the result") }
            if tool.isReadOnly { flags.append("read-only") }
            print("\(tool.name.padding(toLength: width, withPad: " ", startingAt: 0))  \"\(tool.statusLabel)\"  [\(flags.joined(separator: ", "))]")
        }
        print("\ninsert_text is not here: the dictation part owns it.")
    }

    // MARK: call

    static func call(_ args: [String]) async {
        var dryRun = false
        var useWebAPI = false
        var positional: [String] = []
        for arg in args {
            switch arg {
            case "--dry-run": dryRun = true
            case "--spotify-web-api": useWebAPI = true
            default: positional.append(arg)
            }
        }
        guard let name = positional.first, positional.count <= 2 else { fail(usage) }
        let json = positional.count == 2 ? positional[1] : "{}"

        let fakes = dryRun ? DryRun() : nil
        let environment: AppToolEnvironment
        if let fakes {
            environment = fakes.environment
        } else {
            let catalog = useWebAPI ? SpotifyWebAPICatalog.fromCredentials(CoreCommands.store) : nil
            if useWebAPI, catalog == nil {
                FileHandle.standardError.write(Data("note: no Spotify client id and secret in the Keychain; searching without the Web API.\n".utf8))
            }
            environment = .live(spotifyCatalog: catalog)
        }
        if dryRun, useWebAPI {
            FileHandle.standardError.write(Data("note: --spotify-web-api is ignored in a dry run (no network).\n".utf8))
        }
        let toolbox = AppToolbox.standard(environment)

        let callID = "occtl-1"
        let dispatch = toolbox.prepare(ToolCall(id: callID, name: name, arguments: json))
        switch dispatch {
        case .finished(let result):
            note("dispatch: answered without running")
            await output(result)
        case .runNow(let tool):
            note("dispatch: runs now\(tool.needsFollowUpRound ? "; the model reads the result in another round" : "")")
            await output(await toolbox.run(ToolCall(id: callID, name: name, arguments: json)), fakes: fakes)
        case .deferUntilNarrationEnds(let action, let queued):
            note("dispatch: deferred until the narration ends; the model is told \(queued.jsonString). occtl runs it now.")
            await output(await toolbox.run(action), fakes: fakes)
        }
    }

    static func output(_ result: AppToolResult, fakes: DryRun? = nil) async {
        if let fakes { await fakes.report() }
        print(pretty(result.json))
        if !result.succeeded { exit(1) }
    }

    // MARK: upcoming

    static func upcoming(_ args: [String]) async {
        let dryRun = args.contains("--dry-run")
        let numbers = args.filter { $0 != "--dry-run" }
        guard numbers.count <= 1 else { fail(usage) }
        let minutes = numbers.first.map { Int($0) } ?? 15
        guard let minutes, (1...24 * 60).contains(minutes) else { fail("minutes must be a whole number from 1 to 1440") }

        let environment = dryRun ? DryRun().environment : .live()
        let service = CalendarService(store: environment.calendar, clock: environment.clock)
        let state = await service.upcomingMeeting(withinMinutes: minutes)
        let timeZone = environment.clock.timeZone
        switch state {
        case .noAccess(let authorization):
            print(pretty(["status": "no_access", "permission": .string(authorization.rawValue),
                          "message": "The countdown stays hidden without calendar access; it never asks for it itself."]))
        case .nothingSoon:
            print(pretty(["status": "nothing_soon", "within_minutes": .number(Double(minutes))]))
        case .upcoming(let meeting):
            var object: [String: JSONValue] = [
                "status": "upcoming",
                "title": .string(meeting.event.title),
                "starts_at": .string(CalendarTimeFormat.timestamp(meeting.event.start, timeZone: timeZone)),
                "minutes_until_start": .number(Double(meeting.minutesUntilStart)),
                "has_started": .bool(meeting.hasStarted),
            ]
            if let action = meeting.action {
                object["action"] = ["kind": .string(action.kind), "url": .string(action.url.absoluteString)]
            }
            print(pretty(.object(object)))
        }
    }

    // MARK: status

    static func status() async {
        let environment = AppToolEnvironment.live()
        let workspace = environment.workspace
        let calendar = await environment.calendar.authorization()
        var object: [String: JSONValue] = [
            "calendar_permission": .string(calendar.rawValue),
            "spotify": .string(await appState(AppBundleID.spotify, workspace)),
            "music": .string(await appState(AppBundleID.music, workspace)),
            "spotify_web_api": "off unless --spotify-web-api is given",
        ]
        if calendar == .notDetermined {
            object["calendar_note"] = "occtl cannot show the calendar prompt; allow Calendars from the OpenClicky app."
        }
        print(pretty(.object(object)))
    }

    static func appState(_ bundleID: String, _ workspace: any AppToolWorkspace) async -> String {
        guard await workspace.isInstalled(bundleID: bundleID) else { return "not installed" }
        return await workspace.isRunning(bundleID: bundleID) ? "running" : "installed"
    }

    // MARK: Helpers

    static func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.jsonString() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Fakes for `--dry-run`: records what a call would do, in order. Spotify starts closed and plays whatever it was
/// last told to (so the cold-start path shows); Music reports a library match. Sample calendar events are placed
/// around the current time.
struct DryRun {
    let log = DryRunLog()
    let workspace: DryRunWorkspace
    let pasteboard = RecordingPasteboard()
    let scripts: ScriptedAppleScriptRunner
    let calendar: InMemoryCalendarStore

    init(now: Date = Date()) {
        let log = log
        let recorder = RecordingWorkspace(running: [])
        workspace = DryRunWorkspace(inner: recorder, log: log)
        scripts = ScriptedAppleScriptRunner { source, _ in
            log.add("would run AppleScript:\n" + source.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
            return log.simulatedReply(to: source, spotifyRunning: recorder.isRunningNow(AppBundleID.spotify))
        }
        let work = CalendarInfo(id: "sample-work", title: "Work (sample)")
        let home = CalendarInfo(id: "sample-home", title: "Home (sample)")
        // Calendar arithmetic, not fixed hours, so the samples stay put across a daylight-saving change.
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int, hour: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        }
        self.calendar = InMemoryCalendarStore(calendars: [home, work], defaultCalendarID: home.id, events: [
            CalendarEventRecord(id: "sample-1", title: "Design review", start: now.addingTimeInterval(10 * 60),
                                end: now.addingTimeInterval(40 * 60), location: "https://zoom.us/j/123456789", calendar: work),
            CalendarEventRecord(id: "sample-2", title: "Dentist", start: day(1, hour: 9), end: day(1, hour: 10),
                                location: "1 Main St, Springfield", calendar: home),
            CalendarEventRecord(id: "sample-3", title: "Conference", start: day(2), end: day(4), isAllDay: true, calendar: work),
        ])
    }

    var environment: AppToolEnvironment {
        AppToolEnvironment(workspace: workspace, pasteboard: pasteboard, appleScript: scripts, calendar: calendar,
                           sleep: { _ in })
    }

    /// Prints, on stderr, what a real call would have done.
    func report() async {
        for line in log.lines { ToolsCommands.note(line) }
        for text in pasteboard.copies { ToolsCommands.note("would copy \(text.count) characters to the clipboard") }
        for draft in await calendar.savedDrafts {
            ToolsCommands.note("would save \"\(draft.title)\" to \(draft.calendar?.title ?? "the default calendar")")
        }
    }
}

/// The dry run's ordered log, and the simulated player.
final class DryRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var lastPlayed: String?

    var lines: [String] { lock.withLock { entries } }

    func add(_ line: String) { lock.withLock { entries.append(line) } }

    func played(_ uri: String) { lock.withLock { lastPlayed = uri } }

    func simulatedReply(to source: String, spotifyRunning: Bool) -> String {
        let sep = "\u{1F}"
        if source.contains("play track \""), let start = source.range(of: "play track \"") {
            let rest = source[start.upperBound...]
            if let end = rest.firstIndex(of: "\"") { played(String(rest[..<end])) }
            return ""
        }
        if source.contains("application \"Spotify\" is running") {
            guard spotifyRunning else { return "not_running" }
            guard let uri = lock.withLock({ lastPlayed }) else { return "paused" }
            return ["playing", uri, "(dry run)", "(dry run)"].joined(separator: sep)
        }
        if source.contains("search library playlist 1") || source.contains("every user playlist") {
            return ["ok", "(dry run match)", "(dry run)"].joined(separator: sep)
        }
        if source.contains("application \"Music\" is running") {
            return ["playing", "0000000000000000", "(dry run match)", "(dry run)"].joined(separator: sep)
        }
        return ""
    }
}

/// Logs each open and reveal in the shared order, and remembers `spotify:` URIs as what Spotify now plays.
struct DryRunWorkspace: AppToolWorkspace {
    let inner: RecordingWorkspace
    let log: DryRunLog

    func openInDefaultBrowser(_ url: URL) async -> Bool {
        log.add("would open in the default browser: \(url.absoluteString)")
        return await inner.openInDefaultBrowser(url)
    }

    func open(_ url: URL) async -> Bool {
        log.add("would open: \(url.absoluteString)")
        if url.scheme == "spotify", SpotifyURI(url.absoluteString) != nil { log.played(url.absoluteString) }
        return await inner.open(url)
    }

    func revealInFinder(_ fileURL: URL) async -> Bool {
        log.add("would reveal in Finder: \(fileURL.path)")
        return await inner.revealInFinder(fileURL)
    }

    func isInstalled(bundleID: String) async -> Bool { await inner.isInstalled(bundleID: bundleID) }
    func isRunning(bundleID: String) async -> Bool { await inner.isRunning(bundleID: bundleID) }
}
