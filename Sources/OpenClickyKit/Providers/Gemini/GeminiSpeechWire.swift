// Gemini text-to-speech wire format (dialect "gemini-speech").
//
// Checked on 2026-10-31 against Google's own pages:
//   https://ai.google.dev/gemini-api/docs/speech-generation               request body, voices, streaming, audio formats
//   https://ai.google.dev/gemini-api/docs/streaming                       SSE framing and event order
//   https://ai.google.dev/api/interactions-api                            event and AudioResponseFormat schemas
//   https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-lite-tts model id, 8,192 input tokens, no Live API
//   https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts      model id, 8,192 input tokens, no Live API
//
// Which path streams:
// - The TTS model pages list "Live API: Not supported", so speech output cannot go through a Live socket.
// - The speech guide streams with `POST {base}/v1beta/interactions` and `"stream": true`. That is the documented
//   streaming path, so this adapter uses it. (`generateContent` is only mentioned in the guide's migration notes.)
//
// Request (the guide's REST samples):
//   {"model": "...", "input": [{"type": "user_input", "content": [{"type": "text", "text": "<line>",
//     "annotations": [{"type": "speech_metadata", "style": "<delivery>"}]}]}],
//    "response_format": {"type": "audio", "mime_type": "audio/l16", "sample_rate": 24000},
//    "generation_config": {"speech_config": [{"voice": "Kore"}]}, "stream": true}
// - Gemini 3.8 TTS reads `text` strictly as a verbatim transcript; sustained delivery directions go in the
//   `speech_metadata` annotation's `style`. So the line goes in untouched and `instructions` become the `style`.
// - The API reference spells the voice field `structured_speech_config`; every REST sample in the speech guide uses
//   `speech_config`. This adapter follows the samples (and `GeminiSpeechClient.Options.speechConfigField` can switch).
// - `store` (default true) is "whether to store the response and request for later retrieval". A spoken line never
//   needs retrieving, so the adapter sends `false` by default.
// - Auth is the `x-goog-api-key` header.
//
// Response:
// - Streamed as server-sent events: `interaction.created`, `step.start` (`model_output`), `step.delta` events whose
//   `delta` is `{"type": "audio", "data": <base64>, "mime_type"?, "sample_rate"?, "channels"?}`, `step.stop`,
//   `interaction.completed`, then `event: done` / `data: [DONE]`. Errors arrive as `event: error` with
//   `{"error": {"message", "code"}}`.
// - Streamed audio defaults to headerless 16-bit little-endian linear PCM (`audio/l16`), 24 kHz, mono. The adapter
//   asks for it explicitly anyway, because unary 3.8 responses default to WAV.
// - A unary interaction (JSON, no SSE) keeps audio at `steps[type=model_output].content[type=audio].data`; the
//   adapter reads that shape too, stripping a RIFF header if there is one, and chunks the PCM.
// - HTTP errors use Google's `{"error": {"code", "message", "status"}}`.

import Foundation

enum GeminiSpeechWire {
    static let defaultBaseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let pcmMimeType = "audio/l16"

    /// The 30 prebuilt voices in the speech guide, in its order and casing.
    static let prebuiltVoices = [
        "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
        "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia",
        "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix",
        "Sadachbia", "Sadaltager", "Sulafat",
    ]

    // MARK: - Request

    /// `{base}/interactions`. A base with no API version (`https://generativelanguage.googleapis.com`) gets `v1beta`.
    static func interactionsURL(base: URL?) -> URL {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false), components.host != nil else {
            return URL(string: defaultBaseURL + "/interactions")!
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.last == "interactions" { return components.url ?? URL(string: defaultBaseURL + "/interactions")! }
        if !parts.contains(where: isAPIVersion) { parts.append("v1beta") }
        parts.append("interactions")
        components.path = "/" + parts.joined(separator: "/")
        return components.url ?? URL(string: defaultBaseURL + "/interactions")!
    }

