import Foundation
import Testing
@testable import OpenClickyKit

/// OpenAI Responses adapter tests. Every response body below follows the shapes in OpenAI's streaming-events
/// reference and function-calling guide; nothing touches the network and the API key is a placeholder.
@Suite struct OpenAIResponsesTests {
    static let fakeKey = "sk-test-placeholder"

    // MARK: Fixtures

    /// An SSE body: one `event:` line named after the payload's `type`, one `data:` line, a blank line.
    static func sse(_ payloads: [String], comment: String? = nil) -> String {
        var body = payloads.map { payload in
            let type = (try? JSONValue.parse(payload))?["type"]?.stringValue ?? "message"
            return "event: \(type)\ndata: \(payload)\n\n"
        }
        if let comment { body.insert(": \(comment)\n\n", at: min(4, body.count)) }
        return body.joined()
    }

    static let created = #"{"type":"response.created","response":{"id":"resp_67c9fdcecf488190","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"instructions":"You are a helpful assistant.","max_output_tokens":null,"model":"gpt-6-astra","output":[],"parallel_tool_calls":true,"previous_response_id":null,"reasoning":{"effort":null,"summary":null},"store":false,"temperature":1.0,"text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[],"top_p":1.0,"truncation":"disabled","usage":null,"user":null,"metadata":{}},"sequence_number":0}"#
    static let inProgress = #"{"type":"response.in_progress","response":{"id":"resp_67c9fdcecf488190","object":"response","created_at":1741290958,"status":"in_progress","error":null,"incomplete_details":null,"model":"gpt-6-astra","output":[],"store":false,"usage":null,"metadata":{}},"sequence_number":1}"#

    static func textDelta(_ delta: String, _ sequence: Int) -> String {
        let escaped = JSONValue.string(delta).jsonString()
        return #"{"type":"response.output_text.delta","item_id":"msg_67c9fdcf37fc8190","output_index":0,"content_index":0,"delta":\#(escaped),"sequence_number":\#(sequence),"logprobs":[]}"#
    }

    static let textStream = sse([
        created,
        inProgress,
        #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":2}"#,
        #"{"type":"response.content_part.added","item_id":"msg_67c9fdcf37fc8190","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[],"logprobs":[]},"sequence_number":3}"#,
        textDelta("Hi", 4),
        textDelta(" there! ", 5),
        textDelta("Café ☕️ ", 6),
        textDelta("👋", 7),
        #"{"type":"response.output_text.done","item_id":"msg_67c9fdcf37fc8190","output_index":0,"content_index":0,"text":"Hi there! Café ☕️ 👋","sequence_number":8,"logprobs":[]}"#,
        #"{"type":"response.content_part.done","item_id":"msg_67c9fdcf37fc8190","output_index":0,"content_index":0,"part":{"type":"output_text","text":"Hi there! Café ☕️ 👋","annotations":[],"logprobs":[]},"sequence_number":9}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_67c9fdcf37fc8190","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! Café ☕️ 👋","annotations":[],"logprobs":[]}]},"sequence_number":10}"#,
        #"{"type":"response.completed","response":{"id":"resp_67c9fdcecf488190","object":"response","created_at":1741290958,"status":"completed","error":null,"incomplete_details":null,"model":"gpt-6-astra","output":[{"id":"msg_67c9fdcf37fc8190","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"Hi there! Café ☕️ 👋","annotations":[],"logprobs":[]}]}],"store":false,"usage":{"input_tokens":37,"output_tokens":11,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":48,"input_tokens_details":{"cached_tokens":12,"cache_write_tokens":0}},"user":null,"metadata":{}},"sequence_number":11}"#,
    ], comment: "Intermediate response events omitted.")

    static func argsDelta(_ itemID: String, _ index: Int, _ delta: String) -> String {
        #"{"type":"response.function_call_arguments.delta","response_id":"resp_1234xyz","item_id":"\#(itemID)","output_index":\#(index),"delta":\#(JSONValue.string(delta).jsonString())}"#
    }

