import Foundation

/// Turns Responses API server-sent events into `ChatEvent`s, one event at a time, as they arrive.
///
/// Event types handled (names and fields from the streaming-events reference):
/// - `response.output_text.delta` → `.textDelta`. `response.refusal.delta` is also visible output (the model
///   declining), so it is surfaced as text too.
/// - `response.reasoning_summary_text.delta` → `.reasoningDelta`. `response.reasoning_text.delta` (raw reasoning,
///   sent by models that expose it) is also `.reasoningDelta`. When reasoning moves to a new summary part, content
///   part or reasoning item (a response can hold several), a `.reasoningDelta("\n\n")` paragraph break comes
///   first, so the parts don't run together. Nothing is added before the first reasoning text.
/// - `response.output_item.added` with a `function_call` item registers the call's `call_id` and `name`;
///   `response.function_call_arguments.delta` yields `.toolCallDelta`; `response.function_call_arguments.done`
///   yields the finished `.toolCall`. `response.output_item.done` and the `output` array of
///   `response.completed` are fallbacks for a call that never got an arguments `done` event. Each call is
///   emitted once.
/// - `response.completed` → `.providerItems` (only when the output holds an encrypted reasoning item or a message with a
///   `phase`; see `OpenAIResponsesClient`), `.usage` and `.finished(.stop | .toolCalls)`. The items are the completed
///   response's `output`, or the `response.output_item.done` items in output order when a server leaves it empty.
///   `response.incomplete` → `.usage` and `.finished(.length | .contentFilter | .other)` from
///   `incomplete_details.reason`; a cut-off reply's items are not offered for replay.
/// - `response.failed` and `error` throw `ProviderError`.
/// Other documented events (`response.created`, `response.in_progress`, `response.content_part.*`,
/// `response.reasoning_summary_part.*`, `*.done` text events, annotations, built-in tool progress) carry nothing a
/// chat client needs and are ignored.
///
/// Numbers are read with `Int(exactly:)`: they come from the network, and a value outside `Int`'s range would
/// otherwise trap.
struct OpenAIResponsesEventDecoder: Sendable {
    let provider: String
    /// True once a terminal event (`response.completed` / `response.incomplete`) has been decoded.
    private(set) var isFinished = false

    private struct PendingCall: Sendable {
        var callID: String
        var name: String
        var arguments: String
    }

    /// In-progress function calls by `output_index`. Delta events carry both `item_id` and `output_index`; the
    /// function-call item's `id` is optional in the schema, so `item_id` is resolved first and `output_index`
    /// is the fallback.
    private var calls: [Int: PendingCall] = [:]
    private var indexByItemID: [String: Int] = [:]
    private var emittedCallIDs: Set<String> = []
    /// Which reasoning stream (item, summary part or content part) the last reasoning delta belonged to.
    private var lastReasoningSource: String?
    /// Finished output items by `output_index`, for replay when `response.completed` lists no output.
    private var doneItems: [Int: JSONValue] = [:]

    init(provider: String) { self.provider = provider }

    mutating func decode(_ sse: ServerSentEvent) throws -> [ChatEvent] {
        // OpenAI does not send a `[DONE]` sentinel on /responses, but some compatible servers do.
        if sse.data == "[DONE]" { return [] }
        let json: JSONValue
        do {
            json = try JSONValue.parse(sse.data)
        } catch {
            throw ProviderError(provider: provider, message: "Unreadable \(sse.event ?? "stream") event: \(sse.data.prefix(200))")
        }
        return try decode(json, eventName: sse.event)
    }

