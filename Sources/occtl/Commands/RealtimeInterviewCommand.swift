import Foundation
import OpenClickyKit

/// `occtl realtime --interview`: the onboarding welcome chat, headless. It drives the same `OnboardingMachine` step and
/// `OnboardingInterviewPerformer` the onboarding window uses, with a sound file standing in for each spoken answer (or
/// typed answers), the voice going to a WAV, and the answers written into a memory folder (a temporary one unless
/// `--memory` names one). `--simulate` uses the offline realtime stand-in, so it needs no key or network.
enum RealtimeInterviewCommand {
    static let usage = "realtime --interview [--config c.json] [--simulate] [--in answer.wav] [--answers n] [--typed text]… "
        + "[--skip-after n] [--memory dir] [--transcript t.json] [--out chat.wav] [--speakers] [--timeout s]"

    struct Options {
        var configPath: String?
        var simulate = false
        var input: String?
        var answers = OnboardingInterviewScript.answers
        var typed: [String] = []
        var skipAfter: Int?
        var memory: String?
        var transcript: String?
        var output: String?
        var speakers = false
        var timeout = 45.0
    }

    static func run(_ args: [String]) async throws {
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
            case "--simulate": options.simulate = true
            case "--in": options.input = value("--in")
            case "--answers":
                guard let count = Int(value("--answers")), count >= 0 else { fail("--answers needs a number") }
                options.answers = count
            case "--typed": options.typed.append(value("--typed"))
            case "--skip-after":
                guard let count = Int(value("--skip-after")), count >= 0 else { fail("--skip-after needs a number") }
                options.skipAfter = count
            case "--memory": options.memory = value("--memory")
            case "--transcript": options.transcript = value("--transcript")
            case "--out": options.output = value("--out")
            case "--speakers": options.speakers = true
            case "--timeout":
                guard let seconds = Double(value("--timeout")), seconds > 0 else { fail("--timeout needs a number of seconds") }
                options.timeout = seconds
            default: fail("Unknown option \(args[index]).\nUsage: occtl \(usage)")
            }
            index += 1
        }
        if options.input == nil, options.typed.count < min(options.answers, options.skipAfter ?? .max) {
            fail("Give --in answer.wav for spoken answers, or enough --typed answers.\nUsage: occtl \(usage)")
        }
        let driver = try await MainActor.run { try Driver(options: options) }
        try await driver.run()
    }

    /// Lines the offline stand-in says, in order, so a simulated chat reads like one.
    static let simulatedReplies = [
        OnboardingInterviewScript.opener.joined(separator: " "),
        "Nice, that sounds busy. What does a normal day look like: mostly writing, meetings, or building things?",
        "Got it. Which part of that would you most like off your plate?",
        "Makes sense. Last one: have you tried AI agents before, like a coding agent or one that drives the computer?",
        "Love that. Thanks for walking me through it. Let's start with the part you want off your plate.",
    ]

    @MainActor
    final class Driver {
        let options: Options
        let performer: OnboardingInterviewPerformer
        let microphone = QueuedRealtimeMicrophone()
        let output: RecordingRealtimeOutput
        let memoryFolder: URL
        let memory: MemoryStore
        let label: String
        private(set) var machine: OnboardingMachine
        private let clock = ContinuousClock()
        private let started: ContinuousClock.Instant

        init(options: Options) throws {
            self.options = options
            started = clock.now
            let config = try EngineCommands.loadConfig(options.configPath, fallback: .heyClickyLike)
            let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
            let client: any RealtimeVoiceClient
            if options.simulate {
                client = SimulatedRealtimeVoiceClient(replySeconds: 0.8, replies: RealtimeInterviewCommand.simulatedReplies)
                label = "simulated realtime server (no network)"
            } else {
                client = try factory.realtimeVoice()
                let resolution = try factory.resolve(.realtimeVoice)
                label = "\(resolution.selection.provider) / \(resolution.selection.model) via \(resolution.adapter ?? "?")"
            }
            memoryFolder = options.memory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("occtl-interview-memory-\(UUID().uuidString)", isDirectory: true)
            memory = MemoryStore(directory: memoryFolder)
            let output = RecordingRealtimeOutput(realTime: true)
            self.output = output
            let route: AudioOutputRoute = options.speakers ? .speakers : .headphones
            let microphone = microphone
            var state = OnboardingState()
            state.step = .talkKeys
            state.furthest = .talkKeys
            machine = OnboardingMachine(state: state)
            performer = OnboardingInterviewPerformer(
                storage: .init(transcriptURL: options.transcript.map { URL(fileURLWithPath: $0) }, memory: memory)) { toolbox, instructions in
                AlwaysOnVoiceController(environment: AlwaysOnVoiceController.Environment(
                    connect: { try await client.connect($0) },
                    configuration: { route in
                        RealtimeSessionConfiguration(instructions: instructions(), tools: toolbox.specs,
                                                     turnDetection: .serverVAD(route == .headphones ? .headphones : .speakers),
                                                     noiseReduction: route == .headphones ? .nearField : .farField)
                    },
                    toolbox: toolbox, makeOutput: { output }, microphone: microphone, outputRoute: { route },
                    requireHeadphones: false, maxReconnects: 0))
            }
            performer.deliver = { [weak self] event in self?.send(event) }
            performer.acceptsSkip = { [weak self] in self?.machine.acceptsInterviewSkip ?? false }
            performer.onLog = { [weak self] line in self?.log(line) }
        }

        func send(_ event: OnboardingEvent) {
            let before = machine.step
            let effects = machine.send(event)
            if machine.step != before { log("step \(before.title) → \(machine.step.title)") }
            for effect in effects {
                if case .sendInterviewText(let text, let respond) = effect {
                    log("sent \(respond ? "a message" : "a note"): \(text.replacingOccurrences(of: "\n", with: " "))")
                }
                performer.perform(effect)
            }
        }

        var interview: OnboardingInterviewState { machine.state.interview }

        func run() async throws {
            log("welcome chat with \(label); memory in \(memoryFolder.path)")
            send(.next)
            guard await wait({ [.live, .scripted].contains(self.interview.phase) }) else { fail("The welcome chat never started.") }
            if interview.phase == .live {
                _ = await wait { !self.interview.questions.isEmpty }
            }
            let speech = try options.input.map { try TranscribeCommands.decode(URL(fileURLWithPath: $0), to: .speech24k) }
            var typed = options.typed[...]
            for answer in 0..<options.answers {
                if options.skipAfter == answer {
                    log("pressing Skip after \(answer) answer(s)")
                    send(.skipInterview)
                    break
                }
                guard interview.phase == .live || interview.phase == .scripted else { break }
                let questions = interview.questions.count
                if let text = typed.popFirst() {
                    send(.interviewAnswered(text, typed: true))
                } else if interview.phase == .live, let speech {
                    log(String(format: "speaking answer %d (%.1f s of audio)", answer + 1, Double(speech.count) / Double(PCMFormat.speech24k.bytesPerSecond)))
                    microphone.speak(speech, format: .speech24k)
                } else {
                    send(.interviewAnswered("(no typed answer given)", typed: true))
                }
                guard await wait({ self.interview.answers.count > answer || self.interview.isOver }) else {
                    log("no answer was heard")
                    break
                }
                // Wait for the reply (the next question, or the wrap-up after the last answer).
                _ = await wait { self.interview.questions.count > questions || self.interview.isOver }
            }
            if !interview.isOver {
                _ = await wait { self.interview.isOver }
            }
            if !interview.isOver {
                log("no wrap-up before the timeout; continuing (counts as a skip)")
                send(.next)
            }
            // Let the closing line play out and the session close.
            _ = await wait(seconds: 10) { !self.output.isPlaying }
            try await Task.sleep(for: .milliseconds(300))
            report()
        }

        private func report() {
            print("")
            for line in interview.lines {
                print("\(line.role == .user ? "You" : "OpenClicky")\(line.typed == true ? " (typed)" : ""): \(line.text)")
            }
            print("")
            print("Outcome: \(interview.phase.rawValue) after \(interview.answers.count) of \(interview.total) answers; "
                + "\(performer.savedRecords.count) save(s); now on the \(machine.step.title) step.")
            if let path = options.output {
                let heard = output.receivedAudio
                let format = heard.format ?? .speech24k
                do {
                    try EngineCommands.wav(heard.pcm, format: format).write(to: URL(fileURLWithPath: path))
                    print(String(format: "Wrote %.2f s of the chat's voice to %@.", Double(heard.pcm.count) / Double(format.bytesPerSecond), path))
                } catch {
                    print("Couldn't write \(path): \(error)")
                }
            }
            if let path = options.transcript { print("Transcript: \(path)") }
            let profile = (try? memory.profileText()).map(MemoryProfile.init(text:))
            if let profile, let section = profile.section(named: OnboardingInterviewScript.memorySection) {
                print("\nMemory profile, \(section.title):")
                for line in profile.content(of: section) { print("  - \(line)") }
            }
            if let snapshot = try? memory.snapshot() {
                print("\nThe next turn's memory context:\n\(MemoryPromptBuilder().build(from: snapshot, query: "").stableText)")
            }
        }

        private func wait(seconds: Double? = nil, _ condition: @escaping () -> Bool) async -> Bool {
            let deadline = clock.now + .seconds(seconds ?? options.timeout)
            while !condition() {
                if clock.now >= deadline { return condition() }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return true
        }

        func log(_ text: String) {
            let elapsed = clock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            FileHandle.standardError.write(Data(String(format: "[%6.2f s] %@\n", seconds, text).utf8))
        }
    }
}

