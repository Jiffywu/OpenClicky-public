import Foundation
import Testing
@testable import OpenClickyKit

/// Adversarial checks for the OpenAI Responses adapter, added in review: hostile chunking and framing, interleaved
/// reasoning items, untrusted numbers, cancellation before response headers, and key redaction.
@Suite struct OpenAIResponsesAdversarialTests {
    static let fakeKey = "sk-test-review-placeholder-7f3a"

    static func client(_ transport: any HTTPTransport, apiKey: String? = fakeKey) -> OpenAIResponsesClient {
        let provider = ProviderConfig(id: "openai", dialect: .openAIResponses, credential: "openai")
        return OpenAIResponsesClient(context: ProviderContext(provider: provider, apiKey: apiKey, http: transport))
    }

    static let request = ChatRequest(model: "gpt-6-astra", messages: [.user(.text("Weather in Zürich?"))])

    static func collect(_ stream: AsyncThrowingStream<ChatEvent, Error>) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Every byte its own chunk, CRLF line endings, a data-only event (no `event:` line), a payload split over
    /// several `data:` lines, `id:` lines, keep-alive comments, `obfuscation` fields, multibyte UTF-8 inside
    /// tool-call arguments, a refusal delta, and a `[DONE]` sentinel after `response.completed`.
    @Test func oneByteChunksWithHostileFraming() async throws {
        let fragments = ["{\"city\":\"Z", "ü", "rich 🌧", "\",\"unit\":\"°C\"}"]
        let finalArguments = fragments.joined()
        let escapedFinal = JSONValue.string(finalArguments).jsonString()
        var body = ""
        body += ": keep-alive\r\n\r\n"
        body += "event: response.output_item.added\r\nid: 1\r\n"
        body += #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_z","call_id":"call_z","name":"get_weather","arguments":"","status":"in_progress"},"sequence_number":1}"# + "\r\n\r\n"
        for (i, fragment) in fragments.enumerated() {
            // Data-only events: the type comes from the JSON, not an `event:` line.
            body += #"data: {"type":"response.function_call_arguments.delta","item_id":"fc_z","output_index":0,"delta":\#(JSONValue.string(fragment).jsonString()),"obfuscation":"aB3","sequence_number":\#(i + 2)}"# + "\r\n\r\n"
            body += ": ping\r\n\r\n"
        }
        // One event's JSON spread over three `data:` lines; SSE joins them with "\n", which is JSON whitespace.
        body += "event: response.function_call_arguments.done\r\n"
        body += "data: {\"type\":\"response.function_call_arguments.done\",\r\n"
        body += "data:  \"item_id\":\"fc_z\",\"output_index\":0,\r\n"
        body += "data:  \"arguments\":\(escapedFinal),\"sequence_number\":7}\r\n\r\n"
        body += "event: response.refusal.delta\r\n"
        body += #"data: {"type":"response.refusal.delta","item_id":"msg_r","output_index":1,"content_index":0,"delta":"I can’t share that.","sequence_number":8}"# + "\r\n\r\n"
        body += "event: response.completed\r\n"
        body += #"data: {"type":"response.completed","response":{"id":"resp_z","object":"response","status":"completed","output":[{"type":"function_call","id":"fc_z","call_id":"call_z","name":"get_weather","arguments":\#(escapedFinal),"status":"completed"}],"usage":{"input_tokens":9,"output_tokens":5,"input_tokens_details":{"cached_tokens":0}}},"sequence_number":9}"# + "\r\n\r\n"
        body += "data: [DONE]\r\n\r\n"

        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body, chunkSize: 1)])).stream(Self.request))
        let expected: [ChatEvent] =
            fragments.map { .toolCallDelta(id: "call_z", name: "get_weather", argumentsFragment: $0) }
            + [.toolCall(ToolCall(id: "call_z", name: "get_weather", arguments: finalArguments)),
               .textDelta("I can’t share that."),
               .usage(TokenUsage(inputTokens: 9, outputTokens: 5)),
               .finished(.toolCalls)]
        #expect(events == expected)
        #expect(try JSONValue.parse(finalArguments) == ["city": "Zürich 🌧", "unit": "°C"])
    }

    /// Two reasoning items in one response (summary text, then raw reasoning text) are separated like summary
    /// parts are, and an empty first part does not produce a leading break.
    @Test(arguments: [1, 7, 100_000])
    func separatesReasoningAcrossItemsAndParts(chunkSize: Int) async throws {
        let body = [
            #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_a","type":"reasoning","summary":[]},"sequence_number":1}"#,
            #"{"type":"response.reasoning_summary_part.added","item_id":"rs_a","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""},"sequence_number":2}"#,
            #"{"type":"response.reasoning_summary_part.added","item_id":"rs_a","output_index":0,"summary_index":1,"part":{"type":"summary_text","text":""},"sequence_number":3}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_a","output_index":0,"summary_index":1,"delta":"First ","sequence_number":4}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_a","output_index":0,"summary_index":1,"delta":"thought.","sequence_number":5}"#,
            #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg_c","type":"message","status":"in_progress","role":"assistant","content":[]},"sequence_number":6}"#,
            #"{"type":"response.output_text.delta","item_id":"msg_c","output_index":1,"content_index":0,"delta":"Checking.","sequence_number":7,"logprobs":[]}"#,
            #"{"type":"response.output_item.added","output_index":2,"item":{"id":"rs_b","type":"reasoning","summary":[]},"sequence_number":8}"#,
            #"{"type":"response.reasoning_summary_part.added","item_id":"rs_b","output_index":2,"summary_index":0,"part":{"type":"summary_text","text":""},"sequence_number":9}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_b","output_index":2,"summary_index":0,"delta":"Second thought.","sequence_number":10}"#,
            #"{"type":"response.reasoning_text.delta","item_id":"rs_b","output_index":2,"content_index":0,"delta":"raw","sequence_number":11}"#,
            #"{"type":"response.completed","response":{"id":"resp_r","object":"response","status":"completed","output":[],"usage":null},"sequence_number":12}"#,
        ].map { "data: \($0)\n\n" }.joined()
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body, chunkSize: chunkSize)])).stream(Self.request))
        #expect(events == [
            .reasoningDelta("First "), .reasoningDelta("thought."),
            .textDelta("Checking."),
            .reasoningDelta("\n\n"), .reasoningDelta("Second thought."),
            .reasoningDelta("\n\n"), .reasoningDelta("raw"),
            .finished(.stop),
        ])
    }

    /// Numbers come from the network. One too large for `Int` must not trap.
    @Test func hugeNumbersDoNotCrash() async throws {
        let body = [
            #"{"type":"response.output_item.added","output_index":1e300,"item":{"type":"function_call","id":"fc_h","call_id":"call_h","name":"noop","arguments":""}}"#,
            #"{"type":"response.function_call_arguments.delta","item_id":"fc_h","output_index":1e300,"delta":"{}"}"#,
            #"{"type":"response.reasoning_summary_part.added","item_id":"rs_h","output_index":1e300,"summary_index":1e300,"part":{"type":"summary_text","text":""}}"#,
            #"{"type":"response.output_item.done","output_index":1e300,"item":{"type":"function_call","id":"fc_h","call_id":"call_h","name":"noop","arguments":"{}","status":"completed"}}"#,
            #"{"type":"response.completed","response":{"id":"resp_h","status":"completed","output":[],"usage":{"input_tokens":1e300,"output_tokens":-1e300,"input_tokens_details":{"cached_tokens":1.5}}}}"#,
        ].map { "data: \($0)\n\n" }.joined()
        let events = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.request))
        #expect(events.contains(.toolCall(ToolCall(id: "call_h", name: "noop", arguments: "{}"))))
        #expect(events.last == .finished(.toolCalls))
    }

    @Test func hugeStatusInErrorEventDoesNotCrash() async throws {
        let body = "data: " + #"{"type":"error","status":1e300,"error":{"message":"Overloaded","code":"server_overloaded"}}"# + "\n\n"
        do {
            _ = try await Self.collect(Self.client(FakeHTTPTransport([.sse(body)])).stream(Self.request))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == nil)
            #expect(error.message == "Overloaded (server_overloaded)")
        }
    }

    /// Error bodies from `/responses`-compatible servers that are not OpenAI's nested shape still yield the message.
    @Test(arguments: [
        (#"{"error":"model 'llama9' not found"}"#, "model 'llama9' not found"),
        (#"{"object":"error","message":"max_tokens is too large","type":"BadRequestError","param":null,"code":400}"#, "max_tokens is too large"),
        (#"{"error":{"message":"Unsupported parameter: 'temperature' is not supported with this model.","type":"invalid_request_error","param":"temperature","code":"unsupported_parameter"}}"#,
         "Unsupported parameter: 'temperature' is not supported with this model. (unsupported_parameter)"),
    ])
    func httpErrorBodyVariants(body: String, message: String) async throws {
        let transport = FakeHTTPTransport([.body(body, status: 400)])
        do {
            _ = try await Self.collect(Self.client(transport).stream(Self.request))
            Issue.record("expected an error")
        } catch let error as ProviderError {
            #expect(error.status == 400)
            #expect(error.message == message)
        }
    }

    /// Cancelling while the request is still waiting for response headers cancels the request itself.
    @Test func cancellingBeforeHeadersCancelsTheRequest() async throws {
        let transport = NeverRespondingTransport()
        let client = Self.client(transport)
        let consumer = Task { try await Self.collect(client.stream(Self.request)) }
        _ = await waitUntil { transport.started }
        #expect(transport.started)
        consumer.cancel()
        _ = await consumer.result
        _ = await waitUntil { transport.cancelled }
        #expect(transport.cancelled)
    }

    /// Dropping the stream without iterating it to the end (a consumer that `break`s) also cancels the network.
    @Test func breakingOutOfTheLoopCancelsTheNetworkStream() async throws {
        let first = "data: " + #"{"type":"response.output_text.delta","item_id":"m","output_index":0,"content_index":0,"delta":"Hi","sequence_number":1,"logprobs":[]}"# + "\n\n"
        let transport = OpenStreamTransport(firstChunk: Data(first.utf8))
        let client = Self.client(transport)
        let firstEvent: ChatEvent? = try await {
            for try await event in client.stream(Self.request) { return event }
            return nil
        }()
        #expect(firstEvent == .textDelta("Hi"))
        _ = await waitUntil { transport.terminated }
        #expect(transport.terminated)
    }

    /// Logging or dumping the client must not reveal the key.
    @Test func describingTheClientDoesNotRevealTheKey() {
        let client = Self.client(FakeHTTPTransport([]))
        var dumped = ""
        dump(client, to: &dumped)
        for text in [String(describing: client), String(reflecting: client), "\(client)", dumped] {
            #expect(!text.contains(Self.fakeKey))
            #expect(!text.contains("sk-test"))
        }
        #expect(String(describing: client).contains("openai"))
        // The key is still sent where it belongs.
        #expect(client.makeURLRequest(Self.request).value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeKey)")
    }
}

/// `stream(for:)` never returns, like a server that has not sent headers yet. Records when its caller is cancelled.
private final class NeverRespondingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        lock.withLock { didStart = true }
        let (wait, waitContinuation) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in wait {}
        } onCancel: { [weak self] in
            self?.lock.withLock { self?.didCancel = true }
            waitContinuation.finish()
        }
        throw CancellationError()
    }
}

/// Sends one chunk, then stays open until the reader goes away.
private final class OpenStreamTransport: HTTPTransport, @unchecked Sendable {
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
