// Anthropic computer use for the take-over drive: an extension of `AnthropicMessagesClient` that sends one
// non-streaming Messages request with the computer tool and reads back the actions. The streaming chat path is not
// touched.
//
// Verified on 2026-10-31 against:
// - https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
//     `computer_toolset_20260801` is the stable version: no beta header, no `name`, no display size fields (the
//     API rejects `name`, `display_width_px`, `display_height_px`, `display_number` and `enable_zoom` on it);
//     optional `configs` per member (`{"zoom": {"enabled": false}}`). Claude 5.5 models on the Claude API accept
//     only this version. Each action is its own `tool_use` block whose `name` is the member (`left_click`,
//     `type`, `key`, `scroll`, `zoom`, …) with `"toolset_name": "computer"` and no `action` field; every
//     `tool_result` answering a member must echo `"toolset_name": "computer"` and may hold only text and image
//     blocks. Several member calls in one reply are a batch: run in order, stop at the first failure and answer
//     the rest with "Not executed: an earlier computer action in this turn failed." Coordinates are pixels of the
//     screenshots you return; images over the model's limit are rejected, not downscaled (Opus 4.7 and later and
//     every toolset model: 2,576 px long edge and 4,784 visual tokens; earlier models 1,568 px and about 1.15 MP).
//     The earlier beta versions `computer_20251124` (header `computer-use-2025-11-24`; Opus 4.5–4.8, Sonnet 4.6,
//     Opus/Sonnet 5, Fable and Mythos) and `computer_20250124` (header `computer-use-2025-01-24`; Haiku 4.5,
//     Sonnet 4.5 and older) use one tool named `computer` with `display_width_px` / `display_height_px` and the
//     action in `input.action`.
// - https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference#client-toolsets
//     Dispatch on the `toolset_name` + `name` pair; `strict`, `input_examples` and `tool_choice` naming a member
//     are rejected on toolset entries; a tool named `computer` cannot sit next to the toolset.

import Foundation

/// Which computer tool a request declares.
public enum AnthropicComputerToolVersion: String, Sendable, Hashable, CaseIterable {
    /// The stable toolset (no beta header). The only version Claude 5.5 models accept on the Claude API.
    case toolset = "computer_toolset_20260801"
    /// Beta: Opus 4.5 to 4.8, Sonnet 4.6, Opus and Sonnet 5, Fable and Mythos.
    case beta20251124 = "computer_20251124"
    /// Beta: Haiku 4.5, Sonnet 4.5 and older Claude 4 models.
    case beta20250124 = "computer_20250124"

    /// The `anthropic-beta` header the version needs, if any.
    public var betaHeader: String? {
        switch self {
        case .toolset: nil
        case .beta20251124: "computer-use-2025-11-24"
        case .beta20250124: "computer-use-2025-01-24"
        }
    }

    public var isToolset: Bool { self == .toolset }

    /// The longest image edge the models taking this version accept.
    public var maximumImageLongEdge: Int { self == .beta20250124 ? 1568 : 2576 }

    /// The version to declare for a model on Anthropic's own API. Models listed only for an earlier version get it;
    /// every other model, including ones newer than this table, gets the toolset.
    public static func preferred(forModel model: String) -> AnthropicComputerToolVersion {
        let id = model.lowercased()
        let onlyBeta20250124 = ["haiku-4-5", "sonnet-4-5", "opus-4-1", "opus-4-0", "sonnet-4-0", "sonnet-4-2025", "opus-4-2025"]
        if onlyBeta20250124.contains(where: id.contains) { return .beta20250124 }
        let onlyBeta20251124 = ["opus-4-5", "opus-4-6", "opus-4-7", "sonnet-4-6"]
        if onlyBeta20251124.contains(where: id.contains) { return .beta20251124 }
        return .toolset
    }

