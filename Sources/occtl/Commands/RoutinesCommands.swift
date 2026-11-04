import Foundation
import OpenClickyKit

/// `occtl routines …`: the routines Settings → Routines shows, from a terminal. Edits go to routines.json, which a
/// running app picks up before its next scheduling pass; `run` starts a run here with the app's agent settings
/// (approval mode, agent folder, the agent slot's model and effort) and follows it.
enum RoutinesCommands {
    static let help = """
    Usage:
      occtl routines list                                   every routine with its schedule and status
      occtl routines show <id>                              one routine, its last failure and its runs
      occtl routines add <title> --task <task> (--every MIN | --at HH:MM [--days 1,2,3,4,5] | --cron "m h dom mon dow")
                         [--harness codex|claude-code]
      occtl routines run <id> [--yes]                       start a run now and follow it to the end (--yes approves every request)
      occtl routines pause <id> | resume <id> | delete <id>
    """

    static let routines = OcctlCommand(name: "routines", usage: "routines <list|show|add|run|pause|resume|delete> …  scheduled agent tasks") { args in
        guard let sub = args.first else { fail(help) }
        let options = Options(Array(args.dropFirst()))
        switch sub {
        case "list": await list()
        case "show": try await show(options)
        case "add": try await add(options)
        case "run": try await run(options)
        case "pause": try await setPaused(options, true)
        case "resume": try await setPaused(options, false)
        case "delete", "rm": try await delete(options)
        case "help", "-h", "--help": print(help)
        default: fail(help)
        }
    }

    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        static let valued: Set<String> = ["--task", "--every", "--at", "--days", "--cron", "--harness"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.valued.contains(arg) {
                    guard index + 1 < args.count else { fail("\(arg) needs a value.") }
                    values[arg] = args[index + 1]
                    index += 2
                } else if arg.hasPrefix("--") {
                    flags.insert(arg)
                    index += 1
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        func id() -> String {
            guard let id = positional.first else { fail(RoutinesCommands.help) }
            return id
        }
    }

    // MARK: Setup

    /// The manager and scheduler the app would use: Settings → Agents' folder and approval mode, the config's agent slot.
    struct Environment {
        var preferences: AgentPreferences
        var paths: AgentPaths
        var manager: AgentManager
        var scheduler: RoutineScheduler
    }

    static func loadedConfig() -> OpenClickyConfig {
        let file = AgentPaths.default.root.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .heyClickyLike }
        do { return try OpenClickyConfig.load(from: file) } catch { fail("Couldn't read \(file.path): \(error)") }
    }

    static func environment() -> Environment {
        let preferences = AgentPreferences.load(from: AgentPreferences.url())
        let paths = preferences.paths()
        let config = loadedConfig()
        let credentials = KeychainCredentialStore()
        let mode = preferences.approvalMode
        let manager = AgentManager(store: AgentJobStore(paths: paths)) { preference in
            try AgentLaunchSettings.fromConfig(config, credentials: credentials, harness: preference.harness, forceLogin: preference.login,
                                               approvalMode: mode, mcpServers: AgentMCPDiscovery.current())
        }
        let scheduler = RoutineScheduler(store: RoutineStore(url: paths.routines)) { routine, run in
            try await manager.runRoutine(routine, runNumber: run)
        }
        return Environment(preferences: preferences, paths: paths, manager: manager, scheduler: scheduler)
    }

    // MARK: Commands

    static func list() async {
        let env = environment()
        let summaries = RoutineSummary.make(routines: await env.scheduler.list(), jobs: AgentJobStore(paths: env.paths).all())
        guard !summaries.isEmpty else {
            print("No routines yet. Add one with: occtl routines add <title> --task <task> --every 60")
            return
        }
        for summary in summaries {
            let routine = summary.routine
            print("\(routine.id)  \(routine.title)")
            print("    \(routine.schedule.phrase) · \(summary.statusLine()) · \(summary.lastRunLine())")
            if let failure = summary.lastFailure { print("    last failure: \(AgentText.shorten(failure, limit: 160))") }
        }
    }

