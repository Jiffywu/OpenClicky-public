import Foundation

/// Turns the `data:` payloads of a Chat Completions stream into `ChatEvent`s. Feed every payload to `consume`,
/// stop once `isDone`, then call `finish` for the completed tool calls and the finish reason.
struct OpenAIChatStreamDecoder {
    let provider: String
    /// True once the `[DONE]` terminator has arrived.
    private(set) var isDone = false
    private var finishReason: String?
    private var pendingCalls: [PendingToolCall] = []
    private var callsStarted = 0
    private var emittedToolCall = false
    /// The latest usage seen. Usage totals are cumulative, so only the last one is reported, once, at the end.
    private var usage: TokenUsage?

    private struct PendingToolCall {
        /// `index` as the server sent it; nil when it sent none.
        var index: Int?
        /// Arrival order in this reply. Orders the finished calls and names calls that came without an id.
        var ordinal: Int
        /// The id the server sent, or "".
        var id = ""
        /// The id used in events, fixed the first time one is needed.
        var eventID: String?
        var name = ""
        var arguments = ""
    }

    init(provider: String) { self.provider = provider }

    mutating func consume(_ data: String) throws -> [ChatEvent] {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[DONE]" {
            isDone = true
            return []
        }
        if trimmed.isEmpty { return [] }
        let chunk: JSONValue
        do {
            chunk = try JSONValue.parse(trimmed)
        } catch {
            throw ProviderError(provider: provider, message: "Unreadable stream chunk: \(trimmed.prefix(200))")
        }
        if let error = streamError(in: chunk) { throw error }

