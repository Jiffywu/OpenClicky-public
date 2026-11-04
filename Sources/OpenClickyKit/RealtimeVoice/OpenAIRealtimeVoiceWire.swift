// OpenAI Realtime API (GA interface) messages for a full speech-to-speech session: the realtime-voice slot.
//
// Checked on 2026-10-31 against:
//   https://developers.openai.com/api/reference/resources/realtime/client-events
//   https://developers.openai.com/api/reference/resources/realtime/server-events
//   https://developers.openai.com/api/docs/guides/realtime-conversations
//
// What those pages settle:
// - `session.update` takes `session.type = "realtime"`, `output_modalities` (audio or text, not both), `instructions`,
//   `audio.input.{format, transcription, turn_detection, noise_reduction}`, `audio.output.{format, voice, speed}`,
//   `tools` (`{type:"function", name, description, parameters}`) and `tool_choice`.
// - Input PCM must be 24 kHz ("Only a 24kHz sample rate is supported"); output PCM is 24 kHz too.
// - `turn_detection` `server_vad` fields: `threshold` (0…1, default 0.5), `prefix_padding_ms` (300), `silence_duration_ms`
//   (500), `create_response` and `interrupt_response` (both default true), `idle_timeout_ms`. `null` turns it off.
// - `noise_reduction.type` is `near_field` or `far_field`; `null` turns it off.
// - `transcription.model` accepts `gpt-transcribe`, `gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, `whisper-1`.
// - Function calls arrive as `response.function_call_arguments.done{call_id, name, arguments, item_id}` and as
//   `function_call` items in `response.output_item.done` / `response.done`. The answer is a
//   `conversation.item.create{item:{type:"function_call_output", call_id, output}}` followed by `response.create`.
// - Images: `conversation.item.create` with a user message whose content has `{type:"input_image", image_url:<data URI>}`
//   (PNG or JPEG; `detail` auto/low/high).
// - `conversation.item.truncate{item_id, content_index:0, audio_end_ms}` cuts an assistant item to what was heard;
//   `audio_end_ms` must not exceed the item's audio. `response.cancel` takes an optional `response_id`.
// - `response.done.response.status` is completed / cancelled / failed / incomplete; a reply stopped by server VAD is
//   `cancelled` with `status_details.reason = "turn_detected"`.

import Foundation

enum OpenAIRealtimeVoiceWire {
    static let format: JSONValue = ["type": "audio/pcm", "rate": 24_000]
    /// About 100 ms of 24 kHz PCM16 per append, well under the 15 MiB event cap.
    static let maxAudioChunkBytes = 4_800

