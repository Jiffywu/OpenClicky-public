// JSON-RPC 2.0 messages and the MCP data types OpenClicky reads (tools, tool results, server identity).
//
// Checked against the MCP specification at https://modelcontextprotocol.io/specification/2026-07-28 on
// 2026-10-30 (basic/index, server/tools, server/discover) and the 2025-11-25 revision for legacy servers:
// - Request ids are strings or integers, never null. Error codes are integers.
// - A result carries `resultType` ("complete" or "input_required"); an absent `resultType` means "complete"
//   (servers on earlier revisions never send it). Any other value is invalid for a client without extensions.
// - -32020 HeaderMismatch, -32021 MissingRequiredClientCapability and -32022 UnsupportedProtocolVersion are the
//   errors that identify a modern server during era detection.

import Foundation

/// A JSON-RPC id. MCP allows strings and integers.
public enum JSONRPCID: Hashable, Sendable, CustomStringConvertible {
    case number(Int)
    case string(String)

    public init?(json: JSONValue?) {
        switch json {
        case .number(let value) where value.rounded() == value: self = .number(Int(value))
        case .string(let value): self = .string(value)
        default: return nil
        }
    }

    public var json: JSONValue {
        switch self {
        case .number(let value): .number(Double(value))
        case .string(let value): .string(value)
        }
    }

    public var description: String {
        switch self {
        case .number(let value): String(value)
        case .string(let value): value
        }
    }
}

/// A JSON-RPC error object as the peer sent it.
public struct JSONRPCError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue, let code = object["code"]?.intValue else { return nil }
        self.init(code: code, message: object["message"]?.stringValue ?? "", data: object["data"])
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let headerMismatch = -32020
    public static let missingRequiredClientCapability = -32021
    public static let unsupportedProtocolVersion = -32022

    /// Errors only a server on the 2026-07-28 revision (or later) sends. Seeing one means "modern server".
    public var isRecognizedModernError: Bool {
        [Self.headerMismatch, Self.missingRequiredClientCapability, Self.unsupportedProtocolVersion].contains(code)
    }

    public var description: String { "JSON-RPC error \(code): \(message)" }
}

/// A request or notification the client sends.
public struct MCPOutgoingMessage: Sendable, Hashable {
    /// Nil for notifications.
    public var id: JSONRPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONRPCID?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { object["id"] = id.json }
        if let params { object["params"] = params }
        return .object(object)
    }

    /// One line of compact JSON. JSON escapes newlines inside strings, so the text never contains a raw newline.
    public var encoded: Data { Data(json.jsonString().utf8) }
}

/// A message the server sent.
public enum MCPIncomingMessage: Sendable, Hashable {
    case response(id: JSONRPCID, result: JSONValue)
    case error(id: JSONRPCID?, error: JSONRPCError)
    case notification(method: String, params: JSONValue?)
    /// A server-to-client request. Servers on the 2026-07-28 revision never send these; legacy servers may
    /// (ping, roots/list). OpenClicky declares no client capabilities, so it answers none of them.
    case request(id: JSONRPCID, method: String, params: JSONValue?)

    public init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        let id = JSONRPCID(json: object["id"])
        if let method = object["method"]?.stringValue {
            if let id { self = .request(id: id, method: method, params: object["params"]) }
            else { self = .notification(method: method, params: object["params"]) }
        } else if let error = JSONRPCError(json: object["error"]) {
            self = .error(id: id, error: error)
        } else if let id, let result = object["result"] {
            self = .response(id: id, result: result)
        } else {
            return nil
        }
    }

    /// Every message in a body: one object, or (legacy 2025-03-26 servers) a batch array.
    public static func parseAll(_ data: Data) -> [MCPIncomingMessage]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        if let array = value.arrayValue { return array.compactMap(MCPIncomingMessage.init(json:)) }
        return MCPIncomingMessage(json: value).map { [$0] }
    }

    /// The outcome for request `id`, if this message is its response.
    func outcome(for id: JSONRPCID) -> Result<JSONValue, JSONRPCError>? {
        switch self {
        case .response(let responseID, let result) where responseID == id: .success(result)
        case .error(let responseID, let error) where responseID == id || responseID == nil: .failure(error)
        default: nil
        }
    }
}

/// Name and version of an MCP client or server.
public struct MCPImplementation: Sendable, Hashable, Codable {
    public var name: String
    public var version: String
    public var title: String?

