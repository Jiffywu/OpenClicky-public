import Foundation
import Testing
@testable import OpenClickyKit

private let echoTool = MCPTool(name: "echo", description: "Echoes its arguments.", inputSchema: ["type": "object"]) { arguments, meta in
    MCPToolResult(content: [.text(arguments["say"]?.stringValue ?? "")],
                  structuredContent: ["arguments": arguments, "meta": meta ?? .null])
}

/// Raw HTTP to the loopback server, so tests can send what a real MCP client wouldn't.
private func raw(_ url: URL, method: String = "POST", token: String?, body: String? = nil,
                 headers: [String: String] = [:]) async throws -> (Int, JSONValue?, [AnyHashable: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = body.map { Data($0.utf8) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let (data, response) = try await URLSession(configuration: configuration).data(for: request)
    let http = response as! HTTPURLResponse
    return (http.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data), http.allHeaderFields)
}

@Test func mcpServerSpeaksStreamableHTTPOverLoopback() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1.2.3", token: "secret-token", tools: [echoTool], instructions: "Be nice.")
    let url = try server.start()
    defer { server.stop() }
    #expect(url.host == "127.0.0.1")
    #expect(url.path == "/mcp")

    let client = MCPHTTPClient(url: url, token: "secret-token", timeout: 10)
    let initialized = try await client.initialize(protocolVersion: "2025-06-18")
    #expect(initialized["protocolVersion"] == "2025-06-18")
    #expect(initialized["serverInfo"]?["name"] == "test_server")
    #expect(initialized["serverInfo"]?["version"] == "1.2.3")
    #expect(initialized["capabilities"]?["tools"] != nil)
    #expect(initialized["instructions"] == "Be nice.")

    // Unknown protocol versions get the server's preferred one.
    let negotiated = try await client.request("initialize", params: ["protocolVersion": "1999-01-01", "capabilities": .object([:]),
                                                                     "clientInfo": ["name": "x", "version": "0"]])
    #expect(negotiated["protocolVersion"] == .string(MCPHTTPServer.supportedProtocolVersions[0]))

    let tools = try await client.listTools()
    #expect(tools.map { $0["name"] } == ["echo"])
    #expect(tools.first?["inputSchema"]?["type"] == "object")

    let result = try await client.request("tools/call", params: [
        "name": "echo", "arguments": ["say": "hi"],
        "_meta": ["x-codex-turn-metadata": ["thread_id": "t1", "turn_id": "u1"]],
    ])
    #expect(result["content"]?.arrayValue?.first?["text"] == "hi")
    #expect(result["isError"] == false)
    #expect(result["structuredContent"]?["meta"]?["x-codex-turn-metadata"]?["turn_id"] == "u1")

    #expect(try await client.request("ping") == .object([:]))
    #expect(try await client.notify("notifications/initialized") == 202)
}

@Test func mcpServerChecksTheBearerTokenPathMethodAndOrigin() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "secret-token", tools: [echoTool])
    let url = try server.start()
    defer { server.stop() }
    let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

    let (missing, missingBody, missingHeaders) = try await raw(url, token: nil, body: ping)
    #expect(missing == 401)
    #expect(missingBody?["error"] == "unauthorized")
    #expect((missingHeaders["Www-Authenticate"] ?? missingHeaders["WWW-Authenticate"]) as? String == "Bearer")
    #expect(try await raw(url, token: "secret-tokem", body: ping).0 == 401)
    #expect(try await raw(url, token: "secret-token-and-more", body: ping).0 == 401)

    let other = URL(string: url.absoluteString.replacingOccurrences(of: "/mcp", with: "/other"))!
    #expect(try await raw(other, token: "secret-token", body: ping).0 == 404)
    #expect(try await raw(url, method: "GET", token: "secret-token").0 == 405)
    #expect(try await raw(url, method: "PUT", token: "secret-token", body: ping).0 == 405)
    #expect(try await raw(url, method: "DELETE", token: "secret-token").0 == 200)

    #expect(try await raw(url, token: "secret-token", body: ping, headers: ["Origin": "https://evil.example"]).0 == 403)
    #expect(try await raw(url, token: "secret-token", body: ping, headers: ["Origin": "http://localhost:3000"]).0 == 200)

    let (status, _, headers) = try await raw(url, token: "secret-token", body: ping)
    #expect(status == 200)
    #expect(headers["Cache-Control"] as? String == "no-store")
}

@Test func mcpServerReturnsJSONRPCErrors() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "t", tools: [echoTool])
    let url = try server.start()
    defer { server.stop() }

    let (parseStatus, parseBody, _) = try await raw(url, token: "t", body: "{not json")
    #expect(parseStatus == 400)
    #expect(parseBody?["error"]?["code"] == -32700)

    let (_, unknownMethod, _) = try await raw(url, token: "t", body: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
    #expect(unknownMethod?["error"]?["code"] == -32601)
    #expect(unknownMethod?["id"] == 2)

    let (_, unknownTool, _) = try await raw(url, token: "t", body: #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"nope"}}"#)
    #expect(unknownTool?["error"]?["code"] == -32602)

    let (notifyStatus, _, _) = try await raw(url, token: "t", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(notifyStatus == 202)

    let (batchStatus, batch, _) = try await raw(url, token: "t", body: #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"}]"#)
    #expect(batchStatus == 200)
    #expect(batch?.arrayValue?.count == 1)
}

@Test func mcpServerAcceptsChunkedBodies() async throws {
    let server = MCPHTTPServer(name: "test_server", version: "1", token: "t", tools: [echoTool])
    let url = try server.start()
    defer { server.stop() }
    let port = UInt16(url.port!)
    let body = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"echo","arguments":{"say":"chunked"}}}"#
    let bytes = Array(body.utf8)
    let split = 20
    var request = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    request += String(split, radix: 16) + "\r\n" + String(decoding: bytes[0..<split], as: UTF8.self) + "\r\n"
    request += String(bytes.count - split, radix: 16) + "\r\n" + String(decoding: bytes[split...], as: UTF8.self) + "\r\n0\r\n\r\n"

    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    #expect(connected == 0)
    try BridgeSocket.writeAll(fd, Data(request.utf8))
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        response.append(contentsOf: buffer[0..<count])
    }
    let text = String(decoding: response, as: UTF8.self)
    #expect(text.hasPrefix("HTTP/1.1 200 OK"))
    #expect(text.contains("Connection: close"))
    #expect(text.contains(#""text":"chunked""#))
}

