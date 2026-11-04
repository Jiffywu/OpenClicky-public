import Foundation

// Echo cancellation for the voice loop (docs/audio-robustness.md). With the voice coming out of the speakers, the mic
// hears it, so always-on voice would answer itself. macOS's voice-processing I/O unit cancels the voice from the mic
// when the mic and the voice share one AVAudioEngine (`AudioEngineHost(voiceProcessing: true)`), but it doesn't work on
// every device combination: on some the voice-processing mic comes up deaf (no audio, or only digital zeros). So the
// shared engine is adopted only after a short probe proves the mic still hears through it, and the verdict is cached
// per device combination (topology); a combination that came up deaf isn't probed again for a while.

/// Whether the voice loop may use echo cancellation (Settings > Voice > Microphone).
public enum EchoCancellationMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Use it for always-on voice on speakers when the probe says it works here.
    case automatic
    /// Never: always-on voice needs headphones.
    case off
}

/// The input and output devices in use: what an echo-cancellation verdict is cached under.
public struct AudioTopology: Sendable, Hashable, Codable {
    public var inputUID: String?
    public var inputTransport: String?
    public var outputUID: String?
    public var outputTransport: String?

    public init(inputUID: String?, inputTransport: String? = nil, outputUID: String?, outputTransport: String? = nil) {
        self.inputUID = inputUID
        self.inputTransport = inputTransport
        self.outputUID = outputUID
        self.outputTransport = outputTransport
    }

    /// The cache key: both device UIDs ("default" when unknown).
    public var key: String { "in=\(inputUID ?? "default")|out=\(outputUID ?? "default")" }

    /// The devices now: the chosen input (or the default input) and the default output.
    public static func current(inputUID: String? = nil) -> AudioTopology {
        let input = inputUID.flatMap { AudioDevices.device(uid: $0) } ?? AudioDevices.defaultInput()
        let output = AudioDevices.defaultOutput()
        return AudioTopology(inputUID: input?.uid, inputTransport: input.map { "\($0.transport)" },
                             outputUID: output?.uid, outputTransport: output.map { "\($0.transport)" })
    }
}

/// What a probe (or a session) found out about echo cancellation on one topology.
public enum EchoVerdict: Sendable, Hashable, Codable {
    /// The echo-cancelled mic heard the room: use it.
    case promoted(at: Date)
    /// It came up deaf or died; don't try again until `EchoVerdictCache.zombieRetry` has passed.
    case zombie(reason: String, at: Date)

    public var isPromoted: Bool { if case .promoted = self { true } else { false } }

    public var at: Date {
        switch self {
        case .promoted(let at), .zombie(_, let at): at
        }
    }
}

/// Verdicts per topology, saved as JSON (`echo-cancellation.json` in Application Support/OpenClicky).
public struct EchoVerdictCache: Sendable, Hashable {
    public var url: URL?
    public private(set) var verdicts: [String: EchoVerdict]
    /// A zombie verdict older than this is probed again (drivers and OS updates fix things).
    public var zombieRetry: TimeInterval

    public init(url: URL? = nil, verdicts: [String: EchoVerdict] = [:], zombieRetry: TimeInterval = 7 * 24 * 3600) {
        self.url = url
        self.verdicts = verdicts
        self.zombieRetry = zombieRetry
    }

    public static var defaultURL: URL {
        OpenClickyConfig.defaultURL.deletingLastPathComponent().appendingPathComponent("echo-cancellation.json")
    }

    /// The cache at `url`, empty when the file is missing or unreadable.
    public static func load(from url: URL = defaultURL) -> EchoVerdictCache {
        var cache = EchoVerdictCache(url: url)
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(File.self, from: data) { cache.verdicts = file.verdicts }
        }
        return cache
    }

    /// The verdict that still counts for `topology` at `now` (a stale zombie doesn't).
    public func verdict(for topology: AudioTopology, now: Date = Date()) -> EchoVerdict? {
        guard let verdict = verdicts[topology.key] else { return nil }
        if case .zombie(_, let at) = verdict, now.timeIntervalSince(at) > zombieRetry { return nil }
        return verdict
    }

    public mutating func record(_ verdict: EchoVerdict, for topology: AudioTopology) {
        verdicts[topology.key] = verdict
        try? save()
    }

    public mutating func forget(_ topology: AudioTopology) {
        verdicts[topology.key] = nil
        try? save()
    }

    public func save() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(verdicts: verdicts)).write(to: url, options: .atomic)
    }

    private struct File: Codable {
        var version = 1
        var verdicts: [String: EchoVerdict]
    }
}