    /// The `tools` entry. The beta versions carry the display size (the screenshot's pixels); the toolset takes
    /// none and works in the pixels of whatever screenshots it is given.
    public func toolEntry(displayWidth: Int, displayHeight: Int, zoom: Bool) -> JSONValue {
        switch self {
        case .toolset:
            var entry: [String: JSONValue] = ["type": .string(rawValue)]
            if !zoom { entry["configs"] = ["zoom": ["enabled": false]] }
            return .object(entry)
        case .beta20251124:
            var entry: [String: JSONValue] = [
                "type": .string(rawValue), "name": "computer",
                "display_width_px": .number(Double(displayWidth)), "display_height_px": .number(Double(displayHeight)),
            ]
            if zoom { entry["enable_zoom"] = true }
            return .object(entry)
        case .beta20250124:
            return ["type": .string(rawValue), "name": "computer",
                    "display_width_px": .number(Double(displayWidth)), "display_height_px": .number(Double(displayHeight))]
        }
    }
}

/// One `tool_use` block from a reply.
public struct AnthropicToolUse: Sendable, Hashable {
    public var id: String
    public var name: String
    /// `"computer"` for toolset members; nil for ordinary tools and the beta `computer` tool.
    public var toolsetName: String?
    public var input: JSONValue

    public init(id: String, name: String, toolsetName: String? = nil, input: JSONValue) {
        self.id = id
        self.name = name
        self.toolsetName = toolsetName
        self.input = input
    }

    /// A computer action under `version`: a toolset member, or the beta tool named `computer`.
    public func isComputerAction(_ version: AnthropicComputerToolVersion) -> Bool {
        version.isToolset ? toolsetName == "computer" : name == "computer" && toolsetName == nil
    }

    /// The action name: the member name for the toolset, `input.action` for the beta tool.
    public func actionName(_ version: AnthropicComputerToolVersion) -> String {
        version.isToolset ? name : input["action"]?.stringValue ?? ""
    }
}

/// One computer-use reply.
public struct AnthropicComputerUseReply: Sendable {
    /// The assistant content blocks exactly as received (thinking with signatures included), to send back unchanged.
    public var content: [JSONValue]
    public var text: String
    public var toolUses: [AnthropicToolUse]
    public var stopReason: String?
    public var usage: TokenUsage?

    public init(content: [JSONValue], stopReason: String?, usage: TokenUsage?) {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        text = content.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
        toolUses = content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                return nil
            }
            return AnthropicToolUse(id: id, name: name, toolsetName: block["toolset_name"]?.stringValue, input: block["input"] ?? [:])
        }
    }

    /// Parses the body of a non-streaming Messages response.
    public init(response: JSONValue) {
        let usage = response["usage"].map { usage -> TokenUsage in
            let cacheRead = usage["cache_read_input_tokens"]?.intValue ?? 0
            return TokenUsage(inputTokens: (usage["input_tokens"]?.intValue ?? 0) + (usage["cache_creation_input_tokens"]?.intValue ?? 0) + cacheRead,
                              cachedInputTokens: cacheRead, outputTokens: usage["output_tokens"]?.intValue ?? 0)
        }
        self.init(content: response["content"]?.arrayValue ?? [], stopReason: response["stop_reason"]?.stringValue, usage: usage)
    }

    /// Every tool call in order, read as drive actions. A call that is not a computer action becomes an unreadable
    /// action, so it is answered with an error rather than silently dropped (the API requires an answer to each).
    public func plannedActions(_ version: AnthropicComputerToolVersion) -> [PlannedAction] {
        toolUses.map { use in
            guard use.isComputerAction(version) else {
                return PlannedAction(callID: use.id, name: use.name, action: nil, problem: "\(use.name) is not a tool in this session.")
            }
            var input = use.input
            if !version.isToolset, case .object(var fields) = input {
                fields.removeValue(forKey: "action")
                input = .object(fields)
            }
            return PlannedAction.parsing(callID: use.id, name: use.actionName(version), input: input)
        }
    }
}

