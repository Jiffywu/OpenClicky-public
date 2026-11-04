// Protocol eras, transport seam and errors shared by the MCP transports and client.
//
// MCP has two eras (https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning, checked
// 2026-10-30):
// - Modern (2026-07-28 and later): stateless. Every request carries `_meta` with
//   `io.modelcontextprotocol/protocolVersion` (required), `io.modelcontextprotocol/clientCapabilities` (required)
//   and `io.modelcontextprotocol/clientInfo` (recommended). No `initialize`, no sessions. `server/discover`
//   is mandatory on servers and is how a dual-era client probes.
// - Legacy (2025-11-25, 2025-06-18, 2025-03-26): an `initialize` request, then the
//   `notifications/initialized` notification; over HTTP the server may assign an `Mcp-Session-Id`.
// Most hosted servers in late 2026 still speak the legacy era, so OpenClicky is a dual-era client: it tries a
// modern request first and falls back to `initialize` exactly as the versioning page describes.

import Foundation

public enum MCPEra: String, Sendable, Hashable, Codable {
    case modern
    case legacy
}

public enum MCPProtocolVersion {
    /// Modern revisions this client speaks, newest first.
    public static let modern = ["2026-07-28"]
    /// Legacy (initialize-based) revisions this client speaks, newest first.
    public static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26"]

    public static var preferredModern: String { modern[0] }
    public static var preferredLegacy: String { legacy[0] }
}

/// Per-request settings the client hands to a transport.
public struct MCPRequestContext: Sendable, Hashable {
    public var era: MCPEra
    /// Sent as `MCP-Protocol-Version` on HTTP. Nil only for the legacy `initialize` request itself.
    public var protocolVersion: String?
    /// Extra headers mirrored from tool parameters (`Mcp-Param-*`). HTTP only.
    public var parameterHeaders: [String: String]
    /// Give up waiting for the response after this long.
    public var timeout: Duration

    public init(era: MCPEra, protocolVersion: String?, parameterHeaders: [String: String] = [:], timeout: Duration = .seconds(120)) {
        self.era = era
        self.protocolVersion = protocolVersion
        self.parameterHeaders = parameterHeaders
        self.timeout = timeout
    }
}

/// Moves JSON-RPC messages to one server. Streamable HTTP and stdio implement it; tests use in-memory fakes.
public protocol MCPMessageTransport: Sendable {
    /// Sends a request and waits for its response. A JSON-RPC error from the server is returned as `.failure`;
    /// transport problems (HTTP status without a JSON-RPC body, a dead process, a timeout) are thrown.
    func send(_ request: MCPOutgoingMessage, context: MCPRequestContext) async throws -> Result<JSONValue, JSONRPCError>
    /// Sends a notification. No response is expected.
    func notify(_ notification: MCPOutgoingMessage, context: MCPRequestContext) async throws
    /// Forget any legacy session so the next `initialize` starts a new one.
    func resetSession() async
    /// True for Streamable HTTP, where tool parameters marked `x-mcp-header` must be mirrored into headers.
    var mirrorsParameterHeaders: Bool { get }
    func close() async
}

/// Everything that can go wrong talking to an MCP server. Descriptions never contain credentials.
public enum MCPClientError: Error, Sendable, Hashable, CustomStringConvertible {
    /// HTTP 401. The challenge says where to sign in.
    case unauthorized(WWWAuthenticateChallenge?)
    /// HTTP 403, usually `insufficient_scope`.
    case forbidden(WWWAuthenticateChallenge?)
    /// Any other HTTP status without a JSON-RPC error body. `body` is truncated server text.
    case http(status: Int, body: String)
    /// The server answered with a JSON-RPC error.
    case rpc(JSONRPCError)
    /// No protocol revision in common. `supported` is what the server offered.
    case unsupportedProtocolVersion(supported: [String])
    /// HTTP 404 for a legacy session id: the server forgot the session.
    case sessionExpired
    /// The server asked for input (sampling, elicitation, roots) that OpenClicky does not provide.
    case inputRequired
    case invalidResponse(String)
    case timedOut(method: String)
    /// A stdio server exited. `stderr` is the end of what it printed.
    case processExited(status: Int32, stderr: String)
    case launchFailed(String)
    /// Only the deprecated HTTP+SSE transport (2024-11-05) answered.
    case legacySSETransportUnsupported

