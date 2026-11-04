import Foundation
import os

/// One utterance: PCM is buffered by `send`, uploaded by `finish`, and the transcript comes back on `events`.
/// Cancelling the task that reads `events`, or calling `cancel()`, cancels the upload and the HTTP request.
final class OpenAITranscriptionSession: SpeechToTextSession {
    typealias Continuation = AsyncThrowingStream<TranscriptEvent, Error>.Continuation

    let events: AsyncThrowingStream<TranscriptEvent, Error>
    private let continuation: Continuation
    private let state: OSAllocatedUnfairLock<State>
    private let upload: OpenAITranscriptionUpload

    private struct State: Sendable {
        enum Phase: Sendable { case recording, uploading, closed }
        var phase: Phase = .recording
        var audio = Data()
        var task: Task<Void, Never>?
    }

    init(upload: OpenAITranscriptionUpload) {
        self.upload = upload
        (events, continuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        // Runs when the reader stops (task cancelled or stream dropped) and after the stream finishes.
        continuation.onTermination = { _ in
            Self.close(state)?.cancel()
        }
    }

    func send(_ pcm: Data) async {
        state.withLock { state in
            if state.phase == .recording { state.audio.append(pcm) }
        }
    }

    func finish() async {
        let audio: Data? = state.withLock { state in
            guard state.phase == .recording else { return nil }
            state.phase = .uploading
            defer { state.audio = Data() }
            return state.audio
        }
        guard let audio else { return }
        let pcmBytes = audio.count - audio.count % (max(upload.format.channels, 1) * 2)
        guard pcmBytes > 0 else {
            // Nothing was said: no request, just an empty transcript.
            continuation.finish()
            return
        }
        let upload = self.upload
        let continuation = self.continuation
        let task = Task { await upload.run(pcm: audio, into: continuation) }
        let kept = state.withLock { state -> Bool in
            guard state.phase == .uploading else { return false }
            state.task = task
            return true
        }
        // The reader went away between taking the audio and starting the upload.
        if !kept { task.cancel() }
    }

    func cancel() async {
        Self.close(state)?.cancel()
        continuation.finish()
    }

    /// Marks the session closed and hands back the upload to cancel. Never call with the continuation inside the
    /// lock: finishing it runs onTermination, which takes the lock.
    private static func close(_ state: OSAllocatedUnfairLock<State>) -> Task<Void, Never>? {
        state.withLock { state in
            state.phase = .closed
            state.audio = Data()
            defer { state.task = nil }
            return state.task
        }
    }
}

/// Everything one upload needs, captured when the session starts.
struct OpenAITranscriptionUpload: Sendable {
    var providerID: String
    var http: any HTTPTransport
    var url: URL
    var extraHeaders: [String: String]
    var apiKey: String?
    var fields: [OpenAITranscriptionClient.FormField]
    var format: PCMFormat
    var streaming: Bool

    func makeRequest(pcm: Data) -> URLRequest {
        let wav = OpenAITranscriptionClient.WAV.wrap(pcm, format: format)
        let boundary = OpenAITranscriptionClient.Multipart.boundary(avoiding: fields, file: wav)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Same as ProviderContext.jsonRequest: an unstreamed answer (whisper-1) is silent until the whole file is
        // transcribed, so a shorter idle timeout could fail long recordings the server would have finished.
        request.timeoutInterval = 600
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = OpenAITranscriptionClient.Multipart.body(fields: fields, file: wav, boundary: boundary)
        return request
    }

