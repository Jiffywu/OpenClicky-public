// Deepgram live transcription for the stt slot (dialect "deepgram-listen").
//
// Wire protocol checked on 2026-10-30 against Deepgram's documentation:
//   https://developers.deepgram.com/reference/speech-to-text/listen-streaming  URL, query parameters, all message schemas
//   https://developers.deepgram.com/docs/authenticating                       "Authorization: Token <key>"
//   https://developers.deepgram.com/docs/live-streaming-audio                 Results payload
//   https://developers.deepgram.com/docs/audio-keep-alive                     {"type":"KeepAlive"}, text frame, every 3-5 s
//   https://developers.deepgram.com/docs/close-stream                         {"type":"CloseStream"}: last results, Metadata, close
//   https://developers.deepgram.com/docs/understand-endpointing-interim-results  is_final / speech_final
//   https://developers.deepgram.com/docs/understanding-end-of-speech-detection   speech_final vs UtteranceEnd
//   https://developers.deepgram.com/docs/utterance-end, /docs/speech-started, /docs/endpointing
//   https://developers.deepgram.com/docs/keyterm, /docs/keywords              keyterm on Nova-3, keywords on older models
//   https://developers.deepgram.com/docs/stt-troubleshooting-websocket-data-and-net-errors  close codes, empty frames,
//                                                                            failed upgrades (HTTP 4xx/5xx + dg-error)
//   https://developers.deepgram.com/docs/errors                               err_code / err_msg error bodies
// Re-checked 2026-10-30 in review: the reference's AsyncAPI schema also lists Finalize and Configure (client) and
// ConfigureSuccess / ConfigureFailure (server). This adapter sends neither Finalize nor Configure, so it never gets
// the Configure replies; they map to nothing if they ever arrive.
//
// Not supported here: Flux (`flux-*` models), which Deepgram serves on `/v2/listen` with a different message set.

import Foundation

/// Streams 16 kHz mono PCM to Deepgram's `/v1/listen` WebSocket and turns its results into transcript events.
public struct DeepgramListenClient: SpeechToTextClient {
    public static let defaultURL = "wss://api.deepgram.com/v1/listen"
    public static let defaultModel = "nova-3"
    /// The keywords doc limits a request to 100 keywords. The keyterm doc's hard limit is 500 tokens across all
    /// keyterms (the stream is refused past it) and it describes the feature as boosting "up to 100" terms, so 100
    /// terms is the cap for both. 100 long phrases can still pass 500 tokens; the adapter cannot count Deepgram's tokens.
    static let maxSearchTerms = 100

    public struct Options: Sendable, Hashable {
        /// Milliseconds of silence before a result is marked `speech_final`. Nil leaves Deepgram's default (10 ms).
        public var endpointingMs: Int?
        /// Milliseconds of word gap before Deepgram sends `UtteranceEnd` (documented range 1000-5000). Nil turns it off.
        public var utteranceEndMs: Int?
        /// How long the stream may go without audio before a KeepAlive is sent. Deepgram suggests 3-5 s and closes
        /// the stream after 10 s with nothing received. Zero or less turns KeepAlive off.
        public var keepAliveInterval: Duration
        /// How long `finish()` waits for Deepgram to flush its last results and close before giving up.
        public var finishTimeout: Duration

        public init(endpointingMs: Int? = 300, utteranceEndMs: Int? = 1000,
                    keepAliveInterval: Duration = .seconds(4), finishTimeout: Duration = .seconds(5)) {
            self.endpointingMs = endpointingMs
            self.utteranceEndMs = utteranceEndMs
            self.keepAliveInterval = keepAliveInterval
            self.finishTimeout = finishTimeout
        }
    }

    public let context: ProviderContext
    public let model: String
    public let options: Options

    public init(context: ProviderContext, model: String = DeepgramListenClient.defaultModel, options: Options = Options()) {
        self.context = context
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.options = options
    }

