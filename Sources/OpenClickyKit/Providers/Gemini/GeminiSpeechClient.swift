// Gemini text-to-speech for the voice slot (dialect "gemini-speech"): one streamed request per line, the way
// HeyClicky's Gemini voices speak each line with gemini-3.8-flash-lite-tts. HeyClicky goes through its own server;
// OpenClicky calls Google with the user's API key. Wire details and doc links are in GeminiSpeechWire.swift.

import Foundation

/// Speaks lines with a Gemini TTS model through the Interactions API, streaming 16-bit PCM as it is synthesized.
///
/// `voice` is a prebuilt voice name (`Kore`, `Puck`, …; a `gemini:` prefix and any casing are accepted) or a custom
/// voice id (`voice_…`). `instructions` become the line's `speech_metadata` style (for example "calm, unhurried");
/// the text itself is spoken verbatim.
///
/// Cancelling the consuming task, or `stopAll()`, cancels the request; the line's stream then ends with
/// `CancellationError` and never yields `.lineFinished`. Other failures are thrown as `ProviderError` (HTTP errors,
/// in-stream `error` events, a stream that ends early or carries no audio) or as the transport's error.
public struct GeminiSpeechClient: SpeechOutputClient {
    public static let defaultBaseURL = GeminiSpeechWire.defaultBaseURL
    /// The model HeyClicky's Gemini voices use.
    public static let defaultModel = "gemini-3.8-flash-lite-tts"
    public static let defaultVoice = "Kore"
    public static var prebuiltVoices: [String] { GeminiSpeechWire.prebuiltVoices }

    public struct Options: Sendable, Hashable {
        /// `response_format.sample_rate`. The guide's examples name 24000 (the default), 16000 and 8000.
        public var sampleRate: Int
        /// `store`. False keeps spoken lines out of Google's interaction storage.
        public var store: Bool
        /// Longest audio chunk handed on; larger deltas and unary bodies are split at frame boundaries.
        public var maxChunkDuration: Duration
        /// Longest piece of text per request. The 3.8 TTS models take 8,192 input tokens; 4,000 characters stays well
        /// inside that for any script.
        public var maxInputCharacters: Int
        /// Longest `style` sent. The guide advises short styles; long ones make the voice drift.
        public var maxStyleCharacters: Int
        /// Optional `language` on the speaker config. Nil lets the model detect it, as the guide recommends.
        public var language: String?
        /// The `generation_config` key for the voice list: `speech_config` in the guide's samples,
        /// `structured_speech_config` in the API reference.
        public var speechConfigField: String
        /// How often `warmUp()` may touch the network.
        public var warmUpInterval: Duration

        public init(sampleRate: Int = 24_000, store: Bool = false, maxChunkDuration: Duration = .milliseconds(100),
                    maxInputCharacters: Int = 4_000, maxStyleCharacters: Int = 500, language: String? = nil,
                    speechConfigField: String = "speech_config", warmUpInterval: Duration = .seconds(30)) {
            self.sampleRate = sampleRate
            self.store = store
            self.maxChunkDuration = maxChunkDuration
            self.maxInputCharacters = maxInputCharacters
            self.maxStyleCharacters = maxStyleCharacters
            self.language = language
            self.speechConfigField = speechConfigField
            self.warmUpInterval = warmUpInterval
        }
    }

    public let model: String
    /// Used when `speak` is called without a voice.
    public let defaultVoice: String
    public let options: Options

    private let context: ProviderContext
    private let inFlight = InFlightSpeech()
    private let warmGate = GeminiWarmUpGate()

    public init(context: ProviderContext, model: String = GeminiSpeechClient.defaultModel, defaultVoice: String? = nil,
                options: Options = Options()) {
        self.context = context
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.defaultVoice = GeminiSpeechWire.voiceName(defaultVoice) ?? Self.defaultVoice
        self.options = options
    }

    /// The format the request asks for. Audio that says otherwise is reported in its own format.
    public var outputFormat: PCMFormat { PCMFormat(sampleRate: options.sampleRate, channels: 1) }

