import AVFoundation
import Foundation

/// A speech output with a hand-driven clock, for testing anything built on `SpeechPlayer` (timeline, captions,
/// drawing pace, barge-in) without audio hardware. Move the clock with `advance(…)`, then call `SpeechPlayer.poll()`.
public final class FakeSpeechPlaybackBackend: SpeechPlaybackBackend, @unchecked Sendable {
    public struct Scheduled: Sendable, Hashable {
        public var frames: Int
        /// Explicit start frame on the output clock, or nil for "right after the previous buffer".
        public var at: Int64?
        /// First sample of the buffer, so tests can tell which audio was queued.
        public var firstSample: Float
    }

    public let work = AudioWorkQueue(label: "OpenClicky.fakeSpeechOutput")
    public let sampleRate: Double
    public var onRestart: ((String) -> Void)?
    public var onFailure: ((String) -> Void)?

    private let lock = NSLock()
    private var _clock: Int64 = 0
    private var _running = false
    private var _rate: Float = 1
    private var _scheduled: [Scheduled] = []
    private var _starts = 0
    private var _flushes = 0
    private var _releases = 0
    private var _latency: Int64 = 0
    private var _lead: Int64 = 0
    private var _queueEnd: Int64 = 0
    private var _race: Int64 = 0

    public init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    /// Frames between what the output has rendered and what the listener hears.
    public var latencyFrames: Int64 {
        get { lock.withLock { _latency } }
        set { lock.withLock { _latency = newValue } }
    }

    /// How far ahead of the clock a newly scheduled buffer can start.
    public var leadFrames: Int64 {
        get { lock.withLock { _lead } }
        set { lock.withLock { _lead = newValue } }
    }

    public var clock: Int64 { lock.withLock { _clock } }
    public var scheduled: [Scheduled] { lock.withLock { _scheduled } }
    public var scheduledFrames: Int { scheduled.reduce(0) { $0 + $1.frames } }
    public var startCount: Int { lock.withLock { _starts } }
    public var flushCount: Int { lock.withLock { _flushes } }
    public var releaseCount: Int { lock.withLock { _releases } }

    public func advance(to frame: Int64) { lock.withLock { _clock = frame } }
    public func advance(by frames: Int64) { lock.withLock { _clock += frames } }
    public func advance(seconds: TimeInterval) { advance(by: Int64((seconds * sampleRate).rounded())) }

    /// Makes the output render `frames` more between the player's `earliestStartFrame()` check and the next buffer
    /// reaching the queue, the way a render cycle can land between the two on a real device.
    public func renderBeforeNextSchedule(frames: Int64) { lock.withLock { _race = frames } }

    /// Pretend the device changed: queued audio is lost and the clock restarts at 0.
    public func simulateRestart(reason: String = "test route change") {
        work.sync {
            lock.withLock {
                _clock = 0
                _queueEnd = 0
                _scheduled.removeAll()
            }
            onRestart?(reason)
        }
    }

    public func simulateFailure(_ message: String = "test failure") {
        work.sync {
            lock.withLock { _running = false }
            onFailure?(message)
        }
    }

    // MARK: SpeechPlaybackBackend

    public var isRunning: Bool { lock.withLock { _running } }

    public var rate: Float {
        get { lock.withLock { _rate } }
        set { lock.withLock { _rate = newValue } }
    }

    public func start() throws {
        lock.withLock {
            if !_running {
                _clock = 0
                _queueEnd = 0
            }
            _running = true
            _starts += 1
        }
    }

    public func flush() {
        lock.withLock {
            _clock = 0
            _queueEnd = 0
            _scheduled.removeAll()
            _flushes += 1
        }
    }

    public func release() {
        lock.withLock {
            _running = false
            _releases += 1
        }
    }

    public func schedule(_ buffer: AVAudioPCMBuffer, atFrame frame: Int64?) -> Int64 {
        let first = buffer.frameLength > 0 ? (buffer.floatChannelData?[0][0] ?? 0) : 0
        return lock.withLock {
            _clock += _race
            _race = 0
            // Like the real output: never in the past, and nil follows the queued audio.
            let start = max(frame ?? _queueEnd, _clock + _lead)
            _queueEnd = max(_queueEnd, start + Int64(buffer.frameLength))
            _scheduled.append(Scheduled(frames: Int(buffer.frameLength), at: frame, firstSample: first))
            return start
        }
    }

    public func earliestStartFrame() -> Int64 { lock.withLock { _clock + _lead } }

    public func audibleFrame() -> Int64? { lock.withLock { _running ? _clock - _latency : nil } }
}
