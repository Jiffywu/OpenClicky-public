import Foundation
import OpenClickyKit

enum BrowserCommands {
    static let usageText = """
    Usage:
      occtl browser install-host [--host PATH] [--all] [--support DIR]
            write com.openclicky.browser.json for each installed Chromium browser
      occtl browser uninstall-host [--support DIR]
            remove OpenClicky's host manifests (other apps' manifests are never touched)
      occtl browser status [--support DIR]
            manifests, bridge socket, connected browsers and the agent MCP endpoint
      occtl browser mcp-serve [--port N] [--save-dir DIR] [--turn JOB[:TITLE]] [--confirm-writes]
            run the socket bridge and the MCP server in the foreground (Ctrl-C stops); --save-dir keeps
            screenshots taken with save=true by calls that carry no job (they go to DIR/output/). --turn starts a
            turn for a test job (its folder is DIR): SIGUSR1 ends it (closing its unkept tabs, printing its
            counters), SIGUSR2 starts the next one. Without --confirm-writes, browser changes are refused;
            --confirm-writes requires a terminal and asks for approval of each operation or batch.
      occtl browser call <operation> [JSON object | key=value ...] [--image-out FILE] [--json] [--job JOB]
            call the browser MCP tool on the running server, e.g. occtl browser call read tabId=12; --job sends
            the job header a harness would (X-OpenClicky-Job)
    """

    static let browser = OcctlCommand(name: "browser", usage: "browser <install-host|uninstall-host|status|mcp-serve|call> …  Chrome extension bridge") { args in
        guard let sub = args.first else { fail(usageText) }
        var options = Options(Array(args.dropFirst()))
        switch sub {
        case "install-host": try installHost(&options)
        case "uninstall-host": uninstallHost(&options)
        case "status": status(&options)
        case "mcp-serve": try await mcpServe(&options)
        case "call": try await call(&options)
        default: fail(usageText)
        }
    }

    /// `--flag value` / `--flag` options plus positional words.
    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        static let valued: Set<String> = ["--host", "--support", "--port", "--image-out", "--save-dir", "--turn", "--job"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.valued.contains(arg), index + 1 < args.count {
                    values[arg] = args[index + 1]
                    index += 2
                } else if arg.hasPrefix("--") {
                    flags.insert(arg)
                    index += 1
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        var support: URL {
            values["--support"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
                ?? NativeHostInstaller.defaultApplicationSupport
        }
    }

    static func describe(_ action: NativeHostInstaller.Outcome.Action) -> String {
        switch action {
        case .written: "wrote"
        case .unchanged: "up to date"
        case .removed: "removed"
        case .absent: "not present"
        case .browserNotFound: "skipped (browser not installed)"
        case .failed(let message): "FAILED: \(message)"
        }
    }

    static func installHost(_ options: inout Options) throws {
        let host: URL
        if let explicit = options.values["--host"] {
            host = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath).standardizedFileURL
        } else if let found = NativeHostInstaller.locateHost(nextTo: URL(fileURLWithPath: CommandLine.arguments[0])) {
            host = found
        } else {
            fail("Couldn't find \(NativeHostInstaller.hostExecutableName) next to occtl. Build it (swift build) or pass --host PATH.")
        }
        guard FileManager.default.isExecutableFile(atPath: host.path) else { fail("\(host.path) is not an executable.") }
        let paths = BrowserBridgePaths.standard
        let ids = ChromeExtensionIdentity.allowedIDs(paths: paths)
        let outcomes = NativeHostInstaller.install(hostPath: host, extensionIDs: ids, applicationSupport: options.support,
                                                   includeMissing: options.flags.contains("--all"))
        print("Host: \(host.path)")
        print("Extension ID: \(ids.joined(separator: ", "))")
        for outcome in outcomes {
            print("  \(outcome.browser.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)) \(describe(outcome.action))  \(outcome.manifest.path)")
        }
        if outcomes.contains(where: { if case .failed = $0.action { true } else { false } }) { exit(1) }
    }

    static func uninstallHost(_ options: inout Options) {
        for outcome in NativeHostInstaller.uninstall(applicationSupport: options.support) {
            print("  \(outcome.browser.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)) \(describe(outcome.action))")
        }
    }

    static func status(_ options: inout Options) {
        let paths = BrowserBridgePaths.standard
        print("Extension ID: \(ChromeExtensionIdentity.extensionID)  (host name \(ChromeExtensionIdentity.hostName))")
        print("Host manifests:")
        for item in NativeHostInstaller.inspect(applicationSupport: options.support) where item.browserFound || item.manifestPresent {
            var line = "  \(item.browser.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)) "
            if !item.manifestPresent {
                line += "no OpenClicky host manifest (run occtl browser install-host)"
            } else {
                line += item.hostExecutable ? "ok" : "BROKEN: host missing at \(item.hostPath ?? "?")"
                if !item.allowsOpenClickyExtension { line += ", does not allow the OpenClicky extension" }
            }
            if item.browserFound {
                let profiles = ChromiumProfileDiscovery.profiles(for: item.browser, applicationSupport: options.support)
                let localState = ChromiumProfileDiscovery.localStateURL(for: item.browser, applicationSupport: options.support)
                if !profiles.isEmpty {
                    line += "  (\(profiles.count) profile\(profiles.count == 1 ? "" : "s") in Local State)"
                } else {
                    line += (try? Data(contentsOf: localState)) == nil ? "  (Local State missing or not readable)" : "  (no profiles in Local State)"
                }
            }
            print(line)
        }
        print("Bridge folder: \(paths.directory.path)")
        do {
            let probe = try BrowserBridgeProbe.status(paths: paths)
            print("Bridge: running, \(probe.peers.count) browser(s) connected")
            for peer in probe.peers {
                print("  \(peer.browserName)  profile \(peer.profileId)  extension \(peer.extensionVersion ?? "?")  since \(peer.connectedAt)")
            }
        } catch {
            print("Bridge: \(error)")
        }
        if let endpoint = BrowserMCPEndpoint.loadIfRunning(from: paths) {
            print("Agent MCP: \(endpoint.url.absoluteString)  (token in \(paths.mcpEndpoint.path), pid \(endpoint.pid))")
        } else {
            print("Agent MCP: not running")
        }
    }

    static func mcpServe(_ options: inout Options) async throws {
        let port = options.values["--port"].flatMap(UInt16.init) ?? 0
        let service = try BrowserBridgeService()
        if options.flags.contains("--confirm-writes") {
            guard isatty(STDIN_FILENO) == 1 else {
                throw AgentManagerError.configuration("--confirm-writes requires an interactive terminal for browser approvals.")
            }
            service.toolEnvironment.approveChange = { await BrowserWriteApproval.ask($0) }
        }
        let saveFolder = options.values["--save-dir"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        service.toolEnvironment.unboundSaveFolder = saveFolder
        // A test job's turns, driven by signals, so scripts can check turn binding and tidy-up with a real browser.
        let testTurn = options.values["--turn"].map { spec -> (job: String, title: String?) in
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : nil)
        }
        if let testTurn {
            service.turns.beginTurn(jobID: testTurn.job, title: testTurn.title, folder: saveFolder)
            let queue = DispatchQueue(label: "occtl.turns")
            Self.turnSources = [SIGUSR1, SIGUSR2].map { sig in
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler {
                    if sig == SIGUSR2 {
                        service.turns.beginTurn(jobID: testTurn.job)
                        print("[turn] \(testTurn.job): turn started")
                        fflush(stdout)
                        return
                    }
                    Task {
                        let usage = await service.endTurn(jobID: testTurn.job)
                        print("[turn] \(testTurn.job): turn ended; \(usage?.summary ?? "no browser use")")
                        fflush(stdout)
                    }
                }
                source.resume()
                return source
            }
        }
        service.bridge.onPeersChanged = { peers in
            let list = peers.map { "\($0.browserName) [\($0.profileId.prefix(8))]" }.joined(separator: ", ")
            print("[bridge] connected browsers: \(list.isEmpty ? "none" : list)")
            fflush(stdout)
        }
        let endpoint = try service.start(mcpPort: port)
        print("Browser bridge socket: \(service.paths.socket.path)")
        print("MCP server: \(endpoint.url.absoluteString)")
        print("Endpoint file (url + bearer token, mode 0600): \(service.paths.mcpEndpoint.path)")
        print("Codex config:\n\(endpoint.codexConfigTOML)")
        print("Waiting for the extension… (Ctrl-C to stop)")
        fflush(stdout)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
            }
            let once = Once()
            let queue = DispatchQueue(label: "occtl.signals")
            Self.signalSources = [SIGINT, SIGTERM].map { sig in
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
                source.setEventHandler { if once.first() { continuation.resume() } }
                source.resume()
                return source
            }
        }
        service.stop()
        print("Stopped.")
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
    nonisolated(unsafe) static var turnSources: [DispatchSourceSignal] = []

