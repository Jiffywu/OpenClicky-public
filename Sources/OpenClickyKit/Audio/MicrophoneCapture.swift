import AVFoundation
import Foundation

/// Live microphone capture on AVAudioEngine.
///
/// Each press calls `start()` and gets a fresh stream of PCM16 chunks in the requested format (mono 16 kHz for most
/// speech-to-text, 24 kHz for realtime voices), each `chunkDuration` long, plus an input level for the waveform.
///
/// - Echo cancellation: create the capture and the `SpeechPlayer` on one `AudioEngineHost(voiceProcessing: true)`;
///   the voice is then removed from what the mic hears, so the user can talk over it (barge-in).
/// - Devices: follows the system default input unless a device is selected; rebuilds when devices change.
/// - Health: if a whole window passes without an audible chunk, the engine is rebuilt; after repeated failures it
///   fails over to the built-in mic, then reports `.irrecoverable` (see `MicHealthMonitor`).
/// - Bluetooth: after a press on a Bluetooth input the device stays open, muted, for `bluetoothHold` seconds so the
///   headset doesn't flip profiles on every press (see `MicLifecycle`).
///
/// Needs microphone permission (`requestAccess()`); without it `start()` throws instead of capturing silence.
public final class MicrophoneCapture: @unchecked Sendable {
    public struct Options: Sendable, Hashable {
        /// Format of delivered chunks (channels > 1 duplicates the mono signal).
        public var format: PCMFormat
        /// Seconds of audio per chunk.
        public var chunkDuration: TimeInterval
        /// Input device UID; nil follows the system default.
        public var deviceUID: String?
        /// Seconds to keep a Bluetooth input open after a press; 0 closes at once.
        public var bluetoothHold: TimeInterval
        public var health: MicHealthMonitor.Policy
        /// How often the health monitor is consulted.
        public var healthCheckInterval: TimeInterval
        /// Chunks buffered for a slow consumer before newer ones are dropped.
        public var maxBufferedChunks: Int
        /// Start already failed over to this input (carried over from an earlier capture of the same mic, so a
        /// rebuilt capture doesn't go back to the dead one). `selectDevice(uid:)` drops it.
        public var failoverUID: String?

        public init(format: PCMFormat = .speech16k, chunkDuration: TimeInterval = 0.04, deviceUID: String? = nil,
                    bluetoothHold: TimeInterval = 8, health: MicHealthMonitor.Policy = .init(),
                    healthCheckInterval: TimeInterval = 0.25, maxBufferedChunks: Int = 750, failoverUID: String? = nil) {
            self.format = format
            self.chunkDuration = chunkDuration
            self.deviceUID = deviceUID
            self.bluetoothHold = bluetoothHold
            self.health = health
            self.healthCheckInterval = healthCheckInterval
            self.maxBufferedChunks = maxBufferedChunks
            self.failoverUID = failoverUID
        }
    }

    public struct Chunk: Sendable, Hashable {
        public var pcm: Data
        public var format: PCMFormat
        public var level: AudioLevel
        /// Seconds from the start of this press's stream to the start of the chunk.
        public var time: TimeInterval
    }

    public enum Event: Sendable, Hashable {
        /// Audio is flowing for this press (play the start cue now, not before).
        case running(device: String?)
        /// The engine was rebuilt underneath the press (device or route change).
        case routeChanged(reason: String)
        /// The health monitor found the capture dead and is rebuilding it.
        case rebuilding(MicHealthMonitor.Problem)
        case failedOver(from: String?, to: String)
        /// Nothing more to try: tell the user to check the microphone.
        case irrecoverable(MicHealthMonitor.Problem)
        /// Press ended on a Bluetooth input; the device stays open (muted) this long.
        case holdingBluetooth(seconds: TimeInterval)
        /// The consumer fell behind; this many chunks were dropped so far this press.
        case overflow(dropped: Int)
        case closed
        case failed(String)
    }

    public enum Authorization: Sendable, Hashable { case authorized, denied, restricted, notDetermined }