@Test func mcpListenerIsBoundToLoopbackOnly() throws {
    let (fd, port) = try BridgeSocket.listenLoopbackTCP()
    defer { close(fd) }
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    #expect(port > 0)
    #expect(address.sin_addr.s_addr == inet_addr("127.0.0.1"))
}

// MARK: The browser tool, end to end through the bridge and a fake extension

@Test func browserToolRunsThroughMCPBridgeRelayAndExtension() async throws {
    let paths = try makeBridgePaths()
    defer { removeBridgePaths(paths) }
    let service = try BrowserBridgeService(paths: paths, allowedExtensionIDs: [ChromeExtensionIdentity.extensionID])
    let endpoint = try service.start()
    defer { service.stop() }

    // The endpoint file is what agent harnesses read.
    let published = try BrowserMCPEndpoint.load(from: paths)
    #expect(published.url == endpoint.url && published.token == endpoint.token && published.pid == getpid())
    #expect(published.url.absoluteString.hasPrefix("http://127.0.0.1:"))
    #expect(published.token.count == 64)
    #expect(published.isProcessAlive)
    let mode = try FileManager.default.attributesOfItem(atPath: paths.mcpEndpoint.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(published.codexConfigTOML.contains("bearer_token_env_var = \"OPENCLICKY_BROWSER_MCP_TOKEN\""))
    #expect(!published.codexConfigTOML.contains(published.token))

    let client = MCPHTTPClient(url: endpoint.url, token: endpoint.token, timeout: 15)
    _ = try await client.initialize()
    let tools = try await client.listTools()
    #expect(tools.map { $0["name"] } == ["browser"])
    let operations = tools.first?["inputSchema"]?["properties"]?["operation"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(Set(operations).isSuperset(of: ["tabs", "read", "navigate", "click", "type", "select", "scroll", "wait_for", "screenshot"]))

    // Nothing connected yet: a clear tool error, not a protocol error.
    let early = try await client.callTool("browser", arguments: ["operation": "tabs"])
    #expect(early["isError"] == true)
    #expect(early["structuredContent"]?["kind"] == "notConnected")
    let offline = try await client.callTool("browser", arguments: ["operation": "status"])
    #expect(offline["structuredContent"]?["connected"] == false)

    let fake = FakeExtension(paths: paths)
    service.toolEnvironment.approveChange = { _ in true }
    fake.onCommand = FakeExtension.standardReply
    try fake.sendHello()
    #expect(eventually { service.bridge.peers.count == 1 })

    let status = try await client.callTool("browser", arguments: ["operation": "status"])
    #expect(status["structuredContent"]?["connected"] == true)

    let read = try await client.callTool("browser", arguments: ["operation": "read", "tabId": 7])
    #expect(read["isError"] == false)
    let text = read["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(text.contains("Hello from the test page."))
    #expect(text.contains(#"[e2] button "Say hello""#))
    #expect(read["structuredContent"]?["elements"]?.arrayValue?.count == 2)

    let click = try await client.callTool("browser", arguments: ["operation": "click", "tabId": 7, "ref": "e2"])
    #expect(click["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("Clicked [e2]") == true)
    let sent = try #require(fake.messages.last { $0["type"] == "command" })
    #expect(sent["operation"] == "click")
    #expect(sent["args"]?["ref"] == "e2")
    #expect(sent["args"]?["operation"] == nil)

    let shot = try await client.callTool("browser", arguments: ["operation": "screenshot"])
    let image = try #require(shot["content"]?.arrayValue?.first { $0["type"] == "image" })
    #expect(image["mimeType"] == "image/jpeg")
    #expect(Data(base64Encoded: image["data"]?.stringValue ?? "") == Data([0xFF, 0xD8, 0xFF, 0xD9]))
    #expect(shot["structuredContent"]?["data"] == nil)

    // Validation happens before anything reaches the browser.
    let bad = try await client.callTool("browser", arguments: ["operation": "navigate", "url": "file:///etc/passwd"])
    #expect(bad["isError"] == true)
    let unsupported = try await client.callTool("browser", arguments: ["operation": "javascript"])
    #expect(unsupported["isError"] == true)
    // The click also reads the target before and after approval.
    let commandsSent = fake.messages.filter { $0["type"] == "command" && $0["operation"] != "sweep" }.count
    #expect(commandsSent == 5)

    fake.disconnect()
    service.stop()
    #expect(!FileManager.default.fileExists(atPath: paths.mcpEndpoint.path))
}