/// What a probe saw.
public enum EchoProbeResult: Sendable, Hashable {
    /// Audio arrived and some of it was above digital silence.
    case working(chunks: Int, audible: Int)
    /// The voice-processing mic came up deaf.
    case deaf(MicHealthMonitor.Problem)
    /// The engine didn't start.
    case failed(String)
    /// The probe couldn't run (no microphone access): nothing is learned about the devices, so nothing is cached.
    case unavailable(String)

    public var isWorking: Bool { if case .working = self { true } else { false } }

    /// Whether the result says something about the devices (worth caching).
    public var isVerdict: Bool { if case .unavailable = self { false } else { true } }

    /// The verdict to cache.
    public func verdict(at date: Date) -> EchoVerdict {
        switch self {
        case .working: .promoted(at: date)
        case .deaf(let problem): .zombie(reason: problem == .noAudio ? "deaf: no audio" : "deaf: only digital silence", at: date)
        case .failed(let message): .zombie(reason: "engine failed: \(message)", at: date)
        case .unavailable(let why): .zombie(reason: "not probed: \(why)", at: date)
        }
    }

    /// The deaf check over what a probe window delivered.
    public static func check(chunks: Int, audibleChunks: Int) -> EchoProbeResult {
        if chunks == 0 { return .deaf(.noAudio) }
        if audibleChunks == 0 { return .deaf(.allZeros) }
        return .working(chunks: chunks, audible: audibleChunks)
    }
}

/// Decides, per always-on session, whether to use echo cancellation: not needed with headphones, off by setting, a
/// cached verdict when there is one, otherwise a probe, at most `probeBudget` times per app run.
public struct EchoCancellationPlanner: Sendable, Hashable {
    public enum Plan: Sendable, Hashable {
        /// Headphones: no echo to cancel.
        case notNeeded
        /// The setting is off.
        case disabled
        /// Cached as working on this topology.
        case useCached
        /// Cached as deaf on this topology.
        case cachedZombie(String)
        /// Nothing cached: run the probe.
        case probe
        /// Probed too often this run; treat as unavailable.
        case budgetExhausted
    }

    public var probeBudget: Int
    public private(set) var probesThisRun = 0

    public init(probeBudget: Int = 3) { self.probeBudget = probeBudget }

    public func plan(route: AudioOutputRoute, mode: EchoCancellationMode, cached: EchoVerdict?) -> Plan {
        guard route.leaksIntoMicrophone else { return .notNeeded }
        guard mode == .automatic else { return .disabled }
        switch cached {
        case .promoted?: return .useCached
        case .zombie(let reason, _)?: return .cachedZombie(reason)
        case nil: return probesThisRun < probeBudget ? .probe : .budgetExhausted
        }
    }

    public mutating func noteProbe() { probesThisRun += 1 }
}

/// Runs the deaf check on an engine host: opens a voice-processing capture on it for `window` seconds and counts what
/// arrives. The real one needs microphone permission.
public protocol EchoProbing: Sendable {
    func probe(host: AudioEngineHost, inputUID: String?) async -> EchoProbeResult
}

/// The probe on the real microphone: a `MicrophoneCapture` on the shared voice-processing host.
public struct VoiceProcessingProbe: EchoProbing {
    public var window: TimeInterval

    public init(window: TimeInterval = 0.8) { self.window = window }

    public func probe(host: AudioEngineHost, inputUID: String?) async -> EchoProbeResult {
        guard MicrophoneCapture.authorization == .authorized else { return .unavailable("microphone access isn't granted") }
        var health = MicHealthMonitor.Policy()
        // The probe judges the window itself; the capture mustn't rebuild under it.
        health.silentWindow = window * 10
        let capture = MicrophoneCapture(options: .init(format: .speech16k, chunkDuration: 0.04, deviceUID: inputUID, bluetoothHold: 0,
                                                       health: health), host: host)
        let chunks: AsyncStream<MicrophoneCapture.Chunk>
        do {
            chunks = try capture.start()
        } catch {
            return .failed((error as? AudioIOError)?.description ?? "\(error)")
        }
        let counter = LockedValue<(chunks: Int, audible: Int)>((0, 0))
        let threshold = MicHealthMonitor.Policy().silenceThreshold
        let reader = Task {
            for await chunk in chunks {
                counter.mutate { $0.chunks += 1; if chunk.level.peak > threshold { $0.audible += 1 } }
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
        capture.close()
        reader.cancel()
        let seen = counter.get()
        return EchoProbeResult.check(chunks: seen.chunks, audibleChunks: seen.audible)
    }
}

/// A probe that answers from a script, for tests and `occtl soundcheck echo`.
public final class ScriptedEchoProbe: EchoProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [EchoProbeResult]
    private var count = 0

    public init(_ results: [EchoProbeResult]) { self.results = results }

    public var probes: Int { lock.withLock { count } }

    public func probe(host: AudioEngineHost, inputUID: String?) async -> EchoProbeResult {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : (results.first ?? .failed("no scripted result"))
        }
    }
}

