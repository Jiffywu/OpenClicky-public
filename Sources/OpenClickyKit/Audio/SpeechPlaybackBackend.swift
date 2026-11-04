import AVFoundation
import Foundation
import os

/// The output `SpeechPlayer` schedules into. The real one renders from an AVAudioSourceNode (through an
/// AVAudioUnitTimePitch when the speed isn't 1x) on an `AudioEngineHost`; tests use `FakeSpeechPlaybackBackend`, whose
/// clock they move by hand.
///
/// Frames are counted on the output's own clock in player frames (frames of the scheduled buffers, before any speed
/// change), starting at 0 whenever the output starts or is flushed. Every method is called on `work`.
public protocol SpeechPlaybackBackend: AnyObject {
    var work: AudioWorkQueue { get }
    /// Rate of the mono Float32 buffers the player schedules.
    var sampleRate: Double { get }
    var isRunning: Bool { get }
    /// Playback speed (1 = normal) without changing pitch.
    var rate: Float { get set }
    /// The output restarted by itself (a device change) and lost its queued audio; the clock is back at 0.
    var onRestart: ((String) -> Void)? { get set }
    /// The output died and could not be brought back.
    var onFailure: ((String) -> Void)? { get set }

    func start() throws
    /// Stops at once, drops queued audio and resets the clock to 0; stays ready to play.
    func flush()
    /// Lets the output go idle; the device may be released. `start()` brings it back.
    func release()
    /// Queue a buffer at `frame` on the output clock, or right after the previously queued audio when nil. Returns the
    /// frame it will really start at: later than asked when the output has already rendered past that point (it can
    /// render between an `earliestStartFrame()` check and this call).
    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer, atFrame frame: Int64?) -> Int64
    /// The earliest frame a buffer scheduled now is guaranteed to start at.
    func earliestStartFrame() -> Int64
    /// The frame reaching the listener now (output latency removed), or nil while nothing is running.
    func audibleFrame() -> Int64?
}

/// AVAudioSourceNode → (AVAudioUnitTimePitch when not at 1x) → main mixer, on a shared or private engine host.
///
/// The source node's render block reads the queued buffers by timeline frame, so the output clock is exactly the
/// number of frames rendered: a buffer placed at frame F is rendered at F, with no scheduling slack. (An
/// AVAudioPlayerNode was tried first; its sample clock ran a render cycle away from what it actually played, and
/// explicitly timed buffers could lose their first cycle.)
///
/// The time-pitch unit buffers roughly 40–100 ms of audio even when bypassed, so it is only in the graph while the speed
/// isn't 1x, and its delay (measured once per speed, offline) is subtracted from the audible position.
final class EngineSpeechOutput: SpeechPlaybackBackend, AudioEngineClient {
    let host: AudioEngineHost
    var work: AudioWorkQueue { host.work }
    let sampleRate: Double
    private let format: AVAudioFormat
    private let timeline = SourceTimeline()
    private var source: AVAudioSourceNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var pitchConnected = false
    private(set) var isRunning = false
    private var outputLatency: TimeInterval = 0
    /// Timeline frames the time-pitch unit holds back at the current speed (0 when it is out of the graph).
    private var pitchDelay: Int64 = 0
    var onRestart: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    var rate: Float = 1 {
        didSet { applyRate() }
    }

    init(host: AudioEngineHost, sampleRate: Double) {
        self.host = host
        self.sampleRate = sampleRate
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        host.work.sync { host.register(self) }
    }

    deinit {
        // On a shared host the engine outlives this output. Silence it at once (the render block holds the timeline),
        // then take its nodes out of the engine and let the host release the device if nobody else needs it. Nothing
        // else can reach this object now, so its queue-confined node references are safe to read here.
        timeline.reset()
        let host = self.host
        let nodes = OwnedNodes(list: [source, timePitch].compactMap { $0 })
        host.work.async {
            if let engine = host.engine {
                for node in nodes.list where node.engine === engine { engine.detach(node) }
            }
            host.releaseIfUnused()
        }
    }

    private var isOffline: Bool { host.mode != .realtime }
    private var usesPitch: Bool { abs(rate - 1) >= 0.001 }

    // MARK: AudioEngineClient

    var needsEngine: Bool { isRunning }
    var needsInput: Bool { false }

