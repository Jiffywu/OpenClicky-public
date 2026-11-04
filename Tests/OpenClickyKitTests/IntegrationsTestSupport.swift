import Foundation
@testable import OpenClickyKit

/// A small MCP server written for the tests, served over real loopback HTTP by `LocalHTTPListener`.
/// `legacy` mode behaves like an initialize-based server (2025-06-18) that hands out `Mcp-Session-Id` and
/// rejects requests before initialize the way common SDK servers do; `modern` mode follows 2026-07-28 (no
/// sessions, header validation, `server/discover`).
final class FakeMCPHTTPServer: @unchecked Sendable {
    enum Mode { case legacy, modern }

    struct Seen: Sendable {
        var method: String
        var headers: [String: String]
        var body: JSONValue?
    }

    let mode: Mode
    private let lock = NSLock()
    private var server: LocalHTTPListener!
    private var sessionCounter = 0
    private var liveSession: String?
    private(set) var seen: [Seen] = []
    /// Answer requests with SSE (a progress notification, then the response) instead of plain JSON.
    var useSSE = false
    /// Require `Authorization: Bearer <token>`; anything else gets 401 with a challenge.
    var requiredToken: String?
    var challenge = #"Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource/mcp", scope="files:read""#

    init(mode: Mode) throws {
        self.mode = mode
        server = try LocalHTTPListener { [weak self] request in self?.handle(request) ?? .empty(503) }
    }

    deinit { server.stop() }

    var url: URL { server.baseURL.appendingPathComponent("mcp") }
    var currentSession: String? { lock.withLock { liveSession } }

    /// The server forgets its session, as after a restart.
    func expireSession() { lock.withLock { liveSession = nil } }

    func seenMethods() -> [String] { lock.withLock { seen.map(\.method) } }
    func seenRequests() -> [Seen] { lock.withLock { seen } }

