import Foundation

/// One block of MCP tool output.
public enum MCPContent: Sendable, Hashable {
    case text(String)
    /// Base64 image data.
    case image(base64: String, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .image(let data, let mime): ["type": "image", "data": .string(data), "mimeType": .string(mime)]
        }
    }
}

public struct MCPToolResult: Sendable, Hashable {
    public var content: [MCPContent]
    /// A JSON object mirroring the text, for clients that read structured results.
    public var structuredContent: JSONValue?
    public var isError: Bool

    public init(content: [MCPContent], structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public static func error(_ message: String, structured: JSONValue? = nil) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], structuredContent: structured ?? ["error": .string(message)], isError: true)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["content": .array(content.map(\.json)), "isError": .bool(isError)]
        if case .object = structuredContent { object["structuredContent"] = structuredContent }
        return .object(object)
    }
}

/// The HTTP request a tool call arrived in, for handlers that need more than `_meta` (the calling job's header).
public enum MCPServerRequest {
    /// The request's headers, names lowercased; empty outside an HTTP request.
    @TaskLocal public static var headers: [String: String] = [:]
}

/// A tool an MCP server offers. `meta` is the call's `params._meta` (harnesses put turn metadata there).
public struct MCPTool: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: JSONValue?
    /// The tool definition's own `_meta` in `tools/list` (extra hints a client may read).
    public var meta: JSONValue?
    /// When set, `tools/list` asks it for the description each time, so the text can follow the server's state.
    public var describe: (@Sendable () -> String)?
    public var handler: @Sendable (_ arguments: JSONValue, _ meta: JSONValue?) async -> MCPToolResult

    public init(name: String, description: String, inputSchema: JSONValue, annotations: JSONValue? = nil, meta: JSONValue? = nil,
                describe: (@Sendable () -> String)? = nil,
                handler: @escaping @Sendable (_ arguments: JSONValue, _ meta: JSONValue?) async -> MCPToolResult) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.meta = meta
        self.describe = describe
        self.handler = handler
    }

    /// The description `tools/list` shows now.
    public var currentDescription: String { describe?() ?? description }
}

/// A Model Context Protocol server over the Streamable HTTP transport, answering every POST with a single JSON
/// response (no SSE streams, no sessions). Bound to 127.0.0.1; every request needs `Authorization: Bearer <token>`.
public final class MCPHTTPServer: @unchecked Sendable {
    /// Protocol revisions this server speaks, newest first; the newest is offered when the client asks for an unknown one.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let path = "/mcp"

    public let name: String
    public let version: String
    public let instructions: String?
    private let token: String
    private let tools: [String: MCPTool]
    private let toolOrder: [String]
    private let lock = NSLock()
    private var http: LoopbackHTTPServer?

    public init(name: String, version: String, token: String, tools: [MCPTool], instructions: String? = nil) {
        self.name = name
        self.version = version
        self.token = token
        self.instructions = instructions
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        self.toolOrder = tools.map(\.name)
    }

    deinit { stop() }

    /// Starts listening on 127.0.0.1 (port 0 = any free port) and returns the endpoint URL.
    @discardableResult
    public func start(port: UInt16 = 0) throws -> URL {
        let server = LoopbackHTTPServer(port: port) { [weak self] request in
            guard let self else { return .json(500, ["error": "stopped"]) }
            return await self.handle(request)
        }
        let bound = try server.start()
        lock.withLock { http = server }
        return URL(string: "http://127.0.0.1:\(bound)\(Self.path)")!
    }

    public func stop() {
        let server = lock.withLock { () -> LoopbackHTTPServer? in
            defer { http = nil }
            return http
        }
        server?.stop()
    }