    func attach(to engine: AVAudioEngine) throws {
        let timeline = self.timeline
        let source = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let stamp = timestamp.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
            let audible = timeline.render(into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount), hostTime: hostTime)
            // Mono format: any further buffers (there shouldn't be) get the same samples.
            for index in buffers.indices.dropFirst() {
                if let extra = buffers[index].mData { extra.copyMemory(from: data, byteCount: Int(frameCount) * 4) }
            }
            if !audible { isSilence.pointee = true }
            return noErr
        }
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(source)
        engine.attach(timePitch)
        self.source = source
        self.timePitch = timePitch
        pitchConnected = false
        connect(in: engine)
    }

    func detach(from engine: AVAudioEngine) {
        if let source { engine.detach(source) }
        if let timePitch { engine.detach(timePitch) }
        source = nil
        timePitch = nil
        pitchConnected = false
        // The engine is going away with whatever it had queued; the clock restarts with the next one.
        timeline.reset()
    }

    func engineDidStart(rebuildReason: String?) {
        outputLatency = isOffline ? 0 : (host.engine?.outputNode.presentationLatency ?? 0)
        updatePitchDelay()
        guard isRunning, let rebuildReason else { return }
        onRestart?(rebuildReason)
    }

    func engineDidFail(_ message: String) {
        isRunning = false
        timeline.reset()
        onFailure?(message)
    }

    // MARK: SpeechPlaybackBackend

    func start() throws {
        if !isRunning { timeline.reset() }
        isRunning = true
        do {
            let engine = try host.acquire(input: false)
            if source == nil { try attach(to: engine) }
            outputLatency = isOffline ? 0 : engine.outputNode.presentationLatency
        } catch {
            isRunning = false
            throw error
        }
        updatePitchDelay()
    }

    func flush() {
        timeline.reset()
        // Drop what the time-pitch unit is still holding, or the old voice trails on after a barge-in.
        if pitchConnected { timePitch?.reset() }
    }

    func release() {
        isRunning = false
        timeline.reset()
        host.releaseIfUnused()
    }

    func schedule(_ buffer: AVAudioPCMBuffer, atFrame frame: Int64?) -> Int64 {
        timeline.schedule(buffer, at: frame)
    }

    func earliestStartFrame() -> Int64 {
        // The render block reads the queue when it renders, so anything placed at the next unrendered frame plays there.
        timeline.renderedFrames
    }

    func audibleFrame() -> Int64? {
        guard isRunning, let last = timeline.lastRender else { return nil }
        // The newest frame that has actually been rendered; nothing later can be reaching the listener yet.
        let rendered = last.start + Int64(last.frames) - 1
        guard !isOffline else { return rendered - pitchDelay }
        // The render's host time is when its first frame leaves for the device; move forward by the time since then
        // (negative while that render is still queued) and back by the device's own latency.
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let elapsed = now - AVAudioTime.seconds(forHostTime: last.hostTime) - outputLatency
        let speed = Double(usesPitch ? rate : 1)
        let estimate = last.start + Int64((elapsed * sampleRate * speed).rounded(.down))
        // Never ahead of what has actually been rendered.
        return min(estimate, rendered) - pitchDelay
    }

    // MARK: Private

    /// Source → mixer at 1x; source → time pitch → mixer otherwise.
    private func connect(in engine: AVAudioEngine) {
        guard let source, let timePitch else { return }
        let wantsPitch = usesPitch
        engine.disconnectNodeOutput(source)
        if wantsPitch {
            timePitch.rate = rate
            engine.connect(source, to: timePitch, format: format)
            if !pitchConnected { engine.connect(timePitch, to: engine.mainMixerNode, format: format) }
        } else {
            engine.disconnectNodeOutput(timePitch)
            timePitch.reset()
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
        pitchConnected = wantsPitch
    }

    private func applyRate() {
        guard let engine = host.engine, source != nil else { return }
        if usesPitch && pitchConnected {
            timePitch?.rate = rate
        } else if usesPitch != pitchConnected {
            connect(in: engine)
        }
        updatePitchDelay()
    }

    private func updatePitchDelay() {
        guard usesPitch else {
            pitchDelay = 0
            return
        }
        let outputRate: Double
        switch host.mode {
        case .offline(let rate, _): outputRate = rate
        case .realtime: outputRate = host.engine?.outputNode.outputFormat(forBus: 0).sampleRate ?? 48_000
        }
        pitchDelay = TimePitchCalibration.delay(rate: rate, sampleRate: sampleRate, outputRate: outputRate > 0 ? outputRate : 48_000)
    }
}

/// Nodes handed from a deinit to the host's queue, which is the only place they are touched.
private struct OwnedNodes: @unchecked Sendable {
    let list: [AVAudioNode]
}

/// The queue the source node renders from. The render thread and the audio queue share it under an unfair lock;
/// critical sections are short copies, and nothing in them allocates.
final class SourceTimeline: @unchecked Sendable {
    struct RenderMark: Sendable {
        /// Timeline frame of the render's first frame.
        var start: Int64
        var frames: Int
        var hostTime: UInt64
    }

    private struct Segment {
        var start: Int64
        var buffer: AVAudioPCMBuffer
        var end: Int64 { start + Int64(buffer.frameLength) }
    }

    private let lock = OSAllocatedUnfairLock()
    private var segments: [Segment] = []
    private var queueEnd: Int64 = 0
    private var rendered: Int64 = 0
    private var mark: RenderMark?

    init() { segments.reserveCapacity(256) }

