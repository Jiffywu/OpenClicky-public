import Foundation

/// A microphone for always-on mode: PCM16 mono chunks in the format asked for.
public protocol RealtimeMicrophone: Sendable {
    func start(format: PCMFormat) throws -> AsyncStream<Data>
    func stop()
}

/// The app's microphone (`MicrophoneCapture`). Needs microphone permission.
public final class CaptureRealtimeMicrophone: RealtimeMicrophone, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: MicrophoneCapture?
    private let host: AudioEngineHost?
    private let deviceUID: String?

    /// Pass the speech player's host so voice processing (echo cancellation) hears the voice.
    public init(host: AudioEngineHost? = nil, deviceUID: String? = nil) {
        self.host = host
        self.deviceUID = deviceUID
    }

    public func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let capture = MicrophoneCapture(options: .init(format: format, chunkDuration: 0.04, deviceUID: deviceUID), host: host)
        lock.withLock { self.capture = capture }
        let chunks = try capture.start()
        return AsyncStream { continuation in
            let task = Task {
                for await chunk in chunks { continuation.yield(chunk.pcm) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        let capture = lock.withLock { () -> MicrophoneCapture? in
            defer { self.capture = nil }
            return self.capture
        }
        capture?.stop(holdBluetooth: false)
    }
}

/// Plays a file (or any PCM) as if it came from a microphone, in real time or as fast as possible, then keeps sending
/// silence so the provider's voice activity detection hears the turn end. For `occtl realtime` and tests.
public final class FileRealtimeMicrophone: RealtimeMicrophone, @unchecked Sendable {
    public let pcm: Data
    public let sourceFormat: PCMFormat
    public let chunk: Duration
    public let realTime: Bool
    /// Silence after the audio, so the turn can end and the reply has time to arrive.
    public let trailingSilence: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(pcm: Data, format: PCMFormat, chunk: Duration = .milliseconds(100), realTime: Bool = true,
                trailingSilence: Duration = .seconds(2)) {
        self.pcm = pcm
        self.sourceFormat = format
        self.chunk = chunk
        self.realTime = realTime
        self.trailingSilence = trailingSilence
    }

    public func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let audio = format == sourceFormat ? pcm : try PCMConverter.convert(pcm, from: sourceFormat, to: format)
        let bytes = max(2, Int(Double(format.bytesPerSecond) * chunk.realtimeSeconds) / 2 * 2)
        let silenceChunks = Int((trailingSilence.realtimeSeconds / chunk.realtimeSeconds).rounded(.up))
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let realTime = realTime, chunk = chunk
        let task = Task {
            for piece in realtimeAudioChunks(audio, maxBytes: bytes) {
                if Task.isCancelled { break }
                continuation.yield(piece)
                if realTime { try? await Task.sleep(for: chunk) }
            }
            for _ in 0..<max(0, silenceChunks) {
                if Task.isCancelled { break }
                continuation.yield(Data(count: bytes))
                if realTime { try? await Task.sleep(for: chunk) }
            }
            continuation.finish()
        }
        lock.withLock { self.task = task }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func stop() {
        lock.withLock { task }?.cancel()
    }
}

public enum AlwaysOnState: Sendable, Hashable {
    case off
    case starting
    case on
    /// Always-on won't start here (no headphones, no realtime model); the text says why, for the notch.
    case refused(String)
    case failed(String)

    public var isActive: Bool { self == .on || self == .starting }
}

/// How a session on a route that leaks into the mic (speakers) should run, from `Environment.prepareRoute`.
public enum AlwaysOnRoutePlan: Sendable, Hashable {
    /// The mic and the voice share an echo-cancelling engine: speakers are fine.
    case echoCancelled
    /// No echo cancellation: speakers only if the environment allows them.
    case plain
    /// Don't run here; the text says why.
    case refuse(String)
}

/// Why a running always-on session is being swapped for a new one without stopping.
public enum AlwaysOnReplacement: String, Sendable, Hashable {
    /// The provider announced it will close the session (Gemini's goAway).
    case goingAway = "going away"
    /// The voice settings changed; the new session speaks with the new voice.
    case voiceChanged = "voice changed"
}

/// The microphone's current destination: the running conversation, swapped in place when a session is replaced.
final class AlwaysOnMicTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var conversation: RealtimeConversation?
    var current: RealtimeConversation? {
        get { lock.withLock { conversation } }
        set { lock.withLock { conversation = newValue } }
    }
}

