// OpenAI text-to-speech for the voice slot (dialect "openai-speech").
//
// Wire protocol checked on 2026-10-30 against:
// - API reference, POST /audio/speech:
//   https://developers.openai.com/api/reference/resources/audio/subresources/speech/methods/create
//   JSON body: `model`, `input` (max 4096 characters), `voice` (a built-in name, or `{"id": "voice_…"}` for a
//   custom voice), `instructions` (max 4096 characters, "Does not work with `tts-1` or `tts-1-hd`"),
//   `response_format` (mp3 | opus | aac | flac | wav | pcm, default mp3), `speed` (0.25–4.0, default 1),
//   `stream_format` (audio | sse, default audio). Auth: `Authorization: Bearer <key>`. The response is the audio file
//   content (`application/octet-stream`).
// - Text-to-speech guide: https://developers.openai.com/api/docs/guides/text-to-speech
//   "PCM: Similar to WAV but contains the raw samples in 24kHz (16-bit signed, low-endian), without the header."
//   The guide does not state the channel count; its Java PCM example plays the stream as
//   `AudioFormat(24_000, 16, 1, true, false)`, which is mono, signed and little-endian, so that is what we report.
//   "The Speech API provides support for realtime audio streaming using chunk transfer encoding", so the body is
//   playable while it downloads.
//   The same pages say tts-1, tts-1-hd and gpt-4o-mini-tts shut down on January 6, 2027.
// - Error body, `ErrorResponse` / `Error` in the OpenAPI spec (https://github.com/openai/openai-openapi):
//   `{"error": {"message": String, "type": String, "param": String?, "code": String?}}`. The spec documents 401 and
//   403 as `text/plain` "JSON-encoded error text", so the body is parsed as JSON whatever its Content-Type.
// - 200 response content types in the same spec: `application/octet-stream`, `audio/pcm`, `audio/wav`, `audio/mpeg`,
//   `audio/aac`, `audio/opus`, `audio/flac`, `text/event-stream`, with `Transfer-Encoding: chunked`. A 2xx carrying
//   a compressed or text type means the server ignored `response_format: "pcm"`, so the line fails rather than
//   playing it as samples (see `nonPCMKind`).
//
// `stream_format` is left at its default, `audio`: raw PCM bytes over chunked transfer. The `sse` variant wraps the
// same audio in base64 JSON events and the docs say tts-1 and tts-1-hd do not support it.

import Foundation

/// Speaks lines through OpenAI's `/audio/speech` endpoint (or a server that implements it), streaming raw 24 kHz
/// PCM as the response body arrives.
public struct OpenAISpeechClient: SpeechOutputClient {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let defaultModel = "gpt-4o-mini-tts"
    /// The `pcm` response format: 24 kHz, 16-bit signed little-endian, mono, no header.
    public static let outputFormat = PCMFormat.speech24k
    /// The documented maximum length of `input` and of `instructions`.
    public static let maxInputLength = 4096

    public let model: String
    /// Used when `speak` is called without a voice.
    public let defaultVoice: String
    /// Playback speed sent as `speed`, clamped to the documented 0.25–4.0. Nil leaves the provider default (1.0).
    public let speed: Double?

    private let context: ProviderContext
    private let inFlight = InFlightSpeech()

    /// - Parameters:
    ///   - model: The speech model id, e.g. `gpt-4o-mini-tts`, `tts-1`, `tts-1-hd`.
    ///   - defaultVoice: The voice for lines spoken without one. Nil picks `cedar` (OpenAI recommends `marin` or
    ///     `cedar`), or `alloy` for the tts-1 models, which do not have `cedar`.
    ///   - speed: Optional playback speed, 0.25–4.0.
    public init(context: ProviderContext, model: String = OpenAISpeechClient.defaultModel, defaultVoice: String? = nil,
                speed: Double? = nil) {
        self.context = context
        self.model = model
        self.defaultVoice = defaultVoice.flatMap(Self.nonBlank) ?? Self.fallbackVoice(for: model)
        self.speed = speed
    }

