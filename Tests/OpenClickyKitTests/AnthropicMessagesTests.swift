import Foundation
import Testing
@testable import OpenClickyKit

/// Payloads are copied from, or shaped exactly like, the examples in
/// https://platform.claude.com/docs/en/build-with-claude/streaming and https://platform.claude.com/docs/en/api/errors .
@Suite struct AnthropicMessagesTests {
    /// Not a real credential. Tests compare against it but never print it.
    static let fakeKey = "sk-ant-test-0000-not-a-real-key"

    static let basicStream = #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

    event: content_block_start
    data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello"}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "! Grüße 👋"}}

    event: content_block_stop
    data: {"type": "content_block_stop", "index": 0}

    event: message_delta
    data: {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence":null}, "usage": {"output_tokens": 15}}

    event: message_stop
    data: {"type": "message_stop"}


    """#

    static let toolUseStream = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_014p7gG3wDgGV9EUtLvnow3U","type":"message","role":"assistant","model":"claude-opus-5","stop_sequence":null,"usage":{"input_tokens":472,"output_tokens":2},"content":[],"stop_reason":null}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type": "ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Okay"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", let's check the weather for San Francisco, CA:"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \"San"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" Francisc"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"o,"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" CA\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89}}

    event: message_stop
    data: {"type":"message_stop"}


    """#

    /// A thinking block followed by a tool call, as Claude 5 models stream it with `display: "summarized"`.
    static let thinkingToolStream = #"""
    event: message_start
    data: {"type": "message_start", "message": {"id": "msg_01...", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 120, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 2048, "output_tokens": 1}}}