    static func isAPIVersion(_ component: String) -> Bool {
        guard component.hasPrefix("v"), component.count > 1 else { return false }
        let rest = component.dropFirst()
        guard let first = rest.first, first.isNumber else { return false }
        return rest.allSatisfy { $0.isNumber || $0.isLetter }
    }

    static func body(model: String, text: String, voice: String, style: String?, language: String?, sampleRate: Int,
                     store: Bool, speechConfigField: String) -> JSONValue {
        var part: [String: JSONValue] = ["type": "text", "text": .string(text)]
        if let style, !style.isEmpty {
            part["annotations"] = [["type": "speech_metadata", "style": .string(style)]]
        }
        var speaker: [String: JSONValue] = ["voice": .string(voice)]
        if let language, !language.isEmpty { speaker["language"] = .string(language) }
        return [
            "model": .string(model),
            "input": [["type": "user_input", "content": [.object(part)]]],
            "response_format": ["type": "audio", "mime_type": .string(pcmMimeType), "sample_rate": .number(Double(sampleRate))],
            "generation_config": .object([speechConfigField: [.object(speaker)]]),
            "stream": true,
            "store": .bool(store),
        ]
    }

    /// A voice as the API wants it: blank is nil, a HeyClicky-style `gemini:` prefix is dropped, and a prebuilt name in
    /// any casing gets the guide's casing. Anything else (Voice design `voice_…`, `voicekey_…`, library ids) passes
    /// through unchanged.
    static func voiceName(_ raw: String?) -> String? {
        guard var voice = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !voice.isEmpty else { return nil }
        if voice.lowercased().hasPrefix("gemini:") {
            voice = String(voice.dropFirst("gemini:".count)).trimmingCharacters(in: .whitespaces)
            if voice.isEmpty { return nil }
        }
        return prebuiltVoices.first { $0.caseInsensitiveCompare(voice) == .orderedSame } ?? voice
    }

    // MARK: - Response events

    enum Event: Equatable {
        /// Decoded audio bytes and what the delta said about them.
        case audio(Data, mimeType: String?, sampleRate: Int?, channels: Int?)
        /// `interaction.completed`, with the interaction's status.
        case completed(status: String?)
        /// `event: done` / `data: [DONE]`.
        case done
        case failure(code: String?, message: String)
        case ignored
    }

    static func event(_ sse: ServerSentEvent) -> Event {
        let data = sse.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" { return .done }
        guard let json = try? JSONValue.parse(data), case .object = json else {
            return sse.event == "done" ? .done : .ignored
        }
        let type = json["event_type"]?.stringValue ?? sse.event
        switch type {
        case "step.delta"?:
            guard let delta = json["delta"], delta["type"]?.stringValue == "audio" else { return .ignored }
            guard let encoded = delta["data"]?.stringValue else { return .ignored }
            guard let bytes = decodeBase64(encoded) else {
                return .failure(code: nil, message: "Gemini sent audio that is not valid base64.")
            }
            return .audio(bytes, mimeType: delta["mime_type"]?.stringValue, sampleRate: delta["sample_rate"]?.intValue,
                          channels: delta["channels"]?.intValue)
        case "interaction.completed"?:
            return .completed(status: json["interaction"]?["status"]?.stringValue)
        case "error"?:
            let (code, message) = errorParts(json["error"] ?? json)
            return .failure(code: code, message: message)
        case "done"?:
            return .done
        default:
            return .ignored
        }
    }

