// stdio transport for local MCP servers ("Command on this Mac").
//
// Checked against https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio on
// 2026-10-30:
// - The client launches the server; messages are single JSON-RPC objects, one per line, with no embedded
//   newlines, on stdin (client → server) and stdout (server → client).
// - stderr is free-form logging; it does not mean an error. OpenClicky keeps the last few KB for diagnostics.
// - Cancelling an in-flight request means sending `notifications/cancelled` with the request id.
// - Shutdown: close the server's stdin, wait, then SIGTERM, then SIGKILL.
// - Credentials come from the environment, not from the HTTP authorization flow.

import Foundation

/// Splits a byte stream into newline-delimited messages. Tolerates CRLF, blank lines and chunks that end
/// mid-line or mid-UTF-8 sequence.
public struct NewlineJSONFramer: Sendable {
    private var pending = Data()
    /// Lines longer than this are dropped (protects against a server that never writes a newline).
    public var maximumLineLength: Int

    public init(maximumLineLength: Int = 16 * 1024 * 1024) { self.maximumLineLength = maximumLineLength }

    /// Complete lines in the chunk, without their newline. Blank lines are skipped.
    public mutating func feed(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            pending.removeSubrange(pending.startIndex...newline)
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { lines.append(Data(line)) }
        }
        if pending.count > maximumLineLength { pending.removeAll() }
        return lines
    }

    /// A final line the stream ended without a newline for.
    public mutating func finish() -> Data? {
        defer { pending.removeAll() }
        let trimmed = pending.filter { $0 != 0x0D }
        return trimmed.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) ? nil : Data(trimmed)
    }

    /// One outgoing message as a line.
    public static func frame(_ message: MCPOutgoingMessage) -> Data { message.encoded + Data([0x0A]) }
}

/// How to start a local server.
public struct MCPStdioLaunch: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]
    /// The whole environment for the child (resolve with `MCPCommandResolver.environment`).
    public var environment: [String: String]
    public var currentDirectory: URL?

    public init(executable: URL, arguments: [String] = [], environment: [String: String], currentDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// Finds commands the way a login shell would, even from a GUI app whose PATH is minimal.
public enum MCPCommandResolver {
    /// Places package managers install MCP servers' runtimes (node, bun, uv, cargo …), searched after PATH.
    public static func extraSearchPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
         home.appendingPathComponent(".cargo/bin").path, home.appendingPathComponent(".bun/bin").path,
         home.appendingPathComponent(".volta/bin").path, home.appendingPathComponent(".deno/bin").path]
    }

    /// PATH for the child: the current PATH plus the extra locations, without duplicates.
    public static func searchPath(base: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var seen = Set<String>()
        let parts = (base ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init) + extraSearchPaths(home: home)
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The executable for `command`: a path is used as given; a bare name is looked up on `searchPath`.
    public static func resolve(_ command: String, searchPath: String) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Variables a local server inherits from OpenClicky. Everything else in OpenClicky's environment (API keys,
    /// `OPENCLICKY_KEY_*` overrides, tokens exported in the user's shell) stays out of third-party servers; a
    /// server gets its own secrets only through the connector's saved environment values. The official MCP SDKs
    /// use the same kind of short list for the servers they launch.
    public static let inheritedVariables: Set<String> = ["HOME", "LOGNAME", "USER", "SHELL", "TERM", "TMPDIR", "LANG",
                                                          "__CF_USER_TEXT_ENCODING"]

    /// The child's environment: the basic variables above (plus `LC_*` locale settings), the widened PATH, then the
    /// connector's own values.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment,
                                   adding extra: [String: String]) -> [String: String] {
        var environment = base.filter { inheritedVariables.contains($0.key) || $0.key.hasPrefix("LC_") }
        environment["PATH"] = searchPath(base: base["PATH"])
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}

/// Talks to one child process. Responses are matched to requests by id; notifications go to `onNotification`;
/// server-to-client requests are answered with "method not found" (OpenClicky declares no client capabilities).
public final class MCPStdioTransport: MCPMessageTransport, @unchecked Sendable {
    public let launch: MCPStdioLaunch
    private let onNotification: (@Sendable (String, JSONValue?) -> Void)?
    private let lock = NSLock()
    /// Serializes writes to stdin. A message larger than the pipe buffer takes several write(2) calls, and two
    /// tasks writing at once would interleave their bytes into broken lines.
    private let writeLock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [JSONRPCID: CheckedContinuation<Result<JSONValue, JSONRPCError>, Error>] = [:]
    private var exitError: MCPClientError?
    private var stderrTail = Data()
    private static let stderrLimit = 8_192

    public init(launch: MCPStdioLaunch, onNotification: (@Sendable (String, JSONValue?) -> Void)? = nil) {
        self.launch = launch
        self.onNotification = onNotification
    }

    public var mirrorsParameterHeaders: Bool { false }

