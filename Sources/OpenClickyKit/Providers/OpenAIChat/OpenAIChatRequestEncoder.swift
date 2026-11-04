import Foundation

/// Builds the Chat Completions request body. Field names follow the OpenAI reference cited in OpenAIChatClient.swift.
enum OpenAIChatRequestEncoder {
    static func body(for request: ChatRequest, maxTokensParameter: OpenAIChatClient.MaxTokensParameter) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages(request.messages)),
            "stream": true,
            // Asks for a final chunk with `usage` and empty `choices` before `[DONE]`.
            "stream_options": ["include_usage": true],
        ]
        if !request.tools.isEmpty { body["tools"] = .array(request.tools.map(tool)) }
        if let effort = request.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        if let maxTokens = request.maxOutputTokens { body[maxTokensParameter.rawValue] = .number(Double(maxTokens)) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        return .object(body)
    }

    static func tool(_ spec: ToolSpec) -> JSONValue {
        ["type": "function", "function": ["name": .string(spec.name), "description": .string(spec.description), "parameters": spec.parameters]]
    }

    /// Maps the conversation. `system` is used rather than `developer`: OpenAI accepts both, and most compatible
    /// servers know only `system`.
    ///
    /// Tool messages can carry only text on this wire format. Images a tool returned (a screenshot, say) are moved
    /// into one user message placed straight after the run of tool messages, because tool results must directly
    /// follow the assistant message that called them.
    static func messages(_ messages: [ChatMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        var toolImages: [JSONValue] = []

        func flushToolImages() {
            guard !toolImages.isEmpty else { return }
            out.append(["role": "user", "content": .array(toolImages)])
            toolImages = []
        }

        for message in messages {
            if message.role != .tool { flushToolImages() }
            switch message.role {
            case .system:
                out.append(["role": "system", "content": .string(message.text)])
            case .user:
                out.append(["role": "user", "content": content(message.content)])
            case .assistant:
                var object: [String: JSONValue] = ["role": "assistant"]
                let text = message.text
                if message.toolCalls.isEmpty {
                    object["content"] = .string(text)
                } else {
                    // `content` may be null when `tool_calls` is present.
                    object["content"] = text.isEmpty ? .null : .string(text)
                    object["tool_calls"] = .array(message.toolCalls.map(toolCall))
                }
                out.append(.object(object))
            case .tool:
                let callID = message.toolCallID ?? ""
                let images = message.content.compactMap(imagePart)
                var text = message.text
                if !images.isEmpty {
                    if text.isEmpty { text = "The result is an image, attached in the next message." }
                    toolImages.append(["type": "text", "text": .string("Image returned by tool call \(callID):")])
                    toolImages += images
                }
                out.append(["role": "tool", "tool_call_id": .string(callID), "content": .string(text)])
            }
        }
        flushToolImages()
        return out
    }

    /// Plain text goes as a string, which every compatible server accepts; mixed content as a parts array.
    static func content(_ parts: [ContentPart]) -> JSONValue {
        let hasImage = parts.contains { if case .image = $0 { true } else { false } }
        guard hasImage else {
            return .string(parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined())
        }
        return .array(parts.map { part in
            switch part {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .image(let data, let mimeType): imageURLPart(data: data, mimeType: mimeType)
            }
        })
    }

    static func imagePart(_ part: ContentPart) -> JSONValue? {
        if case .image(let data, let mimeType) = part { imageURLPart(data: data, mimeType: mimeType) } else { nil }
    }

    /// Inline images as base64 data URLs: the one image form OpenAI, Ollama, Gemini and OpenRouter all document.
    static func imageURLPart(data: Data, mimeType: String) -> JSONValue {
        ["type": "image_url", "image_url": ["url": .string("data:\(mimeType);base64,\(data.base64EncodedString())")]]
    }

    static func toolCall(_ call: ToolCall) -> JSONValue {
        ["id": .string(call.id), "type": "function", "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
    }
}