    public var description: String {
        switch self {
        case .unauthorized(let challenge):
            "The server needs you to sign in (HTTP 401)\(challenge?.errorDescription.map { ": \($0)" } ?? "")."
        case .forbidden(let challenge):
            "The server refused this request (HTTP 403)\(challenge?.error.map { ": \($0)" } ?? "")."
        case .http(let status, let body):
            "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
        case .rpc(let error): error.description
        case .unsupportedProtocolVersion(let supported):
            "The server supports MCP \(supported.isEmpty ? "versions OpenClicky doesn't know" : supported.joined(separator: ", ")); OpenClicky speaks \((MCPProtocolVersion.modern + MCPProtocolVersion.legacy).joined(separator: ", "))."
        case .sessionExpired: "The server ended the MCP session."
        case .inputRequired: "The server asked for input OpenClicky can't provide (sampling, elicitation or roots)."
        case .invalidResponse(let detail): "Unexpected response from the server: \(detail)"
        case .timedOut(let method): "The server didn't answer \(method) in time."
        case .processExited(let status, let stderr):
            "The server process exited (status \(status))\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .launchFailed(let detail): "Couldn't start the server: \(detail)"
        case .legacySSETransportUnsupported:
            "This server only speaks the old HTTP+SSE transport, which OpenClicky doesn't support. Use its Streamable HTTP URL (often ending in /mcp)."
        }
    }
}

extension MCPRequestContext {
    /// The `_meta` every modern request carries.
    static func modernMeta(version: String, clientInfo: MCPImplementation) -> JSONValue {
        [
            "io.modelcontextprotocol/protocolVersion": .string(version),
            "io.modelcontextprotocol/clientInfo": clientInfo.json,
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
    }
}

// MARK: - Header mirroring (Streamable HTTP, 2026-07-28)

/// Header rules from the Streamable HTTP binding: `Mcp-Method`, `Mcp-Name` and `Mcp-Param-{name}` mirror body
/// fields so gateways can route without parsing JSON.
public enum MCPHeaderMirroring {
    /// The value as a header: plain when it is visible ASCII without leading or trailing whitespace, otherwise
    /// the `=?base64?…?=` sentinel form. Plain values that look like the sentinel are encoded too.
    public static func encode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let isPlain = !bytes.isEmpty
            && bytes.allSatisfy { $0 == 0x09 || (0x20...0x7E).contains($0) }
            && bytes.first.map { $0 != 0x20 && $0 != 0x09 } == true
            && bytes.last.map { $0 != 0x20 && $0 != 0x09 } == true
            && !(value.hasPrefix("=?base64?") && value.hasSuffix("?="))
        if isPlain { return value }
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    /// The header-name part allowed in `x-mcp-header`: RFC 9110 token characters.
    static func isToken(_ name: String) -> Bool {
        let extra = Set("!#$%&'*+-.^_`|~")
        return !name.isEmpty && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || extra.contains($0) }
    }

    /// Where each `x-mcp-header` sits in a tool's input schema, or nil when any annotation breaks the rules (the
    /// spec says such a tool must be left out of `tools/list`).
    public static func parameterHeaders(in schema: JSONValue) -> [(header: String, path: [String])]? {
        var found: [(String, [String])] = []
        var valid = true
        func walk(_ node: JSONValue, path: [String]) {
            guard let properties = node["properties"]?.objectValue else { return }
            for (key, child) in properties {
                if let header = child["x-mcp-header"] {
                    let type = child["type"]?.stringValue
                    if let name = header.stringValue, isToken(name), ["string", "integer", "boolean"].contains(type) {
                        found.append((name, path + [key]))
                    } else {
                        valid = false
                    }
                }
                walk(child, path: path + [key])
            }
        }
        walk(schema, path: [])
        // Annotations anywhere else (items, oneOf, $defs, …) are not statically reachable and make the tool invalid.
        guard valid, countAnnotations(in: schema) == found.count else { return nil }
        let lowered = found.map { $0.0.lowercased() }
        guard Set(lowered).count == lowered.count else { return nil }
        return found
    }

    private static func countAnnotations(in value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            return (object["x-mcp-header"] != nil ? 1 : 0) + object.values.reduce(0) { $0 + countAnnotations(in: $1) }
        case .array(let array):
            return array.reduce(0) { $0 + countAnnotations(in: $1) }
        default:
            return 0
        }
    }

    /// `Mcp-Param-*` headers for a call: the argument at each annotated path, converted and encoded. Missing and
    /// null values are left out, as are numbers that are not integers in JavaScript's safe range.
    public static func headers(for schema: JSONValue, arguments: JSONValue) -> [String: String] {
        guard let annotated = parameterHeaders(in: schema) else { return [:] }
        var headers: [String: String] = [:]
        for (header, path) in annotated {
            var node: JSONValue? = arguments
            for key in path { node = node?[key] }
            let text: String?
            switch node {
            case .string(let value): text = value
            case .bool(let value): text = value ? "true" : "false"
            case .number(let value) where value.rounded() == value && abs(value) <= 9_007_199_254_740_991: text = String(Int64(value))
            default: text = nil
            }
            if let text { headers["Mcp-Param-\(header)"] = encode(text) }
        }
        return headers
    }
}