    static func show(_ options: Options) async throws {
        let env = environment()
        let id = options.id()
        let summaries = RoutineSummary.make(routines: await env.scheduler.list(), jobs: AgentJobStore(paths: env.paths).all())
        guard let summary = summaries.first(where: { $0.routine.id == id }) else { throw RoutineError.notFound(id) }
        let routine = summary.routine
        print("\(routine.title)  (\(routine.id))")
        print("Task: \(routine.task)")
        print("Schedule: \(routine.schedule.phrase)\(routine.harness.map { " · harness \($0.rawValue)" } ?? "")")
        print("Status: \(summary.statusLine())")
        print("\(summary.lastRunLine())")
        if let job = routine.jobID, let record = AgentJobStore(paths: env.paths).all().first(where: { $0.id == job }) {
            print("Job folder: \(record.folderPath)")
        }
        if let failure = summary.lastFailure { print("Last failure: \(failure)") }
        print("Runs (\(summary.runs.count), newest first):")
        let formatter = ISO8601DateFormatter()
        for run in summary.runs {
            let took = run.finishedAt.map { String(format: " %.0fs", $0.timeIntervalSince(run.startedAt)) } ?? ""
            print("  \(formatter.string(from: run.startedAt))  \(run.statusText)\(took)  \(run.jobID)#\(run.runIndex)\(run.spoken.map { "  \(AgentText.shorten($0, limit: 90))" } ?? "")")
        }
    }

    static func add(_ options: Options) async throws {
        let title = options.positional.joined(separator: " ")
        guard let task = options.values["--task"], !task.isEmpty else { fail("A routine needs --task.\n\(help)") }
        let schedule: RoutineSchedule
        if let every = options.values["--every"] {
            guard let minutes = Int(every) else { fail("--every takes minutes, like --every 30.") }
            schedule = .every(minutes: minutes)
        } else if let at = options.values["--at"] {
            guard let time = TimeOfDay(at) else { fail("--at takes HH:MM, like --at 09:00.") }
            let days = try options.values["--days"].map { text -> [Int] in
                let parsed = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !parsed.isEmpty else { throw RoutineError.invalid("--days takes numbers 0 (Sunday) to 6 (Saturday), like 1,2,3,4,5.") }
                return parsed
            }
            schedule = .daily(time, weekdays: days)
        } else if let cron = options.values["--cron"] {
            schedule = .cron(cron)
        } else {
            fail("Give a schedule: --every MIN, --at HH:MM or --cron \"…\".")
        }
        var harness: HarnessKind?
        if let name = options.values["--harness"] {
            guard let kind = HarnessKind(rawValue: name) else { fail("Unknown harness \(name). Use codex or claude-code.") }
            harness = kind
        }
        let routine = try await environment().scheduler.create(title: title, task: task, schedule: schedule, harness: harness)
        print("Added \(routine.id) \"\(routine.title)\": \(routine.schedule.phrase), first run \(routine.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never").")
    }

    static func run(_ options: Options) async throws {
        // The harness runs as a child of this process, so occtl has to stay until the run ends. Refused before
        // anything is counted: leaving early used to mark the routine as run while its job never started.
        if options.flags.contains("--no-follow") {
            fail("occtl runs the routine itself, so it stays until the run ends; --no-follow isn't supported. Use Settings → Routines → Run Now to start one in the background.")
        }
        let env = environment()
        let id = options.id()
        print("Approval: \(env.preferences.approvalMode == .fullAccess ? "full access (Settings → Agents)" : "ask (Settings → Agents)")")
        let updates = await env.manager.subscribe()
        let config = loadedConfig()
        await env.manager.setUsageRecorder(.installed(config: { config }))
        let jobID = try await env.scheduler.runNow(id)
        print("Routine \(id) → job \(jobID)")
        let ok = await AgentCommands.follow(jobID, manager: env.manager, updates: updates, autoApprove: options.flags.contains("--yes"))
        // The app's coordinator records outcomes for its own runs; this run is ours to record.
        await env.scheduler.recordOutcome(routineID: id, outcome: ok ? .completed : .failed)
        exit(ok ? 0 : 1)
    }

    static func setPaused(_ options: Options, _ paused: Bool) async throws {
        let routine = try await environment().scheduler.setPaused(options.id(), paused)
        print("\(routine.title): \(paused ? "paused" : "resumed")\(paused ? "" : ", next run \(routine.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")").")
    }

    static func delete(_ options: Options) async throws {
        let id = options.id()
        try await environment().scheduler.delete(id)
        print("Deleted routine \(id). Its job folder is kept.")
    }
}
