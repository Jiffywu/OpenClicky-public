// On-device speech for the voice slot (dialect "apple-speech-synthesis"), rendered by AVSpeechSynthesizer.
//
// API checked on 2026-10-30 against Apple's documentation and the macOS 27.2 SDK header
// AVFAudio.framework/Headers/AVSpeechSynthesis.h:
// - AVSpeechSynthesizer: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer
//   "The system doesn't automatically retain the speech synthesizer, so you need to manually retain it until speech
//   concludes."
// - write(_:toBufferCallback:):
//   https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
//   "Generates speech for the utterance and invokes the callback with the audio buffer." The header adds that the
//   buffers come in the format described by the voice's `audioFileSettings` (Float32, deinterleaved, mono, 22.05 kHz
//   or 16 kHz for the voices installed here).
// - stopSpeaking(at:): https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/stopspeaking(at:)
// - speechSynthesizer(_:didFinish:) and (_:didCancel:):
//   https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:didfinish:)
// - AVSpeechSynthesisVoice: https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice
//   speechVoices(), init(identifier:), init(language:) with a BCP 47 tag, currentLanguageCode(), and the
//   identifier, name, language and quality properties. An utterance with no voice uses the system default.
// - AVAudioPCMBuffer.floatChannelData / int16ChannelData / int32ChannelData (AVAudioBuffer.h): one pointer per
//   channel, `frameLength` samples spaced by `stride` (1 when deinterleaved, the channel count when interleaved).
//
// Where the docs say nothing, this adapter relies on behaviour observed on macOS 27.2 (26B123):
// - The docs do not say how the buffer callback marks the end of an utterance. The forum thread
//   https://developer.apple.com/forums/thread/678287 shows code checking for a zero-length buffer, and reports that
//   on macOS 10.15 and 11.2.3 neither the buffer callback nor didFinish was called (an Apple reply says it was fixed
//   in macOS 11). A zero-length buffer does arrive last, but one also arrives after each internal segment of a long
//   line (about every three sentences), and the delegate's didFinish follows the last one. A line therefore
//   finishes once didFinish has arrived and the latest buffer was zero-length, in either order. Fallbacks: if
//   didFinish comes but no zero-length buffer follows it, `Timing.finishGrace` of silence ends the line. If didFinish
//   never comes, a zero-length buffer followed by `Timing.terminatorIdle` of silence does, but only until this
//   process has seen didFinish once (`FinishSignal`). After that a zero-length buffer is only a segment boundary,
//   so a busy main thread that holds back the next segment cannot cut a line short.
// - During write(_:toBufferCallback:), `isSpeaking` is false and stopSpeaking(at: .immediate) returns false
//   without stopping the render. Releasing the synthesizer is what stops its callbacks. Cancelling a line calls
//   stopSpeaking(at: .immediate) anyway (the documented way), then releases the synthesizer and drops late buffers.
// - Callbacks arrive on the main thread when the main run loop is running and on AVFAudio's own threads otherwise,
//   whichever queue called write. They never overlapped. `Line` is thread-safe, so either works.

import AVFAudio
import Foundation

