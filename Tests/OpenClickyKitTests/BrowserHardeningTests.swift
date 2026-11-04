import Foundation
import Testing
@testable import OpenClickyKit

// Regression tests for problems found in review: inputs that crashed or stalled the loopback server, calls that
// reached the browser after their task was cancelled, results accepted from the wrong browser, and servers left
// running after a failed start or a stop.

/// Lets a test hold many sockets open at once (macOS shells default to 256 descriptors per process).
private func raiseDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = min(limit.rlim_max, 4096)
    if limit.rlim_cur < wanted {
        limit.rlim_cur = wanted
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}

private func connectLoopback(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else {
        close(fd)
        throw POSIXError(.ECONNREFUSED)
    }
    return fd
}

/// Sends raw bytes and returns whatever the server answers before closing (or before `wait` runs out). The default
/// wait is a hang guard: a busy machine can take seconds to run the server's handler.
private func rawExchange(port: UInt16, _ request: String, wait: Double = 10) throws -> String {
    let fd = try connectLoopback(port)
    defer { close(fd) }
    BridgeSocket.setReadTimeout(fd, seconds: wait)
    try BridgeSocket.writeAll(fd, Data(request.utf8))
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        response.append(contentsOf: buffer[0..<count])
    }
    return String(decoding: response, as: UTF8.self)
}

private let pingTool = MCPTool(name: "noop", description: "Does nothing.", inputSchema: ["type": "object"]) { _, _ in
    MCPToolResult(content: [.text("ok")])
}

private func chunkedPost(_ chunks: String) -> String {
    "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nTransfer-Encoding: chunked\r\n\r\n" + chunks
}

@Test func malformedChunkSizesAreRejectedInsteadOfCrashingTheServer() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "t", tools: [pingTool])
    let url = try server.start()
    defer { server.stop() }
    let port = UInt16(url.port!)

    // A negative size used to build an inverted range (a fatal error); a huge one overflowed `count + size`.
    // Neither needs the bearer token, because the body is read before authentication.
    for chunks in ["-1\r\n\r\n", "1\r\n{\r\n7fffffffffffffff\r\n", "+4\r\nnull\r\n0\r\n\r\n", "zz\r\n", "4\r\nnullXX0\r\n\r\n"] {
        let reply = try rawExchange(port: port, chunkedPost(chunks))
        #expect(reply.hasPrefix("HTTP/1.1 400"), "chunks \(chunks.debugDescription) got \(reply.prefix(40).debugDescription)")
    }

    // A chunk-size line that never ends is refused once it is implausibly long, not buffered forever.
    let started = Date()
    let endless = try rawExchange(port: port, chunkedPost(String(repeating: "a", count: 8192)), wait: 5)
    #expect(endless.hasPrefix("HTTP/1.1 400"))
    #expect(Date().timeIntervalSince(started) < 3)

    // Still alive and answering (the timeout is a hang guard).
    let client = MCPHTTPClient(url: url, token: "t", timeout: 10)
    #expect(try await client.request("ping") == .object([:]))
}

@Test func idleConnectionsDoNotStallTheServer() async throws {
    raiseDescriptorLimit()
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "t", tools: [pingTool])
    let url = try server.start()
    defer { server.stop() }
    let port = UInt16(url.port!)

    // Connections that send half a request and go quiet used to pin a GCD worker each until the 30-second read
    // timeout; enough of them exhausted the pool and every later request waited.
    var idle: [Int32] = []
    defer { idle.forEach { close($0) } }
    for _ in 0..<80 {
        // Eighty connections in a burst overrun the 64-connection listen backlog when the accept loop falls behind, as
        // it does on a busy machine, and the overflow can be refused or reset; try again once it has caught up.
        let giveUp = Date().addingTimeInterval(10)  // a hang guard
        var held: Int32?
        while held == nil, Date() < giveUp {
            if let fd = try? connectLoopback(port) {
                if (try? BridgeSocket.writeAll(fd, Data("POST /mcp HTTP/1.1\r\n".utf8))) != nil { held = fd } else { close(fd) }
            }
            if held == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard let held else {
            Issue.record("could not open idle connection \(idle.count + 1) of 80")
            return
        }
        idle.append(held)
    }
    try await Task.sleep(for: .milliseconds(300))

    // A stalled server would answer only once the idle connections hit their 15-second request deadline. The client
    // gives up well before that, so the ping succeeds only if the server answered while they were still held, however
    // slowly a busy machine runs it.
    let client = MCPHTTPClient(url: url, token: "t", timeout: 10)
    #expect(try await client.request("ping") == .object([:]))
}