    /// The end of what the server printed to stderr.
    public var recentStandardError: String {
        lock.withLock { String(decoding: stderrTail, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// Starts the child. Called automatically by the first message. A server that has exited stays down: its
    /// state is gone, so the owner must make a new client (and transport) rather than talk to a fresh process
    /// that was never initialized.
    public func start() throws {
        try lock.withLock {
            guard process == nil else { return }
            if let exitError { throw exitError }
            let process = Process()
            process.executableURL = launch.executable
            process.arguments = launch.arguments
            process.environment = launch.environment
            if let directory = launch.currentDirectory { process.currentDirectoryURL = directory }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // A write to a server that already died must fail with EPIPE, not kill OpenClicky with SIGPIPE.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.terminationHandler = { [weak self] finished in self?.processExited(finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                throw MCPClientError.launchFailed("\(launch.executable.path): \(error.localizedDescription)")
            }
            self.process = process
            self.stdin = input.fileHandleForWriting
            startReader(output.fileHandleForReading)
            startStderrReader(errors.fileHandleForReading)
        }
    }

    public func resetSession() async {}

    public func notify(_ notification: MCPOutgoingMessage, context: MCPRequestContext) async throws {
        try start()
        try write(NewlineJSONFramer.frame(notification))
    }

    public func send(_ request: MCPOutgoingMessage, context: MCPRequestContext) async throws -> Result<JSONValue, JSONRPCError> {
        guard let id = request.id else { throw MCPClientError.invalidResponse("a request needs an id") }
        try start()
        let timeout = context.timeout
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.fail(id, with: MCPClientError.timedOut(method: request.method))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let failure: Error? = lock.withLock {
                    if let exitError { return exitError }
                    if Task.isCancelled { return CancellationError() }
                    pending[id] = continuation
                    return nil
                }
                if let failure { continuation.resume(throwing: failure); return }
                do {
                    try write(NewlineJSONFramer.frame(request))
                } catch {
                    fail(id, with: error)
                }
            }
        } onCancel: {
            if self.fail(id, with: CancellationError()) {
                let cancel = MCPOutgoingMessage(id: nil, method: "notifications/cancelled",
                                                params: ["requestId": id.json, "reason": "The user cancelled the request."])
                try? self.write(NewlineJSONFramer.frame(cancel))
            }
        }
    }

    /// Close stdin, wait up to `grace`, then SIGTERM, then SIGKILL.
    public func close() async {
        await shutdown(grace: .seconds(2))
    }

    public func shutdown(grace: Duration) async {
        let (process, input) = lock.withLock { (self.process, self.stdin) }
        guard let process else { return }
        try? input?.close()
        if await waitForExit(process, within: grace) { return }
        process.terminate() // SIGTERM
        if await waitForExit(process, within: grace) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(process, within: grace)
    }

    // MARK: Internals

    private func write(_ data: Data) throws {
        let handle: FileHandle? = lock.withLock { stdin }
        guard let handle else { throw lock.withLock { exitError } ?? MCPClientError.launchFailed("not running") }
        do {
            try writeLock.withLock { try handle.write(contentsOf: data) }
        } catch {
            throw lock.withLock { exitError } ?? MCPClientError.processExited(status: -1, stderr: recentStandardError)
        }
    }

    /// Resumes the waiter for `id` with an error. Returns false if it had already been answered.
    @discardableResult
    private func fail(_ id: JSONRPCID, with error: Error) -> Bool {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: error)
        return continuation != nil
    }

    private func startReader(_ handle: FileHandle) {
        let thread = Thread { [weak self] in
            var framer = NewlineJSONFramer()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                for line in framer.feed(chunk) { self?.handleLine(line) }
            }
            if let line = framer.finish() { self?.handleLine(line) }
        }
        thread.name = "OpenClicky MCP stdio reader"
        thread.start()
    }

    private func startStderrReader(_ handle: FileHandle) {
        let thread = Thread { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                guard let self else { break }
                self.lock.withLock {
                    self.stderrTail.append(chunk)
                    if self.stderrTail.count > Self.stderrLimit { self.stderrTail.removeFirst(self.stderrTail.count - Self.stderrLimit) }
                }
            }
        }
        thread.name = "OpenClicky MCP stdio stderr"
        thread.start()
    }

    private func handleLine(_ line: Data) {
        // Anything that is not JSON-RPC is ignored: the spec forbids it, but some servers print banners anyway.
        guard let messages = MCPIncomingMessage.parseAll(line) else { return }
        for message in messages {
            switch message {
            case .response(let id, let result):
                lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: .success(result))
            case .error(let id?, let error):
                lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: .failure(error))
            case .error(nil, _):
                break
            case .notification(let method, let params):
                onNotification?(method, params)
            case .request(let id, let method, _):
                let reply: JSONValue = ["jsonrpc": "2.0", "id": id.json,
                                        "error": ["code": .number(Double(JSONRPCError.methodNotFound)),
                                                  "message": .string("OpenClicky does not support \(method)")]]
                try? write(Data(reply.jsonString().utf8) + Data([0x0A]))
            }
        }
    }

    private func processExited(_ status: Int32) {
        // Give the stderr reader a moment to drain so the error says why the server died.
        Thread.sleep(forTimeInterval: 0.05)
        let stderr = recentStandardError
        let waiters: [CheckedContinuation<Result<JSONValue, JSONRPCError>, Error>] = lock.withLock {
            let error = MCPClientError.processExited(status: status, stderr: String(stderr.suffix(1_000)))
            exitError = error
            process = nil
            stdin = nil
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        let error = MCPClientError.processExited(status: status, stderr: String(stderr.suffix(1_000)))
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func waitForExit(_ process: Process, within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while process.isRunning {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