/// Speaks lines with the voices installed on this Mac. Each line renders to PCM buffers through
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)`; nothing plays directly. Every buffer is mixed to mono 16-bit
/// PCM at the voice's own sample rate (often 22.05 kHz) and yielded as soon as it arrives.
///
/// `voice` may be an `AVSpeechSynthesisVoice` identifier (`com.apple.voice.compact.en-US.Samantha`), a voice name
/// (`Samantha`) or a BCP 47 language (`en-GB`, `fr`). Anything that matches nothing uses the system default voice.
/// `instructions` is ignored: AVSpeechSynthesizer has no style prompt. No credential is needed or read.
public struct AppleSpeechSynthesisClient: SpeechOutputClient {
    /// Used when `speak` is called without a voice. Nil means the system default voice.
    public let defaultVoice: String?

    private let providerID: String
    private let timing: Timing
    private let makeRenderer: @Sendable () -> any Renderer
    private let finishSignal: FinishSignal
    private let lines = LineRegistry()

    /// - Parameters:
    ///   - context: Only `provider.id` is used, to label errors. On-device synthesis has no key, URL or transport.
    ///   - defaultVoice: The voice for lines spoken without one: an identifier, a name or a language.
    public init(context: ProviderContext, defaultVoice: String? = nil) {
        self.init(context: context, defaultVoice: defaultVoice, timing: .standard,
                  finishSignal: .process, makeRenderer: { SynthesizerRenderer() })
    }

    /// The seam tests use to replace AVSpeechSynthesizer and shorten the timeouts. Each test client gets its own
    /// `FinishSignal` unless it passes one.
    init(context: ProviderContext, defaultVoice: String?, timing: Timing, finishSignal: FinishSignal = FinishSignal(),
         makeRenderer: @escaping @Sendable () -> any Renderer) {
        self.providerID = context.provider.id
        self.defaultVoice = Self.nonBlank(defaultVoice)
        self.timing = timing
        self.finishSignal = finishSignal
        self.makeRenderer = makeRenderer
    }

    public func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        guard text.contains(where: { !$0.isWhitespace }) else {
            continuation.yield(.lineFinished)
            continuation.finish()
            return stream
        }
        let line = Line(providerID: providerID, timing: timing, finishSignal: finishSignal, continuation: continuation)
        let renderer = makeRenderer()
        let lines = lines
        // Installed before the line is reachable from stopAll() and before rendering starts, so however the stream
        // ends, even at once, its renderer stops. AsyncStream never runs a handler set after the stream finished.
        continuation.onTermination = { _ in
            line.terminated()
            renderer.stop()
            lines.remove(line)
        }
        lines.insert(line)
        line.startWatchdog()
        renderer.start(text: text, voice: Self.nonBlank(voice) ?? defaultVoice, line: line)
        return stream
    }

    /// Stops every line in flight. Their streams end with `CancellationError` and never yield `.lineFinished`.
    public func stopAll() async {
        for line in lines.removeAll() { line.cancel() }
    }

    static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension AppleSpeechSynthesisClient {
    /// Renders one line and reports to its `Line`. The live one wraps AVSpeechSynthesizer; tests script one.
    protocol Renderer: Sendable {
        /// Starts rendering. Called once per renderer, possibly after `stop()` (then it must do nothing).
        func start(text: String, voice: String?, line: Line)
        /// Stops rendering and releases the synthesizer. Idempotent.
        func stop()
    }

    /// How long a line waits on the fallbacks described at the top of this file.
    struct Timing: Sendable {
        /// How often the watchdog looks at the line.
        var tick: Duration = .milliseconds(50)
        /// A zero-length buffer and then this much silence, with no didFinish, ends the line. Applies only until the
        /// process has seen didFinish.
        var terminatorIdle: Duration = .seconds(2)
        /// didFinish and then this much silence, with no zero-length buffer, ends the line.
        var finishGrace: Duration = .milliseconds(500)
        /// No callback at all for this long fails the line.
        var stallTimeout: Duration = .seconds(20)
        /// The clock the durations above are measured on. Tests substitute one they move by hand, so a busy machine
        /// can't stretch the gaps between callbacks.
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

        static let standard = Timing()
    }

    /// One line's stream and the state that decides when it ends. Renderer callbacks arrive on arbitrary threads.
    final class Line: @unchecked Sendable {
        private let providerID: String
        private let timing: Timing
        private let finishSignal: FinishSignal
        private let continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
        private let lock = NSLock()
        // Guarded by `lock`.
        private var done = false
        private var lastBufferWasEmpty = false
        private var synthesizerFinished = false
        private var audioChunks = 0
        private var lateCallbacks = 0
        private var lastActivity: ContinuousClock.Instant
        private var watchdog: Task<Void, Never>?

        init(providerID: String, timing: Timing, finishSignal: FinishSignal,
             continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation) {
            self.providerID = providerID
            self.timing = timing
            self.finishSignal = finishSignal
            self.continuation = continuation
            self.lastActivity = timing.now()
        }

        /// Renderer callbacks that arrived after the line ended. Tests use it to check that stopping a line really
        /// stops the synthesizer.
        var callbacksAfterEnd: Int { lock.withLock { lateCallbacks } }

        /// False, and counted, once the line has ended: late callbacks are dropped before any conversion work.
        private func isLive() -> Bool {
            lock.withLock {
                if done { lateCallbacks += 1 }
                return !done
            }
        }

        /// A buffer from `write(_:toBufferCallback:)`.
        func deliver(_ buffer: AVAudioBuffer) {
            guard isLive() else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                return end(.failed(ProviderError(provider: providerID, message: "Speech synthesis produced a compressed buffer (\(buffer.format)), not PCM.")))
            }
            if pcm.frameLength == 0 { return segmentEnded() }
            guard let (data, format) = PCM16.monoData(from: pcm) else {
                return end(.failed(ProviderError(provider: providerID, message: "Speech synthesis produced audio in an unsupported format: \(pcm.format).")))
            }
            lock.withLock {
                guard !done else { return }
                // Yielded under the lock so no chunk can land after the line has ended.
                continuation.yield(.audio(data, format))
                audioChunks += 1
                lastBufferWasEmpty = false
                lastActivity = timing.now()
            }
        }

        /// A zero-length buffer: the end of a segment, which is the end of the line once didFinish has arrived.
        private func segmentEnded() {
            let finished = lock.withLock {
                lastBufferWasEmpty = true
                lastActivity = timing.now()
                return synthesizerFinished
            }
            if finished { end(.lineFinished) }
        }

        /// The delegate's didFinish.
        func synthesizerDidFinish() {
            finishSignal.record()
            guard isLive() else { return }
            let finished = lock.withLock {
                synthesizerFinished = true
                lastActivity = timing.now()
                return lastBufferWasEmpty || audioChunks == 0
            }
            if finished { end(.lineFinished) }
        }

        /// The delegate's didCancel. This adapter never triggers it (it detaches the delegate before stopping), so
        /// something else stopped the synthesizer mid-line.
        func synthesizerDidCancel() {
            end(.failed(ProviderError(provider: providerID, message: "Speech synthesis was cancelled before the line finished.")))
        }

        /// `stopAll()`.
        func cancel() { end(.failed(CancellationError())) }

        /// The stream ended, for whatever reason: stop listening.
        func terminated() {
            let task = lock.withLock {
                done = true
                defer { watchdog = nil }
                return watchdog
            }
            task?.cancel()
        }

        func startWatchdog() {
            let tick = timing.tick
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: tick)
                    guard let line = self, line.checkTimers() else { return }
                }
            }
            let alreadyDone = lock.withLock {
                if !done { watchdog = task }
                return done
            }
            if alreadyDone { task.cancel() }
        }

        /// Applies the fallbacks. Returns false once the line has ended.
        private func checkTimers() -> Bool {
            enum Verdict { case running, ended, finish, stalled }
            // Read before taking `lock`; FinishSignal has its own lock and never takes this one.
            let systemSendsDidFinish = finishSignal.seen
            let now = timing.now()
            let verdict: Verdict = lock.withLock {
                guard !done else { return .ended }
                let idle = now - lastActivity
                if synthesizerFinished && idle >= timing.finishGrace { return .finish }
                if !systemSendsDidFinish && lastBufferWasEmpty && idle >= timing.terminatorIdle { return .finish }
                if idle >= timing.stallTimeout { return .stalled }
                return .running
            }
            switch verdict {
            case .running: return true
            case .ended: return false
            case .finish: end(.lineFinished)
            case .stalled:
                end(.failed(ProviderError(provider: providerID, message: "Speech synthesis produced no audio for \(timing.stallTimeout). Check that a system voice is installed.")))
            }
            return false
        }

        private enum Ending {
            case lineFinished
            case failed(any Error)
        }

        private func end(_ ending: Ending) {
            let first = lock.withLock {
                defer { done = true }
                return !done
            }
            guard first else { return }
            // Outside the lock: finishing runs onTermination, which calls `terminated()`. `done` is already set, so
            // no audio can be yielded after these.
            switch ending {
            case .lineFinished:
                continuation.yield(.lineFinished)
                continuation.finish()
            case .failed(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    /// Whether this system has sent didFinish for a written utterance. That is a property of the OS, so the live
    /// client shares one per process (`process`). Until it is set, a zero-length buffer followed by
    /// `Timing.terminatorIdle` of silence may end a line; once it is set, only didFinish (or the stall timeout) can.
    final class FinishSignal: @unchecked Sendable {
        static let process = FinishSignal()

        private let lock = NSLock()
        private var value = false  // Guarded by `lock`.

        var seen: Bool { lock.withLock { value } }
        func record() { lock.withLock { value = true } }
    }

    /// The lines a client has in flight, so `stopAll` can reach them.
    final class LineRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [ObjectIdentifier: Line] = [:]  // Guarded by `lock`.

        func insert(_ line: Line) { lock.withLock { lines[ObjectIdentifier(line)] = line } }

        func remove(_ line: Line) { _ = lock.withLock { lines.removeValue(forKey: ObjectIdentifier(line)) } }

        func removeAll() -> [Line] {
            lock.withLock {
                defer { lines.removeAll() }
                return Array(lines.values)
            }
        }

        var count: Int { lock.withLock { lines.count } }
    }
}
