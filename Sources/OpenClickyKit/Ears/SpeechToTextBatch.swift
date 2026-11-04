import Foundation

// Pieces the voice loop's ears (`VoiceEars`) build on: transcribing a whole press at once when its stream failed, and
// the optional extras a streaming adapter can offer (a socket opened ahead of key-down, a "ready" moment for timings).

/// Transcribes a whole recording in one request: the second chance for a press whose stream failed (HeyClicky's
/// `/brain/ears/transcribe`, which takes the press as a WAV file).
public protocol SpeechToTextBatchClient: Sendable {
    /// The words in `audio` (PCM16), or "" when nobody spoke.
    func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String
}

/// A streaming stt client that can open its connection ahead of key-down (`GeminiLiveSpeechToTextClient` does).
public protocol SpeechToTextWarming: SpeechToTextClient {
    /// Opens a connection for the next press with these settings. Errors are dropped: the press connects as usual.
    func warmUp(language: String?, keywords: [String]) async
    /// Like `warmUp`, but also replaces a warm connection that will close within `margin`, so a periodic refresh
    /// opens the next one before the current one expires instead of after.
    func warmUp(language: String?, keywords: [String], replacingWithin margin: Duration) async
    /// Waits until that connection is ready for a press; false when there is none.
    func waitUntilWarm(language: String?, keywords: [String]) async -> Bool
    /// Closes that connection, if any.
    func discardWarmSocket() async
}

extension SpeechToTextWarming {
    /// Clients whose warm connection never expires on its own only need `warmUp`.
    public func warmUp(language: String?, keywords: [String], replacingWithin margin: Duration) async {
        await warmUp(language: language, keywords: keywords)
    }
}

extension GeminiLiveSpeechToTextClient: SpeechToTextWarming {}

/// A streaming session that can say when the provider is ready for audio and whether it was opened ahead of key-down
/// (for per-press timings).
public protocol SpeechToTextSessionReadiness: SpeechToTextSession {
    /// The press took a connection opened before key-down.
    var startedWarm: Bool { get async }
    /// Waits until the provider accepts the press's audio (Gemini's `setupComplete`); false if it never will.
    func waitUntilReady() async -> Bool
}

/// Any streaming client as a batch one: the recording is converted to the client's format and streamed through one
/// session as fast as the session takes it. Suits batch-per-utterance adapters (OpenAI transcription), on-device
/// recognizers (Apple Speech) and a second try on a fresh stream.
public struct StreamingReplayBatchClient: SpeechToTextBatchClient {
    public let client: any SpeechToTextClient

    public init(client: any SpeechToTextClient) { self.client = client }

    public func transcribe(_ audio: DecodedAudio, language: String?, keywords: [String]) async throws -> String {
        let target = client.inputFormat
        let pcm = PCM16Conversion.convert(audio.pcm, from: audio.format, to: target)
        let session = try await client.startSession(language: language, keywords: keywords)
        return try await withTaskCancellationHandler {
            async let heard = DictationFallbackTranscription.collect(session.events)
            // Tenth-of-a-second slices, the size live capture delivers.
            let slice = max(2, (target.bytesPerSecond / 10) & ~1)
            var offset = 0
            while offset < pcm.count, !Task.isCancelled {
                let end = min(offset + slice, pcm.count)
                await session.send(pcm.subdata(in: offset..<end))
                offset = end
            }
            await session.finish()
            return try await heard.trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: {
            Task { await session.cancel() }
        }
    }
}

/// Tells an account refusal (billing, credit, quota) or a region refusal apart from other stt failures: after one, the
/// ears switch to another recognizer for a while instead of failing every press (HeyClicky: ten minutes).
public enum SpeechRefusal {
    static let words = ["credit", "billing", "quota", "exhausted", "prepayment", "payment"]

    /// True when `error` says the provider account can't pay for the request.
    public static func isAccountRefusal(_ error: Error) -> Bool {
        // A diagnosed failure's text is the plain explanation; judge what the provider sent instead.
        let diagnosed = error as? ProviderUnavailableError
        if (diagnosed?.providerError ?? error as? ProviderError)?.status == 402 { return true }
        let text = (diagnosed?.underlying ?? String(describing: error)).lowercased()
        return words.contains { text.contains($0) }
    }

    /// True when the provider won't serve this country or region: `ProviderDiagnostician` diagnosed
    /// `regionUnsupported`, or the provider said so outright (HTTP 451, or a region refusal in its message). Like an
    /// account refusal, every press would fail the same way, so the ears switch for the same ten minutes.
    public static func isRegionRefusal(_ error: Error) -> Bool {
        if let diagnosed = error as? ProviderUnavailableError { return diagnosed.diagnosis.verdict == .regionUnsupported }
        guard let provider = error as? ProviderError else { return false }
        return provider.status == 451 || ProviderProbe.mentionsRegion(provider.message)
    }

    /// An account or region refusal: the stt slot is avoided for `VoiceEars.Policy.refusalSwitch`.
    public static func switchesSlot(_ error: Error) -> Bool { isAccountRefusal(error) || isRegionRefusal(error) }
}
