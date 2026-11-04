import Foundation

/// Runs jobs with the Codex CLI's app server (`codex app-server`, JSON-RPC 2.0, one JSON object per line on
/// stdin/stdout). Verified against codex-cli 0.165.0: `initialize` → `initialized` → `thread/start` (or
/// `thread/resume`) → `turn/start`, with `turn/steer` for follow-ups mid-turn, `turn/interrupt`, and approval
/// requests (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`, …) answered by the user.
///
/// Bring-your-own-key: OpenClicky's own `CODEX_HOME` gets a generated `config.toml` with a custom
/// `model_provider` (base_url, `wire_api = "responses"`, `env_key`), and the key travels in that environment
/// variable. Harness login: Codex's ChatGPT sign-in is used where it lives, in OpenClicky's home if the user signed
/// in there (`occtl agent login codex`), else in the user's own Codex home with the settings passed as `-c`
/// overrides, so nothing is written there. On the user's home the job runs without their plugins, connectors,
/// memories, hooks and MCP servers (`CodexConfig.isolatedFeatures`, plus each configured server switched off), so a
/// background job never starts tools the user set up for their own Codex sessions.
public struct CodexHarness: AgentHarness {
    public let kind = HarnessKind.codex
    /// Whether a Codex home holds Codex's own sign-in. Checks only that the auth file exists; never reads it.
    public var hasLogin: @Sendable (URL) -> Bool
    /// Names of the MCP servers the user's own Codex config defines (run with the job's environment).
    public var listUserMCPServers: @Sendable (_ executable: URL, _ environment: [String: String]) -> [String]
    public var clientVersion: String

    /// Environment variable that carries the agent slot's key to Codex.
    public static let apiKeyVariable = "OPENCLICKY_AGENT_API_KEY"

