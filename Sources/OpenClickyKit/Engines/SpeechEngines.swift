import Foundation

/// Linear 16-bit little-endian PCM, the one audio format OpenClicky passes between parts.
public struct PCMFormat: Sendable, Hashable {
    public var sampleRate: Int
    public var channels: Int

    public init(sampleRate: Int, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public static let speech16k = PCMFormat(sampleRate: 16_000)
    public static let speech24k = PCMFormat(sampleRate: 24_000)

    public var bytesPerSecond: Int { sampleRate * channels * 2 }
}

// MARK: - Speech to text (the stt slot)

/// What a transcription session reports. Every adapter keeps the same contract, so captions and the talk-key
/// transcript work the same whichever model fills the stt slot:
///
/// - The transcript is every `.final` concatenated in order, with no separator added. A final that continues earlier
///   text carries its own leading space when the language needs one (`"Hello"`, then `" world"`), so consumers
///   append finals as they are and never insert spaces themselves.
/// - An `.interim` covers only the words since the last final, never text already settled, and carries the same
///   leading space the final settling it will. Each interim replaces the previous one. The live caption is
///   therefore `finals + latestInterim`.
/// - A `.final` settles the words the current interim was showing, so it clears the interim: until the next
///   `.interim` arrives, the caption is the finals alone.
public enum TranscriptEvent: Sendable, Hashable {
    /// A provisional transcript of the words since the last final; replaces the previous interim.
    case interim(String)
    /// Settled text. Finals append (with their own leading space when needed); together they are the transcript.
    /// A final also clears the current interim.
    case final(String)
    /// The provider heard speech begin (for barge-in and captions).
    case speechStarted
    /// The provider decided the speaker paused at the end of an utterance.
    case utteranceEnd
}

/// One live transcription: push audio in, read transcript events out.
public protocol SpeechToTextSession: AnyObject, Sendable {
    var events: AsyncThrowingStream<TranscriptEvent, Error> { get }
    /// Append captured audio in the session's format. May return before the audio is written to the network (or
    /// handed to the recognizer): adapters queue it and keep its order. Only `finish()` waits for it to be used.
    func send(_ pcm: Data) async
    /// No more audio is coming; the event stream finishes once the last finals arrive.
    func finish() async
    /// Abandon the session immediately.
    func cancel() async
}

public protocol SpeechToTextClient: Sendable {
    /// The audio format the session wants (capture converts to it).
    var inputFormat: PCMFormat { get }
    func startSession(language: String?, keywords: [String]) async throws -> any SpeechToTextSession
}

// MARK: - Speech output (the voice slot)

public enum SpeechEvent: Sendable, Hashable {
    /// Audio for the line. Chunks arrive in order; play them as they come. Every chunk holds whole frames: its byte
    /// count is a multiple of `channels * 2` (16-bit samples for every channel), whatever the network's chunk
    /// boundaries were, so each chunk can be scheduled on its own.
    case audio(Data, PCMFormat)
    /// Every chunk of the line has been delivered.
    case lineFinished
}

/// Speaks lines of text. Realtime speech models and text-to-speech models both fill this, so the rest of the
/// app never cares which kind the user picked.
public protocol SpeechOutputClient: Sendable {
    /// Synthesize one line. Cancelling the consuming task stops synthesis (barge-in).
    func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error>
    /// Optional: open connections ahead of the first line to cut latency.
    func warmUp() async
    /// Stop everything in flight.
    func stopAll() async
}

extension SpeechOutputClient {
    public func warmUp() async {}
    public func stopAll() async {}
}
