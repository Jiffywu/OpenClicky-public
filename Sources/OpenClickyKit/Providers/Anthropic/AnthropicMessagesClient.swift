// Anthropic Messages adapter (`anthropic-messages` dialect): streaming chat for the brain slot, and the agent
// slot's model checks, against Anthropic and Anthropic-compatible gateways.
//
// Wire protocol verified on 2026-10-30 against:
// - https://platform.claude.com/docs/en/build-with-claude/streaming            (SSE events, deltas, error events, ping)
// - https://platform.claude.com/docs/en/api/errors                             (error JSON shape, type → HTTP status)
// - https://platform.claude.com/docs/en/api/versioning                         (anthropic-version 2026-10-21 / 2023-06-01)
// - https://platform.claude.com/docs/en/api/migration-2026-10-21               (temperature/top_p/top_k removed on 2026-10-21)
// - https://platform.claude.com/docs/en/build-with-claude/effort               (output_config.effort)
// - https://platform.claude.com/docs/en/build-with-claude/thinking             (adaptive thinking, display, preserving blocks)
// - https://platform.claude.com/docs/en/build-with-claude/preserved-thinking    (prefix check, unbroken run, 400 on new accounts)
// - https://platform.claude.com/docs/en/build-with-claude/vision               (base64 image blocks; jpeg/png/gif/webp)
// - https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls        (tool_use / tool_result)
// - https://platform.claude.com/docs/en/agents-and-tools/tool-use/fine-grained-tool-streaming (eager_input_streaming)
// - https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons (stop_reason values)

import Foundation

/// Streams chat completions from `POST {baseURL}/v1/messages` with `stream: true`.
///
/// Mapping from `ChatRequest`:
/// - System messages become the top-level `system` string (joined with blank lines if there are several).
/// - Images become base64 `image` blocks; assistant tool calls become `tool_use` blocks; tool results become
///   `tool_result` blocks in a user message, and consecutive tool results share one user message (the docs ask for
///   all parallel results in a single message, results first).
/// - Tools become `{name, description, input_schema}`.
/// - `max_tokens` is required by the API: `maxOutputTokens`, else `defaultMaxTokens`.
/// - `reasoningEffort` becomes `output_config.effort` plus `thinking: {type: "adaptive", display: …}`. On Claude 5
///   models adaptive thinking is already the default, so this only sets the effort and makes the reasoning visible;
///   on Opus 4.6–4.8 and Sonnet 4.6 it turns adaptive thinking on. A nil effort sends neither field, leaving the
///   provider default. (Models that only support `budget_tokens`, Claude 4.5 and earlier, reject adaptive thinking;
///   no current catalog entry for this dialect is one of them.) A request's `thinking` overrides that: `.summarized`
///   and `.hidden` send adaptive thinking with `display` `"summarized"` or `"omitted"` (whatever the effort), `.off`
///   sends `thinking: {type: "disabled"}`. Voice turns use `.hidden`: the summary holds the answer text back.
/// - `temperature` is sent only when the API version in use predates `2026-10-21`, which removed it (any value is
///   a 400 there). Claude 4.7 and later accept only the default on every version.
/// - Assistant turns this adapter streamed go back with their original blocks, `thinking` included, as long as the
///   preserved-thinking check would accept them (see `AnthropicThinkingReplay`). A system message added later in the
///   conversation is still hoisted into the top-level `system`; that changes the prefix, so earlier thinking is then
///   left out (accepted by the API, but the model loses that reasoning and the prompt cache restarts).
/// - A reply with thinking also ends with `.providerItems(dialect: "anthropic-messages", items:)`: its blocks as
///   received (thinking with signatures) plus a key item. Kept on the assistant message (`ChatReply` does this), they
///   let the turn's thinking be replayed after a restart too, under the same preserved-thinking checks.
/// - Tool results with `isError` are sent with `is_error: true`.
/// - `hostedTools` (server tools such as web search) are appended to `tools` as given. Their `server_tool_use` and
///   result blocks are not mapped; the text around them streams as usual, and such a turn is not replayed with its
///   thinking.
/// - `promptCache` (https://platform.claude.com/docs/en/build-with-claude/prompt-caching): `system` sends the system
///   prompt as one text block with `cache_control` (caching the tools before it too), `throughMessage` puts
///   `cache_control` on that message's last block, and `automatic` sets the top-level `cache_control` so the
///   breakpoint follows the end of the conversation. Without a hint nothing is cached.
public struct AnthropicMessagesClient: LanguageModelClient {
    public static let defaultBaseURL = "https://api.anthropic.com"
    /// `ChatEvent.providerItems` / `ChatMessage.providerDialect` tag for this adapter's items.
    public static let dialect = ProviderDialect.anthropicMessages.rawValue
    /// The newest API version (https://platform.claude.com/docs/en/api/versioning).
    public static let defaultAPIVersion = "2026-10-21"
    /// Streaming requests can afford a high ceiling; 64K fits every current model (Claude Haiku 4.5's maximum).
    public static let defaultMaxTokens = 64_000

