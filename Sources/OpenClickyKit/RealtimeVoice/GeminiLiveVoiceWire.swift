// Gemini Live API messages for a native-audio conversation: the realtime-voice slot on dialect "gemini-live".
//
// Checked on 2026-10-31 against Google's pages:
//   https://ai.google.dev/api/live                                    setup / realtimeInput / clientContent / toolResponse;
//                                                                     server setupComplete, serverContent, toolCall,
//                                                                     toolCallCancellation{ids}, goAway{timeLeft}, usageMetadata
//   https://ai.google.dev/gemini-api/docs/live-guide                  16 kHz PCM16 in, 24 kHz PCM16 out, input/output
//                                                                     transcription, automaticActivityDetection fields,
//                                                                     serverContent.interrupted, images as `video` frames
//   https://ai.google.dev/gemini-api/docs/live-tools                  functionDeclarations, toolCall.functionCalls,
//                                                                     FunctionResponse{id, name, response}, NON_BLOCKING
//                                                                     behavior and response `scheduling`
//   https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live      model id, function calling (async by default),
//                                                                     no thinkingLevel, audio is the only response modality
//   https://ai.google.dev/gemini-api/docs/live-api/capabilities       15 min audio-only / 2 min with video per session,
//                                                                     extended-thinking variant is NON_BLOCKING only
//   https://ai.google.dev/gemini-api/docs/live-session                setup.sessionResumption{handle}, server
//                                                                     sessionResumptionUpdate{newHandle, resumable}, goAway
//
// What those pages settle, and how this adapter follows them:
// - Native-audio models answer only in AUDIO; what they say comes back as `outputAudioTranscription` text.
// - `realtimeInput.audio{data, mimeType:"audio/pcm;rate=16000"}` carries mic audio. `audioStreamEnd` flushes audio when
//   the stream pauses with automatic activity detection; `activityStart`/`activityEnd` mark turns when it is disabled.
// - Screenshots, checked live on 2026-10-31 with gemini-3.8-live (docs/evidence/feat-realtime-voice/): a
//   `realtimeInput.video` frame sent for a `capture_screen` call, and an `inlineData` part in a `clientContent` turn with
//   `turnComplete: false`, both left the reply's prompt with no IMAGE tokens and the model guessed. The same JPEG as an
//   `inlineData` entry in the FunctionResponse's own `parts` was counted (60 IMAGE tokens) and read correctly. So a
//   screenshot taken for a tool call rides in that call's tool response; the other two remain options.
// - `serverContent.modelTurn.parts[].inlineData` is the reply audio (several parts per message are possible, so every
//   part is read); `turnComplete` ends the turn; `interrupted` means the server heard the user and dropped the rest.
// - Tool calls come as `toolCall.functionCalls[{id, name, args}]` and are answered with
//   `toolResponse.functionResponses[{id, name, response}]`. On gemini-3.8-live calls are non-blocking by default and the
//   response may carry `scheduling`: WHEN_IDLE (speak at a natural pause), INTERRUPT or SILENT (record only). It is
//   ignored for blocking calls, so it is always safe to send.
// - Function `parameters` use the OpenAPI subset of JSON Schema, so keywords outside it (`additionalProperties`,
//   `$schema`, …) are dropped before sending.
// - Native audio picks the spoken language itself; a language hint only goes to input transcription.

import Foundation

enum GeminiLiveVoiceWire {
    static let inputFormat = PCMFormat.speech16k
    static let outputFormat = PCMFormat.speech24k
    static let audioMimeType = "audio/pcm;rate=16000"
    /// About 100 ms of 16 kHz PCM16 per message, the documented sweet spot.
    static let maxAudioChunkBytes = 3_200

    /// How function calls run on the model. Nil leaves the model default (non-blocking on gemini-3.8-live).
    enum Behavior: String, Sendable, Hashable {
        case blocking = "BLOCKING"
        case nonBlocking = "NON_BLOCKING"
    }

    static func setup(model: String, configuration: RealtimeSessionConfiguration, voice: String?, behavior: Behavior?,
                      compressContext: Bool, mediaResolution: String? = nil) -> JSONValue {
        var generation: [String: JSONValue] = ["responseModalities": ["AUDIO"]]
        if let mediaResolution { generation["mediaResolution"] = .string(mediaResolution) }
        if let voice {
            generation["speechConfig"] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": .string(voice)]]]
        }
        var setup: [String: JSONValue] = [
            "model": .string(GeminiLiveWire.resourceName(model)),
            "generationConfig": .object(generation),
            "systemInstruction": ["parts": [["text": .string(configuration.instructions)]]],
            "realtimeInputConfig": realtimeInputConfig(configuration.turnDetection),
            "outputAudioTranscription": [:],
        ]
        if configuration.transcribeInput {
            var transcription: [String: JSONValue] = [:]
            if let language = realtimeTrimmed(configuration.language) { transcription["languageCodes"] = [.string(language)] }
            setup["inputAudioTranscription"] = .object(transcription)
        }
        if !configuration.tools.isEmpty {
            setup["tools"] = [["functionDeclarations": .array(configuration.tools.map { declaration($0, behavior: behavior) })]]
        }
        // Without compression an audio session ends after about 15 minutes, or 2 with pictures in it.
        if compressContext { setup["contextWindowCompression"] = ["slidingWindow": [:]] }
        // Resumption: an empty config asks for handles; a handle picks up an earlier session's conversation.
        if configuration.resumable || configuration.resumptionHandle != nil {
            var resumption: [String: JSONValue] = [:]
            if let handle = realtimeTrimmed(configuration.resumptionHandle) { resumption["handle"] = .string(handle) }
            setup["sessionResumption"] = .object(resumption)
        }
        return ["setup": .object(setup)]
    }