public enum AlwaysOnUpdate: Sendable, Hashable {
    case state(AlwaysOnState)
    case conversation(RealtimeConversationUpdate)
    /// The provider dropped the session and a new one is opening.
    case reconnecting
}

/// The always-on toggle the app calls (the voice loop wires triple-tap Control to `toggle()`): opens a realtime
/// session on the realtime-voice slot, streams the microphone into it through the echo gate, plays the replies and
/// runs tools, until `stop()`. Like HeyClicky it refuses to start on speakers unless allowed, ends if output moves to
/// speakers, and opens a new session when the provider ends one.
///
/// Two things swap the session in place, with the mic carrying on: the provider announcing it will close (goAway: the
/// replacement opens at once, resuming the conversation from the provider's handle where there is one, else carrying
/// the recent transcript, and takes over at the next pause or just before the old one closes), and a voice change
/// (`voiceChanged()`: the session is marked stale and replaced at the next pause).
public actor AlwaysOnVoiceController {
    public struct Environment: Sendable {
        public var connect: @Sendable (RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession
        /// The session configuration for an output route (instructions, tools, VAD tuned for the route).
        public var configuration: @Sendable (AudioOutputRoute) -> RealtimeSessionConfiguration
        public var toolbox: RealtimeToolbox?
        public var makeOutput: @Sendable () -> any RealtimeAudioOutput
        public var microphone: any RealtimeMicrophone
        public var outputRoute: @Sendable () -> AudioOutputRoute
        /// HeyClicky only runs always-on with headphones; turn this off to allow speakers with the echo gate.
        public var requireHeadphones: Bool
        /// How many times in a row a dropped session is reopened before giving up.
        public var maxReconnects: Int
        public var echo: RealtimeEchoGate.Settings
        public var maxToolCallsPerTurn: Int
        /// Before a session on a route that leaks into the mic: set up echo cancellation (probe it if needed). With
        /// `.echoCancelled` speakers are allowed even when `requireHeadphones` is on. Nil: no echo cancellation.
        public var prepareRoute: (@Sendable (AudioOutputRoute) async -> AlwaysOnRoutePlan)?
        /// The echo gate for a route, with or without echo cancellation. Nil: `echo` everywhere.
        public var echoSettings: (@Sendable (AudioOutputRoute, Bool) -> RealtimeEchoGate.Settings)?
        /// Undo a `prepareRoute` whose session never started (always-on was turned off while it was being set up).
        public var releaseRoute: (@Sendable () async -> Void)?
        /// After a goAway, how long before the announced close the replacement takes over even if a turn is running.
        public var goAwayMargin: Duration = .milliseconds(1_500)
        /// When the provider gives no time, how long the old session is assumed to have left.
        public var goAwayDefault: Duration = .seconds(10)
        /// How often a session is checked for a pause while a replacement waits.
        public var idlePoll: Duration = .milliseconds(40)
        /// How many recent lines of the conversation a fresh replacement session (no resumption handle) is told.
        public var carriedLines: Int = 12

        public init(connect: @escaping @Sendable (RealtimeSessionConfiguration) async throws -> any RealtimeVoiceSession,
                    configuration: @escaping @Sendable (AudioOutputRoute) -> RealtimeSessionConfiguration,
                    toolbox: RealtimeToolbox? = nil, makeOutput: @escaping @Sendable () -> any RealtimeAudioOutput,
                    microphone: any RealtimeMicrophone, outputRoute: @escaping @Sendable () -> AudioOutputRoute,
                    requireHeadphones: Bool = true, maxReconnects: Int = 2, echo: RealtimeEchoGate.Settings = .init(),
                    maxToolCallsPerTurn: Int = 6) {
            self.connect = connect
            self.configuration = configuration
            self.toolbox = toolbox
            self.makeOutput = makeOutput
            self.microphone = microphone
            self.outputRoute = outputRoute
            self.requireHeadphones = requireHeadphones
            self.maxReconnects = maxReconnects
            self.echo = echo
            self.maxToolCallsPerTurn = maxToolCallsPerTurn
        }

        /// The standard wiring: the realtime-voice slot's client, `instructions` plus the toolbox's tools, VAD tuned to
        /// the route.
        public static func standard(client: any RealtimeVoiceClient, instructions: @escaping @Sendable () -> String,
                                    toolbox: RealtimeToolbox?, voice: String? = nil,
                                    makeOutput: @escaping @Sendable () -> any RealtimeAudioOutput,
                                    microphone: any RealtimeMicrophone,
                                    outputRoute: @escaping @Sendable () -> AudioOutputRoute,
                                    requireHeadphones: Bool = true) -> Environment {
            Environment(connect: { try await client.connect($0) },
                        configuration: { route in
                            RealtimeSessionConfiguration(
                                instructions: instructions(), tools: toolbox?.specs ?? [], voice: voice,
                                turnDetection: .serverVAD(route == .headphones ? .headphones : .speakers),
                                noiseReduction: route == .headphones ? .nearField : .farField, resumable: true)
                        },
                        toolbox: toolbox, makeOutput: makeOutput, microphone: microphone, outputRoute: outputRoute,
                        requireHeadphones: requireHeadphones)
        }

        /// The Mac itself: the microphone and the voice on one voice-processing audio host (so echo cancellation hears
        /// the voice), and the default output device for the route. Nothing opens until `start()`; the microphone then
        /// needs permission.
        public static func live(client: any RealtimeVoiceClient, instructions: @escaping @Sendable () -> String,
                                toolbox: RealtimeToolbox?, voice: String? = nil, requireHeadphones: Bool = true) -> Environment {
            let host = AudioEngineHost(voiceProcessing: true, label: "OpenClicky.alwaysOn")
            return standard(client: client, instructions: instructions, toolbox: toolbox, voice: voice,
                            makeOutput: { SpeechPlayerRealtimeOutput(player: SpeechPlayer(sampleRate: 24_000, host: host)) },
                            microphone: CaptureRealtimeMicrophone(host: host),
                            outputRoute: { AudioOutputRoute.classify(AudioDevices.defaultOutput()) },
                            requireHeadphones: requireHeadphones)
        }
    }

    public nonisolated let updates: AsyncStream<AlwaysOnUpdate>
    private let continuation: AsyncStream<AlwaysOnUpdate>.Continuation
    public nonisolated let environment: Environment
    public private(set) var state: AlwaysOnState = .off
    private var conversation: RealtimeConversation?
    private var runTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var generation = 0
    private var reconnects = 0
    /// The running session's mic and voice share an echo-cancelling engine.
    public private(set) var echoCancelled = false
    /// Text sent while a session was opening (or reopening after a drop); it goes in once the session is on.
    private var pendingTexts: [(text: String, respond: Bool)] = []
    private let micTarget = AlwaysOnMicTarget()
    /// A replacement session is being opened or is waiting for a pause.
    private var replacing: AlwaysOnReplacement?
    /// The old session ended while its replacement was still on its way.
    private var oldEndedDuringReplacement = false
    /// The voice changed since the running session opened; it is replaced at the next pause.
    public private(set) var isStale = false
    /// Sessions swapped in place (goAway or a voice change), for tests and logs.
    public private(set) var replacements: [AlwaysOnReplacement] = []

    public init(environment: Environment) {
        self.environment = environment
        (updates, continuation) = AsyncStream<AlwaysOnUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    /// Turns always-on on when it is off (or refused/failed), off when it is on or starting. Returns the new state.
    @discardableResult
    public func toggle() async -> AlwaysOnState {
        if state.isActive {
            await stop()
            return state
        }
        return await start()
    }

    @discardableResult
    public func start() async -> AlwaysOnState {
        guard !state.isActive else { return state }
        let route = environment.outputRoute()
        echoCancelled = false
        if route.leaksIntoMicrophone, let prepare = environment.prepareRoute {
            // Setting up (and maybe probing) echo cancellation takes a moment: show it starting.
            set(.starting)
            generation += 1
            let generation = generation
            let plan = await prepare(route)
            guard generation == self.generation, state == .starting else {
                // Turned off meanwhile (and not started again): give the engines back.
                if !state.isActive { await environment.releaseRoute?() }
                return state
            }
            switch plan {
            case .echoCancelled: echoCancelled = true
            case .plain: break
            case .refuse(let why):
                set(.refused(why))
                return state
            }
        }
        if environment.requireHeadphones, route != .headphones, !echoCancelled {
            set(.refused(Self.needsHeadphones))
            return state
        }
        reconnects = 0
        set(.starting)
        return await open(route: route)
    }

    static let needsHeadphones = "Always-on listening needs headphones, so OpenClicky doesn't hear itself. Plug some in and try again."

    /// Ends always-on: closes the session and stops the mic and the voice.
    public func stop() async {
        generation += 1
        await tearDown()
        set(.off)
    }

    /// Escape while always-on is talking: stop the reply and any running tools, keep listening.
    public func interrupt() async {
        await conversation?.interrupt()
    }

    /// A typed message (the text panel) or an `[App]` note for the running conversation. While a session is still
    /// opening (or reopening after a drop) it waits and goes in once the session is on. False when always-on is off or
    /// ending (the text is dropped).
    @discardableResult
    public func addText(_ text: String, respond: Bool) async -> Bool {
        if state == .starting {
            pendingTexts.append((text, respond))
            return true
        }
        guard state == .on, let conversation else { return false }
        await conversation.addText(text, respond: respond)
        return true
    }

    /// The output device changed. Ends always-on if it moved to speakers and headphones are required; otherwise the
    /// running conversation's echo gate switches to the new route (on with speakers, off with headphones).
    public func outputRouteChanged() async {
        guard state.isActive else { return }
        let route = environment.outputRoute()
        if route.leaksIntoMicrophone, !echoCancelled, let prepare = environment.prepareRoute {
            // Moved to speakers: echo cancellation may make that fine, on a fresh session over the shared engine.
            generation += 1
            await tearDown()
            set(.starting)
            let generation = generation
            let plan = await prepare(route)
            guard generation == self.generation, state == .starting else {
                if !state.isActive { await environment.releaseRoute?() }
                return
            }
            if plan == .echoCancelled || !environment.requireHeadphones {
                echoCancelled = plan == .echoCancelled
                reconnects = 0
                _ = await open(route: route)
            } else {
                set(.refused("Always-on stopped because sound moved to the speakers."))
            }
            return
        }
        if environment.requireHeadphones, route != .headphones, !echoCancelled {
            generation += 1
            await tearDown()
            set(.refused("Always-on stopped because sound moved to the speakers."))
            return
        }
        await conversation?.outputRouteChanged(to: route, echo: environment.echoSettings?(route, echoCancelled))
    }

    /// The echo-cancelling engine came up deaf or died under the session. The session's mic is on that engine either
    /// way, so it can't just carry on: on speakers it stops unless speakers are allowed without echo cancellation; with
    /// headphones (the route moved there after the session started on speakers) it reopens on the plain engines.
    public func echoCancellationLost(_ reason: String) async {
        guard state.isActive, echoCancelled else { return }
        echoCancelled = false
        let route = environment.outputRoute()
        generation += 1
        await tearDown()
        if route.leaksIntoMicrophone, environment.requireHeadphones {
            set(.refused("Echo cancellation stopped working (\(reason)), so always-on stopped. Use headphones to keep talking."))
            return
        }
        // Headphones, or speakers allowed: carry on over the plain engines (with the stricter gate on speakers).
        set(.starting)
        reconnects = 0
        _ = await open(route: route)
    }

    /// The current conversation, for captions and tests.
    public var currentConversation: RealtimeConversation? { conversation }

    /// The voice settings changed. A running session is marked stale and replaced, with the conversation carried
    /// over, at the next pause (it never cuts off a reply); one still opening is replaced once it is on.
    public func voiceChanged() async {
        guard state.isActive else { return }
        isStale = true
        guard state == .on, replacing == nil else { return }
        // Waits for a pause in the background; the caller (a Settings change) doesn't wait for it.
        Task { await self.replaceSession(.voiceChanged, timeLeft: nil) }
    }

    // MARK: - Internals

    private func open(route: AudioOutputRoute) async -> AlwaysOnState {
        generation += 1
        let generation = generation
        // The session opens with the settings as they are now; a change from here on marks it stale again.
        isStale = false
        let session: any RealtimeVoiceSession
        do {
            session = try await environment.connect(environment.configuration(route))
        } catch {
            guard generation == self.generation else { return state }
            set(.failed("Couldn't start always-on voice: \(error)"))
            return state
        }
        guard generation == self.generation else {
            await session.close()
            return state
        }
        let conversation = makeConversation(session, route: route)
        self.conversation = conversation
        do {
            try startMicrophone(format: session.inputFormat)
        } catch {
            await conversation.close()
            self.conversation = nil
            set(.failed("The microphone didn't start: \(error)"))
            return state
        }
        micTarget.current = conversation
        await run(conversation, generation: generation)
        set(.on)
        let waiting = pendingTexts
        pendingTexts = []
        for item in waiting { await conversation.addText(item.text, respond: item.respond) }
        // The voice changed while this session was opening: replace it at its first pause.
        if isStale, replacing == nil { Task { await self.replaceSession(.voiceChanged, timeLeft: nil) } }
        return state
    }

    /// Starts the microphone in `format`, feeding whatever conversation `micTarget` points at.
    private func startMicrophone(format: PCMFormat) throws {
        let chunks = try environment.microphone.start(format: format)
        let target = micTarget
        micTask = Task {
            for await pcm in chunks { await target.current?.feedMicrophone(pcm) }
        }
    }

    private func makeConversation(_ session: any RealtimeVoiceSession, route: AudioOutputRoute) -> RealtimeConversation {
        let output = environment.makeOutput()
        let dispatcher = environment.toolbox.map { RealtimeToolDispatcher(tools: $0.tools, maxCallsPerTurn: environment.maxToolCallsPerTurn) }
        let echo = environment.echoSettings?(route, echoCancelled) ?? environment.echo
        return RealtimeConversation(session: session, output: output, dispatcher: dispatcher, options: .init(route: route, echo: echo))
    }

    /// Relays `conversation`'s updates and runs it; its end counts only while `generation` is current.
    private func run(_ conversation: RealtimeConversation, generation: Int) async {
        let continuation = continuation
        relayTask?.cancel()
        relayTask = Task {
            for await update in conversation.updates { continuation.yield(.conversation(update)) }
        }
        // Weak: the conversation keeps this handler, so a strong capture would keep every conversation alive.
        await conversation.setGoingAwayHandler { [weak self, weak conversation] timeLeft in
            guard let conversation else { return }
            await self?.providerGoingAway(conversation, timeLeft: timeLeft)
        }
        runTask = Task { [weak self] in
            let error = await conversation.run()
            await self?.sessionEnded(generation: generation, error: error)
        }
    }

    // MARK: - Replacing a session in place

    private func providerGoingAway(_ conversation: RealtimeConversation, timeLeft: Duration?) async {
        guard conversation === self.conversation, state == .on else { return }
        if replacing == .voiceChanged { return }  // already on its way to a new session
        await replaceSession(.goingAway, timeLeft: timeLeft)
    }

    /// Opens a session to take over from the running one and swaps it in at a pause. For goAway the new session opens
    /// at once (resuming from the provider's handle when there is one, else told the recent conversation) and takes
    /// over at the next pause, or `goAwayMargin` before the announced close. For a voice change it waits for a pause
    /// first and opens the session then, with the current settings, and takes over at the pause after it is open. What
    /// was said on the old session after the new one was set up is passed on when it takes over.
    private func replaceSession(_ reason: AlwaysOnReplacement, timeLeft: Duration?) async {
        guard state == .on, let old = conversation, replacing == nil else { return }
        replacing = reason
        oldEndedDuringReplacement = false
        let startedGeneration = generation
        let deadline: ContinuousClock.Instant? = reason == .goingAway
            ? ContinuousClock.now + max(.zero, (timeLeft ?? environment.goAwayDefault) - environment.goAwayMargin) : nil
        func stillCurrent() -> Bool { startedGeneration == generation && (state == .on || oldEndedDuringReplacement) }
        if reason == .voiceChanged {
            _ = await waitForPause(old, until: nil, generation: startedGeneration)
            guard stillCurrent(), conversation === old else { return finishReplacing() }
        }
        let route = environment.outputRoute()
        var configuration = environment.configuration(route)
        // Everything said on the old session after this point reaches the new one when it takes over.
        let snapshot = await old.transcriptSnapshot()
        let handle = reason == .goingAway ? await old.resumptionHandle : nil
        if let handle {
            configuration.resumptionHandle = handle
        } else {
            configuration.instructions += Self.carryOver(snapshot.lines, limit: environment.carriedLines)
        }
        // The new session opens with the settings as they are now; a change from here on marks it stale again.
        let wasStale = isStale
        isStale = false
        let session: any RealtimeVoiceSession
        do {
            session = try await environment.connect(configuration)
        } catch {
            if wasStale { isStale = true }
            continuation.yield(.conversation(.warning("Couldn't open a new session (\(reason.rawValue)): \(error)")))
            let ended = oldEndedDuringReplacement
            finishReplacing()
            // The old session is already gone: fall back to the usual reconnect.
            if ended, startedGeneration == generation { await reconnectAfterDrop(error: error) }
            return
        }
        guard stillCurrent() else {
            await session.close()
            return finishReplacing()
        }
        // Take over at a pause. Connecting takes a moment, and the user may have started talking (or a reply begun)
        // meanwhile: that turn finishes on the old session first (for goAway, until the deadline at the latest).
        if !oldEndedDuringReplacement {
            _ = await waitForPause(old, until: reason == .goingAway ? deadline : nil, generation: startedGeneration)
            guard stillCurrent() else {
                await session.close()
                return finishReplacing()
            }
        }
        await swap(old, for: session, route: route, reason: reason, resumed: handle != nil, since: snapshot.mark)
        finishReplacing()
        // The voice changed again while this replacement was under way: the session now running has the old voice.
        if isStale, state == .on { Task { await self.replaceSession(.voiceChanged, timeLeft: nil) } }
    }

    private func finishReplacing() {
        replacing = nil
        oldEndedDuringReplacement = false
    }

    /// Waits until `conversation` is between turns (true), it ended, the deadline passed or always-on moved on (false).
    private func waitForPause(_ conversation: RealtimeConversation, until deadline: ContinuousClock.Instant?, generation: Int) async -> Bool {
        while generation == self.generation, state == .on, !oldEndedDuringReplacement {
            if await conversation.hasEnded { return false }
            if await conversation.isIdle { return true }
            if let deadline, ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: environment.idlePoll)
        }
        return false
    }

    /// The new session takes over: the mic feeds it from the next chunk, its updates are relayed, and the old one is
    /// closed without its end counting as a drop.
    private func swap(_ old: RealtimeConversation, for session: any RealtimeVoiceSession, route: AudioOutputRoute,
                      reason: AlwaysOnReplacement, resumed: Bool, since mark: RealtimeConversation.TranscriptMark) async {
        generation += 1
        let generation = generation
        let fresh = makeConversation(session, route: route)
        conversation = fresh
        if session.inputFormat != old.session.inputFormat {
            // Another provider or model hears at a different sample rate: restart the mic in the new session's format.
            micTarget.current = nil
            environment.microphone.stop()
            micTask?.cancel()
            do {
                try startMicrophone(format: session.inputFormat)
            } catch {
                await old.close()
                await session.close()
                conversation = nil
                set(.failed("The microphone didn't start: \(error)"))
                return
            }
        }
        micTarget.current = fresh
        // The notch follows the new session from a clean start, not the old one's last state (a reply, a tool label,
        // or its end while the replacement was opening).
        relayTask?.cancel()
        relayTask = nil
        continuation.yield(.conversation(.state(.listening)))
        continuation.yield(.conversation(.status(nil)))
        await run(fresh, generation: generation)
        await old.close()
        replacements.append(reason)
        if state != .on { set(.on) }
        let how = resumed ? "resumed from the provider's handle" : "with the recent conversation carried over"
        continuation.yield(.conversation(.warning("Continued in a new session (\(reason.rawValue)), \(how).")))
        if let note = Self.catchUp(await old.transcript(since: mark), limit: environment.carriedLines) {
            await fresh.addText(note, respond: false)
        }
        let waiting = pendingTexts
        pendingTexts = []
        for item in waiting { await fresh.addText(item.text, respond: item.respond) }
    }

    /// The recent conversation, for a replacement session that can't resume the old one.
    static func carryOver(_ lines: [RealtimeTranscriptLine], limit: Int) -> String {
        guard let text = spokenLines(lines, limit: limit) else { return "" }
        return "\n\n# The conversation so far\nThis is a new connection for the same conversation (the previous one was closed). "
            + "The last things said were:\n\(text)\nCarry on from there; don't greet the user again or repeat yourself."
    }

    /// What was said on the old session after the new one was set up, as a note for the new one (nil: nothing).
    static func catchUp(_ lines: [RealtimeTranscriptLine], limit: Int) -> String? {
        guard let text = spokenLines(lines, limit: limit) else { return nil }
        return "[App] The conversation carried on while this connection was opening:\n\(text)\n"
            + "Carry on from there without repeating any of it."
    }

    private static func spokenLines(_ lines: [RealtimeTranscriptLine], limit: Int) -> String? {
        let spoken = lines.filter { $0.role != .tool }.suffix(max(0, limit))
        guard !spoken.isEmpty else { return nil }
        return spoken.map { line -> String in
            let words = line.text.count > 400 ? String(line.text.prefix(400)) + "…" : line.text
            return "\(line.role == .user ? "User" : "You"): \(words)"
        }.joined(separator: "\n")
    }

    private func sessionEnded(generation: Int, error: Error?) async {
        guard generation == self.generation, state == .on else { return }
        if replacing == .goingAway {
            // Its replacement is on the way: it takes over as soon as it is open (the mic keeps running).
            oldEndedDuringReplacement = true
            return
        }
        await reconnectAfterDrop(error: error)
    }

    private func reconnectAfterDrop(error: Error?) async {
        environment.microphone.stop()
        micTask?.cancel()
        micTarget.current = nil
        conversation = nil
        if reconnects < environment.maxReconnects {
            reconnects += 1
            continuation.yield(.reconnecting)
            set(.starting)
            _ = await open(route: environment.outputRoute())
        } else {
            set(.failed("Always-on voice disconnected: \(error.map { String(describing: $0) } ?? "the session ended")."))
        }
    }

    private func tearDown() async {
        environment.microphone.stop()
        micTask?.cancel()
        micTask = nil
        micTarget.current = nil
        isStale = false
        let conversation = conversation
        self.conversation = nil
        await conversation?.close()
        runTask = nil
        relayTask = nil
    }

    private func set(_ new: AlwaysOnState) {
        // Text waiting for a session that won't come is dropped.
        if !new.isActive { pendingTexts.removeAll() }
        guard state != new else { return }
        state = new
        continuation.yield(.state(new))
    }
}
