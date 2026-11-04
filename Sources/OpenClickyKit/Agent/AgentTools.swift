import Foundation

/// The tools the voice brain calls to run background work: JSON-schema `ToolSpec`s and the code that executes
/// them against the `AgentManager` (and the routine scheduler, when there is one). Every result is a JSON object
/// with a `status`.
public struct AgentTools: Sendable {
    public let manager: AgentManager
    public let routines: RoutineScheduler?
    /// Shows a job's result card (the app supplies this; deferred until narration finishes is the app's choice).
    public var presentResult: (@Sendable (AgentJobReport) async -> Void)?
    /// The calling turn's screenshots and attached files (the voice loop records them as it captures the screen);
    /// `sessions_spawn` gives them to the new job as task assets.
    public var turnAssets: (@Sendable () -> AgentTurnAssets?)?
    /// Opens Settings → Browser (`openclicky://settings/browser`) when the user agrees to connect Chrome for a job,
    /// and returns the setup steps for the brain to explain. Nil: the steps come back without opening anything.
    public var openBrowserSetup: (@Sendable () async -> [String])?
    /// Opens a file from a job's or kept agent's folder for the user (`open_artifact`); nil leaves that tool out.
    public var openFile: (@Sendable (URL) async -> Bool)?
    /// Opens an `openclicky://` link for `open_agent_dashboard` (nil asks to close the dashboard); nil leaves that
    /// tool out.
    public var openLink: (@Sendable (String?) async -> Bool)?

    public init(manager: AgentManager, routines: RoutineScheduler? = nil, presentResult: (@Sendable (AgentJobReport) async -> Void)? = nil,
                turnAssets: (@Sendable () -> AgentTurnAssets?)? = nil, openFile: (@Sendable (URL) async -> Bool)? = nil,
                openLink: (@Sendable (String?) async -> Bool)? = nil) {
        self.manager = manager
        self.routines = routines
        self.presentResult = presentResult
        self.turnAssets = turnAssets
        self.openFile = openFile
        self.openLink = openLink
    }

    public static let names: Set<String> = Set(["sessions_spawn", "sessions_send", "sessions_interrupt", "session_status",
                                               "sessions_answer_request", "find_jobs", "read_job", "show_result", "routines"])
        .union(clickyToolNames)

    // MARK: Specs

    public var specs: [ToolSpec] {
        var specs = [Self.spawnSpec, Self.sendSpec, Self.interruptSpec, Self.statusSpec, Self.answerSpec, Self.findSpec, Self.readSpec,
                     Self.showSpec]
        if routines != nil { specs.append(Self.routinesSpec) }
        specs += clickySpecs
        return specs
    }

    static let jobReference: JSONValue = ["type": "string", "description": "The job_id from an earlier result, or a kept agent's name."]