    /// Frames rendered since the last reset (the next frame to render).
    var renderedFrames: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return rendered
    }

    var lastRender: RenderMark? {
        lock.lock()
        defer { lock.unlock() }
        return mark
    }

    /// Queue a mono Float32 buffer at `frame`, or right after the queued audio (never in the past). Returns the frame
    /// it starts at, decided under the same lock the render thread takes.
    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer, at frame: Int64?) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let start = max(frame ?? queueEnd, rendered)
        guard buffer.frameLength > 0 else { return start }
        let segment = Segment(start: start, buffer: buffer)
        if let last = segments.last, last.start > start {
            let index = segments.firstIndex { $0.start > start } ?? segments.endIndex
            segments.insert(segment, at: index)
        } else {
            segments.append(segment)
        }
        queueEnd = max(queueEnd, segment.end)
        return start
    }

    /// Drops everything queued and restarts the clock at 0.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        segments.removeAll(keepingCapacity: true)
        queueEnd = 0
        rendered = 0
        mark = nil
    }

    /// Render thread: fills `frames` samples from the queue (silence where nothing is queued). Returns whether any
    /// queued audio was rendered.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int, hostTime: UInt64) -> Bool {
        out.update(repeating: 0, count: frames)
        lock.lock()
        defer { lock.unlock() }
        let start = rendered
        let end = start + Int64(frames)
        var wrote = false
        var consumed = 0
        for segment in segments {
            if segment.start >= end { break }
            if segment.end <= start {
                consumed += 1
                continue
            }
            let from = max(segment.start, start)
            let to = min(segment.end, end)
            if let samples = segment.buffer.floatChannelData?[0] {
                out.advanced(by: Int(from - start)).update(from: samples.advanced(by: Int(from - segment.start)), count: Int(to - from))
                wrote = true
            }
            if segment.end <= end { consumed += 1 }
        }
        if consumed > 0 { segments.removeFirst(consumed) }
        rendered = end
        mark = RenderMark(start: start, frames: frames, hostTime: hostTime)
        return wrote
    }
}

/// How many timeline frames AVAudioUnitTimePitch holds back at a given speed, measured once per configuration by
/// rendering a tone through it offline and seeing when it comes out.
enum TimePitchCalibration {
    private static let cache = LockedValue<[String: Int64]>([:])

    static func delay(rate: Float, sampleRate: Double, outputRate: Double) -> Int64 {
        let key = "\(rate)|\(sampleRate)|\(outputRate)"
        if let known = cache.get()[key] { return known }
        let measured = (try? measure(rate: rate, sampleRate: sampleRate, outputRate: outputRate))
            ?? Int64((0.075 * sampleRate).rounded()) // typical when measuring fails
        cache.mutate { $0[key] = measured }
        return measured
    }

    /// Frames pulled from the source minus frames heard, averaged once the unit has settled.
    static func measure(rate: Float, sampleRate: Double, outputRate: Double) throws -> Int64 {
        let engine = AVAudioEngine()
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1),
              let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioIOError.invalidAudioData("calibration formats")
        }
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        let pulled = LockedValue<Int64>(0)
        let toneStart = LockedValue<Int64>(.max)
        let source = AVAudioSourceNode(format: sourceFormat) { _, _, frameCount, audioBufferList in
            guard let data = UnsafeMutableAudioBufferListPointer(audioBufferList).first?.mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            let first = pulled.get()
            let start = toneStart.get()
            for index in 0..<Int(frameCount) {
                let frame = first + Int64(index)
                out[index] = frame >= start ? Float(0.5 * sin(2 * Double.pi * 300 * Double(frame - start) / sampleRate)) : 0
            }
            pulled.set(first + Int64(frameCount))
            return noErr
        }
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = rate
        engine.attach(source)
        engine.attach(timePitch)
        engine.connect(source, to: timePitch, format: sourceFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: sourceFormat)
        try engine.start()
        defer { engine.stop() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else {
            throw AudioIOError.invalidAudioData("calibration buffer")
        }
        let slice = 512
        var output = 0
        func render() throws -> [Float] {
            guard try engine.renderOffline(AVAudioFrameCount(slice), to: buffer) == .success else {
                throw AudioIOError.engineStartFailed("calibration render")
            }
            output += slice
            return PCMConverter.monoFloats(from: buffer)
        }
        while output < Int(0.2 * outputRate) { _ = try render() }
        let startFrame = pulled.get()
        toneStart.set(startFrame)
        var emerged: Int?
        var samples: [(output: Int, pulled: Int64)] = []
        while output < Int(0.2 * outputRate) + Int(0.6 * outputRate) {
            let before = output
            let mono = try render()
            if emerged == nil, let index = mono.firstIndex(where: { abs($0) > 0.02 }) { emerged = before + index }
            samples.append((output, pulled.get() - startFrame))
        }
        guard let emerged else { throw AudioIOError.invalidAudioData("calibration tone never emerged") }
        let scale = Double(rate) * sampleRate / outputRate
        let settled = samples.filter { $0.output > emerged + Int(0.1 * outputRate) }
        guard !settled.isEmpty else { throw AudioIOError.invalidAudioData("calibration too short") }
        let total = settled.reduce(0.0) { $0 + Double($1.pulled) - scale * Double($1.output - emerged) }
        return Int64((total / Double(settled.count)).rounded())
    }
}