    public let options: Options
    public let host: AudioEngineHost
    private var work: AudioWorkQueue { host.work }
    private let relay = EventRelay<Event>()
    private let levelBroadcaster = Broadcaster<Float>()
    private let currentLevel = LockedValue<Float>(0)
    private let sink: MicSink

    // Everything below is confined to `work`.
    private var lifecycle: MicLifecycle
    private var health: MicHealthMonitor
    private var tap: MicTap?
    private var tapEngine: ObjectIdentifier?
    /// The chosen input and any failover pin to the built-in mic.
    private var pin: MicInputPin
    private var inputDevice: AudioDeviceInfo?
    private var announcedRunning = false
    private var runningWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiter: UInt64 = 0
    private var healthTimer: DispatchSourceTimer?
    private var holdToken = 0
    private var smoother = LevelSmoother()
    private var reportedOverflow = 0

    /// A capture on its own engine, or on `host` (share it with the SpeechPlayer for echo cancellation).
    public init(options: Options = Options(), host: AudioEngineHost? = nil) {
        self.options = options
        self.host = host ?? AudioEngineHost(label: "OpenClicky.microphone")
        self.lifecycle = MicLifecycle(bluetoothHold: options.bluetoothHold)
        self.health = MicHealthMonitor(policy: options.health)
        self.pin = MicInputPin(selected: options.deviceUID, failover: options.failoverUID)
        self.sink = MicSink(format: options.format)
        let host = self.host
        host.work.sync { host.register(self) }
    }

    deinit {
        healthTimer?.cancel()
        sink.finish()
        relay.finish()
        levelBroadcaster.finish()
        // Nothing else can reach this object now (queue blocks hold it weakly), so its confined state is safe to read.
        let host = self.host
        let tappedEngine = tapEngine
        host.work.async {
            if let engine = host.engine, ObjectIdentifier(engine) == tappedEngine { engine.inputNode.removeTap(onBus: 0) }
            host.releaseIfUnused()
        }
    }

    // MARK: Permission

    public static var authorization: Authorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Shows the system prompt the first time; returns whether access is granted.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Observing

    public var onEvent: (@Sendable (Event) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    public func events() -> AsyncStream<Event> { relay.stream() }

    /// Smoothed input level 0…1 for a waveform (0 while not capturing).
    public var level: Float { currentLevel.get() }

    /// The smoothed level once per chunk.
    public func levels() -> AsyncStream<Float> { levelBroadcaster.stream(bufferingNewest: 8) }

    /// The input device the capture is using (nil while closed).
    public var device: AudioDeviceInfo? { work.sync { inputDevice } }

    public var isCapturing: Bool { work.sync { lifecycle.isDelivering } }

    /// The chosen input and, after a dead mic, the built-in mic it failed over to.
    public var inputPin: MicInputPin { work.sync { pin } }

    // MARK: Pressing

    /// Starts delivering for a new press. A press still running is finished first.
    public func start() throws -> AsyncStream<Chunk> {
        switch Self.authorization {
        case .denied, .restricted: throw AudioIOError.microphonePermissionDenied
        case .notDetermined: throw AudioIOError.microphonePermissionUndetermined
        case .authorized: break
        }
        return try work.sync {
            sink.finish()
            resolveWaiters(false)
            let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingOldest(options.maxBufferedChunks))
            let action = lifecycle.start()
            holdToken += 1
            announcedRunning = false
            reportedOverflow = 0
            health.reset(at: audioUptime())
            smoother.reset()
            do {
                // A changed choice rebuilds the engine (acquire compares it with the input the engine was built on).
                host.preferredInputUID = pin.effective
                let engine = try host.acquire(input: true)
                if tapEngine != ObjectIdentifier(engine) { try installTap(on: engine) }
            } catch {
                _ = lifecycle.close()
                closeDevice(announce: false)
                relay.deliver()
                throw error
            }
            // Audio captured while a held device was muted must not leak into the new press.
            if action == .resume { tap?.discardPending() }
            sink.begin(continuation)
            startHealthTimer()
            relay.deliver()
            return stream
        }
    }