    static func sessionUpdate(_ configuration: RealtimeSessionConfiguration, voice: String, transcriptionModel: String) -> JSONValue {
        var input: [String: JSONValue] = ["format": format]
        if configuration.transcribeInput {
            var transcription: [String: JSONValue] = ["model": .string(transcriptionModel)]
            if let language = configuration.language?.trimmingCharacters(in: .whitespaces), !language.isEmpty {
                transcription["language"] = .string(String(language.prefix(2)).lowercased())
            }
            input["transcription"] = .object(transcription)
        }
        input["turn_detection"] = turnDetection(configuration.turnDetection)
        input["noise_reduction"] = configuration.noiseReduction.map { ["type": .string($0.rawValue)] } ?? .null

        var output: [String: JSONValue] = ["format": format, "voice": OpenAIRealtimeWire.voiceValue(voice)]
        if let speed = configuration.speed { output["speed"] = .number(min(max(speed, 0.25), 1.5)) }

        var session: [String: JSONValue] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "instructions": .string(configuration.instructions),
            "audio": ["input": .object(input), "output": .object(output)],
        ]
        if !configuration.tools.isEmpty {
            session["tools"] = .array(configuration.tools.map(tool))
            session["tool_choice"] = "auto"
        }
        return ["type": "session.update", "session": .object(session)]
    }

    static func turnDetection(_ detection: RealtimeTurnDetection) -> JSONValue {
        guard case .serverVAD(let vad) = detection else { return .null }
        var object: [String: JSONValue] = [
            "type": "server_vad",
            "create_response": .bool(vad.autoRespond),
            "interrupt_response": .bool(vad.interruptsResponse),
        ]
        if let threshold = vad.threshold { object["threshold"] = .number(min(max(threshold, 0), 1)) }
        if let padding = vad.prefixPadding { object["prefix_padding_ms"] = .number(Double(padding.realtimeMilliseconds)) }
        if let silence = vad.silence { object["silence_duration_ms"] = .number(Double(silence.realtimeMilliseconds)) }
        return .object(object)
    }

    static func tool(_ spec: ToolSpec) -> JSONValue {
        ["type": "function", "name": .string(spec.name), "description": .string(spec.description), "parameters": spec.parameters]
    }

    static func appendAudio(_ pcm: Data) -> JSONValue {
        ["type": "input_audio_buffer.append", "audio": .string(pcm.base64EncodedString())]
    }

    static let commitAudio: JSONValue = ["type": "input_audio_buffer.commit"]
    static let clearAudio: JSONValue = ["type": "input_audio_buffer.clear"]

    static func userText(_ text: String) -> JSONValue {
        ["type": "conversation.item.create",
         "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(text)]]]]
    }

    static func userImage(itemID: String, data: Data, mimeType: String, caption: String?) -> JSONValue {
        var content: [JSONValue] = [[
            "type": "input_image",
            "image_url": .string("data:\(mimeType);base64,\(data.base64EncodedString())"),
        ]]
        if let caption, !caption.isEmpty { content.append(["type": "input_text", "text": .string(caption)]) }
        return ["type": "conversation.item.create",
                "item": ["id": .string(itemID), "type": "message", "role": "user", "content": .array(content)]]
    }

    static func functionOutput(_ result: RealtimeToolResult) -> JSONValue {
        let output: String
        if case .string(let text) = result.output { output = text } else { output = result.output.jsonString() }
        return ["type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": .string(result.callID), "output": .string(output)]]
    }

    static func responseCreate(instructions: String?) -> JSONValue {
        guard let instructions, !instructions.isEmpty else { return ["type": "response.create"] }
        return ["type": "response.create", "response": ["instructions": .string(instructions)]]
    }

    static let responseCancel: JSONValue = ["type": "response.cancel"]

    static func truncate(itemID: String, audioEndMilliseconds: Int) -> JSONValue {
        ["type": "conversation.item.truncate", "item_id": .string(itemID), "content_index": 0,
         "audio_end_ms": .number(Double(max(0, audioEndMilliseconds)))]
    }

    static func deleteItem(_ itemID: String) -> JSONValue {
        ["type": "conversation.item.delete", "item_id": .string(itemID)]
    }

    static func instructionsUpdate(_ instructions: String) -> JSONValue {
        ["type": "session.update", "session": ["type": "realtime", "instructions": .string(instructions)]]
    }

    /// `response.done.response` → status, mapping a VAD-stopped reply to `.interrupted`.
    static func status(of response: JSONValue?) -> RealtimeResponseStatus {
        switch response?["status"]?.stringValue {
        case "completed"?: return .completed
        case "cancelled"?:
            let reason = response?["status_details"]?["reason"]?.stringValue
            return reason == "turn_detected" ? .interrupted : .cancelled
        case "incomplete"?: return .incomplete
        case "failed"?: return .failed
        default: return .completed
        }
    }

    static func usage(of response: JSONValue?) -> RealtimeUsage? {
        guard let usage = response?["usage"], usage.objectValue != nil else { return nil }
        return RealtimeUsage(inputTokens: usage["input_tokens"]?.intValue ?? 0,
                             outputTokens: usage["output_tokens"]?.intValue ?? 0,
                             inputAudioTokens: usage["input_token_details"]?["audio_tokens"]?.intValue,
                             outputAudioTokens: usage["output_token_details"]?["audio_tokens"]?.intValue)
    }

    /// Error codes that only mean a cancel or delete found nothing to act on.
    static let harmlessErrorCodes: Set<String> = ["response_cancel_not_active", "conversation_already_has_active_response"]
}
