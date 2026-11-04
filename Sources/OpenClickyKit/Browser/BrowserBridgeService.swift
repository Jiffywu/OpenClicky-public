import Foundation

/// Everything the app (or `occtl browser mcp-serve`) runs for the browser bridge: the Unix-socket server native hosts
/// connect to, and the loopback MCP server agents call. Starting it writes `BrowserBridge/mcp.json` for harnesses;
/// stopping it removes that file.
public final class BrowserBridgeService: @unchecked Sendable {
    public static let serverVersion = "0.1.0"

    public let paths: BrowserBridgePaths
    public let bridge: BrowserBridgeServer
    /// Turn binding, tab ownership and per-turn counters for the `browser` tool.
    public let turns: BrowserTurnRegistry
    /// What the `browser` tool reaches; the app sets its setup and approval hooks once jobs can be asked.
    public let toolEnvironment: BrowserToolEnvironment
    private let mcpToken: String
    private let lock = NSLock()
    private var mcp: MCPHTTPServer?
    private var _endpoint: BrowserMCPEndpoint?

    /// - Parameters:
    ///   - allowedExtensionIDs: extension IDs whose hosts may connect; OpenClicky's own plus the extra-IDs file by default.
    public init(paths: BrowserBridgePaths = .standard, allowedExtensionIDs: [String]? = nil) throws {
        self.paths = paths
        let token = try paths.loadOrCreateToken()
        let ids = allowedExtensionIDs ?? ChromeExtensionIdentity.allowedIDs(paths: paths)
        self.bridge = BrowserBridgeServer(paths: paths, token: token, allowedOrigins: ids.map(ChromeExtensionIdentity.origin(for:)))
        // The profile chosen in Settings → Browser, when several are connected.
        bridge.preferredProfile = BrowserBridgePreferences.load(from: paths).preferredProfileID
        self.mcpToken = try BrowserBridgeSecrets.randomHex(bytes: 32)
        let turns = BrowserTurnRegistry()
        self.turns = turns
        self.toolEnvironment = BrowserToolEnvironment(bridge: bridge, turns: turns)
        // A browser that (re)connects first hears which jobs are still running, so it can close tabs left by jobs
        // that ended while it was away.
        let bridge = self.bridge
        // Stop in a browser hands the jobs' tabs there to the user.
        bridge.onStop = { [weak turns] peer in turns?.userStopped(profile: peer.profileId) }
        bridge.onHostConnected = { [weak turns] peer in
            guard let turns else { return }
            let running = turns.activeJobs
            Task.detached {
                _ = try? await bridge.send("sweep", arguments: ["running": .array(running.map { .string($0) })],
                                           profile: peer.profileId, timeout: 15)
            }
        }
    }

    /// A job's turn ended: refuse its later calls, close the tabs it opened and didn't keep, and return what the
    /// turn did with the browser (nil when it didn't use it).
    public func endTurn(jobID: String) async -> BrowserTurnUsage? {
        guard let ending = turns.endTurn(jobID: jobID) else { return nil }
        return await tidy(ending)
    }

    /// The second half of `endTurn`, for a turn already ended in `turns` (the app ends it in order with the job's
    /// events, then tidies in the background, when the job's next turn may be running): closes the tabs the turn
    /// opened and didn't keep, and returns its usage.
    public func tidy(_ ending: BrowserTurnRegistry.Ending) async -> BrowserTurnUsage? {
        let jobID = ending.jobID
        var usage = ending.usage
        // Each tab closes in the browser it was opened in; a browser that isn't connected now is left alone.
        let byProfile = Dictionary(grouping: ending.tabsToClose.filter { ending.tabProfiles[$0] != nil }) { ending.tabProfiles[$0]! }
        for (profile, tabs) in byProfile.sorted(by: { $0.key < $1.key }) {
            let ids = tabs.map { JSONValue.number(Double($0)) }
            if let result = try? await bridge.dispatch("close", arguments: ["tabIds": .array(ids), "tidy": true], profile: profile, timeout: 15,
                                                       envelope: ["task": .string(jobID)]).result {
                usage?.tabsClosed += result["closed"]?.arrayValue?.count ?? 0
            }
        }
        return usage
    }

    deinit { stop() }

    /// The running MCP endpoint, once started.
    public var endpoint: BrowserMCPEndpoint? { lock.withLock { _endpoint } }

    /// Starts both servers and publishes the endpoint file.
    /// - Parameter mcpPort: 0 picks a free port.
    @discardableResult
    public func start(mcpPort: UInt16 = 0, extraTools: [MCPTool] = []) throws -> BrowserMCPEndpoint {
        try bridge.start()
        let server = MCPHTTPServer(name: BrowserMCPEndpoint.serverName, version: Self.serverVersion, token: mcpToken,
                                   tools: [BrowserTool.makeTool(toolEnvironment)] + extraTools,
                                   instructions: "Use the browser tool to act in the user's signed-in browser tabs.")
        let url: URL
        do {
            url = try server.start(port: mcpPort)
        } catch {
            bridge.stop()
            throw error
        }
        let endpoint = BrowserMCPEndpoint(url: url, token: mcpToken)
        do {
            try endpoint.write(to: paths)
        } catch {
            // Without the endpoint file no agent can find the server; don't leave it or the socket running.
            server.stop()
            bridge.stop()
            throw error
        }
        lock.withLock {
            mcp = server
            _endpoint = endpoint
        }
        return endpoint
    }

    public func stop() {
        let (server, endpoint) = lock.withLock { () -> (MCPHTTPServer?, BrowserMCPEndpoint?) in
            defer {
                mcp = nil
                _endpoint = nil
            }
            return (mcp, _endpoint)
        }
        server?.stop()
        bridge.stop()
        // Remove the endpoint file only if it is still ours (another process may have started since).
        if let endpoint, let onDisk = try? BrowserMCPEndpoint.load(from: paths), onDisk.token == endpoint.token {
            try? FileManager.default.removeItem(at: paths.mcpEndpoint)
        }
    }
}
