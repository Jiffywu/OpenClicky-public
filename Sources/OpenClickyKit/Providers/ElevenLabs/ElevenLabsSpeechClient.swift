// ElevenLabs text-to-speech for the voice slot (dialect "elevenlabs-speech").
//
// Wire protocol, checked against ElevenLabs' own docs on 2026-10-30:
// - Streaming endpoint: https://elevenlabs.io/docs/api-reference/text-to-speech/stream
//   `POST {base}/v1/text-to-speech/{voice_id}/stream?output_format=pcm_24000`, auth header `xi-api-key`,
//   JSON body `{text, model_id, voice_settings?}`. `voice_settings` fields: stability, similarity_boost, style,
//   use_speaker_boost, speed. `output_format` PCM values: pcm_8000, pcm_16000, pcm_22050, pcm_24000, pcm_32000,
//   pcm_44100 (Pro plan and above), pcm_48000. A 200 response body is the raw audio, streamed.
// - PCM layout: https://elevenlabs.io/docs/overview/capabilities/text-to-speech says the PCM formats are
//   S16LE (16-bit) and calls them mono. That matches OpenClicky's `PCMFormat` (16-bit LE) with one channel.
// - Errors: https://elevenlabs.io/docs/eleven-api/resources/errors says every error body is `{"detail": {...}}`
//   with `type`, `code`, `message`, `status` (legacy), `request_id` and `param`. The streaming reference above
//   instead documents 422 as `{"detail": [{"loc": [...], "msg": "...", "type": "..."}]}`. The docs disagree, so
//   both shapes are parsed, plus a bare string `detail`. Anything else falls back to the raw body text.
//
// Regional servers (`https://api.us.elevenlabs.io`, `https://api.eu.residency.elevenlabs.io`, ...) work by
// setting the provider's `baseURL`. The base may also end in `/v1`, matching how other providers are configured.

import Foundation
import os

/// Optional `voice_settings` for an ElevenLabs request. Fields left nil are not sent, so the voice's own stored
/// settings apply.
public struct ElevenLabsVoiceSettings: Sendable, Hashable {
    public var stability: Double?
    public var similarityBoost: Double?
    public var style: Double?
    public var useSpeakerBoost: Bool?
    /// 1.0 is normal speed.
    public var speed: Double?

    public init(stability: Double? = nil, similarityBoost: Double? = nil, style: Double? = nil,
                useSpeakerBoost: Bool? = nil, speed: Double? = nil) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
        self.speed = speed
    }

    /// The wire object, or nil when nothing is set.
    var json: JSONValue? {
        var object: [String: JSONValue] = [:]
        if let stability { object["stability"] = .number(stability) }
        if let similarityBoost { object["similarity_boost"] = .number(similarityBoost) }
        if let style { object["style"] = .number(style) }
        if let useSpeakerBoost { object["use_speaker_boost"] = .bool(useSpeakerBoost) }
        if let speed { object["speed"] = .number(speed) }
        return object.isEmpty ? nil : .object(object)
    }
}