    public init(clientVersion: String = "0.1.0",
                hasLogin: @escaping @Sendable (URL) -> Bool = { home in
                    FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path)
                },
                listUserMCPServers: @escaping @Sendable (URL, [String: String]) -> [String] = CodexHarness.configuredMCPServers) {
        self.clientVersion = clientVersion
        self.hasLogin = hasLogin
        self.listUserMCPServers = listUserMCPServers
    }

    /// `codex mcp list --json` (plugins and connectors off, as for the job), keeping only the server names. Gives up
    /// after 15 s; an empty list then means the user's servers stay as they are.
    public static func configuredMCPServers(_ executable: URL, _ environment: [String: String]) -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = CodexConfig.isolatedFeatures.flatMap { ["-c", "features.\($0)=false"] } + ["mcp", "list", "--json"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        let box = DataBox()
        DispatchQueue.global().async {
            box.data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try process.run() } catch { return [] }
        if done.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let list = try? JSONValue.parse(String(decoding: box.data, as: UTF8.self)).arrayValue else { return [] }
        return list.compactMap { $0["name"]?.stringValue }
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs blocking work on a GCD thread and waits for it without holding a cooperative thread.
    static func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// What will be launched, and the config file to write first (if any).
    public struct Plan: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        /// The Codex home in use.
        public var codexHome: URL
        /// `config.toml` contents for OpenClicky's own home; nil when running on the user's home.
        public var configTOML: String?
        public var config: CodexConfig
        /// Where the job's skills are installed before launch; nil installs none.
        public var skillsFolder: URL? = nil
        /// Skill folders outside the Codex home in use, added with `skills/extraRoots/set` before the thread starts
        /// (on the user's own home, where OpenClicky writes nothing).
        public var extraSkillRoots: [URL] = []
    }

    public func plan(for launch: HarnessLaunch) throws -> Plan {
        guard let executable = HarnessEnvironment.locate(.codex, override: launch.executable, environment: launch.baseEnvironment) else {
            throw AgentHarnessError.executableNotFound(.codex)
        }
        var added: [String: String] = [:]
        var provider: CodexConfig.Provider?
        var useOwnHome = true
        switch launch.auth {
        case .provider(let config, let apiKey):
            guard config.dialect == .openAIResponses else {
                throw AgentHarnessError.unsupportedProvider(
                    "Codex only talks to OpenAI Responses-style providers (Codex dropped wire_api \"chat\"). Give the agent slot an \(ProviderDialect.openAIResponses.rawValue) provider, or use \(ProviderDialect.harnessLogin.rawValue).")
            }
            guard let baseURL = config.baseURL else { throw AgentHarnessError.unsupportedProvider("Provider \"\(config.id)\" has no baseURL.") }
            provider = .init(name: "OpenClicky agent slot (\(config.id))", baseURL: baseURL.absoluteString,
                             envKey: apiKey == nil ? nil : Self.apiKeyVariable, headers: config.headers ?? [:])
            if let apiKey { added[Self.apiKeyVariable] = apiKey }
        case .harnessLogin:
            useOwnHome = hasLogin(launch.paths.codexHome)
        }
        for server in launch.mcpServers { added.merge(server.harnessSecrets) { _, new in new } }
        if useOwnHome { added["CODEX_HOME"] = launch.paths.codexHome.path }
        // Plain job variables (the Obsidian vault path) reach the agent's commands; the secrets above don't.
        let environment = HarnessEnvironment.child(
            base: launch.baseEnvironment,
            stripping: useOwnHome ? ["CODEX_HOME"] : [],
            adding: launch.environment.merging(added) { _, secret in secret }, executable: executable)
        var config = CodexConfig(model: launch.model, reasoningEffort: launch.reasoningEffort, provider: provider,
                                 approvalMode: launch.approvalMode, mcpServers: launch.mcpServers,
                                 trustedProjects: [launch.paths.projects.path],
                                 hiddenVariables: added.keys.filter { $0 != "CODEX_HOME" }.sorted(),
                                 autoCompactTokenLimit: launch.limits.compactionTokens)
        var arguments = ["app-server"]
        let home: URL
        if useOwnHome {
            home = launch.paths.codexHome
        } else {
            home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: launch.baseEnvironment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".codex")
            config.disabledServers = listUserMCPServers(executable, environment)
            arguments += config.overrideArguments()
        }
        arguments += launch.extraArguments
        if let skills = launch.skills {
            config.skillFiles = skills.map {
                launch.paths.codexSkills.appendingPathComponent(AgentSkillSource.installName($0.name)).appendingPathComponent(SkillFile.fileName).path
            }
        }
        var plan = Plan(executable: executable, arguments: arguments, environment: environment, codexHome: home,
                        configTOML: useOwnHome ? config.renderTOML() : nil, config: config)
        if launch.skills != nil {
            plan.skillsFolder = launch.paths.codexSkills
            if !useOwnHome { plan.extraSkillRoots = [launch.paths.codexSkills] }
        }
        return plan
    }

    public func start(_ launch: HarnessLaunch, message: String, images: [URL]) async throws -> any AgentHarnessSession {
        // Planning can run `codex mcp list` and wait for it (up to 15 s). Swift's cooperative threads are few and
        // shared with the voice pipeline, so the blocking part runs on a GCD thread instead.
        let plan = try await Self.offCooperativePool { [self] in
            let plan = try self.plan(for: launch)
            // A skill that can't be copied mustn't stop the job; the rest still install.
            if let skills = launch.skills, let folder = plan.skillsFolder { _ = try? AgentSkillInstaller.sync(skills, into: folder) }
            if let toml = plan.configTOML {
                try FileManager.default.createDirectory(at: plan.codexHome, withIntermediateDirectories: true)
                let file = plan.codexHome.appendingPathComponent("config.toml")
                try toml.write(to: file, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            return plan
        }
        let process = HarnessProcess(executable: plan.executable, arguments: plan.arguments, environment: plan.environment, directory: launch.folder)
        do { try process.start() } catch { throw AgentHarnessError.startupFailed("\(error.localizedDescription)") }
        let session = CodexAppServerSession(process: process, folder: launch.folder, clientVersion: clientVersion)
        do {
            try await session.begin(launch: launch, plan: plan, message: message, images: images)
        } catch {
            await session.close()
            throw error
        }
        return session
    }
}

// MARK: - Session

/// One `codex app-server` process serving one job's thread.
public actor CodexAppServerSession: AgentHarnessSession {
    public nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let process: HarnessProcess
    private let clientVersion: String
    private var normalizer: CodexEventNormalizer
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var serverRequests: [String: (id: JSONValue, method: String, params: JSONValue)] = [:]
    private var threadID: String?
    private var turnID: String?
    private var turnActive = false
    private var queued: [String] = []
    private var finished = false
    private var readers: [Task<Void, Never>] = []

    /// How long `initialize`, `thread/*` and `turn/*` requests may take.
    static let requestTimeout: TimeInterval = 90

    init(process: HarnessProcess, folder: URL, clientVersion: String) {
        self.process = process
        self.clientVersion = clientVersion
        normalizer = CodexEventNormalizer(folder: folder)
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    func begin(launch: HarnessLaunch, plan: CodexHarness.Plan, message: String, images: [URL]) async throws {
        let stdout = process.stdoutLines
        let stderr = process.stderrLines
        readers.append(Task { [weak self] in
            for await line in stdout { await self?.handle(line: line) }
            await self?.processEnded()
        })
        readers.append(Task { [weak self] in
            for await line in stderr where !line.isEmpty { await self?.emit(.log(AgentText.shorten(line, limit: 500))) }
        })

        _ = try await request("initialize", [
            "clientInfo": ["name": "openclicky", "title": "OpenClicky", "version": .string(clientVersion)],
            "capabilities": ["experimentalApi": true],
        ])
        try notify("initialized")
        if !plan.extraSkillRoots.isEmpty {
            // Older app servers don't know the method; the job runs without the skills then.
            do {
                _ = try await request("skills/extraRoots/set", ["extraRoots": .array(plan.extraSkillRoots.map { .string($0.path) })], timeout: 15)
            } catch {
                emit(.log("Couldn't add OpenClicky's skills to Codex: \(error)"))
            }
        }

        var params: [String: JSONValue] = [
            "cwd": .string(launch.folder.path),
            "developerInstructions": .string(launch.instructions),
            "approvalPolicy": .string(plan.config.approvalPolicy),
            "sandbox": .string(plan.config.sandboxMode),
        ]
        if let model = launch.model { params["model"] = .string(model) }
        let result: JSONValue
        if let resume = launch.resumeThreadID {
            params["threadId"] = .string(resume)
            params["excludeTurns"] = true
            result = try await request("thread/resume", .object(params))
        } else {
            result = try await request("thread/start", .object(params))
        }
        guard let id = result["thread"]?["id"]?.stringValue else { throw AgentHarnessError.protocolError("thread/start returned no thread id") }
        threadID = id
        emit(.sessionStarted(threadID: id))
        try await startTurn(message, images: images)
    }

    private func startTurn(_ text: String, images: [URL] = []) async throws {
        guard let threadID else { throw AgentHarnessError.notRunning }
        var input: [JSONValue] = [["type": "text", "text": .string(text)]]
        input += images.map { ["type": "localImage", "path": .string($0.path)] }
        turnActive = true
        do {
            let result = try await request("turn/start", ["threadId": .string(threadID), "input": .array(input)])
            if turnActive, let id = result["turn"]?["id"]?.stringValue { turnID = id }
        } catch {
            turnActive = false
            throw error
        }
    }

    public func send(_ message: String) async throws -> AgentSendDisposition {
        guard !finished else { throw AgentHarnessError.notRunning }
        if turnActive, let threadID, let turnID {
            do {
                _ = try await request("turn/steer", ["threadId": .string(threadID), "expectedTurnId": .string(turnID),
                                                     "input": [["type": "text", "text": .string(message)]]])
                emit(.progress("Got your follow-up"))
                return .steered
            } catch {
                if turnActive {
                    queued.append(message)
                    return .queued
                }
            }
        }
        try await startTurn(message)
        return .startedTurn
    }

    public func interrupt() async {
        queued.removeAll()
        guard turnActive, let threadID, let turnID else { return }
        _ = try? await request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)], timeout: 15)
    }

    public func respond(to requestID: String, with decision: AgentApprovalDecision) async throws {
        guard let request = serverRequests.removeValue(forKey: requestID) else { throw AgentHarnessError.unknownRequest(requestID) }
        let result = CodexEventNormalizer.response(method: request.method, params: request.params, decision: decision)
        try write(["jsonrpc": "2.0", "id": request.id, "result": result])
        emit(.approvalResolved(id: requestID))
    }

    public func close() async {
        await process.terminate(grace: 3)
        finish()
    }

    // MARK: Wire

    private func request(_ method: String, _ params: JSONValue, timeout: TimeInterval = CodexAppServerSession.requestTimeout) async throws -> JSONValue {
        guard !finished else { throw AgentHarnessError.notRunning }
        let id = nextID
        nextID += 1
        try write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.fail(id, AgentHarnessError.protocolError("\(method) got no answer within \(Int(timeout)) s"))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }

    private func notify(_ method: String, _ params: JSONValue? = nil) throws {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { message["params"] = params }
        try write(.object(message))
    }

    private func write(_ message: JSONValue) throws {
        try process.writeLine(message.jsonString())
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func handle(line: String) {
        guard let message = try? JSONValue.parse(line), case .object(let object) = message else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { emit(.log(AgentText.shorten(line, limit: 500))) }
            return
        }
        let method = object["method"]?.stringValue
        if method == nil, let id = object["id"]?.intValue {
            // A response to one of our requests.
            if let error = object["error"] {
                pending.removeValue(forKey: id)?.resume(throwing: AgentHarnessError.protocolError(error["message"]?.stringValue ?? error.jsonString()))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: object["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        let params = object["params"] ?? .null
        if let id = object["id"] {
            handleServerRequest(id: id, method: method, params: params)
            return
        }
        if method == "turn/started", let id = params["turn"]?["id"]?.stringValue {
            turnID = id
            turnActive = true
        }
        for event in normalizer.notification(method: method, params: params) {
            emit(event)
            if case .turnFinished = event { turnEnded() }
        }
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) {
        let key = id.stringValue ?? id.jsonString()
        if let request = CodexEventNormalizer.approvalRequest(method: method, id: key, params: params) {
            serverRequests[key] = (id, method, params)
            emit(.approvalRequested(request))
            return
        }
        // Elicitations, dynamic tools, token refreshes: nothing OpenClicky offers.
        let result: JSONValue? = method == "mcpServer/elicitation/request" ? ["action": "decline"] : nil
        if let result {
            try? write(["jsonrpc": "2.0", "id": id, "result": result])
        } else {
            try? write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("OpenClicky doesn't handle \(method)")]])
        }
        emit(.log("Declined harness request \(method)"))
    }

    private func turnEnded() {
        turnActive = false
        turnID = nil
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        Task { [weak self] in
            do { try await self?.startTurn(next) } catch { await self?.emit(.error("Couldn't send the follow-up: \(error)", fatal: false)) }
        }
    }

    private func processEnded() async {
        let status = await process.waitForExit()
        for (_, continuation) in pending { continuation.resume(throwing: AgentHarnessError.notRunning) }
        pending.removeAll()
        if turnActive {
            let tail = process.stderrTail
            emit(.turnFinished(.failed, finalText: nil, error: "Codex stopped (exit \(status))\(tail.isEmpty ? "" : ": \(tail)")"))
            turnActive = false
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

/// Turns Codex app-server notifications into `AgentEvent`s. Pure, so recorded transcripts can be replayed in tests.
public struct CodexEventNormalizer: Sendable {
    public var folder: URL
    /// The latest agent message of the current turn: the final report once the turn completes.
    private var lastAgentMessage: String?
    private var reasoning: [String: String] = [:]
    /// Codex reports one compaction both as a `contextCompaction` item and as `thread/compacted`, in either order (or
    /// only one of them, depending on its version): each source is counted, and only the one running ahead emits.
    private var compactionItems = 0
    private var compactionNotices = 0

    public init(folder: URL) { self.folder = folder }

    public mutating func notification(method: String, params: JSONValue) -> [AgentEvent] {
        switch method {
        case "turn/started":
            lastAgentMessage = nil
            return [.turnStarted]
        case "item/started":
            return itemStarted(params["item"] ?? .null)
        case "item/completed":
            return itemCompleted(params["item"] ?? .null)
        case "item/reasoning/summaryTextDelta":
            guard let id = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            reasoning[id, default: ""] += delta
            return []
        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { step -> AgentPlanStep? in
                guard let text = step["step"]?.stringValue else { return nil }
                let status: AgentPlanStep.Status = switch step["status"]?.stringValue {
                case "completed": .completed
                case "inProgress", "in_progress": .inProgress
                default: .pending
                }
                return AgentPlanStep(step: text, status: status)
            }
            return [.plan(steps)]
        case "thread/tokenUsage/updated":
            guard let total = params["tokenUsage"]?["total"] else { return [] }
            return [.usage(AgentTokenUsage(input: total["inputTokens"]?.intValue ?? 0,
                                           cachedInput: total["cachedInputTokens"]?.intValue ?? 0,
                                           output: total["outputTokens"]?.intValue ?? 0,
                                           cacheWrite: total["cacheWriteInputTokens"]?.intValue ?? 0))]
        case "error":
            let message = params["error"]?["message"]?.stringValue ?? "Unknown error"
            let retrying = params["willRetry"]?.boolValue ?? false
            return [.error(message, fatal: !retrying)]
        case "thread/compacted":
            compactionNotices += 1
            return compactionNotices > compactionItems ? [.compacted] : []
        case "warning", "configWarning", "deprecationNotice":
            return params["message"]?.stringValue.map { [.log($0)] } ?? []
        case "turn/completed":
            let turn = params["turn"] ?? .null
            let outcome: AgentTurnOutcome = switch turn["status"]?.stringValue {
            case "interrupted": .interrupted
            case "failed": .failed
            default: .completed
            }
            let fromItems = (turn["items"]?.arrayValue ?? []).last { $0["type"]?.stringValue == "agentMessage" }?["text"]?.stringValue
            let finalText = fromItems ?? lastAgentMessage
            lastAgentMessage = nil
            return [.turnFinished(outcome, finalText: finalText, error: turn["error"]?["message"]?.stringValue)]
        default:
            return []
        }
    }

    private func itemStarted(_ item: JSONValue) -> [AgentEvent] {
        switch item["type"]?.stringValue {
        case "commandExecution":
            return [.progress("Running: \(Self.commandSummary(item))")]
        case "fileChange":
            let paths = (item["changes"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
            // Before the patch is applied (or approved): the moment to keep each file's "before".
            return [.progress(names.isEmpty ? "Editing files" : "Editing \(names.prefix(3).joined(separator: ", "))")]
                + paths.map { .fileWillChange(path: absolute($0)) }
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "app"
            let tool = item["tool"]?.stringValue ?? "tool"
            return [.progress("Using \(server): \(tool)")]
        case "webSearch":
            let query = item["query"]?.stringValue ?? ""
            return [.progress(query.isEmpty ? "Searching the web" : "Searching: \(AgentText.shorten(query, limit: 100))")]
        case "imageView":
            return [.progress("Looking at an image")]
        default:
            return []
        }
    }

    private mutating func itemCompleted(_ item: JSONValue) -> [AgentEvent] {
        switch item["type"]?.stringValue {
        case "contextCompaction":
            compactionItems += 1
            return compactionItems > compactionNotices ? [.compacted] : []
        case "agentMessage":
            guard let text = item["text"]?.stringValue, !text.isEmpty else { return [] }
            if item["phase"]?.stringValue == "commentary" { return [.commentary(text)] }
            let previous = lastAgentMessage
            lastAgentMessage = text
            // An earlier message followed by more work was commentary.
            return previous.map { [.commentary($0)] } ?? []
        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
            let text = summary.isEmpty ? (item["id"]?.stringValue.flatMap { reasoning.removeValue(forKey: $0) } ?? "") : summary
            return Self.heading(text).map { [.thinking($0)] } ?? []
        case "commandExecution":
            let status = item["status"]?.stringValue
            if status == "declined" { return [.progress("Skipped: \(Self.commandSummary(item))")] }
            if let code = item["exitCode"]?.intValue, code != 0 {
                return [.progress("Command failed (exit \(code)): \(Self.commandSummary(item))")]
            }
            return []
        case "fileChange":
            guard item["status"]?.stringValue != "declined", item["status"]?.stringValue != "failed" else { return [] }
            return (item["changes"]?.arrayValue ?? []).compactMap { change in
                guard let path = change["path"]?.stringValue else { return nil }
                let kind = change["kind"]?["type"]?.stringValue ?? change["kind"]?.stringValue ?? "update"
                let label = kind == "add" ? "created" : kind == "delete" ? "deleted" : "changed"
                return .fileChanged(path: absolute(path), change: label)
            }
        case "mcpToolCall":
            if item["status"]?.stringValue == "failed" {
                return [.progress("\(item["tool"]?.stringValue ?? "Tool") failed: \(item["error"]?["message"]?.stringValue ?? "unknown error")")]
            }
            return []
        default:
            return []
        }
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : folder.appendingPathComponent(path).standardizedFileURL.path
    }

    /// The command without the shell wrapper Codex adds (`/bin/zsh -lc '…'`).
    static func commandSummary(_ item: JSONValue) -> String {
        if let action = item["commandActions"]?.arrayValue?.first, let command = action["command"]?.stringValue, !command.isEmpty {
            return AgentText.oneLine(command, limit: 120)
        }
        var command = item["command"]?.stringValue ?? "a command"
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(shell) {
            command = String(command.dropFirst(shell.count))
            if command.hasPrefix("'"), command.hasSuffix("'"), command.count > 1 { command = String(command.dropFirst().dropLast()) }
        }
        return AgentText.oneLine(command, limit: 120)
    }

    /// The bold heading of a reasoning summary ("**Checking the files**"), else its first line.
    static func heading(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("**"), let end = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.endIndex) {
            return String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<end.lowerBound])
        }
        return AgentText.firstLine(AgentText.stripMarkdown(trimmed), limit: 100)
    }

    /// An approval request event for a server request, or nil for requests that aren't approvals.
    public static func approvalRequest(method: String, id: String, params: JSONValue) -> AgentApprovalRequest? {
        let reason = params["reason"]?.stringValue
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            var command = commandSummary(params)
            if command == "a command", let parts = params["command"]?.arrayValue { command = parts.compactMap(\.stringValue).joined(separator: " ") }
            return AgentApprovalRequest(id: id, kind: .command, summary: "Run \(command)", reason: reason)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let root = params["grantRoot"]?.stringValue
            return AgentApprovalRequest(id: id, kind: .fileChange, summary: root.map { "Change files in \($0)" } ?? "Change files outside the job folder", reason: reason)
        case "item/permissions/requestApproval":
            var wants: [String] = []
            if params["permissions"]?["network"].map({ $0 != .null }) == true { wants.append("network access") }
            if params["permissions"]?["fileSystem"].map({ $0 != .null }) == true { wants.append("access to more folders") }
            return AgentApprovalRequest(id: id, kind: .permissions, summary: "Allow \(wants.isEmpty ? "extra permissions" : wants.joined(separator: " and "))", reason: reason)
        case "item/tool/requestUserInput":
            let questions = params["questions"]?.arrayValue ?? []
            let first = questions.first
            let options = first?["options"]?.arrayValue?.compactMap { $0["label"]?.stringValue ?? $0.stringValue }
            return AgentApprovalRequest(id: id, kind: .question, summary: first?["question"]?.stringValue ?? "The agent has a question",
                                        reason: first?["header"]?.stringValue, options: options?.isEmpty == false ? options : nil)
        default:
            return nil
        }
    }

    /// The JSON-RPC result answering an approval request.
    public static func response(method: String, params: JSONValue, decision: AgentApprovalDecision) -> JSONValue {
        let available = params["availableDecisions"]?.arrayValue?.compactMap(\.stringValue)
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            switch decision {
            case .approve(let always):
                let word = always && (available?.contains("acceptForSession") ?? true) ? "acceptForSession" : "accept"
                return ["decision": .string(word)]
            case .decline, .answer:
                // "decline" skips just this action and the turn goes on (verified on codex-cli 0.165.0, even when
                // availableDecisions lists only "cancel", which would end the whole turn).
                return ["decision": "decline"]
            }
        case "execCommandApproval", "applyPatchApproval":
            switch decision {
            case .approve(let always): return ["decision": .string(always ? "approved_for_session" : "approved")]
            case .decline, .answer: return ["decision": "denied"]
            }
        case "item/permissions/requestApproval":
            switch decision {
            case .approve(let always):
                return ["permissions": params["permissions"] ?? [:], "scope": .string(always ? "session" : "turn")]
            case .decline, .answer:
                return ["permissions": [:]]
            }
        case "item/tool/requestUserInput":
            let text: String = switch decision {
            case .answer(let text): text
            case .approve: "Yes"
            case .decline: "No"
            }
            var answers: [String: JSONValue] = [:]
            for question in params["questions"]?.arrayValue ?? [] {
                if let id = question["id"]?.stringValue { answers[id] = ["answers": [.string(text)]] }
            }
            return ["answers": .object(answers)]
        default:
            return [:]
        }
    }
}
