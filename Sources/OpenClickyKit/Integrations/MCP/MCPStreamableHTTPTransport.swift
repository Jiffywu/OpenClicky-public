// Streamable HTTP transport for MCP.
//
// Checked against https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
// and the 2025-11-25 revision it replaces, on 2026-10-30:
// - Every message is its own POST to one endpoint, with `Accept: application/json, text/event-stream`.
// - A notification is answered with 202 and no body. A request is answered with `application/json` (one
//   object) or `text/event-stream` (request-scoped notifications, then the response). Clients must handle both.
// - Every POST carries `MCP-Protocol-Version`. Modern requests also mirror `Mcp-Method`, `Mcp-Name` (for
//   tools/call, resources/read, prompts/get) and `Mcp-Param-*` from the body.
// - Legacy servers may assign `Mcp-Session-Id` on the initialize response; the client echoes it on every later
//   request, and a 404 for that id means the session is gone and the client must initialize again.
// - Authorization (basic/authorization): `Authorization: Bearer <token>` on every request, never in the URL.
//   401 carries a Bearer `WWW-Authenticate` challenge; 403 with `insufficient_scope` asks for more scopes.
// Closing a request's SSE stream is how a modern client cancels it, so cancelling the calling task (which
// cancels the HTTP request) is the cancellation signal.

import Foundation

/// Supplies the `Authorization` header and gets one chance to recover after a 401 (for example by refreshing an
/// OAuth token).
public protocol MCPAuthorizer: Sendable {
    /// The full header value ("Bearer …"), or nil to send none.
    func authorizationHeader() async throws -> String?
    /// Called once after a 401. Return true to retry the request with a fresh `authorizationHeader()`.
    func recover(from challenge: WWWAuthenticateChallenge?) async -> Bool
}

/// A fixed bearer token (an API key or personal access token).
public struct StaticBearerAuthorizer: MCPAuthorizer {
    private let token: String

    public init(token: String) { self.token = token }

    public func authorizationHeader() async throws -> String? { "Bearer \(token)" }
    public func recover(from challenge: WWWAuthenticateChallenge?) async -> Bool { false }
}

public final class MCPStreamableHTTPTransport: MCPMessageTransport, @unchecked Sendable {
    public let endpoint: URL
    private let http: any HTTPTransport
    private let authorizer: (any MCPAuthorizer)?
    /// Extra headers on every request (for example a gateway's `x-api-key`). Values are secrets: never logged.
    private let staticHeaders: [String: String]
    private let onNotification: (@Sendable (String, JSONValue?) -> Void)?
    private let lock = NSLock()
    private var sessionID: String?

    public init(endpoint: URL, http: any HTTPTransport = URLSessionTransport(), authorizer: (any MCPAuthorizer)? = nil,
                staticHeaders: [String: String] = [:], onNotification: (@Sendable (String, JSONValue?) -> Void)? = nil) {
        self.endpoint = endpoint
        self.http = http
        self.authorizer = authorizer
        self.staticHeaders = staticHeaders
        self.onNotification = onNotification
    }

    public var mirrorsParameterHeaders: Bool { true }

    /// The legacy session the server assigned, if any.
    public var currentSessionID: String? { lock.withLock { sessionID } }

    public func resetSession() async { lock.withLock { sessionID = nil } }

    public func close() async {
        // A legacy session can be ended with DELETE. Best effort: servers may answer 405.
        guard let session = lock.withLock({ () -> String? in defer { sessionID = nil }; return sessionID }) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        request.timeoutInterval = 5
        if let header = try? await authorizer?.authorizationHeader() { request.setValue(header, forHTTPHeaderField: "Authorization") }
        _ = try? await http.data(for: request)
    }

    public func notify(_ notification: MCPOutgoingMessage, context: MCPRequestContext) async throws {
        let (status, body, _) = try await post(notification, context: context, expectResponseFor: nil)
        // 202 is the specified answer; some servers send 200 or 204. Anything 2xx is accepted.
        guard (200..<300).contains(status) else { throw MCPClientError.http(status: status, body: body) }
    }

    public func send(_ request: MCPOutgoingMessage, context: MCPRequestContext) async throws -> Result<JSONValue, JSONRPCError> {
        guard let id = request.id else { throw MCPClientError.invalidResponse("a request needs an id") }
        let (status, body, outcome) = try await post(request, context: context, expectResponseFor: id)
        if let outcome { return outcome }
        if (200..<300).contains(status) {
            throw MCPClientError.invalidResponse(status == 202 ? "the server accepted a request without answering it" : "no response for request \(id)")
        }
        throw MCPClientError.http(status: status, body: body)
    }