    /// A reasoning summary, then two function calls, as a reasoning model streams them.
    static let toolStream = sse([
        created,
        #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_6806bfca0b2481918a","type":"reasoning","summary":[]},"sequence_number":2}"#,
        #"{"type":"response.reasoning_summary_part.added","item_id":"rs_6806bfca0b2481918a","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""},"sequence_number":3}"#,
        #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_6806bfca0b2481918a","output_index":0,"summary_index":0,"delta":"**Finding the button**\n\nThe user wants the Save button.","sequence_number":4}"#,
        #"{"type":"response.reasoning_summary_part.added","item_id":"rs_6806bfca0b2481918a","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""},"sequence_number":5}"#,
        #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_6806bfca0b2481918a","output_index":0,"summary_index":1,"delta":"I'll check the weather too.","sequence_number":6}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_6806bfca0b2481918a","type":"reasoning","summary":[{"type":"summary_text","text":"..."}],"encrypted_content":"gAAAAAB..."},"sequence_number":7}"#,
        #"{"type":"response.output_item.added","response_id":"resp_1234xyz","output_index":1,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":""}}"#,
        argsDelta("fc_1234xyz", 1, "{\""),
        argsDelta("fc_1234xyz", 1, "location"),
        argsDelta("fc_1234xyz", 1, "\":\""),
        argsDelta("fc_1234xyz", 1, "Paris"),
        argsDelta("fc_1234xyz", 1, ","),
        argsDelta("fc_1234xyz", 1, " France"),
        argsDelta("fc_1234xyz", 1, "\"}"),
        #"{"type":"response.function_call_arguments.done","response_id":"resp_1234xyz","item_id":"fc_1234xyz","output_index":1,"arguments":"{\"location\":\"Paris, France\"}"}"#,
        #"{"type":"response.output_item.done","response_id":"resp_1234xyz","output_index":1,"item":{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":"{\"location\":\"Paris, France\"}"}}"#,
        #"{"type":"response.output_item.added","response_id":"resp_1234xyz","output_index":2,"item":{"type":"function_call","id":"fc_5678abc","call_id":"call_5678abc","name":"point_at","arguments":"","status":"in_progress"}}"#,
        argsDelta("fc_5678abc", 2, "{\"x\":412,"),
        argsDelta("fc_5678abc", 2, "\"y\":88}"),
        #"{"type":"response.function_call_arguments.done","response_id":"resp_1234xyz","item_id":"fc_5678abc","output_index":2,"arguments":"{\"x\":412,\"y\":88}"}"#,
        #"{"type":"response.output_item.done","response_id":"resp_1234xyz","output_index":2,"item":{"type":"function_call","id":"fc_5678abc","call_id":"call_5678abc","name":"point_at","arguments":"{\"x\":412,\"y\":88}","status":"completed"}}"#,
        #"{"type":"response.completed","response":{"id":"resp_1234xyz","object":"response","status":"completed","error":null,"incomplete_details":null,"model":"gpt-6-astra","output":[{"id":"rs_6806bfca0b2481918a","type":"reasoning","summary":[]},{"type":"function_call","id":"fc_1234xyz","call_id":"call_1234xyz","name":"get_weather","arguments":"{\"location\":\"Paris, France\"}","status":"completed"},{"type":"function_call","id":"fc_5678abc","call_id":"call_5678abc","name":"point_at","arguments":"{\"x\":412,\"y\":88}","status":"completed"}],"store":false,"usage":{"input_tokens":812,"output_tokens":164,"output_tokens_details":{"reasoning_tokens":96},"total_tokens":976,"input_tokens_details":{"cached_tokens":768,"cache_write_tokens":0}}},"sequence_number":30}"#,
    ])

