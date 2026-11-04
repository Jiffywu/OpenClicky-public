import Foundation
import Testing
@testable import OpenClickyKit

/// Reasoning and thinking round-trip through `ChatMessage.providerItems`, tagged by dialect.
@Suite struct ProviderItemsTests {
    // MARK: - OpenAI Responses

    static func sse(_ payloads: [JSONValue]) -> String {
        payloads.map { "event: \($0["type"]?.stringValue ?? "")\ndata: \($0.jsonString())\n\n" }.joined()
    }

    static let reasoning: JSONValue = ["id": "rs_1", "type": "reasoning", "summary": [], "encrypted_content": "gAAA-encrypted-1"]
    static let preamble: JSONValue = ["id": "msg_1", "type": "message", "role": "assistant", "status": "completed", "phase": "commentary",
                                      "content": [["type": "output_text", "text": "Let me look.", "annotations": []]]]
    static let call: JSONValue = ["id": "fc_1", "type": "function_call", "call_id": "call_1", "name": "point_at",
                                  "arguments": #"{"x":1}"#, "status": "completed"]

    /// A reasoning item, a commentary preamble and a function call, as a stateless reasoning model streams them.
    static let phasedToolStream = sse([
        ["type": "response.output_item.added", "output_index": 0, "item": ["id": "rs_1", "type": "reasoning", "summary": []]],
        ["type": "response.output_item.done", "output_index": 0, "item": reasoning],
        ["type": "response.output_item.added", "output_index": 1,
         "item": ["id": "msg_1", "type": "message", "role": "assistant", "status": "in_progress", "phase": "commentary", "content": []]],
        ["type": "response.output_text.delta", "item_id": "msg_1", "output_index": 1, "content_index": 0, "delta": "Let me look."],
        ["type": "response.output_item.done", "output_index": 1, "item": preamble],
        ["type": "response.output_item.added", "output_index": 2,
         "item": ["id": "fc_1", "type": "function_call", "call_id": "call_1", "name": "point_at", "arguments": ""]],
        ["type": "response.function_call_arguments.delta", "item_id": "fc_1", "output_index": 2, "delta": #"{"x":1}"#],
        ["type": "response.function_call_arguments.done", "item_id": "fc_1", "output_index": 2, "arguments": #"{"x":1}"#],
        ["type": "response.output_item.done", "output_index": 2, "item": call],
        ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "output": [reasoning, preamble, call],
                                                    "usage": ["input_tokens": 10, "output_tokens": 5]]],
    ])

    static let plainTextStream = sse([
        ["type": "response.output_text.delta", "item_id": "msg_2", "output_index": 0, "content_index": 0, "delta": "Done."],
        ["type": "response.completed", "response": ["id": "resp_2", "status": "completed", "output": [
            ["id": "msg_2", "type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]],
        ]]],
    ])

    static func openAI(_ transport: any HTTPTransport, baseURL: String? = nil, include: Bool? = nil) -> OpenAIResponsesClient {
        OpenAIResponsesClient(context: ProviderContext(
            provider: ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: baseURL.flatMap(URL.init(string:)), credential: "openai"),
            apiKey: "sk-test", http: transport), includeEncryptedReasoning: include)
    }

    @Test func responsesEmitsEncryptedReasoningAndPhasedItemsAtTheEnd() async throws {
        let client = Self.openAI(FakeHTTPTransport([.sse(Self.phasedToolStream, chunkSize: 13)]))
        var events: [ChatEvent] = []
        for try await event in client.stream(ChatRequest(model: "gpt-6.1-sol", messages: [.user(.text("Point"))], reasoningEffort: "medium")) {
            events.append(event)
        }
        #expect(Array(events.suffix(3)) == [
            .providerItems(dialect: "openai-responses", items: [Self.reasoning, Self.preamble, Self.call]),
            .usage(TokenUsage(inputTokens: 10, outputTokens: 5)),
            .finished(.toolCalls),
        ])
    }

    @Test func responsesReplaysItemsVerbatimForTheNextTurn() async throws {
        let fake = FakeHTTPTransport([.sse(Self.phasedToolStream), .sse(Self.plainTextStream)])
        let client = Self.openAI(fake)
        let question = ChatMessage.user(.text("Point at it"))
        let reply = try await client.completeReply(ChatRequest(model: "gpt-6.1-sol", messages: [question], reasoningEffort: "medium"))
        #expect(reply.phase == "commentary")
        #expect(reply.text == "Let me look.")

        _ = try await client.complete(ChatRequest(model: "gpt-6.1-sol", messages: [
            question, reply.message, .tool(callID: "call_1", result: "pointed"),
        ], reasoningEffort: "medium"))
        let body = try fake.jsonBody(1)
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["input"]?.arrayValue == [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Point at it"]]],
            Self.reasoning, Self.preamble, Self.call,
            ["type": "function_call_output", "call_id": "call_1", "output": "pointed"],
        ])
    }

    @Test func editedOrForeignMessagesAreRebuiltWithTheirPhase() throws {
        let items = [Self.reasoning, Self.preamble, Self.call]
        let toolCall = ToolCall(id: "call_1", name: "point_at", arguments: #"{"x":1}"#)
        let edited = ChatMessage.assistant("Let me look again.", toolCalls: [toolCall], providerItems: items,
                                           providerDialect: "openai-responses", phase: "commentary")
        let foreign = ChatMessage.assistant("Let me look.", toolCalls: [toolCall], providerItems: items, providerDialect: "anthropic-messages")
        let client = Self.openAI(FakeHTTPTransport([]))
        for (message, phase) in [(edited, "commentary"), (foreign, nil)] as [(ChatMessage, String?)] {
            let request = client.makeURLRequest(ChatRequest(model: "gpt-6.1-sol", messages: [.user(.text("Hi")), message]))
            let body = try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            var assistant: JSONValue = ["type": "message", "role": "assistant", "content": .string(message.text)]
            if let phase { assistant = .object(assistant.objectValue!.merging(["phase": .string(phase)]) { $1 }) }
            // No reasoning item: the edited message no longer matches it, and the foreign one came from another dialect.
            #expect(body["input"]?.arrayValue?.dropFirst().map { $0 } == [
                assistant,
                ["type": "function_call", "call_id": "call_1", "name": "point_at", "arguments": #"{"x":1}"#],
            ])
        }
    }

    @Test func plainRepliesEmitNoProviderItems() async throws {
        let client = Self.openAI(FakeHTTPTransport([.sse(Self.plainTextStream)]))
        let reply = try await client.completeReply(ChatRequest(model: "gpt-6.1-sol", messages: [.user(.text("Hi"))]))
        #expect(reply.providerItems.isEmpty)
        #expect(reply.message == .assistant("Done."))
    }

    @Test func reasoningWithoutEncryptedContentIsNotReplayed() {
        let bare: JSONValue = ["id": "rs_x", "type": "reasoning", "summary": []]
        #expect(OpenAIResponsesEventDecoder.replayItems([bare, Self.call]) == nil)
        let phased = OpenAIResponsesEventDecoder.replayItems([bare, Self.preamble, Self.call])
        #expect(phased == [Self.preamble, Self.call])
    }

    @Test func includeIsSentToOpenAIForReasoningRequestsOnly() throws {
        func include(_ client: OpenAIResponsesClient, effort: String?) throws -> JSONValue? {
            let request = client.makeURLRequest(ChatRequest(model: "m", messages: [.user(.text("Hi"))], reasoningEffort: effort))
            return try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))["include"]
        }
        let fake = FakeHTTPTransport([])
        #expect(try include(Self.openAI(fake), effort: "low") == ["reasoning.encrypted_content"])
        #expect(try include(Self.openAI(fake), effort: nil) == nil)
        #expect(try include(Self.openAI(fake, baseURL: "https://api.openai.com/v1"), effort: "low") == ["reasoning.encrypted_content"])
        // Compatible servers may not know the value.
        #expect(try include(Self.openAI(fake, baseURL: "http://127.0.0.1:8000/v1"), effort: "low") == nil)
        #expect(try include(Self.openAI(fake, baseURL: "http://127.0.0.1:8000/v1", include: true), effort: nil) == ["reasoning.encrypted_content"])
        #expect(try include(Self.openAI(fake, include: false), effort: "high") == nil)
    }

    // MARK: - Anthropic Messages

    static func anthropic(_ transport: any HTTPTransport, replay: AnthropicThinkingReplay = AnthropicThinkingReplay()) -> AnthropicMessagesClient {
        AnthropicMessagesClient(context: ProviderContext(
            provider: ProviderConfig(id: "anthropic", dialect: .anthropicMessages, credential: "anthropic"), apiKey: "sk-ant-test", http: transport),
            thinkingReplay: replay)
    }

    static let pointAt = ToolSpec(name: "point_at", description: "Point", parameters: ["type": "object", "properties": ["x": ["type": "number"]]])

    static func thinkingTurn(signature: String, tool: String) -> String {
        sse([
            ["type": "message_start", "message": ["id": "msg", "type": "message", "role": "assistant", "content": [],
                                                  "usage": ["input_tokens": 10, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Where is it?"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": .string(signature)]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": .string(tool), "name": "point_at", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": #"{"x": 1}"#]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 9]],
            ["type": "message_stop"],
        ])
    }

    static func signatures(_ body: JSONValue) -> [String] {
        (body["messages"]?.arrayValue ?? []).flatMap { $0["content"]?.arrayValue ?? [] }
            .compactMap { $0["type"] == "thinking" ? $0["signature"]?.stringValue : nil }
    }

    @Test func anthropicThinkingSurvivesARestartThroughProviderItems() async throws {
        let first = Self.anthropic(FakeHTTPTransport([.sse(Self.thinkingTurn(signature: "sig-1", tool: "toolu_A"))]))
        let question = ChatMessage.user(.text("Point at the button"))
        let request = ChatRequest(model: "claude-opus-5-5", messages: [.system("You are Clicky."), question], tools: [Self.pointAt],
                                  reasoningEffort: "medium")
        let reply = try await first.completeReply(request)
        #expect(reply.providerDialect == "anthropic-messages")
        #expect(reply.providerItems.first?["signature"] == "sig-1")

        // A new client with an empty replay cache stands in for a restarted app.
        let fake = FakeHTTPTransport([.sse(Self.thinkingTurn(signature: "sig-2", tool: "toolu_B"))])
        let restarted = Self.anthropic(fake)
        var history = request.messages + [reply.message, .tool(callID: "toolu_A", result: "pointed")]
        _ = try await restarted.complete(ChatRequest(model: "claude-opus-5-5", messages: history, tools: [Self.pointAt], reasoningEffort: "medium"))
        let sent = try fake.jsonBody(0)
        #expect(Self.signatures(sent) == ["sig-1"])
        // The bookkeeping item never reaches the API.
        #expect(!sent.jsonString().contains(AnthropicThinkingReplay.replayKeyType))
        #expect(sent["messages"]?.arrayValue?[1] == ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "Where is it?", "signature": "sig-1"],
            ["type": "tool_use", "id": "toolu_A", "name": "point_at", "input": ["x": 1]],
        ]])

        // A changed system prompt invalidates the block, so it is left out rather than rejected by the API.
        history[0] = .system("You are Clicky. Be brief.")
        let changed = restarted.requestBody(ChatRequest(model: "claude-opus-5-5", messages: history, tools: [Self.pointAt]))
        #expect(Self.signatures(changed) == [])
    }

    @Test func anthropicIgnoresItemsFromAnotherDialectAndEditedTurns() throws {
        let client = Self.anthropic(FakeHTTPTransport([]))
        let items: [JSONValue] = [["type": "thinking", "thinking": "t", "signature": "sig-x"],
                                  ["type": "tool_use", "id": "toolu_A", "name": "point_at", "input": ["x": 1]]]
        let call = ToolCall(id: "toolu_A", name: "point_at", arguments: #"{"x": 1}"#)
        for message in [ChatMessage.assistant("", toolCalls: [call], providerItems: items, providerDialect: "openai-responses"),
                        // Right dialect, but no key item: not a reply this adapter recorded.
                        ChatMessage.assistant("", toolCalls: [call], providerItems: items, providerDialect: "anthropic-messages")] {
            let body = client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: [.user(.text("Hi")), message]))
            #expect(Self.signatures(body) == [])
        }
    }

    @Test func anthropicSendsToolErrors() throws {
        let client = Self.anthropic(FakeHTTPTransport([]))
        let body = client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: [
            .user(.text("Click it")),
            .assistant("", toolCalls: [ToolCall(id: "toolu_A", name: "click", arguments: "{}")]),
            .tool(callID: "toolu_A", result: "No such button", isError: true),
        ]))
        #expect(body["messages"]?.arrayValue?.last == ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_A", "content": "No such button", "is_error": true],
        ]])
    }
}
