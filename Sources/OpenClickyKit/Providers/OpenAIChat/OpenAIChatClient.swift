import Foundation

// OpenAI-compatible Chat Completions, streamed. Wire format checked on 2026-10-30 against:
// - https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
// - https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
// - https://github.com/openai/openai-python/blob/main/src/openai/_streaming.py
//     (any data object with a truthy `error` key is an error; `error.message` carries the text)
// - https://openrouter.ai/docs/api/reference/streaming (`: OPENROUTER PROCESSING` comments, mid-stream
//     `error` object with `finish_reason: "error"`, pre-stream `{"error":{"code","message"}}`, and a final usage
//     chunk that, unlike OpenAI's, keeps one choice repeating the finish reason)
// - https://openrouter.ai/docs/api/reference/parameters (top-level `reasoning_effort`, `max_tokens`)
// - https://openrouter.ai/docs/guides/best-practices/reasoning-tokens (`delta.reasoning_details`)
// - https://docs.vllm.ai/en/latest/features/reasoning_outputs.html (`delta.reasoning`, formerly `reasoning_content`)
// - https://docs.ollama.com/api/openai-compatibility (`reasoning_effort`, `max_tokens`, data-URL images, key ignored)
// - https://ai.google.dev/gemini-api/docs/openai (base URL, `reasoning_effort`, data-URL images, streaming tools)
// - https://lmstudio.ai/docs/developer/api-changelog (`delta.reasoning` for gpt-oss, separate reasoning for R1)
// - https://github.com/ollama/ollama/blob/main/openai/openai.go (Ollama's chunk structs: `delta.reasoning`,
//     tool-call `index` taken from the model's parser, `stop` rewritten to `tool_calls`, `{"error":{…}}` bodies)
// Not documentation, but reports of how real servers deviate, handled in OpenAIChatStreamDecoder.slot(for:):
// - https://github.com/vercel/ai/pull/14277 (Ollama streams every parallel tool call with `index` 0)
// - https://discuss.ai.google.dev/t/gemini-openai-compatibility-issue-with-tool-call-streaming/59886
//     (Gemini's tool-call deltas carry no `index`)