/// A microphone that sends silence in real time and plays queued speech when asked, like a person who answers when
/// it's their turn.
final class QueuedRealtimeMicrophone: RealtimeMicrophone, @unchecked Sendable {
    private let lock = NSLock()
    private var queue = Data()
    private var queueFormat: PCMFormat?
    private var task: Task<Void, Never>?

    func speak(_ pcm: Data, format: PCMFormat) {
        lock.withLock {
            queue.append(pcm)
            queueFormat = format
        }
    }

    func start(format: PCMFormat) throws -> AsyncStream<Data> {
        let chunkBytes = format.bytesPerSecond / 10 / 2 * 2
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                let chunk = self?.next(bytes: chunkBytes, format: format) ?? Data(count: chunkBytes)
                continuation.yield(chunk)
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
        lock.withLock { self.task = task }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func next(bytes: Int, format: PCMFormat) -> Data {
        lock.withLock {
            if let source = queueFormat, source != format, !queue.isEmpty {
                queue = (try? PCMConverter.convert(queue, from: source, to: format)) ?? Data()
                queueFormat = format
            }
            guard !queue.isEmpty else { return Data(count: bytes) }
            let piece = queue.prefix(bytes)
            queue.removeFirst(piece.count)
            return piece.count == bytes ? Data(piece) : Data(piece) + Data(count: bytes - piece.count)
        }
    }

    func stop() {
        lock.withLock { task }?.cancel()
    }
}
