import Foundation
import OpenClickyKit
import os

/// The browser bridge as the app runs it: the Unix socket the extension's native host connects to, and the loopback
/// MCP server background jobs call as `openclicky_browser`. Starting it writes `BrowserBridge/mcp.json`, which
/// `AgentMCPDiscovery` reads at every job launch, so app-launched jobs get the browser tool; quitting removes it.
///
/// Jobs' turns are bound here: `AgentServices` reports each turn's start and end, so calls after a turn are refused
/// and the tabs a turn opened and didn't keep are closed when it ends.
///
/// Another process may already serve the bridge (`occtl browser mcp-serve`): then the app leaves it alone, and jobs
/// use that one through the same endpoint file (unbound: no turn checks, no tidying).
final class AppBrowserBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "app.openclicky", category: "browser-bridge")
    private let lock = NSLock()
    private var service: BrowserBridgeService?
    private let paths: BrowserBridgePaths
    private var _askForChromeSetup: (@Sendable (String) async -> Bool)?
    private var _approveChange: (@Sendable (BrowserChangeRequest) async -> Bool)?
    private var _onBrowserConnected: (@Sendable () -> Void)?
    private var hadPeers = false
    private var peersHandler: (@Sendable ([BrowserPeer]) -> Void)?

    /// Called with the connected browsers whenever the extension connects or leaves (the notch's browser events).
    /// Only for a bridge this app serves; read at each change, after the bridge's own bookkeeping (`peersChanged`).
    var onPeersChanged: (@Sendable ([BrowserPeer]) -> Void)? {
        get { lock.withLock { peersHandler } }
        set { lock.withLock { peersHandler = newValue } }
    }

    init(paths: BrowserBridgePaths = .standard) { self.paths = paths }

    /// Where the MCP server listens, once started.
    var endpoint: BrowserMCPEndpoint? { lock.withLock { service?.endpoint } }

    /// A job called the browser while none is connected (raises its `chrome_setup` request).
    var askForChromeSetup: (@Sendable (String) async -> Bool)? {
        get { lock.withLock { _askForChromeSetup } }
        set {
            let running = lock.withLock { () -> BrowserBridgeService? in
                _askForChromeSetup = newValue
                return service
            }
            running?.toolEnvironment.askForChromeSetup = newValue
        }
    }

    var approveChange: (@Sendable (BrowserChangeRequest) async -> Bool)? {
        get { lock.withLock { _approveChange } }
        set {
            let running = lock.withLock { () -> BrowserBridgeService? in
                _approveChange = newValue
                return service
            }
            running?.toolEnvironment.approveChange = newValue
        }
    }

    /// A browser connected after none was (jobs waiting for Chrome carry on).
    var onBrowserConnected: (@Sendable () -> Void)? {
        get { lock.withLock { _onBrowserConnected } }
        set { lock.withLock { _onBrowserConnected = newValue } }
    }

    /// Starts the bridge off the main thread (binding sockets and writing files). Safe to call more than once.
    /// - Parameter extraTools: served next to the browser tool (OpenClicky's job tools).
    func start(extraTools: [MCPTool] = []) {
        DispatchQueue.global(qos: .utility).async { [self] in
            if lock.withLock({ service != nil }) { return }
            if let running = BrowserMCPEndpoint.loadIfRunning(from: paths), running.pid != getpid() {
                log.info("browser bridge already served by pid \(running.pid, privacy: .public); not starting another")
                return
            }
            do {
                let made = try BrowserBridgeService(paths: paths)
                made.toolEnvironment.askForChromeSetup = lock.withLock { _askForChromeSetup }
                made.toolEnvironment.approveChange = lock.withLock { _approveChange }
                made.bridge.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
                let endpoint = try made.start(extraTools: extraTools)
                lock.withLock { service = made }
                log.info("browser bridge up; agents' MCP at \(endpoint.url.absoluteString, privacy: .public)")
            } catch {
                log.error("browser bridge didn't start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        let running = lock.withLock { () -> BrowserBridgeService? in
            defer { service = nil }
            return service
        }
        running?.stop()
    }

    /// Remembers the first connection ever (Settings shows a notice), tells waiting jobs a browser is here, and passes
    /// the change on (`onPeersChanged`).
    private func peersChanged(_ peers: [BrowserPeer]) {
        var preferences = BrowserBridgePreferences.load(from: paths)
        let before = preferences
        if preferences.noteConnected(peers) { log.info("first browser connection on this Mac") }
        if preferences != before { try? preferences.save(to: paths) }
        let (connectedNow, observer, handler) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?, (@Sendable ([BrowserPeer]) -> Void)?) in
            defer { hadPeers = !peers.isEmpty }
            return (!hadPeers && !peers.isEmpty, _onBrowserConnected, peersHandler)
        }
        if connectedNow { observer?() }
        handler?(peers)
    }

    // MARK: Turns

    func beginTurn(jobID: String, title: String?, folder: URL?) {
        lock.withLock { service }?.turns.beginTurn(jobID: jobID, title: title, folder: folder)
    }

    func noteThread(jobID: String, threadID: String) {
        lock.withLock { service }?.turns.noteThread(jobID: jobID, threadID: threadID)
    }

    /// Ends the job's turn now (its later calls are refused) and returns how to tidy it up; nil when no turn runs.
    func endTurn(jobID: String) -> (@Sendable () async -> BrowserTurnUsage?)? {
        guard let running = lock.withLock({ service }), let ending = running.turns.endTurn(jobID: jobID) else { return nil }
        return { await running.tidy(ending) }
    }

    // MARK: Status for the brain

    /// The connection as the brain should hear it: this app's bridge if it runs one, else a probe of whoever does.
    func connectionState() -> BrowserConnectionState {
        if let running = lock.withLock({ service }) {
            let peers = running.bridge.peers
            return peers.isEmpty ? .waitingForExtension : .connected(peers)
        }
        return BrowserConnectionState.from(probe: Result { try BrowserBridgeProbe.status(paths: paths) })
    }

    /// The `[Browser]` turn note (sent to the brain only when its text changes).
    func brainNote() -> String {
        BrowserBrainNote.make(state: connectionState(), chromiumInstalled: !ChromiumProfileDiscovery.installed().isEmpty)
    }
}
