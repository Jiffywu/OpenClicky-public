import Foundation

/// The native host's logic, kept in OpenClickyKit so tests can drive it with pipes instead of Chrome.
///
/// Chrome starts the host with the caller's origin as the first argument and talks native-messaging frames over
/// stdin/stdout. The relay checks the origin, waits for the extension's `hello`, then keeps a connection to the
/// app's Unix socket (retrying every `retryDelay` seconds while the app isn't running) and copies messages both ways.
/// It tells the extension whether the app is reachable with `{type:"ready", app}` whenever that changes.
public final class NativeHostRelay: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// argv[1] from Chrome: `chrome-extension://<id>/`.
        public var origin: String
        public var allowedExtensionIDs: [String]
        public var paths: BrowserBridgePaths
        /// Bundle ID of the browser that launched the host, when it can be found.
        public var browserBundleID: String
        public var retryDelay: TimeInterval
        /// Brings OpenClicky forward when the extension asks (`{type:"openApp"}`).
        public var openApp: @Sendable () -> Void
        /// Diagnostics go to stderr, which Chrome shows in its log when started with logging enabled.
        public var log: @Sendable (String) -> Void

        public init(origin: String, allowedExtensionIDs: [String], paths: BrowserBridgePaths, browserBundleID: String = "",
                    retryDelay: TimeInterval = 2, openApp: @escaping @Sendable () -> Void = {},
                    log: @escaping @Sendable (String) -> Void = { _ in }) {
            self.origin = origin
            self.allowedExtensionIDs = allowedExtensionIDs
            self.paths = paths
            self.browserBundleID = browserBundleID
            self.retryDelay = retryDelay
            self.openApp = openApp
            self.log = log
        }
    }

    public enum Exit: Int32, Sendable {
        /// The extension closed the port.
        case normal = 0
        /// A protocol violation: wrong caller, no hello, oversize or malformed message.
        case refused = 1
    }

    private let config: Configuration
    private let toExtension: FramedChannel
    private let fromExtension: FramedChannel
    public let session = UUID().uuidString.lowercased()
    private let lock = NSLock()
    private var app: FramedChannel?
    private var stopped = false
    private var reportedApp: Bool?
    private var hello: JSONValue = .object([:])

    /// - Parameters:
    ///   - input: frames from the extension (stdin).
    ///   - output: frames to the extension (stdout).
    public init(configuration: Configuration, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.config = configuration
        self.fromExtension = FramedChannel(readFD: input, writeFD: input, readLimit: NativeMessageFraming.maxFromExtension)
        self.toExtension = FramedChannel(readFD: output, writeFD: output, writeLimit: NativeMessageFraming.maxToExtension)
    }

    /// Whether `origin` names one of the allowed extension IDs.
    public static func isAllowed(origin: String, ids: [String]) -> Bool {
        ids.contains { ChromeExtensionIdentity.origin(for: $0) == origin }
    }

    /// Runs until the extension disconnects. Returns the process exit code.
    public func run() -> Exit {
        defer { shutdown() }
        guard Self.isAllowed(origin: config.origin, ids: config.allowedExtensionIDs) else {
            config.log("refusing caller \(config.origin)")
            return .refused
        }
        let first: JSONValue?
        do {
            first = try fromExtension.read()
        } catch {
            config.log("bad first message: \(error)")
            return .refused
        }
        guard let first else { return .normal }
        guard first["type"]?.stringValue == "hello", first["protocol"]?.intValue == BrowserBridgeServer.protocolVersion,
              let profile = first["profileId"]?.stringValue, UUID(uuidString: profile) != nil else {
            config.log("expected hello with protocol \(BrowserBridgeServer.protocolVersion) and a profile UUID")
            return .refused
        }
        lock.withLock { hello = first }
        Thread.detachNewThread { [self] in appLoop() }

        while true {
            let message: JSONValue?
            do {
                message = try fromExtension.read()
            } catch {
                config.log("bad message from the extension: \(error)")
                return .refused
            }
            guard let message else { return .normal }
            switch message["type"]?.stringValue {
            case "result", "pong", "stop", "event":
                if let app = lock.withLock({ self.app }) { try? app.write(message) }
            case "openApp":
                config.openApp()
            case "hello":
                break
            case nil:
                config.log("message without a type")
                return .refused
            default:
                break
            }
        }
    }

    private func shutdown() {
        let app = lock.withLock { () -> FramedChannel? in
            stopped = true
            defer { self.app = nil }
            return self.app
        }
        app?.close()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func report(app reachable: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { reportedApp = reachable }
            return reportedApp != reachable
        }
        if changed { try? toExtension.write(["type": "ready", "app": .bool(reachable)]) }
    }

    /// Keeps a connection to the app open, forwarding app messages to the extension.
    private func appLoop() {
        while !isStopped {
            if let channel = connectToApp() {
                let keep = lock.withLock { () -> Bool in
                    if stopped { return false }
                    app = channel
                    return true
                }
                guard keep else {
                    channel.close()
                    return
                }
                report(app: true)
                while let message = try? channel.read() {
                    switch message["type"]?.stringValue {
                    case "command":
                        do {
                            try toExtension.write(message)
                        } catch {
                            let id = message["id"] ?? .null
                            try? channel.write(["type": "result", "id": id, "ok": false, "error": .string("The host couldn't pass that command to the browser: \(error)")])
                        }
                    case "ping":
                        try? toExtension.write(message)
                    default:
                        break
                    }
                }
                lock.withLock { app = nil }
                channel.close()
            }
            if isStopped { return }
            report(app: false)
            Thread.sleep(forTimeInterval: config.retryDelay)
        }
    }

    /// Connects and authenticates. Re-reads the token each time so a reinstalled app is picked up.
    private func connectToApp() -> FramedChannel? {
        guard let token = try? config.paths.readToken(),
              let fd = try? BridgeSocket.connectUnix(path: config.paths.socket.path) else { return nil }
        let channel = FramedChannel(socket: fd, readLimit: NativeMessageFraming.maxToExtension, writeLimit: NativeMessageFraming.maxFromExtension)
        let hello = lock.withLock { self.hello }
        let auth: JSONValue = [
            "type": "auth",
            "token": .string(token),
            "protocol": .number(Double(BrowserBridgeServer.protocolVersion)),
            "session": .string(session),
            "profileId": hello["profileId"] ?? .null,
            "extensionVersion": hello["version"] ?? .null,
            "origin": .string(config.origin),
            "browser": .string(config.browserBundleID),
        ]
        BridgeSocket.setReadTimeout(fd, seconds: 10)
        guard (try? channel.write(auth)) != nil, let reply = try? channel.read() else {
            channel.close()
            return nil
        }
        guard reply["type"]?.stringValue == "welcome" else {
            config.log("app refused the connection: \(reply["reason"]?.stringValue ?? "unknown")")
            channel.close()
            return nil
        }
        BridgeSocket.setReadTimeout(fd, seconds: 0)
        return channel
    }
}

/// Finds which browser started the native host by walking up the process tree to the first `.app` bundle.
public enum CallerBrowser {
    public static func bundleID(startingAt pid: pid_t = getppid(), maxDepth: Int = 4) -> String {
        var current = pid
        for _ in 0..<maxDepth where current > 1 {
            // The outermost .app, so a helper app nested inside the browser bundle still names the browser.
            if let path = executablePath(of: current), let appPath = outermostApp(in: path),
               let id = Bundle(path: appPath)?.bundleIdentifier {
                return id
            }
            guard let parent = parentPID(of: current) else { break }
            current = parent
        }
        return ""
    }

    static func outermostApp(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
