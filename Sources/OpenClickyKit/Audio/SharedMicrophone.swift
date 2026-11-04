import Foundation

/// The physical microphone behind a `SharedMicrophone`: PCM16 chunks in the format asked for until `stop`.
public protocol SharedMicrophoneDevice: AnyObject, Sendable {
    /// Opens the device (or hands it to a new caller: a stream still open is finished first).
    func start(format: PCMFormat) throws -> AsyncStream<Data>
    /// Ends the current stream. `keepWarm` may hold a Bluetooth input open for a moment (between voice-loop presses).
    func stop(keepWarm: Bool)
    /// Input level 0…1 (0 when closed).
    var level: Float { get }
    /// Waits until audio is flowing for the current stream (true), or `timeout` passes or the stream ends (false).
    /// Devices that can't tell answer true at once.
    func waitUntilLive(timeout: TimeInterval) async -> Bool
    /// The user picked an input (nil: the system default). Drops a failover pin to the built-in mic.
    func select(deviceUID: String?)
    /// The built-in mic the device failed over to after the chosen one went dead (nil when it hasn't).
    var failoverPin: String? { get }
    /// Called (on an audio queue) with the capture's own events: rebuilds, failover, a dead mic, dropped chunks.
    func setEventHandler(_ handler: (@Sendable (MicrophoneCapture.Event) -> Void)?)
}

extension SharedMicrophoneDevice {
    public func waitUntilLive(timeout: TimeInterval) async -> Bool { true }
    public func select(deviceUID: String?) {}
    public var failoverPin: String? { nil }
    public func setEventHandler(_ handler: (@Sendable (MicrophoneCapture.Event) -> Void)?) {}
}

/// One microphone for the voice loop and always-on voice. Each gets its own handle over the same device (`turns`, a
/// `TurnMicrophone`, and `alwaysOn`, a `RealtimeMicrophone`); whichever opened it last holds it, and a handle's `stop()`
/// does nothing unless that handle holds the mic, so a late stop from one side can't cut the other off.
///
/// The app never lets both listen at once (the voice loop holds its turns while always-on runs), so the handover
/// only matters for stragglers: a press being torn down while always-on starts, or a dropped session's cleanup.
///
/// Each stream a handle stopped itself is summed up for dead-air counting (`onStreamEnded`), and the capture's own
/// trouble events come out of `onCaptureEvent` (docs/audio-robustness.md).
public final class SharedMicrophone: @unchecked Sendable {
    public enum User: String, Sendable, Hashable {
        case turns
        case alwaysOn = "always_on"
    }

    private let core: Core
    /// The voice loop's handle.
    public let turns: TurnHandle
    /// Always-on voice's handle.
    public let alwaysOn: Handle

    /// `maxBufferedChunks`: chunks kept for a reader that fell behind before newer ones are dropped (and reported as
    /// `.overflow` through `onCaptureEvent`). 750 is 30 s of the capture's 40 ms chunks.
    public init(device: any SharedMicrophoneDevice, maxBufferedChunks: Int = 750) {
        core = Core(device: device, maxBufferedChunks: maxBufferedChunks)
        turns = TurnHandle(core: core)
        alwaysOn = Handle(core: core, user: .alwaysOn)
    }

    /// The Mac's microphone (`MicrophoneCapture`, rebuilt when the format changes). Needs microphone permission.
    public convenience init(deviceUID: String? = nil) {
        self.init(device: CaptureMicrophoneDevice(deviceUID: deviceUID))
    }

    /// Who holds the mic now (nil when closed).
    public var holder: User? { core.holder }

    /// The input level while open.
    public var level: Float { core.holder == nil ? 0 : core.device.level }

    /// Called (from any thread) when a stream its own handle stopped has ended: how long it was open and how much of
    /// it was audible. Streams handed over to the other user aren't reported.
    public var onStreamEnded: (@Sendable (User, MicPressSummary) -> Void)? {
        get { core.streamEnded.get() }
        set { core.streamEnded.set(newValue) }
    }

    /// The capture's events (rebuilds, failover, a dead mic, dropped chunks), from an audio queue.
    public var onCaptureEvent: (@Sendable (MicrophoneCapture.Event) -> Void)? {
        get { core.captureEvents.get() }
        set {
            core.captureEvents.set(newValue)
            core.device.setEventHandler(newValue)
        }
    }

