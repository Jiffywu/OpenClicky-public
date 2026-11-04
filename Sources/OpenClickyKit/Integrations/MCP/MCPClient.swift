// A minimal dual-era MCP client: connect (era detection), tools/list, tools/call.
//
// Era detection follows https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning#backward-compatibility-with-initialization-based-versions
// (checked 2026-10-30):
// 1. Send `server/discover` with modern `_meta`.
// 2. A DiscoverResult means modern. A recognized modern error (-32020/-32021/-32022) also means modern; for
//    -32022 pick a version from the server's `supported` list (if it only lists legacy versions, initialize).
// 3. Anything else (a 4xx without a modern error body, another JSON-RPC error, or no answer within the probe
//    timeout on stdio) means legacy: `initialize`, check the negotiated version, send
//    `notifications/initialized`.
// The result is remembered (`era`) so a caller can skip the probe next time.

import Foundation

public actor MCPClient {
    public struct Options: Sendable {
        public var clientInfo: MCPImplementation
        /// Skip the probe and use this era (for example the era found last time). Re-probes if it fails.
        public var knownEra: MCPEra?
        /// How long to wait for the `server/discover` probe before assuming a legacy server.
        public var probeTimeout: Duration
        public var requestTimeout: Duration

        public init(clientInfo: MCPImplementation = MCPImplementation(name: "OpenClicky", version: "1.0"),
                    knownEra: MCPEra? = nil, probeTimeout: Duration = .seconds(10), requestTimeout: Duration = .seconds(120)) {
            self.clientInfo = clientInfo
            self.knownEra = knownEra
            self.probeTimeout = probeTimeout
            self.requestTimeout = requestTimeout
        }
    }

    public let transport: any MCPMessageTransport
    public let options: Options
    public private(set) var server: MCPServerDescription?
    private var nextID = 1
    private var toolsByName: [String: MCPToolDefinition] = [:]
    /// The handshake in progress. Callers that arrive while it runs wait for it instead of starting their own: a
    /// second `initialize` would open a second legacy session, and many stdio servers reject it outright.
    private var connecting: Task<MCPServerDescription, Error>?
    /// Counts completed handshakes, so a request that lost its session can tell whether someone else already
    /// started a new one.
    private var generation = 0

    public init(transport: any MCPMessageTransport, options: Options = Options()) {
        self.transport = transport
        self.options = options
    }

    /// The era in use once connected.
    public var era: MCPEra? { server?.era }

    /// Connects if needed and describes the server.
    @discardableResult
    public func connect() async throws -> MCPServerDescription {
        if let server { return server }
        let knownEra = options.knownEra
        return try await handshake {
            knownEra == .legacy ? try await $0.initializeLegacy(version: MCPProtocolVersion.preferredLegacy) : try await $0.probe()
        }
    }

    /// Runs `operation` as the one handshake in flight, or joins the one already running.
    private func handshake(_ operation: @escaping @Sendable (MCPClient) async throws -> MCPServerDescription) async throws -> MCPServerDescription {
        if let connecting { return try await connecting.value }
        let task = Task { try await operation(self) }
        connecting = task
        defer { connecting = nil }
        let description = try await task.value
        server = description
        generation += 1
        return description
    }

    /// Every tool, following `nextCursor`. On Streamable HTTP, tools with invalid `x-mcp-header` annotations are
    /// left out, as the spec requires.
    public func listTools() async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<100 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request("tools/list", params: params)
            for item in result["tools"]?.arrayValue ?? [] {
                guard let tool = MCPToolDefinition(json: item) else { continue }
                if transport.mirrorsParameterHeaders, MCPHeaderMirroring.parameterHeaders(in: tool.inputSchema) == nil { continue }
                tools.append(tool)
            }
            guard let next = result["nextCursor"]?.stringValue, !next.isEmpty, seenCursors.insert(next).inserted else { break }
            cursor = next
        }
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return tools
    }

    /// Calls one tool. A tool-level failure comes back as a result with `isError`; protocol failures throw.
    public func callTool(_ name: String, arguments: JSONValue = [:]) async throws -> MCPToolResult {
        var headers: [String: String] = [:]
        if transport.mirrorsParameterHeaders, try await connect().era == .modern {
            if toolsByName[name] == nil { _ = try await listTools() }
            if let tool = toolsByName[name] { headers = MCPHeaderMirroring.headers(for: tool.inputSchema, arguments: arguments) }
        }
        let result = try await request("tools/call", params: ["name": .string(name), "arguments": arguments], parameterHeaders: headers)
        return MCPToolResult(json: result)
    }

    /// Sends any request after connecting. Retries once after a lost legacy session.
    public func request(_ method: String, params: [String: JSONValue] = [:], parameterHeaders: [String: String] = [:]) async throws -> JSONValue {
        let description = try await connect()
        let generation = self.generation
        do {
            return try await exchange(method, params: params, era: description.era, version: description.protocolVersion,
                                      parameterHeaders: parameterHeaders, timeout: options.requestTimeout)
        } catch MCPClientError.sessionExpired where description.era == .legacy {
            // Requests that lose the session together re-initialize once: the first to notice starts the
            // handshake, the rest join it (or find it already done).
            let fresh: MCPServerDescription
            if self.generation != generation, let current = server {
                fresh = current
            } else {
                server = nil
                let version = description.protocolVersion
                fresh = try await handshake { try await $0.initializeLegacy(version: version) }
            }
            return try await exchange(method, params: params, era: fresh.era, version: fresh.protocolVersion,
                                      parameterHeaders: parameterHeaders, timeout: options.requestTimeout)
        }
    }

    public func close() async {
        await transport.close()
        server = nil
    }

    // MARK: Era detection

    private func probe() async throws -> MCPServerDescription {
        let version = MCPProtocolVersion.preferredModern
        let outcome: Result<JSONValue, JSONRPCError>
        do {
            outcome = try await send("server/discover", params: [:], era: .modern, version: version, timeout: options.probeTimeout)
        } catch MCPClientError.http(let status, _) where (400..<500).contains(status) {
            return try await fallBackToLegacy(afterStatus: status)
        } catch MCPClientError.timedOut {
            return try await initializeLegacy(version: MCPProtocolVersion.preferredLegacy)
        }
        switch outcome {
        case .success(let result):
            try Self.checkResultType(result)
            let supported = result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) ?? [version]
            let chosen = MCPProtocolVersion.modern.first(where: supported.contains) ?? version
            return MCPServerDescription(era: .modern, protocolVersion: chosen,
                                        serverInfo: MCPImplementation(json: result["_meta"]?["io.modelcontextprotocol/serverInfo"]),
                                        capabilities: result["capabilities"] ?? [:], instructions: result["instructions"]?.stringValue)
        case .failure(let error) where error.code == JSONRPCError.unsupportedProtocolVersion:
            let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if let modern = MCPProtocolVersion.modern.first(where: supported.contains), modern != version {
                // A newer modern revision we also speak; discovery is optional, so just use it.
                return MCPServerDescription(era: .modern, protocolVersion: modern, serverInfo: nil, capabilities: [:], instructions: nil)
            }
            if let legacy = MCPProtocolVersion.legacy.first(where: supported.contains) {
                return try await initializeLegacy(version: legacy)
            }
            throw MCPClientError.unsupportedProtocolVersion(supported: supported)
        case .failure(let error) where error.isRecognizedModernError:
            throw MCPClientError.rpc(error)
        case .failure:
            // Legacy servers answer an unknown pre-initialize method with implementation-defined errors.
            return try await initializeLegacy(version: MCPProtocolVersion.preferredLegacy)
        }
    }

    private func fallBackToLegacy(afterStatus status: Int) async throws -> MCPServerDescription {
        do {
            return try await initializeLegacy(version: MCPProtocolVersion.preferredLegacy)
        } catch MCPClientError.http(let legacyStatus, _) where [404, 405].contains(status) && [404, 405].contains(legacyStatus) {
            // Neither era answered POST: most likely the deprecated HTTP+SSE transport.
            throw MCPClientError.legacySSETransportUnsupported
        }
    }

    private func initializeLegacy(version: String) async throws -> MCPServerDescription {
        await transport.resetSession()
        let params: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": [:],
            "clientInfo": options.clientInfo.json,
        ]
        let result = try await send("initialize", params: params, era: .legacy, version: nil, timeout: options.requestTimeout).get()
        let negotiated = result["protocolVersion"]?.stringValue ?? version
        guard MCPProtocolVersion.legacy.contains(negotiated) else {
            throw MCPClientError.unsupportedProtocolVersion(supported: [negotiated])
        }
        let initialized = MCPOutgoingMessage(id: nil, method: "notifications/initialized")
        try await transport.notify(initialized, context: MCPRequestContext(era: .legacy, protocolVersion: negotiated, timeout: options.requestTimeout))
        return MCPServerDescription(era: .legacy, protocolVersion: negotiated, serverInfo: MCPImplementation(json: result["serverInfo"]),
                                    capabilities: result["capabilities"] ?? [:], instructions: result["instructions"]?.stringValue)
    }

    // MARK: Wire

    private func exchange(_ method: String, params: [String: JSONValue], era: MCPEra, version: String,
                          parameterHeaders: [String: String], timeout: Duration) async throws -> JSONValue {
        switch try await send(method, params: params, era: era, version: version, parameterHeaders: parameterHeaders, timeout: timeout) {
        case .success(let result):
            try Self.checkResultType(result)
            return result
        case .failure(let error):
            throw MCPClientError.rpc(error)
        }
    }

    private func send(_ method: String, params: [String: JSONValue], era: MCPEra, version: String?,
                      parameterHeaders: [String: String] = [:], timeout: Duration) async throws -> Result<JSONValue, JSONRPCError> {
        var params = params
        if era == .modern, let version {
            var meta = params["_meta"]?.objectValue ?? [:]
            for (key, value) in MCPRequestContext.modernMeta(version: version, clientInfo: options.clientInfo).objectValue ?? [:] {
                meta[key] = value
            }
            params["_meta"] = .object(meta)
        }
        let id = JSONRPCID.number(nextID)
        nextID += 1
        let message = MCPOutgoingMessage(id: id, method: method, params: .object(params))
        let context = MCPRequestContext(era: era, protocolVersion: version, parameterHeaders: parameterHeaders, timeout: timeout)
        return try await transport.send(message, context: context)
    }

    /// Results without `resultType` are complete (legacy servers never send it). `input_required` asks for
    /// sampling, elicitation or roots, which OpenClicky does not offer.
    private static func checkResultType(_ result: JSONValue) throws {
        switch result["resultType"]?.stringValue {
        case nil, "complete": return
        case "input_required": throw MCPClientError.inputRequired
        case let other?: throw MCPClientError.invalidResponse("unknown resultType \"\(other)\"")
        }
    }
}