    /// Ends the press: the stream gets the last partial chunk and finishes. A Bluetooth input is held open (muted)
    /// unless `holdBluetooth` is false.
    public func stop(holdBluetooth: Bool = true) {
        work.sync {
            guard lifecycle.isDelivering else { return }
            if let tap { tap.flush().forEach(noteChunk) }
            sink.finish()
            stopHealthTimer()
            resolveWaiters(false)
            let isBluetooth = inputDevice?.transport.isBluetooth == true
            switch lifecycle.stop(at: audioUptime(), inputIsBluetooth: isBluetooth, allowHold: holdBluetooth) {
            case .mute:
                setLevel(0)
                relay.emit(.holdingBluetooth(seconds: lifecycle.bluetoothHold))
                scheduleHoldClose()
            case .close:
                closeDevice(announce: true)
            default:
                break
            }
            relay.deliver()
        }
    }

    /// Closes the device now (ends a press and any Bluetooth hold).
    public func close() {
        work.sync {
            if lifecycle.isDelivering, let tap { tap.flush().forEach(noteChunk) }
            sink.finish()
            stopHealthTimer()
            resolveWaiters(false)
            if lifecycle.close() == .close { closeDevice(announce: true) }
            relay.deliver()
        }
    }

    /// Choose an input device (nil = system default). A user choice also drops a failover pin to the built-in mic.
    public func selectDevice(uid: String?) {
        work.sync {
            pin.select(uid)
            guard host.preferredInputUID != uid else { return }
            host.preferredInputUID = uid
            if lifecycle.isOpen { host.rebuild(reason: "microphone selection changed") }
            relay.deliver()
        }
    }

    /// Waits until audio is flowing for the current press (true), or `timeout` passes or the press ends (false).
    public func waitUntilRunning(timeout: TimeInterval = 1.5) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate: Bool? = work.sync {
                // A press that already ended doesn't count as running, even if audio flowed during it.
                if !lifecycle.isDelivering { return false }
                if announcedRunning { return true }
                nextWaiter += 1
                let id = nextWaiter
                runningWaiters[id] = continuation
                work.asyncAfter(timeout) { [weak self] in
                    self?.runningWaiters.removeValue(forKey: id)?.resume(returning: false)
                }
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    // MARK: Private (on `work`)

    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw AudioIOError.inputFormatInvalid(sampleRate: hardware.sampleRate, channels: Int(hardware.channelCount))
        }
        // With voice processing the first channel carries the echo-cancelled voice.
        let tap = try MicTap(inputFormat: hardware, target: options.format, chunkDuration: options.chunkDuration,
                             channel: host.voiceProcessing ? 0 : nil, sink: sink) { [weak self] stats in
            guard let self else { return }
            self.work.async {
                self.noteChunk(stats)
                self.relay.deliver()
            }
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate * 0.02), format: hardware) { buffer, _ in
            tap.process(buffer)
        }
        self.tap = tap
        tapEngine = ObjectIdentifier(engine)
        inputDevice = host.preferredInputUID.flatMap { AudioDevices.device(uid: $0) } ?? AudioDevices.defaultInput()
    }

    private func noteChunk(_ stats: MicTap.ChunkStats) {
        guard lifecycle.isDelivering else { return }
        health.observe(peak: stats.level.peak, at: audioUptime())
        setLevel(smoother.update(stats.level.normalized))
        if stats.delivered && !announcedRunning {
            announcedRunning = true
            relay.emit(.running(device: inputDevice?.name))
            resolveWaiters(true)
        }
        if stats.droppedSoFar > reportedOverflow {
            reportedOverflow = stats.droppedSoFar
            relay.emit(.overflow(dropped: stats.droppedSoFar))
        }
    }

    private func setLevel(_ value: Float) {
        currentLevel.set(value)
        levelBroadcaster.yield(value)
    }

    private func resolveWaiters(_ value: Bool) {
        let waiters = runningWaiters.values
        runningWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }

    private func closeDevice(announce: Bool) {
        if let engine = host.engine, tapEngine == ObjectIdentifier(engine) { engine.inputNode.removeTap(onBus: 0) }
        tap = nil
        tapEngine = nil
        inputDevice = nil
        setLevel(0)
        host.releaseIfUnused()
        if announce { relay.emit(.closed) }
    }

    private func scheduleHoldClose() {
        holdToken += 1
        let token = holdToken
        work.asyncAfter(lifecycle.bluetoothHold + 0.01) { [weak self] in
            guard let self, self.holdToken == token else { return }
            if self.lifecycle.tick(at: audioUptime()) == .close {
                self.closeDevice(announce: true)
                self.relay.deliver()
            }
        }
    }

    private func startHealthTimer() {
        stopHealthTimer()
        let timer = DispatchSource.makeTimerSource(queue: work.queue)
        timer.schedule(deadline: .now() + options.healthCheckInterval, repeating: options.healthCheckInterval, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkHealth()
            self.relay.deliver()
        }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func checkHealth() {
        guard lifecycle.isDelivering, let verdict = health.check(at: audioUptime()) else { return }
        switch verdict {
        case .rebuild(let problem):
            relay.emit(.rebuilding(problem))
            host.rebuild(reason: "microphone \(problem == .noAudio ? "delivered no audio" : "delivered only silence")")
        case .failover(let problem):
            guard let builtIn = AudioDevices.builtInInput(), builtIn.uid != inputDevice?.uid else {
                relay.emit(.irrecoverable(problem))
                stopHealthTimer()
                return
            }
            pin.failOver(to: builtIn.uid)
            host.preferredInputUID = builtIn.uid
            relay.emit(.failedOver(from: inputDevice?.name, to: builtIn.name))
            host.rebuild(reason: "failed over to the built-in microphone")
        case .irrecoverable(let problem):
            relay.emit(.irrecoverable(problem))
            stopHealthTimer()
        }
    }
}

