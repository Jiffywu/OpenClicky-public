import Foundation
import OpenClickyKit

/// `occtl soundcheck …`: the sound-trouble handling from a terminal, headlessly (docs/audio-robustness.md). Nothing here
/// opens the microphone or changes the Mac's volume: `output` and `topology` only read, the rest use scripted devices.
enum SoundcheckCommands {
    static let usage = """
        Usage:
          occtl soundcheck output
              Read the default output's mute switch and volume (never changes them) and say what OpenClicky would do.
          occtl soundcheck mic [--script dead,dead,ok,failover,select,dead,dead,irrecoverable,stall]
              Drive the voice loop's mic-trouble monitor with a scripted microphone: each "dead" or "ok" is a 1.2 s press
              (only digital silence, or speech-level audio) through SharedMicrophone; "stall" is a press nobody reads
              (the shared mic keeps 0.5 s and reports the rest as dropped); the rest are capture events.
          occtl soundcheck muted-turn [--config c.json] [--silence muted|zero|live] [--typed] [--out dir] <words…>
              One whole turn through the real orchestrator and brain with the output muted: nothing is spoken, the lines
              are copied (to an in-memory clipboard, never yours) and the notice offers the fix. --silence live reads
              this Mac's real output instead of pretending.
          occtl soundcheck echo [--probe working|deaf|zeros|failed[,…]] [--route speakers|headphones] [--sessions 2]
              The echo-cancellation decision for always-on with a scripted probe: planner, verdict cache, router.
          occtl soundcheck topology
              The input and output devices now and the cached echo-cancellation verdict for them.
          occtl soundcheck gate-tune --reply a.wav[,b.wav] --user q.wav[,r.wav] [--out table.txt]
              Tune the always-on echo gate offline: replies played into modelled rooms, a user talking over them.
        """

    static let command = OcctlCommand(name: "soundcheck", usage: "soundcheck <output|mic|muted-turn|echo|topology|gate-tune> …  sound-trouble handling, headless (--help)") { args in
        guard let sub = args.first, !["--help", "-h"].contains(sub) else { print(usage); return }
        let options = Options(Array(args.dropFirst()))
        switch sub {
        case "output": await MainActor.run { output() }
        case "mic": try await mic(options)
        case "muted-turn": try await mutedTurn(options)
        case "echo": await echo(options)
        case "topology": topology()
        case "gate-tune": try gateTune(options)
        default: fail(usage)
        }
    }

    struct Options {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        static let valued: Set<String> = ["--script", "--config", "--silence", "--out", "--probe", "--route", "--sessions", "--reply", "--user"]

