import AudioToolbox
import AVFoundation
import Foundation

/// A part of the audio layer that puts nodes or taps into an engine. Every method is called on the host's queue.
protocol AudioEngineClient: AnyObject {
    /// The client is active and wants the engine running.
    var needsEngine: Bool { get }
    /// The client captures from the input node.
    var needsInput: Bool { get }
    /// Attach nodes / install taps on a freshly built engine (before it starts).
    func attach(to engine: AVAudioEngine) throws
    /// Remove everything from an engine that is being torn down.
    func detach(from engine: AVAudioEngine)
    /// The engine started. `rebuildReason` is set when it was rebuilt underneath a running client (route change,
    /// health rebuild): queued audio and taps from the old engine are gone.
    func engineDidStart(rebuildReason: String?)
    /// The engine could not be brought back; the client should give up its session.
    func engineDidFail(_ message: String)
}

/// Owns one AVAudioEngine and rebuilds it when devices change.
///
/// Capture and playback that share a host share an engine. That matters for echo cancellation: with
/// `voiceProcessing` on, the voice-processing I/O unit can only cancel audio that plays through the same engine, so
/// the microphone stays usable while the voice speaks (barge-in) only if `MicrophoneCapture` and `SpeechPlayer` are
/// given the same host. Without voice processing each part can have its own host, and an idle microphone is released
/// completely.
///
/// The engine is built lazily when a client needs it and stopped when none does. When the system's default devices
/// change or AVAudioEngine reports a configuration change, the engine is rebuilt from scratch and clients re-attach.
public final class AudioEngineHost: @unchecked Sendable {
    public enum Mode: Sendable, Hashable {
        /// Real devices.
        case realtime
        /// AVAudioEngine manual rendering: nothing touches hardware; `renderOffline(frames:)` pulls output. For tests
        /// and for rendering cues to files.
        case offline(sampleRate: Double, channels: Int)
    }

    public enum Event: Sendable, Hashable {
        case started(input: Bool)
        case rebuilt(reason: String)
        case stopped
        case failed(String)
    }

    public let mode: Mode
    public let voiceProcessing: Bool
    let work: AudioWorkQueue
    private let eventHandler = LockedValue<(@Sendable (Event) -> Void)?>(nil)