    public func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        let voice = GeminiSpeechWire.voiceName(voice) ?? defaultVoice
        let style = instructions.map { OpenAISpeechClient.prefix($0.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                 maxScalars: options.maxStyleCharacters) }
        let requests = OpenAISpeechClient.segments(of: text, maxScalars: max(options.maxInputCharacters, 1))
            .map { makeRequest(text: $0, voice: voice, style: style) }
        let http = context.http
        let providerID = context.provider.id
        let requested = outputFormat
        let maxChunkDuration = options.maxChunkDuration

        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        // Register before the task exists so onTermination is in place however quickly the task ends.
        let id = inFlight.reserve()
        let inFlight = inFlight
        continuation.onTermination = { _ in inFlight.end(id) }
        let task = Task {
            do {
                var output = GeminiPCMOutput(requested: requested, maxChunkDuration: maxChunkDuration) {
                    continuation.yield(.audio($0, $1))
                }
                for request in requests {
                    try Task.checkCancellation()
                    try await Self.run(request, http: http, provider: providerID, output: &output)
                    output.flush()
                }
                try Task.checkCancellation()
                if !requests.isEmpty, output.deliveredBytes == 0 {
                    throw ProviderError(provider: providerID, message: "Gemini finished the line without sending any audio.")
                }
                continuation.yield(.lineFinished)
                continuation.finish()
            } catch {
                // URLSession reports a request cancelled before its headers arrive as URLError(.cancelled); a cancelled
                // line always ends with CancellationError.
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

    /// Warms DNS and TLS for the API host with a key-less `HEAD`, at most once per `Options.warmUpInterval`.
    /// Failures are ignored: the first line then simply connects from cold.
    public func warmUp() async {
        guard warmGate.claim(interval: options.warmUpInterval) else { return }
        let url = GeminiSpeechWire.interactionsURL(base: context.provider.baseURL)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.path = "/"
        components.query = nil
        guard let origin = components.url else { return }
        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        _ = try? await context.http.data(for: request)
    }

    /// Lines currently being synthesized (for tests).
    var inFlightCount: Int { inFlight.count }

    // MARK: - Request

    func makeRequest(text: String, voice: String, style: String?) -> URLRequest {
        let body = GeminiSpeechWire.body(model: model, text: text, voice: voice, style: style,
                                         language: options.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                                         sampleRate: options.sampleRate, store: options.store,
                                         speechConfigField: options.speechConfigField)
        // No Accept header: the guide's curl sends none, and `"stream": true` alone selects server-sent events.
        var headers: [String: String] = [:]
        if let key = context.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["x-goog-api-key"] = key
        }
        return context.jsonRequest(GeminiSpeechWire.interactionsURL(base: context.provider.baseURL), body: body, headers: headers)
    }

    // MARK: - Response

    private static func run(_ request: URLRequest, http: any HTTPTransport, provider: String,
                            output: inout GeminiPCMOutput) async throws {
        let (body, response) = try await http.stream(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let data = try await OpenAISpeechClient.readPrefix(of: body)
            throw httpError(status: response.statusCode, body: data, provider: provider)
        }
        let mediaType = OpenAISpeechClient.mediaType(of: response)
        if mediaType == "application/json" || mediaType?.hasSuffix("+json") == true {
            try await readUnary(body, status: response.statusCode, provider: provider, output: &output)
        } else if mediaType == nil || mediaType == "text/event-stream" {
            try await readStream(body, provider: provider, output: &output)
        } else {
            let data = try await OpenAISpeechClient.readPrefix(of: body, limit: 4_096)
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError(provider: provider, status: response.statusCode,
                                message: "Expected Gemini interaction events but the server sent \(mediaType ?? "no content type")"
                                    + (text.isEmpty || mediaType?.hasPrefix("audio/") == true ? "." : ": \(text.prefix(512))"))
        }
    }

    private static func readStream(_ body: AsyncThrowingStream<Data, Error>, provider: String,
                                   output: inout GeminiPCMOutput) async throws {
        var completed = false
        events: for try await sse in body.serverSentEvents() {
            switch GeminiSpeechWire.event(sse) {
            case let .audio(bytes, mimeType, sampleRate, channels):
                try output.append(bytes, mimeType: mimeType, sampleRate: sampleRate, channels: channels, provider: provider)
            case .completed(let status):
                if let status, ["failed", "cancelled", "incomplete"].contains(status.lowercased()) {
                    throw ProviderError(provider: provider, message: "Gemini ended the speech interaction as \(status).")
                }
                completed = true
            case .done:
                completed = true
                break events
            case let .failure(code, message):
                throw ProviderError(provider: provider, status: code.flatMap(Int.init), message: "Gemini speech failed: \(message)")
            case .ignored:
                break
            }
        }
        // A cancelled body ends its loop quietly; do not mistake that for a cut-off stream.
        try Task.checkCancellation()
        guard completed else {
            throw ProviderError(provider: provider, message: "The Gemini speech stream ended before the line was complete.")
        }
    }

    private static func readUnary(_ body: AsyncThrowingStream<Data, Error>, status: Int, provider: String,
                                  output: inout GeminiPCMOutput) async throws {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        try Task.checkCancellation()
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ProviderError(provider: provider, status: status, message: "Gemini sent a speech response that is not JSON.")
        }
        if let error = json["error"] {
            let (code, message) = GeminiSpeechWire.errorParts(error)
            throw ProviderError(provider: provider, status: error["code"]?.intValue ?? code.flatMap(Int.init),
                                message: "Gemini speech failed: \(message)")
        }
        switch GeminiSpeechWire.unaryAudio(json) {
        case let .audio(bytes, mimeType, sampleRate, channels)?:
            try output.append(bytes, mimeType: mimeType, sampleRate: sampleRate, channels: channels, provider: provider)
        case let .failure(_, message)?:
            throw ProviderError(provider: provider, status: status, message: message)
        default:
            throw ProviderError(provider: provider, status: status, message: "Gemini's speech response held no audio.")
        }
    }