    static func realtimeInputConfig(_ detection: RealtimeTurnDetection) -> JSONValue {
        guard case .serverVAD(let vad) = detection else {
            return ["automaticActivityDetection": ["disabled": true]]
        }
        var activity: [String: JSONValue] = ["disabled": false]
        if let threshold = vad.threshold {
            // Gemini has coarse sensitivities instead of a threshold: a high threshold means hard to trigger.
            if threshold >= 0.65 { activity["startOfSpeechSensitivity"] = "START_SENSITIVITY_LOW" }
            if threshold <= 0.35 { activity["startOfSpeechSensitivity"] = "START_SENSITIVITY_HIGH" }
        }
        if let padding = vad.prefixPadding { activity["prefixPaddingMs"] = .number(Double(padding.realtimeMilliseconds)) }
        if let silence = vad.silence { activity["silenceDurationMs"] = .number(Double(silence.realtimeMilliseconds)) }
        var config: [String: JSONValue] = ["automaticActivityDetection": .object(activity)]
        if !vad.interruptsResponse { config["activityHandling"] = "NO_INTERRUPTION" }
        return .object(config)
    }

    static func declaration(_ spec: ToolSpec, behavior: Behavior?) -> JSONValue {
        var object: [String: JSONValue] = ["name": .string(spec.name), "description": .string(spec.description)]
        let parameters = schema(spec.parameters)
        // A tool without arguments sends no `parameters` at all: an empty OBJECT schema is refused by some models.
        if let properties = parameters["properties"]?.objectValue, !properties.isEmpty { object["parameters"] = parameters }
        if let behavior { object["behavior"] = .string(behavior.rawValue) }
        return .object(object)
    }

    /// Keywords of the OpenAPI schema subset Gemini accepts.
    static let schemaKeywords: Set<String> = [
        "type", "format", "description", "nullable", "enum", "properties", "required", "items", "minItems", "maxItems",
        "minimum", "maximum", "minLength", "maxLength", "pattern", "anyOf", "propertyOrdering", "default", "title",
    ]

    /// `value` with keywords Gemini doesn't accept removed, recursively through properties, items and anyOf.
    static func schema(_ value: JSONValue) -> JSONValue {
        guard case .object(let object) = value else { return value }
        var cleaned: [String: JSONValue] = [:]
        for (key, item) in object where schemaKeywords.contains(key) {
            switch key {
            case "properties":
                if case .object(let properties) = item { cleaned[key] = .object(properties.mapValues(schema)) }
            case "items":
                cleaned[key] = schema(item)
            case "anyOf":
                cleaned[key] = .array((item.arrayValue ?? []).map(schema))
            default:
                cleaned[key] = item
            }
        }
        return .object(cleaned)
    }

    static func audio(_ pcm: Data) -> JSONValue {
        ["realtimeInput": ["audio": ["data": .string(pcm.base64EncodedString()), "mimeType": .string(audioMimeType)]]]
    }

    /// A screenshot as a live video frame. Frames only count toward the user's next spoken turn, so a picture sent
    /// for a tool call this way is not in the context the model answers the call from.
    static func videoFrame(_ data: Data, mimeType: String) -> JSONValue {
        ["realtimeInput": ["video": ["data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]]]
    }

    /// A screenshot as a user message in the conversation (without ending the turn), so the model sees it at once.
    static func imageTurn(_ data: Data, mimeType: String, caption: String?) -> JSONValue {
        var parts: [JSONValue] = [["inlineData": ["mimeType": .string(mimeType), "data": .string(data.base64EncodedString())]]]
        if let caption = realtimeTrimmed(caption) { parts.append(["text": .string(caption)]) }
        return ["clientContent": ["turns": [["role": "user", "parts": .array(parts)]], "turnComplete": false]]
    }

    static let audioStreamEnd: JSONValue = ["realtimeInput": ["audioStreamEnd": true]]

    static func userText(_ text: String, turnComplete: Bool) -> JSONValue {
        ["clientContent": ["turns": [["role": "user", "parts": [["text": .string(text)]]]], "turnComplete": .bool(turnComplete)]]
    }

    static let turnComplete: JSONValue = ["clientContent": ["turnComplete": true]]

    enum Scheduling: String {
        case whenIdle = "WHEN_IDLE"
        case interrupt = "INTERRUPT"
        case silent = "SILENT"
    }

    /// A function's answer. `images` go in the FunctionResponse's own `parts` (inline media for the function's result).
    static func toolResponse(_ result: RealtimeToolResult, scheduling: Scheduling, images: [RealtimeImage] = []) -> JSONValue {
        var response = result.outputObject
        response["scheduling"] = .string(scheduling.rawValue)
        var functionResponse: [String: JSONValue] = [
            "id": .string(result.callID), "name": .string(result.name), "response": .object(response),
        ]
        if !images.isEmpty {
            functionResponse["parts"] = .array(images.map {
                ["inlineData": ["mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())]]
            })
        }
        return ["toolResponse": ["functionResponses": [.object(functionResponse)]]]
    }

    static func usage(_ metadata: JSONValue?) -> RealtimeUsage? {
        guard let metadata, metadata.objectValue != nil else { return nil }
        func audioTokens(_ details: JSONValue?) -> Int? {
            details?.arrayValue?.first { $0["modality"]?.stringValue == "AUDIO" }?["tokenCount"]?.intValue
        }
        return RealtimeUsage(inputTokens: metadata["promptTokenCount"]?.intValue ?? 0,
                             outputTokens: metadata["responseTokenCount"]?.intValue ?? 0,
                             inputAudioTokens: audioTokens(metadata["promptTokensDetails"]),
                             outputAudioTokens: audioTokens(metadata["responseTokensDetails"]))
    }
}