    /// The user picked an input in Settings (nil: the system default). Drops the failover pin.
    public func selectDevice(uid: String?) { core.device.select(deviceUID: uid) }

    /// The built-in mic capture failed over to, until the user picks a mic.
    public var failoverPin: String? { core.device.failoverPin }

    /// The voice loop's view of the shared mic.
    @MainActor
    public final class TurnHandle: TurnMicrophone, TurnMicrophoneReadiness {
        private let core: Core

        fileprivate nonisolated init(core: Core) { self.core = core }

        public func start(format: PCMFormat) throws -> AsyncStream<Data> { try core.start(.turns, format: format) }
        public func stop() { core.stop(.turns) }
        /// The level while the voice loop holds the mic.
        public var level: Float { core.holder == .turns ? core.device.level : 0 }

        /// True once the press's audio is flowing (the start cue waits for it); false if the voice loop doesn't hold
        /// the mic or it didn't start within `timeout`.
        public func waitUntilLive(timeout: TimeInterval) async -> Bool {
            guard core.holder == .turns else { return false }
            let device = core.device
            return await device.waitUntilLive(timeout: timeout)
        }
    }

    /// One user's view of the shared mic, from any thread (always-on voice's).
    public final class Handle: RealtimeMicrophone, @unchecked Sendable {
        private let core: Core
        public let user: User

        fileprivate init(core: Core, user: User) {
            self.core = core
            self.user = user
        }

        public func start(format: PCMFormat) throws -> AsyncStream<Data> { try core.start(user, format: format) }
        public func stop() { core.stop(user) }
        /// The level while this handle holds the mic.
        public var level: Float { core.holder == user ? core.device.level : 0 }
    }

    fileprivate final class Core: @unchecked Sendable {
        let device: any SharedMicrophoneDevice
        let streamEnded = LockedValue<(@Sendable (User, MicPressSummary) -> Void)?>(nil)
        let captureEvents = LockedValue<(@Sendable (MicrophoneCapture.Event) -> Void)?>(nil)
        private let lock = NSLock()
        private var current: User?
        private var meter: StreamMeter?
        let maxBufferedChunks: Int

        init(device: any SharedMicrophoneDevice, maxBufferedChunks: Int) {
            self.device = device
            self.maxBufferedChunks = max(1, maxBufferedChunks)
        }

        var holder: User? { lock.withLock { current } }

        func start(_ user: User, format: PCMFormat) throws -> AsyncStream<Data> {
            // Claimed under the lock together with the start, so two starts can't interleave their claims.
            try lock.withLock {
                let stream = try device.start(format: format)
                current = user
                let meter = StreamMeter(user: user)
                self.meter = meter
                return metered(stream, meter: meter)
            }
        }

        func stop(_ user: User) {
            lock.withLock {
                guard current == user else { return }
                current = nil
                meter?.markStopped()
                meter = nil
                // Between presses a Bluetooth headset stays on its call profile for a moment; always-on lets go at once.
                device.stop(keepWarm: user == .turns)
            }
        }

        /// Passes the chunks through, adding them up; reports the stream once it has ended, if its own user stopped it.
        ///
        /// The buffer here is bounded and its drops are reported as `.overflow`: this pump drains the device's stream as
        /// fast as chunks arrive, so `MicrophoneCapture`'s own bounded buffer never fills and its overflow event could
        /// never fire for a slow reader (a speech session that hasn't caught up).
        private func metered(_ source: AsyncStream<Data>, meter: StreamMeter) -> AsyncStream<Data> {
            AsyncStream(bufferingPolicy: .bufferingOldest(maxBufferedChunks)) { continuation in
                let pump = Task { [streamEnded, captureEvents] in
                    var dropped = 0
                    for await chunk in source {
                        meter.add(chunk)
                        if case .dropped = continuation.yield(chunk) {
                            dropped += 1
                            // The first drop, then every 25th (a second of audio), not one event per chunk.
                            if dropped == 1 || dropped % 25 == 0 { captureEvents.get()?(.overflow(dropped: dropped)) }
                        }
                    }
                    continuation.finish()
                    if let summary = meter.finish() { streamEnded.get()?(meter.user, summary) }
                }
                continuation.onTermination = { _ in pump.cancel() }
            }
        }
    }