    // MARK: HTTP

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path == Self.path else { return .json(404, ["error": "not_found"]) }
        // DNS-rebinding guard: a browser page may only reach this from a loopback origin (and still needs the token).
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) {
            return .json(403, ["error": "forbidden_origin"])
        }
        let presented = request.headers["authorization"].flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        } ?? ""
        guard BrowserBridgeSecrets.constantTimeEquals(presented, token) else {
            return .json(401, ["error": "unauthorized"], headers: ["WWW-Authenticate": "Bearer"])
        }
        // Clients repeat the negotiated revision in this header after initialize; an unknown one is a 400 (spec).
        if let version = request.headers["mcp-protocol-version"], !Self.supportedProtocolVersions.contains(version) {
            return .json(400, ["jsonrpc": "2.0", "error": ["code": -32600, "message": .string("Unsupported MCP-Protocol-Version \(version)")]])
        }
        switch request.method {
        case "POST":
            break
        case "DELETE":
            // Stateless server: there is no session to end.
            return HTTPResponse(status: 200)
        default:
            // GET would open a server-to-client SSE stream, which this server doesn't offer.
            return .json(405, ["error": "method_not_allowed"], headers: ["Allow": "POST, DELETE"])
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return .json(400, Self.errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        // Tools read the job's identity two ways: `x-openclicky-*` headers merged into a call's `_meta` (the browser
        // tool) and the whole request's headers through `MCPServerRequest.headers` (the job tools).
        let forwarded = Self.forwardedHeaders(request.headers)
        return await MCPServerRequest.$headers.withValue(request.headers) {
            if case .array(let batch) = message {
                var replies: [JSONValue] = []
                for item in batch {
                    if let reply = await handleMessage(item, headers: forwarded) { replies.append(reply) }
                }
                return replies.isEmpty ? HTTPResponse(status: 202) : .json(200, .array(replies))
            }
            guard let reply = await handleMessage(message, headers: forwarded) else { return HTTPResponse(status: 202) }
            return .json(200, reply)
        }
    }

    /// Request headers a tool may read, by lowercase name: only OpenClicky's own `x-openclicky-*` headers (a job's
    /// identity, which harnesses send as a per-server header). Never the authorization header.
    static func forwardedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.lowercased().hasPrefix(headerPrefix) }
            .reduce(into: [:]) { $0[$1.key.lowercased()] = String($1.value.prefix(200)) }
    }

    public static let headerPrefix = "x-openclicky-"

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard origin != "null", let host = URL(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    // MARK: JSON-RPC

    /// Answers one JSON-RPC message; nil for notifications and client responses (HTTP 202).
    /// - Parameter headers: forwarded request headers (`forwardedHeaders`); a `tools/call` sees them merged into its
    ///   `_meta` under their lowercase names, where the call's own `_meta` can't override them.
    public func handleMessage(_ message: JSONValue, headers: [String: String] = [:]) async -> JSONValue? {
        guard case .object(let object) = message else {
            return Self.errorResponse(id: .null, code: -32600, message: "Invalid Request")
        }
        guard let method = object["method"]?.stringValue else {
            // A response to a server request (this server sends none) or junk.
            return object["id"] == nil || object["result"] != nil || object["error"] != nil
                ? nil : Self.errorResponse(id: object["id"] ?? .null, code: -32600, message: "Invalid Request")
        }
        guard let id = object["id"], id != .null else { return nil }  // notification
        let params = object["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return Self.resultResponse(id: id, .object(result))
        case "ping":
            return Self.resultResponse(id: id, .object([:]))
        case "tools/list":
            let list: [JSONValue] = toolOrder.compactMap { tools[$0] }.map { tool in
                var entry: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.currentDescription), "inputSchema": tool.inputSchema]
                if let annotations = tool.annotations { entry["annotations"] = annotations }
                if let meta = tool.meta { entry["_meta"] = meta }
                return .object(entry)
            }
            return Self.resultResponse(id: id, ["tools": .array(list)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "Invalid params: missing tool name")
            }
            guard let tool = tools[name] else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard case .object = arguments else {
                return Self.errorResponse(id: id, code: -32602, message: "Invalid params: arguments must be an object")
            }
            var meta = params["_meta"]
            if !headers.isEmpty {
                var merged = meta?.objectValue ?? [:]
                for key in merged.keys where key.lowercased().hasPrefix(Self.headerPrefix) { merged[key] = nil }
                for (name, value) in headers { merged[name] = .string(value) }
                meta = .object(merged)
            } else if var own = meta?.objectValue, own.keys.contains(where: { $0.lowercased().hasPrefix(Self.headerPrefix) }) {
                // Identity only comes from headers the harness sets, never from what a model wrote into `_meta`.
                for key in own.keys where key.lowercased().hasPrefix(Self.headerPrefix) { own[key] = nil }
                meta = .object(own)
            }
            let result = await tool.handler(arguments, meta)
            return Self.resultResponse(id: id, result.json)
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func resultResponse(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

/// A small MCP client for the Streamable HTTP transport (JSON or SSE answers). Used by `occtl browser call` and tests.
public struct MCPHTTPClient: Sendable {
    public var url: URL
    public var token: String?
    public var timeout: TimeInterval
    /// Sent as `MCP-Protocol-Version` on every request after `initialize`.
    public var protocolVersion = MCPHTTPServer.supportedProtocolVersions[0]
    /// More headers on every request (a job's `X-OpenClicky-Job`, as a harness would send it).
    public var headers: [String: String] = [:]
    private let session: URLSession

    public struct RPCError: Error, CustomStringConvertible {
        public var status: Int
        public var code: Int?
        public var message: String
        public var description: String { "MCP error\(code.map { " \($0)" } ?? "") (HTTP \(status)): \(message)" }
    }

    public init(url: URL, token: String?, timeout: TimeInterval = 120) {
        self.url = url
        self.token = token
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    /// Sends one JSON-RPC request and returns its `result`.
    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        let body: JSONValue = ["jsonrpc": "2.0", "id": .string(UUID().uuidString), "method": .string(method), "params": params]
        let (data, status) = try await post(body)
        guard status == 200 else {
            throw RPCError(status: status, code: nil, message: String(decoding: data.prefix(2000), as: UTF8.self))
        }
        let reply = try Self.decodeReply(data)
        if let error = reply["error"] {
            throw RPCError(status: status, code: error["code"]?.intValue, message: error["message"]?.stringValue ?? "")
        }
        return reply["result"] ?? .null
    }

    /// Sends a notification; returns the HTTP status (202 expected).
    @discardableResult
    public func notify(_ method: String, params: JSONValue = .object([:])) async throws -> Int {
        try await post(["jsonrpc": "2.0", "method": .string(method), "params": params]).1
    }

    public func initialize(protocolVersion: String = MCPHTTPServer.supportedProtocolVersions[0]) async throws -> JSONValue {
        let result = try await request("initialize", params: [
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": ["name": "occtl", "version": "0.1.0"],
        ])
        try await notify("notifications/initialized")
        return result
    }

    public func listTools() async throws -> [JSONValue] {
        try await request("tools/list")["tools"]?.arrayValue ?? []
    }

    public func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try await request("tools/call", params: ["name": .string(name), "arguments": arguments])
    }

    public func post(_ body: JSONValue) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body["method"]?.stringValue != "initialize" {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = Data(body.jsonString().utf8)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// A JSON body, or the last `data:` event of an SSE body.
    static func decodeReply(_ data: Data) throws -> JSONValue {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { return value }
        var parser = SSEParser()
        let events = parser.feed(data) + parser.finish()
        guard let last = events.last else { throw RPCError(status: 200, code: nil, message: "empty reply") }
        return try JSONValue.parse(last.data)
    }
}