/// Speaks lines through ElevenLabs' streaming text-to-speech endpoint and yields raw 16-bit PCM as it arrives.
///
/// `voice` is an ElevenLabs voice id (voices are per account); nil or blank uses `defaultVoice`. The
/// `instructions` argument of `speak` is ignored: this endpoint has no field for spoken-style instructions.
///
/// Cancelling the consuming task, or calling `stopAll()`, cancels the HTTP request. The line's stream then ends
/// without `.lineFinished` and without an error. Every other failure is thrown: HTTP errors as `ProviderError`,
/// network failures as the transport's error.
public final class ElevenLabsSpeechClient: SpeechOutputClient {
    public static let defaultBaseURL = "https://api.elevenlabs.io"
    public static let defaultModel = "eleven_flash_v2_5"
    /// Sample rates that have a documented `pcm_<rate>` output format.
    public static let supportedSampleRates: Set<Int> = [8_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    public let model: String
    public let defaultVoice: String?
    public let voiceSettings: ElevenLabsVoiceSettings?
    /// The format of every `.audio` event: mono 16-bit PCM at the requested sample rate.
    public let outputFormat: PCMFormat

    private let context: ProviderContext
    private let inFlight = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])
    /// When `warmUp` last opened the connection.
    private let lastWarmUp = OSAllocatedUnfairLock<Date?>(initialState: nil)
    /// `warmUp` skips the round trip when it opened the connection this recently (it is still in the pool).
    public static let warmUpInterval: TimeInterval = 30

    /// - Parameters:
    ///   - model: The ElevenLabs `model_id`, e.g. `eleven_flash_v2_5` or `eleven_multilingual_v2`.
    ///   - defaultVoice: The voice id used when `speak` is called with `voice: nil`.
    ///   - voiceSettings: Sent as `voice_settings` on every request when set.
    ///   - sampleRate: Picks the `pcm_<rate>` output format. Must be one of `supportedSampleRates`.
    public init(context: ProviderContext, model: String = ElevenLabsSpeechClient.defaultModel, defaultVoice: String? = nil,
                voiceSettings: ElevenLabsVoiceSettings? = nil, sampleRate: Int = 24_000) {
        self.context = context
        self.model = model
        self.defaultVoice = defaultVoice
        self.voiceSettings = voiceSettings
        self.outputFormat = PCMFormat(sampleRate: sampleRate, channels: 1)
    }

    public func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            // Register under the lock that the task's own cleanup takes, so a fast-finishing task cannot remove
            // its entry before it is added.
            let task: Task<Void, Never> = inFlight.withLock { tasks in
                let task = Task {
                    defer { self.forget(id) }
                    do {
                        try await self.run(text: text, voice: voice, continuation: continuation)
                        continuation.finish()
                    } catch {
                        // Only our own cancellation (the consumer went away, or stopAll()) ends a line quietly.
                        // URLSession also reports a cancelled auth challenge or an invalidated session as
                        // URLError(.cancelled); swallowing that would end the line in silence with no error.
                        if Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                    }
                }
                tasks[id] = task
                return task
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the HTTPS connection to ElevenLabs before the first line (the turn's key-down), so that line skips the
    /// TCP and TLS handshakes: a `HEAD` of the API host, without the key; its answer doesn't matter. Skipped when it ran
    /// in the last `warmUpInterval` seconds.
    public func warmUp() async {
        let now = Date()
        let due = lastWarmUp.withLock { last -> Bool in
            if let last, now.timeIntervalSince(last) < Self.warmUpInterval { return false }
            last = now
            return true
        }
        guard due else { return }
        var base = context.provider.baseURL?.absoluteString ?? Self.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + "/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await context.http.data(for: request)
    }

    public func stopAll() async {
        let tasks = inFlight.withLock { tasks in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    private func forget(_ id: UUID) {
        inFlight.withLock { _ = $0.removeValue(forKey: id) }
    }

    private func run(text: String, voice: String?,
                     continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation) async throws {
        guard let request = try makeRequest(text: text, voice: voice) else {
            continuation.yield(.lineFinished)
            return
        }
        // Binary mode: audio bytes are handed on as they arrive, not held back looking for newlines.
        let (body, response) = try await context.http.stream(for: request, mode: .binary)
        guard (200..<300).contains(response.statusCode) else {
            throw await Self.providerError(provider: context.provider.id, status: response.statusCode, body: body)
        }
        var chunker = PCMChunker(frameBytes: outputFormat.channels * 2,
                                 minimumBytes: outputFormat.bytesPerSecond / PCMChunker.chunksPerSecond)
        for try await chunk in body {
            if let audio = chunker.feed(chunk) { continuation.yield(.audio(audio, outputFormat)) }
        }
        // A cancelled body stream ends quietly instead of throwing, so check before claiming the line is complete.
        try Task.checkCancellation()
        if let audio = chunker.finish() { continuation.yield(.audio(audio, outputFormat)) }
        continuation.yield(.lineFinished)
    }

    /// The request for one line, or nil when there is nothing to say.
    func makeRequest(text: String, voice: String?) throws -> URLRequest? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let provider = context.provider.id
        guard let apiKey = context.apiKey, !apiKey.isEmpty else {
            throw ProviderError(provider: provider, message: "No ElevenLabs API key is configured for this provider.")
        }
        // A blank `voice` (an empty settings field) means "no choice", so it falls back to the default voice.
        let voiceID = [voice, defaultVoice].lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !voiceID.isEmpty else {
            throw ProviderError(provider: provider, message: "No ElevenLabs voice id was chosen for the voice slot.")
        }
        guard Self.supportedSampleRates.contains(outputFormat.sampleRate) else {
            throw ProviderError(provider: provider, message: "ElevenLabs has no pcm_\(outputFormat.sampleRate) output format.")
        }

        var body: [String: JSONValue] = ["text": .string(text), "model_id": .string(model)]
        if let settings = voiceSettings?.json { body["voice_settings"] = settings }
        return context.jsonRequest(endpoint(voiceID: voiceID), body: .object(body), headers: ["xi-api-key": apiKey])
    }

    private func endpoint(voiceID: String) -> URL {
        var base = context.provider.baseURL?.absoluteString ?? Self.defaultBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        let version = base.hasSuffix("/v1") ? "" : "v1/"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encodedVoice = voiceID.addingPercentEncoding(withAllowedCharacters: allowed) ?? voiceID
        let url = context.url("\(version)text-to-speech/\(encodedVoice)/stream", default: Self.defaultBaseURL)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "output_format", value: "pcm_\(outputFormat.sampleRate)")]
        return components.url ?? url
    }

    // MARK: - Errors

    static func providerError(provider: String, status: Int, body: AsyncThrowingStream<Data, Error>) async -> ProviderError {
        var data = Data()
        do {
            for try await chunk in body {
                data.append(chunk)
                if data.count >= 16_384 { break }
            }
        } catch {
            // Keep whatever arrived; the status alone still explains the failure.
        }
        return ProviderError(provider: provider, status: status, message: errorMessage(from: data, status: status))
    }

    /// The human message inside an ElevenLabs error body.
    static func errorMessage(from body: Data, status: Int) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: body), let detail = json["detail"] {
            switch detail {
            case .string(let message) where !message.isEmpty:
                return message
            case .object(let object):
                // Documented envelope: {type, code, message, status (legacy), request_id, param}.
                if let message = object["message"]?.stringValue, !message.isEmpty { return message }
                if let code = object["code"]?.stringValue ?? object["status"]?.stringValue ?? object["type"]?.stringValue {
                    return code
                }
            case .array(let items):
                // Validation shape from the endpoint reference: [{loc: [...], msg, type}].
                let messages = items.compactMap { item -> String? in
                    guard let message = item["msg"]?.stringValue else { return nil }
                    let location = (item["loc"]?.arrayValue ?? [])
                        .compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
                        .joined(separator: ".")
                    return location.isEmpty ? message : "\(location): \(message)"
                }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            default:
                break
            }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
    }
}