    public static let spawnSpec = ToolSpec(
        name: "sessions_spawn",
        description: """
        Start background work on the user's Mac: research, files, data, code, anything that takes more than a moment. \
        It runs in its own folder while you keep talking; you hear back when it finishes. Write the task as a complete \
        brief in the user's words plus anything you know that helps (names, links, what they're looking at). To give \
        work to a kept agent, pass its name in agent; set keep to create a new kept agent for lasting work.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "task": ["type": "string", "description": "The complete brief for the agent."],
                "title": ["type": "string", "description": "Two to six words naming the job."],
                "agent": ["type": "string", "description": "Name of a kept agent to run this in."],
                "agent_role": ["type": "string", "description": "With keep: what the new kept agent is for."],
                "keep": ["type": "boolean", "description": "Create the named kept agent if it doesn't exist."],
                "include_screen": ["type": "boolean", "description": "Attach this turn's screenshot (default true). Set false when the screen has nothing to do with the task."],
                "attachments": ["type": "array", "items": ["type": "string"], "description": "Absolute paths of files the user pointed at, given to the agent as inputs."],
            ],
            "required": ["task"],
            "additionalProperties": false,
        ])

    public static let sendSpec = ToolSpec(
        name: "sessions_send",
        description: "Send a follow-up to a job or kept agent: more instructions while it works, or a new request in the same folder after it finished.",
        parameters: [
            "type": "object",
            "properties": ["job_id": jobReference, "message": ["type": "string", "description": "What to tell the agent."]],
            "required": ["job_id", "message"],
            "additionalProperties": false,
        ])

    public static let interruptSpec = ToolSpec(
        name: "sessions_interrupt",
        description: "Stop a job's current work. Files it already made stay in its folder.",
        parameters: ["type": "object", "properties": ["job_id": jobReference], "required": ["job_id"], "additionalProperties": false])

    public static let statusSpec = ToolSpec(
        name: "session_status",
        description: "What background jobs are doing: the ones running now, the ones waiting on the user, and recent ones. Pass job_id for one job in detail.",
        parameters: ["type": "object", "properties": ["job_id": jobReference], "additionalProperties": false])

    public static let answerSpec = ToolSpec(
        name: "sessions_answer_request",
        description: """
        Answer a job that is waiting on the user: approve or decline what it asked to do (including a routine it \
        proposed), answer its question, or approve when the user did the step it waits for (decline if they won't). A \
        chrome_setup request means the job needs the user's Chrome connected: approve when they agree (OpenClicky opens \
        Settings → Browser and you get the steps to walk them through; the job carries on once Chrome connects), \
        decline when they'd rather not (the job finishes without the browser).
        """,
        parameters: [
            "type": "object",
            "properties": [
                "job_id": jobReference,
                "request_id": ["type": "string", "description": "The pending request's id from session_status (optional)."],
                "decision": ["type": "string", "enum": ["approve", "decline", "answer"]],
                "always": ["type": "boolean", "description": "With approve: allow the same thing again without asking for the rest of this job."],
                "answer": ["type": "string", "description": "With answer: the user's reply."],
            ],
            "required": ["job_id", "decision"],
            "additionalProperties": false,
        ])

    public static let findSpec = ToolSpec(
        name: "find_jobs",
        description: "Search earlier background jobs and kept agents by topic. Use it when the user mentions earlier work.",
        parameters: [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Words to look for. Empty lists the most recent jobs."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 20],
            ],
            "additionalProperties": false,
        ])

    public static let readSpec = ToolSpec(
        name: "read_job",
        description: "Read a job's full report (with its runs and files), or its recent conversation with the agent. Use it before answering questions about what a job found.",
        parameters: [
            "type": "object",
            "properties": [
                "job_id": jobReference,
                "detail": ["type": "string", "enum": ["report", "conversation"], "description": "report (default) or conversation."],
            ],
            "required": ["job_id"],
            "additionalProperties": false,
        ])

    public static let showSpec = ToolSpec(
        name: "show_result",
        description: "Show the user a finished job's result card (its report and files). Returns what the card shows.",
        parameters: ["type": "object", "properties": ["job_id": jobReference], "required": ["job_id"], "additionalProperties": false])

    public static let routinesSpec = ToolSpec(
        name: "routines",
        description: """
        Manage routines: tasks OpenClicky re-runs on a schedule while it is open. Schedules: every_minutes, or at \
        (HH:MM, local time) with optional days (0 = Sunday … 6 = Saturday), or a five-field cron string.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["list", "create", "update", "pause", "resume", "delete", "run_now"]],
                "routine_id": ["type": "string"],
                "title": ["type": "string"],
                "task": ["type": "string", "description": "The brief each run gets."],
                "every_minutes": ["type": "integer", "minimum": 1],
                "at": ["type": "string", "description": "HH:MM"],
                "days": ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 6]],
                "cron": ["type": "string"],
                "agent": ["type": "string", "description": "Run inside this kept agent."],
            ],
            "required": ["action"],
            "additionalProperties": false,
        ])

    // MARK: Calling

    /// Runs one tool call. Unknown tools and bad arguments come back as `{"status":"error"}` results.
    public func call(_ call: ToolCall) async -> String {
        await callJSON(name: call.name, arguments: call.arguments).jsonString()
    }

    public func callJSON(name: String, arguments: String) async -> JSONValue {
        let args: JSONValue
        do {
            args = arguments.trimmingCharacters(in: .whitespaces).isEmpty ? [:] : try JSONValue.parse(arguments)
        } catch {
            return Self.error("The arguments weren't valid JSON.")
        }
        do {
            switch name {
            case "sessions_spawn": return try await spawn(args)
            case "sessions_send": return try await send(args)
            case "sessions_interrupt": return try await interrupt(args)
            case "session_status": return await status(args)
            case "sessions_answer_request": return try await answer(args)
            case "find_jobs": return await find(args)
            case "read_job": return try await read(args)
            case "show_result": return try await show(args)
            case "routines": return try await manageRoutines(args)
            case _ where Self.clickyToolNames.contains(name): return try await callClickyTool(name, args)
            default: return ["status": "not_implemented", "message": .string("No tool named \(name).")]
            }
        } catch {
            return Self.error("\(error)")
        }
    }

    static func error(_ message: String) -> JSONValue { ["status": "error", "message": .string(message)] }

    private func required(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = args[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AgentToolError.missing(key)
        }
        return value
    }

    private func spawn(_ args: JSONValue) async throws -> JSONValue {
        var request = AgentSpawnRequest(task: try required(args, "task"), title: args["title"]?.stringValue,
                                        agent: args["agent"]?.stringValue?.nilIfEmpty, agentRole: args["agent_role"]?.stringValue,
                                        keep: args["keep"]?.boolValue ?? false)
        let assets = AgentTurnAssets.forBrainTurn ?? turnAssets?()
        if args["include_screen"]?.boolValue ?? true { request.screenshots = Array((assets?.screenshots ?? []).prefix(2)) }
        var attachments = assets?.attachments ?? []
        for path in args["attachments"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard url.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path), !attachments.contains(url) else { continue }
            attachments.append(url)
        }
        request.attachments = attachments
        let result = try await manager.spawn(request)
        var out: [String: JSONValue] = ["job_id": .string(result.record.id), "title": .string(result.record.title)]
        if result.alreadyStarted {
            out["status"] = "already_started"
            out["message"] = "That same task started moments ago; nothing new was started."
        } else if let sentAs = result.sentAs {
            out["status"] = "sent"
            out["sent_as"] = .string(sentAs.rawValue)
            out["message"] = .string("\(result.record.agentName ?? result.record.title) was busy, so the task went to it as a follow-up.")
        } else {
            out["status"] = "dispatched"
            out["message"] = "Started in the background. You'll hear back when it finishes; don't wait for it."
        }
        if let name = result.record.agentName { out["agent"] = .string(name) }
        if result.revived { Self.noteRevived(result.record, in: &out) }
        if result.sentAs == nil, !result.alreadyStarted {
            if !request.screenshots.isEmpty { out["screenshot_attached"] = true }
            if !request.attachments.isEmpty { out["attachments"] = .number(Double(request.attachments.count)) }
        }
        return .object(out)
    }

    private func read(_ args: JSONValue) async throws -> JSONValue {
        let reference = try required(args, "job_id")
        guard let record = await manager.job(reference) else { throw AgentManagerError.unknownJob(reference) }
        var out = Self.summary(record, running: await manager.isRunning(record.id))
        out["status"] = "ok"
        out["folder"] = .string(record.folderPath)
        if args["detail"]?.stringValue == "conversation" {
            // The same turns Home → Agents shows, rebuilt from the job's files.
            let transcript = manager.store.transcript(of: record)
            out["asks"] = .array(record.runs.suffix(8).map { .string(AgentText.shorten($0.ask, limit: 400)) })
            out["conversation"] = .array(transcript.brainLines(limit: 80))
        } else {
            if let text = try? String(contentsOf: record.folder.appendingPathComponent("report.md"), encoding: .utf8) {
                out["report"] = .string(AgentText.shorten(text, limit: 8_000))
            }
            let outputs = manager.store.outputs(of: record)
            if !outputs.isEmpty { out["files"] = .array(outputs.prefix(20).map { .string($0) }) }
            if let next = record.report?.nextSteps, !next.isEmpty { out["next"] = .array(next.map { .string($0) }) }
        }
        return .object(out)
    }

    private func send(_ args: JSONValue) async throws -> JSONValue {
        let reference = try required(args, "job_id")
        let wasArchived = await manager.job(reference)?.isArchived ?? false
        let (record, disposition) = try await manager.send(to: reference, message: try required(args, "message"))
        var out: [String: JSONValue] = ["status": "sent", "job_id": .string(record.id), "sent_as": .string(disposition.rawValue)]
        if wasArchived { Self.noteRevived(record, in: &out) }
        return .object(out)
    }

    private func interrupt(_ args: JSONValue) async throws -> JSONValue {
        let reference = try required(args, "job_id")
        guard let record = await manager.job(reference) else { throw AgentManagerError.unknownJob(reference) }
        let stopped = await manager.interrupt(record.id)
        return ["status": stopped ? "interrupted" : "not_running", "job_id": .string(record.id)]
    }

    private func status(_ args: JSONValue) async -> JSONValue {
        if let reference = args["job_id"]?.stringValue?.nilIfEmpty {
            guard let record = await manager.job(reference) else { return Self.error(AgentManagerError.unknownJob(reference).description) }
            var detail = Self.summary(record, running: await manager.isRunning(record.id))
            let recent = manager.store.events(of: record, limit: 60).compactMap { $0.event?.progressLine }.suffix(8)
            if !recent.isEmpty { detail["recent_progress"] = .array(recent.map { .string($0) }) }
            return ["status": "ok", "job": .object(detail)]
        }
        let all = await manager.jobs()
        var active: [JSONValue] = []
        var recent: [JSONValue] = []
        for record in all {
            let running = await manager.isRunning(record.id)
            if record.status.isActive || running {
                active.append(.object(Self.summary(record, running: running)))
            } else if recent.count < 6 {
                recent.append(.object(Self.summary(record, running: false)))
            }
        }
        return ["status": "ok", "active": .array(active), "recent": .array(recent)]
    }

    static func summary(_ record: AgentJobRecord, running: Bool) -> [String: JSONValue] {
        var out: [String: JSONValue] = [
            "job_id": .string(record.id), "title": .string(record.title),
            "state": .string(running && record.status == .done ? "running" : record.status.rawValue),
            "harness": .string(record.harness.rawValue),
        ]
        if let name = record.agentName { out["agent"] = .string(name) }
        if let progress = record.lastProgress { out["progress"] = .string(progress) }
        if let request = record.pendingRequest {
            var pending: [String: JSONValue] = ["request_id": .string(request.id), "kind": .string(request.kind.rawValue), "asks": .string(request.summary)]
            if let reason = request.reason { pending["reason"] = .string(reason) }
            if let options = request.options { pending["options"] = .array(options.map { .string($0) }) }
            out["pending_request"] = .object(pending)
        }
        if let report = record.report, !record.status.isActive || record.status == .needsYou {
            if !report.spoken.isEmpty { out["latest_report"] = .string(report.spoken) }
            if let question = report.question { out["question"] = .string(question) }
        }
        if let step = record.waitingStep, record.status == .needsYou {
            out["user_step"] = .string(step.step + (step.page.map { " (at \($0))" } ?? ""))
        }
        if let error = record.error, record.status == .failed { out["error"] = .string(AgentText.shorten(error, limit: 200)) }
        if let duration = record.lastRunDuration() { out["seconds"] = .number(duration.rounded()) }
        return out
    }

    private func answer(_ args: JSONValue) async throws -> JSONValue {
        let reference = try required(args, "job_id")
        let decision: AgentApprovalDecision
        switch try required(args, "decision") {
        case "approve": decision = .approve(always: args["always"]?.boolValue ?? false)
        case "decline": decision = .decline
        case "answer": decision = .answer(try required(args, "answer"))
        case let other: throw AgentToolError.invalid("decision must be approve, decline or answer (got \(other)).")
        }
        let requestID = args["request_id"]?.stringValue?.nilIfEmpty
        let setup = await manager.chromeSetupRequest(reference, answering: requestID)
        let result = try await manager.answer(reference, requestID: requestID, decision: decision)
        guard setup != nil else { return ["status": .string(result.rawValue)] }
        var out: [String: JSONValue] = ["status": .string(result.rawValue), "request": "chrome_setup"]
        if !AgentManager.approvesChromeSetup(decision) {
            out["next"] = "The job carries on without the browser."
        } else if result == .sentAsFollowUp {
            out["next"] = "The browser is already connected, so the job carries on with the website steps now."
        } else {
            let steps = await openBrowserSetup?() ?? BrowserSetupGuide.genericSteps
            out["opened"] = .string(openBrowserSetup == nil ? "" : BrowserSetupGuide.settingsURL)
            out["steps"] = .array(steps.map { .string($0) })
            out["next"] = "Walk the user through these steps briefly. The job carries on by itself once the browser connects."
        }
        return .object(out)
    }

    private func find(_ args: JSONValue) async -> JSONValue {
        let limit = min(20, max(1, args["limit"]?.intValue ?? 8))
        let found = await manager.find(args["query"]?.stringValue ?? "", limit: limit)
        let formatter = ISO8601DateFormatter()
        return ["status": "ok", "jobs": .array(found.map { record in
            var out = Self.summary(record, running: false)
            out["created_at"] = .string(formatter.string(from: record.createdAt))
            out["folder"] = .string(record.folderPath)
            return .object(out)
        })]
    }

    private func show(_ args: JSONValue) async throws -> JSONValue {
        let reference = try required(args, "job_id")
        guard let record = await manager.job(reference) else { throw AgentManagerError.unknownJob(reference) }
        guard record.report != nil || !record.status.isActive else {
            return ["status": "not_ready", "job_id": .string(record.id), "message": "It's still working; there's no result yet."]
        }
        let report = AgentJobReport.make(record: record, outputs: manager.store.outputs(of: record))
        await presentResult?(report)
        var out = report.json.objectValue ?? [:]
        out["status"] = presentResult == nil ? "ok" : "shown"
        if !report.markdown.isEmpty { out["report"] = .string(AgentText.shorten(report.markdown, limit: 4000)) }
        return .object(out)
    }

    private func manageRoutines(_ args: JSONValue) async throws -> JSONValue {
        guard let routines else { return ["status": "not_implemented", "message": "Routines aren't available here."] }
        let action = try required(args, "action")
        func schedule() throws -> RoutineSchedule? {
            if let minutes = args["every_minutes"]?.intValue { return .every(minutes: minutes) }
            if let at = args["at"]?.stringValue {
                guard let time = TimeOfDay(at) else { throw AgentToolError.invalid("at must be HH:MM (got \(at)).") }
                return .daily(time, weekdays: args["days"]?.arrayValue?.compactMap(\.intValue))
            }
            if let cron = args["cron"]?.stringValue { return .cron(cron) }
            return nil
        }
        func describe(_ routine: AgentRoutine) -> JSONValue {
            var out: [String: JSONValue] = ["routine_id": .string(routine.id), "title": .string(routine.title), "task": .string(routine.task),
                                            "schedule": .string(routine.schedule.phrase), "paused": .bool(routine.isPaused), "runs": .number(Double(routine.runCount))]
            if let next = routine.dueAt { out["next_run"] = .string(ISO8601DateFormatter().string(from: next)) }
            if let jobID = routine.jobID { out["job_id"] = .string(jobID) }
            return .object(out)
        }
        switch action {
        case "list":
            return ["status": "ok", "routines": .array(await routines.list().map(describe))]
        case "create":
            guard let schedule = try schedule() else { throw AgentToolError.invalid("create needs every_minutes, at, or cron.") }
            let routine = try await routines.create(title: args["title"]?.stringValue ?? "", task: try required(args, "task"),
                                                    schedule: schedule, agent: args["agent"]?.stringValue?.nilIfEmpty)
            return ["status": "created", "routine": describe(routine)]
        case "update":
            let routine = try await routines.update(try required(args, "routine_id"), title: args["title"]?.stringValue,
                                                    task: args["task"]?.stringValue, schedule: try schedule())
            return ["status": "updated", "routine": describe(routine)]
        case "pause", "resume":
            let routine = try await routines.setPaused(try required(args, "routine_id"), action == "pause")
            return ["status": .string(action == "pause" ? "paused" : "resumed"), "routine": describe(routine)]
        case "delete":
            try await routines.delete(try required(args, "routine_id"))
            return ["status": "deleted"]
        case "run_now":
            let jobID = try await routines.runNow(try required(args, "routine_id"))
            return ["status": "started", "job_id": .string(jobID)]
        default:
            throw AgentToolError.invalid("Unknown routines action \(action).")
        }
    }
}

enum AgentToolError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .missing(let key): "Missing \(key)."
        case .invalid(let message): message
        }
    }
}