    /// Called on the host's audio queue when the engine starts, is rebuilt, stops or fails.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { eventHandler.get() }
        set { eventHandler.set(newValue) }
    }

    // Everything below is confined to `work`.
    private(set) var engine: AVAudioEngine?
    private(set) var engineHasInput = false
    /// Input device UID to pin; nil follows the system default input.
    var preferredInputUID: String?
    /// The pin `preferredInputUID` held when the running engine's input was set up.
    private var engineInputUID: String?
    private var clients: [WeakClient] = []
    private var configurationObserver: NSObjectProtocol?
    private var deviceWatcher: AudioDeviceWatcher?
    private var pendingRebuild: (token: Int, reasons: [String])?
    private var rebuildToken = 0
    private var consecutiveFailures = 0
    /// Seconds to let a burst of device notifications settle before rebuilding.
    var rebuildDebounce: TimeInterval = 0.12
    /// Base delay between attempts to bring a lost engine back (the n-th retry waits n times this).
    var retryDelay: TimeInterval = 0.4
    /// Test seam: the next this-many engine builds fail as if the device refused to start.
    var injectedBuildFailures = 0

    public init(voiceProcessing: Bool = false, label: String = "OpenClicky.audio") {
        self.mode = .realtime
        self.voiceProcessing = voiceProcessing
        self.work = AudioWorkQueue(label: label)
        deviceWatcher = AudioDeviceWatcher(queue: work.queue) { [weak self] change in self?.devicesChanged(change) }
    }

    /// A host that renders offline instead of using devices.
    public init(offlineSampleRate sampleRate: Double, channels: Int = 1, label: String = "OpenClicky.audio.offline") {
        self.mode = .offline(sampleRate: sampleRate, channels: channels)
        self.voiceProcessing = false
        self.work = AudioWorkQueue(label: label)
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine?.stop()
    }

    /// Whether the engine currently exists and runs.
    public var isRunning: Bool { work.sync { engine?.isRunning ?? false } }

    // MARK: Clients (on `work`)

    func register(_ client: AudioEngineClient) {
        clients.removeAll { $0.value == nil || $0.value === client }
        clients.append(WeakClient(value: client))
    }

    func unregister(_ client: AudioEngineClient) {
        if let engine { client.detach(from: engine) }
        clients.removeAll { $0.value == nil || $0.value === client }
        releaseIfUnused()
    }

    private var liveClients: [AudioEngineClient] { clients.compactMap(\.value) }

    /// Returns the running engine, building or rebuilding it if needed. `input` asks for an engine with the input
    /// node live (a running engine without input is rebuilt).
    @discardableResult
    func acquire(input: Bool) throws -> AVAudioEngine {
        let verdict = Self.reuse(hasEngine: engine != nil, isRunning: engine?.isRunning ?? false, hasInput: engineHasInput,
                                 inputPin: engineInputUID, preferredPin: preferredInputUID, wantsInput: input)
        if case .reuse = verdict, let engine { return engine }
        guard case .build(let reason) = verdict else { preconditionFailure("reuse without an engine") }
        teardown()
        do {
            return try build(rebuildReason: reason)
        } catch {
            if let reason {
                // Other clients (the voice on a shared host) were using the engine that was just torn down. Once the
                // caller has backed out, bring an engine back for them, or tell them it is gone; otherwise they would
                // wait forever on an engine that no longer exists.
                work.async { [weak self] in
                    guard let self, self.engine == nil, self.liveClients.contains(where: \.needsEngine) else { return }
                    self.attemptBuild(reason: reason)
                }
            }
            throw error
        }
    }

    enum Reuse: Equatable {
        case reuse
        /// Build a new engine; `reason` is nil when there was none, otherwise why the old one can't serve.
        case build(reason: String?)
    }

    /// Whether the current engine can serve a client as it is. A capture also needs the engine's input to be the
    /// microphone chosen now: with a shared echo-cancelling host the engine keeps its input open while the voice
    /// plays, so a choice made since then would otherwise be ignored until something else rebuilt it.
    static func reuse(hasEngine: Bool, isRunning: Bool, hasInput: Bool, inputPin: String?, preferredPin: String?,
                      wantsInput: Bool) -> Reuse {
        guard hasEngine else { return .build(reason: nil) }
        guard isRunning else { return .build(reason: "engine stopped") }
        guard wantsInput else { return .reuse }
        guard hasInput else { return .build(reason: "input needed") }
        return inputPin == preferredPin ? .reuse : .build(reason: "microphone selection changed")
    }

    /// Stops and discards the engine when no client needs it (releases the microphone and output device).
    func releaseIfUnused() {
        guard engine != nil, !liveClients.contains(where: \.needsEngine) else { return }
        teardown()
        onEvent?(.stopped)
    }

    /// Tears the engine down and builds a new one, keeping every client attached.
    func rebuild(reason: String) {
        guard engine != nil else { return }
        teardown()
        attemptBuild(reason: reason)
    }

    private func attemptBuild(reason: String) {
        do {
            try build(rebuildReason: reason)
            consecutiveFailures = 0
            onEvent?(.rebuilt(reason: reason))
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures <= 2 {
                // Devices often settle a moment after a change; try again shortly.
                work.asyncAfter(retryDelay * Double(consecutiveFailures)) { [weak self] in
                    guard let self, self.engine == nil, self.liveClients.contains(where: \.needsEngine) else { return }
                    self.attemptBuild(reason: reason)
                }
            } else {
                consecutiveFailures = 0
                let message = "\(error)"
                // Only clients with an active session have something to give up (a closed mic has nothing to report).
                for client in liveClients where client.needsEngine { client.engineDidFail(message) }
                onEvent?(.failed(message))
            }
        }
    }

    /// Asks for a rebuild soon, folding together bursts of device notifications.
    func scheduleRebuild(reason: String) {
        if var pending = pendingRebuild {
            if !pending.reasons.contains(reason) { pending.reasons.append(reason) }
            pendingRebuild = pending
            return
        }
        rebuildToken += 1
        let token = rebuildToken
        pendingRebuild = (token, [reason])
        work.asyncAfter(rebuildDebounce) { [weak self] in
            guard let self, let pending = self.pendingRebuild, pending.token == token else { return }
            self.pendingRebuild = nil
            self.rebuild(reason: pending.reasons.joined(separator: ", "))
        }
    }

    // MARK: Offline rendering

    /// Offline hosts only: renders the next `frames` of mixed output (any count; long requests render in slices).
    /// Drives any SpeechPlayer on this host.
    public func renderOffline(frames: Int) throws -> AVAudioPCMBuffer {
        try work.sync {
            guard case .offline = mode else { throw AudioIOError.engineStartFailed("renderOffline needs an offline host") }
            let engine = try acquire(input: false)
            let format = engine.manualRenderingFormat
            let sliceCapacity = Int(engine.manualRenderingMaximumFrameCount)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))),
                  let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sliceCapacity)) else {
                throw AudioIOError.invalidAudioData("could not allocate \(frames) frames")
            }
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            var done = 0
            while done < frames {
                let count = min(sliceCapacity, frames - done)
                let status = try engine.renderOffline(AVAudioFrameCount(count), to: slice)
                guard status == .success else { throw AudioIOError.engineStartFailed("offline render status \(status.rawValue)") }
                let source = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
                let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                for (index, buffer) in source.enumerated() where index < destination.count {
                    guard let from = buffer.mData, let to = destination[index].mData else { continue }
                    to.advanced(by: done * bytesPerFrame).copyMemory(from: from, byteCount: count * bytesPerFrame)
                }
                done += count
            }
            output.frameLength = AVAudioFrameCount(frames)
            return output
        }
    }

    // MARK: Building

    @discardableResult
    private func build(rebuildReason: String?) throws -> AVAudioEngine {
        if injectedBuildFailures > 0 {
            injectedBuildFailures -= 1
            throw AudioIOError.engineStartFailed("injected test failure")
        }
        let engine = AVAudioEngine()
        let wantsInput = voiceProcessing || liveClients.contains(where: \.needsInput)
        switch mode {
        case .offline(let sampleRate, let channels):
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
                throw AudioIOError.invalidAudioData("offline format \(sampleRate) Hz × \(channels)")
            }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        case .realtime:
            if wantsInput { try configureInput(of: engine) }
        }
        self.engine = engine
        engineHasInput = wantsInput && mode == .realtime
        engineInputUID = engineHasInput ? preferredInputUID : nil
        do {
            for client in liveClients { try client.attach(to: engine) }
            // Voice processing needs the output path in the graph so it has a reference signal to cancel.
            if voiceProcessing { _ = engine.mainMixerNode }
            engine.prepare()
            try engine.start()
        } catch {
            for client in liveClients { client.detach(from: engine) }
            self.engine = nil
            engineHasInput = false
            engineInputUID = nil
            if let ioError = error as? AudioIOError { throw ioError }
            throw AudioIOError.engineStartFailed((error as NSError).localizedDescription)
        }
        observeConfigurationChanges(of: engine)
        onEvent?(.started(input: engineHasInput))
        for client in liveClients { client.engineDidStart(rebuildReason: rebuildReason) }
        return engine
    }

    private func configureInput(of engine: AVAudioEngine) throws {
        let input = engine.inputNode
        if voiceProcessing {
            // Enabled first: it swaps in the voice-processing I/O unit, which is the one to pin below.
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                throw AudioIOError.voiceProcessingUnavailable((error as NSError).localizedDescription)
            }
            // Voice processing ducks other apps' audio by default; keep that as light as the system allows.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        if let uid = preferredInputUID, let device = AudioDevices.device(uid: uid), device.inputChannels > 0 {
            // Pin the input element of the I/O unit to the chosen device; on failure the system default is used.
            if let unit = input.audioUnit {
                var id = device.id
                _ = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                         &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioIOError.inputFormatInvalid(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        }
    }

    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        engine.stop()
        for client in liveClients { client.detach(from: engine) }
        engine.reset()
        self.engine = nil
        engineHasInput = false
        engineInputUID = nil
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        guard mode == .realtime else { return }
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.work.async {
                guard let current = self.engine, ObjectIdentifier(current) == engineID else { return }
                self.scheduleRebuild(reason: "engine configuration changed")
            }
        }
    }

    private func devicesChanged(_ change: AudioDeviceWatcher.Change) {
        guard engine != nil else { return }
        switch change {
        case .defaultOutput:
            scheduleRebuild(reason: "default output changed")
        case .defaultInput where engineHasInput && preferredInputUID == nil:
            scheduleRebuild(reason: "default input changed")
        case .deviceList where engineHasInput && preferredInputUID.map({ AudioDevices.device(uid: $0) == nil }) == true:
            scheduleRebuild(reason: "pinned input disconnected")
        default:
            break
        }
    }

    private struct WeakClient {
        weak var value: AudioEngineClient?
    }
}
