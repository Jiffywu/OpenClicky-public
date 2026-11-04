import AVFAudio
import Foundation

/// What a recognizer engine reports, reduced to plain values so the session logic is engine-independent.
enum AppleSpeechBackendEvent: Sendable {
    /// A transcription. `isFinal` false = provisional (SFSpeechRecognizer partial / SpeechTranscriber volatile).
    case result(text: String, isFinal: Bool)
    /// The engine delivered everything it will deliver.
    case finished
    case failed(any Error)
}

/// One running recognizer: `SFSpeechRecognizer` or `SpeechAnalyzer`. The seam the session (and its tests) drive.
/// Implementations must deliver events asynchronously: never call `handler` from inside `append`, `endAudio` or
/// `cancel` (the session calls `append` while holding its lock).
protocol AppleSpeechBackend: AnyObject, Sendable {
    /// The format `append` expects. The session converts captured PCM16 into it.
    var bufferFormat: AVAudioFormat { get }
    /// Begin recognition; events may arrive on any thread.
    func start(reporting handler: @escaping @Sendable (AppleSpeechBackendEvent) -> Void)
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio; the engine should deliver its last finals and then report `.finished`.
    func endAudio()
    /// Stop now. Must be safe to call more than once and after the engine has finished.
    func cancel()
}

/// Maps engine results to the stt slot's events.
///
/// - `TranscriptEvent.interim` replaces the previous interim, and `.final` appends. That is exactly how both
///   engines behave: SFSpeechRecognizer partials carry the whole transcription so far and the final result is
///   settled, and SpeechTranscriber sends each phrase "one or more times as the interpretation gets better and
///   better until it is finalized" (https://developer.apple.com/documentation/speech/speechtranscriber/result).
/// - An empty volatile result is kept: for SpeechTranscriber it means "previous results for this range are
///   revoked" (https://developer.apple.com/documentation/speech/speechtranscriber/result/text), so an empty interim
///   correctly clears the provisional caption.
/// - An empty final adds nothing to the transcript, so it is dropped.
/// - Text is passed through verbatim (no trimming), so consecutive finals concatenate exactly as the engine
///   spaced them. Run live on macOS 27.2, SpeechTranscriber starts every phrase after the first with a space
///   (finals "Open Safari." then " Then turn on the lights."), and the interims of that phrase carry the same
///   leading space. A final settles the interim before it, as with the other stt adapters.
enum AppleSpeechTranscript {
    static func event(text: String, isFinal: Bool) -> TranscriptEvent? {
        if isFinal {
            return text.allSatisfy(\.isWhitespace) ? nil : .final(text)
        }
        return .interim(text)
    }
}

/// The `SpeechToTextSession` handed to the app: PCM16 in, transcript events out, over any `AppleSpeechBackend`.
final class AppleSpeechSession: SpeechToTextSession, @unchecked Sendable {
    // @unchecked: every mutable field (including the non-Sendable AVFAudio objects) is guarded by `lock`.
    let events: AsyncThrowingStream<TranscriptEvent, Error>

    private let providerID: String
    private let backend: any AppleSpeechBackend
    private let continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    private let lock = NSLock()
    private var assembler: PCM16BufferAssembler
    private var converter: PCMBufferConverter?
    private var inputEnded = false
    /// The stream has been finished (normally, with an error, or by cancellation); ignore later engine events.
    private var closed = false
    /// Set by finish() until the stream closes. finish() promises the last finals, but a caller may keep only
    /// `events` and drop the session (Swift can release it right after its last use); without this, deinit would
    /// cancel the engine and lose them. The engine always ends after endAudio(), which breaks the cycle.
    private var keepAlive: AppleSpeechSession?

