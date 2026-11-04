import Foundation

/// One connected browser profile: an OpenClicky extension instance reached through a native host process.
public struct BrowserPeer: Sendable, Hashable, Codable {
    /// Assigned by the bridge for this connection.
    public var id: String
    /// The native host process's session UUID.
    public var session: String
    /// The extension's persistent per-profile UUID.
    public var profileId: String
    /// `chrome-extension://<id>/`
    public var origin: String
    /// Bundle ID of the browser that launched the host (`com.google.Chrome`, `company.thebrowser.Browser`, …); empty if unknown.
    public var browser: String
    public var extensionVersion: String?
    public var connectedAt: Date
    public var lastSeen: Date

    /// A readable browser name for status lines.
    public var browserName: String {
        NativeHostInstaller.browsers.first { $0.bundleID == browser }?.displayName ?? (browser.isEmpty ? "Chromium browser" : browser)
    }
}

public struct BrowserBridgeError: Error, Sendable, CustomStringConvertible, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// No extension is connected (or not the requested profile).
        case notConnected
        /// The browser didn't answer in time; the action's outcome is unknown.
        case timeout
        /// The browser went away while the command was in flight.
        case disconnected
        /// The user pressed Stop in the extension.
        case stopped
        /// The extension ran the command and reported a failure.
        case failed
        case invalidRequest
        /// The call's agent turn already ended.
        case turnEnded
        /// The browser reconnected since the turn's first call; tabs and refs from before may be gone.
        case connectionChanged
        /// An acting call timed out earlier in this turn, so the turn may no longer act in the browser.
        case accessEnded
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
}

/// The app's end of the browser bridge. Listens on a Unix-domain socket for native host processes, checks each
/// one's per-install token and extension origin, and sends commands to a connected extension, matching results by id.
///
/// Wire protocol (both directions use native-messaging framing; see docs/browser-bridge.md):
/// - host → app, first message: `{type:"auth", token, protocol:1, session, profileId, origin, browser, extensionVersion}`
///   answered by `{type:"welcome", peerId}` or `{type:"denied", reason}`.
/// - app → host → extension: `{type:"command", id, operation, args}` and `{type:"ping"}`.
/// - extension → host → app: `{type:"result", id, ok, result | error}`, `{type:"pong"}`, `{type:"stop"}`.
/// - a local status probe: `{type:"status", token}` answered by `{type:"status", peers}`.
public final class BrowserBridgeServer: @unchecked Sendable {
    public static let protocolVersion = 1

    public let paths: BrowserBridgePaths
    private let token: String
    private let allowedOrigins: Set<String>
    private let pingInterval: TimeInterval
    private let lock = NSLock()
    private var acceptor: SocketAcceptor?
    private var connections: [String: Connection] = [:]
    private var pending: [String: Pending] = [:]
    private var timer: DispatchSourceTimer?
    /// True between `start()` and `stop()`; hosts that finish their handshake outside that window are turned away.
    private var running = false
    private let timeouts = DispatchQueue(label: "com.openclicky.browser-bridge.timeouts")
    private var _preferredProfile: String?
    private var peersObserver: (@Sendable ([BrowserPeer]) -> Void)?
    private var hostObserver: (@Sendable (BrowserPeer) -> Void)?
    private var stopObserver: (@Sendable (BrowserPeer) -> Void)?
    /// Counts host registrations; each connection keeps the value it got, so a turn can tell the browser reconnected.
    private var generationCounter = 0
    private var _lastFailure: BrowserSetupFailure?

    private final class Connection: @unchecked Sendable {
        let channel: FramedChannel
        var peer: BrowserPeer
        let generation: Int
        init(channel: FramedChannel, peer: BrowserPeer, generation: Int) {
            self.channel = channel
            self.peer = peer
            self.generation = generation
        }
    }

    private struct Pending {
        var peerID: String
        var continuation: CheckedContinuation<JSONValue, Error>
    }

    public init(paths: BrowserBridgePaths, token: String, allowedOrigins: [String], pingInterval: TimeInterval = 20) {
        self.paths = paths
        self.token = token
        self.allowedOrigins = Set(allowedOrigins)
        self.pingInterval = pingInterval
    }