extension MicrophoneCapture: AudioEngineClient {
    var needsEngine: Bool { lifecycle.isOpen }
    var needsInput: Bool { lifecycle.isOpen }

    func attach(to engine: AVAudioEngine) throws {
        guard lifecycle.isOpen else { return }
        try installTap(on: engine)
    }

    func detach(from engine: AVAudioEngine) {
        if tapEngine == ObjectIdentifier(engine) { engine.inputNode.removeTap(onBus: 0) }
        tap = nil
        tapEngine = nil
    }

    func engineDidStart(rebuildReason: String?) {
        guard let rebuildReason, lifecycle.isOpen else { return }
        health.started(at: audioUptime())
        relay.emit(.routeChanged(reason: rebuildReason))
        relay.deliver()
    }

    func engineDidFail(_ message: String) {
        sink.finish()
        stopHealthTimer()
        resolveWaiters(false)
        _ = lifecycle.close()
        tap = nil
        tapEngine = nil
        inputDevice = nil
        setLevel(0)
        relay.emit(.failed(message))
        relay.deliver()
    }
}

/// Where chunks go: the current press's stream. Thread-safe; the tap thread yields directly so chunk order is kept
/// even when a press ends while a buffer is being converted.
final class MicSink: @unchecked Sendable {
    private let lock = NSLock()
    private let format: PCMFormat
    private var continuation: AsyncStream<MicrophoneCapture.Chunk>.Continuation?
    private var frames = 0
    private var dropped = 0

    init(format: PCMFormat) { self.format = format }

    func begin(_ continuation: AsyncStream<MicrophoneCapture.Chunk>.Continuation) {
        lock.withLock {
            self.continuation?.finish()
            self.continuation = continuation
            frames = 0
            dropped = 0
        }
    }

    /// Returns whether a press was listening, and the dropped-chunk count so far.
    func yield(_ pcm: Data, level: AudioLevel) -> (delivered: Bool, dropped: Int) {
        lock.withLock {
            guard let continuation else { return (false, dropped) }
            let time = Double(frames) / Double(max(1, format.sampleRate))
            frames += pcm.count / (2 * max(1, format.channels))
            if case .dropped = continuation.yield(MicrophoneCapture.Chunk(pcm: pcm, format: format, level: level, time: time)) {
                dropped += 1
            }
            return (true, dropped)
        }
    }