    static func client(_ transport: any HTTPTransport, apiKey: String? = fakeKey, baseURL: String? = nil,
                       headers: [String: String]? = nil, reasoningSummary: String? = nil, imageDetail: String = "auto",
                       strictTools: Bool = false) -> OpenAIResponsesClient {
        let provider = ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: baseURL.flatMap(URL.init(string:)),
                                      credential: "openai", headers: headers)
        return OpenAIResponsesClient(context: ProviderContext(provider: provider, apiKey: apiKey, http: transport),
                                     reasoningSummary: reasoningSummary, imageDetail: imageDetail, strictTools: strictTools)
    }

    static let simpleRequest = ChatRequest(model: "gpt-6-astra", messages: [.system("Be brief."), .user(.text("Hello!"))])

    static func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Events seen before the stream threw, and the error.
    static func collectUntilError(_ stream: AsyncThrowingStream<ChatEvent, Error>) async -> ([ChatEvent], Error?) {
        var events: [ChatEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    // MARK: Streaming

    @Test(arguments: [1, 5, 37, 100_000])
    func streamsTextDeltasThenUsageAndStop(chunkSize: Int) async throws {
        let transport = FakeHTTPTransport([.sse(Self.textStream, chunkSize: chunkSize)])
        let events = try await Self.collect(Self.client(transport).stream(Self.simpleRequest))
        #expect(events == [
            .textDelta("Hi"),
            .textDelta(" there! "),
            .textDelta("Café ☕️ "),
            .textDelta("👋"),
            .usage(TokenUsage(inputTokens: 37, cachedInputTokens: 12, outputTokens: 11)),
            .finished(.stop),
        ])
    }

    @Test(arguments: [1, 9, 64])
    func streamsReasoningAndToolCalls(chunkSize: Int) async throws {
        let transport = FakeHTTPTransport([.sse(Self.toolStream, chunkSize: chunkSize)])
        let events = try await Self.collect(Self.client(transport).stream(Self.simpleRequest))
        let weatherFragments = ["{\"", "location", "\":\"", "Paris", ",", " France", "\"}"]
        let expected: [ChatEvent] =
            [.reasoningDelta("**Finding the button**\n\nThe user wants the Save button."), .reasoningDelta("\n\n"),
             .reasoningDelta("I'll check the weather too.")]
            + weatherFragments.map { .toolCallDelta(id: "call_1234xyz", name: "get_weather", argumentsFragment: $0) }
            + [.toolCall(ToolCall(id: "call_1234xyz", name: "get_weather", arguments: "{\"location\":\"Paris, France\"}")),
               .toolCallDelta(id: "call_5678abc", name: "point_at", argumentsFragment: "{\"x\":412,"),
               .toolCallDelta(id: "call_5678abc", name: "point_at", argumentsFragment: "\"y\":88}"),
               .toolCall(ToolCall(id: "call_5678abc", name: "point_at", arguments: "{\"x\":412,\"y\":88}")),
               // The encrypted reasoning item (from its output_item.done event) and both calls, for replay.
               .providerItems(dialect: "openai-responses", items: [
                   ["id": "rs_6806bfca0b2481918a", "type": "reasoning", "summary": [["type": "summary_text", "text": "..."]],
                    "encrypted_content": "gAAAAAB..."],
                   ["type": "function_call", "id": "fc_1234xyz", "call_id": "call_1234xyz", "name": "get_weather",
                    "arguments": "{\"location\":\"Paris, France\"}"],
                   ["type": "function_call", "id": "fc_5678abc", "call_id": "call_5678abc", "name": "point_at",
                    "arguments": "{\"x\":412,\"y\":88}", "status": "completed"],
               ]),
               .usage(TokenUsage(inputTokens: 812, cachedInputTokens: 768, outputTokens: 164)),
               .finished(.toolCalls)]
        #expect(events == expected)
        // Assembled fragments equal the final arguments.
        #expect(weatherFragments.joined() == "{\"location\":\"Paris, France\"}")
    }

    @Test func toolCallFallsBackToOutputItemDoneAndCompletedOutput() async throws {
        // First call: no `function_call_arguments.done`. Second call: only listed in `response.completed`.
        let body = Self.sse([
            #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"draw","arguments":""}}"#,
            Self.argsDelta("fc_a", 0, "{\"shape\":"),
            Self.argsDelta("fc_a", 0, "\"circle\"}"),
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_a","call_id":"call_a","name":"draw","arguments":"{\"shape\":\"circle\"}","status":"completed"}}"#,
            #"{"type":"response.completed","response":{"id":"resp_x","object":"response","status":"completed","output":[{"type":"function_call","id":"fc_a","call_id":"call_a","name":"draw","arguments":"{\"shape\":\"circle\"}","status":"completed"},{"type":"function_call","id":"fc_b","call_id":"call_b","name":"speak","arguments":"{}","status":"completed"}],"usage":null}}"#,
        ])
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body, chunkSize: 11)])).stream(Self.simpleRequest))
        #expect(events == [
            .toolCallDelta(id: "call_a", name: "draw", argumentsFragment: "{\"shape\":"),
            .toolCallDelta(id: "call_a", name: "draw", argumentsFragment: "\"circle\"}"),
            .toolCall(ToolCall(id: "call_a", name: "draw", arguments: "{\"shape\":\"circle\"}")),
            .toolCall(ToolCall(id: "call_b", name: "speak", arguments: "{}")),
            .finished(.toolCalls),
        ])
    }

    @Test func incompleteResponseFinishesWithLength() async throws {
        let body = Self.sse([
            Self.textDelta("Once upon", 1),
            #"{"type":"response.incomplete","response":{"id":"resp_123","object":"response","created_at":1740855869,"status":"incomplete","completed_at":null,"error":null,"incomplete_details":{"reason":"max_output_tokens"},"instructions":null,"max_output_tokens":16,"model":"gpt-6-astra","output":[],"store":false,"usage":{"input_tokens":20,"output_tokens":16,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":36,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0}},"metadata":{}},"sequence_number":2}"#,
        ])
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.simpleRequest))
        #expect(events == [.textDelta("Once upon"), .usage(TokenUsage(inputTokens: 20, outputTokens: 16)), .finished(.length)])
    }

    @Test func contentFilterIncompleteMapsToContentFilter() async throws {
        let body = Self.sse([#"{"type":"response.incomplete","response":{"id":"resp_1","status":"incomplete","incomplete_details":{"reason":"content_filter"},"usage":null},"sequence_number":1}"#])
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.simpleRequest))
        #expect(events == [.finished(.contentFilter)])
    }

    // MARK: Request encoding

    @Test func encodesConversationToolsAndOptions() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let request = ChatRequest(
            model: "gpt-6.1-sol",
            messages: [
                .system("You are Clicky."),
                .system("Keep replies short."),
                .user(.text("What's on my screen?"), .image(data: png, mimeType: "image/png")),
                .assistant("Let me look.", toolCalls: [
                    ToolCall(id: "call_1", name: "point_at", arguments: "{\"x\":10,\"y\":20}"),
                    ToolCall(id: "call_2", name: "screenshot", arguments: "{}"),
                ]),
                .tool(callID: "call_1", result: "{\"ok\":true}"),
                ChatMessage(role: .tool, content: [.text("Captured."), .image(data: png, mimeType: "image/jpeg")], toolCallID: "call_2"),
                .system("The user switched to Safari."),
                .assistant("", toolCalls: [ToolCall(id: "call_3", name: "point_at", arguments: "{}")]),
                .tool(callID: "call_3", result: "done"),
                .user(.text("Thanks!")),
            ],
            tools: [ToolSpec(name: "point_at", description: "Point at a spot on screen.",
                             parameters: ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                                          "required": ["x", "y"]])],
            reasoningEffort: "medium",
            maxOutputTokens: 2048,
            temperature: 0.7
        )
        let transport = FakeHTTPTransport([])
        let urlRequest = Self.client(transport, baseURL: "https://gateway.example.com/v1/", headers: ["X-Title": "OpenClicky"])
            .makeURLRequest(request)

        #expect(urlRequest.url?.absoluteString == "https://gateway.example.com/v1/responses")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Title") == "OpenClicky")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)")

        let body = try JSONValue.parse(String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self))
        let pngURL = "data:image/png;base64,\(png.base64EncodedString())"
        let jpegURL = "data:image/jpeg;base64,\(png.base64EncodedString())"
        let expected: JSONValue = [
            "model": "gpt-6.1-sol",
            "stream": true,
            "store": false,
            "instructions": "You are Clicky.\n\nKeep replies short.",
            "input": [
                ["type": "message", "role": "user", "content": [
                    ["type": "input_text", "text": "What's on my screen?"],
                    ["type": "input_image", "image_url": .string(pngURL), "detail": "auto"],
                ]],
                ["type": "message", "role": "assistant", "content": "Let me look."],
                ["type": "function_call", "call_id": "call_1", "name": "point_at", "arguments": "{\"x\":10,\"y\":20}"],
                ["type": "function_call", "call_id": "call_2", "name": "screenshot", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_1", "output": "{\"ok\":true}"],
                ["type": "function_call_output", "call_id": "call_2", "output": [
                    ["type": "input_text", "text": "Captured."],
                    ["type": "input_image", "image_url": .string(jpegURL), "detail": "auto"],
                ]],
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "The user switched to Safari."]]],
                ["type": "function_call", "call_id": "call_3", "name": "point_at", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_3", "output": "done"],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Thanks!"]]],
            ],
            "tools": [[
                "type": "function", "name": "point_at", "description": "Point at a spot on screen.", "strict": false,
                "parameters": ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"]],
            ]],
            "reasoning": ["effort": "medium"],
            "max_output_tokens": 2048,
            "temperature": 0.7,
        ]
        #expect(body == expected)
    }

    @Test func sendsRequestThroughTransportAndOmitsUnsetOptions() async throws {
        let transport = FakeHTTPTransport([.sse(Self.textStream)])
        _ = try await Self.collect(Self.client(transport, apiKey: nil).stream(
            ChatRequest(model: "gpt-oss-20b", messages: [.user(.text("Hi"))])))

        #expect(transport.requests.count == 1)
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        // A keyless local server gets no Authorization header at all.
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try transport.jsonBody(0)
        #expect(body == [
            "model": "gpt-oss-20b",
            "stream": true,
            "store": false,
            "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": "Hi"]]]],
        ])
    }

    @Test func passesReasoningSummaryImageDetailAndStrictOptions() throws {
        let request = ChatRequest(model: "gpt-6.1-sol", messages: [.user(.image(data: Data([1, 2, 3]), mimeType: "image/png"))],
                                  tools: [ToolSpec(name: "noop", description: "", parameters: ["type": "object", "properties": [:], "required": [], "additionalProperties": false])],
                                  reasoningEffort: "high")
        let urlRequest = Self.client(FakeHTTPTransport([]), reasoningSummary: "auto", imageDetail: "high", strictTools: true)
            .makeURLRequest(request)
        let body = try JSONValue.parse(String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self))
        #expect(body["reasoning"] == ["effort": "high", "summary": "auto"])
        #expect(body["input"]?.arrayValue?.first?["content"]?.arrayValue?.first?["detail"] == "high")
        // Empty descriptions are left out rather than sent as "".
        #expect(body["tools"] == [["type": "function", "name": "noop", "strict": true,
                                   "parameters": ["type": "object", "properties": [:], "required": [], "additionalProperties": false]]])
    }

    // MARK: Errors

    @Test func httpErrorSurfacesStatusAndOpenAIMessage() async throws {
        let body = #"{"error":{"message":"Incorrect API key provided: sk-test-****lder. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#
        let transport = FakeHTTPTransport([.body(body, status: 401)])
        let (events, error) = await Self.collectUntilError(Self.client(transport).stream(Self.simpleRequest))
        #expect(events.isEmpty)
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.provider == "openai")
        #expect(providerError.status == 401)
        #expect(providerError.message == "Incorrect API key provided: sk-test-****lder. You can find your API key at https://platform.openai.com/account/api-keys. (invalid_api_key)")
    }

    @Test func nonJSONErrorBodyIsKeptVerbatim() async throws {
        let transport = FakeHTTPTransport([.body("<html>502 Bad Gateway</html>", status: 502, contentType: "text/html")])
        let (_, error) = await Self.collectUntilError(Self.client(transport).stream(Self.simpleRequest))
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.status == 502)
        #expect(providerError.message == "<html>502 Bad Gateway</html>")
    }

    @Test func streamErrorEventThrowsAfterEarlierDeltas() async throws {
        let body = Self.sse([
            Self.textDelta("Partial", 1),
            #"{"type":"error","code":"ERR_SOMETHING","message":"Something went wrong","param":null,"sequence_number":2}"#,
        ])
        let (events, error) = await Self.collectUntilError(Self.client(FakeHTTPTransport([.sse(body, chunkSize: 3)])).stream(Self.simpleRequest))
        #expect(events == [.textDelta("Partial")])
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.message == "Something went wrong (ERR_SOMETHING)")
        #expect(providerError.status == nil)
    }

    @Test func nestedErrorEventIsAlsoUnderstood() async throws {
        let body = Self.sse([#"{"type":"error","status":429,"error":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"Rate limit reached for gpt-6-astra.","param":null}}"#])
        let (_, error) = await Self.collectUntilError(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.simpleRequest))
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.status == 429)
        #expect(providerError.message == "Rate limit reached for gpt-6-astra. (rate_limit_exceeded)")
    }

    @Test func failedResponseThrowsItsError() async throws {
        let body = Self.sse([
            Self.created,
            #"{"type":"response.failed","response":{"id":"resp_123","object":"response","created_at":1740855869,"status":"failed","completed_at":null,"error":{"code":"server_error","message":"The model failed to generate a response."},"incomplete_details":null,"model":"gpt-6-astra","output":[],"store":false,"usage":null,"metadata":{}},"sequence_number":1}"#,
        ])
        let (events, error) = await Self.collectUntilError(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.simpleRequest))
        #expect(events.isEmpty)
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.message == "The model failed to generate a response. (server_error)")
    }

    @Test func truncatedStreamThrowsInsteadOfFinishingQuietly() async throws {
        let body = Self.sse([Self.created, Self.textDelta("Cut", 1)])
        let (events, error) = await Self.collectUntilError(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.simpleRequest))
        #expect(events == [.textDelta("Cut")])
        #expect(error is ProviderError)
    }

    // MARK: Cancellation

    @Test func cancellingTheConsumerCancelsTheNetworkStream() async throws {
        let transport = HangingSSETransport(firstChunk: Data(Self.sse([Self.created, Self.textDelta("Hel", 1)]).utf8))
        let client = Self.client(transport)
        let (seen, seenContinuation) = AsyncStream<ChatEvent>.makeStream()
        let consumer = Task {
            for try await event in client.stream(Self.simpleRequest) { seenContinuation.yield(event) }
        }
        // The first delta arrives while the response is still open, so nothing waits for the whole body.
        var iterator = seen.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .textDelta("Hel"))
        #expect(!transport.terminated)

        consumer.cancel()
        _ = await consumer.result
        _ = await waitUntil { transport.terminated }
        #expect(transport.terminated)
    }
}

/// Streams one chunk and then stays open, like a server mid-response, until whoever reads it goes away.
private final class HangingSSETransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var didTerminate = false
    private let firstChunk: Data

    init(firstChunk: Data) { self.firstChunk = firstChunk }

    var terminated: Bool { lock.withLock { didTerminate } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(firstChunk)
            continuation.onTermination = { [weak self] _ in self?.markTerminated() }
        }
        return (stream, response)
    }

    private func markTerminated() { lock.withLock { didTerminate = true } }
}