/// The engines the voice loop's mic and voice use. Normally plain: the mic and the voice each on their own engine.
/// For an always-on session on speakers it switches to echo-cancelled: the mic and a second speech player on one shared
/// voice-processing engine, after the planner and the probe agree. If that engine comes up deaf or dies during the
/// session, it is demoted (cached as a zombie for the topology) and the session is told to stop or move to plain.
///
/// Hand `captureHost` to `CaptureMicrophoneDevice` (as its host provider) and use `player` for always-on's output.
public final class DuplexAudioRouter: @unchecked Sendable {
    public enum Mode: String, Sendable, Hashable { case plain, echoCancelled = "echo_cancelled" }

    /// What `prepare` decided, for logs and the notch.
    public struct Decision: Sendable, Hashable {
        public var mode: Mode
        public var plan: EchoCancellationPlanner.Plan
        public var topology: AudioTopology
        public var probe: EchoProbeResult?

        public var summary: String {
            var line = "\(mode.rawValue) (\(plan))"
            if let probe { line += ", probe: \(probe)" }
            return line + ", topology \(topology.key)"
        }
    }

    private let lock = NSLock()
    private var mode: Mode = .plain
    private var cache: EchoVerdictCache
    private var planner: EchoCancellationPlanner
    private var promotedAt: TimeInterval?
    private var topologyInUse: AudioTopology?
    private var host: AudioEngineHost?
    private var duplexPlayer: SpeechPlayer?
    private let prober: any EchoProbing
    private let topology: @Sendable (String?) -> AudioTopology
    private let makeHost: @Sendable () -> AudioEngineHost
    private let now: @Sendable () -> TimeInterval
    /// Seconds after promotion in which a rebuilding mic counts as deaf (demote at once, don't wait for the ladder).
    public var deafGrace: TimeInterval = 4

    public init(cache: EchoVerdictCache = .load(), planner: EchoCancellationPlanner = EchoCancellationPlanner(),
                prober: any EchoProbing = VoiceProcessingProbe(),
                topology: @escaping @Sendable (String?) -> AudioTopology = { AudioTopology.current(inputUID: $0) },
                makeHost: @escaping @Sendable () -> AudioEngineHost = { AudioEngineHost(voiceProcessing: true, label: "OpenClicky.duplex") },
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.cache = cache
        self.planner = planner
        self.prober = prober
        self.topology = topology
        self.makeHost = makeHost
        self.now = now
    }

    public var currentMode: Mode { lock.withLock { mode } }

    /// The engine the mic should capture on now: the shared voice-processing host while echo-cancelled, else nil (the
    /// mic's own engine).
    public var captureHost: AudioEngineHost? { lock.withLock { mode == .echoCancelled ? host : nil } }

    /// The speech player on the shared host while echo-cancelled (nil: use the plain player).
    public var player: SpeechPlayer? { lock.withLock { mode == .echoCancelled ? duplexPlayer : nil } }

    public var verdicts: EchoVerdictCache { lock.withLock { cache } }

