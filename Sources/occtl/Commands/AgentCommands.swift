import Foundation
import OpenClickyKit

enum AgentCommands {
    static let agent = OcctlCommand(
        name: "agent",
        usage: "agent <run|send|list|show|maintain|label|login|learn|organize|clickys|archive|diffs> …  background jobs (occtl agent help)"
    ) { args in
        guard let sub = args.first else { fail(help) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "run": try await run(rest)
        case "send": try await send(rest)
        case "list": list()
        case "show": try show(rest)
        case "maintain": try await maintain(rest)
        case "label": try await label(rest)
        case "login": try login(rest)
        case "learn":
            guard let id = rest.first else { fail("Usage: occtl agent learn <job-id>") }
            await learn(from: id, manager: makeManager(parse([])))
        case "organize", "clickys", "archive", "unarchive", "diffs": try await AgentUXCommands.run(sub, rest)
        case "help", "-h", "--help": print(help)
        default: fail(help)
        }
    }

    static let help = """
    Usage:
      occtl agent run <task> [--harness codex|claude-code] [--login] [--model M] [--title T]
                             [--keep NAME] [--role R] [--yes] [--full-access]
          Start a background job and stream its progress until it finishes.
          --login        use the harness's own sign-in (ChatGPT for Codex, Claude subscription) instead of a key
          --keep NAME    run inside the kept agent NAME (created if new)
          --yes          approve every request the agent makes (default: ask on a terminal, else decline)
          --full-access  no sandbox and no approvals (HeyClicky's behavior)
          --no-browser   don't offer the browser bridge's MCP server even if it is running
          --no-apps      don't offer connected apps (connectors, Composio, the Obsidian vault)
          --job-tools    serve OpenClicky's job tools (openclicky_web_search with the configured search service,
                         openclicky_progress, openclicky_routines) on a loopback MCP server for this run, as the app does
          --image FILE   attach an image as the run's task asset (repeatable; a file named screen*.jpg is shown
                         to the agent as the user's screenshot)
          --attach FILE  list a file for the agent to read (repeatable)
          --label        name the job and write its start line with the brain-fast slot
          --learn        when the job is done, let brain-fast keep a how-to from its report in memory (as the app does)
          --diffs        keep before-and-after diffs of the files it changes (Settings → Agents developer preview)
          Jobs get the active skills and the memory brief (OPENCLICKY_SKILLS_DIR, OPENCLICKY_MEMORY_DIR move them).
      occtl agent send <job-id|agent> <message> [--yes]   follow up on a job and stream the new run
      occtl agent list                                    jobs and kept agents, newest first
      occtl agent show <job-id|agent> [--transcript]      details, report, files, state and recent events; with
                                                          --transcript, every run's turn rebuilt from events.jsonl
      occtl agent maintain [--dry-run]                    the periodic sweep: assume, idle end, 30-day cleanup
      occtl agent label <task>                            what the brain-fast labeler names a task
      occtl agent login codex                             sign Codex in inside OpenClicky's own CODEX_HOME
      occtl agent learn <job-id>                          keep a how-to from a finished job in memory (brain-fast)
    \(AgentUXCommands.help)
    """

    // MARK: Options

