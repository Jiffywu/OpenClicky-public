import Foundation
import OpenClickyKit

/// `occtl realtime`: one headless always-on round trip through the realtime-voice slot. A sound file stands in for the
/// microphone (sent in real time, then silence so the provider's voice activity detection ends the turn); the reply's
/// audio goes to a WAV instead of the speakers, with its transcript, timings and tool calls. Needs no microphone,
/// speaker or screen permission: `--screen` takes a picture file for `capture_screen`.
enum RealtimeCommands {
    static let usage = "realtime [--config c.json] --in speech.wav --out reply.wav [--transcript t.json] [--screen shot.jpg] "
        + "[--brain] [--lookups] [--voice v] [--instructions text] [--note text] [--manual] [--speakers] [--fast] [--timeout s] [--simulate [--scenario go-away|go-away-no-handle|voice-change|muted|drawing]] "
        + "[--runtime [--state dir] [--app name] [--window title] [--doc file]]"
        + "  one headless always-on round trip (--runtime: the app's wiring: send_to_higher_model on the brain runtime with "
        + "the given context, memory and skills in the instructions, the exchange recorded in the history's current conversation)"
        + "\n       occtl " + RealtimeInterviewCommand.usage + "  the onboarding welcome chat, headless"

    static let realtime = OcctlCommand(name: "realtime", usage: usage) { args in
        if args.contains("--interview") { return try await RealtimeInterviewCommand.run(args.filter { $0 != "--interview" }) }
        var options = Options()
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--config": options.configPath = value("--config")
            case "--in": options.input = value("--in")
            case "--out": options.output = value("--out")
            case "--transcript": options.transcript = value("--transcript")
            case "--screen": options.screen = value("--screen")
            case "--brain": options.brain = true
            case "--lookups": options.lookups = true
            case "--voice": options.voice = value("--voice")
            case "--instructions": options.instructions = value("--instructions")
            case "--note": options.notes.append(value("--note"))
            case "--manual": options.manual = true
            case "--speakers": options.speakers = true
            case "--fast": options.fast = true
            case "--simulate": options.simulate = true
            case "--scenario": options.scenario = value("--scenario")
            case "--runtime": options.runtime = true
            case "--state": options.state = value("--state")
            case "--app": options.app = value("--app")
            case "--window": options.window = value("--window")
            case "--doc": options.document = value("--doc")
            case "--timeout":
                guard let seconds = Double(value("--timeout")), seconds > 0 else { fail("--timeout needs a number of seconds") }
                options.timeout = seconds
            default: fail("Unknown option \(args[index]).\nUsage: occtl \(usage)")
            }
            index += 1
        }
        if let scenario = options.scenario {
            guard options.simulate, options.input != nil else { fail("--scenario runs on the simulator: --simulate --in speech.wav") }
            return try await runScenario(scenario, options: options)
        }
        guard options.input != nil, options.output != nil else { fail("Usage: occtl \(usage)") }
        try await run(options)
    }

    struct Options {
        var configPath: String?
        var input: String?
        var output: String?
        var transcript: String?
        var screen: String?
        var brain = false
        var lookups = false
        var voice: String?
        var instructions: String?
        /// Notes added before the audio without asking for a reply, the way the app adds `[App]` notes.
        var notes: [String] = []
        var manual = false
        var speakers = false
        var fast = false
        var simulate = false
        /// An always-on edge case on the simulator (`RealtimeScenarioCommand.swift`).
        var scenario: String?
        var timeout = 45.0
        /// The app's wiring: the brain runtime for send_to_higher_model, memory and skills, and the history.
        var runtime = false
        var state: String?
        var app: String?
        var window: String?
        var document: String?
    }

    static func run(_ options: Options) async throws {
        let config = try EngineCommands.loadConfig(options.configPath, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models),
                                    credentials: CoreCommands.store)
        let client: any RealtimeVoiceClient
        var label: String
        if options.simulate {
            client = SimulatedRealtimeVoiceClient()
            label = "simulated realtime server (no network)"
        } else {
            client = try factory.realtimeVoice()
            let resolution = try factory.resolve(.realtimeVoice)
            label = "\(resolution.selection.provider) / \(resolution.selection.model) via \(resolution.adapter ?? "?")"
        }

        // Tools: only what was asked for, so a plain run never touches the screen, memory or the network beyond the slot.
        let screen = try options.screen.map { try StaticRealtimeScreenSource(imageFile: URL(fileURLWithPath: $0)) }
        let brainLog = BrainLog()
        var lookups: LookupTools?
        if options.lookups {
            let services = LookupServices.make(config: (try? ServicesConfig.load()) ?? ServicesConfig(), credentials: CoreCommands.store)
            lookups = LookupTools(services: services)
        }
        var brain: (any BrainTurnRunning)? = options.brain ? try VisionAnswerBrain.forBrainSlot(factory) : nil
        var runtime: BrainRuntime?
        var wiring = BrainWiring()
        var recorder: AlwaysOnRecorder?
        var look: (any RealtimeBrainLooking)?
        if options.runtime {
            // The app's always-on wiring: the brain runtime answers send_to_higher_model with the context a
            // push-to-talk turn would get, and the exchange goes into the conversation the runtime holds.
            let state = BrainSessionStore(root: options.state.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? BrainSessionStore.defaultRoot)
            wiring = BrainCommands.wiring(tools: options.lookups ? "memory,skills,lookups" : "memory,skills", factory: factory,
                                          dialect: try factory.resolve(.brain).provider?.dialect,
                                          memoryDirectory: state.root.appendingPathComponent("memory", isDirectory: true),
                                          services: nil, hostedSearch: false, connectors: nil)
            let made = try BrainCommands.runtime(factory: factory, wiring: wiring, store: state)
            runtime = made
            brain = made
            let writer = try? MemoryWriter(factory: factory)
            let memory = wiring.memory
            let made2 = await MainActor.run {
                let recorder = AlwaysOnRecorder(history: HistoryStore(directory: HistoryCommands.directory), sessions: made,
                                                memory: writer.flatMap { writer in memory.map { (writer, $0) } }, model: client.model)
                recorder.onRunNote = { note in await made.recordOutcome(note) }
                recorder.onLog = { text in RealtimeCommands.log(0, text) }
                return recorder
            }
            recorder = made2
            var context = TurnContext(frontApp: options.app, windowTitle: options.window)
            if let path = options.document { context.documentText = try String(contentsOfFile: path, encoding: .utf8) }
            let shots = screen.map { [$0.screenshot] } ?? []
            look = StaticRealtimeBrainLook(screenshots: shots, context: context,
                                           notes: { await MainActor.run { [made2.recentNote()].compactMap { $0 } } })
            log(0, "brain runtime session \(await made.currentSessionID()); history \(HistoryCommands.directory.path)")
        }
        let toolbox = RealtimeToolbox.standard(screen: screen, brain: brain, brainLook: look, brainObserver: { brainLog.record($0) },
                                               memory: wiring.memoryTools, lookups: lookups)
        let route: AudioOutputRoute = options.speakers ? .speakers : .headphones
        let stableMemory = wiring.memory.flatMap { try? $0.snapshot() }.map { MemoryPromptBuilder().build(from: $0, query: "").stableText }
        let instructions = options.instructions ?? RealtimeInstructions.alwaysOn(
            memory: stableMemory, skills: wiring.skills?.skillsPromptSection(), toolNames: Set(toolbox.specs.map(\.name)))
        let configuration = RealtimeSessionConfiguration(
            instructions: instructions, tools: toolbox.specs, voice: options.voice,
            turnDetection: options.manual ? .manual : .serverVAD(route == .headphones ? .headphones : .speakers),
            noiseReduction: route == .headphones ? .nearField : .farField)

        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> Double { (clock.now - started).seconds }
        log(0, "connecting to \(label)")
        let session = try await client.connect(configuration)
        let setupSeconds = elapsed()
        log(setupSeconds, "session ready (model \(session.model), in \(session.inputFormat.sampleRate) Hz, out \(session.outputFormat.sampleRate) Hz, \(toolbox.specs.count) tools)")

        let pcm = try TranscribeCommands.decode(URL(fileURLWithPath: options.input!), to: session.inputFormat)
        let inputSeconds = Double(pcm.count) / Double(session.inputFormat.bytesPerSecond)
        let output = RecordingRealtimeOutput(realTime: !options.fast)
        let dispatcher = toolbox.tools.isEmpty ? nil : toolbox.dispatcher()
        let conversation = RealtimeConversation(session: session, output: output, dispatcher: dispatcher,
                                                options: .init(route: route))
        let timeline = Recorder(start: started)
        let alwaysOnRecorder = recorder
        let updatesTask = Task {
            for await update in conversation.updates {
                timeline.note(update, at: elapsed())
                if let alwaysOnRecorder { await MainActor.run { alwaysOnRecorder.apply(.conversation(update)) } }
            }
        }
        let runTask = Task { await conversation.run() }
        for note in options.notes {
            await conversation.addText(note, respond: false)
            log(elapsed(), "added a note without asking for a reply (\(note.count) characters)")
        }

        // The "microphone": the file in real time, then silence so the turn can end.
        let microphone = FileRealtimeMicrophone(pcm: pcm, format: session.inputFormat, realTime: !options.fast,
                                                trailingSilence: options.manual ? .zero : .seconds(1.5))
        log(elapsed(), String(format: "sending %.2f s of audio", inputSeconds))
        var fed = 0
        var speechEnded: Double?
        for await chunk in try microphone.start(format: session.inputFormat) {
            await conversation.feedMicrophone(chunk)
            fed += chunk.count
            if speechEnded == nil, fed >= pcm.count {
                speechEnded = elapsed()
                log(speechEnded!, "end of the input speech")
            }
        }
        if options.manual { await session.endAudioTurn() }
        let inputEnded = speechEnded ?? elapsed()

        // Keep the mic "open" with silence (as the real mic would be) until the reply has played and nothing is running.
        let deadline = inputEnded + options.timeout
        let silence = Data(count: session.inputFormat.bytesPerSecond / 10)
        while elapsed() < deadline {
            if !options.manual { await conversation.feedMicrophone(silence) }
            try await Task.sleep(for: .milliseconds(100))
            let running = await dispatcher?.runningCount ?? 0
            if timeline.isSettled(now: elapsed(), quiet: 1.5), running == 0, !output.isPlaying { break }
        }
        let timedOut = elapsed() >= deadline
        await conversation.close()
        _ = await runTask.value
        // The update stream ends with the conversation; every update has been seen once it does.
        await updatesTask.value
        if let alwaysOnRecorder {
            // Always-on going off: the exchange is recorded, memory is written and the brain hears what was said.
            await MainActor.run { alwaysOnRecorder.apply(.state(.off)) }
            await alwaysOnRecorder.flush()
            await alwaysOnRecorder.ending?.value
            await runtime?.waitForBackgroundWork()
            let id = await runtime?.currentSessionID() ?? "?"
            log(elapsed(), "recorded in conversation \(id): occtl history show \(id)")
        }

        // Results.
        let heard = output.heardAudio
        let format = heard.format ?? session.outputFormat
        try EngineCommands.wav(heard.pcm, format: format).write(to: URL(fileURLWithPath: options.output!))
        let replySeconds = Double(heard.pcm.count) / Double(format.bytesPerSecond)
        let transcript = await conversation.transcript
        let responses = await conversation.responses
        let firstAudio = timeline.firstAudio.map { $0 - inputEnded }
        if let path = options.transcript {
            let report = Report(provider: label, model: session.model, input: options.input!, inputSeconds: inputSeconds,
                                setupSeconds: setupSeconds, firstReplyAudioAfterInputEnd: firstAudio, replySeconds: replySeconds,
                                transcript: transcript, timeline: timeline.timeline, brain: brainLog.lines, timedOut: timedOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
        }
        print("")
        for line in transcript {
            let who = line.role == .user ? "You" : line.role == .assistant ? "OpenClicky" : "Tool"
            print("\(who): \(line.text)\(line.note.map { "  [\($0)]" } ?? "")")
        }
        let usage = responses.compactMap(\.usage).reduce(into: (input: 0, output: 0)) { $0.input += $1.inputTokens; $0.output += $1.outputTokens }
        print(String(format: "Wrote %.2f s of reply audio (%d Hz) to %@.", replySeconds, format.sampleRate, options.output!))
        print("Setup \(fmt(setupSeconds)); first reply audio \(firstAudio.map(fmt) ?? "-") after the input ended; "
            + "\(responses.count) response(s); tokens in \(usage.input) out \(usage.output)"
            + (timedOut ? "; stopped at the \(Int(options.timeout)) s timeout" : "") + ".")
        if replySeconds == 0 { fail("No reply audio came back.") }
    }

    static func log(_ seconds: Double, _ text: String) {
        FileHandle.standardError.write(Data("[\(fmt(seconds))] \(text)\n".utf8))
    }

    static func fmt(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

    /// Notes the conversation's updates for the timeline and decides when the exchange is over.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [TimelineEntry] = []
        private var lastActivity = 0.0
        private var finishedWithAudio = false
        private(set) var firstAudio: Double?
        let start: ContinuousClock.Instant

        init(start: ContinuousClock.Instant) { self.start = start }

        func note(_ update: RealtimeConversationUpdate, at time: Double) {
            let text: String?
            switch update {
            case .state(let state):
                if state == .speaking { lock.withLock { if firstAudio == nil { firstAudio = time } } }
                text = "state \(state.rawValue)"
            case .userCaption(let caption, let isFinal): text = isFinal ? "you said: \(caption)" : nil
            case .assistantCaption: text = nil
            case .status(let label): text = label.map { "status: \($0)" }
            case .tool(let activity): text = "tool \(activity)"
            case .bargeIn(let heard): text = "barge-in after \(fmt(heard)) of the reply"
            case .discardedTurn(let reason): text = "dropped a turn: \(reason)"
            case .responseFinished(let summary):
                // Done once a reply with speech and no pending tool calls has finished; a reply that called a tool is
                // followed by another one about the result.
                lock.withLock { finishedWithAudio = !summary.itemIDs.isEmpty && summary.toolCalls.isEmpty }
                text = "response \(summary.status.rawValue)\(summary.toolCalls.isEmpty ? "" : " with \(summary.toolCalls.map(\.name))")"
                    + (summary.transcript.isEmpty ? "" : ": \(summary.transcript)")
            case .deferredActionFailed(let note): text = note
            case .warning(let warning): text = "warning: \(warning)"
            case .ended(let error): text = "ended\(error.map { ": \($0)" } ?? "")"
            }
            lock.withLock {
                lastActivity = time
                if let text { entries.append(TimelineEntry(seconds: (time * 100).rounded() / 100, event: text)) }
            }
            if let text { RealtimeCommands.log(time, text) }
        }

        func isSettled(now: Double, quiet: Double) -> Bool {
            lock.withLock { finishedWithAudio && now - lastActivity >= quiet }
        }

        var timeline: [TimelineEntry] { lock.withLock { entries } }
    }

    /// What the brain did for `send_to_higher_model`, for the report.
    final class BrainLog: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func record(_ event: TurnEvent) {
            if case .sayLine(_, let text) = event { lock.withLock { said.append(text) } }
        }
        var lines: [String] { lock.withLock { said } }
    }

    struct TimelineEntry: Codable {
        var seconds: Double
        var event: String
    }

    struct Report: Codable {
        var provider: String
        var model: String
        var input: String
        var inputSeconds: Double
        var setupSeconds: Double
        var firstReplyAudioAfterInputEnd: Double?
        var replySeconds: Double
        var transcript: [RealtimeTranscriptLine]
        var timeline: [TimelineEntry]
        var brain: [String]
        var timedOut: Bool
    }
}

fileprivate extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