    func run(pcm: Data, into continuation: OpenAITranscriptionSession.Continuation) async {
        do {
            let request = makeRequest(pcm: pcm)
            if let size = request.httpBody?.count, size > OpenAITranscriptionClient.maxUploadBytes {
                let megabytes = (Double(size) / 1_048_576).formatted(.number.precision(.fractionLength(1)))
                throw ProviderError(provider: providerID, message:
                    "The recording is \(megabytes) MB; the transcription endpoint accepts files up to 25 MB.")
            }
            // The reader may have left while finish() was handing over the audio; don't send what nobody will read.
            try Task.checkCancellation()
            let (body, response) = try await http.stream(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw await providerError(status: response.statusCode, body: body)
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("text/event-stream") || (contentType.isEmpty && streaming) {
                try await readEvents(body, into: continuation)
            } else {
                try await readJSON(body, status: response.statusCode, into: continuation)
            }
            continuation.finish()
        } catch {
            if Task.isCancelled || error is CancellationError {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    /// `stream=true`: deltas become a growing interim, `transcript.text.done` becomes the final.
    private func readEvents(_ body: AsyncThrowingStream<Data, Error>, into continuation: OpenAITranscriptionSession.Continuation) async throws {
        var parser = SSEParser()
        var interim = ""
        var sawDone = false
        func handle(_ event: ServerSentEvent) throws {
            guard event.data != "[DONE]", let payload = try? JSONValue.parse(event.data) else { return }
            let type = payload["type"]?.stringValue ?? event.event
            // Errors inside the stream aren't documented for this endpoint; read them the way other OpenAI
            // streams send them (`{"error": {...}}` or `{"type": "error", ...}`) rather than ending silently.
            if let error = payload["error"], error != .null {
                throw ProviderError(provider: providerID, message: Self.message(from: error) ?? event.data)
            }
            if type == "error" {
                throw ProviderError(provider: providerID, message: payload["message"]?.stringValue ?? event.data)
            }
            switch type {
            case "transcript.text.delta":
                guard let delta = payload["delta"]?.stringValue, !delta.isEmpty else { return }
                interim += delta
                continuation.yield(.interim(interim))
            case "transcript.text.done":
                let text = payload["text"]?.stringValue ?? interim
                interim = ""
                sawDone = true
                if !text.isEmpty { continuation.yield(.final(text)) }
            default:
                // transcript.text.segment (diarized_json only) and anything newer: not needed for the stt slot.
                break
            }
        }
        for try await chunk in body {
            for event in parser.feed(chunk) { try handle(event) }
        }
        try Task.checkCancellation()
        for event in parser.finish() { try handle(event) }
        // The body ended cleanly without a done event: keep what was heard rather than dropping it.
        if !sawDone, !interim.isEmpty { continuation.yield(.final(interim)) }
    }

    /// Unstreamed `json` response: `{"text": "...", "usage": {...}}`.
    private func readJSON(_ body: AsyncThrowingStream<Data, Error>, status: Int, into continuation: OpenAITranscriptionSession.Continuation) async throws {
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        try Task.checkCancellation()
        let payload = try? JSONValue.parse(String(decoding: data, as: UTF8.self))
        guard let text = payload?["text"]?.stringValue else {
            if let error = payload?["error"], error != .null {
                throw ProviderError(provider: providerID, status: status, message: Self.message(from: error) ?? "Unknown error")
            }
            throw ProviderError(provider: providerID, status: status,
                                message: "Unexpected transcription response: \(String(decoding: data.prefix(512), as: UTF8.self))")
        }
        if !text.isEmpty { continuation.yield(.final(text)) }
    }

    /// A non-2xx response as a ProviderError carrying OpenAI's `error.message` (or the body text).
    /// Never throws: the status is the news, and an error body cut short (a proxy dropping the connection) mustn't
    /// replace it with a transport error.
    private func providerError(status: Int, body: AsyncThrowingStream<Data, Error>) async -> ProviderError {
        var data = Data()
        do {
            for try await chunk in body {
                data.append(chunk)
                if data.count >= 16_384 { break }
            }
        } catch {
            // Keep whatever arrived; run() still notices cancellation through Task.isCancelled.
        }
        let text = String(decoding: data.prefix(16_384), as: UTF8.self)
        let message = (try? JSONValue.parse(text)).flatMap { $0["error"] }.flatMap(Self.message(from:))
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderError(provider: providerID, status: status,
                             message: message ?? (fallback.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : fallback))
    }

    /// `{"message": ...}` objects (OpenAI's shape) or a bare string.
    static func message(from error: JSONValue) -> String? {
        if let text = error.stringValue { return text }
        return error["message"]?.stringValue
    }
}
