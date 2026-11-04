// OpenAI audio transcription (`POST {baseURL}/audio/transcriptions`) for the stt slot, dialect
// "openai-transcription". Batch per utterance: the session buffers PCM, and finish() uploads it as one WAV file.
//
// Wire protocol checked on 2026-10-30 against:
//   https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create
//   https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/streaming-events
//   https://developers.openai.com/api/docs/guides/speech-to-text
//   https://developers.openai.com/api/docs/deprecations (whisper-1 and gpt-4o-*-transcribe shut down 2027-02-26,
//     gpt-4o-mini-transcribe-2025-03-20 on 2027-01-20; replacements are gpt-live-transcribe, which is Realtime-only,
//     and gpt-transcribe, the one this endpoint takes)
//   https://developers.openai.com/api/docs/guides/error-codes (errors arrive as an `error` object)
//
// What those pages say, and how this adapter uses it:
// - The body is multipart/form-data: `file` (wav is accepted, files up to 25 MB), `model`, optional `language`
//   (ISO-639-1), `prompt` and `stream`. Array parameters are repeated `name[]` parts, as in the curl examples
//   (`include[]=logprobs` in the reference; `keywords[]=…` and `languages[]=…` in the speech-to-text guide).
// - gpt-transcribe takes `keywords[]` (one line each, no `<`, `>`, CR or LF, or the whole request is rejected)
//   and `languages[]`, which replaces `language` ("Don't send both fields"). It can also take a prompt with them.
//   Older models get keyword hints through `prompt`, the guide's "dictionary of the correct spellings" written as
//   a comma-separated list. gpt-4o-transcribe-diarize doesn't support prompts and needs `chunking_strategy` for
//   inputs over 30 seconds.
// - With `stream=true` the response is server-sent events whose `data:` lines carry `transcript.text.delta`
//   {delta} and then `transcript.text.done` {text, usage, languages?}. whisper-1 ignores `stream` and answers with
//   plain JSON `{"text": …}`, so the response's Content-Type decides how the body is read. The docs show no
//   `event:` field and no `[DONE]` sentinel: the event type is read from the JSON `type` field, falling back to an
//   SSE `event:` name, and a `[DONE]` line from a compatible server is ignored.
// - The docs give no sample-rate requirement; the WAV header carries the rate. 16 kHz mono keeps uploads at
//   32 KB/s, about 13 minutes of speech per 25 MB request.

import Foundation

/// Speech to text through OpenAI's audio transcription endpoint (also served by OpenAI-compatible local servers).
/// Transcribes one utterance per session: audio is buffered while the user talks and uploaded on `finish()`.
/// When the model streams, the transcript arrives as interims while the model works, then one final.
public struct OpenAITranscriptionClient: SpeechToTextClient {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    /// Matches the built-in model catalog. OpenAI's recommended replacement is `gpt-transcribe`.
    public static let defaultModel = "gpt-4o-mini-transcribe"
    /// The endpoint's documented upload limit ("Files can be up to 25 MB").
    public static let maxUploadBytes = 25 * 1024 * 1024

    public let model: String
    public let inputFormat: PCMFormat
    /// Whether uploads ask for `stream=true`, which yields interim text while the model transcribes.
    public let streamsTranscript: Bool

    private let context: ProviderContext
    private let prompt: String?

    /// - Parameters:
    ///   - model: e.g. `gpt-4o-mini-transcribe`, `gpt-transcribe`, `whisper-1`.
    ///   - prompt: Optional context sent with every request (e.g. "Commands spoken to a Mac assistant.").
    ///     Session keywords are added to it, or sent as `keywords[]` for gpt-transcribe.
    ///   - streaming: Ask for streamed deltas. Nil streams for every model except whisper-1, which doesn't stream.
    ///   - inputFormat: The PCM that capture should deliver; written into the WAV header as-is.
    public init(context: ProviderContext, model: String = OpenAITranscriptionClient.defaultModel, prompt: String? = nil,
                streaming: Bool? = nil, inputFormat: PCMFormat = .speech16k) {
        self.context = context
        self.model = model
        self.prompt = prompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.streamsTranscript = streaming ?? Self.modelStreams(model)
        self.inputFormat = inputFormat
    }

    public func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession {
        let url = context.url("audio/transcriptions", default: Self.defaultBaseURL)
        let apiKey = context.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        // Fail before the user speaks rather than after: OpenAI itself always needs a key. Keyless local
        // OpenAI-compatible servers are allowed.
        if apiKey == nil, url.host?.lowercased() == "api.openai.com" {
            throw ProviderError(provider: context.provider.id, message: "No API key is configured for \(context.provider.id).")
        }
        let upload = OpenAITranscriptionUpload(
            providerID: context.provider.id, http: context.http, url: url, extraHeaders: context.provider.headers ?? [:],
            apiKey: apiKey, fields: formFields(language: language, keywords: keywords), format: inputFormat,
            streaming: streamsTranscript)
        return OpenAITranscriptionSession(upload: upload)
    }

    /// The text parts of the form, in wire order (the file part follows them).
    func formFields(language: String?, keywords: [String]) -> [FormField] {
        var fields = [FormField("model", model)]
        let language = Self.languageCode(language)
        let keywords = Self.cleanKeywords(keywords)
        if Self.modelTakesKeywordList(model) {
            if let language { fields.append(FormField("languages[]", language)) }
            if let prompt { fields.append(FormField("prompt", prompt)) }
            fields += keywords.map { FormField("keywords[]", $0) }
        } else {
            if let language { fields.append(FormField("language", language)) }
            if Self.modelTakesPrompt(model) {
                let parts = [prompt, keywords.isEmpty ? nil : keywords.joined(separator: ", ")].compactMap { $0 }
                if !parts.isEmpty { fields.append(FormField("prompt", parts.joined(separator: "\n"))) }
            }
        }
        if Self.modelNeedsChunkingStrategy(model) { fields.append(FormField("chunking_strategy", "auto")) }
        if streamsTranscript { fields.append(FormField("stream", "true")) }
        return fields
    }

    // MARK: - Model rules from the docs

    /// "Streaming is not supported for the `whisper-1` model and will be ignored."
    static func modelStreams(_ model: String) -> Bool { !model.hasPrefix("whisper") }
    /// `keywords` and `languages` are documented for gpt-transcribe (and its snapshots).
    static func modelTakesKeywordList(_ model: String) -> Bool { model.hasPrefix("gpt-transcribe") }
    /// "gpt-4o-transcribe-diarize doesn't support prompts."
    static func modelTakesPrompt(_ model: String) -> Bool { !model.contains("diarize") }
    /// chunking_strategy "Required when using gpt-4o-transcribe-diarize for inputs longer than 30 seconds."
    static func modelNeedsChunkingStrategy(_ model: String) -> Bool { model.contains("diarize") }

    /// The endpoint wants ISO-639-1 (`en`), so a locale such as `en-US` or `pt_BR` is cut to its language.
    static func languageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        let primary = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return primary.isEmpty ? nil : primary
    }

    /// One line each, without `<` or `>` (the docs say such keywords reject the whole request), deduplicated.
    static func cleanKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for keyword in keywords {
            let text = keyword.filter { $0 != "<" && $0 != ">" }
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            cleaned.append(text)
        }
        return cleaned
    }
}