    /// Before an always-on session on `route`: decide, probing if needed, and switch modes. Echo-cancelled only when the
    /// route leaks into the mic and the verdict for this topology (cached or just probed) is good.
    public func prepare(route: AudioOutputRoute, setting: EchoCancellationMode, inputUID: String? = nil) async -> Decision {
        let topology = topology(inputUID)
        let plan = lock.withLock { planner.plan(route: route, mode: setting, cached: cache.verdict(for: topology)) }
        switch plan {
        case .useCached:
            lock.withLock { _ = promote(topology) }
            return Decision(mode: .echoCancelled, plan: plan, topology: topology, probe: nil)
        case .probe:
            let probeHost = lock.withLock { () -> AudioEngineHost in
                planner.noteProbe()
                if host == nil { host = makeHost() }
                return host!
            }
            let result = await prober.probe(host: probeHost, inputUID: inputUID)
            let mode: Mode = lock.withLock {
                if result.isVerdict { cache.record(result.verdict(at: Date()), for: topology) }
                if result.isWorking {
                    promote(topology)
                    return .echoCancelled
                }
                demoteLocked()
                return .plain
            }
            return Decision(mode: mode, plan: plan, topology: topology, probe: result)
        case .notNeeded, .disabled, .cachedZombie, .budgetExhausted:
            lock.withLock { demoteLocked() }
            return Decision(mode: .plain, plan: plan, topology: topology, probe: nil)
        }
    }

    /// A mic event during an echo-cancelled session. True when it demoted the engine (cached as a zombie): the session
    /// must move off it (always-on on speakers stops).
    @discardableResult
    public func captureEvent(_ event: MicrophoneCapture.Event) -> Bool {
        lock.withLock {
            guard mode == .echoCancelled, let topology = topologyInUse else { return false }
            let reason: String?
            switch event {
            case .rebuilding(let problem):
                let fresh = promotedAt.map { now() - $0 < deafGrace } ?? false
                reason = fresh ? (problem == .noAudio ? "deaf at start: no audio" : "deaf at start: only digital silence") : nil
            case .irrecoverable(let problem):
                reason = problem == .noAudio ? "died: no audio" : "died: only digital silence"
            case .failed(let message):
                reason = "engine failed: \(message)"
            default:
                reason = nil
            }
            guard let reason else { return false }
            cache.record(.zombie(reason: reason, at: Date()), for: topology)
            demoteLocked()
            return true
        }
    }

    /// The session ended: back to the plain engines (the shared one is released once nothing uses it).
    public func release() {
        lock.withLock { demoteLocked() }
    }

    /// Forget the verdict for the devices now (Settings' "Test echo cancellation again").
    public func forgetVerdict(inputUID: String? = nil) {
        let topology = topology(inputUID)
        lock.withLock { cache.forget(topology) }
    }

    @discardableResult
    private func promote(_ topology: AudioTopology) -> AudioEngineHost {
        let host = self.host ?? makeHost()
        self.host = host
        if duplexPlayer == nil { duplexPlayer = SpeechPlayer(sampleRate: 24_000, host: host) }
        mode = .echoCancelled
        topologyInUse = topology
        promotedAt = now()
        return host
    }

    private func demoteLocked() {
        mode = .plain
        topologyInUse = nil
        promotedAt = nil
    }
}

extension RealtimeEchoGate.Settings {
    /// Speakers with the voice-processing engine cancelling the voice. The residual echo sits 22-28 dB under the plain
    /// echo, so the gate lets the user in sooner, with a short ring-out. Chosen with `EchoGateTuner` over recorded
    /// replies and questions in modelled rooms: no false barge-in, no miss down to a -34 dBFS voice, worst 440 ms
    /// (docs/evidence/feat-audio-robustness/echo-gate-tuning.txt). A person still has to confirm it in a real room.
    public static let speakersEchoCancelled = RealtimeEchoGate.Settings(
        speechLevelDB: -45, bargeInLevelDB: -36, bargeInSpeech: 0.2, bargeInWindow: 0.6, settleWindow: 0.3,
        minimumTurnSpeech: 0.15, prefix: 0.3)

    /// Speakers with no echo cancellation: the mic hears the voice nearly as loud as the user, so barging in takes a
    /// louder burst and the ring-out is longer. Safe in the tuner at normal volume only (no setting is safe with loud
    /// laptop speakers), so always-on refuses this route unless the user allowed speakers anyway.
    public static let speakersRaw = RealtimeEchoGate.Settings(
        speechLevelDB: -45, bargeInLevelDB: -20, bargeInSpeech: 0.24, bargeInWindow: 0.6, settleWindow: 0.7,
        minimumTurnSpeech: 0.2, prefix: 0.3)

    /// The gate for a route, with or without echo cancellation (headphones keep the defaults; the gate is open there).
    public static func tuned(for route: AudioOutputRoute, echoCancelled: Bool) -> RealtimeEchoGate.Settings {
        guard route.leaksIntoMicrophone else { return RealtimeEchoGate.Settings() }
        return echoCancelled ? .speakersEchoCancelled : .speakersRaw
    }
}
