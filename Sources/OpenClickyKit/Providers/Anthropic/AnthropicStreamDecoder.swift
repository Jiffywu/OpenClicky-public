import Foundation

/// Turns Anthropic Messages server-sent events into `ChatEvent`s, one event at a time, so text reaches the caller
/// as soon as its delta arrives.
///
/// Event flow, per https://platform.claude.com/docs/en/build-with-claude/streaming :
/// `message_start` → for each content block: `content_block_start`, `content_block_delta`…, `content_block_stop` →
/// one or more `message_delta` → `message_stop`, with `ping` events anywhere and `error` events possible after the
/// 200 response. New event types may be added (versioning policy), so unknown events and unknown block or delta
/// types are ignored rather than treated as errors.
struct AnthropicStreamDecoder {
    /// One content block as it accumulates, by its `index` in the final message.
    enum Block: Sendable {
        case text(String)
        case toolUse(id: String, name: String, json: String, startInput: JSONValue)
        case thinking(text: String, signature: String)
        case redactedThinking(data: String)
        /// A block this adapter does not map (server tools, fallback markers, future types).
        case other
    }

    let provider: String
    private(set) var blocks: [Int: Block] = [:]
    private(set) var blockOrder: [Int] = []
    private(set) var stopReason: String?
    /// True once `message_stop` arrived.
    private(set) var isComplete = false

    // Raw usage counters. Anthropic's `input_tokens` excludes cache reads and writes; `message_delta` counts are
    // cumulative, so later values replace earlier ones.
    private var inputTokens: Int?
    private var cacheCreationInputTokens: Int?
    private var cacheReadInputTokens: Int?
    private var outputTokens: Int?

    init(provider: String) { self.provider = provider }