    // MARK: Request

    private func makeRequest(_ message: MCPOutgoingMessage, context: MCPRequestContext) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message.encoded
        request.timeoutInterval = TimeInterval(context.timeout.components.seconds)
        for (name, value) in staticHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version = context.protocolVersion { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if context.era == .modern {
            request.setValue(message.method, forHTTPHeaderField: "Mcp-Method")
            if ["tools/call", "prompts/get", "resources/read"].contains(message.method),
               let name = message.params?["name"]?.stringValue ?? message.params?["uri"]?.stringValue {
                request.setValue(MCPHeaderMirroring.encode(name), forHTTPHeaderField: "Mcp-Name")
            }
            for (name, value) in context.parameterHeaders { request.setValue(value, forHTTPHeaderField: name) }
        } else if let session = lock.withLock({ sessionID }) {
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let header = try await authorizer?.authorizationHeader() { request.setValue(header, forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Posts one message. Returns the HTTP status, the body text for errors, and the outcome for `id` if the
    /// response carried one.
    private func post(_ message: MCPOutgoingMessage, context: MCPRequestContext, expectResponseFor id: JSONRPCID?)
        async throws -> (Int, String, Result<JSONValue, JSONRPCError>?)
    {
        var attempt = 0
        while true {
            attempt += 1
            let request = try await makeRequest(message, context: context)
            let sentSession = request.value(forHTTPHeaderField: "Mcp-Session-Id")
            let (stream, response) = try await withTimeout(context.timeout, method: message.method) {
                try await self.http.stream(for: request)
            }
            if let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty, context.era == .legacy {
                lock.withLock { sessionID = assigned }
            }
            let status = response.statusCode
            let challenge = WWWAuthenticateChallenge.bearer(from: response.value(forHTTPHeaderField: "WWW-Authenticate"))

            if status == 401 {
                if attempt == 1, let authorizer, await authorizer.recover(from: challenge) { continue }
                throw MCPClientError.unauthorized(challenge)
            }
            if status == 403, challenge != nil { throw MCPClientError.forbidden(challenge) }

            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if (200..<300).contains(status), contentType.hasPrefix("text/event-stream"), let id {
                let outcome = try await withTimeout(context.timeout, method: message.method) {
                    try await self.readEventStream(stream, id: id)
                }
                return (status, "", outcome)
            }

            let body = try await collect(stream, limit: 4 * 1024 * 1024)
            // 404 for a request that carried a legacy session id means the session is gone, whatever the body says
            // (SDK servers add an id-less JSON-RPC error such as "Session not found").
            if status == 404, sentSession != nil {
                lock.withLock { sessionID = nil }
                throw MCPClientError.sessionExpired
            }
            if let messages = MCPIncomingMessage.parseAll(body) {
                deliver(messages)
                if let id, let outcome = messages.lazy.compactMap({ $0.outcome(for: id) }).first { return (status, "", outcome) }
                // A JSON-RPC error without an id (malformed request, header mismatch on a notification).
                if case .error(nil, let error)? = messages.first, !(200..<300).contains(status) { return (status, "", .failure(error)) }
            }
            return (status, Self.excerpt(body), nil)
        }
    }

    private func readEventStream(_ stream: AsyncThrowingStream<Data, Error>, id: JSONRPCID) async throws -> Result<JSONValue, JSONRPCError>? {
        for try await event in stream.serverSentEvents() {
            guard event.event == nil || event.event == "message",
                  let messages = MCPIncomingMessage.parseAll(Data(event.data.utf8)) else { continue }
            deliver(messages)
            // The response ends the request; leaving the loop cancels the stream (and the HTTP request).
            if let outcome = messages.lazy.compactMap({ $0.outcome(for: id) }).first { return outcome }
        }
        return nil
    }

    private func deliver(_ messages: [MCPIncomingMessage]) {
        guard let onNotification else { return }
        for case .notification(let method, let params) in messages { onNotification(method, params) }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var body = Data()
        for try await chunk in stream {
            body.append(chunk)
            if body.count > limit { throw MCPClientError.invalidResponse("response larger than \(limit / 1_048_576) MB") }
        }
        return body
    }

    static func excerpt(_ body: Data) -> String {
        String(decoding: body.prefix(2_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs `operation`, throwing `MCPClientError.timedOut` if it takes longer than `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, method: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw MCPClientError.timedOut(method: method)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