/// The brain slot's adapter for the `openai-chat` dialect: OpenAI, OpenRouter, Ollama, LM Studio, vLLM and
/// Gemini's OpenAI-compatible endpoint. Streams `POST {baseURL}/chat/completions` and turns the chunks into
/// `ChatEvent`s as they arrive.
public struct OpenAIChatClient: LanguageModelClient {
    /// Which request field carries `ChatRequest.maxOutputTokens`. OpenAI deprecated `max_tokens` and rejects it
    /// for reasoning models; Ollama, LM Studio and most other compatible servers document only `max_tokens`.
    public enum MaxTokensParameter: String, Sendable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
    }

    public static let defaultBaseURL = "https://api.openai.com/v1"

    private let context: ProviderContext
    public let maxTokensParameter: MaxTokensParameter

    /// - Parameter maxTokensParameter: nil picks `max_completion_tokens` for api.openai.com (the default base URL)
    ///   and `max_tokens` for every other server.
    public init(context: ProviderContext, maxTokensParameter: MaxTokensParameter? = nil) {
        self.context = context
        self.maxTokensParameter = maxTokensParameter ?? Self.defaultMaxTokensParameter(for: context.provider.baseURL)
    }

    static func defaultMaxTokensParameter(for baseURL: URL?) -> MaxTokensParameter {
        guard let host = baseURL?.host()?.lowercased() else { return .maxCompletionTokens }
        return host == "api.openai.com" ? .maxCompletionTokens : .maxTokens
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let context = self.context
        let maxTokensParameter = self.maxTokensParameter
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = Self.urlRequest(for: request, context: context, maxTokensParameter: maxTokensParameter)
                    let body = try await Self.openStream(urlRequest, context: context)
                    var parser = SSEParser()
                    var decoder = OpenAIChatStreamDecoder(provider: context.provider.id)
                    // The start of the body, kept until the first event, so that a 2xx reply that is not an event
                    // stream (a web page at a wrong base URL, a JSON error) is reported with what the server said.
                    var bodyStart = Data()
                    var sawEvent = false
                    // Reading the transport directly, without an intermediate task, means that cancelling this task
                    // or leaving the loop ends the network read straight away.
                    reading: for try await chunk in body {
                        if !sawEvent, bodyStart.count < Self.bodyStartLimit {
                            bodyStart.append(chunk.prefix(Self.bodyStartLimit - bodyStart.count))
                        }
                        for event in parser.feed(chunk) {
                            sawEvent = true
                            for chatEvent in try decoder.consume(event.data) { continuation.yield(chatEvent) }
                            if decoder.isDone { break reading }
                        }
                    }
                    // A cancelled consumer ends the read early; that is not a truncated reply.
                    try Task.checkCancellation()
                    if !decoder.isDone {
                        for event in parser.finish() {
                            sawEvent = true
                            for chatEvent in try decoder.consume(event.data) { continuation.yield(chatEvent) }
                        }
                    }
                    if !sawEvent, let error = Self.notAnEventStream(bodyStart, provider: context.provider.id) { throw error }
                    for chatEvent in try decoder.finish() { continuation.yield(chatEvent) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let bodyStartLimit = 4_096

    /// The error for a successful response whose body had no `data:` events. Nil when the body was empty or held
    /// only SSE comments, which is an ordinary dropped stream.
    static func notAnEventStream(_ bodyStart: Data, provider: String) -> ProviderError? {
        let text = String(decoding: bodyStart, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix(":") else { return nil }
        return ProviderError(provider: provider, message: "The server did not send an event stream: \(errorMessage(fromBody: text))")
    }

    static func urlRequest(for request: ChatRequest, context: ProviderContext, maxTokensParameter: MaxTokensParameter) -> URLRequest {
        var headers = ["Accept": "text/event-stream"]
        // Local servers (Ollama, LM Studio, vLLM) need no key; send the header only when there is one.
        if let apiKey = context.apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let url = context.url("chat/completions", default: defaultBaseURL)
        let body = OpenAIChatRequestEncoder.body(for: request, maxTokensParameter: maxTokensParameter)
        return context.jsonRequest(url, body: body, headers: headers)
    }

    /// Opens the response body, turning a non-2xx status into a ProviderError that carries the provider's own message.
    private static func openStream(_ request: URLRequest, context: ProviderContext) async throws -> AsyncThrowingStream<Data, Error> {
        do {
            return try await context.http.checkedStream(for: request, provider: context.provider.id)
        } catch let error as ProviderError where error.status != nil {
            throw ProviderError(provider: error.provider, status: error.status, message: errorMessage(fromBody: error.message))
        }
    }

    /// The human-readable message from an error body. Handles `{"error":{"message":…}}` (OpenAI, OpenRouter, Ollama,
    /// vLLM), `{"error":"…"}` (LM Studio), a bare `{"message":…}`, and the same wrapped in a one-element array (some
    /// gateways); anything else is returned as trimmed text.
    static func errorMessage(fromBody body: String) -> String {
        if var json = try? JSONValue.parse(body) {
            if let first = json.arrayValue?.first { json = first }
            if let message = json["error"]?["message"]?.stringValue, !message.isEmpty { return message }
            if let message = json["error"]?.stringValue, !message.isEmpty { return message }
            if let message = json["message"]?.stringValue, !message.isEmpty { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The server returned an error with an empty body." : String(trimmed.prefix(2_000))
    }
}

/// Printing, `dump` and debugger views show the provider and options but never the API key or the provider's extra
/// headers, which can carry credentials too.
extension OpenAIChatClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenAIChatClient(provider: \(context.provider.id), url: \(redactedURL), "
            + "maxTokensParameter: \(maxTokensParameter.rawValue))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "provider": context.provider.id,
            "url": redactedURL,
            "hasAPIKey": context.apiKey.map { !$0.isEmpty } ?? false,
            "maxTokensParameter": maxTokensParameter,
        ], displayStyle: .struct)
    }

    /// The endpoint without a user, password or query, which can hold a credential.
    private var redactedURL: String { ProviderContext.redacted(context.url("chat/completions", default: Self.defaultBaseURL)) }
}
