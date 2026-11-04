import Foundation

/// A job-finished notification, built from a report. The app posts it (UNUserNotificationCenter); occtl prints it.
public struct AgentNotice: Sendable, Hashable, Identifiable {
    public var id: String
    public var jobID: String
    public var title: String
    public var body: String
    /// Waiting on the user: worth a sound and a badge, not only a banner.
    public var needsAttention: Bool

    public init(id: String, jobID: String, title: String, body: String, needsAttention: Bool) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.body = body
        self.needsAttention = needsAttention
    }

    public static func make(from report: AgentJobReport) -> AgentNotice {
        let name = report.agentName ?? report.title
        let title: String = switch report.outcome {
        case .done: "\(name) is done"
        case .needsYou: "\(name) needs you"
        case .failed: "\(name) didn't finish"
        case .stopped: "\(name) stopped"
        }
        var body = report.question.map { "\(report.spoken) \($0)" } ?? report.spoken
        if report.outcome == .done, let file = report.files.first {
            body += " · " + (URL(string: file).flatMap { $0.scheme?.hasPrefix("http") == true ? $0.host : nil } ?? URL(fileURLWithPath: file).lastPathComponent)
        }
        return AgentNotice(id: report.id, jobID: report.jobID, title: title, body: AgentText.shorten(body, limit: 240),
                           needsAttention: report.outcome == .needsYou)
    }
}

