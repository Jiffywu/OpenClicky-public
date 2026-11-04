import Foundation

/// Runs jobs with Claude Code in print mode, streaming both ways:
/// `claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio`.
/// Verified against Claude Code 2.1.314: user messages go in as `{"type":"user",…}` lines (more can follow while a
/// turn runs), every turn ends with a `{"type":"result",…}` line, and permission prompts arrive as
/// `control_request` / `can_use_tool` lines that OpenClicky answers with `control_response`.
///
/// Bring-your-own-key: `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` in the environment, and a separate
/// `CLAUDE_CONFIG_DIR` so the user's own Claude settings, hooks and login stay out of it. Harness login: no key in
/// the environment, so Claude Code uses the subscription it is signed in with.
public struct ClaudeCodeHarness: AgentHarness {
    public let kind = HarnessKind.claudeCode

    public init() {}

    public struct Plan: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        /// The JSON passed to `--mcp-config` (tokens appear only as `${VAR}` references).
        public var mcpConfig: String
        /// The variable each MCP secret travels in (`mcpVariableAliases`): its own name → the name Claude Code reads.
        public var mcpVariables: [String: String]
    }

    /// Plain names for the MCP secrets' variables. With `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` on (every
    /// bring-your-own-key run), Claude Code withholds variables whose names look like credentials (…_TOKEN, …_KEY,
    /// …AUTH…) from `${VAR}` expansion in its MCP config as well as from its subprocesses, so a header like
    /// `Bearer ${OPENCLICKY_BROWSER_MCP_TOKEN}` went out as a bare "Bearer" and the server answered 401 (checked on
    /// 2.1.314 against a local server). The secrets therefore travel as `OPENCLICKY_MCPVAR_<n>`.
    static func mcpVariableAliases(_ servers: [AgentMCPServer]) -> [String: String] {
        let names = Set(servers.flatMap { $0.harnessSecrets.keys }).sorted()
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, "OPENCLICKY_MCPVAR_\($0.offset + 1)") })
    }

    public func plan(for launch: HarnessLaunch) throws -> Plan {
        guard let executable = HarnessEnvironment.locate(.claudeCode, override: launch.executable, environment: launch.baseEnvironment) else {
            throw AgentHarnessError.executableNotFound(.claudeCode)
        }
        var added: [String: String] = [:]
        switch launch.auth {
        case .provider(let config, let apiKey):
            guard config.dialect == .anthropicMessages else {
                throw AgentHarnessError.unsupportedProvider(
                    "Claude Code talks to Anthropic Messages providers. Give the agent slot an \(ProviderDialect.anthropicMessages.rawValue) provider, or use \(ProviderDialect.harnessLogin.rawValue).")
            }
            // Keyless gateways still need the variable set, or Claude Code goes looking for a login.
            added["ANTHROPIC_API_KEY"] = apiKey ?? "openclicky-no-key"
            if let baseURL = config.baseURL { added["ANTHROPIC_BASE_URL"] = baseURL.absoluteString }
            if let headers = config.headers, !headers.isEmpty {
                added["ANTHROPIC_CUSTOM_HEADERS"] = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            }
            added["CLAUDE_CONFIG_DIR"] = launch.paths.claudeConfig.path
            added["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            // Claude Code passes its whole environment to the agent's Bash commands, hooks and stdio MCP servers, key
            // included, unless told to strip credentials from them (checked on 2.1.314: `echo $ANTHROPIC_API_KEY`
            // in a job's Bash call prints the key without this, nothing with it). Claude Code keeps the key for its
            // own API calls.
            added["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1"
        case .harnessLogin:
            break
        }
        let aliases = Self.mcpVariableAliases(launch.mcpServers)
        for server in launch.mcpServers {
            for (name, value) in server.harnessSecrets { added[aliases[name] ?? name] = value }
        }
        // The limits Claude Code enforces itself: a Bash command's default and longest run, and when it compacts.
        if launch.limits.commandTimeoutSeconds > 0 {
            let milliseconds = String(Int(launch.limits.commandTimeoutSeconds * 1000))
            added["BASH_DEFAULT_TIMEOUT_MS"] = milliseconds
            added["BASH_MAX_TIMEOUT_MS"] = milliseconds
        }
        // Claude Code 2.1.314 accepts windows from 100k tokens up; a smaller one would be refused, so it is raised.
        if launch.limits.compactionTokens > 0 { added["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(max(100_000, launch.limits.compactionTokens)) }
        let mcpConfig = Self.mcpConfig(launch.mcpServers, aliases: aliases)

        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--permission-prompt-tool", "stdio",
                         "--setting-sources", "project,local",
                         "--strict-mcp-config", "--mcp-config", mcpConfig,
                         "--append-system-prompt", launch.instructions]
        switch launch.approvalMode {
        case .ask: arguments += ["--permission-mode", "acceptEdits"]
        case .fullAccess: arguments += ["--dangerously-skip-permissions"]
        }
        if let model = launch.model, !model.isEmpty, model != "default" { arguments += ["--model", model] }
        if let effort = launch.reasoningEffort, ["low", "medium", "high", "xhigh", "max"].contains(effort) { arguments += ["--effort", effort] }
        if let resume = launch.resumeThreadID { arguments += ["--resume", resume] }
        if launch.skills?.isEmpty == false { arguments += ["--plugin-dir", launch.paths.claudeSkillsPlugin.path] }
        let trusted = Self.trustedToolNames(launch.mcpServers)
        if !trusted.isEmpty, launch.approvalMode == .ask { arguments += ["--allowedTools", trusted.joined(separator: ",")] }
        arguments += launch.extraArguments

        let environment = HarnessEnvironment.child(
            base: launch.baseEnvironment,
            stripping: (launch.auth.isLogin ? [] : ["CLAUDE_CONFIG_DIR"])
                + ["BASH_DEFAULT_TIMEOUT_MS", "BASH_MAX_TIMEOUT_MS", "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "OPENCLICKY_MCPVAR_*"],
            adding: launch.environment.merging(added) { _, ours in ours }, executable: executable)
        return Plan(executable: executable, arguments: arguments, environment: environment, mcpConfig: mcpConfig, mcpVariables: aliases)
    }

    /// `mcp__<server>__<tool>` for each server's trusted tools (names that wouldn't survive Claude Code's naming are
    /// skipped, so a call to them is simply asked about).
    static func trustedToolNames(_ servers: [AgentMCPServer]) -> [String] {
        func plain(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }
        return servers.flatMap { server in
            plain(server.name) ? server.trustedTools.filter(plain).map { "mcp__\(server.name)__\($0)" } : []
        }
    }

    /// `{"mcpServers": {...}}` for `--mcp-config`. Bearer tokens are `${VAR}` references Claude Code expands from
    /// its environment, so the token is neither on disk nor in the process list.
    static func mcpConfig(_ servers: [AgentMCPServer], aliases: [String: String] = [:]) -> String {
        func reference(_ name: String) -> String { "${\(aliases[name] ?? name)}" }
        var entries: [String: JSONValue] = [:]
        for server in servers {
            switch server.transport {
            case .http(let url):
                var entry: [String: JSONValue] = ["type": "http", "url": .string(url.absoluteString)]
                var headers: [String: JSONValue] = [:]
                if server.bearerToken != nil { headers["Authorization"] = .string("Bearer " + reference(server.tokenEnvironmentVariable)) }
                for (header, variable) in server.secretHeaders { headers[header] = .string(reference(variable)) }
                if !headers.isEmpty { entry["headers"] = .object(headers) }
                entries[server.name] = .object(entry)
            case .stdio(let command, let arguments):
                var entry: [String: JSONValue] = ["type": "stdio", "command": .string(command), "args": .array(arguments.map { .string($0) })]
                var env = server.environment.mapValues { JSONValue.string($0) }
                for variable in server.forwardedVariables { env[variable] = .string(reference(variable)) }
                if !env.isEmpty { entry["env"] = .object(env) }
                entries[server.name] = .object(entry)
            }
        }
        return JSONValue.object(["mcpServers": .object(entries)]).jsonString()
    }

    public func start(_ launch: HarnessLaunch, message: String, images: [URL]) async throws -> any AgentHarnessSession {
        let plan = try plan(for: launch)
        if !launch.auth.isLogin {
            try FileManager.default.createDirectory(at: launch.paths.claudeConfig, withIntermediateDirectories: true)
        }
        // A skill that can't be copied mustn't stop the job; the rest still install.
        if let skills = launch.skills { _ = try? AgentSkillInstaller.syncClaudePlugin(skills, at: launch.paths.claudeSkillsPlugin) }
        let process = HarnessProcess(executable: plan.executable, arguments: plan.arguments, environment: plan.environment, directory: launch.folder)
        do { try process.start() } catch { throw AgentHarnessError.startupFailed("\(error.localizedDescription)") }
        let session = ClaudeCodeSession(process: process, folder: launch.folder)
        do {
            try await session.begin(message: message, images: images)
        } catch {
            await session.close()
            throw error
        }
        return session
    }
}

// MARK: - Session

public actor ClaudeCodeSession: AgentHarnessSession {
    public nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let process: HarnessProcess
    private var normalizer: ClaudeEventNormalizer
    /// User messages written whose turn hasn't produced a `result` yet.
    private var outstanding = 0
    private var permissionRequests: [String: JSONValue] = [:]
    private var interruptRequested = false
    private var controlCounter = 0
    private var finished = false
    private var readers: [Task<Void, Never>] = []

    init(process: HarnessProcess, folder: URL) {
        self.process = process
        normalizer = ClaudeEventNormalizer(folder: folder)
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    func begin(message: String, images: [URL]) async throws {
        let stdout = process.stdoutLines
        let stderr = process.stderrLines
        readers.append(Task { [weak self] in
            for await line in stdout { await self?.handle(line: line) }
            await self?.processEnded()
        })
        readers.append(Task { [weak self] in
            for await line in stderr where !line.isEmpty { await self?.emit(.log(AgentText.shorten(line, limit: 500))) }
        })
        try writeUser(message, images: images)
    }

    private func writeUser(_ text: String, images: [URL] = []) throws {
        var content: [JSONValue] = [["type": "text", "text": .string(text)]]
        for url in images {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            content.append(["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(data.base64EncodedString())]])
        }
        let line: JSONValue = ["type": "user", "message": ["role": "user", "content": .array(content)]]
        try process.writeLine(line.jsonString())
        if outstanding == 0 { emit(.turnStarted) }
        outstanding += 1
    }

    public func send(_ message: String) async throws -> AgentSendDisposition {
        guard !finished, process.isRunning else { throw AgentHarnessError.notRunning }
        let busy = outstanding > 0
        try writeUser(message)
        return busy ? .queued : .startedTurn
    }

    public func interrupt() async {
        guard outstanding > 0 else { return }
        interruptRequested = true
        controlCounter += 1
        let request: JSONValue = ["type": "control_request", "request_id": .string("openclicky-interrupt-\(controlCounter)"),
                                  "request": ["subtype": "interrupt"]]
        try? process.writeLine(request.jsonString())
        // If the turn hasn't ended in 10 s, fall back to SIGINT.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.forceInterruptIfStillRunning()
        }
    }

    private func forceInterruptIfStillRunning() {
        if interruptRequested, outstanding > 0 { process.send(signal: SIGINT) }
    }

    public func respond(to requestID: String, with decision: AgentApprovalDecision) async throws {
        guard let request = permissionRequests.removeValue(forKey: requestID) else { throw AgentHarnessError.unknownRequest(requestID) }
        let response: JSONValue = ["type": "control_response", "response": [
            "subtype": "success", "request_id": .string(requestID),
            "response": ClaudeEventNormalizer.permissionResponse(request: request, decision: decision),
        ]]
        try process.writeLine(response.jsonString())
        emit(.approvalResolved(id: requestID))
    }

    public func close() async {
        process.closeStdin()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        await process.terminate(grace: 2)
        finish()
    }

    private func handle(line: String) {
        guard let message = try? JSONValue.parse(line), let type = message["type"]?.stringValue else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { emit(.log(AgentText.shorten(line, limit: 500))) }
            return
        }
        switch type {
        case "control_request":
            let id = message["request_id"]?.stringValue ?? ""
            let request = message["request"] ?? .null
            if request["subtype"]?.stringValue == "can_use_tool" {
                permissionRequests[id] = request
                emit(.approvalRequested(ClaudeEventNormalizer.approvalRequest(id: id, request: request)))
            } else {
                let reply: JSONValue = ["type": "control_response", "response": [
                    "subtype": "error", "request_id": .string(id),
                    "error": .string("OpenClicky doesn't handle \(request["subtype"]?.stringValue ?? "this request")"),
                ]]
                try? process.writeLine(reply.jsonString())
            }
        case "control_response", "control_cancel_request":
            if type == "control_cancel_request", let id = message["request_id"]?.stringValue, permissionRequests.removeValue(forKey: id) != nil {
                emit(.approvalResolved(id: id))
            }
        default:
            for event in normalizer.message(message, interruptRequested: interruptRequested) {
                emit(event)
                if case .turnFinished = event {
                    outstanding = max(0, outstanding - 1)
                    interruptRequested = false
                    // Requests the finished turn never got answered are moot now.
                    for id in permissionRequests.keys { emit(.approvalResolved(id: id)) }
                    permissionRequests.removeAll()
                }
            }
        }
    }

    private func processEnded() async {
        let status = await process.waitForExit()
        if outstanding > 0 {
            let tail = process.stderrTail
            let outcome: AgentTurnOutcome = interruptRequested ? .interrupted : .failed
            emit(.turnFinished(outcome, finalText: nil, error: outcome == .interrupted ? nil : "Claude Code stopped (exit \(status))\(tail.isEmpty ? "" : ": \(tail)")"))
            outstanding = 0
        }
        finish()
    }

    private func emit(_ event: AgentEvent) {
        guard !finished else { return }
        continuation.yield(event)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }
}

// MARK: - Normalizer

/// Turns Claude Code's stream-json lines into `AgentEvent`s. Pure, so recorded streams can be replayed in tests.
public struct ClaudeEventNormalizer: Sendable {
    public var folder: URL
    private var toolUses: [String: (name: String, input: JSONValue)] = [:]
    private var lastText: String?
    private var sessionID: String?

    public init(folder: URL) { self.folder = folder }

    public mutating func message(_ message: JSONValue, interruptRequested: Bool = false) -> [AgentEvent] {
        switch message["type"]?.stringValue {
        case "system":
            switch message["subtype"]?.stringValue {
            case "init":
                guard let id = message["session_id"]?.stringValue, id != sessionID else { return [] }
                sessionID = id
                return [.sessionStarted(threadID: id)]
            case "api_retry":
                let attempt = message["attempt"]?.intValue ?? 0
                let maximum = message["max_retries"]?.intValue ?? 0
                return [.error("Model request failed; retrying (\(attempt) of \(maximum))", fatal: false)]
            case "compact_boundary":
                return [.compacted]
            default:
                return []
            }
        case "assistant":
            // Messages from subagents (parent_tool_use_id set) only feed progress, never the report.
            let nested = message["parent_tool_use_id"].map { $0 != .null } ?? false
            let blocks = message["message"]?["content"]?.arrayValue ?? []
            let hasToolUse = blocks.contains { $0["type"]?.stringValue == "tool_use" }
            var events: [AgentEvent] = []
            for block in blocks {
                switch block["type"]?.stringValue {
                case "text":
                    guard let text = block["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if hasToolUse || nested { events.append(.commentary(text)) } else { lastText = text }
                case "thinking":
                    if let heading = CodexEventNormalizer.heading(block["thinking"]?.stringValue ?? "") { events.append(.thinking(heading)) }
                case "tool_use":
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                    let input = block["input"] ?? .null
                    toolUses[id] = (name, input)
                    events.append(contentsOf: Self.toolStarted(name: name, input: input))
                    // Claude Code runs the edit right after this message: keep the file's "before" now.
                    if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name),
                       let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue {
                        events.append(.fileWillChange(path: absolute(path)))
                    }
                default:
                    continue
                }
            }
            return events
        case "user":
            var events: [AgentEvent] = []
            for block in message["message"]?["content"]?.arrayValue ?? [] where block["type"]?.stringValue == "tool_result" {
                guard let id = block["tool_use_id"]?.stringValue, let use = toolUses.removeValue(forKey: id) else { continue }
                if block["is_error"]?.boolValue == true {
                    events.append(.progress("\(use.name) didn't work"))
                    continue
                }
                if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(use.name),
                   let path = use.input["file_path"]?.stringValue ?? use.input["notebook_path"]?.stringValue {
                    events.append(.fileChanged(path: absolute(path), change: use.name == "Write" ? "created" : "changed"))
                }
            }
            return events
        case "result":
            let subtype = message["subtype"]?.stringValue ?? "success"
            let isError = message["is_error"]?.boolValue ?? (subtype != "success")
            let outcome: AgentTurnOutcome = !isError ? .completed : (interruptRequested ? .interrupted : .failed)
            let resultText = message["result"]?.stringValue
            var events: [AgentEvent] = []
            if let usage = message["usage"] {
                events.append(.usage(AgentTokenUsage(
                    input: (usage["input_tokens"]?.intValue ?? 0) + (usage["cache_creation_input_tokens"]?.intValue ?? 0) + (usage["cache_read_input_tokens"]?.intValue ?? 0),
                    cachedInput: usage["cache_read_input_tokens"]?.intValue ?? 0,
                    output: usage["output_tokens"]?.intValue ?? 0,
                    cacheWrite: usage["cache_creation_input_tokens"]?.intValue ?? 0)))
            }
            let errors = message["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ")
            let error: String? = outcome == .failed ? (errors?.isEmpty == false ? errors : resultText ?? subtype) : nil
            let final = outcome == .completed ? (resultText ?? lastText) : lastText
            lastText = nil
            toolUses.removeAll()
            events.append(.turnFinished(outcome, finalText: final, error: error))
            return events
        default:
            return []
        }
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL.path : folder.appendingPathComponent(path).standardizedFileURL.path
    }

    static func toolStarted(name: String, input: JSONValue) -> [AgentEvent] {
        func file(_ key: String = "file_path") -> String { input[key]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file" }
        switch name {
        case "Bash":
            let what = input["description"]?.stringValue ?? input["command"]?.stringValue ?? "a command"
            return [.progress("Running: \(AgentText.oneLine(what, limit: 120))")]
        case "Write": return [.progress("Writing \(file())")]
        case "Edit", "MultiEdit": return [.progress("Editing \(file())")]
        case "NotebookEdit": return [.progress("Editing \(file("notebook_path"))")]
        case "Read": return [.progress("Reading \(file())")]
        case "Glob", "Grep": return [.progress("Looking through files")]
        case "WebSearch": return [.progress("Searching: \(AgentText.shorten(input["query"]?.stringValue ?? "the web", limit: 100))")]
        case "WebFetch":
            let host = input["url"]?.stringValue.flatMap { URL(string: $0)?.host } ?? "a page"
            return [.progress("Reading \(host)")]
        case "TodoWrite":
            let steps = (input["todos"]?.arrayValue ?? []).compactMap { todo -> AgentPlanStep? in
                guard let text = todo["content"]?.stringValue else { return nil }
                let status: AgentPlanStep.Status = switch todo["status"]?.stringValue {
                case "completed": .completed
                case "in_progress": .inProgress
                default: .pending
                }
                return AgentPlanStep(step: text, status: status)
            }
            return [.plan(steps)]
        case "Task", "Agent":
            return [.progress("Delegating: \(AgentText.shorten(input["description"]?.stringValue ?? "a subtask", limit: 100))")]
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                return [.progress("Using \(parts.first ?? "app"): \(parts.dropFirst().joined(separator: "_"))")]
            }
            return [.progress("Using \(name)")]
        }
    }

    public static func approvalRequest(id: String, request: JSONValue) -> AgentApprovalRequest {
        let tool = request["tool_name"]?.stringValue ?? "a tool"
        let input = request["input"] ?? .null
        let summary: String = switch tool {
        case "Bash": "Run \(AgentText.oneLine(input["command"]?.stringValue ?? "a command", limit: 160))"
        case "Write": "Write \(input["file_path"]?.stringValue ?? "a file")"
        case "Edit", "MultiEdit": "Edit \(input["file_path"]?.stringValue ?? "a file")"
        case "WebFetch": "Open \(input["url"]?.stringValue ?? "a web page")"
        default: "Use \(request["display_name"]?.stringValue ?? tool)"
        }
        let reason = request["description"]?.stringValue ?? input["description"]?.stringValue
        return AgentApprovalRequest(id: id, kind: .tool, summary: summary, reason: reason)
    }

    /// The `response` body of a `control_response` answering `can_use_tool`.
    public static func permissionResponse(request: JSONValue, decision: AgentApprovalDecision) -> JSONValue {
        switch decision {
        case .approve(let always):
            var allow: [String: JSONValue] = ["behavior": "allow", "updatedInput": request["input"] ?? [:]]
            if always, let suggestions = request["permission_suggestions"], suggestions != .null { allow["updatedPermissions"] = suggestions }
            return .object(allow)
        case .decline:
            return ["behavior": "deny", "message": "The user said no. Don't try this again; find another way or say what you couldn't do."]
        case .answer(let text):
            return ["behavior": "deny", "message": .string("The user answered instead: \(text)")]
        }
    }
}
