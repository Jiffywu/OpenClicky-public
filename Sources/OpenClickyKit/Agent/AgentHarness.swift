import Foundation

/// How a harness signs in to its model.
public enum HarnessAuth: Sendable {
    /// Bring your own key: the agent slot's provider and its secret (nil for keyless local servers). The secret
    /// reaches the harness only as an environment variable.
    case provider(ProviderConfig, apiKey: String?)
    /// The harness's own sign-in (ChatGPT login for Codex, a Claude subscription for Claude Code).
    case harnessLogin

    public var isLogin: Bool { if case .harnessLogin = self { true } else { false } }
}

/// How much the agent may do without asking.
public enum AgentApprovalMode: String, Codable, Sendable, CaseIterable {
    /// Work inside the job folder freely (network allowed); ask before anything beyond it. The default.
    case ask
    /// Full access to the Mac and never ask (HeyClicky's behavior).
    case fullAccess = "full-access"
}

/// An MCP server offered to the agent (for example the browser bridge's localhost server).
public struct AgentMCPServer: Sendable, Hashable {
    public enum Transport: Sendable, Hashable {
        case http(URL)
        case stdio(command: String, arguments: [String])
    }

    /// Server name as the agent sees it (letters, digits, `_` and `-`).
    public var name: String
    public var transport: Transport
    /// Bearer token for HTTP servers. Never written to a file: the harness reads it from
    /// `tokenEnvironmentVariable`.
    public var bearerToken: String?
    public var tokenEnvironmentVariable: String
    public var startupTimeout: TimeInterval
    public var toolTimeout: TimeInterval
    /// HTTP servers: more headers whose values are secret, as header name → the environment variable holding the
    /// value (Codex `env_http_headers`, Claude Code `${VAR}` headers). The values travel in `secretValues`.
    public var secretHeaders: [String: String]
    /// Stdio servers: variables forwarded from the harness's environment to the server (Codex `env_vars`, Claude
    /// Code `${VAR}` env entries). Values that are secrets travel in `secretValues`.
    public var forwardedVariables: [String]
    /// Stdio servers: plain variables set for the server (a PATH that finds its runtime). Never secrets: they are
    /// written into the harness's config.
    public var environment: [String: String]
    /// Secret values the harness puts into its own environment (variable → value) for `secretHeaders` and
    /// `forwardedVariables`. Never written to a file or a command line, and hidden from the agent's shell commands.
    public var secretValues: [String: String]
    /// HTTP servers: a header that carries the calling job's id (the server's job tools and the browser tool read it;
    /// `AgentJobMCPTools.jobHeader`, `BrowserCallIdentity`). The manager fills it in for each launch
    /// (`identifyingJob(_:)`), as a secret header so the agent's commands can't read or change it.
    public var jobHeaderName: String?
    /// Tools on this server the agent may call without asking the user (OpenClicky's own job tools, which confirm
    /// anything that matters themselves). Claude Code gets them as `--allowedTools mcp__<server>__<tool>`; Codex
    /// doesn't ask before MCP calls.
    public var trustedTools: [String] = []

    public init(name: String, transport: Transport, bearerToken: String? = nil, tokenEnvironmentVariable: String? = nil,
                startupTimeout: TimeInterval = 20, toolTimeout: TimeInterval = 900, secretHeaders: [String: String] = [:],
                forwardedVariables: [String] = [], environment: [String: String] = [:], secretValues: [String: String] = [:]) {
        self.name = name
        self.transport = transport
        self.bearerToken = bearerToken
        self.tokenEnvironmentVariable = tokenEnvironmentVariable
            ?? "OPENCLICKY_MCP_TOKEN_" + name.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        self.startupTimeout = startupTimeout
        self.toolTimeout = toolTimeout
        self.secretHeaders = secretHeaders
        self.forwardedVariables = forwardedVariables
        self.environment = environment
        self.secretValues = secretValues
    }

    /// The prefix of the variable the job's id travels in for `jobHeaderName` (through `secretHeaders`, so both
    /// harnesses send it); the server's name follows.
    public static let jobVariable = "OPENCLICKY_MCP_JOB"