    /// One stream's chunk count and loudness, shared by the pump that reads it and the `stop` that ends it.
    fileprivate final class StreamMeter: @unchecked Sendable {
        let user: User
        private let lock = NSLock()
        private var meter: MicPressMeter
        private var stoppedAt: TimeInterval?
        private var reported = false

        init(user: User) {
            self.user = user
            meter = MicPressMeter(startedAt: audioUptime())
        }

        func add(_ pcm: Data) { lock.withLock { meter.add(pcm16: pcm) } }

        func markStopped() { lock.withLock { if stoppedAt == nil { stoppedAt = audioUptime() } } }

        /// The summary once, if the stream was stopped by its user (nil for one handed over or ended by the device).
        func finish() -> MicPressSummary? {
            lock.withLock {
                guard !reported, let stoppedAt else { return nil }
                reported = true
                return meter.summary(endedAt: stoppedAt)
            }
        }
    }
}

/// `MicrophoneCapture` as a `SharedMicrophoneDevice`: one capture per format and engine host, closed and rebuilt when
/// either changes. `host` picks the engine for the next stream: nil gives the capture its own engine; a shared
/// voice-processing host (`DuplexAudioRouter`) makes the capture echo-cancelled against the voice on that host. A
/// failover pin to the built-in mic survives a rebuilt capture until the user picks a mic.
public final class CaptureMicrophoneDevice: SharedMicrophoneDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: MicrophoneCapture?
    /// The host the current capture was asked to use (nil: its own).
    private var captureHost: AudioEngineHost?
    private var deviceUID: String?
    private var carriedFailover: String?
    private let host: @Sendable () -> AudioEngineHost?
    private var eventHandler: (@Sendable (MicrophoneCapture.Event) -> Void)?

    public init(deviceUID: String? = nil, host: @escaping @Sendable () -> AudioEngineHost? = { nil }) {
        self.deviceUID = deviceUID
        self.host = host
    }

    /// Switches the input (nil = the system default) for the open capture and every one made later. A user's choice
    /// also drops a failover pin to the built-in mic (`MicrophoneCapture.selectDevice`).
    public func selectDevice(uid: String?) {
        let open = lock.withLock { () -> MicrophoneCapture? in
            deviceUID = uid
            return capture
        }
        open?.selectDevice(uid: uid)
    }

    /// The input chosen for this device (nil = the system default).
    public var selectedDeviceUID: String? { lock.withLock { deviceUID } }

    public func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let wanted = host()
        let capture = lock.withLock { () -> MicrophoneCapture in
            if let capture = self.capture, capture.options.format == format, captureHost === wanted { return capture }
            if let old = self.capture {
                carriedFailover = old.inputPin.failover
                old.close()
            }
            let options = MicrophoneCapture.Options(format: format, deviceUID: deviceUID, failoverUID: carriedFailover)
            let fresh = MicrophoneCapture(options: options, host: wanted)
            fresh.onEvent = eventHandler
            self.capture = fresh
            captureHost = wanted
            return fresh
        }
        let chunks = try capture.start()
        return AsyncStream { continuation in
            let pump = Task {
                for await chunk in chunks { continuation.yield(chunk.pcm) }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func stop(keepWarm: Bool) {
        lock.withLock { capture }?.stop(holdBluetooth: keepWarm)
    }

    public var level: Float { lock.withLock { capture }?.level ?? 0 }

    public func waitUntilLive(timeout: TimeInterval) async -> Bool {
        guard let capture = lock.withLock({ capture }) else { return false }
        return await capture.waitUntilRunning(timeout: timeout)
    }

    public func select(deviceUID uid: String?) {
        let capture = lock.withLock { () -> MicrophoneCapture? in
            deviceUID = uid
            carriedFailover = nil
            return self.capture
        }
        capture?.selectDevice(uid: uid)
    }

    public var failoverPin: String? {
        let (capture, carried) = lock.withLock { (self.capture, carriedFailover) }
        return capture.map { $0.inputPin.failover } ?? carried
    }

    public func setEventHandler(_ handler: (@Sendable (MicrophoneCapture.Event) -> Void)?) {
        let capture = lock.withLock { () -> MicrophoneCapture? in
            eventHandler = handler
            return self.capture
        }
        capture?.onEvent = handler
    }

    /// Closes the capture now (a Bluetooth hold included), e.g. before switching engines.
    public func close() {
        let capture = lock.withLock { () -> MicrophoneCapture? in
            defer {
                if let old = self.capture { carriedFailover = old.inputPin.failover }
                self.capture = nil
                captureHost = nil
            }
            return self.capture
        }
        capture?.close()
    }
}
