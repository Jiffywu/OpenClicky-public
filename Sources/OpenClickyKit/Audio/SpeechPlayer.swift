import AVFoundation
import Foundation

/// Plays the voice: a sequence of spoken lines whose PCM chunks stream in from a `SpeechOutputClient`.
///
/// - Lines play in the order they were begun, back to back with no gaps. A later line can receive audio early (the
///   voice may synthesize ahead); it is held until every earlier line has all of its audio.
/// - A playback timeline reports when each line actually starts and finishes reaching the listener (output latency
///   removed). That drives `SpeechPacing` for drawings and the caption timing.
/// - `rate` changes speed without changing pitch.
/// - `stop()` flushes everything at once for barge-in and reports how much of the current line was heard.
/// - `.drained` (and `waitUntilDrained()`) fire when every begun line has finished playing.
///
/// Positions are kept on one timeline in frames at `sampleRate` (audio time, before the speed change), so a starved
/// stream (audio arriving slower than it plays) or a device restart doesn't skew line boundaries.
public final class SpeechPlayer: @unchecked Sendable {
    public enum Event: Sendable, Hashable {
        /// Line `index` started reaching the listener. `expectedDuration` is the wall-clock seconds it will take at the
        /// current speed, known when the voice had already delivered the whole line.
        case lineStarted(index: Int, expectedDuration: TimeInterval?)
        case lineFinished(index: Int)
        /// `stop()` cut line `index` after `playedAudio` seconds of its audio (audio time, independent of speed).
        case lineCut(index: Int, playedAudio: TimeInterval)
        /// Every line begun so far has finished playing.
        case drained
        /// `stop()` flushed queued audio.
        case stopped
        /// The output restarted underneath (device or route change); playback resumed where the listener was.
        case outputRestarted(reason: String)
        /// The output failed and could not be restarted; pending lines were dropped.
        case outputFailed(String)
    }

    /// A line being played; pass it back to `append` and `finishLine`. Handles from before a `stop()` are ignored.
    public struct Line: Sendable, Hashable {
        public let index: Int
        let id: UInt64
    }

    public struct Position: Sendable, Hashable {
        public var lineIndex: Int
        /// Seconds of the line's audio heard so far.
        public var elapsed: TimeInterval
        /// Seconds of audio in the whole line, once the voice has delivered all of it.
        public var duration: TimeInterval?
    }

    public struct StopReport: Sendable, Hashable {
        /// The line that was playing, if any.
        public var cutLine: Int?
        /// Seconds of that line's audio the listener heard (for truncating a realtime conversation item).
        public var playedAudio: TimeInterval
        /// Lines that never started.
        public var droppedLines: [Int]
    }

    /// Rate of the timeline and of the buffers sent to the output; incoming audio at other rates is resampled.
    public let sampleRate: Int

    private let backend: any SpeechPlaybackBackend
    private let work: AudioWorkQueue
    private let relay = EventRelay<Event>()
    private let pollInterval: TimeInterval?
    private let floatFormat: AVAudioFormat

    // Everything below is confined to `work`.
    private var lines: [LineState] = []
    private var segments: [Segment] = []
    /// Timeline frame at output clock frame 0.
    private var base: Int64 = 0
    /// Timeline frame where the next audio goes.
    private var cursor: Int64 = 0
    /// The output's queue ends exactly at `cursor` (so the next buffer can simply follow it).
    private var contiguous = true
    /// Latest timeline frame heard (-1 before the output has played anything).
    private var heard: Int64 = -1
    private var nextID: UInt64 = 0
    private var drained = true
    private var drainWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var idleToken = 0
    private var speed: Float = 1
    private var idleSeconds: TimeInterval

    /// A player on its own engine, or on `host` (share the microphone's host so echo cancellation hears the voice).
    public convenience init(sampleRate: Int = 24_000, host: AudioEngineHost? = nil) {
        let host = host ?? AudioEngineHost(label: "OpenClicky.speechPlayer")
        let pollInterval: TimeInterval? = host.mode == .realtime ? 0.01 : nil
        self.init(backend: EngineSpeechOutput(host: host, sampleRate: Double(sampleRate)), pollInterval: pollInterval)
    }