    /// This server as one job launches it: `jobHeaderName` set to the job's id. Unchanged without a `jobHeaderName`.
    public func identifyingJob(_ jobID: String) -> AgentMCPServer {
        guard let jobHeaderName, case .http = transport else { return self }
        var copy = self
        let variable = Self.jobVariable + "_" + name.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        copy.secretHeaders[jobHeaderName] = variable
        copy.secretValues[variable] = jobID
        return copy
    }

    /// Every secret the harness must hold in its environment for this server (the bearer token and `secretValues`).
    public var harnessSecrets: [String: String] {
        var all = secretValues
        if let bearerToken { all[tokenEnvironmentVariable] = bearerToken }
        return all
    }
}

extension AgentMCPServer: CustomStringConvertible {
    /// Safe to log: variable names only, never values.
    public var description: String {
        let target: String = switch transport {
        case .http(let url): url.absoluteString
        case .stdio(let command, _): command
        }
        return "AgentMCPServer(\(name): \(target), secrets: \(harnessSecrets.keys.sorted()))"
    }
}

/// Everything a harness needs to run one job session.
public struct HarnessLaunch: Sendable {
    /// The job folder; the harness's working directory.
    public var folder: URL
    /// Skills to install into the harness's skills folder before it starts (Codex: `CODEX_HOME/skills`, enabled in
    /// its config; Claude Code: a plugin passed with `--plugin-dir`). nil leaves the skills folders alone.
    public var skills: [AgentSkillSource]? = nil
    /// OpenClicky's job instructions (developer/system prompt).
    public var instructions: String
    /// Model id; nil lets the harness use its default.
    public var model: String?
    public var reasoningEffort: String?
    public var auth: HarnessAuth
    public var mcpServers: [AgentMCPServer]
    public var approvalMode: AgentApprovalMode
    /// Resume this harness conversation instead of starting a new one.
    public var resumeThreadID: String?
    /// Overrides PATH lookup.
    public var executable: URL?
    public var extraArguments: [String]
    public var paths: AgentPaths
    /// The environment the harness inherits (before OpenClicky strips and adds variables).
    public var baseEnvironment: [String: String]
    /// Plain variables the job's commands may read (OBSIDIAN_VAULT_PATH). Never secrets: unlike MCP secrets they
    /// reach the agent's shell.
    public var environment: [String: String]
    /// Limits the harness can enforce itself (Claude Code's Bash timeout, Codex's compaction threshold).
    public var limits: AgentLimits

    public init(folder: URL, instructions: String, model: String?, reasoningEffort: String? = nil, auth: HarnessAuth,
                mcpServers: [AgentMCPServer] = [], approvalMode: AgentApprovalMode = .ask, resumeThreadID: String? = nil,
                executable: URL? = nil, extraArguments: [String] = [], paths: AgentPaths = .default,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, environment: [String: String] = [:],
                limits: AgentLimits = AgentLimits()) {
        self.environment = environment
        self.limits = limits
        self.folder = folder
        self.instructions = instructions
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.auth = auth
        self.mcpServers = mcpServers
        self.approvalMode = approvalMode
        self.resumeThreadID = resumeThreadID
        self.executable = executable
        self.extraArguments = extraArguments
        self.paths = paths
        self.baseEnvironment = baseEnvironment
    }
}

/// What happened to a follow-up message.
public enum AgentSendDisposition: String, Sendable, Codable {
    /// Added to the turn that is running now.
    case steered
    /// Will run as soon as the current turn ends.
    case queued
    /// Started a new turn.
    case startedTurn = "started_turn"
}

public enum AgentHarnessError: Error, CustomStringConvertible, Equatable {
    case executableNotFound(HarnessKind)
    case unsupportedProvider(String)
    case startupFailed(String)
    case protocolError(String)
    case notRunning
    case unknownRequest(String)

    public var description: String {
        switch self {
        case .executableNotFound(let kind):
            "Couldn't find the \(kind.executableName) command. Install \(kind == .codex ? "Codex CLI" : "Claude Code") or set its path in the harness settings."
        case .unsupportedProvider(let message): message
        case .startupFailed(let message): "The agent didn't start: \(message)"
        case .protocolError(let message): "The agent sent something unexpected: \(message)"
        case .notRunning: "The agent isn't running."
        case .unknownRequest(let id): "No pending request \(id)."
        }
    }
}