    init(providerID: String, inputFormat: PCMFormat, backend: any AppleSpeechBackend) throws {
        guard let assembler = PCM16BufferAssembler(format: inputFormat) else {
            throw ProviderError(provider: providerID, message: "unsupported input format \(inputFormat)")
        }
        let target = backend.bufferFormat
        if !assembler.audioFormat.isEqual(target) {
            guard let converter = PCMBufferConverter(from: assembler.audioFormat, to: target) else {
                throw ProviderError(provider: providerID, message: AppleSpeechAudioError.unsupportedConversion(
                    from: "\(assembler.audioFormat)", to: "\(target)").description)
            }
            self.converter = converter
        }
        self.providerID = providerID
        self.backend = backend
        self.assembler = assembler
        (events, continuation) = AsyncThrowingStream.makeStream(of: TranscriptEvent.self)

        // Cancelling the task that consumes `events` (or dropping the stream) stops recognition.
        continuation.onTermination = { [weak self, backend] termination in
            guard case .cancelled = termination else { return }
            if let self { self.stop() } else { backend.cancel() }
        }
        backend.start { [weak self] event in self?.handle(event) }
    }

    deinit {
        // Dropped without finish() or cancel(): stop the engine and release anyone still awaiting events.
        if !closed {
            backend.cancel()
            continuation.finish()
        }
    }

    func send(_ pcm: Data) async {
        let failure: (any Error)? = lock.withLock {
            guard !closed, !inputEnded, let buffer = assembler.append(pcm) else { return nil }
            do {
                if let converter {
                    for converted in try converter.convert(buffer) { backend.append(converted) }
                } else {
                    backend.append(buffer)
                }
                return nil
            } catch {
                return error
            }
        }
        if let failure { fail(failure) }
    }

    func finish() async {
        let outcome: Result<Bool, any Error> = lock.withLock {
            guard !closed, !inputEnded else { return .success(false) }
            inputEnded = true
            keepAlive = self
            // A trailing odd byte or partial frame cannot be recognised; drop it, then flush the resampler tail.
            assembler.reset()
            do {
                for converted in try converter?.flush() ?? [] { backend.append(converted) }
                return .success(true)
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(true): backend.endAudio()
        case .success: break
        case .failure(let error): fail(error)
        }
    }

    func cancel() async { stop() }

    /// Abandon recognition and end the event stream without an error.
    private func stop() {
        guard close() else { return }
        backend.cancel()
        continuation.finish()
    }

    /// End the stream with `error` and stop the engine.
    private func fail(_ error: any Error) {
        guard close() else { return }
        backend.cancel()
        continuation.finish(throwing: AppleSpeechErrors.wrap(error, provider: providerID))
    }

    /// Marks the session closed; true for the one caller that actually closed it.
    private func close() -> Bool {
        let (wasOpen, retained): (Bool, AppleSpeechSession?) = lock.withLock {
            defer {
                closed = true
                keepAlive = nil
            }
            return (!closed, keepAlive)
        }
        // Released here, outside the lock (callers always hold their own reference for the call anyway).
        withExtendedLifetime(retained) {}
        return wasOpen
    }

    private func handle(_ event: AppleSpeechBackendEvent) {
        switch event {
        case .result(let text, let isFinal):
            guard let mapped = AppleSpeechTranscript.event(text: text, isFinal: isFinal) else { return }
            // Yield under the lock so a result can never slip in after the stream was closed.
            lock.withLock {
                if !closed { continuation.yield(mapped) }
            }
        case .finished:
            // The engine is done of its own accord; nothing to cancel.
            if close() { continuation.finish() }
        case .failed(let error):
            fail(error)
        }
    }
}

enum AppleSpeechErrors {
    /// Speech framework errors are `NSError`s; keep their domain and code, since the descriptions are often vague.
    static func wrap(_ error: any Error, provider: String) -> ProviderError {
        if let providerError = error as? ProviderError { return providerError }
        if let audioError = error as? AppleSpeechAudioError {
            return ProviderError(provider: provider, message: audioError.description)
        }
        let nsError = error as NSError
        return ProviderError(provider: provider,
                             message: "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}
