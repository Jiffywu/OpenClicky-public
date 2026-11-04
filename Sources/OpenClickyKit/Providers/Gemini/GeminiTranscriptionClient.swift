// Gemini batch transcription: one whole press as a WAV file, for the ears' fallback when the Gemini Live stream
// fails (HeyClicky sends the press to its own `/brain/ears/transcribe`; OpenClicky asks Gemini directly with the
// user's key).
//
// Checked on 2026-10-31 against Google's pages:
//   https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe   unary model id, up to 1 hour of audio,
//     custom vocabulary up to 1,000 terms, no thinking
//   https://ai.google.dev/gemini-api/docs/transcribe                     `POST {base}/v1beta/interactions`,
//     `generation_config.transcription_config` with `language_codes` and `custom_vocabulary`; the text is at
//     `steps[type=model_output].content[type=text].text`
//   https://ai.google.dev/api/interactions-api                           `AudioContent` {type: "audio", data
//     (base64) or uri, mime_type: "audio/wav" …}
// Live check (2026-10-31): a 2 s macOS `say` clip as 16 kHz WAV came back exact in 1.03 s.

import Foundation

/// Transcribes a recording with Gemini's unary transcription model (the batch side of `gemini-3.5-transcribe-live`).
public struct GeminiTranscriptionClient: SpeechToTextBatchClient {
    public static let defaultModel = "gemini-3.5-transcribe"

    let context: ProviderContext
    public let model: String

    public init(context: ProviderContext, model: String = GeminiTranscriptionClient.defaultModel) {
        self.context = context
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
    }

    /// The unary model that goes with a Live stt model: `gemini-3.5-transcribe-live` → `gemini-3.5-transcribe`; Live
    /// agent models fall back to the default transcription model.
    public static func batchModel(forLive model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("transcribe"), trimmed.hasSuffix("-live") { return String(trimmed.dropLast("-live".count)) }
        return defaultModel
    }

    public func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String {
        let (data, response) = try await context.http.data(for: makeRequest(audio, language: language, keywords: keywords))
        let text = String(decoding: data, as: UTF8.self)
        let payload = try? JSONValue.parse(text)
        guard (200..<300).contains(response.statusCode) else {
            let message = payload?["error"].map { GeminiLiveWire.errorMessage($0).message }
                ?? String(text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError(provider: context.provider.id, status: response.statusCode,
                                message: "Gemini could not transcribe the recording: \(message)")
        }
        guard let payload else { throw ProviderError(provider: context.provider.id, message: "Gemini's transcription reply was not JSON") }
        return Self.transcript(in: payload)
    }

    /// The request: the WAV inline, language and vocabulary hints, nothing stored.
    func makeRequest(_ audio: DecodedAudio, language: String?, keywords: [String]) -> URLRequest {
        let wav = WAVEncoder.encode(audio.pcm, format: audio.format)
        var config: [String: JSONValue] = [:]
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            config["language_codes"] = [.string(language)]
        }
        let vocabulary = WarmKey.vocabulary(keywords)
        if !vocabulary.isEmpty { config["custom_vocabulary"] = .array(vocabulary.map { .string($0) }) }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": [["type": "audio", "data": .string(wav.base64EncodedString()), "mime_type": "audio/wav"]],
            "store": false,
        ]
        if !config.isEmpty { body["generation_config"] = ["transcription_config": .object(config)] }
        var headers: [String: String] = [:]
        if let key = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { headers["x-goog-api-key"] = key }
        return context.jsonRequest(GeminiSpeechWire.interactionsURL(base: Self.httpBase(context.provider.baseURL)), body: .object(body),
                                   headers: headers)
    }

    /// A Live provider may be configured with the WebSocket endpoint; the unary API lives on the same host over HTTPS.
    static func httpBase(_ base: URL?) -> URL? {
        guard let base, let scheme = base.scheme?.lowercased() else { return nil }
        if scheme == "ws" || scheme == "wss" || base.path.contains("BidiGenerateContent") { return nil }
        return base
    }

    /// The text of the `model_output` steps, in order.
    static func transcript(in payload: JSONValue) -> String {
        let steps = payload["steps"]?.arrayValue ?? []
        let texts = steps.filter { $0["type"]?.stringValue == "model_output" }.flatMap { step in
            (step["content"]?.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// `context` carries the API key; describe the client without it.
extension GeminiTranscriptionClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let key = (context.apiKey?.isEmpty == false) ? "set" : "none"
        return "GeminiTranscriptionClient(provider: \(context.provider.id), model: \(model), apiKey: \(key))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["provider": context.provider.id, "model": model], displayStyle: .struct) }
}