/// An agent program that runs OpenClicky's background jobs (Codex CLI, Claude Code, or a test fake).
public protocol AgentHarness: Sendable {
    var kind: HarnessKind { get }
    /// Launches the harness in the job folder and starts its first turn with `message`.
    func start(_ launch: HarnessLaunch, message: String, images: [URL]) async throws -> any AgentHarnessSession
}

/// One running harness process for one job. Turns come and go; the session lives until `close()`.
public protocol AgentHarnessSession: Sendable {
    /// Normalized events for every turn of the session. Finishes when the process exits.
    var events: AsyncStream<AgentEvent> { get }
    /// A follow-up: steers the running turn, queues it, or starts a new turn.
    func send(_ message: String) async throws -> AgentSendDisposition
    func interrupt() async
    /// Answers an `approvalRequested` event.
    func respond(to requestID: String, with decision: AgentApprovalDecision) async throws
    /// Ends the process (gracefully, then forcefully).
    func close() async
}

// MARK: - Finding the harness and building its environment

public enum HarnessEnvironment {
    /// Folders where harness CLIs and their runtimes (node, bun) usually live. Apps launched from Finder get a
    /// minimal PATH, so these are searched and prepended for the child.
    public static func searchFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
         "\(home)/.volta/bin", "\(home)/.claude/local", "\(home)/.local/share/mise/shims", "/opt/local/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    /// The harness executable: the configured override, else the first match on PATH or the usual folders.
    public static func locate(_ kind: HarnessKind, override: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        if let override { return manager.isExecutableFile(atPath: override.path) ? override : nil }
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for folder in pathEntries + searchFolders(home: environment["HOME"] ?? NSHomeDirectory()) {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(kind.executableName)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Variables an agent host sets for its own children. Inherited by a harness (say, when occtl runs inside a
    /// Claude Code or Codex session) they make it think it is nested in that session, so they never pass through.
    public static let nestedSessionMarkers = [
        "CLAUDECODE", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CODE_MESSAGING_*", "CLAUDE_CODE_SESSION_*", "CLAUDE_CODE_SSE_PORT", "CLAUDE_EFFORT", "CLAUDE_PID",
        "CODEX_SANDBOX*", "CODEX_THREAD_ID", "CODEX_TURN_ID",
    ]

    /// Model keys and endpoints a shell may export. A harness gets only the ones OpenClicky sets for it, so a key
    /// lying around in the user's shell never decides which account a job bills, or leaks into its commands.
    public static let modelCredentialVariables = [
        "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_MODEL",
    ]

    /// The child's environment: the parent's, minus OpenClicky's own secrets and anything that would make the
    /// harness use a different account or think it is nested in another agent, plus `adding`.
    /// `stripping` holds exact names, or prefixes ending in `*`.
    public static func child(base: [String: String], stripping patterns: [String], adding: [String: String], executable: URL?) -> [String: String] {
        let patterns = patterns + ["OPENCLICKY_KEY_*", "OPENCLICKY_MCP_TOKEN_*", "OPENCLICKY_APP_*", "OPENCLICKY_COMPOSIO_*"]
            + modelCredentialVariables + nestedSessionMarkers
        func matches(_ key: String, _ pattern: String) -> Bool {
            pattern.hasSuffix("*") ? key.hasPrefix(String(pattern.dropLast())) : key == pattern
        }
        var environment = base.filter { key, _ in !patterns.contains { matches(key, $0) } }
        // The harness's own folder first (its launcher may need a sibling runtime), then the inherited PATH in its
        // order, then the usual tool folders a Finder-launched app's minimal PATH lacks.
        var path: [String] = []
        let candidates = [executable?.deletingLastPathComponent().path].compactMap { $0 }
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + searchFolders(home: base["HOME"] ?? NSHomeDirectory())
        for folder in candidates where !folder.isEmpty && !path.contains(folder) { path.append(folder) }
        environment["PATH"] = path.joined(separator: ":")
        // Local model servers and the browser bridge's MCP live on loopback; a system proxy must never see them.
        for key in ["NO_PROXY", "no_proxy"] {
            var hosts = (environment[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for host in ["localhost", "127.0.0.1", "::1"] where !hosts.contains(host) { hosts.append(host) }
            environment[key] = hosts.joined(separator: ",")
        }
        for (key, value) in adding { environment[key] = value }
        return environment
    }
}

// MARK: - Child process with line-oriented pipes

/// A child process whose stdout and stderr arrive as lines and whose stdin takes lines.
final class HarnessProcess: @unchecked Sendable {
    let stdoutLines: AsyncStream<String>
    let stderrLines: AsyncStream<String>
    private let stdoutContinuation: AsyncStream<String>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    /// Guards the state below. Never held across a blocking call.
    private let lock = NSLock()
    /// Serializes writes to stdin. A write can block for good when the child stops reading, so nothing that has to
    /// make progress regardless (exit handling, `isRunning`, `terminate`) ever waits on this lock.
    private let writeLock = NSLock()
    private var stdinOpen = true
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var recentStderr: [String] = []

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) {
        (stdoutLines, stdoutContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        (stderrLines, stderrContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var processIdentifier: Int32 { process.processIdentifier }

    func start() throws {
        // A harness that dies while we write to it must not take the app down with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        process.terminationHandler = { [weak self] finished in self?.didExit(finished.terminationStatus) }
        attach(stdoutPipe.fileHandleForReading, to: stdoutContinuation, keepTail: false)
        attach(stderrPipe.fileHandleForReading, to: stderrContinuation, keepTail: true)
        try process.run()
    }

    private func attach(_ handle: FileHandle, to continuation: AsyncStream<String>.Continuation, keepTail: Bool) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let last = buffer.flush() { self?.deliver(last, to: continuation, keepTail: keepTail) }
                continuation.finish()
                return
            }
            for line in buffer.append(data) { self?.deliver(line, to: continuation, keepTail: keepTail) }
        }
    }

    private func deliver(_ line: String, to continuation: AsyncStream<String>.Continuation, keepTail: Bool) {
        if keepTail {
            lock.withLock {
                recentStderr.append(line)
                if recentStderr.count > 20 { recentStderr.removeFirst() }
            }
        }
        continuation.yield(line)
    }

    /// The last few stderr lines, for error messages.
    var stderrTail: String { lock.withLock { recentStderr.suffix(6).joined(separator: "\n") } }

    func writeLine(_ line: String) throws {
        try writeLock.withLock {
            guard lock.withLock({ stdinOpen }) else { throw AgentHarnessError.notRunning }
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func closeStdin() {
        let wasOpen: Bool = lock.withLock {
            defer { stdinOpen = false }
            return stdinOpen
        }
        guard wasOpen else { return }
        // A write stuck on a child that stopped reading holds the write lock. Leave the handle open then: the
        // signals that follow end the child, the stuck write fails with EPIPE, and the Pipe closes the handle.
        guard writeLock.try() else { return }
        defer { writeLock.unlock() }
        try? stdinPipe.fileHandleForWriting.close()
    }

    var isRunning: Bool { lock.withLock { exitStatus == nil } && process.isRunning }

    func send(signal number: Int32) {
        if isRunning { kill(process.processIdentifier, number) }
    }

    /// SIGTERM, then SIGKILL if it hasn't exited after `grace` seconds.
    func terminate(grace: TimeInterval = 3) async {
        closeStdin()
        guard isRunning else { return }
        send(signal: SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if isRunning { send(signal: SIGKILL) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status: Int32? = lock.withLock {
                if let exitStatus { return exitStatus }
                exitWaiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    private func didExit(_ status: Int32) {
        let waiters: [CheckedContinuation<Int32, Never>] = lock.withLock {
            exitStatus = status
            stdinOpen = false
            defer { exitWaiters.removeAll() }
            return exitWaiters
        }
        waiters.forEach { $0.resume(returning: status) }
    }
}

/// Splits a byte stream into UTF-8 lines.
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    func flush() -> String? {
        lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}