    static func call(_ options: inout Options) async throws {
        guard let operation = options.positional.first else { fail(usageText) }
        var arguments: [String: JSONValue] = ["operation": .string(operation)]
        for word in options.positional.dropFirst() {
            if word.hasPrefix("{") {
                guard case .object(let object) = try JSONValue.parse(word) else { fail("Arguments must be a JSON object.") }
                arguments.merge(object) { $1 }
            } else if let equals = word.firstIndex(of: "=") {
                let key = String(word[..<equals])
                let raw = String(word[word.index(after: equals)...])
                arguments[key] = (try? JSONValue.parse(raw)).flatMap { value -> JSONValue? in
                    switch value { case .number, .bool: value; default: nil }
                } ?? .string(raw)
            } else {
                fail("Unexpected argument \(word); use key=value or a JSON object.")
            }
        }
        guard let endpoint = BrowserMCPEndpoint.loadIfRunning() else {
            fail("The browser MCP server isn't running (start OpenClicky or occtl browser mcp-serve).")
        }
        // Longer than the slowest operation (a 120 s wait_for), so the answer arrives before the client gives up.
        var client = MCPHTTPClient(url: endpoint.url, token: endpoint.token, timeout: BrowserTool.longestCall + 30)
        if let job = options.values["--job"] { client.headers[BrowserCallIdentity.jobHeader] = job }
        _ = try await client.initialize()
        let result = try await client.callTool(BrowserTool.name, arguments: .object(arguments))
        if options.flags.contains("--json") {
            var printable = result
            if case .object(var object) = result, let content = object["content"]?.arrayValue {
                object["content"] = .array(content.map { item in
                    guard case .object(var block) = item, block["type"] == "image" else { return item }
                    block["data"] = .string("<\(block["data"]?.stringValue?.count ?? 0) base64 characters>")
                    return .object(block)
                })
                printable = .object(object)
            }
            print(printable.jsonString())
        }
        for item in result["content"]?.arrayValue ?? [] {
            if item["type"] == "text", !options.flags.contains("--json") {
                print(item["text"]?.stringValue ?? "")
            } else if item["type"] == "image", let data = item["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) {
                if let out = options.values["--image-out"] {
                    try data.write(to: URL(fileURLWithPath: out))
                    print("Saved \(data.count)-byte image to \(out)")
                } else {
                    print("(\(data.count)-byte image; pass --image-out FILE to save it)")
                }
            }
        }
        if result["isError"]?.boolValue == true { exit(2) }
    }
}