    deinit { stop() }

    /// Called (on a background thread) whenever a browser connects or disconnects.
    public var onPeersChanged: (@Sendable ([BrowserPeer]) -> Void)? {
        get { lock.withLock { peersObserver } }
        set { lock.withLock { peersObserver = newValue } }
    }

    /// Profile that should receive commands when several are connected; nil = the most recently connected one.
    public var preferredProfile: String? {
        get { lock.withLock { _preferredProfile } }
        set { lock.withLock { _preferredProfile = newValue } }
    }

    /// Called (on a background thread) right after a browser's host connects, before any command reaches it.
    public var onHostConnected: (@Sendable (BrowserPeer) -> Void)? {
        get { lock.withLock { hostObserver } }
        set { lock.withLock { hostObserver = newValue } }
    }

    /// Called (on a background thread) when the user presses Stop in a browser's extension, in flight or not.
    public var onStop: (@Sendable (BrowserPeer) -> Void)? {
        get { lock.withLock { stopObserver } }
        set { lock.withLock { stopObserver = newValue } }
    }

    /// The latest reason a browser couldn't connect or reported a setup problem; cleared by the next good connection
    /// that reports nothing.
    public var lastFailure: BrowserSetupFailure? { lock.withLock { _lastFailure } }

    private func noteFailure(_ reason: String, browser: String = "") {
        lock.withLock { _lastFailure = BrowserSetupFailure(reason: reason, browser: browser, at: Date()) }
    }

    public var peers: [BrowserPeer] {
        lock.withLock { connections.values.map(\.peer) }.sorted { $0.connectedAt < $1.connectedAt }
    }

    public var isConnected: Bool { lock.withLock { !connections.isEmpty } }