    /// The events one SSE event produces. Throws `ProviderError` for an `error` event or malformed data.
    mutating func consume(_ sse: ServerSentEvent) throws -> [ChatEvent] {
        let payload: JSONValue
        do {
            payload = try JSONValue.parse(sse.data)
        } catch {
            throw ProviderError(provider: provider, message: "Malformed stream event \(sse.event ?? "(unnamed)"): not JSON")
        }
        // Every event names its type both as the SSE event name and in the JSON `type` field.
        let type = payload["type"]?.stringValue ?? sse.event ?? ""
        switch type {
        case "message_start":
            if let usage = payload["message"]?["usage"] { absorbUsage(usage) }
            return []
        case "content_block_start":
            return startBlock(payload)
        case "content_block_delta":
            return applyDelta(payload)
        case "content_block_stop":
            return stopBlock(payload)
        case "message_delta":
            if let reason = payload["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let usage = payload["usage"] { absorbUsage(usage) }
            return []
        case "message_stop":
            isComplete = true
            var events: [ChatEvent] = []
            if let usage = tokenUsage { events.append(.usage(usage)) }
            events.append(.finished(Self.finishReason(stopReason)))
            return events
        case "error":
            throw Self.streamError(payload, provider: provider)
        default:
            // "ping" and any event type added after this adapter was written.
            return []
        }
    }

    /// The final usage, if the stream reported any.
    var tokenUsage: TokenUsage? {
        guard inputTokens != nil || outputTokens != nil || cacheReadInputTokens != nil || cacheCreationInputTokens != nil else {
            return nil
        }
        let cacheRead = cacheReadInputTokens ?? 0
        // `inputTokens` is the whole prompt (uncached + cache writes + cache reads), with cache reads also reported
        // as `cachedInputTokens`, so the numbers mean the same as other dialects where cached tokens are a subset.
        return TokenUsage(inputTokens: (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + cacheRead,
                          cachedInputTokens: cacheRead,
                          outputTokens: outputTokens ?? 0,
                          cacheWriteTokens: cacheCreationInputTokens ?? 0)
    }

    /// The assistant content blocks as received, in order, for replaying the turn. Nil when the turn contains a
    /// block this adapter cannot reproduce faithfully.
    var replayableContent: [JSONValue]? {
        var content: [JSONValue] = []
        for index in blockOrder {
            switch blocks[index] {
            case .text(let text):
                if !text.isEmpty { content.append(["type": "text", "text": .string(text)]) }
            case .toolUse(let id, let name, let json, let startInput):
                content.append(["type": "tool_use", "id": .string(id), "name": .string(name),
                                "input": Self.toolInput(json: json, startInput: startInput)])
            case .thinking(let text, let signature):
                content.append(["type": "thinking", "thinking": .string(text), "signature": .string(signature)])
            case .redactedThinking(let data):
                content.append(["type": "redacted_thinking", "data": .string(data)])
            case .other, nil:
                return nil
            }
        }
        return content
    }

    // MARK: - Content blocks

    private mutating func startBlock(_ payload: JSONValue) -> [ChatEvent] {
        guard let index = payload["index"]?.intValue, let block = payload["content_block"] else { return [] }
        if blocks[index] == nil { blockOrder.append(index) }
        switch block["type"]?.stringValue {
        case "text":
            let text = block["text"]?.stringValue ?? ""
            blocks[index] = .text(text)
            return text.isEmpty ? [] : [.textDelta(text)]
        case "tool_use":
            // `input` here is a placeholder (`{}`); the real input arrives as `input_json_delta` fragments.
            blocks[index] = .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "",
                                     json: "", startInput: block["input"] ?? [:])
            return []
        case "thinking":
            let text = block["thinking"]?.stringValue ?? ""
            blocks[index] = .thinking(text: text, signature: block["signature"]?.stringValue ?? "")
            return text.isEmpty ? [] : [.reasoningDelta(text)]
        case "redacted_thinking":
            blocks[index] = .redactedThinking(data: block["data"]?.stringValue ?? "")
            return []
        default:
            blocks[index] = .other
            return []
        }
    }

    private mutating func applyDelta(_ payload: JSONValue) -> [ChatEvent] {
        guard let index = payload["index"]?.intValue, let delta = payload["delta"], let block = blocks[index] else { return [] }
        switch (delta["type"]?.stringValue, block) {
        case ("text_delta", .text(let text)):
            let piece = delta["text"]?.stringValue ?? ""
            blocks[index] = .text(text + piece)
            return piece.isEmpty ? [] : [.textDelta(piece)]
        case ("input_json_delta", .toolUse(let id, let name, let json, let startInput)):
            let piece = delta["partial_json"]?.stringValue ?? ""
            blocks[index] = .toolUse(id: id, name: name, json: json + piece, startInput: startInput)
            return piece.isEmpty ? [] : [.toolCallDelta(id: id, name: name, argumentsFragment: piece)]
        case ("thinking_delta", .thinking(let text, let signature)):
            // With `display: "omitted"` this delta carries an empty string; nothing to surface then.
            let piece = delta["thinking"]?.stringValue ?? ""
            blocks[index] = .thinking(text: text + piece, signature: signature)
            return piece.isEmpty ? [] : [.reasoningDelta(piece)]
        case ("signature_delta", .thinking(let text, let signature)):
            blocks[index] = .thinking(text: text, signature: signature + (delta["signature"]?.stringValue ?? ""))
            return []
        default:
            // citations_delta, deltas for server-tool blocks, and delta types added later.
            return []
        }
    }

    private func stopBlock(_ payload: JSONValue) -> [ChatEvent] {
        guard let index = payload["index"]?.intValue,
              case .toolUse(let id, let name, let json, let startInput)? = blocks[index] else { return [] }
        return [.toolCall(ToolCall(id: id, name: name, arguments: Self.arguments(json: json, startInput: startInput)))]
    }

    /// The reply as a caller collecting the stream rebuilds it: every text delta joined, and each `.toolCall` as
    /// emitted, in order. Its encoding identifies the turn when the caller sends it back.
    var assistantMessage: ChatMessage {
        var text = ""
        var calls: [ToolCall] = []
        for index in blockOrder {
            switch blocks[index] {
            case .text(let piece): text += piece
            case .toolUse(let id, let name, let json, let startInput):
                calls.append(ToolCall(id: id, name: name, arguments: Self.arguments(json: json, startInput: startInput)))
            default: break
            }
        }
        return .assistant(text, toolCalls: calls)
    }

    /// The model's argument text as streamed. A tool with no parameters may stream no fragments at all; then the
    /// start block's `input` stands in. With eager input streaming the text is not validated by the API and may be
    /// invalid or cut off (check for `.finished(.length)`), so it is passed through untouched for the caller to check.
    static func arguments(json: String, startInput: JSONValue) -> String {
        json.isEmpty ? startInput.jsonString() : json
    }

    // MARK: - Helpers

    private mutating func absorbUsage(_ usage: JSONValue) {
        if let value = usage["input_tokens"]?.intValue { inputTokens = value }
        if let value = usage["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = value }
        if let value = usage["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = value }
        if let value = usage["output_tokens"]?.intValue { outputTokens = value }
    }

    /// The tool input as an object for replay: the accumulated fragments when they parse, else the start placeholder.
    static func toolInput(json: String, startInput: JSONValue) -> JSONValue {
        if !json.isEmpty, let parsed = try? JSONValue.parse(json), parsed.objectValue != nil { return parsed }
        return startInput.objectValue != nil ? startInput : [:]
    }

    /// Stop reasons per https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons .
    static func finishReason(_ stopReason: String?) -> FinishReason {
        switch stopReason {
        case "end_turn", "stop_sequence": .stop
        case "tool_use": .toolCalls
        case "max_tokens", "model_context_window_exceeded": .length
        case "refusal": .contentFilter
        default: .other // "pause_turn", nil, and values added later
        }
    }

    /// HTTP statuses for each error `type`, per https://platform.claude.com/docs/en/api/errors . Mid-stream errors
    /// arrive after a 200, so the status is the one the same error would have had outside a stream.
    static func status(forErrorType type: String?) -> Int? {
        switch type {
        case "invalid_request_error": 400
        case "authentication_error": 401
        case "billing_error": 402
        case "permission_error": 403
        case "not_found_error": 404
        case "conflict_error": 409
        case "request_too_large": 413
        case "rate_limit_error": 429
        case "api_error": 500
        case "timeout_error": 504
        case "overloaded_error": 529
        default: nil
        }
    }

    /// `{"type": "error", "error": {"type": …, "message": …}, "request_id": …}` as a ProviderError.
    static func streamError(_ payload: JSONValue, provider: String, status: Int? = nil) -> ProviderError {
        let errorType = payload["error"]?["type"]?.stringValue
        let message = payload["error"]?["message"]?.stringValue ?? "Unknown error"
        var text = errorType.map { "\($0): \(message)" } ?? message
        if let requestID = payload["request_id"]?.stringValue { text += " (request_id \(requestID))" }
        return ProviderError(provider: provider, status: status ?? Self.status(forErrorType: errorType), message: text)
    }
}