    static func httpError(status: Int, body: Data, provider: String) -> ProviderError {
        if let message = GeminiSpeechWire.errorMessage(in: body) {
            return ProviderError(provider: provider, status: status, message: message)
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(provider: provider, status: status,
                             message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : String(text.prefix(1_024)))
    }
}

/// Turns decoded audio blocks into frame-aligned `.audio` events of at most `maxChunkDuration` each. A partial
/// sample at the end of one delta is carried into the next; a WAV header is stripped; a format change flushes first.
struct GeminiPCMOutput {
    let requested: PCMFormat
    let maxChunkDuration: Duration
    let emit: (Data, PCMFormat) -> Void
    private var format: PCMFormat?
    private var aligner = PCMFrameAligner(frameSize: 2)
    private(set) var deliveredBytes = 0

    /// Sample rates and channel counts accepted from the server: telephone-band up to studio rates, mono to 7.1.
    static let playableRates = 4_000...384_000
    static let playableChannels = 1...8

    init(requested: PCMFormat, maxChunkDuration: Duration, emit: @escaping (Data, PCMFormat) -> Void) {
        self.requested = requested
        self.maxChunkDuration = maxChunkDuration
        self.emit = emit
    }

    mutating func append(_ bytes: Data, mimeType: String?, sampleRate: Int?, channels: Int?, provider: String) throws {
        var pcm = bytes
        var blockFormat = PCMFormat(
            sampleRate: sampleRate.flatMap { $0 > 0 ? $0 : nil } ?? GeminiSpeechWire.rateParameter(mimeType) ?? requested.sampleRate,
            channels: channels.flatMap { $0 > 0 ? $0 : nil } ?? requested.channels)
        switch GeminiSpeechWire.audioKind(mimeType) {
        case .linear16:
            // A RIFF header where raw PCM was promised would play as a click; take the samples behind it.
            if let wav = GeminiSpeechWire.wavPayload(bytes) { (pcm, blockFormat) = wav }
        case .wav:
            if let wav = GeminiSpeechWire.wavPayload(bytes) {
                (pcm, blockFormat) = wav
            } else if bytes.starts(with: Data("RIFF".utf8)) {
                throw ProviderError(provider: provider, message: "Gemini sent WAV audio that is not 16-bit PCM.")
            }
            // Later blocks of a streamed WAV carry bare samples.
        case .unsupported(let type):
            throw ProviderError(provider: provider, message: "Expected 16-bit PCM audio (audio/l16) but Gemini sent \(type).")
        }
        // The rate and channel count come from the network. Out-of-range values would overflow the byte arithmetic
        // below (a trap) or reach the player as a format it cannot open.
        guard Self.playableRates.contains(blockFormat.sampleRate), Self.playableChannels.contains(blockFormat.channels) else {
            throw ProviderError(provider: provider, message: "Gemini sent audio in a format OpenClicky cannot play "
                                    + "(\(blockFormat.sampleRate) Hz, \(blockFormat.channels) channels).")
        }
        if blockFormat != format {
            flush()
            format = blockFormat
            aligner = PCMFrameAligner(frameSize: blockFormat.channels * 2)
        }
        emitChunks(aligner.push(pcm), blockFormat)
    }

    /// Ends a request: a dangling partial sample is dropped.
    mutating func flush() {
        if let format { aligner = PCMFrameAligner(frameSize: format.channels * 2) }
    }

    private mutating func emitChunks(_ frames: Data, _ format: PCMFormat) {
        guard !frames.isEmpty else { return }
        let frameBytes = format.channels * 2
        let seconds = Double(maxChunkDuration.components.seconds) + Double(maxChunkDuration.components.attoseconds) / 1e18
        // Clamped before converting, so no option value can make `Int(_:)` trap; 16 MB is far above any real chunk.
        let wanted = min(max(Double(format.bytesPerSecond) * seconds, 0), 16_777_216)
        let perChunk = max(Int(wanted) / frameBytes * frameBytes, frameBytes)
        var offset = frames.startIndex
        while offset < frames.endIndex {
            let end = min(offset + perChunk, frames.endIndex)
            emit(Data(frames[offset..<end]), format)
            deliveredBytes += end - offset
            offset = end
        }
    }
}

/// Lets `warmUp()` reach the network at most once per interval, however many callers race it.
final class GeminiWarmUpGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: ContinuousClock.Instant?

    func claim(interval: Duration) -> Bool {
        let now = ContinuousClock.now
        return lock.withLock {
            if let last, now - last < interval { return false }
            last = now
            return true
        }
    }
}

// Keep the API key out of logs: the default description and dump() would print the stored context.
extension GeminiSpeechClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let key = (context.apiKey?.isEmpty == false) ? "set" : "none"
        return "GeminiSpeechClient(provider: \(context.provider.id), model: \(model), voice: \(defaultVoice), apiKey: \(key))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["provider": context.provider.id, "model": model, "defaultVoice": defaultVoice,
                                "options": options], displayStyle: .struct)
    }
}