    public func start() throws {
        try paths.prepareDirectory()
        let fd = try BridgeSocket.listenUnix(path: paths.socket.path)
        lock.withLock { running = true }
        let acceptor = SocketAcceptor(listener: fd, unlinkOnCancel: paths.socket.path, label: "com.openclicky.browser-bridge.accept") { [weak self] client in
            guard let self else { Darwin.close(client); return }
            Thread.detachNewThread { self.serve(client) }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.openclicky.browser-bridge.ping"))
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.resume()
        lock.withLock {
            self.acceptor = acceptor
            self.timer = timer
        }
    }

    public func stop() {
        let (acceptor, timer, open, waiting) = lock.withLock { () -> (SocketAcceptor?, DispatchSourceTimer?, [Connection], [Pending]) in
            defer {
                running = false
                self.acceptor = nil
                self.timer = nil
                connections.removeAll()
                pending.removeAll()
            }
            return (self.acceptor, self.timer, Array(connections.values), Array(pending.values))
        }
        acceptor?.cancel()
        timer?.cancel()
        open.forEach { $0.channel.close() }
        waiting.forEach { $0.continuation.resume(throwing: BrowserBridgeError(.disconnected, "OpenClicky's browser bridge stopped.")) }
    }

    // MARK: Commands

    /// Sends one operation to the extension and waits for its result.
    /// - Parameters:
    ///   - profile: a specific profile; nil picks `preferredProfile` if connected, else the newest connection.
    ///   - timeout: seconds before the call fails with `.timeout`.
    public func send(_ operation: String, arguments: [String: JSONValue] = [:], profile: String? = nil,
                     timeout: TimeInterval = 30) async throws -> JSONValue {
        try await dispatch(operation, arguments: arguments, profile: profile, timeout: timeout).result
    }

    /// `send` with more: fields added to the command envelope (`task`, `groupTitle`), and the connection generation
    /// the caller's turn is tied to. With a generation the call goes to that connection, even when another browser
    /// connected since; once it is gone the call fails with `.connectionChanged` before anything is sent.
    /// Returns the result and the generation and profile of the connection that answered.
    public func dispatch(_ operation: String, arguments: [String: JSONValue] = [:], profile: String? = nil,
                         timeout: TimeInterval = 30, envelope: [String: JSONValue] = [:],
                         generation expected: Int? = nil) async throws -> (result: JSONValue, generation: Int, profile: String) {
        let id = UUID().uuidString.lowercased()
        var fields: [String: JSONValue] = envelope
        fields["type"] = "command"
        fields["id"] = .string(id)
        fields["operation"] = .string(operation)
        fields["args"] = .object(arguments)
        let message = JSONValue.object(fields)
        guard Data(message.jsonString().utf8).count < NativeMessageFraming.maxToExtension else {
            throw BrowserBridgeError(.invalidRequest, "That request is too large to send to the browser.")
        }
        let used = GenerationBox()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                var changed = false
                let target: Connection? = lock.withLock {
                    let selected: Connection?
                    if let expected, !connections.isEmpty {
                        selected = connections.values.first { $0.generation == expected }
                        // The turn's connection went away and another took its place.
                        changed = selected == nil
                    } else {
                        selected = selectConnection(profile: profile)
                    }
                    guard let connection = selected else { return nil }
                    pending[id] = Pending(peerID: connection.peer.id, continuation: continuation)
                    return connection
                }
                if changed {
                    continuation.resume(throwing: BrowserBridgeError(.connectionChanged, "Browser connection changed. Start a new turn."))
                    return
                }
                guard let target else {
                    let detail = profile.map { " for profile \($0)" } ?? ""
                    continuation.resume(throwing: BrowserBridgeError(.notConnected, "No OpenClicky browser extension is connected\(detail)."))
                    return
                }
                // The cancellation handler only sees calls already in `pending`. A task cancelled before that point
                // (the handler ran early and found nothing) is caught here, before the command goes out.
                if Task.isCancelled {
                    fail(id, CancellationError())
                    return
                }
                used.set(target.generation, target.peer.profileId)
                do {
                    try target.channel.write(message)
                } catch {
                    fail(id, BrowserBridgeError(.disconnected, "Couldn't reach the browser: \(error)"))
                    return
                }
                timeouts.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(id, BrowserBridgeError(.timeout, "The browser didn't answer within \(Int(timeout)) seconds; the action's outcome is unknown."))
                }
            }
        } onCancel: {
            fail(id, CancellationError())
        }
        let (generation, answeredBy) = used.value
        return (result, generation, answeredBy)
    }

    private final class GenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = (generation: 0, profile: "")
        var value: (generation: Int, profile: String) { lock.withLock { stored } }
        func set(_ generation: Int, _ profile: String) { lock.withLock { stored = (generation, profile) } }
    }

    private func selectConnection(profile: String?) -> Connection? {
        let all = connections.values.sorted { $0.peer.connectedAt > $1.peer.connectedAt }
        if let profile = profile?.lowercased() { return all.first { $0.peer.profileId == profile } }
        if let preferred = _preferredProfile, let match = all.first(where: { $0.peer.profileId == preferred }) { return match }
        return all.first
    }

    private func fail(_ id: String, _ error: Error) {
        lock.withLock { pending.removeValue(forKey: id) }?.continuation.resume(throwing: error)
    }

    /// Completes a command with a host's answer. Only the connection the command went to can answer it.
    private func resolve(_ id: String, from peerID: String, with message: JSONValue) {
        let entry = lock.withLock { () -> Pending? in
            guard let entry = pending[id], entry.peerID == peerID else { return nil }
            pending[id] = nil
            return entry
        }
        guard let entry else { return }
        if message["ok"]?.boolValue == true {
            entry.continuation.resume(returning: message["result"] ?? .object([:]))
        } else {
            let text = message["error"]?.stringValue ?? "The browser couldn't do that."
            // Refused because the user pressed Stop (before this call): as much the user's Stop as one in flight.
            let kind: BrowserBridgeError.Kind = message["code"]?.stringValue == "paused" ? .stopped : .failed
            entry.continuation.resume(throwing: BrowserBridgeError(kind, text))
        }
    }

    // MARK: Connections

    private func serve(_ fd: Int32) {
        let channel = FramedChannel(socket: fd, readLimit: NativeMessageFraming.maxFromExtension, writeLimit: NativeMessageFraming.maxToExtension)
        guard BridgeSocket.peerUID(fd) == getuid() else {
            channel.close()
            return
        }
        BridgeSocket.setReadTimeout(fd, seconds: 10)
        guard let first = try? channel.read() else {
            channel.close()
            return
        }
        let presented = first["token"]?.stringValue ?? ""
        guard BrowserBridgeSecrets.constantTimeEquals(presented, token) else {
            try? channel.write(["type": "denied", "reason": "bad token"])
            channel.close()
            return
        }
        switch first["type"]?.stringValue {
        case "status":
            let peers = (try? JSONValue.encodeCodable(self.peers)) ?? .array([])
            var reply: [String: JSONValue] = ["type": "status", "protocol": .number(Double(Self.protocolVersion)), "peers": peers]
            if let failure = lastFailure, let encoded = try? JSONValue.encodeCodable(failure) { reply["failure"] = encoded }
            try? channel.write(.object(reply))
            channel.close()
        case "auth":
            serveHost(channel, fd: fd, hello: first)
        default:
            try? channel.write(["type": "denied", "reason": "expected auth"])
            channel.close()
        }
    }

    private func serveHost(_ channel: FramedChannel, fd: Int32, hello: JSONValue) {
        let origin = hello["origin"]?.stringValue ?? ""
        let profile = hello["profileId"]?.stringValue ?? ""
        let browser = hello["browser"]?.stringValue ?? ""
        guard hello["protocol"]?.intValue == Self.protocolVersion else {
            noteFailure("The extension speaks a different bridge protocol (\(hello["protocol"]?.intValue.map(String.init) ?? "none")); update the extension or OpenClicky.", browser: browser)
            try? channel.write(["type": "denied", "reason": "unsupported protocol"])
            channel.close()
            return
        }
        guard allowedOrigins.contains(origin) else {
            noteFailure("A browser extension OpenClicky doesn't know (\(origin.prefix(80))) tried to connect. Load OpenClicky's own extension folder.", browser: browser)
            try? channel.write(["type": "denied", "reason": "extension not allowed"])
            channel.close()
            return
        }
        guard UUID(uuidString: profile) != nil else {
            noteFailure("The extension sent an unreadable profile id; reload it from the browser's extensions page.", browser: browser)
            try? channel.write(["type": "denied", "reason": "bad profile id"])
            channel.close()
            return
        }
        let now = Date()
        let peer = BrowserPeer(id: UUID().uuidString.lowercased(), session: hello["session"]?.stringValue ?? "",
                               profileId: profile.lowercased(), origin: origin, browser: hello["browser"]?.stringValue ?? "",
                               extensionVersion: hello["extensionVersion"]?.stringValue, connectedAt: now, lastSeen: now)
        let connection = Connection(channel: channel, peer: peer, generation: lock.withLock { () -> Int in
            generationCounter += 1
            return generationCounter
        })
        // Checked before the welcome and again when registering, so a host whose handshake straddles stop() is
        // dropped rather than left connected to a stopped bridge.
        guard lock.withLock({ running }) else {
            try? channel.write(["type": "denied", "reason": "bridge stopped"])
            channel.close()
            return
        }
        do {
            try channel.write(["type": "welcome", "peerId": .string(peer.id)])
        } catch {
            channel.close()
            return
        }
        let registered = lock.withLock { () -> Bool in
            guard running else { return false }
            connections[peer.id] = connection
            _lastFailure = nil
            return true
        }
        guard registered else {
            channel.close()
            return
        }
        BridgeSocket.setReadTimeout(fd, seconds: 0)
        notifyPeersChanged()
        onHostConnected?(peer)

        while let message = try? channel.read() {
            lock.withLock { connection.peer.lastSeen = Date() }
            switch message["type"]?.stringValue {
            case "result":
                if let id = message["id"]?.stringValue { resolve(id, from: peer.id, with: message) }
            case "event":
                // The extension reports a problem it can't fix itself (an old copy missing a permission).
                if message["name"]?.stringValue == "problem", let reason = message["reason"]?.stringValue, !reason.isEmpty {
                    noteFailure(String(reason.prefix(300)), browser: peer.browser)
                }
            case "stop":
                onStop?(peer)
                failAll(peerID: peer.id, BrowserBridgeError(.stopped, "The user pressed Stop in the OpenClicky extension, which pauses agent control of that browser until they press Resume. Whatever this call was doing may or may not have taken effect; leave the browser alone unless the user asks you to continue."))
            default:
                break
            }
        }
        channel.close()
        lock.withLock { _ = connections.removeValue(forKey: peer.id) }
        failAll(peerID: peer.id, BrowserBridgeError(.disconnected, "The browser disconnected before answering; the action's outcome is unknown."))
        notifyPeersChanged()
    }

    private func failAll(peerID: String, _ error: BrowserBridgeError) {
        let failed = lock.withLock { () -> [Pending] in
            let ids = pending.filter { $0.value.peerID == peerID }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0) }
        }
        failed.forEach { $0.continuation.resume(throwing: error) }
    }

    private func notifyPeersChanged() {
        let observer = onPeersChanged
        observer?(peers)
    }

    /// Pings every host (the extension answers with `pong`) and drops connections silent for three intervals.
    private func heartbeat() {
        let open = lock.withLock { Array(connections.values) }
        let cutoff = Date().addingTimeInterval(-3 * pingInterval)
        for connection in open {
            let lastSeen = lock.withLock { connection.peer.lastSeen }
            if lastSeen < cutoff {
                connection.channel.close()
                continue
            }
            if (try? connection.channel.write(["type": "ping"])) == nil { connection.channel.close() }
        }
    }
}

