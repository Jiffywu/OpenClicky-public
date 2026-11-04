// Gemini Live API wire format for push-to-talk transcription (dialect "gemini-live").
//
// Checked on 2026-10-31 against Google's own pages:
//   https://ai.google.dev/api/live                                         BidiGenerateContentSetup, RealtimeInput,
//                                                                          AudioTranscriptionConfig, ServerMessage
//                                                                          (serverContent, goAway, voiceActivity)
//   https://ai.google.dev/gemini-api/docs/live-api/live-transcribe         gemini-3.5-transcribe-live, TEXT modality,
//                                                                          languageCodes / customVocabulary / mode,
//                                                                          manual VAD, interim vs finalized transcription
//   https://ai.google.dev/gemini-api/docs/live-guide                       16 kHz PCM16 LE input, manual activity markers
//   https://ai.google.dev/gemini-api/docs/live-session                     ~10 minute connections, goAway.timeLeft
//   https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe     model ids, 10 minutes per Live session
//   https://ai.google.dev/gemini-api/docs/api-key                          `x-goog-api-key` header
//
// What those pages settle:
// - Endpoint `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`.
//   (`BidiGenerateContentConstrained` is the ephemeral-token variant HeyClicky uses through its server; with the user's
//   own key the plain method is the right one.) The WebSocket sample puts the key in a `key=` query parameter; Google's
//   own Python SDK (googleapis/python-genai, `live.py` + `_api_client.py`) sends it as an `x-goog-api-key` header on
//   the upgrade request instead. The header keeps the key out of URLs (and so out of anything that logs a URL).
// - The first client message is `{"setup": {...}}` with `model` as `models/{id}`; nothing else may be sent until the
//   server answers `setupComplete`.
// - The transcription model `gemini-3.5-transcribe-live` takes `generationConfig.responseModalities: ["TEXT"]` and is a
//   speech-recognition pipeline rather than an agent, so it never answers back. Live agent models (`gemini-3.8-live`
//   and other native-audio models) accept only AUDIO output; with those this adapter adds a system instruction to stay
//   silent and never reads the reply, and closes the socket as soon as the transcript is in.
// - `realtimeInputConfig.automaticActivityDetection.disabled: true` makes the client mark speech with
//   `realtimeInput.activityStart` / `activityEnd` (push-to-talk). `audioStreamEnd` is only for automatic detection.
// - Audio is `realtimeInput.audio{data: base64 PCM16, mimeType: "audio/pcm;rate=16000"}`, raw 16-bit little-endian
//   16 kHz mono, ideally in chunks of about 100 ms (1,024 to 2,048 frames).
// - `inputAudioTranscription{languageCodes[], customVocabulary[], mode}`: an empty `languageCodes` auto-detects;
//   `customVocabulary` takes up to 1,000 terms (about 100 works best); `mode` is VERBATIM (default) or SMART.
// - Server: `serverContent.interimInputTranscription.text` is a speculative partial for the words being spoken now,
//   `serverContent.inputTranscription.text` the authoritative text of a finished speech segment. The reference says
//   input transcriptions arrive "independently" of other messages, with no ordering guarantee.
// - `goAway{timeLeft}` warns that the connection ends soon (proto Duration, JSON like "50s").
// - Error frames and close codes are not documented. Google APIs answer errors with `{"error":{code,message,status}}`,
//   so a frame of that shape is read as a refusal; any other unexpected close is reported as a dropped connection.
// - The pages only show `JSON.parse(event.data)`; servers are known to send JSON in binary frames too, so text and
//   binary frames are both read as UTF-8 JSON.

import Foundation

enum GeminiLiveWire {
    static let defaultEndpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    /// Raw 16-bit PCM at 16 kHz, little-endian, mono: the documented input format.
    static let inputFormat = PCMFormat.speech16k
    static let audioMimeType = "audio/pcm;rate=16000"
    /// About 100 ms per message is the documented sweet spot; 2,048 frames is the top of the documented range.
    static let maxAudioChunkBytes = 2_048 * 2
    /// `customVocabulary` accepts up to 1,000 terms.
    static let maxVocabularyTerms = 1_000

    /// Which kind of Live model the setup is for.
    enum ModelFamily: Sendable, Equatable {
        /// A transcription model: TEXT output, never answers.
        case transcription
        /// A Live agent (native audio) model: AUDIO output only, told to stay silent.
        case conversational

        static func of(_ model: String) -> ModelFamily {
            model.lowercased().contains("transcribe") ? .transcription : .conversational
        }
    }

    // MARK: - Endpoint

