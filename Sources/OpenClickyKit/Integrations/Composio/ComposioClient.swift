// Optional Composio adapter, used only with the user's own Composio API key (Keychain credential "composio").
// HeyClicky reaches Composio through its own server; OpenClicky talks to Composio directly instead.
//
// Checked against Composio's API reference on 2026-10-30
// (https://docs.composio.dev/reference/api-reference/tool-router/postToolRouterSession and the
// "MCP tool router sessions" guide):
// - `POST https://backend.composio.dev/api/v3.1/tool_router/session` with header `x-api-key` and JSON body
//   `{"user_id": "...", "toolkits": {"enable": [...]}}` (toolkits optional) answers 201 with
//   `{"session_id", "mcp": {"type": "http", "url"}, "tool_router_tools": [...]}`.
// - The SDK sends the session credential to the MCP URL only when that URL has the same origin as the API base
//   URL; OpenClicky follows the same rule for `x-api-key`.
// - Apps (Gmail, Calendar, …) are connected to the Composio user in Composio's dashboard, or through the
//   connection-management tool the session itself offers. The user id must match the one those accounts belong to.

import Foundation

public struct ComposioSession: Sendable, Hashable, Codable {
    public var sessionID: String
    public var mcpURL: URL
    /// The meta tools the session offers (search tools, run tools, manage connections, …).
    public var tools: [String]
}

public enum ComposioError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey
    case http(status: Int, message: String)
    case invalidResponse

    public var description: String {
        switch self {
        case .missingKey: "Add your Composio API key first: occtl key set \(ComposioClient.credentialName)"
        case .http(let status, let message): "Composio HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .invalidResponse: "Composio answered without an MCP URL."
        }
    }
}

public struct ComposioClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://backend.composio.dev/api/v3.1")!
    /// Keychain credential holding the user's Composio API key.
    public static let credentialName = "composio"
    /// The connector id Composio appears under in the connected-apps list and agent configs.
    public static let connectorID = "composio"

    private let apiKey: String
    public let baseURL: URL
    let http: any HTTPTransport

    public init(apiKey: String, baseURL: URL = defaultBaseURL, http: any HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    /// A client using the stored key, or nil when the user has not added one.
    public static func fromKeychain(_ credentials: any CredentialStore, http: any HTTPTransport = URLSessionTransport()) -> ComposioClient? {
        guard let key = try? credentials.secret(named: credentialName), !key.isEmpty else { return nil }
        return ComposioClient(apiKey: key, http: http)
    }

    /// Creates a tool-router session for `userID`, limited to `toolkits` when given.
    public func createSession(userID: String, toolkits: [String] = []) async throws -> ComposioSession {
        guard !apiKey.isEmpty else { throw ComposioError.missingKey }
        var body: [String: JSONValue] = ["user_id": .string(userID)]
        if !toolkits.isEmpty { body["toolkits"] = ["enable": .array(toolkits.map { .string($0) })] }
        var request = URLRequest(url: baseURL.appendingPathComponent("tool_router/session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = Data(JSONValue.object(body).jsonString().utf8)
        let (data, response) = try await http.data(for: request)
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            let message = json?["error"]?["message"]?.stringValue ?? json?["message"]?.stringValue
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw ComposioError.http(status: response.statusCode, message: redact(message))
        }
        guard let urlText = json?["mcp"]?["url"]?.stringValue, let url = URL(string: urlText),
              let sessionID = json?["session_id"]?.stringValue else { throw ComposioError.invalidResponse }
        return ComposioSession(sessionID: sessionID, mcpURL: url,
                               tools: json?["tool_router_tools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// Headers for the session's MCP URL: the API key only when the URL shares the API's origin.
    public func mcpHeaders(for url: URL) -> [String: String] {
        sameOrigin(url, baseURL) ? ["x-api-key": apiKey] : [:]
    }

    /// The name of the header that carries the key to the MCP URL, if one does (for agent configs).
    public func mcpKeyHeaderName(for url: URL) -> String? { sameOrigin(url, baseURL) ? "x-api-key" : nil }

    /// The API key, for an agent's environment only.
    public var apiKeyForEnvironment: String { apiKey }

    func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
    }

    /// Never let the key travel in an error message.
    func redact(_ text: String) -> String {
        apiKey.isEmpty ? text : text.replacingOccurrences(of: apiKey, with: "<redacted>")
    }
}

extension ComposioClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ComposioClient(base: \(baseURL.absoluteString), key: \(apiKey.isEmpty ? "none" : "<redacted>"))" }
    public var debugDescription: String { description }
}
