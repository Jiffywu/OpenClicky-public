import Foundation
import Testing
@testable import OpenClickyKit

/// OpenAIChatClient against scripted servers. Payloads follow the shapes in the OpenAI, OpenRouter, vLLM and Ollama
/// docs cited in OpenAIChatClient.swift. No network, no real keys.
@Suite struct OpenAIChatTests {
    /// Not a real key: the tests only check that it is forwarded.
    static let fakeKey = "sk-test-not-a-real-key"

    static func sse(_ payloads: [String]) -> String { payloads.map { "data: \($0)\n\n" }.joined() }

    static func client(baseURL: String? = "https://api.openai.com/v1", apiKey: String? = fakeKey, headers: [String: String]? = nil,
                       id: String = "openai", responses: [FakeHTTPTransport.Scripted]) -> (OpenAIChatClient, FakeHTTPTransport) {
        let transport = FakeHTTPTransport(responses)
        let provider = ProviderConfig(id: id, dialect: .openAIChat, baseURL: baseURL.flatMap(URL.init(string:)), credential: "k", headers: headers)
        return (OpenAIChatClient(context: ProviderContext(provider: provider, apiKey: apiKey, http: transport)), transport)
    }

    /// Every event the stream yields, and the error it ended with.
    static func drain(_ stream: AsyncThrowingStream<ChatEvent, Error>) async -> (events: [ChatEvent], error: Error?) {
        var events: [ChatEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    static let simpleRequest = ChatRequest(model: "gpt-test", messages: [.user(.text("Hi"))])

    // MARK: - Streaming

    @Test func streamsTextUsageAndFinishAcrossAwkwardChunkBoundaries() async throws {
        let body = ": OPENROUTER PROCESSING\n\n" + Self.sse([
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-test","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","content":"","refusal":null},"logprobs":null,"finish_reason":null}],"usage":null,"obfuscation":"r4N7vQ2m"}"#,
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-test","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-test","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"content":" wörld 👋"},"logprobs":null,"finish_reason":null}],"usage":null}"#,
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-test","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}],"usage":null}"#,
            #"{"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-test","system_fingerprint":"fp_44709d6fcb","choices":[],"usage":{"prompt_tokens":19,"completion_tokens":10,"total_tokens":29,"prompt_tokens_details":{"cached_tokens":4,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}"#,
            "[DONE]",
        ])
        // 5-byte chunks split JSON, the `data:` prefix and the multi-byte "ö" and "👋" mid-character.
        let (client, _) = Self.client(responses: [.sse(body, chunkSize: 5)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .textDelta("Hello"),
            .textDelta(" wörld 👋"),
            .usage(TokenUsage(inputTokens: 19, cachedInputTokens: 4, outputTokens: 10)),
            .finished(.stop),
        ])
    }

    @Test(.timeLimit(.minutes(1))) func yieldsEventsBeforeTheResponseEnds() async throws {
        // The transport below never finishes; the first delta must still come through.
        let transport = HangingStreamTransport(firstChunk: Self.sse([
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"early"},"finish_reason":null}]}"#,
        ]))
        let client = OpenAIChatClient(context: ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil, http: transport))
        var iterator = client.stream(Self.simpleRequest).makeAsyncIterator()
        #expect(try await iterator.next() == .textDelta("early"))
    }

    @Test func assemblesFragmentedParallelToolCallsByIndex() async throws {
        let body = Self.sse([
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_DdmO9pD3","type":"function","function":{"name":"point_at","arguments":""}}],"refusal":null},"logprobs":null,"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":"}}]},"logprobs":null,"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"12,\"y\":34}"}}]},"logprobs":null,"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_Xy7","type":"function","function":{"name":"say","arguments":""}}]},"logprobs":null,"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"text\":\"hi\"}"}}]},"logprobs":null,"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"tool_calls"}]}"#,
            #"{"id":"chatcmpl-9","object":"chat.completion.chunk","created":1,"model":"gpt-test","choices":[],"usage":{"prompt_tokens":80,"completion_tokens":30,"total_tokens":110}}"#,
            "[DONE]",
        ])
        let (client, _) = Self.client(responses: [.sse(body, chunkSize: 11)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .toolCallDelta(id: "call_DdmO9pD3", name: "point_at", argumentsFragment: "{\"x\":"),
            .toolCallDelta(id: "call_DdmO9pD3", name: "point_at", argumentsFragment: "12,\"y\":34}"),
            .toolCallDelta(id: "call_Xy7", name: "say", argumentsFragment: "{\"text\":\"hi\"}"),
            .toolCall(ToolCall(id: "call_DdmO9pD3", name: "point_at", arguments: "{\"x\":12,\"y\":34}")),
            .toolCall(ToolCall(id: "call_Xy7", name: "say", arguments: "{\"text\":\"hi\"}")),
            .usage(TokenUsage(inputTokens: 80, outputTokens: 30)),
            .finished(.toolCalls),
        ])
    }

    @Test func acceptsWholeToolCallsInOneChunkAndStopFinishReason() async throws {
        // Ollama-style: each call arrives complete. The second has no id and no arguments; the server says "stop".
        let body = Self.sse([
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","tool_calls":[{"id":"call_abc","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},{"index":1,"type":"function","function":{"name":"screenshot","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"qwen3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        let (client, _) = Self.client(baseURL: "http://127.0.0.1:11434/v1", apiKey: nil, id: "ollama", responses: [.sse(body, chunkSize: 9)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .toolCallDelta(id: "call_abc", name: "get_weather", argumentsFragment: "{\"city\":\"Paris\"}"),
            .toolCall(ToolCall(id: "call_abc", name: "get_weather", arguments: "{\"city\":\"Paris\"}")),
            .toolCall(ToolCall(id: "call_1", name: "screenshot", arguments: "{}")),
            .finished(.toolCalls),
        ])
        let result = try await Self.client(baseURL: "http://127.0.0.1:11434/v1", apiKey: nil, responses: [.sse(body)]).0.complete(Self.simpleRequest)
        #expect(result.toolCalls.map(\.name) == ["get_weather", "screenshot"])
    }

    @Test func readsEachDocumentedReasoningFieldOnce() async throws {
        let body = Self.sse([
            // OpenRouter mirrors the same text into `reasoning` and `reasoning_details`: one event, not two.
            #"{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"anthropic/claude","provider":"Anthropic","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"Let me think","reasoning_details":[{"type":"reasoning.text","text":"Let me think","signature":null,"id":"reasoning-text-1","format":"anthropic-claude-v1","index":0}]},"finish_reason":null,"native_finish_reason":null}]}"#,
            // DeepSeek and older vLLM.
            #"{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"reasoning_content":" step by step."},"finish_reason":null}]}"#,
            // `reasoning_details` alone, as OpenRouter's reasoning guide shows it; encrypted entries carry no text.
            #"{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.summary","summary":" Summary.","format":"openai-responses-v1","index":0},{"type":"reasoning.encrypted","data":"eyJlbmNyeXB0ZWQiOiJ0cnVlIn0=","index":1}]},"finish_reason":null}]}"#,
            #"{"id":"gen-1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Answer."},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        let (client, _) = Self.client(baseURL: "https://openrouter.ai/api/v1", id: "openrouter", responses: [.sse(body, chunkSize: 13)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .reasoningDelta("Let me think"),
            .reasoningDelta(" step by step."),
            .reasoningDelta(" Summary."),
            .textDelta("Answer."),
            .finished(.stop),
        ])
    }

    @Test(arguments: [
        ("length", FinishReason.length),
        ("content_filter", .contentFilter),
        ("function_call", .toolCalls),
        ("something_new", .other),
    ])
    func mapsFinishReasons(raw: String, expected: FinishReason) async throws {
        let body = Self.sse([
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":"\#(raw)"}]}"#,
            "[DONE]",
        ])
        let (client, _) = Self.client(responses: [.sse(body)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events.last == .finished(expected))
    }

    @Test func refusalIsPassedOnAsText() async throws {
        let body = Self.sse([
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":null,"refusal":"I can't help with that."},"finish_reason":null}]}"#,
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        let (client, _) = Self.client(responses: [.sse(body)])
        let (events, _) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(events == [.textDelta("I can't help with that."), .finished(.stop)])
    }

    @Test func finishesWithoutDoneMarkerButNotWithoutFinishReason() async throws {
        let complete = Self.sse([#"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#])
        let (client, _) = Self.client(responses: [.sse(complete)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(error == nil)
        #expect(events == [.textDelta("ok"), .finished(.stop)])

        let truncated = Self.sse([#"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"cut"},"finish_reason":null}]}"#])
        let (cutClient, _) = Self.client(responses: [.sse(truncated)])
        let (cutEvents, cutError) = await Self.drain(cutClient.stream(Self.simpleRequest))
        #expect(cutEvents == [.textDelta("cut")])
        #expect(cutError is ProviderError)
    }

    @Test func stopsReadingAtDone() async throws {
        let body = Self.sse([
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"a"},"finish_reason":"stop"}]}"#,
            "[DONE]",
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"after done"},"finish_reason":null}]}"#,
        ])
        let (client, _) = Self.client(responses: [.sse(body)])
        let (events, _) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(events == [.textDelta("a"), .finished(.stop)])
    }

    // MARK: - Errors

    @Test func httpErrorCarriesStatusAndProviderMessage() async throws {
        let openAIBody = """
        {
            "error": {
                "message": "Incorrect API key provided: sk-test*****-key. You can find your API key at https://platform.openai.com/account/api-keys.",
                "type": "invalid_request_error",
                "param": null,
                "code": "invalid_api_key"
            }
        }
        """
        let (client, _) = Self.client(responses: [.body(openAIBody, status: 401)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(events.isEmpty)
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.provider == "openai")
        #expect(providerError.status == 401)
        #expect(providerError.message.hasPrefix("Incorrect API key provided"))

        // OpenRouter's documented pre-stream error, and LM Studio's plain-string error.
        let (router, _) = Self.client(baseURL: "https://openrouter.ai/api/v1", id: "openrouter",
                                      responses: [.body(#"{"error": {"code": 402, "message": "Insufficient credits"}}"#, status: 402)])
        let routerError = try #require(await Self.drain(router.stream(Self.simpleRequest)).error as? ProviderError)
        #expect(routerError.status == 402)
        #expect(routerError.message == "Insufficient credits")

        let (lmStudio, _) = Self.client(baseURL: "http://localhost:1234/v1", apiKey: nil, id: "lmstudio",
                                        responses: [.body(#"{"error":"Unexpected endpoint or method. (POST /v1/chat/completion)"}"#, status: 404)])
        let lmError = try #require(await Self.drain(lmStudio.stream(Self.simpleRequest)).error as? ProviderError)
        #expect(lmError.status == 404)
        #expect(lmError.message == "Unexpected endpoint or method. (POST /v1/chat/completion)")

        let (proxy, _) = Self.client(responses: [.body("<html>502 Bad Gateway</html>", status: 502, contentType: "text/html")])
        let proxyError = try #require(await Self.drain(proxy.stream(Self.simpleRequest)).error as? ProviderError)
        #expect(proxyError.status == 502)
        #expect(proxyError.message == "<html>502 Bad Gateway</html>")
    }

    @Test func errorObjectInsideTheStreamThrowsAfterEarlierText() async throws {
        let body = Self.sse([
            #"{"id":"cmpl-abc123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-3.5-turbo","provider":"openai","choices":[{"index":0,"delta":{"content":"Partial"},"finish_reason":null}]}"#,
            #"{"id":"cmpl-abc123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-3.5-turbo","provider":"openai","error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#,
        ])
        let (client, _) = Self.client(baseURL: "https://openrouter.ai/api/v1", id: "openrouter", responses: [.sse(body, chunkSize: 17)])
        let (events, error) = await Self.drain(client.stream(Self.simpleRequest))
        #expect(events == [.textDelta("Partial")])
        let providerError = try #require(error as? ProviderError)
        #expect(providerError.message == "Provider disconnected unexpectedly")
        #expect(providerError.status == nil)

        // vLLM nests `{"error":{"message","type","param","code"}}` with an integer code.
        let vllm = Self.sse([#"{"error":{"message":"The model ran out of KV cache","type":"InternalServerError","param":null,"code":500}}"#])
        let (vllmClient, _) = Self.client(baseURL: "http://gpu-box:8000/v1", apiKey: nil, responses: [.sse(vllm)])
        let vllmError = try #require(await Self.drain(vllmClient.stream(Self.simpleRequest)).error as? ProviderError)
        #expect(vllmError.status == 500)
        #expect(vllmError.message == "The model ran out of KV cache")
    }

    // MARK: - Request encoding

    @Test func encodesTheFullConversationToolsAndOptions() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let schema: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"]]
        let request = ChatRequest(
            model: "anthropic/claude-sonnet",
            messages: [
                .system("You are a helpful buddy."),
                .user(.text("What is this?"), .image(data: png, mimeType: "image/png")),
                .assistant("", toolCalls: [ToolCall(id: "call_1", name: "point_at", arguments: "{\"x\":1,\"y\":2}")]),
                .tool(callID: "call_1", result: "pointed"),
                .assistant("Done. Anything else?"),
                .user(.text("No thanks")),
            ],
            tools: [ToolSpec(name: "point_at", description: "Point at a spot on screen.", parameters: schema)],
            reasoningEffort: "high",
            maxOutputTokens: 2048,
            temperature: 0.5
        )
        let (client, transport) = Self.client(baseURL: "https://openrouter.ai/api/v1/",
                                              headers: ["HTTP-Referer": "https://openclicky.app", "X-Title": "OpenClicky"],
                                              id: "openrouter", responses: [.sse(Self.sse(["[DONE]"]))])
        _ = await Self.drain(client.stream(request))

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)")
        #expect(sent.value(forHTTPHeaderField: "HTTP-Referer") == "https://openclicky.app")
        #expect(sent.value(forHTTPHeaderField: "X-Title") == "OpenClicky")

        let expected: JSONValue = [
            "model": "anthropic/claude-sonnet",
            "stream": true,
            "stream_options": ["include_usage": true],
            "reasoning_effort": "high",
            "max_tokens": 2048,
            "temperature": 0.5,
            "tools": [["type": "function", "function": ["name": "point_at", "description": "Point at a spot on screen.", "parameters": schema]]],
            "messages": [
                ["role": "system", "content": "You are a helpful buddy."],
                ["role": "user", "content": [
                    ["type": "text", "text": "What is this?"],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,iVBORw=="]],
                ]],
                ["role": "assistant", "content": .null, "tool_calls": [
                    ["id": "call_1", "type": "function", "function": ["name": "point_at", "arguments": "{\"x\":1,\"y\":2}"]],
                ]],
                ["role": "tool", "tool_call_id": "call_1", "content": "pointed"],
                ["role": "assistant", "content": "Done. Anything else?"],
                ["role": "user", "content": "No thanks"],
            ],
        ]
        #expect(try transport.jsonBody(0) == expected)
    }

    @Test func openAIDefaultsAndKeylessLocalServers() async throws {
        let request = ChatRequest(model: "gpt-test", messages: [.user(.text("Hi"))], maxOutputTokens: 100)

        // No base URL: api.openai.com, `max_completion_tokens`, no optional fields that were not asked for.
        let (openAI, openAITransport) = Self.client(baseURL: nil, responses: [.sse(Self.sse(["[DONE]"]))])
        _ = await Self.drain(openAI.stream(request))
        let sent = try #require(openAITransport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") != nil)
        let body = try openAITransport.jsonBody(0)
        #expect(body["max_completion_tokens"] == 100)
        #expect(body["max_tokens"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["reasoning_effort"] == nil)
        #expect(body["temperature"] == nil)

        // Ollama with no key: no Authorization header at all, and `max_tokens`.
        for key in [nil, ""] as [String?] {
            let (ollama, ollamaTransport) = Self.client(baseURL: "http://127.0.0.1:11434/v1", apiKey: key, id: "ollama", responses: [.sse(Self.sse(["[DONE]"]))])
            _ = await Self.drain(ollama.stream(request))
            let local = try #require(ollamaTransport.requests.first)
            #expect(local.url?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
            #expect(local.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(try ollamaTransport.jsonBody(0)["max_tokens"] == 100)
        }

        // The field can be forced for servers that want the other one.
        let provider = ProviderConfig(id: "gemini", dialect: .openAIChat, baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/"))
        let forced = OpenAIChatClient(context: ProviderContext(provider: provider, apiKey: Self.fakeKey), maxTokensParameter: .maxCompletionTokens)
        #expect(forced.maxTokensParameter == .maxCompletionTokens)
        #expect(OpenAIChatClient(context: ProviderContext(provider: provider, apiKey: nil)).maxTokensParameter == .maxTokens)
    }

    @Test func toolImagesFollowTheRunOfToolResults() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let messages: [ChatMessage] = [
            .user(.text("Look")),
            .assistant("", toolCalls: [ToolCall(id: "a", name: "screenshot", arguments: "{}"), ToolCall(id: "b", name: "clock", arguments: "{}")]),
            ChatMessage(role: .tool, content: [.image(data: jpeg, mimeType: "image/jpeg")], toolCallID: "a"),
            .tool(callID: "b", result: "12:00"),
            .assistant("Got it."),
        ]
        let expected: [JSONValue] = [
            ["role": "user", "content": "Look"],
            ["role": "assistant", "content": .null, "tool_calls": [
                ["id": "a", "type": "function", "function": ["name": "screenshot", "arguments": "{}"]],
                ["id": "b", "type": "function", "function": ["name": "clock", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "a", "content": "The result is an image, attached in the next message."],
            ["role": "tool", "tool_call_id": "b", "content": "12:00"],
            ["role": "user", "content": [
                ["type": "text", "text": "Image returned by tool call a:"],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,/9j/"]],
            ]],
            ["role": "assistant", "content": "Got it."],
        ]
        #expect(OpenAIChatRequestEncoder.messages(messages) == expected)
    }

    // MARK: - Cancellation

    @Test(.timeLimit(.minutes(1))) func cancellingTheConsumerCancelsTheNetworkRead() async throws {
        let transport = HangingStreamTransport(firstChunk: Self.sse([
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#,
        ]))
        let client = OpenAIChatClient(context: ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil, http: transport))
        let (firstEvent, firstEventSignal) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var events: [ChatEvent] = []
            do {
                for try await event in client.stream(Self.simpleRequest) {
                    events.append(event)
                    firstEventSignal.yield()
                }
            } catch {}
            return events
        }
        for await _ in firstEvent { break }
        consumer.cancel()
        let events = await consumer.value
        #expect(events == [.textDelta("Hi")])

        _ = await waitUntil { transport.terminated }
        #expect(transport.terminated, "the response body stream should be cancelled when the consumer goes away")
    }
}


/// Adversarial cases added in review: byte-at-a-time delivery, servers that deviate from OpenAI's tool-call indexing,
/// OpenRouter's usage chunk, bodies that are not event streams, connections that stay open, and key redaction.
@Suite struct OpenAIChatAdversarialTests {
    typealias Base = OpenAIChatTests

    static func chunk(_ delta: String, finish: String? = nil, extra: String = "") -> String {
        #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":\#(delta),"logprobs":null,"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null")}]\#(extra)}"#
    }

    @Test func oneByteChunksWithCRLFCommentsAndNoSpaceAfterDataGiveTheSameEvents() async throws {
        let payloads = [
            Self.chunk(#"{"role":"assistant","content":"","reasoning_content":"Hmm, "}"#),
            Self.chunk(#"{"reasoning_content":"ünïcode 🤔"}"#),
            Self.chunk(#"{"content":"Sure — "}"#),
            Self.chunk(#"{"content":"pointing 👉"}"#),
            Self.chunk(#"{"tool_calls":[{"index":0,"id":"call_A","type":"function","function":{"name":"point_at","arguments":""}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":1,"id":"call_B","type":"function","function":{"name":"say","arguments":"{\"te"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":1,"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":1,"function":{"arguments":"xt\":\"é\"}"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"\"y\":2}"}}]}"#),
            Self.chunk("{}", finish: "tool_calls"),
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":3}}}"#,
            "[DONE]",
        ]
        // CRLF line endings, a keep-alive comment between events, and `data:` with no space after the colon.
        let body = ": keep-alive\r\n\r\n" + payloads.map { "data:\($0)\r\n\r\n" }.joined(separator: ": ping\r\n\r\n")
        let expected: [ChatEvent] = [
            .reasoningDelta("Hmm, "),
            .reasoningDelta("ünïcode 🤔"),
            .textDelta("Sure — "),
            .textDelta("pointing 👉"),
            .toolCallDelta(id: "call_B", name: "say", argumentsFragment: "{\"te"),
            .toolCallDelta(id: "call_A", name: "point_at", argumentsFragment: "{\"x\":1,"),
            .toolCallDelta(id: "call_B", name: "say", argumentsFragment: "xt\":\"é\"}"),
            .toolCallDelta(id: "call_A", name: "point_at", argumentsFragment: "\"y\":2}"),
            .toolCall(ToolCall(id: "call_A", name: "point_at", arguments: "{\"x\":1,\"y\":2}")),
            .toolCall(ToolCall(id: "call_B", name: "say", arguments: "{\"text\":\"é\"}")),
            .usage(TokenUsage(inputTokens: 7, cachedInputTokens: 3, outputTokens: 5)),
            .finished(.toolCalls),
        ]
        for size in [1, 2, 3, Data(body.utf8).count] {
            let (client, _) = Base.client(responses: [.sse(body, chunkSize: size)])
            let (events, error) = await Base.drain(client.stream(Base.simpleRequest))
            #expect(error == nil, "chunk size \(size)")
            #expect(events == expected, "chunk size \(size)")
        }
    }

    @Test func parallelCallsThatAllReuseIndexZeroStaySeparate() async throws {
        // Ollama: each parallel call arrives whole, every one with `index` 0 and its own id; in separate chunks
        // and, in the second body, together in one chunk.
        let separate = Base.sse([
            Self.chunk(#"{"role":"assistant","content":"","tool_calls":[{"id":"call_k1","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}"#),
            Self.chunk(#"{"role":"assistant","content":"","tool_calls":[{"id":"call_k2","index":0,"type":"function","function":{"name":"get_time","arguments":"{\"tz\":\"CET\"}"}}]}"#),
            Self.chunk("{}", finish: "tool_calls"),
            "[DONE]",
        ])
        let together = Base.sse([
            Self.chunk(#"{"role":"assistant","content":"","tool_calls":[{"id":"call_k1","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},{"id":"call_k2","index":0,"type":"function","function":{"name":"get_time","arguments":"{\"tz\":\"CET\"}"}}]}"#),
            Self.chunk("{}", finish: "tool_calls"),
            "[DONE]",
        ])
        for body in [separate, together] {
            let (client, _) = Base.client(baseURL: "http://127.0.0.1:11434/v1", apiKey: nil, id: "ollama", responses: [.sse(body, chunkSize: 1)])
            let (events, error) = await Base.drain(client.stream(Base.simpleRequest))
            #expect(error == nil)
            #expect(events.filter { if case .toolCall = $0 { true } else { false } } == [
                .toolCall(ToolCall(id: "call_k1", name: "get_weather", arguments: "{\"city\":\"Paris\"}")),
                .toolCall(ToolCall(id: "call_k2", name: "get_time", arguments: "{\"tz\":\"CET\"}")),
            ])
            #expect(events.last == .finished(.toolCalls))
        }
    }

    @Test func wholeCallsWithoutIndexOrIDStaySeparateAndGetDistinctIDs() async throws {
        // Gemini: no `index`, an empty `id`, two whole calls in one chunk, and `stop` as the finish reason.
        let body = Base.sse([
            #"{"choices":[{"delta":{"role":"assistant","tool_calls":[{"function":{"arguments":"{\"x\":1}","name":"point_at"},"id":"","type":"function"},{"function":{"arguments":"{}","name":"screenshot"},"id":"","type":"function"}]},"finish_reason":"stop","index":0}],"created":1,"model":"gemini-2.5-flash","object":"chat.completion.chunk"}"#,
            "[DONE]",
        ])
        let (client, _) = Base.client(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/", id: "gemini", responses: [.sse(body, chunkSize: 1)])
        let (events, error) = await Base.drain(client.stream(Base.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .toolCallDelta(id: "call_0", name: "point_at", argumentsFragment: "{\"x\":1}"),
            .toolCallDelta(id: "call_1", name: "screenshot", argumentsFragment: "{}"),
            .toolCall(ToolCall(id: "call_0", name: "point_at", arguments: "{\"x\":1}")),
            .toolCall(ToolCall(id: "call_1", name: "screenshot", arguments: "{}")),
            .finished(.toolCalls),
        ])

        // Without index or id, fragments that do not name a function still continue the latest call.
        let fragmented = Base.sse([
            Self.chunk(#"{"tool_calls":[{"type":"function","function":{"name":"say","arguments":"{\"text\":"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"function":{"arguments":"\"hi\"}"}}]}"#),
            Self.chunk("{}", finish: "tool_calls"),
            "[DONE]",
        ])
        let (fragClient, _) = Base.client(responses: [.sse(fragmented, chunkSize: 4)])
        let result = try await fragClient.complete(Base.simpleRequest)
        #expect(result.toolCalls == [ToolCall(id: "call_0", name: "say", arguments: "{\"text\":\"hi\"}")])
    }

    @Test func openRouterUsageChunkRepeatingTheFinishReasonAddsNoCallsAndUsageIsReportedOnce() async throws {
        let body = ": OPENROUTER PROCESSING\n\n" + Base.sse([
            Self.chunk(#"{"role":"assistant","content":"","tool_calls":[{"index":0,"id":"call_or","type":"function","function":{"name":"point_at","arguments":"{\"x\":3}"}}]}"#),
            Self.chunk(#"{"role":"assistant","content":""}"#, finish: "tool_calls", extra: #","usage":null"#),
            // OpenRouter keeps one choice in the usage chunk and repeats the finish reason there.
            Self.chunk(#"{"role":"assistant","content":""}"#, finish: "tool_calls",
                       extra: #","usage":{"prompt_tokens":40,"completion_tokens":9,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":0}}"#),
            "[DONE]",
        ])
        let (client, _) = Base.client(baseURL: "https://openrouter.ai/api/v1", id: "openrouter", responses: [.sse(body, chunkSize: 3)])
        let (events, error) = await Base.drain(client.stream(Base.simpleRequest))
        #expect(error == nil)
        #expect(events == [
            .toolCallDelta(id: "call_or", name: "point_at", argumentsFragment: "{\"x\":3}"),
            .toolCall(ToolCall(id: "call_or", name: "point_at", arguments: "{\"x\":3}")),
            .usage(TokenUsage(inputTokens: 40, outputTokens: 9)),
            .finished(.toolCalls),
        ])

        // Usage totals are cumulative; a server that repeats them must not be counted twice.
        let repeated = Base.sse([
            Self.chunk(#"{"content":"a"}"#, extra: #","usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}"#),
            Self.chunk(#"{"content":"b"}"#, finish: "stop", extra: #","usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}"#),
            "[DONE]",
        ])
        let (repeatClient, _) = Base.client(responses: [.sse(repeated)])
        let (repeatEvents, _) = await Base.drain(repeatClient.stream(Base.simpleRequest))
        #expect(repeatEvents == [.textDelta("a"), .textDelta("b"), .usage(TokenUsage(inputTokens: 5, outputTokens: 2)), .finished(.stop)])
    }

    @Test func successfulResponseThatIsNotAnEventStreamReportsWhatTheServerSaid() async throws {
        // A base URL pointing at a web app that answers every path with its index page.
        let (web, _) = Base.client(baseURL: "http://localhost:8080", apiKey: nil, id: "local",
                                   responses: [.body("<!doctype html><title>Open WebUI</title>", status: 200, contentType: "text/html")])
        let webError = try #require(await Base.drain(web.stream(Base.simpleRequest)).error as? ProviderError)
        #expect(webError.message == "The server did not send an event stream: <!doctype html><title>Open WebUI</title>")

        // A gateway that returns a JSON error with status 200.
        let (gateway, _) = Base.client(responses: [.body(#"{"error":{"message":"model `nope` not found","type":"invalid_request_error"}}"#, status: 200)])
        let gatewayError = try #require(await Base.drain(gateway.stream(Base.simpleRequest)).error as? ProviderError)
        #expect(gatewayError.message == "The server did not send an event stream: model `nope` not found")

        // Only keep-alive comments before the connection dropped: an ordinary truncated stream.
        let (dropped, _) = Base.client(responses: [.sse(": OPENROUTER PROCESSING\n\n")])
        let droppedError = try #require(await Base.drain(dropped.stream(Base.simpleRequest)).error as? ProviderError)
        #expect(droppedError.message == "The stream ended before the model finished its reply.")
    }

    @Test(.timeLimit(.minutes(1))) func doneEndsTheReplyEvenIfTheConnectionStaysOpen() async throws {
        let transport = HangingStreamTransport(firstChunk: Base.sse([Self.chunk(#"{"content":"bye"}"#, finish: "stop"), "[DONE]"]))
        let client = OpenAIChatClient(context: ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil, http: transport))
        let (events, error) = await Base.drain(client.stream(Base.simpleRequest))
        #expect(error == nil)
        #expect(events == [.textDelta("bye"), .finished(.stop)])
        try await transport.waitUntilTerminated()
        #expect(transport.terminated, "the open connection should be released after [DONE]")
    }

    @Test(.timeLimit(.minutes(1))) func consumerThatStopsIteratingReleasesTheConnection() async throws {
        let transport = HangingStreamTransport(firstChunk: Base.sse([Self.chunk(#"{"content":"one"}"#), Self.chunk(#"{"content":"two"}"#)]))
        let client = OpenAIChatClient(context: ProviderContext(provider: ProviderConfig(id: "p", dialect: .openAIChat), apiKey: nil, http: transport))
        var first: ChatEvent?
        for try await event in client.stream(Base.simpleRequest) {
            first = event
            break
        }
        #expect(first == .textDelta("one"))
        try await transport.waitUntilTerminated()
        #expect(transport.terminated, "dropping the stream should cancel the network read")
    }

    @Test func printingOrDumpingTheClientNeverShowsTheKeyOrHeaders() {
        let secret = "sk-live-should-never-print"
        let provider = ProviderConfig(id: "azure-ish", dialect: .openAIChat, baseURL: URL(string: "https://gateway.example/v1"),
                                      credential: "k", headers: ["api-key": "header-secret-value"])
        let client = OpenAIChatClient(context: ProviderContext(provider: provider, apiKey: secret))
        var dumped = ""
        dump(client, to: &dumped)
        let mirrored = Mirror(reflecting: client).children.map { "\($0.label ?? ""):\($0.value)" }.joined(separator: ",")
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped, mirrored] {
            #expect(!text.contains(secret))
            #expect(!text.contains("header-secret-value"))
        }
        #expect(String(describing: client).contains("azure-ish"))
        #expect(mirrored.contains("hasAPIKey:true"))
    }
}

/// A server that sends one chunk and then holds the connection open, recording when the client lets go of it.
private final class HangingStreamTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var didTerminate = false
    private let firstChunk: Data

    init(firstChunk: String) { self.firstChunk = Data(firstChunk.utf8) }

    var terminated: Bool { lock.withLock { didTerminate } }

    /// Polls for up to ten seconds (a hang guard); termination happens on another task, shortly after the client lets go.
    func waitUntilTerminated() async throws {
        _ = await waitUntil { terminated }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let chunk = firstChunk
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { _ in self.lock.withLock { self.didTerminate = true } }
            continuation.yield(chunk)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        return (stream, response)
    }
}