    public let context: ProviderContext
    public let apiVersion: String
    public let defaultMaxTokens: Int
    public let thinkingDisplay: String?
    public let eagerToolInputStreaming: Bool
    public let thinkingReplay: AnthropicThinkingReplay

    /// - Parameters:
    ///   - apiVersion: The `anthropic-version` header. An `anthropic-version` entry in the provider's configured
    ///     headers wins over this, for gateways that only accept an older version.
    ///   - defaultMaxTokens: `max_tokens` when the request leaves `maxOutputTokens` nil.
    ///   - thinkingDisplay: `thinking.display` when `reasoningEffort` is set. `"summarized"` streams readable
    ///     reasoning as `.reasoningDelta`; `"omitted"` hides it for a faster first text token; nil sends no `display`.
    ///   - eagerToolInputStreaming: Sets `eager_input_streaming` on each tool so arguments stream as the model writes
    ///     them (`.toolCallDelta`) instead of after the API buffers each parameter. Nil means on for Anthropic's own
    ///     API and off for other hosts, since a third-party gateway may reject the field.
    ///   - thinkingReplay: Where received assistant turns are kept so their thinking blocks can be sent back.
    public init(context: ProviderContext, apiVersion: String = AnthropicMessagesClient.defaultAPIVersion,
                defaultMaxTokens: Int = AnthropicMessagesClient.defaultMaxTokens, thinkingDisplay: String? = "summarized",
                eagerToolInputStreaming: Bool? = nil, thinkingReplay: AnthropicThinkingReplay = .shared) {
        self.context = context
        self.apiVersion = apiVersion
        self.defaultMaxTokens = defaultMaxTokens
        self.thinkingDisplay = thinkingDisplay
        self.eagerToolInputStreaming = eagerToolInputStreaming ?? Self.isAnthropicHost(context.provider.baseURL)
        self.thinkingReplay = thinkingReplay
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let prepared = prepare(request)
        let urlRequest = makeURLRequest(body: prepared.body)
        let http = context.http
        let provider = context.provider.id
        let replay = thinkingReplay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (chunks, response) = try await http.stream(for: urlRequest)
                    guard (200..<300).contains(response.statusCode) else {
                        throw await Self.httpError(status: response.statusCode, body: chunks, provider: provider)
                    }
                    var decoder = AnthropicStreamDecoder(provider: provider)
                    for try await event in chunks.serverSentEvents() {
                        let events = try decoder.consume(event)
                        if decoder.isComplete, let content = decoder.replayableContent {
                            // Before `.finished`, so a caller that starts the next request right away finds it.
                            let visible = Self.encodeAssistant(decoder.assistantMessage)
                            replay.record(content: content, visible: visible, after: prepared.replayPrefix)
                            if content.contains(where: Self.isThinking),
                               let items = AnthropicThinkingReplay.providerItems(content: content, visible: visible,
                                                                                 after: prepared.replayPrefix) {
                                continuation.yield(.providerItems(dialect: Self.dialect, items: items))
                            }
                        }
                        for chatEvent in events { continuation.yield(chatEvent) }
                        if decoder.isComplete { break }
                    }
                    try Task.checkCancellation()
                    guard decoder.isComplete else {
                        throw ProviderError(provider: provider, message: "Stream ended before message_stop")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    /// The HTTP request for `request`. Sends the API key only as `x-api-key`; nothing here is logged.
    func makeURLRequest(_ request: ChatRequest) -> URLRequest {
        makeURLRequest(body: prepare(request).body)
    }

    private func makeURLRequest(body: JSONValue) -> URLRequest {
        var headers = ["anthropic-version": effectiveAPIVersion]
        if let key = context.apiKey, !key.isEmpty { headers["x-api-key"] = key }
        return context.jsonRequest(messagesURL, body: body, headers: headers)
    }

    /// `{baseURL}/v1/messages`. A base URL that already ends in `/v1` (the convention `ProviderConfig` documents for
    /// other dialects) gets `/messages`, so both `https://api.anthropic.com` and `https://api.anthropic.com/v1` work.
    var messagesURL: URL {
        let base = context.provider.baseURL?.absoluteString ?? Self.defaultBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return context.url(trimmed.hasSuffix("/v1") ? "messages" : "v1/messages", default: Self.defaultBaseURL)
    }

    var effectiveAPIVersion: String {
        context.provider.headers?.first { $0.key.lowercased() == "anthropic-version" }?.value ?? apiVersion
    }

    func requestBody(_ request: ChatRequest) -> JSONValue { prepare(request).body }

    /// The request body, and where its conversation ends so the reply's thinking can be replayed later.
    func prepare(_ request: ChatRequest) -> (body: JSONValue, replayPrefix: AnthropicThinkingReplay.Prefix) {
        let systemText = request.messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }
        let system: JSONValue? = systemText.isEmpty ? nil : .string(systemText.joined(separator: "\n\n"))
        let allTools = request.tools.map(encodeTool) + request.hostedTools
        let tools: JSONValue? = allTools.isEmpty ? nil : .array(allTools)
        let encoded = encodeMessages(request.messages, breakpointAt: request.promptCache?.throughMessage)
        // Cache markers are added after planning so they never change the keys thinking blocks are filed under.
        let plan = thinkingReplay.plan(turns: encoded.turns, system: system, tools: tools)
        var messages = plan.messages
        if let breakpoint = encoded.breakpoint { messages = Self.markCacheBreakpoint(messages, at: breakpoint) }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxOutputTokens ?? defaultMaxTokens)),
            "stream": true,
            "messages": .array(messages),
        ]
        if let system {
            if request.promptCache?.system == true, let text = system.stringValue {
                // A breakpoint on the system prompt caches the tools too: they come before it.
                body["system"] = [["type": "text", "text": .string(text), "cache_control": ["type": "ephemeral"]]]
            } else {
                body["system"] = system
            }
        }
        if request.promptCache?.automatic == true { body["cache_control"] = ["type": "ephemeral"] }
        if let tools { body["tools"] = tools }
        let effort = request.reasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
        if let effort { body["output_config"] = ["effort": .string(effort)] }
        switch request.thinking {
        case .off:
            // Answers at once. Only models and efforts that allow it accept this.
            body["thinking"] = ["type": "disabled"]
        case .summarized:
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
        case .hidden:
            body["thinking"] = ["type": "adaptive", "display": "omitted"]
        case nil:
            if effort != nil {
                var thinking: [String: JSONValue] = ["type": "adaptive"]
                if let thinkingDisplay { thinking["display"] = .string(thinkingDisplay) }
                body["thinking"] = .object(thinking)
            }
        }
        // ISO dates compare correctly as strings.
        if let temperature = request.temperature, effectiveAPIVersion < "2026-10-21" {
            body["temperature"] = .number(temperature)
        }
        return (.object(body), plan.prefix)
    }

    private func encodeTool(_ tool: ToolSpec) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            // `input_schema` must be a JSON Schema object.
            "input_schema": tool.parameters.objectValue != nil ? tool.parameters : ["type": "object", "properties": [:]],
        ]
        if eagerToolInputStreaming { object["eager_input_streaming"] = true }
        return .object(object)
    }

    /// Where a cache breakpoint goes: the turn, and how many of that turn's blocks come after the marked one.
    /// Counting from the end keeps it right when replayed thinking is put back at the front of an assistant turn.
    struct CacheBreakpoint: Equatable {
        var turn: Int
        var blocksAfter: Int
    }

    /// Adds `cache_control` to the block a breakpoint names (no change when it no longer exists).
    static func markCacheBreakpoint(_ messages: [JSONValue], at breakpoint: CacheBreakpoint) -> [JSONValue] {
        guard messages.indices.contains(breakpoint.turn), var turn = messages[breakpoint.turn].objectValue,
              var content = turn["content"]?.arrayValue else { return messages }
        let index = content.count - 1 - breakpoint.blocksAfter
        guard content.indices.contains(index), var block = content[index].objectValue else { return messages }
        block["cache_control"] = ["type": "ephemeral"]
        content[index] = .object(block)
        turn["content"] = .array(content)
        var result = messages
        result[breakpoint.turn] = .object(turn)
        return result
    }

    /// Maps messages to Anthropic turns, merging consecutive turns of the same role (tool results are user turns).
    /// Assistant turns hold only their text and tool calls here; `AnthropicThinkingReplay.plan` puts recorded
    /// thinking back where that is valid.
    private func encodeMessages(_ messages: [ChatMessage]) -> [AnthropicThinkingReplay.Turn] {
        encodeMessages(messages, breakpointAt: nil).turns
    }

    /// As above, also locating the last block of `messages[breakpointAt]` (or of the nearest earlier message that
    /// encodes to anything) for a cache breakpoint.
    private func encodeMessages(_ messages: [ChatMessage], breakpointAt: Int?)
        -> (turns: [AnthropicThinkingReplay.Turn], breakpoint: CacheBreakpoint?) {
        var turns: [AnthropicThinkingReplay.Turn] = []
        // The turn and its block count right after the last message at or before `breakpointAt` that added blocks.
        var marker: (turn: Int, blocks: Int)?
        for (messageIndex, message) in messages.enumerated() {
            let role: String
            let content: [JSONValue]
            var providerItems: [JSONValue] = []
            switch message.role {
            case .system:
                continue
            case .user:
                role = "user"
                content = message.content.compactMap(Self.encodePart)
            case .assistant:
                role = "assistant"
                content = Self.encodeAssistant(message)
                providerItems = message.providerItems(for: Self.dialect)
            case .tool:
                role = "user"
                content = [Self.encodeToolResult(message)]
            }
            guard !content.isEmpty else { continue } // the API rejects empty turns
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].content += content
                // A turn merged from several messages is not any one reply the model produced.
                turns[turns.count - 1].providerItems = []
            } else {
                turns.append(.init(role: role, content: content, providerItems: providerItems))
            }
            if let breakpointAt, messageIndex <= breakpointAt {
                marker = (turns.count - 1, turns[turns.count - 1].content.count)
            }
        }
        let breakpoint = marker.map { CacheBreakpoint(turn: $0.turn, blocksAfter: turns[$0.turn].content.count - $0.blocks) }
        return (turns, breakpoint)
    }

    private static func encodePart(_ part: ContentPart) -> JSONValue? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : ["type": "text", "text": .string(text)]
        case .image(let data, let mimeType):
            return ["type": "image",
                    "source": ["type": "base64", "media_type": .string(mimeType), "data": .string(data.base64EncodedString())]]
        }
    }

    /// Text then `tool_use` blocks. Images are dropped: the API takes images in user turns only.
    static func encodeAssistant(_ message: ChatMessage) -> [JSONValue] {
        var content: [JSONValue] = message.content.compactMap { part in
            if case .text(let text) = part, !text.isEmpty { return ["type": "text", "text": .string(text)] }
            return nil
        }
        for call in message.toolCalls {
            content.append(["type": "tool_use", "id": .string(call.id), "name": .string(call.name),
                            "input": AnthropicStreamDecoder.toolInput(json: call.arguments, startInput: [:])])
        }
        return content
    }

    static func isThinking(_ block: JSONValue) -> Bool {
        let type = block["type"]?.stringValue
        return type == "thinking" || type == "redacted_thinking"
    }

    /// A string `content` for text-only results, an array of text and image blocks when the result has images.
    /// `is_error: true` when the message reports a failure.
    private static func encodeToolResult(_ message: ChatMessage) -> JSONValue {
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(message.toolCallID ?? "")]
        if message.isError { block["is_error"] = true }
        let hasImages = message.content.contains { if case .image = $0 { true } else { false } }
        if hasImages {
            block["content"] = .array(message.content.compactMap(encodePart))
        } else if !message.text.isEmpty {
            block["content"] = .string(message.text)
        }
        return .object(block)
    }

    // MARK: - Errors

    /// A non-2xx response as a ProviderError carrying the API's own `error.message`.
    static func httpError(status: Int, body: AsyncThrowingStream<Data, Error>, provider: String) async -> ProviderError {
        var data = Data()
        do {
            for try await chunk in body {
                data.append(chunk)
                if data.count >= 16_384 { break }
            }
        } catch {
            // Keep whatever arrived; the status alone still explains the failure.
        }
        if let payload = try? JSONValue.parse(String(decoding: data, as: UTF8.self)), payload["error"] != nil {
            return AnthropicStreamDecoder.streamError(payload, provider: provider, status: status)
        }
        let text = String(decoding: data.prefix(16_384), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(provider: provider, status: status, message: text.isEmpty ? "Empty error response" : text)
    }

    static func isAnthropicHost(_ baseURL: URL?) -> Bool {
        guard let host = baseURL?.host()?.lowercased() else { return true }
        return host == "api.anthropic.com"
    }
}