    /// A player on any output. `pollInterval` nil means the caller drives the timeline with `poll()` (tests, offline
    /// rendering). The output is released after `idleTimeout` seconds without lines.
    public init(backend: any SpeechPlaybackBackend, pollInterval: TimeInterval? = 0.01, idleTimeout: TimeInterval = 5) {
        self.backend = backend
        self.work = backend.work
        self.sampleRate = Int(backend.sampleRate)
        self.pollInterval = pollInterval
        self.idleSeconds = idleTimeout
        self.floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: backend.sampleRate, channels: 1, interleaved: false)!
        work.sync {
            backend.onRestart = { [weak self] reason in self?.handleRestart(reason) }
            backend.onFailure = { [weak self] message in self?.handleFailure(message) }
        }
    }

    deinit {
        timer?.cancel()
        relay.finish()
    }

    // MARK: Observing

    /// Called on the audio queue for every event, before stream subscribers see it. Keep it short.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    /// A stream of every event from now on.
    public func events() -> AsyncStream<Event> { relay.stream(bufferingNewest: 1024) }

    // MARK: Settings

    /// Playback speed, 0.5…2 (pitch is kept).
    public var rate: Float {
        get { work.sync { speed } }
        set {
            work.sync {
                speed = min(max(newValue, 0.5), 2)
                backend.rate = speed
            }
        }
    }

    /// Seconds without lines before the output device is released.
    public var idleTimeout: TimeInterval {
        get { work.sync { idleSeconds } }
        set { work.sync { idleSeconds = newValue } }
    }

    // MARK: Feeding lines

    /// Starts line `index` (the say() line number). Also wakes the output so the first audio isn't delayed.
    @discardableResult
    public func beginLine(_ index: Int) -> Line {
        work.sync {
            nextID += 1
            let line = LineState(id: nextID, index: index)
            lines.append(line)
            drained = false
            idleToken += 1
            if ensureRunning() { startTimer() }
            deliver()
            return Line(index: index, id: line.id)
        }
    }

    /// Adds audio to a line. Any rate or channel count is accepted; it is converted to the player's mono format.
    public func append(_ pcm: Data, format: PCMFormat, to handle: Line) {
        guard !pcm.isEmpty else { return }
        work.sync {
            guard let line = lines.first(where: { $0.id == handle.id }), !line.inputFinished,
                  let buffer = convert(pcm, format: format, for: line), buffer.frameLength > 0 else { return }
            if line === schedulingLine { schedule(buffer, for: line) } else { line.pending.append(buffer) }
            deliver()
        }
    }

    /// The voice has delivered all of the line.
    public func finishLine(_ handle: Line) {
        work.sync {
            guard let line = lines.first(where: { $0.id == handle.id }), !line.inputFinished else { return }
            line.inputFinished = true
            if let resampler = line.resampler, let tail = try? resampler.finish(), tail.frameLength > 0 {
                if line === schedulingLine { schedule(tail, for: line) } else { line.pending.append(tail) }
            }
            line.resampler = nil
            advanceScheduling()
            pollLocked()
            deliver()
        }
    }

    /// Plays one line straight from a voice stream: begins it, appends each chunk, finishes it when the stream says
    /// the line is complete or ends. Cancelling the calling task stops reading (pair it with `stop()` for barge-in).
    public func speak(line index: Int, from stream: AsyncThrowingStream<SpeechEvent, Error>) async throws {
        let line = beginLine(index)
        defer { finishLine(line) }
        for try await event in stream {
            switch event {
            case .audio(let pcm, let format): append(pcm, format: format, to: line)
            case .lineFinished: return
            }
        }
    }

    /// Plays a complete clip as line `index`.
    @discardableResult
    public func play(_ pcm: Data, format: PCMFormat, line index: Int) -> Line {
        let line = beginLine(index)
        append(pcm, format: format, to: line)
        finishLine(line)
        return line
    }

    // MARK: Control

    /// Barge-in: stops at once, drops all queued and pending audio, and reports what was heard.
    @discardableResult
    public func stop() -> StopReport {
        work.sync {
            pollLocked()
            var report = StopReport(cutLine: nil, playedAudio: 0, droppedLines: [])
            for line in lines {
                if line.started, let start = line.startFrame {
                    let played = seconds(min(max(heard - start, 0), line.frames))
                    report.cutLine = line.index
                    report.playedAudio = played
                    emit(.lineCut(index: line.index, playedAudio: played))
                } else {
                    report.droppedLines.append(line.index)
                }
            }
            let hadWork = !lines.isEmpty
            resetTimeline()
            backend.flush()
            if hadWork { emit(.stopped) }
            settleIdle()
            deliver()
            return report
        }
    }

    /// Waits until every begun line has finished playing (returns at once when idle, and on `stop()`). Cancelling the
    /// waiting task ends the wait without stopping the voice.
    public func waitUntilDrained() async {
        let id: UInt64 = work.sync {
            nextWaiter += 1
            return nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Checked on the queue the cancellation handler also uses, so a cancel can't slip between the two.
                let done: Bool = work.sync {
                    if lines.isEmpty || Task.isCancelled { return true }
                    drainWaiters[id] = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            work.async { [weak self] in self?.drainWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    public var isIdle: Bool { work.sync { lines.isEmpty } }

    /// Whether the output is awake (a cue played on a cold output may want a short lead-in).
    public var isOutputRunning: Bool { work.sync { backend.isRunning } }

    /// Where the listener is in the current line.
    public func position() -> Position? {
        work.sync {
            pollLocked()
            deliver()
            guard let line = lines.first, line.started, let start = line.startFrame else { return nil }
            return Position(lineIndex: line.index,
                            elapsed: seconds(min(max(heard - start, 0), line.frames)),
                            duration: line.endFrame.map { seconds($0 - start) })
        }
    }

    /// Advances the timeline to the output's current position and sends due events. Runs by itself every few
    /// milliseconds unless the player was made with `pollInterval: nil`.
    public func poll() {
        work.sync {
            pollLocked()
            deliver()
        }
    }

    // MARK: Timeline (on `work`)

    private var schedulingLine: LineState? { lines.first { !$0.sealed } }

    private func ensureRunning() -> Bool {
        if backend.isRunning { return true }
        do {
            try backend.start()
        } catch {
            handleFailure("\(error)")
            return false
        }
        backend.rate = speed
        // A freshly started output counts from 0 again, and nothing on it has been heard yet.
        base = max(cursor, heard)
        heard = base - 1
        cursor = base
        contiguous = true
        return true
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, for line: LineState) {
        let frames = Int64(buffer.frameLength)
        guard frames > 0 else { return }
        let earliest = base + backend.earliestStartFrame()
        let placed: Int64
        if contiguous && cursor >= earliest {
            // Still ahead of the output: queue right behind the previous buffer, gapless.
            placed = backend.schedule(buffer, atFrame: nil)
        } else {
            // The output ran dry (or an empty line moved the cursor): place the buffer at an exact frame.
            placed = backend.schedule(buffer, atFrame: max(cursor, earliest) - base)
        }
        // The output may have rendered past the planned frame since `earliest` was read; keep the timeline on the
        // frame the audio really starts at, so line boundaries match what is heard.
        let start = base + placed
        cursor = start + frames
        contiguous = true
        segments.append(Segment(start: start, buffer: buffer))
        if line.startFrame == nil { line.startFrame = start }
        line.frames += frames
    }

    /// Seals finished lines in order, releasing the held audio of the next line each time.
    private func advanceScheduling() {
        while let line = schedulingLine {
            if !line.pending.isEmpty {
                let pending = line.pending
                line.pending.removeAll()
                for buffer in pending { schedule(buffer, for: line) }
            }
            guard line.inputFinished else { return }
            if line.startFrame == nil {
                // A line without audio still takes its turn, so pacing sees it start and finish in order.
                let at = max(cursor, base + backend.earliestStartFrame())
                if at != cursor {
                    cursor = at
                    contiguous = false
                }
                line.startFrame = at
            }
            line.endFrame = cursor
            line.sealed = true
        }
    }

    private func pollLocked() {
        guard let audible = backend.audibleFrame() else { return }
        heard = max(heard, base + audible)
        while let line = lines.first {
            if !line.started {
                guard let start = line.startFrame, heard >= start else { break }
                line.started = true
                emit(.lineStarted(index: line.index, expectedDuration: line.endFrame.map { wallSeconds($0 - start) }))
            }
            guard let end = line.endFrame, heard >= end else { break }
            lines.removeFirst()
            emit(.lineFinished(index: line.index))
        }
        while let first = segments.first, first.end <= heard { segments.removeFirst() }
        if lines.isEmpty && !drained {
            emit(.drained)
            settleIdle()
        }
    }

    private func handleRestart(_ reason: String) {
        // The output's clock is back at 0 and its queue is empty: put back everything not yet heard, at the same
        // timeline positions, starting where the listener was.
        let resume = heard
        base = resume - backend.earliestStartFrame()
        var kept: [Segment] = []
        for segment in segments where segment.end > resume {
            let offset = max(0, resume - segment.start)
            guard let buffer = offset > 0 ? PCMConverter.slice(segment.buffer, from: Int(offset)) : segment.buffer else { continue }
            let start = segment.start + offset
            let placed = backend.schedule(buffer, atFrame: start - base)
            // The new output rendered past the planned frame first: move the whole mapping with it (nothing on this
            // clock has been heard yet), so the rest of the audio and every line boundary keep their relative places.
            if base + placed != start { base = start - placed }
            kept.append(Segment(start: start, buffer: buffer))
        }
        segments = kept
        contiguous = kept.last?.end == cursor
        backend.rate = speed
        emit(.outputRestarted(reason: reason))
        deliver()
    }

    private func handleFailure(_ message: String) {
        resetTimeline()
        emit(.outputFailed(message))
        settleIdle()
        deliver()
    }

    private func resetTimeline() {
        lines.removeAll()
        segments.removeAll()
        base = 0
        cursor = 0
        // The output clock restarts at 0 (flush); frame 0 counts as heard only once the output says so.
        heard = -1
        contiguous = true
    }

    /// Nothing left to play: wake waiters, stop polling, and release the output after a while.
    private func settleIdle() {
        drained = true
        let waiters = drainWaiters.values
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        timer?.cancel()
        timer = nil
        idleToken += 1
        let token = idleToken
        work.asyncAfter(idleSeconds) { [weak self] in
            guard let self, self.idleToken == token, self.lines.isEmpty, self.backend.isRunning else { return }
            self.backend.release()
        }
    }

    private func startTimer() {
        guard timer == nil, let pollInterval else { return }
        let timer = DispatchSource.makeTimerSource(queue: work.queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollLocked()
            self.deliver()
        }
        timer.resume()
        self.timer = timer
    }

    private func emit(_ event: Event) { relay.emit(event) }

    /// Sends queued events in order. Handlers may call back into the player; their events join the same queue.
    private func deliver() { relay.deliver() }

    private func convert(_ pcm: Data, format: PCMFormat, for line: LineState) -> AVAudioPCMBuffer? {
        var data = pcm
        var source = format
        if source.channels > 1 {
            data = PCMConverter.downmixToMono(data, channels: source.channels)
            source = PCMFormat(sampleRate: source.sampleRate, channels: 1)
        }
        if source.sampleRate == sampleRate { return try? PCMConverter.floatBuffer(fromPCM16: data, format: source) }
        if line.resampler == nil || line.resamplerRate != source.sampleRate {
            line.resampler = try? PCMResampler(from: PCMConverter.avFormat(source), to: floatFormat)
            line.resamplerRate = source.sampleRate
        }
        guard let resampler = line.resampler,
              let input = try? PCMConverter.int16Buffer(fromPCM16: data, format: source) else { return nil }
        return try? resampler.convert(input)
    }

    private func seconds(_ frames: Int64) -> TimeInterval { Double(frames) / Double(sampleRate) }
    private func wallSeconds(_ frames: Int64) -> TimeInterval { seconds(frames) / Double(speed) }

    private final class LineState {
        let id: UInt64
        let index: Int
        var pending: [AVAudioPCMBuffer] = []
        var resampler: PCMResampler?
        var resamplerRate = 0
        var inputFinished = false
        /// All of the line's audio is scheduled and its end frame is known.
        var sealed = false
        var startFrame: Int64?
        var endFrame: Int64?
        var frames: Int64 = 0
        var started = false

        init(id: UInt64, index: Int) {
            self.id = id
            self.index = index
        }
    }

    private struct Segment {
        var start: Int64
        var buffer: AVAudioPCMBuffer
        var end: Int64 { start + Int64(buffer.frameLength) }
    }
}

extension SpeechPlayer {
    /// Forwards line starts and finishes to the drawing engine's pacing, on the main actor, until the returned task is
    /// cancelled.
    @MainActor
    public func relayTimeline(to pacing: any SpeechPacing) -> Task<Void, Never> {
        let stream = events()
        return Task { @MainActor in
            for await event in stream {
                switch event {
                case .lineStarted(let index, let expected): pacing.lineStarted(index, expectedDuration: expected)
                case .lineFinished(let index): pacing.lineFinished(index)
                default: break
                }
            }
        }
    }
}