        init(_ args: [String]) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if Self.valued.contains(arg) {
                    guard index + 1 < args.count else { fail("\(arg) needs a value.") }
                    values[arg] = args[index + 1]
                    index += 2
                } else if arg.hasPrefix("--") {
                    flags.insert(arg)
                    index += 1
                } else {
                    positional.append(arg)
                    index += 1
                }
            }
        }

        func list(_ name: String) -> [String]? {
            values[name].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
    }

    // MARK: output

    @MainActor
    static func output() {
        let output = CoreAudioOutputVolume()
        guard let state = output.read() else { print("No output device."); return }
        print("Default output: \(state.summary)")
        guard let silence = state.silence else {
            print("Audible: replies are spoken as usual.")
            return
        }
        print("Silent (\(silence.rawValue)): a reply would be answered with captions only, copied to the clipboard, and this notice shown:")
        let notice = AudioNotice.unheard(silence, copied: true, volume: state.volume)
        print("  " + notice.summary)
        print("(Nothing was changed. The buttons only act when a person presses them.)")
    }

    // MARK: mic

    static func mic(_ options: Options) async throws {
        let script = options.list("--script") ?? ["dead", "dead", "ok", "failover", "select", "dead", "dead", "irrecoverable", "stall"]
        await MainActor.run {
            let device = SimMicDevice()
            // 50 of the scripted 10 ms chunks: a reader stalled for longer loses audio (the "stall" step).
            let shared = SharedMicrophone(device: device, maxBufferedChunks: 50)
            let monitor = MicTroubleMonitor(microphone: shared, policy: .init(minimumPress: 0.8))
            let clock = Stopwatch()
            monitor.onLog = { print(clock.stamp("log: \($0)")) }
            monitor.onNotice = { print(clock.stamp("NOTICE \($0.summary)")) }
            monitor.start()
            Task { @MainActor in
                do {
                    for step in script {
                        switch step {
                        case "dead", "ok":
                            device.amplitude = step == "ok" ? 3_000 : 0
                            print(clock.stamp("press: hold 1.2 s (\(step == "ok" ? "speech" : "digital silence"))"))
                            let stream = try shared.turns.start(format: .speech16k)
                            let reader = Task { var count = 0; for await _ in stream { count += 1 }; return count }
                            let live = await shared.turns.waitUntilLive(timeout: 1)
                            print(clock.stamp("  mic live: \(live)"))
                            try await Task.sleep(for: .milliseconds(1200))
                            shared.turns.stop()
                            let chunks = await reader.value
                            print(clock.stamp("  release: \(chunks) chunk(s) read"))
                        case "stall":
                            device.amplitude = 3_000
                            print(clock.stamp("press: hold 1.2 s while the speech connection reads nothing"))
                            let stream = try shared.turns.start(format: .speech16k)
                            try await Task.sleep(for: .milliseconds(1200))
                            shared.turns.stop()
                            var kept = 0
                            for await _ in stream { kept += 1 }
                            print(clock.stamp("  release: \(kept) chunk(s) kept for the late reader"))
                        case "failover": device.emit(.failedOver(from: "USB Audio Mic", to: "MacBook Air Microphone"))
                        case "rebuilding": device.emit(.rebuilding(.allZeros))
                        case "irrecoverable": device.emit(.irrecoverable(.noAudio))
                        case "overflow": device.emit(.overflow(dropped: 40))
                        case "select":
                            print(clock.stamp("user picks \"USB Audio Mic\" in Settings (failover pin before: \(shared.failoverPin ?? "none"))"))
                            monitor.microphoneChosen(uid: "usb-audio-mic")
                            print(clock.stamp("  failover pin after: \(shared.failoverPin ?? "none")"))
                        default: print("unknown step \(step)")
                        }
                        try await Task.sleep(for: .milliseconds(150))
                    }
                } catch {
                    print("the script stopped: \(error)")
                }
            }
        }
        // Long enough for every scripted press (1.4 s each) and event.
        try await Task.sleep(for: .seconds(Double(script.count) * 1.6 + 0.5))
        print("done")
    }

    /// A scripted microphone device: 10 ms chunks of digital silence or a speech-level tone while open; it fails over
    /// to the built-in mic when told, and a selection drops the pin, like CaptureMicrophoneDevice.
    final class SimMicDevice: SharedMicrophoneDevice, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<Data>.Continuation?
        private var ticker: Task<Void, Never>?
        private var live = false
        private var handler: (@Sendable (MicrophoneCapture.Event) -> Void)?
        private var pin: String?
        private var _amplitude: Int16 = 0

        var amplitude: Int16 {
            get { lock.withLock { _amplitude } }
            set { lock.withLock { _amplitude = newValue } }
        }

        func start(format: PCMFormat) throws -> AsyncStream<Data> {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            let count = format.sampleRate / 100
            let amplitude = self.amplitude
            let ticker = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                self?.lock.withLock { self?.live = true }
                var phase = 0.0
                while !Task.isCancelled {
                    let samples = (0..<count).map { _ -> Int16 in
                        phase += 2 * .pi * 220 / Double(format.sampleRate)
                        return Int16(sin(phase) * Double(amplitude))
                    }
                    continuation.yield(PCMConverter.pcm16(fromSamples: samples))
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            lock.withLock {
                self.ticker?.cancel()
                self.continuation?.finish()
                self.continuation = continuation
                self.ticker = ticker
                live = false
            }
            return stream
        }

        func stop(keepWarm: Bool) {
            lock.withLock {
                ticker?.cancel()
                continuation?.finish()
                continuation = nil
                ticker = nil
                live = false
            }
        }

        var level: Float { 0 }

        func waitUntilLive(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if lock.withLock({ live }) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        func select(deviceUID: String?) { lock.withLock { pin = nil } }
        var failoverPin: String? { lock.withLock { pin } }
        func setEventHandler(_ handler: (@Sendable (MicrophoneCapture.Event) -> Void)?) { lock.withLock { self.handler = handler } }

        func emit(_ event: MicrophoneCapture.Event) {
            let handler = lock.withLock { () -> (@Sendable (MicrophoneCapture.Event) -> Void)? in
                if case .failedOver(_, let to) = event { pin = to }
                return self.handler
            }
            handler?(event)
        }
    }

    // MARK: muted-turn

    @MainActor
    static func mutedTurn(_ options: Options) async throws {
        let words = options.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { fail(usage) }
        let out = URL(fileURLWithPath: options.values["--out"] ?? NSTemporaryDirectory() + "openclicky-muted-turn", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let config = try EngineCommands.loadConfig(options.values["--config"], fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let brain = try TurnCommands.makeBrain(factory: factory, stateRoot: out.appendingPathComponent("brain", isDirectory: true), tools: "none",
                                               figures: false, fresh: true)
        let speakers = try OfflineSpeakers(url: out.appendingPathComponent("voice.wav"))
        let fallback = AppleSpeechSynthesisClient(context: ProviderContext(provider: ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis), apiKey: nil))
        let voice = CountingVoice(wrapped: (try? factory.speechOutput()) ?? fallback)
        let narrator = LineNarrator(voice: voice, fallback: fallback, player: speakers.player)

        let output: any SystemOutputControlling
        switch options.values["--silence"] ?? "muted" {
        case "live": output = CoreAudioOutputVolume()
        case "zero": output = FakeOutputVolume(OutputVolumeState(deviceName: "Simulated Speakers", muted: false, volume: 0))
        default: output = FakeOutputVolume(OutputVolumeState(deviceName: "Simulated Speakers", muted: true, volume: 0.7))
        }
        let clipboard = InMemoryPasteboard()
        let guardian = MutedOutputGuard(output: output, pasteboard: clipboard)
        print("→ output: \(output.read()?.summary ?? "none") (\(options.values["--silence"] == "live" ? "read from this Mac" : "simulated"))")

        let screen = StillImageScreen(imageData: StillImageScreen.blankCanvas())
        let surfaces = OffscreenDrawingSurfaces()
        let services = TurnOrchestrator.Services(microphone: SilentMicrophone(), speechToText: { SimulatedSpeechToText(text: words, chunksPerWord: 8) },
                                                 screen: screen, brain: brain, narrator: narrator, drawings: surfaces, output: guardian)
        let orchestrator = TurnOrchestrator(services: services, settings: .init(speaksTypedAnswers: true))
        let clock = Stopwatch()
        var log: [String] = []
        func note(_ text: String) {
            let line = clock.stamp(text)
            log.append(line)
            print(line)
        }
        orchestrator.onLog = { note($0) }
        var captions: [String] = []
        orchestrator.onDisplayChange = { display in
            if let caption = display.caption, captions.last != caption {
                captions.append(caption)
                note("caption: \(caption)")
            }
        }
        var record: TurnRecord?
        orchestrator.onTurnFinished = { record = $0 }
        speakers.start()
        if options.flags.contains("--typed") {
            orchestrator.submitTyped(words)
        } else {
            orchestrator.pressBegan()
            try await Task.sleep(for: .seconds(max(1.0, Double(words.split(separator: " ").count) / 2.5 + 0.4)))
            orchestrator.pressEnded()
        }
        let deadline = Date().addingTimeInterval(120)
        while record == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        try speakers.finish()
        guard let record else { fail("the turn didn't finish within 2 minutes") }
        note("turn finished: \(record.outcome.label)")
        note("voice slot calls: \(voice.calls); rendered audio peak \(String(format: "%.4f", speakers.peakLevel)) over \(String(format: "%.1f", speakers.seconds)) s")
        if let unheard = record.unheardReply, let notice = guardian.replyWasUnheard(unheard) {
            note("unheard reply (\(unheard.silence.rawValue)) copied to the clipboard: \"\(clipboard.string ?? "")\"")
            note("NOTICE \(notice.summary)")
            if let pressed = notice.actions.first {
                // Only against a simulated output: this never touches the real volume.
                if output is FakeOutputVolume {
                    try guardian.perform(pressed)
                    note("pressed \"\(pressed.label)\" → \(output.read()?.summary ?? "?")")
                } else {
                    note("(not pressing \"\(pressed.label)\": the output is this Mac's real one)")
                }
            }
        } else {
            note("the reply was spoken (output audible)")
        }
        try (log.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("muted-turn.log"), atomically: true, encoding: .utf8)
        print("→ wrote \(out.path)/muted-turn.log and voice.wav")
    }

    /// Counts the voice slot's calls (there should be none while muted).
    final class CountingVoice: SpeechOutputClient, @unchecked Sendable {
        let wrapped: any SpeechOutputClient
        private let lock = NSLock()
        private var count = 0
        init(wrapped: any SpeechOutputClient) { self.wrapped = wrapped }
        var calls: Int { lock.withLock { count } }
        func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
            lock.withLock { count += 1 }
            return wrapped.speak(text, voice: voice, instructions: instructions)
        }
        func warmUp() async { await wrapped.warmUp() }
        func stopAll() async { await wrapped.stopAll() }
    }

    // MARK: echo

    static func echo(_ options: Options) async {
        let script: [EchoProbeResult] = (options.list("--probe") ?? ["working"]).map {
            switch $0 {
            case "deaf": .deaf(.noAudio)
            case "zeros": .deaf(.allZeros)
            case "failed": .failed("voice processing could not be enabled")
            default: .working(chunks: 20, audible: 19)
            }
        }
        let route: AudioOutputRoute = options.values["--route"] == "headphones" ? .headphones : .speakers
        let sessions = Int(options.values["--sessions"] ?? "2") ?? 2
        let probe = ScriptedEchoProbe(script)
        let topology = AudioTopology(inputUID: "BuiltInMicrophoneDevice", inputTransport: "built-in", outputUID: "BuiltInSpeakerDevice",
                                     outputTransport: "built-in")
        let router = DuplexAudioRouter(cache: EchoVerdictCache(), prober: probe, topology: { _ in topology },
                                       makeHost: { AudioEngineHost(offlineSampleRate: 24_000) })
        print("Route: \(route.rawValue); topology \(topology.key); scripted probe results: \(script)")
        for session in 1...max(1, sessions) {
            let decision = await router.prepare(route: route, setting: .automatic)
            print("session \(session): \(decision.summary)")
            print("  mic engine: \(router.captureHost == nil ? "its own (plain)" : "shared voice-processing host"); voice: \(router.player == nil ? "plain player" : "player on the shared host")")
            if decision.mode == .echoCancelled, session == 1, options.flags.contains("--deaf-after-start") {
                let demoted = router.captureEvent(.rebuilding(.allZeros))
                print("  mic rebuilt right after promotion → demoted: \(demoted); verdict now \(String(describing: router.verdicts.verdict(for: topology)))")
            }
            router.release()
        }
        print("probes run: \(probe.probes); cached verdict: \(String(describing: router.verdicts.verdict(for: topology)))")
        let gate = RealtimeEchoGate.Settings.tuned(for: route, echoCancelled: router.verdicts.verdict(for: topology)?.isPromoted ?? false)
        print(String(format: "echo gate for this route: barge-in at %.0f dBFS for %.2f s within %.2f s, ring-out %.2f s",
                     gate.bargeInLevelDB, gate.bargeInSpeech, gate.bargeInWindow, gate.settleWindow))
    }

    // MARK: topology

    static func topology() {
        let topology = AudioTopology.current()
        let route = AudioOutputRoute.classify(AudioDevices.defaultOutput())
        print("Input:  \(topology.inputUID ?? "none") (\(topology.inputTransport ?? "?"))")
        print("Output: \(topology.outputUID ?? "none") (\(topology.outputTransport ?? "?")) → route \(route.rawValue)")
        print("Key:    \(topology.key)")
        let cache = EchoVerdictCache.load()
        print("Cached echo-cancellation verdict: \(cache.verdict(for: topology).map { "\($0)" } ?? "none (always-on on speakers would probe first)")")
    }

    // MARK: gate-tune

    static func gateTune(_ options: Options) throws {
        guard let replies = options.list("--reply"), let users = options.list("--user") else { fail(usage) }
        let rate = 16_000
        func load(_ path: String) throws -> [Float] {
            let decoded = try AudioFileLoader.load(URL(fileURLWithPath: path))
            let mono = PCMConverter.downmixToMono(decoded.pcm, channels: decoded.format.channels)
            let pcm = try PCMConverter.convert(mono, from: PCMFormat(sampleRate: decoded.format.sampleRate), to: PCMFormat(sampleRate: rate))
            return PCMConverter.floats(fromPCM16: pcm)
        }
        let replyAudio = try replies.map(load)
        let userAudio = try users.map(load)
        var report: [String] = []
        func say(_ line: String = "") {
            print(line)
            report.append(line)
        }
        say("Echo-gate tuning, offline (EchoGateTuner): \(replies.count) repl(ies) × \(users.count) user clip(s), 16 kHz, 40 ms frames.")
        say("Replies: " + replies.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
        say("Users:   " + users.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
        say("A run is a false barge-in if the gate opens before the user's first voiced sound; a miss if the user talks over the reply and it never opens.")

        let modes: [(String, [EchoGateTuner.Room], [Float], TimeInterval, [Float])] = [
            ("echo-cancelled speakers", EchoGateTuner.Room.speakersCancelled, [-44, -40, -38, -36, -34, -32, -30], 0.3, [-34, -28, -22]),
            ("speakers without echo cancellation, normal volume", [EchoGateTuner.Room.speakersRaw[1]], [-30, -28, -26, -24, -22, -20, -18], 0.7,
             [-20, -16]),
            ("speakers without echo cancellation, loud", [EchoGateTuner.Room.speakersRaw[0]], [-26, -22, -18, -14], 0.7, [-20, -16]),
        ]
        for (name, rooms, levels, settle, userLevels) in modes {
            say()
            say("== \(name) ==")
            say("Rooms: " + rooms.map { "\($0.name) (coupling \(Int($0.couplingDB)) dB, cancels \(Int($0.cancellationDB)) dB)" }.joined(separator: "; "))
            say("User levels (voiced RMS at the mic): " + userLevels.map { "\(Int($0)) dBFS" }.joined(separator: ", ") + "; starts 0.8 s, 1.6 s or 2.4 s into the reply")
            var scenarios: [EchoGateTuner.Scenario] = rooms.map { .init(room: $0, userLevelDB: nil) }
            for room in rooms {
                for level in userLevels {
                    for start in [0.8, 1.6, 2.4] { scenarios.append(.init(room: room, userLevelDB: level, userStartsAt: start)) }
                }
            }
            let candidates = EchoGateTuner.grid(levels: levels, speech: [0.16, 0.2, 0.24, 0.3, 0.35, 0.4, 0.5], windows: [0.6, 0.8], settle: settle)
            let rows = EchoGateTuner.sweep(candidates: candidates, replies: replyAudio, users: userAudio, sampleRate: rate, scenarios: scenarios)
            say("level dB  speech s  window s   false  misses  runs   worst ms  mean ms")
            func ms(_ value: TimeInterval?) -> String { value.map { String(format: "%.0f", $0 * 1000) } ?? "-" }
            func pad(_ text: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - text.count)) + text }
            for row in rows.prefix(12) {
                say(String(format: "%8.0f  %8.2f  %8.2f  %6d  %6d  %4d  ", row.settings.bargeInLevelDB, row.settings.bargeInSpeech,
                           row.settings.bargeInWindow, row.falseBargeIns, row.misses, row.runs)
                    + pad(ms(row.worstLatency), 9) + "  " + pad(ms(row.meanLatency), 7))
            }
            let unsafe = rows.filter { $0.falseBargeIns > 0 }.count
            say("(\(rows.count) candidates; \(unsafe) opened on echo alone at least once)")
            let current = name.hasPrefix("echo") ? RealtimeEchoGate.Settings.speakersEchoCancelled : RealtimeEchoGate.Settings.speakersRaw
            let check = EchoGateTuner.sweep(candidates: [current, RealtimeEchoGate.Settings()], replies: replyAudio, users: userAudio, sampleRate: rate,
                                            scenarios: scenarios)
            for row in check {
                let label = row.settings == RealtimeEchoGate.Settings() ? "old default" : "shipped preset"
                say(label + String(format: ": level %.0f dB, speech %.2f s, window %.2f s, ring-out %.2f s → %d false, %d misses, ",
                                   row.settings.bargeInLevelDB, row.settings.bargeInSpeech, row.settings.bargeInWindow, row.settings.settleWindow,
                                   row.falseBargeIns, row.misses)
                    + "worst \(ms(row.worstLatency)) ms, mean \(ms(row.meanLatency)) ms")
            }
        }
        if let path = options.values["--out"] {
            try (report.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            print("→ wrote \(path)")
        }
    }

    final class Stopwatch: Sendable {
        private let start = Date()
        func stamp(_ text: String) -> String { String(format: "%7.3fs  ", Date().timeIntervalSince(start)) + text }
    }
}