    /// The last audio block of a unary interaction: `steps[type=model_output].content[type=audio]`.
    static func unaryAudio(_ json: JSONValue) -> Event? {
        let steps = json["steps"]?.arrayValue ?? []
        let blocks = steps.filter { ($0["type"]?.stringValue ?? "model_output") == "model_output" }
            .flatMap { $0["content"]?.arrayValue ?? [] }
            .filter { $0["type"]?.stringValue == "audio" && $0["data"]?.stringValue != nil }
        guard let block = blocks.last, let encoded = block["data"]?.stringValue else { return nil }
        guard let bytes = decodeBase64(encoded) else { return .failure(code: nil, message: "Gemini sent audio that is not valid base64.") }
        return .audio(bytes, mimeType: block["mime_type"]?.stringValue, sampleRate: block["sample_rate"]?.intValue,
                      channels: block["channels"]?.intValue)
    }

    /// Standard or URL-safe base64, padded or not, ignoring line breaks.
    static func decodeBase64(_ text: String) -> Data? {
        var normalized = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        normalized = normalized.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    // MARK: - Audio formats

    /// What a block's MIME type means for playback.
    enum AudioKind: Equatable {
        /// Headerless 16-bit little-endian PCM.
        case linear16
        /// A WAV file: PCM behind a RIFF header.
        case wav
        /// Anything else (compressed, G.711): not playable as samples.
        case unsupported(String)
    }

    static func audioKind(_ mimeType: String?) -> AudioKind {
        guard let mimeType else { return .linear16 }  // the documented streaming default
        let base = mimeType.split(separator: ";", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        switch base {
        case "", "audio/l16", "audio/pcm", "audio/raw", "audio/linear16": return .linear16
        case "audio/wav", "audio/wave", "audio/x-wav", "audio/vnd.wave": return .wav
        default: return .unsupported(mimeType)
        }
    }

    /// A `rate=` parameter on the MIME type (`audio/l16;rate=24000`), if any.
    static func rateParameter(_ mimeType: String?) -> Int? {
        guard let mimeType else { return nil }
        for parameter in mimeType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "rate", let rate = Int(pair[1]) { return rate }
        }
        return nil
    }

    /// The PCM inside a WAV file and its format. Nil if the bytes are not a 16-bit PCM WAV.
    static func wavPayload(_ data: Data) -> (pcm: Data, format: PCMFormat)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
            return nil
        }
        func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
        var offset = 12
        var format: PCMFormat?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = le32(offset + 4)
            let start = offset + 8
            switch id {
            case "fmt ":
                guard start + 16 <= bytes.count else { return nil }
                let encoding = le16(start), channels = le16(start + 2), rate = le32(start + 4), bits = le16(start + 14)
                // 1 is integer PCM; 0xFFFE (extensible) is accepted when the sample size still says 16 bits.
                guard encoding == 1 || encoding == 0xFFFE, bits == 16, channels > 0, rate > 0 else { return nil }
                format = PCMFormat(sampleRate: rate, channels: channels)
            case "data":
                guard let format else { return nil }
                // Streaming writers often leave the size as 0 or 0xFFFFFFFF; then the data runs to the end.
                let end = (size == 0 || start + size > bytes.count) ? bytes.count : start + size
                return (Data(bytes[start..<end]), format)
            default:
                break
            }
            offset = start + size + (size % 2)
        }
        return nil
    }

    // MARK: - Errors

    /// `(code, message)` from Google's `{"code", "message", "status"}` or the Interactions `{"code", "message"}`.
    static func errorParts(_ error: JSONValue) -> (code: String?, message: String) {
        let status = error["status"]?.stringValue
        let code = error["code"]?.stringValue ?? error["code"]?.intValue.map(String.init)
        let message = error["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = status ?? code
        switch (label, message) {
        case let (label?, message?) where !message.isEmpty: return (label, "\(label): \(message)")
        case let (nil, message?) where !message.isEmpty: return (nil, message)
        case let (label?, _): return (label, label)
        default: return (nil, "Gemini reported an error")
        }
    }

    /// The readable message of an HTTP error body, or nil if it is not Google's error JSON.
    static func errorMessage(in body: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body), let error = json["error"] else { return nil }
        if let text = error.stringValue { return text }
        return errorParts(error).message
    }
}