    public var inputFormat: PCMFormat { .speech16k }

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let request = makeRequest(language: language, keywords: keywords)
        let connection: any WebSocketConnection
        do {
            connection = try await context.webSocket.connect(request)
        } catch {
            throw DeepgramListenSession.providerError(error, provider: context.provider.id, while: "connecting")
        }
        let session = DeepgramListenSession(connection: connection, provider: context.provider.id, options: options)
        await session.start()
        return session
    }

    // MARK: - Request

    /// The WebSocket upgrade request: listen URL with the stream's settings, provider headers and the API key.
    func makeRequest(language: String?, keywords: [String]) -> URLRequest {
        var request = URLRequest(url: listenURL(language: language, keywords: keywords))
        for (name, value) in context.provider.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Keyless self-hosted Deepgram is possible, so a missing key sends no header rather than failing here.
        if let key = context.apiKey, !key.isEmpty {
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func listenURL(language: String?, keywords: [String]) -> URL {
        let base = context.url("", default: Self.defaultURL)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents(string: Self.defaultURL)!
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        // ProviderConfig describes base URLs as "including the version path", while the shipped default names the
        // full endpoint. Accept both: add /listen (or /v1/listen to a bare host) unless the path already ends in it.
        let path = components.path
        if path.isEmpty || path == "/" {
            components.path = "/v1/listen"
        } else if !path.hasSuffix("/listen") {
            components.path = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/listen"
        }

        var items: [(String, String)] = [
            ("model", model),
            ("encoding", "linear16"),
            ("sample_rate", String(inputFormat.sampleRate)),
            ("channels", String(inputFormat.channels)),
            ("interim_results", "true"),
            ("smart_format", "true"),
            ("punctuate", "true"),
            ("vad_events", "true"),
        ]
        if let ms = options.utteranceEndMs { items.append(("utterance_end_ms", String(ms))) }
        if let ms = options.endpointingMs { items.append(("endpointing", String(ms))) }
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            items.append(("language", language))
        }
        // Repeat the parameter once per term; commas or semicolons would make one literal term (keyterm doc).
        let termParameter = Self.usesKeyterm(model) ? "keyterm" : "keywords"
        items += Self.searchTerms(keywords).map { (termParameter, $0) }

        let query = items.map { "\(Self.queryEncode($0.0))=\(Self.queryEncode($0.1))" }.joined(separator: "&")
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + query
        } else {
            components.percentEncodedQuery = query
        }
        return components.url ?? URL(string: Self.defaultURL)!
    }

    /// Keyterm prompting is Nova-3 only; Nova-2, Nova-1, Enhanced and Base take `keywords` instead.
    static func usesKeyterm(_ model: String) -> Bool { model.lowercased().hasPrefix("nova-3") }

    /// Trimmed, non-empty, de-duplicated terms, capped at Deepgram's documented limit.
    static func searchTerms(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for keyword in keywords {
            let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == maxSearchTerms { break }
        }
        return terms
    }

    /// Percent-encodes everything outside RFC 3986's unreserved set, so `+`, `&`, `:` and spaces in terms survive
    /// (URLComponents leaves `+`, which servers read as a space).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func queryEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: - Errors

    /// The readable part of a Deepgram error object. Streaming `Error` frames carry `variant` and `description`
    /// (listen-streaming reference); REST and failed-upgrade bodies carry `err_code` / `err_msg`, or `category` /
    /// `message` / `details` (errors doc). All documented shapes are read.
    static func errorMessage(_ json: JSONValue) -> String {
        let code = json["variant"]?.stringValue ?? json["err_code"]?.stringValue ?? json["category"]?.stringValue
            ?? json["code"]?.stringValue
        let text = json["description"]?.stringValue ?? json["err_msg"]?.stringValue ?? json["message"]?.stringValue
            ?? json["details"]?.stringValue
        switch (code, text) {
        case let (code?, text?): return "\(code): \(text)"
        case let (nil, text?): return text
        case let (code?, nil): return code
        case (nil, nil): return "Deepgram reported an error"
        }
    }
}

// MARK: - Redaction

/// `context` carries the API key, and Swift's default description of a struct prints every stored property, so
/// `print(client)`, `"\(client)"` or `dump(client)` would show the key. Describe the client without it.
extension DeepgramListenClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let key = (context.apiKey?.isEmpty == false) ? "set" : "none"
        return "DeepgramListenClient(provider: \(context.provider.id), model: \(model), apiKey: \(key))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "options": options], displayStyle: .struct)
    }
}
