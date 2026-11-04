import Foundation
import Testing
@testable import OpenClickyKit

// MCP JSON-RPC over real loopback HTTP: a test server on 127.0.0.1, the production URLSession transport.

@Suite(.serialized) struct MCPHTTPClientTests {
    @Test func legacyServerInitializesThenListsAndCallsWithSessionHeader() async throws {
        let server = try FakeMCPHTTPServer(mode: .legacy)
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: server.url))

        let description = try await client.connect()
        #expect(description.era == .legacy)
        #expect(description.protocolVersion == "2025-06-18")
        #expect(description.serverInfo?.name == "fake-legacy")
        #expect(description.instructions == "Test server.")

        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["search_files", "echo", "regional_lookup"]) // two pages joined
        let result = try await client.callTool("echo", arguments: ["text": "hi there"])
        #expect(result.text == "echo: hi there")
        #expect(!result.isError)

        // Modern probe first, rejected before initialize; then the handshake.
        #expect(server.seenMethods() == ["server/discover", "initialize", "notifications/initialized", "tools/list", "tools/list", "tools/call"])
        let requests = server.seenRequests()
        #expect(requests[1].headers["mcp-session-id"] == nil)
        #expect(requests[1].headers["mcp-protocol-version"] == nil)
        #expect(requests[1].body?["params"]?["protocolVersion"]?.stringValue == MCPProtocolVersion.preferredLegacy)
        #expect(requests[1].body?["params"]?["clientInfo"]?["name"]?.stringValue == "OpenClicky")
        for later in requests.dropFirst(2) {
            #expect(later.headers["mcp-session-id"] == "sess-1")
            #expect(later.headers["mcp-protocol-version"] == "2025-06-18")
            #expect(later.headers["accept"] == "application/json, text/event-stream")
            #expect(later.body?["params"]?["_meta"] == nil)
        }
        #expect(requests[3].body?["params"]?["cursor"] == nil)
        #expect(requests[4].body?["params"]?["cursor"]?.stringValue == "page-2")
        #expect(requests[5].body?["params"]?["name"]?.stringValue == "echo")
        #expect(requests[5].body?["jsonrpc"]?.stringValue == "2.0")
        await client.close()
    }

    @Test func legacyServerAnsweringWithServerSentEventsDeliversProgressAndResult() async throws {
        let server = try FakeMCPHTTPServer(mode: .legacy)
        server.useSSE = true
        let progress = ProgressBox()
        let transport = MCPStreamableHTTPTransport(endpoint: server.url) { method, _ in progress.add(method) }
        let client = MCPClient(transport: transport)
        let result = try await client.callTool("search_files", arguments: ["query": "budget"])
        #expect(result.text == "found notes about budget")
        #expect(progress.methods.contains("notifications/progress"))
        #expect(transport.currentSessionID == "sess-1")
    }

    @Test func expiredLegacySessionIsReinitializedAndTheRequestRetried() async throws {
        let server = try FakeMCPHTTPServer(mode: .legacy)
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: server.url))
        _ = try await client.listTools()
        server.expireSession()
        let result = try await client.callTool("echo", arguments: ["text": "again"])
        #expect(result.text == "echo: again")
        #expect(server.currentSession == "sess-2")
        let methods = server.seenMethods()
        #expect(methods.filter { $0 == "initialize" }.count == 2)
        #expect(Array(methods.suffix(4)) == ["tools/call", "initialize", "notifications/initialized", "tools/call"])
    }

    @Test func modernServerGetsMetaAndMirroredHeadersWithoutSessions() async throws {
        let server = try FakeMCPHTTPServer(mode: .modern)
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: server.url))
        let description = try await client.connect()
        #expect(description.era == .modern)
        #expect(description.protocolVersion == "2026-07-28")
        #expect(description.serverInfo?.name == "fake-modern")

        let tools = try await client.listTools()
        #expect(tools.count == 3)
        let echo = try await client.callTool("echo", arguments: ["text": "modern"])
        #expect(echo.text == "echo: modern")
        let regional = try await client.callTool("regional_lookup", arguments: ["region": "us-west1", "q": "x"])
        #expect(regional.structuredContent?["region"]?.stringValue == "us-west1")

        #expect(server.seenMethods() == ["server/discover", "tools/list", "tools/list", "tools/call", "tools/call"])
        for request in server.seenRequests() {
            #expect(request.headers["mcp-session-id"] == nil)
            #expect(request.headers["mcp-protocol-version"] == "2026-07-28")
            #expect(request.headers["mcp-method"] == request.method)
            let meta = request.body?["params"]?["_meta"]
            #expect(meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue == "2026-07-28")
            #expect(meta?["io.modelcontextprotocol/clientInfo"]?["name"]?.stringValue == "OpenClicky")
            #expect(meta?["io.modelcontextprotocol/clientCapabilities"] != nil)
        }
        let calls = server.seenRequests().filter { $0.method == "tools/call" }
        #expect(calls[0].headers["mcp-name"] == "echo")
        #expect(calls[0].headers["mcp-param-region"] == nil)
        #expect(calls[1].headers["mcp-name"] == "regional_lookup")
        #expect(calls[1].headers["mcp-param-region"] == "us-west1")
    }

    @Test func unauthorizedServerSurfacesTheBearerChallenge() async throws {
        let server = try FakeMCPHTTPServer(mode: .modern)
        server.requiredToken = "right-token"
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: server.url, authorizer: StaticBearerAuthorizer(token: "wrong")))
        do {
            _ = try await client.connect()
            Issue.record("expected 401")
        } catch MCPClientError.unauthorized(let challenge) {
            #expect(challenge?.scope == "files:read")
            #expect(challenge?.resourceMetadata?.path == "/.well-known/oauth-protected-resource/mcp")
        }
        #expect(server.seenRequests().first?.headers["authorization"] == "Bearer wrong")
    }

    @Test func bearerTokenIsSentOnEveryRequest() async throws {
        let server = try FakeMCPHTTPServer(mode: .legacy)
        server.requiredToken = "pat-123"
        let client = MCPClient(transport: MCPStreamableHTTPTransport(endpoint: server.url, authorizer: StaticBearerAuthorizer(token: "pat-123")))
        #expect(try await client.listTools().count == 3)
        #expect(server.seenRequests().allSatisfy { $0.headers["authorization"] == "Bearer pat-123" })
    }

    @Test func headerMirroringFollowsTheEncodingRules() {
        #expect(MCPHeaderMirroring.encode("us-west1") == "us-west1")
        #expect(MCPHeaderMirroring.encode("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
        #expect(MCPHeaderMirroring.encode(" padded ") == "=?base64?IHBhZGRlZCA=?=")
        #expect(MCPHeaderMirroring.encode("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?=")
        #expect(MCPHeaderMirroring.encode("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
        // An annotation inside `items` makes the whole tool invalid.
        let invalid: JSONValue = ["type": "object", "properties": ["list": ["type": "array", "items": ["type": "string", "x-mcp-header": "X"]]]]
        #expect(MCPHeaderMirroring.parameterHeaders(in: invalid) == nil)
        let numberTyped: JSONValue = ["type": "object", "properties": ["n": ["type": "number", "x-mcp-header": "N"]]]
        #expect(MCPHeaderMirroring.parameterHeaders(in: numberTyped) == nil)
    }

    @Test func wwwAuthenticateParsesQuotedAndBareParameters() {
        let header = #"Bearer realm="mcp", error="insufficient_scope", scope="a b", resource_metadata="https://x.example/.well-known/oauth-protected-resource", Basic realm=other"#
        let challenges = WWWAuthenticateChallenge.parse(header)
        #expect(challenges.map(\.scheme) == ["Bearer", "Basic"])
        let bearer = WWWAuthenticateChallenge.bearer(from: header)
        #expect(bearer?.error == "insufficient_scope")
        #expect(bearer?.scope == "a b")
        #expect(bearer?.resourceMetadata?.host == "x.example")
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ method: String) { lock.withLock { seen.append(method) } }
    var methods: [String] { lock.withLock { seen } }
}