/// The silent context the voice brain gets about background work each turn: what is running, what waits on the
/// user, and what finished recently. Plain text, a few lines per job.
public enum AgentBrainContext {
    public static func note(jobs: [AgentJobRecord], running: Set<String>, recentLimit: Int = 4, now: Date = Date()) -> String? {
        let active = jobs.filter { $0.status.isActive || running.contains($0.id) }
        let recent = jobs.filter { !($0.status.isActive || running.contains($0.id)) }.prefix(recentLimit)
        guard !active.isEmpty || !recent.isEmpty else { return nil }
        var lines = ["[Your jobs] Background work, for your eyes only (don't read this out). Use job_id with sessions_send, sessions_interrupt, sessions_answer_request, read_job and show_result."]
        for record in active {
            var line = "- \(record.id) \"\(record.title)\""
            if let name = record.agentName { line += " (kept agent \(name))" }
            switch record.status {
            case .needsYou:
                line += ": WAITING ON THE USER"
                if let request = record.pendingRequest { line += " to approve: \(request.summary) [request_id \(request.id)]" }
                if let step = record.waitingStep {
                    // With routines to approve too, the step's "I'm done" is the approval without a request_id.
                    line += (record.pendingRequest != nil ? "; and" : "") + " to do a step: \(step.step) ("
                        + (record.pendingRequest != nil ? "approve with no request_id" : "approve") + " when they say it's done)"
                } else if record.pendingRequest == nil, let question = record.report?.question { line += ", asked: \(question)" }
            default:
                line += ": WORKING NOW"
                if let progress = record.lastProgress { line += ", latest: \(AgentText.shorten(progress, limit: 120))" }
                if let said = record.lastSaid { line += ", it said: \"\(AgentText.shorten(said, limit: 160))\"" }
                if let seconds = record.lastRunDuration(now: now) { line += " (\(Int(seconds))s)" }
            }
            lines.append(line)
        }
        for record in recent {
            var line = "- \(record.id) \"\(record.title)\": \(record.status.rawValue)"
            if let spoken = record.report?.spoken, !spoken.isEmpty { line += ", said: \(AgentText.shorten(spoken, limit: 140))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// Wires the agent subsystem together for the app (and occtl): the job manager, the routine scheduler, the brain
/// tools, report batching for report turns, and finished-job notices. Owns no UI.
public actor AgentCoordinator {
    public nonisolated let manager: AgentManager
    public nonisolated let routines: RoutineScheduler
    public nonisolated let tools: AgentTools
    private let batcher: AgentReportBatcher
    private let onNotice: @Sendable (AgentNotice) async -> Void
    private let limits: @Sendable () -> AgentLimits
    private let maintenanceInterval: TimeInterval
    /// Runs once at `start()`, before anything can launch (hooks the manager up to connected apps and the labeler).
    private var prepare: (@Sendable (AgentManager) async -> Void)?
    private var listener: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?

    /// - Parameters:
    ///   - onReports: a batch of finished runs for one report turn (`AgentReportTurn.note(for:)`).
    ///   - onNotice: one notice per finished run.
    /// - Parameters:
    ///   - turnAssets: the calling turn's screenshots and attachments, for `sessions_spawn`.
    ///   - limits: read for every maintenance sweep (the idle end, the cleanup).
    ///   - maintenanceInterval: seconds between sweeps after the one at start.
    public init(manager: AgentManager, routineStore: RoutineStore, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = { Date() }, reportDelay: TimeInterval = 1.5,
                presentResult: (@Sendable (AgentJobReport) async -> Void)? = nil,
                turnAssets: (@Sendable () -> AgentTurnAssets?)? = nil,
                limits: @escaping @Sendable () -> AgentLimits = { AgentLimits() }, maintenanceInterval: TimeInterval = 3600,
                prepare: (@Sendable (AgentManager) async -> Void)? = nil,
                routineConditions: (any RoutineRunConditions)? = nil,
                openFile: (@Sendable (URL) async -> Bool)? = nil, openLink: (@Sendable (String?) async -> Bool)? = nil,
                onReports: @escaping @Sendable ([AgentJobReport]) async -> Void,
                onNotice: @escaping @Sendable (AgentNotice) async -> Void = { _ in }) {
        self.prepare = prepare
        self.manager = manager
        let routines = RoutineScheduler(store: routineStore, calendar: calendar, now: now, conditions: routineConditions) { [manager] routine, run in
            try await manager.runRoutine(routine, runNumber: run)
        }
        self.routines = routines
        tools = AgentTools(manager: manager, routines: routines, presentResult: presentResult, turnAssets: turnAssets,
                           openFile: openFile, openLink: openLink)
        batcher = AgentReportBatcher(delay: reportDelay, deliver: onReports)
        self.onNotice = onNotice
        self.limits = limits
        self.maintenanceInterval = maintenanceInterval
    }

    /// The coordinator the app runs: settings come from the current config at every launch (with the key read
    /// from the credential store then), and the browser bridge's MCP server is offered whenever it is running.
    ///
    /// - Parameter extraInstructions: read at every launch and appended to the job's instructions (the active skills
    ///   section from `SkillsLibrary.skillsAgentInstructions()`).
    ///   - connectedApps: exported for every launch (connector MCP servers, the Connected apps and Obsidian
    ///     sections, `OBSIDIAN_VAULT_PATH`); nil offers none.
    ///   - catalog: the model catalog the brain-fast labeler is resolved against; nil skips launch labels.
    ///   - turnAssets: the calling turn's screenshots and attachments, for `sessions_spawn`.
    public static func live(paths: AgentPaths = .default, config: @escaping @Sendable () -> OpenClickyConfig,
                            credentials: any CredentialStore, approvalMode: @escaping @Sendable () -> AgentApprovalMode = { .ask },
                            extraInstructions: @escaping @Sendable () -> String? = { nil },
                            connectedApps: AgentConnectedApps? = nil, catalog: (@Sendable () -> ModelCatalog)? = nil,
                            turnAssets: (@Sendable () -> AgentTurnAssets?)? = nil,
                            presentResult: (@Sendable (AgentJobReport) async -> Void)? = nil,
                            openFile: (@Sendable (URL) async -> Bool)? = nil, openLink: (@Sendable (String?) async -> Bool)? = nil,
                            fileDiffs: (@Sendable () -> Bool)? = nil,
                            onReports: @escaping @Sendable ([AgentJobReport]) async -> Void,
                            onNotice: @escaping @Sendable (AgentNotice) async -> Void = { _ in }) -> AgentCoordinator {
        let manager = AgentManager(store: AgentJobStore(paths: paths)) { preference in
            var settings = try AgentLaunchSettings.fromConfig(config(), credentials: credentials, harness: preference.harness,
                                                              forceLogin: preference.login, approvalMode: approvalMode(),
                                                              mcpServers: AgentMCPDiscovery.current())
            settings.extraInstructions = extraInstructions()
            return settings
        }
        return AgentCoordinator(
            manager: manager, routineStore: RoutineStore(url: paths.routines), presentResult: presentResult, turnAssets: turnAssets,
            limits: { config().agentLimits ?? AgentLimits() },
            prepare: { manager in
                if let fileDiffs { await manager.setFileDiffs(fileDiffs) }
                if let connectedApps { await manager.setLaunchExtras { _ in await connectedApps.extras() } }
                await manager.setUsageRecorder(.installed(config: config))
                if let catalog {
                    await manager.setLabeler(ConfiguredLaunchLabeler {
                        try? ModelAgentLaunchLabeler(factory: EngineFactory(config: config(), catalog: catalog(), credentials: credentials))
                    })
                }
            },
            routineConditions: SystemRoutineConditions(),
            openFile: openFile, openLink: openLink,
            onReports: onReports, onNotice: onNotice)
    }

    /// Marks jobs left running by a previous launch as stopped, starts listening, and starts the routine clock.
    public func start() async {
        guard listener == nil else { return }
        if let prepare {
            self.prepare = nil
            await prepare(manager)
        }
        await connectRoutines()
        await manager.recoverInterruptedJobs()
        let updates = await manager.subscribe()
        listener = Task { [weak self] in
            for await update in updates {
                guard case .report(let report) = update else { continue }
                await self?.handle(report)
            }
        }
        await routines.start()
        let limits = self.limits
        let interval = maintenanceInterval
        maintenance = Task { [manager] in
            while !Task.isCancelled {
                await manager.maintain(limits: limits())
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    /// Stops routines and every running harness (app quit).
    public func stop() async {
        listener?.cancel()
        listener = nil
        maintenance?.cancel()
        maintenance = nil
        await routines.stop()
        await manager.shutdown()
    }

    private func handle(_ report: AgentJobReport) async {
        if let routineID = report.routineID {
            let outcome: AgentTurnOutcome = switch report.outcome {
            case .done, .needsYou: .completed
            case .failed: .failed
            case .stopped: .interrupted
            }
            await routines.recordOutcome(routineID: routineID, outcome: outcome)
        }
        await batcher.add(report)
        await onNotice(AgentNotice.make(from: report))
    }

    /// Lets jobs see the current routines in their instructions and apply the routines they propose (after the user's
    /// yes): created routines run in the proposing job's folder (or its kept agent).
    public func connectRoutines() async {
        let routines = self.routines
        await manager.setRoutinesNote { [routines] jobID in RoutineNotes.jobNote(await routines.list(), jobID: jobID) }
        await manager.setRoutineApplier { [routines] request, job in
            try await Self.apply(request, job: job, routines: routines)
        }
    }

    /// Applies one routine request for `job`. Changes find the routine by title, preferring the job's own.
    public static func apply(_ request: AgentRoutineRequest, job: AgentJobRecord, routines: RoutineScheduler) async throws -> String {
        if request.action == .create {
            guard let task = request.task, let schedule = request.schedule else { throw RoutineError.invalid("A new routine needs a task and a schedule.") }
            let made = try await routines.create(title: request.title, task: task, schedule: schedule, agent: job.isKept ? job.id : nil,
                                                 harness: job.harness, jobID: job.isKept ? nil : job.id)
            return "Created the routine \"\(made.title)\" (\(made.schedule.phrase))"
        }
        let all = await routines.list()
        func sameTitle(_ routine: AgentRoutine) -> Bool { routine.title.caseInsensitiveCompare(request.title) == .orderedSame || routine.id == request.title }
        guard let routine = all.first(where: { sameTitle($0) && ($0.jobID == job.id || $0.agent == job.id) }) ?? all.first(where: sameTitle) else {
            throw RoutineError.notFound(request.title)
        }
        switch request.action {
        case .create:
            return ""
        case .update:
            let changed = try await routines.update(routine.id, title: request.newTitle, task: request.task, schedule: request.schedule)
            return "Changed the routine \"\(changed.title)\" (\(changed.schedule.phrase))"
        case .pause:
            try await routines.setPaused(routine.id, true)
            return "Paused the routine \"\(routine.title)\""
        case .resume:
            try await routines.setPaused(routine.id, false)
            return "Resumed the routine \"\(routine.title)\""
        case .delete:
            try await routines.delete(routine.id)
            return "Deleted the routine \"\(routine.title)\""
        }
    }

    /// OpenClicky's MCP tools for jobs (web search, progress, routines), for the loopback server.
    public nonisolated func jobTools(lookups: @escaping @Sendable () -> LookupTools?) -> AgentJobMCPTools {
        AgentJobMCPTools(manager: manager, routines: routines, lookups: lookups)
    }

    /// `[Your routines]` context for the brain's next turn (the runtime passes it on only when it changed).
    public func routinesContext(now: Date = Date()) async -> String {
        RoutineNotes.brainNote(await routines.list(), now: now)
    }

    /// `[Your jobs]` context for the brain's next turn.
    public func brainContext(now: Date = Date()) async -> String? {
        let jobs = await manager.jobs()
        var running = Set<String>()
        for record in jobs where await manager.isRunning(record.id) { running.insert(record.id) }
        return AgentBrainContext.note(jobs: jobs, running: running, now: now)
    }

    /// The notes for the brain's next turn: `[Your jobs]` and `[Your Clickys]` (each only when there is something to say).
    public func brainNotes(now: Date = Date()) async -> [String] {
        let jobs = await manager.jobs()
        var running = Set<String>()
        for record in jobs where await manager.isRunning(record.id) { running.insert(record.id) }
        return [AgentBrainContext.note(jobs: jobs, running: running, now: now),
                AgentBrainContext.clickysNote(jobs: jobs, running: running, now: now)].compactMap { $0 }
    }
}