    mutating func decode(_ event: JSONValue, eventName: String? = nil) throws -> [ChatEvent] {
        guard let type = event["type"]?.stringValue ?? eventName else { return [] }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            return nonEmpty(event["delta"]?.stringValue).map { [.textDelta($0)] } ?? []

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = nonEmpty(event["delta"]?.stringValue) else { return [] }
            let item = event["item_id"]?.stringValue ?? Self.int(event["output_index"]).map(String.init) ?? ""
            let part = type == "response.reasoning_text.delta"
                ? "content/\(Self.int(event["content_index"]) ?? 0)" : "summary/\(Self.int(event["summary_index"]) ?? 0)"
            let source = "\(item)/\(part)"
            defer { lastReasoningSource = source }
            if let last = lastReasoningSource, last != source { return [.reasoningDelta("\n\n"), .reasoningDelta(delta)] }
            return [.reasoningDelta(delta)]

        case "response.output_item.added":
            guard let item = event["item"], item["type"]?.stringValue == "function_call",
                  let index = Self.int(event["output_index"]) else { return [] }
            let call = PendingCall(callID: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "",
                                   name: item["name"]?.stringValue ?? "",
                                   arguments: item["arguments"]?.stringValue ?? "")
            calls[index] = call
            if let itemID = item["id"]?.stringValue { indexByItemID[itemID] = index }
            return call.arguments.isEmpty ? [] : [.toolCallDelta(id: call.callID, name: call.name, argumentsFragment: call.arguments)]

        case "response.function_call_arguments.delta":
            guard let index = callIndex(event), let fragment = nonEmpty(event["delta"]?.stringValue) else { return [] }
            calls[index]?.arguments += fragment
            guard let call = calls[index] else { return [] }
            return [.toolCallDelta(id: call.callID, name: call.name, argumentsFragment: fragment)]

        case "response.function_call_arguments.done":
            guard let index = callIndex(event), var call = calls[index] else { return [] }
            if let arguments = event["arguments"]?.stringValue { call.arguments = arguments }
            calls[index] = call
            return emit(call)

        case "response.output_item.done":
            if let item = event["item"], let index = Self.int(event["output_index"]) { doneItems[index] = item }
            guard let item = event["item"], item["type"]?.stringValue == "function_call" else { return [] }
            let streamed = Self.int(event["output_index"]).flatMap { calls[$0] }
            return emit(functionCall(item, streamed: streamed))

        case "response.completed":
            isFinished = true
            var events: [ChatEvent] = []
            // A server that skipped the per-item events still lists every call in the final output.
            let output = event["response"]?["output"]?.arrayValue ?? []
            for item in output where item["type"]?.stringValue == "function_call" {
                events += emit(functionCall(item, streamed: nil))
            }
            if let items = Self.replayItems(finishedItems(output)) {
                events.append(.providerItems(dialect: OpenAIResponsesClient.dialect, items: items))
            }
            if let usage = usage(event["response"]?["usage"]) { events.append(.usage(usage)) }
            events.append(.finished(emittedCallIDs.isEmpty ? .stop : .toolCalls))
            return events

        case "response.incomplete":
            isFinished = true
            var events: [ChatEvent] = []
            if let usage = usage(event["response"]?["usage"]) { events.append(.usage(usage)) }
            let reason: FinishReason = switch event["response"]?["incomplete_details"]?["reason"]?.stringValue {
            case "max_output_tokens": .length
            case "content_filter": .contentFilter
            default: .other
            }
            events.append(.finished(reason))
            return events

        case "response.failed":
            let error = event["response"]?["error"]
            throw ProviderError(provider: provider, message: Self.describe(error) ?? "The response failed.")

        case "error":
            // The streaming reference documents a flat event (`code`, `message`, `param` at the top level); the
            // WebSocket-mode guide documents `status` plus a nested `error` object. Both are accepted.
            let nested = event["error"]
            let message = Self.describe(event) ?? Self.describe(nested) ?? "The stream reported an error."
            throw ProviderError(provider: provider, status: Self.int(event["status"]), message: message)

        default:
            return []
        }
    }

    /// The response's output items in order. `response.completed` lists them; where an `output_item.done` event
    /// carried the same item (same index, type and id), that copy is used, since it is the item as finished (with
    /// `encrypted_content`) even when a server abbreviates the final list. With no list, the done items are used.
    private func finishedItems(_ output: [JSONValue]) -> [JSONValue] {
        guard !output.isEmpty else { return doneItems.sorted { $0.key < $1.key }.map(\.value) }
        return output.enumerated().map { index, item in
            guard let done = doneItems[index], done["type"] == item["type"], done["id"] == item["id"] else { return item }
            return done
        }
    }

    /// The output items worth replaying, or nil when rebuilding the reply from its text and tool calls loses
    /// nothing (no encrypted reasoning, no phases). Reasoning items without `encrypted_content` are left out: a
    /// stateless request cannot look them up by id, and the API rejects them.
    static func replayItems(_ output: [JSONValue]) -> [JSONValue]? {
        let items = output.filter { item in
            guard item["type"]?.stringValue == "reasoning" else { return true }
            return !(item["encrypted_content"]?.stringValue ?? "").isEmpty
        }
        let worthKeeping = items.contains { item in
            switch item["type"]?.stringValue {
            case "reasoning": true
            case "message": item["phase"]?.stringValue != nil
            default: false
            }
        }
        return worthKeeping ? items : nil
    }

    /// The text and tool calls a stream of these items decodes to, the way `ChatReply` collects them: every
    /// `output_text` and `refusal` part in order, and each function call (call id, name, arguments).
    static func visibleContent(of items: [JSONValue]) -> (text: String, toolCalls: [ToolCall]) {
        var text = ""
        var calls: [ToolCall] = []
        for item in items {
            switch item["type"]?.stringValue {
            case "message":
                for part in item["content"]?.arrayValue ?? [] {
                    switch part["type"]?.stringValue {
                    case "output_text": text += part["text"]?.stringValue ?? ""
                    case "refusal": text += part["refusal"]?.stringValue ?? ""
                    default: break
                    }
                }
            case "function_call":
                calls.append(ToolCall(id: item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "",
                                      name: item["name"]?.stringValue ?? "",
                                      arguments: item["arguments"]?.stringValue ?? ""))
            default:
                break
            }
        }
        return (text, calls)
    }

    /// Re-words an HTTP error from `checkedStream` using the error body's message, keeping the status. OpenAI sends
    /// `{"error": {"message": …}}`; `/responses`-compatible servers also send `{"error": "…"}` or a top-level
    /// `message`, which are accepted too. Bodies with none of these (a proxy's HTML page) are kept as they are.
    static func refineHTTPError(_ error: ProviderError) -> ProviderError {
        guard let body = try? JSONValue.parse(error.message),
              let message = describe(body["error"]) ?? body["error"]?.stringValue.flatMap(nonEmptyText) ?? describe(body)
        else { return error }
        return ProviderError(provider: error.provider, status: error.status, message: message)
    }

    /// `message`, prefixed with `code` when there is one, from an error object.
    private static func describe(_ error: JSONValue?) -> String? {
        guard let message = error?["message"]?.stringValue, !message.isEmpty else { return nil }
        if let code = error?["code"]?.stringValue, !code.isEmpty { return "\(message) (\(code))" }
        return message
    }

    private func callIndex(_ event: JSONValue) -> Int? {
        if let itemID = event["item_id"]?.stringValue, let index = indexByItemID[itemID] { return index }
        if let index = Self.int(event["output_index"]), calls[index] != nil { return index }
        return nil
    }

    /// An integer from untrusted JSON: nil, rather than a trap, for fractions and values outside `Int`'s range.
    private static func int(_ value: JSONValue?) -> Int? {
        value?.doubleValue.flatMap { Int(exactly: $0) }
    }

    /// A finished function-call item, preferring its own fields over what was streamed.
    private func functionCall(_ item: JSONValue, streamed: PendingCall?) -> PendingCall {
        PendingCall(callID: item["call_id"]?.stringValue ?? streamed?.callID ?? item["id"]?.stringValue ?? "",
                    name: item["name"]?.stringValue ?? streamed?.name ?? "",
                    arguments: item["arguments"]?.stringValue ?? streamed?.arguments ?? "")
    }

    private mutating func emit(_ call: PendingCall) -> [ChatEvent] {
        guard !call.name.isEmpty, emittedCallIDs.insert(call.callID).inserted else { return [] }
        return [.toolCall(ToolCall(id: call.callID, name: call.name, arguments: call.arguments))]
    }

    /// `input_tokens` includes the cached ones, as OpenAI reports it; `cachedInputTokens` is the cached share.
    private func usage(_ usage: JSONValue?) -> TokenUsage? {
        guard let usage, usage.objectValue != nil else { return nil }
        return TokenUsage(inputTokens: Self.int(usage["input_tokens"]) ?? 0,
                          cachedInputTokens: Self.int(usage["input_tokens_details"]?["cached_tokens"]) ?? 0,
                          outputTokens: Self.int(usage["output_tokens"]) ?? 0)
    }

    private func nonEmpty(_ text: String?) -> String? { Self.nonEmptyText(text) }

    private static func nonEmptyText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