    struct Options {
        var positional: [String] = []
        var harness: HarnessKind?
        var login = false
        var model: String?
        var title: String?
        var keep: String?
        var role: String?
        var yes = false
        var fullAccess = false
        var noBrowser = false
        var noApps = false
        var images: [URL] = []
        var attachments: [URL] = []
        var label = false
        var dryRun = false
        var learn = false
        var jobTools = false
        var diffs = false
    }

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var index = 0
        func value() -> String {
            index += 1
            guard index < args.count else { fail("\(args[index - 1]) needs a value.") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--harness":
                let name = value()
                guard let kind = HarnessKind(rawValue: name) else { fail("Unknown harness \(name). Use codex or claude-code.") }
                options.harness = kind
            case "--login": options.login = true
            case "--model": options.model = value()
            case "--title": options.title = value()
            case "--keep": options.keep = value()
            case "--role": options.role = value()
            case "--yes", "-y": options.yes = true
            case "--full-access": options.fullAccess = true
            case "--no-browser": options.noBrowser = true
            case "--no-apps": options.noApps = true
            case "--label": options.label = true
            case "--dry-run": options.dryRun = true
            case "--image", "--attach":
                let url = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else { fail("No file at \(url.path).") }
                if arg == "--image" { options.images.append(url) } else { options.attachments.append(url) }
            case "--learn": options.learn = true
            case "--job-tools": options.jobTools = true
            case "--diffs": options.diffs = true
            default:
                if arg.hasPrefix("--") { fail("Unknown option \(arg).\n\(help)") }
                options.positional.append(arg)
            }
            index += 1
        }
        return options
    }

    static func loadConfig() -> OpenClickyConfig {
        // Same file as OpenClickyConfig.defaultURL unless OPENCLICKY_SUPPORT_DIR relocates the support folder. With no
        // file, the built-in defaults apply; a file that exists but can't be read stops here, so a typo in it never
        // turns into an unrelated error about the defaults' credentials. OPENCLICKY_CONFIG names another file.
        let file = ProcessInfo.processInfo.environment["OPENCLICKY_CONFIG"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? AgentPaths.default.root.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { return try OpenClickyConfig.load(from: file) } catch { fail("Couldn't read \(file.path): \(error)") }
        }
        return .heyClickyLike
    }

    /// The manager occtl runs jobs with: the config's agent slot, the browser bridge's MCP server when it runs, and
    /// (unless --no-apps) the connected apps exported at launch, as in the app.
    static func makeManager(_ options: Options) async -> AgentManager {
        let config = loadConfig()
        let credentials = KeychainCredentialStore()
        let mode: AgentApprovalMode = options.fullAccess ? .fullAccess : .ask
        let skills = SkillsCommands.library(), memory = MemoryStore(directory: MemoryCommand.directory)
        let toolServer = JobToolServerBox()
        let manager = AgentManager(store: AgentJobStore()) { preference in
            var settings = try AgentLaunchSettings.fromConfig(config, credentials: credentials, harness: preference.harness ?? options.harness,
                                               forceLogin: preference.login || options.login, model: options.model, approvalMode: mode,
                                               mcpServers: (options.noBrowser ? [] : AgentMCPDiscovery.current()) + toolServer.offered)
            settings.extraInstructions = [skills.skillsAgentInstructions(), MemoryAgentBrief.section(store: memory)]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            return settings
        }
        if !options.noApps {
            let apps = AgentConnectedApps(environment: ConnectorEnvironment(credentials: credentials))
            await manager.setLaunchExtras { _ in await apps.extras() }
        }
        await SkillsCommands.useSkills(manager, includesConnectedApps: !options.noApps)
        if options.jobTools {
            let routines = RoutineScheduler(store: RoutineStore(url: AgentPaths.default.routines)) { routine, run in
                try await manager.runRoutine(routine, runNumber: run)
            }
            await manager.setRoutineApplier { request, job in try await AgentCoordinator.apply(request, job: job, routines: routines) }
            await manager.setRoutinesNote { jobID in RoutineNotes.jobNote(await routines.list(), jobID: jobID) }
            let tools = AgentJobMCPTools(manager: manager, routines: routines, lookups: {
                LookupTools(services: LookupServices.make(config: (try? ServicesConfig.load()) ?? .defaults, credentials: credentials))
            })
            do {
                let server = try AgentJobToolServer(tools: tools.tools)
                toolServer.set(server, offered: try server.start())
                print("MCP: \(AgentJobToolServer.serverName) (\(AgentJobMCPTools.names.joined(separator: ", ")))")
            } catch {
                fail("Couldn't start the job tools server: \(error)")
            }
        }
        await manager.setUsageRecorder(.installed(config: { config }))
        if options.label, let labeler = makeLabeler(config: config, credentials: credentials) { await manager.setLabeler(labeler) }
        // File diffs as in the app: Settings → Agents' developer preview, or --diffs.
        if options.diffs || AgentPreferences.load(from: AgentPreferences.url()).developerFileDiffs { await manager.setFileDiffs { true } }
        return manager
    }

    static func makeLabeler(config: OpenClickyConfig, credentials: any CredentialStore) -> ModelAgentLaunchLabeler? {
        let catalog = ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(config.models)
        do {
            return try ModelAgentLaunchLabeler(factory: EngineFactory(config: config, catalog: catalog, credentials: credentials))
        } catch {
            FileHandle.standardError.write(Data("No launch labels: \(error)\n".utf8))
            return nil
        }
    }

    // MARK: run / send

    static func run(_ args: [String]) async throws {
        let options = parse(args)
        let task = options.positional.joined(separator: " ")
        guard !task.isEmpty else { fail("Usage: occtl agent run <task> [options]") }
        let manager = await makeManager(options)
        let updates = await manager.subscribe()
        // An image named like a screenshot is handed over the way the app hands over the turn's screen.
        let screens = options.images.filter { $0.lastPathComponent.lowercased().hasPrefix("screen") && ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        let request = AgentSpawnRequest(task: task, title: options.title, agent: options.keep, agentRole: options.role, keep: options.keep != nil,
                                        preference: AgentLaunchPreference(harness: options.harness, login: options.login),
                                        images: options.images.filter { !screens.contains($0) }, attachments: options.attachments,
                                        screenshots: screens.compactMap { try? Data(contentsOf: $0) })
        let result = try await manager.spawn(request, waitForStart: true)
        let record = result.record
        print("Job \(record.id) · \(record.harness.rawValue)\(record.model.map { " · \($0)" } ?? "")\(record.provider == AgentLaunchSettings.loginProviderID ? " · harness login" : "")")
        print("Folder: \(record.folderPath)")
        if !options.noBrowser, let browser = AgentMCPDiscovery.browserServer() { print("MCP: \(browser.name) (browser bridge)") }
        let ok = await follow(record.id, manager: manager, updates: updates, autoApprove: options.yes)
        if ok, options.learn { await learn(from: record.id, manager: manager) }
        exit(ok ? 0 : 1)
    }

    /// The how-to learner the app runs on finished jobs (brain-fast), on this job's latest report.
    static func learn(from jobID: String, manager: AgentManager) async {
        guard let record = await manager.jobs().first(where: { $0.id == jobID }) else { fail("No job \(jobID).") }
        let report = AgentJobReport.make(record: record, outputs: [])
        if let learned = report.learned, !learned.isEmpty {
            // The job wrote down what it learned: saved as is, no model pass.
            let outcomes = AgentHowToLearner.saveLearned(learned, store: MemoryStore(directory: MemoryCommand.directory))
            for (item, outcome) in zip(learned, outcomes) { print("How-to (from the job's learned block): \(item.topic): \(outcome)") }
            return
        }
        print("Reading the report of \(record.id) and \(report.files.count) file(s): \(report.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        let config = (try? OpenClickyConfig.load(from: AgentPaths.default.root.appendingPathComponent("config.json"))) ?? .heyClickyLike
        let factory = EngineFactory(config: config, catalog: (try? ModelCatalog.builtIn().merging(config.models)) ?? ModelCatalog(models: []),
                                    credentials: KeychainCredentialStore())
        do {
            let learner = try AgentHowToLearner(factory: factory)
            let outcome = try await learner.learn(from: report, task: record.runs.last?.ask ?? record.task,
                                                  store: MemoryStore(directory: MemoryCommand.directory))
            print("How-to: " + (outcome.map { "\($0)" } ?? "nothing worth keeping from this job"))
        } catch {
            print("How-to: not learned (\(error))")
        }
    }

    static func send(_ args: [String]) async throws {
        let options = parse(args)
        guard options.positional.count >= 2 else { fail("Usage: occtl agent send <job-id|agent> <message> [--yes]") }
        let manager = await makeManager(options)
        let updates = await manager.subscribe()
        let (record, disposition) = try await manager.send(to: options.positional[0], message: options.positional.dropFirst().joined(separator: " "), waitForStart: true)
        print("Job \(record.id): follow-up \(disposition.rawValue)")
        let ok = await follow(record.id, manager: manager, updates: updates, autoApprove: options.yes)
        exit(ok ? 0 : 1)
    }

    /// Prints progress until the job's run finishes; answers approvals. Ctrl-C stops the job (twice quits).
    static func follow(_ id: String, manager: AgentManager, updates: AsyncStream<AgentManagerUpdate>, autoApprove: Bool) async -> Bool {
        let interrupts = InterruptCounter()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            if interrupts.increment() > 1 { exit(130) }
            FileHandle.standardError.write(Data("\nStopping the job (Ctrl-C again to quit now)…\n".utf8))
            Task { await manager.interrupt(id) }
        }
        source.resume()
        let started = Date()
        var lastLine = ""
        // A follow-up keeps the job's earlier start line; only a new one is printed.
        var lastCue = await manager.job(id)?.startCue
        for await update in updates {
            switch update {
            case .event(let jobID, let event) where jobID == id:
                if case .approvalRequested(let request) = event {
                    let decision = await decide(request, autoApprove: autoApprove)
                    _ = try? await manager.answer(id, requestID: request.id, decision: decision)
                    continue
                }
                if case .error(let message, false) = event { FileHandle.standardError.write(Data("  (retrying: \(message))\n".utf8)) }
                guard let line = event.progressLine, line != lastLine else { continue }
                lastLine = line
                print(String(format: "[%5.1fs] ", Date().timeIntervalSince(started)) + line)
            case .launched(let record) where record.id == id:
                print("Launched: \(record.title)")
            case .job(let record) where record.id == id && record.startCue != nil && record.startCue != lastCue:
                lastCue = record.startCue
                print("Labeled: \(record.title) · \(record.startCue ?? "")")
            case .report(let report) where report.jobID == id:
                printReport(report)
                source.cancel()
                return report.outcome == .done || report.outcome == .needsYou
            default:
                continue
            }
        }
        return false
    }

    /// Keeps the job tools server alive for the run and hands it to each launch once started.
    final class JobToolServerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var server: AgentJobToolServer?
        private var _offered: AgentMCPServer?
        var offered: [AgentMCPServer] { lock.withLock { _offered.map { [$0] } ?? [] } }
        func set(_ server: AgentJobToolServer, offered: AgentMCPServer) { lock.withLock { self.server = server; _offered = offered } }
    }

    final class InterruptCounter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()
        func increment() -> Int { lock.withLock { count += 1; return count } }
    }

    static func decide(_ request: AgentApprovalRequest, autoApprove: Bool) async -> AgentApprovalDecision {
        print("? The agent asks: \(request.summary)\(request.reason.map { " (\($0))" } ?? "")")
        if request.kind == .question {
            if let options = request.options { print("  Options: \(options.joined(separator: " · "))") }
            guard isatty(STDIN_FILENO) != 0 else { return .answer("Use your best judgment.") }
            print("  Your answer: ", terminator: "")
            fflush(stdout)
            let text = await Task.detached { readLine() ?? "" }.value
            return .answer(text.isEmpty ? "Use your best judgment." : text)
        }
        if autoApprove {
            print("  approved (--yes)")
            return .approve(always: false)
        }
        guard isatty(STDIN_FILENO) != 0 else {
            print("  declined (not a terminal; pass --yes to approve)")
            return .decline
        }
        print("  Allow? [y]es / [a]lways / [N]o: ", terminator: "")
        fflush(stdout)
        let answer = await Task.detached { readLine() ?? "" }.value.lowercased()
        switch answer {
        case "y", "yes": return .approve(always: false)
        case "a", "always": return .approve(always: true)
        default: return .decline
        }
    }

    static func printReport(_ report: AgentJobReport) {
        print("")
        print("== \(report.title) · \(report.outcome.rawValue) · \(report.durationSeconds)s")
        print("Say: \(report.spoken)")
        if let question = report.question { print("Question: \(question)") }
        if let error = report.error, report.outcome == .failed { print("Error: \(error)") }
        for file in report.files { print("File: \(file)") }
        for step in report.nextSteps { print("Next: \(step)") }
        if let kind = report.kind { print("Kind: \(kind.rawValue)") }
    }

    // MARK: list / show

    static func list() {
        let records = AgentJobStore().all()
        guard !records.isEmpty else { print("No jobs yet."); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        for record in records {
            let kind = record.isKept ? "agent" : "job"
            let line = [record.id, kind, record.status.rawValue, record.harness.rawValue, formatter.string(from: record.updatedAt), record.title]
            print(line.joined(separator: "  "))
            if let progress = record.status.isActive ? record.lastProgress : record.report?.spoken, !progress.isEmpty {
                print("    \(AgentText.shorten(progress, limit: 110))")
            }
        }
    }

    static func show(_ args: [String]) throws {
        guard let reference = args.first else { fail("Usage: occtl agent show <job-id|agent>") }
        let store = AgentJobStore()
        guard let record = store.load(id: reference) ?? store.load(id: AgentJobStore.slug(reference)) else {
            fail(AgentManagerError.unknownJob(reference).description)
        }
        print("\(record.title)  [\(record.status.rawValue)]")
        print("id: \(record.id)\(record.isKept ? " (kept agent\(record.agentRole.map { ", \($0)" } ?? ""))" : "")")
        print("harness: \(record.harness.rawValue)  model: \(record.model ?? "harness default")  provider: \(record.provider)")
        print("folder: \(record.folderPath)")
        if let thread = record.threadID { print("thread: \(thread)") }
        print("usage: \(record.usage.input) in (\(record.usage.cachedInput) cached) / \(record.usage.output) out")
        if let request = record.pendingRequest { print("waiting on: \(request.summary)") }
        if let error = record.error { print("error: \(error)") }
        print("\nRuns:")
        for (index, run) in record.runs.enumerated() {
            let seconds = run.finishedAt.map { Int($0.timeIntervalSince(run.startedAt)) }
            print("  \(index + 1). \(run.outcome?.rawValue ?? "running")\(seconds.map { " in \($0)s" } ?? ""): \(AgentText.shorten(run.ask.replacingOccurrences(of: "\n", with: " "), limit: 100))")
        }
        if let report = record.report {
            print("\nReport (\(report.title ?? "untitled")):")
            print("  say: \(report.spoken)")
            if !report.markdown.isEmpty { print(report.markdown.split(separator: "\n").map { "  | \($0)" }.joined(separator: "\n")) }
            for file in report.files { print("  file: \(file)") }
            for step in report.nextSteps { print("  next: \(step)") }
            if let question = report.question { print("  question: \(question)") }
        }
        let outputs = store.outputs(of: record)
        if !outputs.isEmpty { print("\nOutput folder:\n" + outputs.map { "  \($0)" }.joined(separator: "\n")) }
        if let kind = record.deliverableKind { print("kind: \(kind.rawValue)") }
        if let ledger = record.ledger, !ledger.isEmpty || ledger.compactions > 0 {
            print("\nState (state.md, \(ledger.compactions) compaction(s)):")
            for entry in ledger.sideEffects { print("  done: \(entry.text)") }
            for entry in ledger.answers { print("  user: \(entry.text)") }
            for (path, change) in ledger.files.sorted(by: { $0.key < $1.key }) { print("  file: \(path) (\(change))") }
        }
        if args.contains("--transcript") {
            printTranscript(store.transcript(of: record))
            return
        }
        let events = store.events(of: record, limit: 40)
        if !events.isEmpty {
            print("\nRecent events:")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for entry in events.suffix(15) {
                let text = entry.event?.progressLine ?? entry.text.map { AgentText.firstLine($0, limit: 100) } ?? entry.outcome?.rawValue ?? ""
                print("  \(formatter.string(from: entry.t)) \(entry.kind)\(text.isEmpty ? "" : ": \(text)")")
            }
        }
    }

    /// The turns Home → Agents shows, as text.
    static func printTranscript(_ transcript: AgentTranscript) {
        for turn in transcript.turns {
            print("\nRun \(turn.number)\(turn.outcome.map { " (\($0.rawValue))" } ?? ""): \(AgentText.shorten(turn.ask.replacingOccurrences(of: "\n", with: " "), limit: 200))")
            for step in turn.plan { print("  plan [\(step.status.rawValue)] \(step.step)") }
            for step in turn.steps { print("  \(step.kind.rawValue): \(AgentText.firstLine(step.text, limit: 160))") }
            for file in turn.files { print("  file: \(file.path) (\(file.change))") }
            if let report = turn.report {
                print("  say: \(report.spoken)")
                if let answer = report.answer?.outcome { print("  answer: \(answer)") }
                for next in report.nextSteps { print("  next: \(next)") }
            }
            if let error = turn.error { print("  error: \(error)") }
        }
    }

    // MARK: maintain / label

    static func maintain(_ args: [String]) async throws {
        let options = parse(args)
        var limits = loadConfig().agentLimits ?? AgentLimits()
        if options.dryRun {
            // Report what is due without changing anything.
            let now = Date()
            for record in AgentJobStore().all() {
                let quiet = now.timeIntervalSince(record.updatedAt)
                if record.status == .needsYou {
                    let action = quiet >= limits.idleEndSeconds ? "would end (idle)" : quiet >= limits.assumeAfterSeconds ? "would assume" : "waiting"
                    print("\(record.id): needs-you for \(Int(quiet / 60)) min · \(action)")
                } else if !record.status.isActive, record.cleanedAt == nil, quiet >= TimeInterval(limits.cleanupAfterDays) * 86_400 {
                    print("\(record.id): idle \(Int(quiet / 86_400)) days · would clean up")
                }
            }
            return
        }
        limits.assumeAfterSeconds = 0 // occtl exits right away; it can't follow a job it would restart.
        let manager = await makeManager(Options())
        let result = await manager.maintain(limits: limits)
        print("ended: \(result.ended.isEmpty ? "none" : result.ended.joined(separator: ", "))")
        print("cleaned: \(result.cleaned.isEmpty ? "none" : result.cleaned.joined(separator: ", "))")
    }

    static func label(_ args: [String]) async throws {
        let task = parse(args).positional.joined(separator: " ")
        guard !task.isEmpty else { fail("Usage: occtl agent label <task>") }
        guard let labeler = makeLabeler(config: loadConfig(), credentials: KeychainCredentialStore()) else { exit(1) }
        let started = Date()
        let answer = await labeler.answer(for: task)
        guard let labels = answer.flatMap(ModelAgentLaunchLabeler.parse) else {
            fail("The labeler gave nothing usable (model \(labeler.model), effort \(labeler.reasoningEffort ?? "default")): \(answer.map { "\"\($0.prefix(300))\"" } ?? "no answer within \(Int(labeler.timeout)) s")")
        }
        print("model: \(labeler.model)")
        print("title: \(labels.title)")
        print("start: \(labels.startCue)")
        print(String(format: "seconds: %.2f", Date().timeIntervalSince(started)))
    }

    // MARK: login

    static func login(_ args: [String]) throws {
        switch args.first {
        case "codex":
            guard let codex = HarnessEnvironment.locate(.codex) else { fail(AgentHarnessError.executableNotFound(.codex).description) }
            let home = AgentPaths.default.codexHome
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            print("Signing Codex in for OpenClicky (CODEX_HOME=\(home.path)). Codex stores its own sign-in there.")
            let process = Process()
            process.executableURL = codex
            process.arguments = ["login"] + args.dropFirst()
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        case "claude-code", "claude":
            print("Claude Code keeps one sign-in for your user. Run `claude` once and sign in with your Claude account; OpenClicky's --login runs use it.")
        default:
            fail("Usage: occtl agent login codex")
        }
    }
}