/// One computer-use request.
public struct AnthropicComputerUseRequest: Sendable {
    public var model: String
    public var system: String
    /// Messages API turns (`{"role", "content": [blocks]}`), sent as given.
    public var messages: [JSONValue]
    public var version: AnthropicComputerToolVersion
    /// The screenshot size, for the beta versions' tool entry.
    public var displayWidth: Int
    public var displayHeight: Int
    public var zoom: Bool
    public var maxTokens: Int
    /// `output_config.effort`; nil leaves the model's default.
    public var effort: String?

    public init(model: String, system: String, messages: [JSONValue], version: AnthropicComputerToolVersion, displayWidth: Int,
                displayHeight: Int, zoom: Bool = true, maxTokens: Int = 4096, effort: String? = nil) {
        self.model = model
        self.system = system
        self.messages = messages
        self.version = version
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.zoom = zoom
        self.maxTokens = maxTokens
        self.effort = effort
    }
}

extension AnthropicMessagesClient {
    /// The JSON body for a computer-use request (non-streaming).
    public func computerUseBody(_ request: AnthropicComputerUseRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "system": .string(request.system),
            "tools": [request.version.toolEntry(displayWidth: request.displayWidth, displayHeight: request.displayHeight, zoom: request.zoom)],
            "messages": .array(request.messages),
        ]
        if let effort = request.effort, !effort.isEmpty {
            body["output_config"] = ["effort": .string(effort)]
            var thinking: [String: JSONValue] = ["type": "adaptive"]
            if let thinkingDisplay { thinking["display"] = .string(thinkingDisplay) }
            body["thinking"] = .object(thinking)
        }
        return .object(body)
    }

    /// The HTTP request: `x-api-key`, `anthropic-version`, and `anthropic-beta` for the beta tool versions (appended
    /// to any beta the provider's headers already name).
    public func computerUseURLRequest(_ request: AnthropicComputerUseRequest) -> URLRequest {
        var headers = ["anthropic-version": effectiveAPIVersion]
        if let key = context.apiKey, !key.isEmpty { headers["x-api-key"] = key }
        if let beta = request.version.betaHeader {
            let existing = context.provider.headers?.first { $0.key.lowercased() == "anthropic-beta" }?.value
            headers["anthropic-beta"] = [existing, beta].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
        }
        var urlRequest = context.jsonRequest(messagesURL, body: computerUseBody(request), headers: headers)
        urlRequest.timeoutInterval = 120
        return urlRequest
    }

    /// Sends one computer-use step and returns the reply. Cancelling the task cancels the request.
    public func computerUseStep(_ request: AnthropicComputerUseRequest) async throws -> AnthropicComputerUseReply {
        let (data, response) = try await context.http.data(for: computerUseURLRequest(request))
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(response.statusCode) else {
            if let payload = try? JSONValue.parse(text), payload["error"] != nil {
                throw AnthropicStreamDecoder.streamError(payload, provider: context.provider.id, status: response.statusCode)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError(provider: context.provider.id, status: response.statusCode,
                                message: trimmed.isEmpty ? "Empty error response" : String(trimmed.prefix(2000)))
        }
        guard let payload = try? JSONValue.parse(text), payload["content"] != nil else {
            throw ProviderError(provider: context.provider.id, status: response.statusCode, message: "The reply was not a Messages response.")
        }
        return AnthropicComputerUseReply(response: payload)
    }

    /// The `tool_result` block answering one action. Toolset results echo `toolset_name`; an image (a screenshot
    /// or a zoom) follows the text.
    public static func computerToolResult(callID: String, version: AnthropicComputerToolVersion, text: String, image: DriveImage?,
                                          isError: Bool) -> JSONValue {
        var content: [JSONValue] = []
        if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
        if let image {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]])
        }
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(callID), "content": .array(content)]
        if version.isToolset { block["toolset_name"] = "computer" }
        if isError { block["is_error"] = true }
        return .object(block)
    }
}