        var events: [ChatEvent] = []
        // We never ask for `n` > 1, so only choice 0 matters.
        for choice in chunk["choices"]?.arrayValue ?? [] where (int(choice["index"]) ?? 0) == 0 {
            events += try consume(choice: choice)
        }
        // `usage` is null on every chunk but the last when `include_usage` is set. OpenAI sends that last chunk with
        // no choices; OpenRouter repeats the finish reason in it. `finish` reports it.
        if let usage = chunk["usage"], case .object = usage {
            self.usage = tokenUsage(usage)
        }
        return events
    }

    /// Call when the stream ends. Throws when it ended before either `[DONE]` or a finish reason arrived, which
    /// means the connection dropped mid-reply.
    mutating func finish() throws -> [ChatEvent] {
        guard isDone || finishReason != nil else {
            throw ProviderError(provider: provider, message: "The stream ended before the model finished its reply.")
        }
        var events = flushToolCalls()
        if let usage { events.append(.usage(usage)) }
        events.append(.finished(mappedFinishReason()))
        return events
    }

    // MARK: - Choices

    private mutating func consume(choice: JSONValue) throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        if let delta = choice["delta"], case .object = delta {
            if let reasoning = reasoningText(in: delta) { events.append(.reasoningDelta(reasoning)) }
            if let text = delta["content"]?.stringValue, !text.isEmpty { events.append(.textDelta(text)) }
            // A refusal is what the model says instead of answering, so it is passed on as text.
            if let refusal = delta["refusal"]?.stringValue, !refusal.isEmpty { events.append(.textDelta(refusal)) }
            for call in delta["tool_calls"]?.arrayValue ?? [] { events += absorb(toolCall: call) }
        }
        if let reason = choice["finish_reason"]?.stringValue, !reason.isEmpty {
            // OpenRouter pairs `finish_reason: "error"` with an `error` object, which `streamError` already threw on.
            if reason == "error" { throw ProviderError(provider: provider, message: "The model stopped with an error.") }
            finishReason = reason
            // Every tool call is complete once the choice has a finish reason.
            events += flushToolCalls()
        }
        return events
    }

    /// Reasoning text from whichever field the server uses. vLLM, LM Studio (gpt-oss), Ollama and OpenRouter send
    /// `delta.reasoning`; DeepSeek, older vLLM and LM Studio's R1 mode send `delta.reasoning_content`; OpenRouter
    /// documents `delta.reasoning_details`. Some servers mirror the same text into more than one of these, so the
    /// first one present wins and the others are ignored rather than counted twice.
    private func reasoningText(in delta: JSONValue) -> String? {
        if let text = delta["reasoning"]?.stringValue, !text.isEmpty { return text }
        if let text = delta["reasoning_content"]?.stringValue, !text.isEmpty { return text }
        // `reasoning.text` carries `text`, `reasoning.summary` carries `summary`; `reasoning.encrypted` has no
        // readable text.
        let details = (delta["reasoning_details"]?.arrayValue ?? []).compactMap { detail -> String? in
            switch detail["type"]?.stringValue {
            case "reasoning.text": detail["text"]?.stringValue
            case "reasoning.summary": detail["summary"]?.stringValue
            default: nil
            }
        }.joined()
        return details.isEmpty ? nil : details
    }

    // MARK: - Tool calls

    /// Assembles `delta.tool_calls`: OpenAI sends `id`, `type` and `function.name` in the first fragment of each
    /// `index` and `function.arguments` in pieces after it; Ollama and Gemini send each call whole in one fragment.
    private mutating func absorb(toolCall call: JSONValue) -> [ChatEvent] {
        let slot = slot(for: call)
        if let id = call["id"]?.stringValue, !id.isEmpty, pendingCalls[slot].id.isEmpty { pendingCalls[slot].id = id }
        let function = call["function"]
        // The name arrives whole; repeats of it in later fragments are not appended.
        if let name = function?["name"]?.stringValue, !name.isEmpty, pendingCalls[slot].name.isEmpty {
            pendingCalls[slot].name = name
        }
        let fragment: String
        switch function?["arguments"] {
        case .string(let text)?: fragment = text
        // Arguments are documented as JSON text; accept an already-decoded object too rather than drop the call.
        case let value? where value.objectValue != nil: fragment = value.jsonString()
        default: fragment = ""
        }
        guard !fragment.isEmpty else { return [] }
        pendingCalls[slot].arguments += fragment
        let id = resolvedID(slot)
        return [.toolCallDelta(id: id, name: pendingCalls[slot].name, argumentsFragment: fragment)]
    }

    /// Where a tool-call fragment belongs. OpenAI keys fragments by `index`, sending `id` and `function.name` only in
    /// the first fragment of each call. Two servers are reported to deviate, so this also checks `id` and `name`:
    /// - Ollama sends every parallel call with `index` 0, each with its own `id` (https://github.com/vercel/ai/pull/14277).
    ///   A fragment whose `id` differs from the one already held at that index starts a new call.
    /// - Gemini's compatibility layer sends whole calls with no `index` and an empty `id`
    ///   (https://discuss.ai.google.dev/t/gemini-openai-compatibility-issue-with-tool-call-streaming/59886). Without
    ///   an index, an `id` is matched first. A fragment with neither starts a new call when it names a function
    ///   and the latest call already has a name; otherwise it continues the latest call.
    private mutating func slot(for call: JSONValue) -> Int {
        let id = call["id"]?.stringValue ?? ""
        let name = call["function"]?["name"]?.stringValue ?? ""
        if let index = int(call["index"]) {
            if let slot = pendingCalls.lastIndex(where: { $0.index == index }),
               id.isEmpty || pendingCalls[slot].id.isEmpty || pendingCalls[slot].id == id {
                return slot
            }
            return startCall(index: index)
        }
        if !id.isEmpty {
            if let slot = pendingCalls.firstIndex(where: { $0.id == id }) { return slot }
            return startCall(index: nil)
        }
        if let latest = pendingCalls.indices.last, name.isEmpty || pendingCalls[latest].name.isEmpty { return latest }
        return startCall(index: nil)
    }

    private mutating func startCall(index: Int?) -> Int {
        pendingCalls.append(PendingToolCall(index: index, ordinal: callsStarted))
        callsStarted += 1
        return pendingCalls.count - 1
    }

    /// The call's id, synthesized once (and kept) for servers that send none, so deltas, the finished call and the
    /// tool result sent back later all agree.
    private mutating func resolvedID(_ slot: Int) -> String {
        if let id = pendingCalls[slot].eventID { return id }
        let id = pendingCalls[slot].id.isEmpty ? "call_\(pendingCalls[slot].ordinal)" : pendingCalls[slot].id
        pendingCalls[slot].eventID = id
        return id
    }

    /// Every pending call, in the order the calls started.
    private mutating func flushToolCalls() -> [ChatEvent] {
        guard !pendingCalls.isEmpty else { return [] }
        var events: [ChatEvent] = []
        for slot in pendingCalls.indices {
            let id = resolvedID(slot)
            let call = pendingCalls[slot]
            // A call without parameters can arrive with no argument text at all; "{}" keeps it valid JSON.
            events.append(.toolCall(ToolCall(id: id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments)))
        }
        pendingCalls.removeAll()
        emittedToolCall = true
        return events
    }

    // MARK: - Finish, usage, errors

    private func mappedFinishReason() -> FinishReason {
        switch finishReason {
        case "tool_calls", "function_call": return .toolCalls
        case "length": return .length
        case "content_filter": return .contentFilter
        // Some compatible servers report `stop` even when the reply is tool calls; `[DONE]` with no finish reason
        // at all is treated as a normal end.
        case "stop", nil: return emittedToolCall ? .toolCalls : .stop
        default: return .other
        }
    }

    private func tokenUsage(_ usage: JSONValue) -> TokenUsage {
        TokenUsage(
            inputTokens: int(usage["prompt_tokens"]) ?? 0,
            cachedInputTokens: int(usage["prompt_tokens_details"]?["cached_tokens"]) ?? 0,
            outputTokens: int(usage["completion_tokens"]) ?? 0
        )
    }

    /// An error object inside the stream: `{"error":{"message":…,"code":…}}` (OpenAI SDK, OpenRouter, vLLM),
    /// `{"error":"…"}`, or vLLM's older top-level `{"object":"error","message":…,"code":…}`. A numeric `code`
    /// is an HTTP-style status on OpenRouter and vLLM, so it becomes `status`.
    private func streamError(in chunk: JSONValue) -> ProviderError? {
        let fallback = "The provider reported an error during streaming."
        switch chunk["error"] {
        case .object(let error)? where !error.isEmpty:
            let message = error["message"]?.stringValue ?? fallback
            return ProviderError(provider: provider, status: int(error["code"]), message: message.isEmpty ? fallback : message)
        case .string(let message)? where !message.isEmpty:
            return ProviderError(provider: provider, message: message)
        default:
            break
        }
        if chunk["object"]?.stringValue == "error" {
            let message = chunk["message"]?.stringValue ?? fallback
            return ProviderError(provider: provider, status: int(chunk["code"]), message: message.isEmpty ? fallback : message)
        }
        return nil
    }

    /// An integral JSON number, or nil. Unlike `JSONValue.intValue` this never traps on a huge or fractional value
    /// from a misbehaving server.
    private func int(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue else { return nil }
        return Int(exactly: number)
    }
}
