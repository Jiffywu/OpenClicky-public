// OpenAI Responses API adapter (dialect "openai-responses"): `POST {baseURL}/responses` with `stream: true`.
//
// Wire protocol checked on 2026-10-30 against OpenAI's primary docs:
// - Create request: https://developers.openai.com/api/reference/resources/responses/methods/create
// - Streaming events: https://developers.openai.com/api/reference/resources/responses/streaming-events
// - Streaming function calls: https://developers.openai.com/api/docs/guides/function-calling#streaming
// - Reasoning effort, summaries, stateless (`store: false`) use: https://developers.openai.com/api/docs/guides/reasoning
// - Image inputs as data URLs: https://developers.openai.com/api/docs/guides/images-vision
// - Bearer authentication: https://developers.openai.com/api/reference/overview
// - Error event with a nested `error` object: https://developers.openai.com/api/docs/guides/websocket-mode
// - HTTP error body `{"error": {"message", "type", "param", "code"}}`: `ErrorResponse` in
//   https://github.com/openai/openai-openapi (manual_spec/openapi.yaml)

import Foundation

/// Streams chat turns from the OpenAI Responses API, or any server that speaks it (set `baseURL`).
///
/// Requests are stateless (`store: false`): the whole conversation is sent each turn, and nothing is kept on
/// OpenAI's side for later retrieval.
///
/// Reasoning and phases round-trip through `ChatMessage.providerItems`. In stateless mode reasoning items carry
/// `encrypted_content` (https://developers.openai.com/api/docs/guides/reasoning: "pass in all reasoning items from a
/// previous response into the next one"), and assistant messages carry `phase` ("If you replay assistant history
/// manually, preserve each original `phase` value"). So when a reply holds an encrypted reasoning item or a phased
/// message, the adapter emits `.providerItems(dialect: "openai-responses", items:)` at the end with the response's
/// whole `output` in order (reasoning items without `encrypted_content` left out, since a stateless request cannot
/// resolve them). Sent back on an assistant message whose text and tool calls still match them, those items replace
/// the message and tool calls the adapter would otherwise rebuild, so order and phases come back exactly. An edited
/// message is rebuilt from its text, `phase` and tool calls instead, without reasoning.
public struct OpenAIResponsesClient: LanguageModelClient {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    /// `ChatEvent.providerItems` / `ChatMessage.providerDialect` tag for this adapter's items.
    public static let dialect = ProviderDialect.openAIResponses.rawValue

    public let context: ProviderContext
    let options: Options

    struct Options: Sendable, Hashable {
        var reasoningSummary: String?
        var imageDetail: String
        var strictTools: Bool
        /// Explicit choice for `include: ["reasoning.encrypted_content"]`; nil decides per request (see `init`).
        var includeEncryptedReasoning: Bool? = nil
        /// The base URL is OpenAI's own API (or unset, which defaults to it).
        var isOpenAIHost: Bool = true

        /// Whether a request asks for encrypted reasoning.
        func includesEncryptedReasoning(for request: ChatRequest) -> Bool {
            includeEncryptedReasoning ?? (isOpenAIHost && (request.reasoningEffort != nil || reasoningSummary != nil))
        }
    }

    /// - Parameters:
    ///   - reasoningSummary: `reasoning.summary` ("auto", "concise" or "detailed"). Summaries are what arrive as
    ///     `.reasoningDelta`. Off by default because OpenAI may require organization verification before it
    ///     returns them, and asking for them unverified fails the request.
    ///   - imageDetail: `detail` sent with every image ("low", "high", "auto" or "original").
    ///   - strictTools: `strict` on function tools. Strict mode needs every schema to list all properties as
    ///     required and set `additionalProperties: false`, which arbitrary tool schemas often don't, so it is off.
    ///   - includeEncryptedReasoning: Send `include: ["reasoning.encrypted_content"]`. OpenAI now returns encrypted
    ///     reasoning by default in stateless mode and accepts the value "for compatibility"; compatible servers may
    ///     not know it. Nil sends it to OpenAI's own API when the request sets a reasoning effort (or a summary is
    ///     asked for), and never to other servers.
    public init(context: ProviderContext, reasoningSummary: String? = nil, imageDetail: String = "auto", strictTools: Bool = false,
                includeEncryptedReasoning: Bool? = nil) {
        self.context = context
        let host = context.provider.baseURL?.host()?.lowercased()
        self.options = Options(reasoningSummary: reasoningSummary, imageDetail: imageDetail, strictTools: strictTools,
                               includeEncryptedReasoning: includeEncryptedReasoning,
                               isOpenAIHost: host == nil || host == "api.openai.com")
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let context = self.context
        let urlRequest = makeURLRequest(request)
        let provider = context.provider.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: AsyncThrowingStream<Data, Error>
                    do {
                        body = try await context.http.checkedStream(for: urlRequest, provider: provider)
                    } catch let error as ProviderError {
                        throw OpenAIResponsesEventDecoder.refineHTTPError(error)
                    }
                    var decoder = OpenAIResponsesEventDecoder(provider: provider)
                    for try await sse in body.serverSentEvents() {
                        for event in try decoder.decode(sse) { continuation.yield(event) }
                        if decoder.isFinished { break }
                    }
                    try Task.checkCancellation()
                    guard decoder.isFinished else {
                        throw ProviderError(provider: provider, message: "The response stream ended before response.completed.")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The HTTP request for one turn. The API key goes only into the `Authorization` header.
    func makeURLRequest(_ request: ChatRequest) -> URLRequest {
        var headers = ["Accept": "text/event-stream"]
        if let key = context.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let body = OpenAIResponsesRequestEncoder(options: options).body(for: request)
        return context.jsonRequest(context.url("responses", default: Self.defaultBaseURL), body: body, headers: headers)
    }
}

/// `print`, string interpolation, `dump` and debugger summaries would otherwise reflect `context.apiKey` verbatim.
/// These show where the client points and whether it has a key, never the key itself (or extra header values).
extension OpenAIResponsesClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenAIResponsesClient(provider: \(context.provider.id), url: \(endpoint), apiKey: \(keyState))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "provider": context.provider.id,
            "url": endpoint,
            "apiKey": keyState,
            "extraHeaderNames": (context.provider.headers ?? [:]).keys.sorted(),
            "reasoningSummary": options.reasoningSummary as Any,
            "imageDetail": options.imageDetail,
            "strictTools": options.strictTools,
        ], displayStyle: .struct)
    }

    /// The endpoint without a user, password or query, which can hold a credential.
    private var endpoint: String { ProviderContext.redacted(context.url("responses", default: Self.defaultBaseURL)) }
    private var keyState: String { context.apiKey?.isEmpty == false ? "<redacted>" : "none" }
}