@Test func connectionsOverTheCapAreTurnedAway() throws {
    // A request deadline far longer than the test, so the two clients hold their slots however slowly the machine runs.
    let http = LoopbackHTTPServer(maxConnections: 2, requestTimeout: 60) { _ in .json(200, ["ok": true]) }
    let port = try http.start()
    defer { http.stop() }

    let first = try connectLoopback(port)
    let second = try connectLoopback(port)
    defer {
        close(first)
        close(second)
    }
    try BridgeSocket.writeAll(first, Data("POST /mcp HTTP/1.1\r\n".utf8))
    try BridgeSocket.writeAll(second, Data("POST /mcp HTTP/1.1\r\n".utf8))
    // Connections are admitted in the order they arrive, so both slots are taken before this one is looked at.
    #expect(try rawExchange(port: port, "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\n", wait: 10).hasPrefix("HTTP/1.1 503"))
}

@Test func slowRequestsTimeOutAndGiveTheirSlotsBack() throws {
    /// Sends whole requests until one is served instead of turned away (a slot is held until its connection's
    /// lingering close ends, a moment after the answer).
    func slotsComeBack(_ port: UInt16) throws -> String {
        var answer = ""
        let giveUp = Date().addingTimeInterval(10)  // a hang guard
        repeat {
            answer = try rawExchange(port: port, "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
            if answer.hasPrefix("HTTP/1.1 200") { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < giveUp
        return answer
    }

    // Two idle clients fill the server and are dropped at the request deadline…
    let http = LoopbackHTTPServer(maxConnections: 2, requestTimeout: 0.6) { _ in .json(200, ["ok": true]) }
    let port = try http.start()
    defer { http.stop() }
    let idle = [try connectLoopback(port), try connectLoopback(port)]
    for fd in idle { try BridgeSocket.writeAll(fd, Data("POST /mcp HTTP/1.1\r\n".utf8)) }
    for fd in idle {
        BridgeSocket.setReadTimeout(fd, seconds: 10)  // a hang guard; the answer comes at the 0.6 s deadline
        var probe = [UInt8](repeating: 0, count: 256)
        #expect(String(decoding: probe[0..<max(read(fd, &probe, probe.count), 0)], as: UTF8.self).hasPrefix("HTTP/1.1 408"))
        close(fd)
    }
    // …which frees their slots.
    let freed = try slotsComeBack(port)
    #expect(freed.hasPrefix("HTTP/1.1 200"), "got \(freed.prefix(60).debugDescription)")

    // A client that trickles bytes can't hold a slot past the deadline either: the server must answer while it is
    // still trickling. The trickle outlasts the deadline many times over, so only a server that lets each byte
    // extend the request could miss it. It gets a server of its own with one slot, so slots the clients above are
    // still giving back (on a busy machine, a while after they close) can't turn it away, and the server answers
    // anyone afterwards only if the trickling client's slot came back.
    let single = LoopbackHTTPServer(maxConnections: 1, requestTimeout: 0.6) { _ in .json(200, ["ok": true]) }
    let singlePort = try single.start()
    defer { single.stop() }
    let slow = try connectLoopback(singlePort)
    defer { close(slow) }
    BridgeSocket.setReadTimeout(slow, seconds: 10)
    var poller = pollfd(fd: slow, events: Int16(POLLIN), revents: 0)
    var answeredWhileTrickling = false
    let trickle = Array("POST /mcp HTTP/1.1\r\n".utf8) + Array(repeating: Array("X-Slow: 1\r\n".utf8), count: 30).flatMap { $0 }
    for byte in trickle {
        if (try? BridgeSocket.writeAll(slow, Data([byte]))) == nil || poll(&poller, 1, 50) > 0 {
            answeredWhileTrickling = true  // the server has answered (or already closed after answering)
            break
        }
    }
    #expect(answeredWhileTrickling, "the server let a trickling client hold its slot")
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = read(slow, &buffer, buffer.count)
    #expect(count > 0 && String(decoding: buffer[0..<max(count, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 408"))

    // The slot comes back once the server has dropped that client.
    let after = try slotsComeBack(singlePort)
    #expect(after.hasPrefix("HTTP/1.1 200"), "got \(after.prefix(60).debugDescription)")
}

@Test func unsupportedProtocolVersionHeaderIsABadRequest() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "t", tools: [pingTool])
    let url = try server.start()
    defer { server.stop() }
    let port = UInt16(url.port!)
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    func post(version: String) throws -> String {
        try rawExchange(port: port, "POST /mcp HTTP/1.1\r\nAuthorization: Bearer t\r\nMCP-Protocol-Version: \(version)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
    }
    #expect(try post(version: "1999-01-01").hasPrefix("HTTP/1.1 400"))
    #expect(try post(version: "2025-11-25").hasPrefix("HTTP/1.1 200"))
    #expect(try post(version: "2025-06-18").hasPrefix("HTTP/1.1 200"))

    // An unknown requested version is answered with the newest one the server speaks (the timeout is a hang guard).
    let client = MCPHTTPClient(url: url, token: "t", timeout: 10)
    let negotiated = try await client.request("initialize", params: ["protocolVersion": "1999-01-01", "capabilities": .object([:]),
                                                                     "clientInfo": ["name": "x", "version": "0"]])
    #expect(negotiated["protocolVersion"] == "2025-11-25")
}

// MARK: Bridge

private let origin = ChromeExtensionIdentity.origin(for: ChromeExtensionIdentity.extensionID)

@Test func aCancelledCallNeverReachesTheBrowser() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = BrowserBridgeServer(paths: paths, token: try paths.loadOrCreateToken(), allowedOrigins: [origin])
    try server.start()
    defer { server.stop() }
    let fake = FakeExtension(paths: paths)  // connected, never answers
    try fake.sendHello()
    #expect(eventually { server.peers.count == 1 })

    let task = Task { () -> (error: (any Error)?, took: Duration) in
        // Cancelled before it reaches the bridge, as when an agent turn is torn down.
        while !Task.isCancelled { await Task.yield() }
        // Timed from the call itself, not from the cancel: on a busy machine the task may only start running later.
        let started = ContinuousClock.now
        do {
            _ = try await server.send("click", arguments: ["ref": "e1"], timeout: 10)
            return (nil, ContinuousClock.now - started)
        } catch {
            return (error, ContinuousClock.now - started)
        }
    }
    task.cancel()
    let (error, took) = await task.value
    #expect(error is CancellationError, "got \(String(describing: error))")
    #expect(took < .seconds(2), "the cancelled call waited for its timeout")
    try await Task.sleep(for: .milliseconds(300))
    #expect(fake.messages.filter { $0["type"] == "command" }.isEmpty)
    fake.disconnect()
}

@Test func onlyTheBrowserACommandWentToCanAnswerIt() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let server = BrowserBridgeServer(paths: paths, token: try paths.loadOrCreateToken(), allowedOrigins: [origin])
    try server.start()
    defer { server.stop() }
    let target = FakeExtension(paths: paths)  // silent
    let other = FakeExtension(paths: paths)
    let targetProfile = "11111111-2222-4333-8444-555555555555"
    try target.sendHello(profile: targetProfile)
    try other.sendHello(profile: "66666666-7777-4888-9999-000000000000")
    #expect(eventually { server.peers.count == 2 })

    async let call = server.send("tabs", profile: targetProfile, timeout: 1.5)
    #expect(eventually { target.messages.contains { $0["type"] == "command" } })
    let id = try #require(target.messages.first { $0["type"] == "command" }?["id"])
    // A different profile answers with the same id; that must not count as the target's answer.
    try other.send(["type": "result", "id": id, "ok": true, "result": ["spoofed": true]])
    do {
        let value = try await call
        Issue.record("accepted an answer from the wrong browser: \(value)")
    } catch let error as BrowserBridgeError {
        #expect(error.kind == .timeout)
    }
    target.disconnect()
    other.disconnect()
}