    public init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue, let name = object["name"]?.stringValue else { return nil }
        self.init(name: name, version: object["version"]?.stringValue ?? "", title: object["title"]?.stringValue)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["name": .string(name), "version": .string(version)]
        if let title { object["title"] = .string(title) }
        return .object(object)
    }
}

/// Behaviour hints a server attaches to a tool. Hints are untrusted: OpenClicky uses them only to be more
/// careful (a tool hinted destructive is never treated as a read), never to skip a check.
public struct MCPToolAnnotations: Sendable, Hashable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue else { return nil }
        self.init(title: object["title"]?.stringValue, readOnlyHint: object["readOnlyHint"]?.boolValue,
                  destructiveHint: object["destructiveHint"]?.boolValue, idempotentHint: object["idempotentHint"]?.boolValue,
                  openWorldHint: object["openWorldHint"]?.boolValue)
    }
}

/// One tool from `tools/list`.
public struct MCPToolDefinition: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var description: String?
    /// JSON Schema for the arguments object.
    public var inputSchema: JSONValue
    public var annotations: MCPToolAnnotations?

    public init(name: String, title: String? = nil, description: String? = nil,
                inputSchema: JSONValue = ["type": "object"], annotations: MCPToolAnnotations? = nil) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }

    public init?(json: JSONValue) {
        guard let object = json.objectValue, let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        self.init(name: name, title: object["title"]?.stringValue, description: object["description"]?.stringValue,
                  inputSchema: object["inputSchema"] ?? ["type": "object"], annotations: MCPToolAnnotations(json: object["annotations"]))
    }

    /// The name people see: the title if the server gave one.
    public var displayName: String { title ?? annotations?.title ?? name }
}

// `MCPToolResult` and `MCPContent` are shared with the loopback MCP server (Browser/MCPServer.swift). The client
// side reads every content type the spec defines: text and images are kept as they are, and other blocks (audio,
// resource links, embedded resources) become short text notes, which is all a model or a terminal needs.

extension MCPContent {
    init(json: JSONValue) {
        let object = json.objectValue ?? [:]
        switch object["type"]?.stringValue {
        case "text":
            self = .text(object["text"]?.stringValue ?? "")
        case "image":
            self = .image(base64: object["data"]?.stringValue ?? "", mimeType: object["mimeType"]?.stringValue ?? "image/png")
        case "audio":
            self = .text("[audio \(object["mimeType"]?.stringValue ?? "")]")
        case "resource_link":
            let name = object["name"]?.stringValue.map { "\($0): " } ?? ""
            self = .text("[link \(name)\(object["uri"]?.stringValue ?? "")]")
        case "resource":
            let resource = object["resource"]?.objectValue ?? [:]
            self = .text(resource["text"]?.stringValue ?? "[resource \(resource["uri"]?.stringValue ?? "")]")
        default:
            self = .text(json.jsonString())
        }
    }
}

extension MCPToolResult {
    /// A `tools/call` result as a server sent it. `isError` means the tool ran and reported a failure the model
    /// should read.
    init(json: JSONValue) {
        let object = json.objectValue ?? [:]
        self.init(content: (object["content"]?.arrayValue ?? []).map(MCPContent.init(json:)),
                  structuredContent: object["structuredContent"], isError: object["isError"]?.boolValue ?? false)
    }

    /// Plain text for a model or a terminal: text blocks in order, images summarized in brackets, and the
    /// structured content as JSON when there is no text at all.
    public var text: String {
        var parts: [String] = []
        for block in content {
            switch block {
            case .text(let text): parts.append(text)
            case .image(_, let mimeType): parts.append("[image \(mimeType)]")
            }
        }
        if parts.isEmpty, let structuredContent { parts.append(structuredContent.jsonString()) }
        return parts.joined(separator: "\n")
    }
}

/// What the client learned about a server when it connected.
public struct MCPServerDescription: Sendable, Hashable {
    public var era: MCPEra
    /// The revision used for every request after connecting.
    public var protocolVersion: String
    public var serverInfo: MCPImplementation?
    public var capabilities: JSONValue
    public var instructions: String?

    public init(era: MCPEra, protocolVersion: String, serverInfo: MCPImplementation?, capabilities: JSONValue, instructions: String?) {
        self.era = era
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.instructions = instructions
    }
}