    /// The socket URL for a provider base URL. Accepts the full endpoint, or a REST-style base such as
    /// `https://generativelanguage.googleapis.com` or `.../v1beta` (the version is kept), so one Gemini base URL works.
    static func endpoint(base: URL?) -> URL {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false), components.host != nil else {
            return URL(string: defaultEndpoint)!
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        if !components.path.contains("BidiGenerateContent") {
            var parts = components.path.split(separator: "/").map(String.init)
            var version = "v1beta"
            if let last = parts.last, isAPIVersion(last) {
                version = last
                parts.removeLast()
            }
            let prefix = parts.isEmpty ? "" : "/" + parts.joined(separator: "/")
            components.path = prefix + "/ws/google.ai.generativelanguage.\(version).GenerativeService.BidiGenerateContent"
        }
        return components.url ?? URL(string: defaultEndpoint)!
    }

    private static func isAPIVersion(_ component: String) -> Bool {
        guard component.hasPrefix("v"), component.count > 1 else { return false }
        let rest = component.dropFirst()
        guard let first = rest.first, first.isNumber else { return false }
        return rest.allSatisfy { $0.isNumber || $0.isLetter }
    }

    // MARK: - Client messages

    /// `models/{id}`, as the setup message wants it.
    static func resourceName(_ model: String) -> String {
        model.hasPrefix("models/") ? model : "models/\(model)"
    }

    static func setup(model: String, family: ModelFamily, language: String?, vocabulary: [String], mode: String?) -> JSONValue {
        var transcription: [String: JSONValue] = [:]
        if let language {
            transcription["languageCodes"] = [.string(language)]
        } else if family == .transcription {
            // Empty means automatic language detection, including code-switching (the docs' own setup sends it).
            transcription["languageCodes"] = []
        }
        if !vocabulary.isEmpty { transcription["customVocabulary"] = .array(vocabulary.map(JSONValue.string)) }
        if let mode, !mode.isEmpty { transcription["mode"] = .string(mode) }

        var setup: [String: JSONValue] = [
            "model": .string(resourceName(model)),
            "generationConfig": ["responseModalities": [family == .transcription ? "TEXT" : "AUDIO"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": .object(transcription),
        ]
        if family == .conversational {
            setup["systemInstruction"] = ["parts": [["text": .string(silentListenerInstruction)]]]
        }
        return ["setup": .object(setup)]
    }

    /// For Live agent models, which must answer in audio: the adapter wants only their input transcription.
    static let silentListenerInstruction = """
        You are a microphone feed for a transcription system. Do not reply to, answer or comment on anything you \
        hear. Stay silent.
        """

    static let activityStart: JSONValue = ["realtimeInput": ["activityStart": [:]]]
    static let activityEnd: JSONValue = ["realtimeInput": ["activityEnd": [:]]]

    static func audio(_ pcm: Data) -> JSONValue {
        ["realtimeInput": ["audio": ["data": .string(pcm.base64EncodedString()), "mimeType": .string(audioMimeType)]]]
    }

    // MARK: - Server messages

    /// A server frame as JSON. Text and binary frames both carry UTF-8 JSON.
    static func parse(_ message: WebSocketMessage) -> JSONValue? {
        let json: JSONValue?
        switch message {
        case .text(let text): json = try? JSONValue.parse(text)
        case .binary(let data): json = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        guard case .object = json else { return nil }
        return json
    }

    /// A proto3 JSON Duration: `"50s"`, `"1.5s"`, or the `{seconds, nanos}` object form. Nil for anything negative,
    /// non-finite or longer than a day: the value comes from the network, and `Int64(_:)` traps on out-of-range input.
    static func duration(_ value: JSONValue?) -> Duration? {
        switch value {
        case .string(let text)?:
            guard text.hasSuffix("s"), let seconds = Double(text.dropLast()) else { return nil }
            return milliseconds(seconds * 1000)
        case .object(let object)?:
            let seconds = object["seconds"].flatMap { $0.doubleValue ?? $0.stringValue.flatMap(Double.init) } ?? 0
            let nanos = object["nanos"]?.doubleValue ?? 0
            return milliseconds(seconds * 1000 + nanos / 1_000_000)
        case .number(let seconds)?:
            return milliseconds(seconds * 1000)
        default:
            return nil
        }
    }

    /// The longest `goAway.timeLeft` taken at face value. Connections last about ten minutes.
    private static let maxDurationMilliseconds = 86_400_000.0

    private static func milliseconds(_ value: Double) -> Duration? {
        guard value.isFinite, value >= 0, value <= maxDurationMilliseconds else { return nil }
        return .milliseconds(Int64(value.rounded()))
    }

    /// The readable part of a Google API error object (`{"error": {"code", "message", "status"}}`).
    static func errorMessage(_ error: JSONValue) -> (status: Int?, message: String) {
        let code = error["code"]?.intValue
        let status = error["status"]?.stringValue ?? error["code"]?.stringValue
        let text = error["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (status, text) {
        case let (status?, text?) where !text.isEmpty: return (code, "\(status): \(text)")
        case let (nil, text?) where !text.isEmpty: return (code, text)
        case let (status?, _): return (code, status)
        default: return (code, "Gemini reported an error")
        }
    }
}