    event: content_block_start
    data: {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "The user wants the weather."}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "\nI should call get_weather."}}

    event: content_block_delta
    data: {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."}}

    event: content_block_stop
    data: {"type": "content_block_stop", "index": 0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01T1x1fJ34qAmk2tNTrN7Up6","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\": \"Paris\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":64}}

    event: message_stop
    data: {"type":"message_stop"}


    """#

    static let signature = "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds..."

    static func provider(baseURL: String? = nil, headers: [String: String]? = nil) -> ProviderConfig {
        ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: baseURL.flatMap(URL.init(string:)),
                       credential: "anthropic", headers: headers)
    }

    static func client(_ transport: any HTTPTransport, baseURL: String? = nil, headers: [String: String]? = nil,
                       apiKey: String? = fakeKey, replay: AnthropicThinkingReplay = AnthropicThinkingReplay()) -> AnthropicMessagesClient {
        AnthropicMessagesClient(context: ProviderContext(provider: provider(baseURL: baseURL, headers: headers), apiKey: apiKey,
                                                         http: transport),
                                thinkingReplay: replay)
    }

    static func collect(_ client: AnthropicMessagesClient, _ request: ChatRequest) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in client.stream(request) { events.append(event) }
        return events
    }

    static let hello = ChatRequest(model: "claude-opus-5-5", messages: [.user(.text("Hello"))])

    // MARK: - Streaming

    @Test(arguments: [1, 3, 7, 64, 4096])
    func streamsTextUsageAndStopAtAnyChunkBoundary(chunkSize: Int) async throws {
        let fake = FakeHTTPTransport([.sse(Self.basicStream, chunkSize: chunkSize)])
        let events = try await Self.collect(Self.client(fake), Self.hello)
        #expect(events == [
            .textDelta("Hello"),
            .textDelta("! Grüße 👋"),
            .usage(TokenUsage(inputTokens: 25, cachedInputTokens: 0, outputTokens: 15)),
            .finished(.stop),
        ])
    }

    @Test(arguments: [1, 5, 37])
    func streamsToolCallFragmentsThenTheCompleteCall(chunkSize: Int) async throws {
        let fake = FakeHTTPTransport([.sse(Self.toolUseStream, chunkSize: chunkSize)])
        let events = try await Self.collect(Self.client(fake), Self.hello)

        let text = events.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined()
        #expect(text == "Okay, let's check the weather for San Francisco, CA:")
        let fragments = events.compactMap { event -> String? in
            guard case .toolCallDelta(let id, let name, let fragment) = event else { return nil }
            #expect(id == "toolu_01T1x1fJ34qAmk2tNTrN7Up6")
            #expect(name == "get_weather")
            return fragment
        }
        #expect(fragments == [#"{"location":"#, #" "San"#, " Francisc", "o,", #" CA"}"#])
        #expect(Array(events.suffix(3)) == [
            .toolCall(ToolCall(id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather",
                               arguments: #"{"location": "San Francisco, CA"}"#)),
            .usage(TokenUsage(inputTokens: 472, cachedInputTokens: 0, outputTokens: 89)),
            .finished(.toolCalls),
        ])
    }

    @Test func streamsReasoningAndCountsCachedInput() async throws {
        let fake = FakeHTTPTransport([.sse(Self.thinkingToolStream, chunkSize: 11)])
        let events = try await Self.collect(Self.client(fake), Self.hello)
        #expect(events.compactMap { if case .reasoningDelta(let t) = $0 { t } else { nil } }
                == ["The user wants the weather.", "\nI should call get_weather."])
        // input_tokens excludes cache reads; the adapter reports the whole prompt with reads as the cached part.
        #expect(events.contains(.usage(TokenUsage(inputTokens: 2168, cachedInputTokens: 2048, outputTokens: 64))))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func toolWithoutParametersYieldsEmptyObjectArguments() async throws {
        let body = #"""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_02","name":"take_screenshot","input":{}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":12}}

        event: message_stop
        data: {"type":"message_stop"}

        """#
        let result = try await Self.client(FakeHTTPTransport([.sse(body)])).complete(Self.hello)
        #expect(result.toolCalls == [ToolCall(id: "toolu_02", name: "take_screenshot", arguments: "{}")])
    }

    @Test func ignoresUnknownEventsAndServerToolBlocks() async throws {
        let body = #"""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2679,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}

        event: some_future_event
        data: {"type":"some_future_event","detail":{"x":1}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_014hJH82Qum7Td6UV8gDXThB","name":"web_search","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"weather\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location"}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Sunny."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"input_tokens":10682,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":510,"server_tool_use":{"web_search_requests":1}}}

        event: message_stop
        data: {"type":"message_stop"}

        """#
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body, chunkSize: 4)])), Self.hello)
        #expect(events == [
            .textDelta("Sunny."),
            .usage(TokenUsage(inputTokens: 10682, cachedInputTokens: 0, outputTokens: 510)),
            .finished(.length),
        ])
    }

    @Test(arguments: [
        ("end_turn", FinishReason.stop), ("stop_sequence", .stop), ("tool_use", .toolCalls), ("max_tokens", .length),
        ("model_context_window_exceeded", .length), ("refusal", .contentFilter), ("pause_turn", .other),
    ])
    func mapsEveryDocumentedStopReason(stopReason: String, expected: FinishReason) {
        #expect(AnthropicStreamDecoder.finishReason(stopReason) == expected)
    }

    // MARK: - Request encoding

    @Test func encodesRequestHeadersAndBody() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let schema: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                                 "required": ["x", "y"]]
        let request = ChatRequest(
            model: "claude-opus-5-5",
            messages: [
                .system("You are Clicky."),
                .user(.text("What is this?"), .image(data: png, mimeType: "image/png")),
                .system("Be brief."),
                .assistant("Let me point at it.", toolCalls: [
                    ToolCall(id: "toolu_01", name: "point_at", arguments: #"{"x": 10, "y": 20}"#),
                    ToolCall(id: "toolu_02", name: "point_at", arguments: #"{"x": 30, "y": 40}"#),
                ]),
                .tool(callID: "toolu_01", result: "pointed"),
                ChatMessage(role: .tool, content: [.text("screenshot"), .image(data: png, mimeType: "image/png")],
                            toolCallID: "toolu_02"),
                .user(.text("Thanks")),
            ],
            tools: [ToolSpec(name: "point_at", description: "Point at a spot on screen", parameters: schema)],
            reasoningEffort: "high",
            temperature: 0.2)
        let fake = FakeHTTPTransport([])
        let urlRequest = Self.client(fake).makeURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == Self.fakeKey)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)

        let bodyText = String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(!bodyText.contains(Self.fakeKey))
        let image: JSONValue = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw=="]]
        let expected: JSONValue = [
            "model": "claude-opus-5-5",
            "max_tokens": 64000,
            "stream": true,
            "system": "You are Clicky.\n\nBe brief.",
            "output_config": ["effort": "high"],
            "thinking": ["type": "adaptive", "display": "summarized"],
            "tools": [["name": "point_at", "description": "Point at a spot on screen", "input_schema": schema,
                       "eager_input_streaming": true]],
            "messages": [
                ["role": "user", "content": [["type": "text", "text": "What is this?"], image]],
                ["role": "assistant", "content": [
                    ["type": "text", "text": "Let me point at it."],
                    ["type": "tool_use", "id": "toolu_01", "name": "point_at", "input": ["x": 10, "y": 20]],
                    ["type": "tool_use", "id": "toolu_02", "name": "point_at", "input": ["x": 30, "y": 40]],
                ]],
                // Both results in one user message, results first, the follow-up text after them.
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_01", "content": "pointed"],
                    ["type": "tool_result", "tool_use_id": "toolu_02",
                     "content": [["type": "text", "text": "screenshot"], image]],
                    ["type": "text", "text": "Thanks"],
                ]],
            ],
        ]
        #expect(try JSONValue.parse(bodyText) == expected)
    }

    @Test func gatewayBaseURLOlderVersionAndKeylessRequest() throws {
        let request = ChatRequest(model: "claude-sonnet-5-5", messages: [.user(.text("Hi"))],
                                  tools: [ToolSpec(name: "noop", description: "Does nothing", parameters: .null)],
                                  maxOutputTokens: 1024, temperature: 0.3)
        let client = Self.client(FakeHTTPTransport([]), baseURL: "https://gateway.example.com/anthropic/",
                                 headers: ["anthropic-version": "2023-06-01", "X-Title": "OpenClicky"], apiKey: nil)
        let urlRequest = client.makeURLRequest(request)
        #expect(urlRequest.url?.absoluteString == "https://gateway.example.com/anthropic/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Title") == "OpenClicky")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(try JSONValue.parse(String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self)) == [
            "model": "claude-sonnet-5-5",
            "max_tokens": 1024,
            "stream": true,
            // 2023-06-01 still accepts temperature; no effort means no thinking or output_config.
            "temperature": 0.3,
            // Not Anthropic's own host, so no eager_input_streaming; a missing schema becomes an empty object schema.
            "tools": [["name": "noop", "description": "Does nothing", "input_schema": ["type": "object", "properties": [:]]]],
            "messages": [["role": "user", "content": [["type": "text", "text": "Hi"]]]],
        ])
    }

    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/v1/", "https://api.anthropic.com/v1/messages"),
        ("http://127.0.0.1:4000", "http://127.0.0.1:4000/v1/messages"),
    ])
    func buildsMessagesURL(baseURL: String, expected: String) {
        #expect(Self.client(FakeHTTPTransport([]), baseURL: baseURL).messagesURL.absoluteString == expected)
    }

    @Test func sendsRequestThroughTransport() async throws {
        let fake = FakeHTTPTransport([.sse(Self.basicStream)])
        _ = try await Self.client(fake).complete(Self.hello)
        #expect(fake.requests.count == 1)
        #expect(try fake.jsonBody(0)["stream"] == true)
        #expect(try fake.jsonBody(0)["messages"] == [["role": "user", "content": [["type": "text", "text": "Hello"]]]])
    }

    // MARK: - Thinking replay in the tool loop

    @Test func replaysThinkingBlocksUnchangedWithTheToolCallTheyPreceded() async throws {
        let fake = FakeHTTPTransport([.sse(Self.thinkingToolStream, chunkSize: 9), .sse(Self.basicStream)])
        let client = Self.client(fake)
        let question = ChatMessage.user(.text("Weather in Paris?"))
        let first = try await client.complete(ChatRequest(model: "claude-opus-5-5", messages: [question], reasoningEffort: "medium"))
        #expect(first.toolCalls == [ToolCall(id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather",
                                             arguments: #"{"location": "Paris"}"#)])

        _ = try await client.complete(ChatRequest(model: "claude-opus-5-5", messages: [
            question,
            .assistant(first.text, toolCalls: first.toolCalls),
            .tool(callID: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", result: "18°C and sunny"),
        ], reasoningEffort: "medium"))

        let messages = try fake.jsonBody(1)["messages"]?.arrayValue ?? []
        #expect(messages.count == 3)
        #expect(messages[1] == ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "The user wants the weather.\nI should call get_weather.", "signature": .string(Self.signature)],
            ["type": "tool_use", "id": "toolu_01T1x1fJ34qAmk2tNTrN7Up6", "name": "get_weather", "input": ["location": "Paris"]],
        ]])
        #expect(messages[2] == ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_01T1x1fJ34qAmk2tNTrN7Up6", "content": "18°C and sunny"],
        ]])
    }

    @Test func editedAssistantTurnIsSentWithoutThinking() async throws {
        let replay = AnthropicThinkingReplay()
        let fake = FakeHTTPTransport([.sse(Self.thinkingToolStream)])
        let client = Self.client(fake, replay: replay)
        _ = try await client.complete(Self.hello)
        #expect(replay.count == 1)

        let edited = ChatMessage.assistant("", toolCalls: [
            ToolCall(id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", name: "get_weather", arguments: #"{"location": "Lyon"}"#),
        ])
        let body = client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: [.user(.text("Hi")), edited]))
        #expect(body["messages"]?.arrayValue?[1] == ["role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_01T1x1fJ34qAmk2tNTrN7Up6", "name": "get_weather", "input": ["location": "Lyon"]],
        ]])
    }

    // MARK: - Preserved thinking (https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)
    //
    // On Claude Opus 5.5, Sonnet 5.5 and Haiku 5.5 the API checks every replayed thinking block against the `system`
    // prompt, the `tools` and every message before it, and the kept blocks must form an unbroken run of the original
    // sequence. Accounts created on or after 2026-08-31 get a 400 otherwise. These tests pin both rules.

    static let pointAt = ToolSpec(name: "point_at", description: "Point at a spot on screen",
                                  parameters: ["type": "object", "properties": ["x": ["type": "number"]]])

    static func sseEvent(_ payload: JSONValue) -> String {
        "event: \(payload["type"]?.stringValue ?? "")\ndata: \(payload.jsonString())\n\n"
    }

    /// One assistant turn as Claude 5 models stream it: a thinking block (empty text under `display: "omitted"`),
    /// then optional text, then an optional tool call.
    static func turnStream(signature: String, thinking: String = "", text: String? = nil,
                           tool: (id: String, input: String)? = nil) -> String {
        var events: [JSONValue] = [
            ["type": "message_start", "message": ["id": .string("msg_" + signature), "type": "message", "role": "assistant", "content": [],
                                                   "model": "claude-opus-5-5", "stop_reason": .null, "stop_sequence": .null,
                                                   "usage": ["input_tokens": 50, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": .string(thinking)]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": .string(signature)]],
            ["type": "content_block_stop", "index": 0],
        ]
        var index = 1
        if let text {
            events += [
                ["type": "content_block_start", "index": .number(Double(index)), "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "text_delta", "text": .string(text)]],
                ["type": "content_block_stop", "index": .number(Double(index))],
            ]
            index += 1
        }
        if let tool {
            events += [
                ["type": "content_block_start", "index": .number(Double(index)),
                 "content_block": ["type": "tool_use", "id": .string(tool.id), "name": "point_at", "input": [:]]],
                ["type": "content_block_delta", "index": .number(Double(index)),
                 "delta": ["type": "input_json_delta", "partial_json": .string(tool.input)]],
                ["type": "content_block_stop", "index": .number(Double(index))],
            ]
        }
        events += [
            ["type": "message_delta", "delta": ["stop_reason": tool == nil ? "end_turn" : "tool_use", "stop_sequence": .null],
             "usage": ["output_tokens": 30]],
            ["type": "message_stop"],
        ]
        return events.map(sseEvent).joined()
    }

    /// Signatures of the thinking blocks a request sends back, in order.
    static func thinkingSignatures(_ body: JSONValue) -> [String] {
        (body["messages"]?.arrayValue ?? []).flatMap { $0["content"]?.arrayValue ?? [] }
            .compactMap { $0["type"] == "thinking" ? $0["signature"]?.stringValue : nil }
    }

    /// Runs one turn of a tool loop the way an app would: send the history, append the reply as it came back.
    static func runTurn(_ client: AnthropicMessagesClient, _ history: inout [ChatMessage], tools: [ToolSpec] = [pointAt]) async throws {
        let reply = try await client.complete(ChatRequest(model: "claude-opus-5-5", messages: history, tools: tools,
                                                          reasoningEffort: "medium"))
        history.append(.assistant(reply.text, toolCalls: reply.toolCalls))
    }

    @Test func replaysEveryEarlierTurnsThinkingAsOneUnbrokenRun() async throws {
        let fake = FakeHTTPTransport([
            .sse(Self.turnStream(signature: "sig-1", thinking: "Find the button.", tool: ("toolu_A", #"{"x": 1}"#))),
            // A text-only turn under `display: "omitted"`: its thinking block has an empty `thinking` field.
            .sse(Self.turnStream(signature: "sig-2", text: "Done.")),
            .sse(Self.turnStream(signature: "sig-3", thinking: "Now the other one.", tool: ("toolu_B", #"{"x": 2}"#))),
            .sse(Self.basicStream),
        ])
        let client = Self.client(fake)
        var history: [ChatMessage] = [.system("You are Clicky."), .user(.text("Point at the button"))]
        try await Self.runTurn(client, &history)
        history.append(.tool(callID: "toolu_A", result: "pointed"))
        try await Self.runTurn(client, &history)
        history.append(.user(.text("And the other one?")))
        try await Self.runTurn(client, &history)
        history.append(.tool(callID: "toolu_B", result: "pointed"))
        try await Self.runTurn(client, &history)

        let sent = try (0..<4).map { Self.thinkingSignatures(try fake.jsonBody($0)) }
        // Leaving out the text-only turn's block while keeping sig-3 would break the run: a 400 on enforced accounts.
        #expect(sent == [[], ["sig-1"], ["sig-1", "sig-2"], ["sig-1", "sig-2", "sig-3"]])
        let messages = try fake.jsonBody(3)["messages"]?.arrayValue ?? []
        #expect(messages[3] == ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "", "signature": "sig-2"],
            ["type": "text", "text": "Done."],
        ]])
    }

    @Test func changedSystemPromptToolsOrEarlierMessageStopsReplay() async throws {
        let replay = AnthropicThinkingReplay()
        let client = Self.client(FakeHTTPTransport([.sse(Self.turnStream(signature: "sig-1", tool: ("toolu_A", #"{"x": 1}"#)))]),
                                 replay: replay)
        var history: [ChatMessage] = [.system("You are Clicky."), .user(.text("Point at the button"))]
        try await Self.runTurn(client, &history)
        history.append(.tool(callID: "toolu_A", result: "pointed"))

        func signatures(_ messages: [ChatMessage], tools: [ToolSpec] = [Self.pointAt]) -> [String] {
            Self.thinkingSignatures(client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: messages, tools: tools)))
        }
        #expect(signatures(history) == ["sig-1"])
        // Each of these changes something before the block, so the API would reject the block: send none.
        var newSystem = history
        newSystem[0] = .system("You are Clicky. Be brief.")
        #expect(signatures(newSystem) == [])
        #expect(signatures(history, tools: [Self.pointAt, ToolSpec(name: "click", description: "Click", parameters: [:])]) == [])
        var editedQuestion = history
        editedQuestion[1] = .user(.text("Point at the red button"))
        #expect(signatures(editedQuestion) == [])
        // A system message appended mid-conversation is hoisted into the top-level `system`, which also changes it.
        #expect(signatures(history + [.system("Be brief.")]) == [])
    }

    @Test func unknownEarlierTurnDropsTheThinkingBeforeItNotAfter() async throws {
        let fake = FakeHTTPTransport([
            .sse(Self.turnStream(signature: "sig-1", tool: ("toolu_A", #"{"x": 1}"#))),
            .sse(Self.turnStream(signature: "sig-3", tool: ("toolu_B", #"{"x": 2}"#))),
        ])
        let client = Self.client(fake)
        var history: [ChatMessage] = [.user(.text("Point at the button"))]
        try await Self.runTurn(client, &history)
        // A turn this adapter never saw (written by the app, or produced before a restart): its thinking, if it had
        // any, is gone, so sig-1 may only be sent if nothing after it is, and the newest reasoning matters most.
        history += [.tool(callID: "toolu_A", result: "pointed"), .assistant("Here it is."), .user(.text("And the other one?"))]
        try await Self.runTurn(client, &history)
        history.append(.tool(callID: "toolu_B", result: "pointed"))
        let body = client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: history, tools: [Self.pointAt]))

        #expect(Self.thinkingSignatures(try fake.jsonBody(1)) == [])
        #expect(Self.thinkingSignatures(body) == ["sig-3"])
        // The earlier turn goes back as it came, minus its thinking.
        #expect(body["messages"]?.arrayValue?[1] == ["role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_A", "name": "point_at", "input": ["x": 1]],
        ]])
    }

    @Test func replayEvictsOldestTurnsFirst() async throws {
        let fake = FakeHTTPTransport([
            .sse(Self.turnStream(signature: "sig-1", tool: ("toolu_A", #"{"x": 1}"#))),
            .sse(Self.turnStream(signature: "sig-2", tool: ("toolu_B", #"{"x": 2}"#))),
            .sse(Self.turnStream(signature: "sig-3", tool: ("toolu_C", #"{"x": 3}"#))),
        ])
        let replay = AnthropicThinkingReplay(capacity: 2)
        let client = Self.client(fake, replay: replay)
        var history: [ChatMessage] = [.user(.text("Point at three things"))]
        for id in ["toolu_A", "toolu_B", "toolu_C"] {
            try await Self.runTurn(client, &history)
            history.append(.tool(callID: id, result: "pointed"))
        }
        #expect(replay.count == 2)
        // Dropping the oldest block keeps an unbroken run, which the API accepts.
        let body = client.requestBody(ChatRequest(model: "claude-opus-5-5", messages: history, tools: [Self.pointAt]))
        #expect(Self.thinkingSignatures(body) == ["sig-2", "sig-3"])
    }

    // MARK: - Errors

    @Test func httpErrorCarriesStatusAndAPIMessage() async throws {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fy"}"#
        let client = Self.client(FakeHTTPTransport([.body(body, status: 401)]))
        let error = await #expect(throws: ProviderError.self) { _ = try await client.complete(Self.hello) }
        #expect(error?.provider == "anthropic")
        #expect(error?.status == 401)
        #expect(error?.message == "authentication_error: invalid x-api-key (request_id req_011CSHoEeqs5C35K2UUqR7Fy)")
    }

    @Test func nonJSONErrorBodyIsKeptAsText() async throws {
        let client = Self.client(FakeHTTPTransport([.body("<html>Bad gateway</html>", status: 502, contentType: "text/html")]))
        let error = await #expect(throws: ProviderError.self) { _ = try await client.complete(Self.hello) }
        #expect(error?.status == 502)
        #expect(error?.message == "<html>Bad gateway</html>")
    }

    @Test func midStreamErrorEventThrowsAfterEarlierDeltas() async throws {
        let body = #"""
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Partial"}}

        event: error
        data: {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}

        """#
        let client = Self.client(FakeHTTPTransport([.sse(body, chunkSize: 6)]))
        var received: [ChatEvent] = []
        let error = await #expect(throws: ProviderError.self) {
            for try await event in client.stream(Self.hello) { received.append(event) }
        }
        #expect(received == [.textDelta("Partial")])
        #expect(error?.status == 529)
        #expect(error?.message == "overloaded_error: Overloaded")
    }

    @Test func streamThatStopsBeforeMessageStopThrows() async throws {
        let truncated = Self.basicStream.components(separatedBy: "event: message_delta")[0]
        let client = Self.client(FakeHTTPTransport([.sse(truncated)]))
        let error = await #expect(throws: ProviderError.self) { _ = try await client.complete(Self.hello) }
        #expect(error?.message == "Stream ended before message_stop")
    }

    // MARK: - Cancellation

    @Test func cancellingTheConsumerCancelsTheNetworkStream() async throws {
        let firstChunk = #"""
        event: message_start
        data: {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [], "model": "claude-opus-5-5", "stop_reason": null, "stop_sequence": null, "usage": {"input_tokens": 25, "output_tokens": 1}}}

        event: content_block_start
        data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}

        event: content_block_delta
        data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hel"}}


        """#
        let transport = HangingTransport(firstChunk: firstChunk)
        let client = Self.client(transport)
        let (seen, seenContinuation) = AsyncStream<ChatEvent>.makeStream()
        let consumer = Task {
            for try await event in client.stream(Self.hello) { seenContinuation.yield(event) }
            seenContinuation.finish()
        }

        var iterator = seen.makeAsyncIterator()
        // The delta arrives while the body is still open: events are not held until the response ends.
        #expect(await iterator.next() == .textDelta("Hel"))
        #expect(!transport.wasTerminated)

        consumer.cancel()
        _ = await waitUntil { transport.wasTerminated }
        #expect(transport.wasTerminated)
        _ = await consumer.result
    }

    @Test func consumerThatStopsReadingTearsDownTheNetworkStream() async throws {
        let transport = HangingTransport(firstChunk: Self.basicStream.components(separatedBy: "event: content_block_stop")[0])
        let client = Self.client(transport)
        for try await event in client.stream(Self.hello) {
            #expect(event == .textDelta("Hello"))
            break
        }
        _ = await waitUntil { transport.wasTerminated }
        #expect(transport.wasTerminated)
    }

    @Test func cancellingBeforeResponseHeadersCancelsTheRequest() async throws {
        let transport = NoResponseTransport()
        let client = Self.client(transport)
        let consumer = Task { for try await _ in client.stream(Self.hello) {} }
        _ = await waitUntil { transport.didStart }
        #expect(transport.didStart)

        consumer.cancel()
        _ = await consumer.result
        #expect(transport.wasCancelled)
    }

    // MARK: - Adversarial chunking

    /// Thinking, then two parallel tool calls whose argument fragments split a `\u` escape and carry multi-byte
    /// UTF-8, delivered one byte at a time so every multi-byte character is split across network chunks.
    @Test func parallelToolCallsSurviveOneByteChunks() async throws {
        let fragmentsA = [#"{"label": "caf\u00"#, #"e9 \"au lait\" ☕️"#, #"", "x": 12.5}"#]
        let fragmentsB = ["", #"{"label": "日本語"#, #"", "x": -3}"#]
        var events: [JSONValue] = [
            ["type": "message_start", "message": ["id": "msg_p", "type": "message", "role": "assistant", "content": [],
                                                  "model": "claude-opus-5-5", "stop_reason": .null, "stop_sequence": .null,
                                                  "usage": ["input_tokens": 40, "cache_read_input_tokens": 1000, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Two spots — 🎯"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig-p"]],
            ["type": "content_block_stop", "index": 0],
        ]
        for (index, (id, fragments)) in [("toolu_P1", fragmentsA), ("toolu_P2", fragmentsB)].enumerated() {
            let blockIndex = JSONValue.number(Double(index + 1))
            events.append(["type": "content_block_start", "index": blockIndex,
                           "content_block": ["type": "tool_use", "id": .string(id), "name": "point_at", "input": [:]]])
            for fragment in fragments {
                events.append(["type": "content_block_delta", "index": blockIndex,
                               "delta": ["type": "input_json_delta", "partial_json": .string(fragment)]])
            }
            events.append(["type": "content_block_stop", "index": blockIndex])
        }
        events += [
            ["type": "message_delta", "delta": ["stop_reason": "tool_use", "stop_sequence": .null], "usage": ["output_tokens": 77]],
            ["type": "message_stop"],
        ]
        let body = events.map(Self.sseEvent).joined()
        let received = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body, chunkSize: 1)])), Self.hello)

        let argumentsA = #"{"label": "caf\u00e9 \"au lait\" ☕️", "x": 12.5}"#
        let argumentsB = #"{"label": "日本語", "x": -3}"#
        // A reply with thinking ends with its blocks as provider items, just before usage and finished.
        guard case .providerItems(let dialect, let items)? = received.dropLast(2).last else {
            Issue.record("expected provider items before usage")
            return
        }
        #expect(dialect == "anthropic-messages")
        #expect(items.first == ["type": "thinking", "thinking": "Two spots — 🎯", "signature": "sig-p"])
        #expect(items.last?["type"] == .string(AnthropicThinkingReplay.replayKeyType))
        // The argument text is passed through exactly as streamed (escapes included) for the caller to parse.
        #expect(received.filter { if case .providerItems = $0 { false } else { true } } == [
            .reasoningDelta("Two spots — 🎯"),
            .toolCallDelta(id: "toolu_P1", name: "point_at", argumentsFragment: fragmentsA[0]),
            .toolCallDelta(id: "toolu_P1", name: "point_at", argumentsFragment: fragmentsA[1]),
            .toolCallDelta(id: "toolu_P1", name: "point_at", argumentsFragment: fragmentsA[2]),
            .toolCall(ToolCall(id: "toolu_P1", name: "point_at", arguments: argumentsA)),
            .toolCallDelta(id: "toolu_P2", name: "point_at", argumentsFragment: fragmentsB[1]),
            .toolCallDelta(id: "toolu_P2", name: "point_at", argumentsFragment: fragmentsB[2]),
            .toolCall(ToolCall(id: "toolu_P2", name: "point_at", arguments: argumentsB)),
            .usage(TokenUsage(inputTokens: 1040, cachedInputTokens: 1000, outputTokens: 77)),
            .finished(.toolCalls),
        ])
        #expect(try JSONValue.parse(argumentsA)["label"] == "café \"au lait\" ☕️")
    }
}

/// Never answers; records when the request starts and when its task is cancelled, like URLSession waiting on headers.
private final class NoResponseTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    var didStart: Bool { lock.withLock { started } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        lock.withLock { started = true }
        try await withTaskCancellationHandler {
            while true { try await Task.sleep(for: .seconds(60)) }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
        }
        throw URLError(.timedOut) // not reached: the sleep throws CancellationError once cancelled
    }
}

/// Sends one chunk, then keeps the response open until the reader goes away, like a slow network. Records when the
/// response stream is torn down so a test can see that cancellation reached the network layer.
private final class HangingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    private let firstChunk: Data

    init(firstChunk: String) { self.firstChunk = Data(firstChunk.utf8) }

    var wasTerminated: Bool { lock.withLock { terminated } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let chunk = firstChunk
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in self.markTerminated() }
            continuation.yield(chunk)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        return (stream, response)
    }

    private func markTerminated() { lock.withLock { terminated = true } }
}
