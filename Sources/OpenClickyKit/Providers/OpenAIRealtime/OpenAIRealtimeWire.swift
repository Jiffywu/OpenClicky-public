import Foundation

// Client events and server-event parsing for the OpenAI Realtime API (GA interface), limited to what the voice
// slot needs. Field names follow the reference pages listed at the top of OpenAIRealtimeSpeechClient.swift.

enum OpenAIRealtimeWire {
    static let defaultBaseURL = "wss://api.openai.com/v1/realtime"

    /// `wss://…/realtime?model=<model>`. Accepts a base that already ends in `/realtime` (the configured
    /// default) or a plain API base such as `https://api.openai.com/v1`; http(s) becomes ws(s). Other query
    /// items on the base are kept.
    static func endpoint(base: URL?, model: String) -> URL {
        let raw = base?.absoluteString ?? defaultBaseURL
        var components = URLComponents(string: raw) ?? URLComponents(string: defaultBaseURL)!
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !(path == "realtime" || path.hasSuffix("/realtime")) { path += "/realtime" }
        components.path = path
        var items = (components.queryItems ?? []).filter { $0.name != "model" }
        items.append(URLQueryItem(name: "model", value: model))
        components.queryItems = items
        return components.url ?? URL(string: defaultBaseURL)!
    }

    /// Built-in voices are names ("cedar"); custom voices are `{ "id": "voice_…" }` per the session reference.
    static func voiceValue(_ voice: String) -> JSONValue {
        voice.hasPrefix("voice_") ? ["id": .string(voice)] : .string(voice)
    }

    /// Output-only speech: audio out as 24 kHz PCM16, no turn detection (we never send input audio, and a VAD
    /// would otherwise create responses on its own), and the read-aloud instructions.
    static func sessionUpdate(eventID: String, voice: String, instructions: String, reasoningEffort: String?) -> JSONValue {
        var session: [String: JSONValue] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": .string(instructions),
            "audio": [
                "input": ["turn_detection": .null],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "voice": voiceValue(voice),
                ],
            ],
        ]
        if let reasoningEffort { session["reasoning"] = ["effort": .string(reasoningEffort)] }
        return ["type": "session.update", "event_id": .string(eventID), "session": .object(session)]
    }

    static func userLine(eventID: String, text: String) -> JSONValue {
        [
            "type": "conversation.item.create",
            "event_id": .string(eventID),
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": .string(text)]],
            ],
        ]
    }

    /// `instructions` on a response overrides the session instructions for that response only.
    static func responseCreate(eventID: String, instructions: String?) -> JSONValue {
        var event: [String: JSONValue] = ["type": "response.create", "event_id": .string(eventID)]
        if let instructions { event["response"] = ["instructions": .string(instructions)] }
        return .object(event)
    }

    static func responseCancel(eventID: String, responseID: String?) -> JSONValue {
        var event: [String: JSONValue] = ["type": "response.cancel", "event_id": .string(eventID)]
        if let responseID { event["response_id"] = .string(responseID) }
        return .object(event)
    }

    static func itemDelete(eventID: String, itemID: String) -> JSONValue {
        ["type": "conversation.item.delete", "event_id": .string(eventID), "item_id": .string(itemID)]
    }
}

/// The `error` object of a Realtime `error` server event.
struct OpenAIRealtimeServerError: Error, Sendable {
    var type: String?
    var code: String?
    var message: String
    var param: String?
    /// The client event that caused it, when the server knows.
    var eventID: String?

    init(event: JSONValue) {
        let error = event["error"]
        type = error?["type"]?.stringValue
        code = error?["code"]?.stringValue
        message = error?["message"]?.stringValue ?? "Unknown Realtime API error"
        param = error?["param"]?.stringValue
        eventID = error?["event_id"]?.stringValue
    }

    /// Whether the error is about a session field (used to drop `reasoning` for models without it).
    func concerns(_ field: String) -> Bool {
        (param ?? "").contains(field) || message.localizedCaseInsensitiveContains(field)
    }

    func providerError(provider: String) -> ProviderError {
        ProviderError(provider: provider, status: nil, message: code.map { "\($0): \(message)" } ?? message)
    }
}