    static let tools: [JSONValue] = [
        ["name": "search_files", "description": "Search files by name", "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]],
         "annotations": ["readOnlyHint": true]],
        ["name": "echo", "description": "Echo the text back", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]]]],
        ["name": "regional_lookup", "description": "Look something up in a region",
         "inputSchema": ["type": "object", "properties": ["region": ["type": "string", "x-mcp-header": "Region"], "q": ["type": "string"]]]],
    ]

    private func handle(_ request: LocalHTTPListener.Request) -> LocalHTTPListener.Response {
        guard request.path == "/mcp" else { return .text("Not found", status: 404) }
        guard request.method == "POST" else { return .empty(405) }
        let body = request.json
        let method = body?["method"]?.stringValue ?? ""
        lock.withLock { seen.append(Seen(method: method, headers: request.headers, body: body)) }
        if let requiredToken, request.header("authorization") != "Bearer \(requiredToken)" {
            return .json(["jsonrpc": "2.0", "id": .null, "error": ["code": -32001, "message": "unauthorized"]], status: 401,
                         headers: ["WWW-Authenticate": challenge])
        }
        let id = body?["id"] ?? .null
        switch mode {
        case .legacy: return legacy(method: method, id: id, body: body, request: request)
        case .modern: return modern(method: method, id: id, body: body, request: request)
        }
    }

    private func legacy(method: String, id: JSONValue, body: JSONValue?, request: LocalHTTPListener.Request) -> LocalHTTPListener.Response {
        if method == "initialize" {
            let session: String = lock.withLock {
                sessionCounter += 1
                liveSession = "sess-\(sessionCounter)"
                return liveSession!
            }
            let result: JSONValue = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]],
                                     "serverInfo": ["name": "fake-legacy", "version": "0.1"], "instructions": "Test server."]
            return respond(id: id, result: result, headers: ["Mcp-Session-Id": session])
        }
        let sent = request.header("mcp-session-id")
        guard let sent else {
            // What the TypeScript SDK answers before initialize: 400 with an id-less JSON-RPC error.
            return .json(["jsonrpc": "2.0", "id": .null, "error": ["code": -32000, "message": "Bad Request: Server not initialized"]], status: 400)
        }
        guard sent == currentSession else {
            return .json(["jsonrpc": "2.0", "id": .null, "error": ["code": -32001, "message": "Session not found"]], status: 404)
        }
        if method.hasPrefix("notifications/") { return .empty(202) }
        return dispatch(method: method, id: id, params: body?["params"])
    }

    private func modern(method: String, id: JSONValue, body: JSONValue?, request: LocalHTTPListener.Request) -> LocalHTTPListener.Response {
        let version = body?["params"]?["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        guard request.header("mcp-protocol-version") == version, request.header("mcp-method") == method else {
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32020, "message": "Header mismatch"]], status: 400)
        }
        guard version == "2026-07-28" else {
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32022, "message": "Unsupported protocol version",
                                                                 "data": ["supported": ["2026-07-28"], "requested": .string(version ?? "")]]], status: 400)
        }
        if method == "tools/call", request.header("mcp-name") != body?["params"]?["name"]?.stringValue {
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32020, "message": "Mcp-Name mismatch"]], status: 400)
        }
        if method == "server/discover" {
            return respond(id: id, result: ["resultType": "complete", "supportedVersions": ["2026-07-28"], "capabilities": ["tools": [:]],
                                            "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "fake-modern", "version": "0.2"]]])
        }
        return dispatch(method: method, id: id, params: body?["params"])
    }

    private func dispatch(method: String, id: JSONValue, params: JSONValue?) -> LocalHTTPListener.Response {
        switch method {
        case "tools/list":
            if params?["cursor"]?.stringValue == "page-2" {
                return respond(id: id, result: ["tools": .array(Array(Self.tools.dropFirst(2)))])
            }
            return respond(id: id, result: ["tools": .array(Array(Self.tools.prefix(2))), "nextCursor": "page-2"])
        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"] ?? [:]
            switch name {
            case "echo": return respond(id: id, result: ["content": [["type": "text", "text": .string("echo: \(arguments["text"]?.stringValue ?? "")")]]])
            case "search_files": return respond(id: id, result: ["content": [["type": "text", "text": .string("found notes about \(arguments["query"]?.stringValue ?? "")")]]])
            case "regional_lookup": return respond(id: id, result: ["content": [["type": "text", "text": "ok"]], "structuredContent": ["region": arguments["region"] ?? .null]])
            default: return respond(id: id, result: ["content": [["type": "text", "text": "no such tool"]], "isError": true])
            }
        default:
            return .json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]], status: mode == .modern ? 404 : 200)
        }
    }

    private func respond(id: JSONValue, result: JSONValue, headers: [String: String] = [:]) -> LocalHTTPListener.Response {
        let message: JSONValue = ["jsonrpc": "2.0", "id": id, "result": result]
        guard useSSE else { return .json(message, headers: headers) }
        let progress: JSONValue = ["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progress": 1, "progressToken": "t"]]
        var all = headers
        all["Content-Type"] = "text/event-stream"
        return LocalHTTPListener.Response(status: 200, headers: all, chunks: [
            Data(": keep-alive\n\nevent: message\ndata: \(progress.jsonString())\n\n".utf8),
            Data("event: message\ndata: \(message.jsonString())\n\n".utf8),
        ], chunkDelay: .milliseconds(20))
    }
}

/// A language model that answers every request with fixed tool calls (and records what it was asked).
final class ScriptedChooserModel: LanguageModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private let reply: @Sendable (ChatRequest) -> (text: String, calls: [ToolCall])
    private(set) var requests: [ChatRequest] = []

    init(reply: @escaping @Sendable (ChatRequest) -> (text: String, calls: [ToolCall])) { self.reply = reply }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.withLock { requests.append(request) }
        let (text, calls) = reply(request)
        return AsyncThrowingStream { continuation in
            if !text.isEmpty { continuation.yield(.textDelta(text)) }
            for call in calls { continuation.yield(.toolCall(call)) }
            continuation.yield(.finished(calls.isEmpty ? .stop : .toolCalls))
            continuation.finish()
        }
    }
}

/// A connected app served from memory.
struct FakeAppSource: ConnectedAppSource {
    var tools: [MCPToolDefinition]
    var handler: @Sendable (String, JSONValue) -> MCPToolResult
    let calls = CallLog()

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(String, JSONValue)] = []
        func append(_ name: String, _ arguments: JSONValue) { lock.withLock { entries.append((name, arguments)) } }
        var names: [String] { lock.withLock { entries.map(\.0) } }
        var all: [(String, JSONValue)] { lock.withLock { entries } }
    }

    func listTools() async throws -> [MCPToolDefinition] { tools }
    func callTool(_ name: String, arguments: JSONValue) async throws -> MCPToolResult {
        calls.append(name, arguments)
        return handler(name, arguments)
    }
    func serverDescription() async throws -> MCPServerDescription? { nil }
    func close() async {}
}

func scratchFolder(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("openclicky-tests-\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