/// A connection the listener accepted before `stop()` must not reach the handler afterwards: the handler's owner
/// (a test fake, the OAuth redirect listener) may already be gone. Before this was enforced, test fakes that
/// captured themselves `unowned` crashed the test run now and then.
@Test func listenerDoesNotCallItsHandlerAfterStop() throws {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
    let calls = Counter()
    let listener = try LocalHTTPListener { request in
        // Only this test's request counts. Under the parallel suite a straggling connection meant for another test's
        // server can land on this recycled loopback port; it isn't ours and says nothing about stop().
        if request.target == "/late" { calls.bump() }
        return .text("ok")
    }
    // Connect first so the accept loop picks the connection up while the listener is still running.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = listener.port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(connected == 0)
    Thread.sleep(forTimeInterval: 0.3)
    listener.stop()
    let request = Data("GET /late HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var buffer = [UInt8](repeating: 0, count: 4_096)
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let count = recv(fd, &buffer, buffer.count, 0)
    let reply = count > 0 ? String(decoding: buffer[0..<count], as: UTF8.self) : ""
    #expect(reply.hasPrefix("HTTP/1.1 503"))
    #expect(calls.count == 0)
}

/// An in-memory legacy server that counts handshakes. `initialize` takes a moment, like a real server, and each
/// request belongs to the session that was live when it was sent.
final class CountingLegacyTransport: MCPMessageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    private var session = 0
    private var deadSessions = Set<Int>()
    private var requestCount = 0

    var mirrorsParameterHeaders: Bool { false }
    var seen: [String] { lock.withLock { methods } }
    func count(_ method: String) -> Int { seen.filter { $0 == method }.count }
    /// The server forgets the live session: requests sent on it fail with a lost session, even ones that answer late.
    func expireSession() { lock.withLock { _ = deadSessions.insert(session) } }

    func send(_ request: MCPOutgoingMessage, context: MCPRequestContext) async throws -> Result<JSONValue, JSONRPCError> {
        let (sentOn, order): (Int, Int) = lock.withLock {
            methods.append(request.method)
            requestCount += 1
            return (session, requestCount)
        }
        switch request.method {
        case "server/discover":
            return .failure(JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found"))
        case "initialize":
            try await Task.sleep(for: .milliseconds(80))
            lock.withLock { session += 1 }
            return .success(["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "counting", "version": "1"]])
        default:
            // Staggered answers: some come back after another request has already re-initialized.
            try await Task.sleep(for: .milliseconds(20 + (order % 4) * 60))
            if lock.withLock({ deadSessions.contains(sentOn) }) { throw MCPClientError.sessionExpired }
            return .success(["tools": [["name": "get_thing", "inputSchema": ["type": "object"]]]])
        }
    }

    func notify(_ notification: MCPOutgoingMessage, context: MCPRequestContext) async throws {
        lock.withLock { methods.append(notification.method) }
    }

    func resetSession() async {}
    func close() async {}
}

@Test func concurrentFirstRequestsShareOneHandshake() async throws {
    let transport = CountingLegacyTransport()
    let client = MCPClient(transport: transport)
    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<5 { group.addTask { try await client.listTools().count } }
        for try await count in group { #expect(count == 1) }
    }
    #expect(transport.count("server/discover") == 1)
    #expect(transport.count("initialize") == 1)
    #expect(transport.count("notifications/initialized") == 1)
    #expect(transport.count("tools/list") == 5)
}

@Test func concurrentRequestsThatLoseTheSessionReinitializeOnce() async throws {
    let transport = CountingLegacyTransport()
    let client = MCPClient(transport: transport)
    _ = try await client.connect()
    transport.expireSession()
    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<6 { group.addTask { try await client.listTools().count } }
        for try await count in group { #expect(count == 1) }
    }
    #expect(transport.count("initialize") == 2)
}

@Test func listenerRefusesHugeBodiesWithoutReadingThem() throws {
    let listener = try LocalHTTPListener { _ in .text("ok") }
    defer { listener.stop() }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = listener.port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(connected == 0)
    let head = Data("POST /callback HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4000000000\r\n\r\nabc".utf8)
    _ = head.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 256)
    // The listener hangs up at once instead of waiting for (and buffering) four gigabytes.
    #expect(recv(fd, &buffer, buffer.count, 0) == 0)
}