    func finish() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

/// Converts what an input tap delivers (any rate, any channel count, Float32) into fixed-size PCM16 chunks.
final class MicTap: @unchecked Sendable {
    struct ChunkStats: Sendable {
        var level: AudioLevel
        var delivered: Bool
        var droppedSoFar: Int
    }

    private let lock = NSLock()
    private let inputRate: Double
    private let channel: Int?
    private let resampler: PCMResampler?
    private var chunker: PCM16Chunker
    private let sink: MicSink
    private let onChunk: @Sendable (ChunkStats) -> Void

    init(inputFormat: AVAudioFormat, target: PCMFormat, chunkDuration: TimeInterval, channel: Int?, sink: MicSink,
         onChunk: @escaping @Sendable (ChunkStats) -> Void) throws {
        inputRate = inputFormat.sampleRate
        self.channel = channel
        self.sink = sink
        self.onChunk = onChunk
        chunker = PCM16Chunker(format: target, duration: chunkDuration)
        if inputFormat.sampleRate == Double(target.sampleRate) && target.channels == 1 {
            resampler = nil
        } else {
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)!
            resampler = try PCMResampler(from: mono, to: PCMConverter.avFormat(target))
        }
    }

    /// Called on the tap thread with each captured buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        let stats: [ChunkStats] = lock.withLock {
            let mono = PCMConverter.monoFloats(from: buffer, channel: channel)
            guard !mono.isEmpty else { return [] }
            return chunker.append(convert(mono)).map(send)
        }
        stats.forEach(onChunk)
    }

    /// End of a press: delivers what the converter and the chunker still hold.
    func flush() -> [ChunkStats] {
        lock.withLock {
            var stats: [ChunkStats] = []
            if let resampler, let tail = try? resampler.finish() {
                stats += chunker.append(PCMConverter.pcm16(from: tail)).map(send)
            }
            if let rest = chunker.flush() { stats.append(send(rest)) }
            return stats
        }
    }

    /// Forgets partially converted audio (after a muted hold).
    func discardPending() {
        lock.withLock {
            resampler?.reset()
            _ = chunker.flush()
        }
    }

    private func convert(_ mono: [Float]) -> Data {
        guard let resampler else { return PCMConverter.pcm16(fromFloats: mono) }
        let input = PCMConverter.floatBuffer(mono: mono, sampleRate: inputRate)
        guard let output = try? resampler.convert(input) else { return Data() }
        return PCMConverter.pcm16(from: output)
    }

    private func send(_ chunk: Data) -> ChunkStats {
        let level = AudioLevel.measure(pcm16: chunk)
        let result = sink.yield(chunk, level: level)
        return ChunkStats(level: level, delivered: result.delivered, droppedSoFar: result.dropped)
    }
}

/// Queues events while state changes on an audio queue and sends them, in order, once the change is complete;
/// handlers may call back in without reordering anything.
final class EventRelay<Event: Sendable>: @unchecked Sendable {
    private let handlerBox = LockedValue<(@Sendable (Event) -> Void)?>(nil)
    private let broadcaster = Broadcaster<Event>()
    // Confined to the owner's audio queue.
    private var outbox: [Event] = []
    private var delivering = false

    var handler: (@Sendable (Event) -> Void)? {
        get { handlerBox.get() }
        set { handlerBox.set(newValue) }
    }

    func stream(bufferingNewest limit: Int = 256) -> AsyncStream<Event> { broadcaster.stream(bufferingNewest: limit) }

    func emit(_ event: Event) { outbox.append(event) }

    func deliver() {
        guard !delivering else { return }
        delivering = true
        while !outbox.isEmpty {
            let event = outbox.removeFirst()
            handlerBox.get()?(event)
            broadcaster.yield(event)
        }
        delivering = false
    }

    func finish() { broadcaster.finish() }
}