    public func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        let voice = voice.flatMap(Self.nonBlank) ?? defaultVoice
        let requests = Self.segments(of: text).map { makeRequest(input: $0, voice: voice, instructions: instructions) }
        let http = context.http
        let providerID = context.provider.id
        let format = Self.outputFormat

        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        // Register before the task exists so onTermination is in place however quickly the task ends.
        let id = inFlight.reserve()
        let inFlight = inFlight
        continuation.onTermination = { _ in inFlight.end(id) }
        let task = Task {
            do {
                for request in requests {
                    try Task.checkCancellation()
                    // Binary mode: audio bytes are handed on as they arrive, not held back looking for newlines.
                    let (body, response) = try await http.stream(for: request, mode: .binary)
                    guard (200..<300).contains(response.statusCode) else {
                        throw try await Self.providerError(status: response.statusCode, body: body, provider: providerID)
                    }
                    if let mediaType = Self.mediaType(of: response), let kind = Self.nonPCMKind(mediaType) {
                        throw try await Self.notPCMError(kind, mediaType: mediaType, status: response.statusCode,
                                                         body: body, provider: providerID)
                    }
                    var aligner = PCMFrameAligner(frameSize: format.channels * 2)
                    for try await chunk in body {
                        let frames = aligner.push(chunk)
                        if !frames.isEmpty { continuation.yield(.audio(frames, format)) }
                    }
                    // A cancelled body ends its loop quietly; do not report a cut-off line as finished.
                    try Task.checkCancellation()
                }
                continuation.yield(.lineFinished)
                continuation.finish()
            } catch {
                // URLSession reports a request cancelled before its headers arrive as URLError(.cancelled), so a
                // stopAll() would otherwise look like a network failure. A cancelled line always ends with
                // CancellationError.
                continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
            }
        }
        inFlight.attach(task, to: id)
        return stream
    }

    /// Cancels every line in flight. Their streams end with `CancellationError` and never yield `.lineFinished`.
    public func stopAll() async {
        inFlight.cancelAll()
    }

    /// Lines currently being synthesized (for tests).
    var inFlightCount: Int { inFlight.count }

    // MARK: - Request

    func makeRequest(input: String, voice: String, instructions: String?) -> URLRequest {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .string(input),
            "voice": Self.voiceValue(voice),
            "response_format": "pcm",
        ]
        if Self.supportsInstructions(model: model), let instructions = instructions.flatMap(Self.nonBlank) {
            body["instructions"] = .string(Self.prefix(instructions, maxScalars: Self.maxInputLength))
        }
        // A non-finite speed is left out: JSONEncoder cannot encode NaN or infinity, and JSONValue.jsonString()
        // would then send the literal body `null`.
        if let speed, speed.isFinite { body["speed"] = .number(min(max(speed, 0.25), 4.0)) }
        var headers: [String: String] = [:]
        if let key = context.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        return context.jsonRequest(context.url("audio/speech", default: Self.defaultBaseURL), body: .object(body), headers: headers)
    }

    /// The API reference documents `instructions` as not working with `tts-1` or `tts-1-hd` (and their dated
    /// snapshots, which share the prefix).
    static func supportsInstructions(model: String) -> Bool { !model.hasPrefix("tts-1") }

    static func fallbackVoice(for model: String) -> String { model.hasPrefix("tts-1") ? "alloy" : "cedar" }

    /// The API takes built-in voices by name and custom voices as `{"id": "voice_…"}`.
    static func voiceValue(_ voice: String) -> JSONValue {
        voice.hasPrefix("voice_") ? ["id": .string(voice)] : .string(voice)
    }

    // MARK: - Errors

    /// Reads up to 16 KB of an error body and prefers the documented `error.message`, falling back to the raw text.
    static func providerError(status: Int, body: AsyncThrowingStream<Data, Error>, provider: String) async throws -> ProviderError {
        providerError(status: status, body: try await readPrefix(of: body), provider: provider)
    }

    static func providerError(status: Int, body: Data, provider: String) -> ProviderError {
        if let message = errorMessage(in: body) { return ProviderError(provider: provider, status: status, message: message) }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(provider: provider, status: status,
                             message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }

    /// The documented `{"error": {"message": …}}`, if the body is that.
    static func errorMessage(in body: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return nil }
        return json["error"]?["message"]?.stringValue.flatMap(nonBlank)
    }

    static func readPrefix(of body: AsyncThrowingStream<Data, Error>, limit: Int = 16_384) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data.prefix(limit)
    }

    // MARK: - Response format

    /// What a 2xx body is when it is not the raw PCM we asked for.
    enum NonPCMKind: Equatable {
        /// Compressed audio: the server ignored `response_format: "pcm"`.
        case encodedAudio
        /// Text, JSON or SSE: an error page, a misrouted base URL, or `stream_format: sse` events.
        case text
    }

    /// The response's media type, lowercased and without parameters; nil if there is no Content-Type.
    static func mediaType(of response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let type = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        let trimmed = type.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Classifies a 2xx Content-Type that cannot be raw samples. The OpenAPI spec documents `audio/pcm` and
    /// `application/octet-stream` for `pcm`, `audio/mpeg|aac|opus|flac` for the compressed formats and
    /// `text/event-stream` for `stream_format: sse`. `audio/mp3`, `audio/ogg`, `audio/webm` and the `x-` names are
    /// common aliases on OpenAI-compatible servers. Anything else, including `audio/wav` (PCM with a header), a
    /// missing type and unfamiliar binary types, is played as PCM, so a lenient compatible server still works.
    static func nonPCMKind(_ mediaType: String) -> NonPCMKind? {
        let encoded: Set<String> = ["audio/mpeg", "audio/mp3", "audio/aac", "audio/x-aac", "audio/opus", "audio/ogg",
                                    "audio/flac", "audio/x-flac", "audio/webm", "audio/mp4"]
        if encoded.contains(mediaType) { return .encodedAudio }
        if mediaType.hasPrefix("text/") || mediaType == "application/json" || mediaType.hasSuffix("+json") { return .text }
        return nil
    }

    /// A 2xx whose body is not PCM. Playing it as samples would be loud noise, so the line fails instead.
    static func notPCMError(_ kind: NonPCMKind, mediaType: String, status: Int, body: AsyncThrowingStream<Data, Error>,
                            provider: String) async throws -> ProviderError {
        let expected = "Expected raw PCM audio (response_format \"pcm\") but the server sent \(mediaType)"
        guard kind == .text else { return ProviderError(provider: provider, status: status, message: expected + ".") }
        let data = try await readPrefix(of: body, limit: 4_096)
        if let message = errorMessage(in: data) { return ProviderError(provider: provider, status: status, message: message) }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(provider: provider, status: status,
                             message: text.isEmpty ? expected + "." : "\(expected): \(text.prefix(512))")
    }

    // MARK: - Text

    /// Splits a line into pieces within the API's 4096-character `input` limit, cutting after a sentence where
    /// possible, else at a space. Counts Unicode scalars, which is how JSON Schema's `maxLength` (the spec's
    /// `maxLength: 4096`) counts characters, and never splits a grapheme. Blank text yields no pieces.
    static func segments(of text: String, maxScalars: Int = maxInputLength) -> [String] {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var pieces: [String] = []
        let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
        let closingSentenceEnds: Set<Character> = ["。", "！", "？"]
        while !rest.isEmpty {
            if rest.unicodeScalars.count <= maxScalars {
                pieces.append(String(rest))
                break
            }
            var index = rest.startIndex
            var scalars = 0
            var sentenceCut: Substring.Index?
            var spaceCut: Substring.Index?
            while index < rest.endIndex {
                let character = rest[index]
                scalars += character.unicodeScalars.count
                if scalars > maxScalars { break }
                let next = rest.index(after: index)
                if character.isNewline || closingSentenceEnds.contains(character)
                    || (sentenceEnds.contains(character) && (next == rest.endIndex || rest[next].isWhitespace)) {
                    sentenceCut = next
                } else if character.isWhitespace {
                    spaceCut = index
                }
                index = next
            }
            var cut = sentenceCut ?? spaceCut ?? index
            if cut == rest.startIndex { cut = rest.index(after: cut) }  // always make progress
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop(while: \.isWhitespace)
        }
        return pieces
    }

    static func prefix(_ text: String, maxScalars: Int) -> String {
        guard text.unicodeScalars.count > maxScalars else { return text }
        var result = ""
        var scalars = 0
        for character in text {
            scalars += character.unicodeScalars.count
            if scalars > maxScalars { break }
            result.append(character)
        }
        return result
    }

    static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// Keep the API key out of logs: the default description and dump() would print the stored context.
extension OpenAISpeechClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OpenAISpeechClient(provider: \(context.provider.id), model: \(model), voice: \(defaultVoice))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "defaultVoice": defaultVoice,
                                "speed": speed as Any], displayStyle: .struct)
    }
}