@Test func aHostThatFinishesItsHandshakeAfterStopIsTurnedAway() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let token = try paths.loadOrCreateToken()
    let server = BrowserBridgeServer(paths: paths, token: token, allowedOrigins: [origin])
    try server.start()

    let fd = try BridgeSocket.connectUnix(path: paths.socket.path)
    let channel = FramedChannel(socket: fd)
    defer { channel.close() }
    Thread.sleep(forTimeInterval: 0.2)  // the server is now waiting for this host's first message
    server.stop()

    BridgeSocket.setReadTimeout(fd, seconds: 3)
    try? channel.write([
        "type": "auth", "token": .string(token), "protocol": 1, "session": "s",
        "profileId": "8a6e0c55-3f1b-4f7a-9d44-0b1c2d3e4f50", "origin": .string(origin), "browser": "com.google.Chrome",
    ])
    let reply = try? channel.read()
    #expect(reply?["type"] != "welcome")
    #expect(server.peers.isEmpty)
}

@Test func aFailedStartLeavesNothingRunning() throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    // Something in the way of the endpoint file makes publishing it fail.
    try FileManager.default.createDirectory(at: paths.mcpEndpoint.appendingPathComponent("blocker"), withIntermediateDirectories: true)
    let service = try BrowserBridgeService(paths: paths, allowedExtensionIDs: [ChromeExtensionIdentity.extensionID])
    #expect(throws: (any Error).self) { _ = try service.start() }
    #expect(service.endpoint == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.socket.path))

    // The socket was released, so a retry once the obstacle is gone succeeds.
    try FileManager.default.removeItem(at: paths.mcpEndpoint)
    let endpoint = try service.start()
    #expect(try BrowserMCPEndpoint.load(from: paths).token == endpoint.token)
    service.stop()
}

@Test func noOperationOutlastsTheLongestCallClientsWaitFor() {
    // occtl's MCP client waits `longestCall` plus a margin (it used the client's 120 s default, which a 120 s wait_for
    // outlasts), so no operation may be allowed to take longer.
    for operation in BrowserTool.Operation.allCases {
        for args: [String: JSONValue] in [[:], ["timeout": 120], ["timeout": 1_000_000], ["timeout": -5]] {
            #expect(BrowserTool.timeout(for: operation, args) <= BrowserTool.longestCall)
        }
    }
}