/// Why a browser couldn't connect, or a setup problem its extension reported (shown as "Setup failed" in Settings).
public struct BrowserSetupFailure: Codable, Sendable, Hashable {
    public var reason: String
    /// Bundle ID of the browser it came from; empty if unknown.
    public var browser: String
    public var at: Date

    public init(reason: String, browser: String = "", at: Date = Date()) {
        self.reason = reason
        self.browser = browser
        self.at = at
    }
}

/// Talks to a running bridge from another process (`occtl browser status`).
public enum BrowserBridgeProbe {
    public struct Status: Sendable {
        public var peers: [BrowserPeer]
        /// Why a browser last failed to connect, when it hasn't connected since.
        public var failure: BrowserSetupFailure?

        public init(peers: [BrowserPeer], failure: BrowserSetupFailure? = nil) {
            self.peers = peers
            self.failure = failure
        }
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case noToken
        case notRunning(String)
        case denied(String)

        public var description: String {
            switch self {
            case .noToken: "no bridge token yet (the bridge has never run)"
            case .notRunning(let detail): "the bridge isn't running (\(detail))"
            case .denied(let reason): "the bridge refused the probe: \(reason)"
            }
        }
    }

    public static func status(paths: BrowserBridgePaths = .standard) throws -> Status {
        guard let token = try paths.readToken() else { throw ProbeError.noToken }
        let fd: Int32
        do {
            fd = try BridgeSocket.connectUnix(path: paths.socket.path)
        } catch {
            throw ProbeError.notRunning("\(error)")
        }
        let channel = FramedChannel(socket: fd)
        defer { channel.close() }
        BridgeSocket.setReadTimeout(fd, seconds: 5)
        try channel.write(["type": "status", "token": .string(token)])
        guard let reply = try channel.read() else { throw ProbeError.notRunning("closed without answering") }
        guard reply["type"]?.stringValue == "status" else { throw ProbeError.denied(reply["reason"]?.stringValue ?? "unknown") }
        let peers = (try? reply["peers"]?.decodeCodable([BrowserPeer].self)) ?? []
        return Status(peers: peers, failure: try? reply["failure"]?.decodeCodable(BrowserSetupFailure.self))
    }
}

extension JSONValue {
    /// A Codable value as JSON (dates as ISO 8601).
    static func encodeCodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    /// Decodes this JSON as a Codable type (dates as ISO 8601).
    func decodeCodable<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(jsonString().utf8))
    }
}
