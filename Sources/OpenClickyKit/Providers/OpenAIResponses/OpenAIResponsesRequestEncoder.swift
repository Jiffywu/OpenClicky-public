import Foundation

/// Builds the JSON body for `POST /responses` from a provider-neutral `ChatRequest`.
///
/// Message mapping (see the `input` parameter in the create-response reference):
/// - Leading text-only system messages are joined into `instructions`. A system message that comes later in the
///   conversation, or carries an image, becomes an input message with role `developer`.
/// - User messages become `{"type":"message","role":"user","content":[input_text | input_image]}`; images are
///   base64 `data:` URLs.
/// - An assistant message carrying this dialect's `providerItems` (encrypted reasoning, phased output messages) goes
///   back as those items, verbatim, when its text and tool calls still match them.
/// - Otherwise assistant text becomes an input message with role `assistant` and string content (the documented
///   `EasyInputMessage` form for earlier model output), with the message's `phase` when it has one; each tool call
///   becomes a `function_call` item.
/// - Tool results become `function_call_output` items. Text-only results are sent as a string; results with
///   images use the documented array form of `output`.
struct OpenAIResponsesRequestEncoder: Sendable {
    var options: OpenAIResponsesClient.Options

    func body(for request: ChatRequest) -> JSONValue {
        var instructions: [String] = []
        var input: [JSONValue] = []
        var inPreamble = true

        for message in request.messages {
            switch message.role {
            case .system:
                if inPreamble, message.content.allSatisfy(\.isText) {
                    if !message.text.isEmpty { instructions.append(message.text) }
                } else {
                    input.append(["type": "message", "role": "developer", "content": .array(message.content.map(inputContent))])
                }
            case .user:
                inPreamble = false
                input.append(["type": "message", "role": "user", "content": .array(message.content.map(inputContent))])
            case .assistant:
                inPreamble = false
                if let items = replayableItems(message) {
                    input += items
                    continue
                }
                // Assistant turns can only carry text back; there is no assistant-side image input.
                if !message.text.isEmpty {
                    var item: [String: JSONValue] = ["type": "message", "role": "assistant", "content": .string(message.text)]
                    if let phase = message.phase, !phase.isEmpty { item["phase"] = .string(phase) }
                    input.append(.object(item))
                }
                for call in message.toolCalls {
                    input.append(["type": "function_call", "call_id": .string(call.id), "name": .string(call.name),
                                  "arguments": .string(call.arguments)])
                }
            case .tool:
                inPreamble = false
                var item: [String: JSONValue] = ["type": "function_call_output", "output": toolOutput(message.content)]
                if let callID = message.toolCallID { item["call_id"] = .string(callID) }
                input.append(.object(item))
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(input),
            "stream": true,
            "store": false,
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions.joined(separator: "\n\n")) }
        if options.includesEncryptedReasoning(for: request) { body["include"] = ["reasoning.encrypted_content"] }
        // Hosted tools (web search) go after the function tools, as given.
        let tools = request.tools.map(functionTool) + request.hostedTools
        if !tools.isEmpty { body["tools"] = .array(tools) }

        var reasoning: [String: JSONValue] = [:]
        if let effort = request.reasoningEffort { reasoning["effort"] = .string(effort) }
        if let summary = options.reasoningSummary { reasoning["summary"] = .string(summary) }
        if !reasoning.isEmpty { body["reasoning"] = .object(reasoning) }

        if let maxOutputTokens = request.maxOutputTokens { body["max_output_tokens"] = .number(Double(maxOutputTokens)) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        return .object(body)
    }

    /// This dialect's provider items for an assistant message, if they still describe it: the text and tool calls
    /// they decode to are the message's own. Nil for edited messages and messages from other adapters.
    private func replayableItems(_ message: ChatMessage) -> [JSONValue]? {
        let items = message.providerItems(for: OpenAIResponsesClient.dialect)
        guard !items.isEmpty else { return nil }
        let visible = OpenAIResponsesEventDecoder.visibleContent(of: items)
        guard visible.text == message.text, visible.toolCalls == message.toolCalls else { return nil }
        return items
    }

    private func inputContent(_ part: ContentPart) -> JSONValue {
        switch part {
        case .text(let text):
            return ["type": "input_text", "text": .string(text)]
        case .image(let data, let mimeType):
            return ["type": "input_image", "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
                    "detail": .string(options.imageDetail)]
        }
    }

    private func toolOutput(_ content: [ContentPart]) -> JSONValue {
        if content.allSatisfy(\.isText) {
            return .string(content.compactMap(\.textValue).joined())
        }
        return .array(content.map(inputContent))
    }

    private func functionTool(_ tool: ToolSpec) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": "function",
            "name": .string(tool.name),
            "parameters": tool.parameters,
            "strict": .bool(options.strictTools),
        ]
        if !tool.description.isEmpty { object["description"] = .string(tool.description) }
        return .object(object)
    }
}

private extension ContentPart {
    var isText: Bool { if case .text = self { true } else { false } }
    var textValue: String? { if case .text(let text) = self { text } else { nil } }
}