/// Holds back a trailing partial frame so every chunk handed on is whole 16-bit samples, whatever the network's
/// chunk boundaries. A partial frame left when the body ends is dropped.
struct PCMFrameAligner {
    let frameSize: Int
    private var carry = Data()

    init(frameSize: Int) { self.frameSize = max(frameSize, 1) }

    mutating func push(_ chunk: Data) -> Data {
        var bytes = carry
        bytes.append(chunk)
        let whole = bytes.count - bytes.count % frameSize
        carry = Data(bytes[(bytes.startIndex + whole)...])
        return Data(bytes[..<(bytes.startIndex + whole)])
    }

    var pendingByteCount: Int { carry.count }
}

/// The synthesis tasks a client has running, so `stopAll` can cancel them. An id is reserved before its task is
/// created, so a stream that terminates (or a `stopAll`) before the task is attached still cancels it.
final class InFlightSpeech: @unchecked Sendable {
    private enum Entry {
        case reserved(cancelled: Bool)
        case running(Task<Void, Never>)
    }

    private let lock = NSLock()
    private var nextID = 0
    private var entries: [Int: Entry] = [:]

    func reserve() -> Int {
        lock.withLock {
            nextID += 1
            entries[nextID] = .reserved(cancelled: false)
            return nextID
        }
    }

    func attach(_ task: Task<Void, Never>, to id: Int) {
        let cancelNow: Bool = lock.withLock {
            switch entries[id] {
            case .reserved(cancelled: false):
                entries[id] = .running(task)
                return false
            case .reserved(cancelled: true):
                entries[id] = .running(task)
                return true
            case .running, nil:
                return true  // already ended
            }
        }
        if cancelNow { task.cancel() }
    }

    /// The stream terminated (finished, failed or its consumer went away): stop the work and forget it.
    func end(_ id: Int) {
        let entry = lock.withLock { entries.removeValue(forKey: id) }
        if case .running(let task) = entry { task.cancel() }
    }

    func cancelAll() {
        let running: [Task<Void, Never>] = lock.withLock {
            var tasks: [Task<Void, Never>] = []
            for (id, entry) in entries {
                switch entry {
                case .reserved: entries[id] = .reserved(cancelled: true)
                case .running(let task): tasks.append(task)
                }
            }
            return tasks
        }
        running.forEach { $0.cancel() }
    }

    var count: Int { lock.withLock { entries.count } }
}