// The context holds the API key, so printing, debug-printing or dumping the client shows only safe fields.
extension ElevenLabsSpeechClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ElevenLabsSpeechClient(provider: \(context.provider.id), model: \(model), voice: \(defaultVoice ?? "none"), "
            + "format: pcm_\(outputFormat.sampleRate))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "defaultVoice": defaultVoice as Any,
                                "voiceSettings": voiceSettings as Any, "outputFormat": outputFormat],
               displayStyle: .class)
    }
}

extension ElevenLabsSpeechClient {
    /// Re-chunks a raw PCM byte stream so every emitted chunk holds whole samples. Network chunks split samples
    /// anywhere (and a line-mode transport flushes on every 0x0A byte), so a trailing partial sample is carried into
    /// the next chunk. Small pieces are held until `minimumBytes` (20 ms of audio) so playback is not handed hundreds
    /// of tiny buffers per second. Nothing waits for the whole response. Nested so the name cannot collide with
    /// another adapter's helper in this module.
    struct PCMChunker: Sendable {
        static let chunksPerSecond = 50

        let frameBytes: Int
        let minimumBytes: Int
        private var pending = Data()

        init(frameBytes: Int, minimumBytes: Int) {
            self.frameBytes = max(frameBytes, 1)
            self.minimumBytes = max(minimumBytes, self.frameBytes)
        }

        mutating func feed(_ chunk: Data) -> Data? {
            pending.append(chunk)
            guard pending.count >= minimumBytes else { return nil }
            return takeWholeFrames()
        }

        /// Flushes the remaining whole samples. A dangling partial sample at the very end is dropped.
        mutating func finish() -> Data? {
            defer { pending.removeAll() }
            return takeWholeFrames()
        }

        private mutating func takeWholeFrames() -> Data? {
            let count = pending.count - pending.count % frameBytes
            guard count > 0 else { return nil }
            let out = Data(pending.prefix(count))
            pending = Data(pending.dropFirst(count))
            return out
        }
    }
}
