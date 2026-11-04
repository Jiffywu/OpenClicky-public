import Foundation

/// A loopback relay in front of connected apps that sign in with OAuth, so a job that runs longer than an access
/// token lives keeps working.
///
/// A harness reads an MCP server's bearer token once, when it starts the server, and never again. Handing it the
/// app's OAuth access token directly would break every tool call after the token expires (often after an hour). The
/// job is given `http://127.0.0.1:<port>/apps/<key>/mcp` and a relay token instead; for each request the relay asks
/// the app's token source for a current access token (which refreshes it shortly before expiry), forwards the
/// request upstream, and on a 401 refreshes once and tries again.
///
/// Requests are relayed whole: an upstream reply streamed as server-sent events is collected and returned in one
/// response, which MCP's Streamable HTTP clients accept. A GET (the optional server-to-client event stream) is
/// answered 405, which the transport defines as "no stream here".
public final class AgentConnectorRelay: @unchecked Sendable {
    /// A current access token for the app; `forceRefresh` after the upstream refused the last one.
    public typealias TokenSource = @Sendable (_ forceRefresh: Bool) async throws -> String

    struct Route {
        var upstream: URL
        /// What the agent must send as its bearer token: per route, kept when the route is updated, so a job already
        /// running keeps access after a later launch refreshes the route.
        var localToken: String
        var token: TokenSource
    }

    /// How long one relayed call may take (MCP tool calls can run for minutes).
    public var upstreamTimeout: TimeInterval
    private let http: any HTTPTransport
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var server: LoopbackHTTPServer?

    public init(http: any HTTPTransport = URLSessionTransport(), upstreamTimeout: TimeInterval = 900) {
        self.http = http
        self.upstreamTimeout = upstreamTimeout
    }

    deinit { stop() }

    /// The local URL and bearer token a job uses for this app. Starts the relay on first use; a later call for the
    /// same key updates its upstream and token source but keeps the URL and token.
    public func route(key: String, upstream: URL, token: @escaping TokenSource) throws -> (url: URL, token: String) {
        let port = try startIfNeeded()
        let localToken: String = try lock.withLock {
            let existing = routes[key]?.localToken
            let localToken = try existing ?? BrowserBridgeSecrets.randomHex(bytes: 24)
            routes[key] = Route(upstream: upstream, localToken: localToken, token: token)
            return localToken
        }
        let path = Self.path(for: key)
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw URLError(.badURL) }
        return (url, localToken)
    }

    /// Stops listening; jobs still using the relay lose their connected apps.
    public func stop() {
        let server = lock.withLock { () -> LoopbackHTTPServer? in
            defer { self.server = nil }
            return self.server
        }
        server?.stop()
    }

    static func path(for key: String) -> String {
        "/apps/" + (key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "app") + "/mcp"
    }

    private func startIfNeeded() throws -> UInt16 {
        if let port = lock.withLock({ server?.port }), port != 0 { return port }
        let made = LoopbackHTTPServer(maxBodyBytes: 16 * 1024 * 1024, requestTimeout: 30) { [weak self] request in
            guard let self else { return HTTPResponse.json(503, ["error": "stopped"]) }
            return await self.handle(request)
        }
        _ = try made.start()
        let winner: (LoopbackHTTPServer, Bool) = lock.withLock {
            if let server { return (server, false) }
            server = made
            return (made, true)
        }
        if !winner.1 { made.stop() }
        return winner.0.port
    }

    // MARK: Relaying

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let route = lock.withLock { routes.first { Self.path(for: $0.key) == request.path }?.value }
        guard let route else { return .json(404, ["error": "no such app"]) }
        let presented = request.headers["authorization"].flatMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[0].lowercased() == "bearer" ? String(parts[1]) : nil
        }
        guard let presented, Self.constantTimeEqual(presented, route.localToken) else {
            return .json(401, ["error": "unauthorized"], headers: ["WWW-Authenticate": "Bearer"])
        }
        switch request.method {
        case "POST", "DELETE": break
        case "GET": return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        default: return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
        do {
            var (data, response) = try await forward(request, to: route, forceRefresh: false)
            if response.statusCode == 401 {
                (data, response) = try await forward(request, to: route, forceRefresh: true)
            }
            var headers: [String: String] = [:]
            for name in ["Content-Type", "Mcp-Session-Id", "Mcp-Protocol-Version"] {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            if response.statusCode == 401 {
                return .json(401, Self.rpcError(request, "The app refused OpenClicky's sign-in. Ask the user to sign in again in OpenClicky's Settings → Connected Apps."))
            }
            return HTTPResponse(status: response.statusCode, headers: headers, body: data)
        } catch MCPOAuthError.needsSignIn {
            return .json(401, Self.rpcError(request, "This app needs the user to sign in again in OpenClicky's Settings → Connected Apps."))
        } catch {
            return .json(502, Self.rpcError(request, "Couldn't reach the app: \(error.localizedDescription)"))
        }
    }

    private func forward(_ request: HTTPRequest, to route: Route, forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        let token = try await route.token(forceRefresh)
        var upstream = URLRequest(url: route.upstream, timeoutInterval: upstreamTimeout)
        upstream.httpMethod = request.method
        for name in ["content-type", "accept", "mcp-session-id", "mcp-protocol-version", "last-event-id"] {
            if let value = request.headers[name] { upstream.setValue(value, forHTTPHeaderField: name) }
        }
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !request.body.isEmpty { upstream.httpBody = request.body }
        return try await http.data(for: upstream)
    }

    /// A JSON-RPC error for the request's id, so an MCP client shows the message instead of a bare HTTP status.
    static func rpcError(_ request: HTTPRequest, _ message: String) -> JSONValue {
        let id = (try? JSONValue.parse(String(decoding: request.body, as: UTF8.self)))?["id"] ?? .null
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32001, "message": .string(message)]]
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
