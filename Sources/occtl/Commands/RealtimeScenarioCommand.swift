import Foundation
import OpenClickyKit

/// `occtl realtime --simulate --scenario <name> --in question.wav`: the app's always-on path (`AlwaysOnVoiceLoop` over
/// `AlwaysOnVoiceController`) on the simulated realtime server, with the file spoken as up to three turns a few seconds
/// apart. Each scenario sets up one of the always-on edge cases and prints a timeline plus a check list:
///
/// - `go-away`: at the start of the second turn the provider says it will close in 10 s (with a resumption handle, as
///   Gemini sends); `go-away-no-handle` does the same without a handle, so the transcript is carried instead.
/// - `voice-change`: the voice changes at the start of the second turn.
/// - `muted`: the Mac's output is muted (a pretend output device; the real volume is never read or changed).
/// - `drawing`: a drawing is playing when the model asks for `capture_screen`.
///
/// No network, no key, no microphone or speakers: the reply audio goes to `--out` when given.
extension RealtimeCommands {
    static let scenarios = ["go-away", "go-away-no-handle", "voice-change", "muted", "drawing"]

    @MainActor
    static func runScenario(_ name: String, options: Options) async throws {
        guard scenarios.contains(name) else { fail("Unknown scenario \(name). Scenarios: \(scenarios.joined(separator: ", "))") }
        let run = ScenarioRun(name: name)
        try await run.perform(input: URL(fileURLWithPath: options.input!), output: options.output.map { URL(fileURLWithPath: $0) })
    }
}

@MainActor
final class ScenarioRun {
    /// The sessions the simulated client opened, with what each was opened with.
    final class Sessions: @unchecked Sendable {
        struct Opened {
            var session: FakeRealtimeVoiceSession
            var configuration: RealtimeSessionConfiguration
            var openedAt: Double
            var closedAt: Double?
        }
        private let lock = NSLock()
        private var list: [Opened] = []
        private var _voice = "Kore"
        var voice: String {
            get { lock.withLock { _voice } }
            set { lock.withLock { _voice = newValue } }
        }
        var all: [Opened] { lock.withLock { list } }
        func add(_ opened: Opened) -> Int { lock.withLock { list.append(opened); return list.count } }
        func markClosed(at time: Double) -> [Int] {
            lock.withLock {
                var closed: [Int] = []
                for index in list.indices where list[index].closedAt == nil && list[index].session.sent.contains(.close) {
                    list[index].closedAt = time
                    closed.append(index + 1)
                }
                return closed
            }
        }
    }

    let name: String
    let sessions = Sessions()
    let started = ContinuousClock.now
    private var checks: [(String, Bool)] = []
    private var speechStarts = 0
    private var goAwayAt: Double?
    private var voiceChangedAt: Double?
    private var notices: [AudioNotice] = []
    private var finishedReplies: [String] = []

    init(name: String) { self.name = name }

    func elapsed() -> Double {
        let parts = (ContinuousClock.now - started).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func log(_ text: String) { RealtimeCommands.log(elapsed(), text) }

    func perform(input: URL, output outputURL: URL?) async throws {
        let turns = name == "muted" || name == "drawing" ? 1 : 3
        let client = SimulatedRealtimeVoiceClient()
        let sessions = sessions
        let started = started
        let since: @Sendable () -> Double = {
            let parts = (ContinuousClock.now - started).components
            return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        }

        // Tools: only `capture_screen` (for `drawing`), on a blank picture, with a drawing always playing.
        var toolbox = RealtimeToolbox([])
        if name == "drawing" {
            guard let shot = StillImageScreen(imageData: StillImageScreen.blankCanvas()).screenshot else { fail("no blank canvas") }
            toolbox = RealtimeToolbox.standard(screen: StaticRealtimeScreenSource(screenshot: shot), brain: nil,
                                               isDrawing: { true })
        }
        let specs = toolbox.specs
        let output = RecordingRealtimeOutput(realTime: true)

        // The microphone: the file `turns` times, 4 s apart, then quiet.
        let format = PCMFormat.speech24k
        let question = try TranscribeCommands.decode(input, to: format)
        var pcm = Data()
        for turn in 0..<turns {
            if turn > 0 { pcm.append(Data(count: format.bytesPerSecond * 4)) }
            pcm.append(question)
        }
        let microphone = FileRealtimeMicrophone(pcm: pcm, format: format, realTime: true, trailingSilence: .seconds(3))
        let totalSeconds = Double(pcm.count) / Double(format.bytesPerSecond) + 3

        let environment = AlwaysOnVoiceController.Environment(
            connect: { configuration in
                let session = try await client.connect(configuration)
                guard let fake = session as? FakeRealtimeVoiceSession else { return session }
                let number = sessions.add(.init(session: fake, configuration: configuration, openedAt: since()))
                let carried = configuration.instructions.contains("You:") || configuration.instructions.contains("User:")
                RealtimeCommands.log(since(), "session \(number) opened: voice \(configuration.voice ?? "-"), resumption handle "
                    + "\(configuration.resumptionHandle ?? "none"), recent transcript carried: \(carried ? "yes" : "no")")
                return session
            },
            configuration: { _ in
                RealtimeSessionConfiguration(instructions: "You are the simulated always-on voice. Be brief.", tools: specs,
                                             voice: sessions.voice, resumable: true)
            },
            toolbox: toolbox,
            makeOutput: { output },
            microphone: microphone, outputRoute: { .headphones })

        let orchestrator = TurnOrchestrator(services: .init(
            microphone: nil, speechToText: { throw EngineFactoryError.slotEmpty(.stt) }, screen: StillImageScreen(imageData: nil),
            brain: ScenarioBrain(), narrator: nil, drawings: nil))
        let loop = AlwaysOnVoiceLoop(orchestrator: orchestrator) { AlwaysOnVoiceController(environment: environment) }
        let volume = FakeOutputVolume(OutputVolumeState(deviceName: "Pretend Headphones", muted: true, volume: 0.6))
        let clipboard = InMemoryPasteboard()
        var guardian: MutedOutputGuard?
        if name == "muted" {
            log("output: Pretend Headphones, muted (a stand-in device; the Mac's own volume is not touched)")
            guardian = MutedOutputGuard(output: volume, pasteboard: clipboard)
            loop.mutedGuard = guardian
            loop.onUnheardReply = { [weak self] notice in
                self?.notices.append(notice)
                self?.log("notice: \(notice.title)\(notice.detail.map { " (\($0))" } ?? "") buttons \(notice.actions.map(\.label))")
            }
        }
        loop.onLog = { [weak self] text in self?.log("loop: \(text)") }
        loop.onUpdate = { [weak self] update in self?.observe(update, loop: loop) }

        let closer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                for number in self.sessions.markClosed(at: self.elapsed()) { self.log("session \(number) closed") }
            }
        }
        loop.start()
        let deadline = totalSeconds + 8
        while elapsed() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if finishedReplies.count >= turns, elapsed() > totalSeconds { break }
        }
        loop.stop()
        while loop.isActive, elapsed() < deadline + 3 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        closer.cancel()
        _ = sessions.markClosed(at: elapsed())

        if let outputURL {
            let heard = output.heardAudio
            try EngineCommands.wav(heard.pcm, format: heard.format ?? format).write(to: outputURL)
        }
        report(turns: turns, guardian: guardian, volume: volume)
    }

    private func observe(_ update: AlwaysOnUpdate, loop: AlwaysOnVoiceLoop) {
        switch update {
        case .state: break  // the loop logs these
        case .reconnecting: log("reconnecting after a drop")
        case .conversation(let event):
            switch event {
            case .state(let state):
                if state == .userSpeaking {
                    speechStarts += 1
                    onSpeechStarted(speechStarts, loop: loop)
                }
            case .userCaption(let text, true): log("you said: \(text)")
            case .tool(let activity): log("tool \(activity)")
            case .responseFinished(let summary):
                log("response \(summary.status.rawValue)\(summary.toolCalls.isEmpty ? "" : " with \(summary.toolCalls.map(\.name))")"
                    + (summary.transcript.isEmpty ? "" : ": \(summary.transcript)"))
                if !summary.itemIDs.isEmpty, summary.toolCalls.isEmpty { finishedReplies.append(summary.transcript) }
            case .warning(let text): log("warning: \(text)")
            case .ended(let error): log("conversation ended\(error.map { ": \($0)" } ?? "")")
            default: break
            }
        }
    }

    /// The second turn starting is when the provider announces goAway or the voice changes.
    private func onSpeechStarted(_ count: Int, loop: AlwaysOnVoiceLoop) {
        guard count == 2, let current = sessions.all.last?.session else { return }
        switch name {
        case "go-away", "go-away-no-handle":
            if name == "go-away" {
                current.emit(.resumable(handle: "sim-handle-1"))
                log("provider: resumption handle sim-handle-1")
            }
            goAwayAt = elapsed()
            current.emit(.goingAway(timeLeft: .seconds(10)))
            log("provider: goAway, closing in 10 s (the user is mid-turn)")
        case "voice-change":
            voiceChangedAt = elapsed()
            sessions.voice = "Puck"
            log("settings: voice changed to Puck (the user is mid-turn)")
            loop.voiceChanged()
        default:
            break
        }
    }

    private func check(_ text: String, _ passed: Bool) { checks.append((text, passed)) }

    private func report(turns: Int, guardian: MutedOutputGuard?, volume: FakeOutputVolume) {
        let opened = sessions.all
        check("every turn was answered (\(finishedReplies.count) of \(turns))", finishedReplies.count >= turns)
        switch name {
        case "go-away", "go-away-no-handle":
            check("a replacement session opened", opened.count == 2)
            if let goAway = goAwayAt, opened.count >= 2 {
                let first = opened[0], second = opened[1]
                check(String(format: "the replacement opened %.2f s after goAway", second.openedAt - goAway), second.openedAt - goAway < 1)
                if let closed = first.closedAt {
                    check(String(format: "the old session closed %.2f s after goAway, before its 10 s were up", closed - goAway),
                          closed - goAway < 10)
                } else {
                    check("the old session closed", false)
                }
                if name == "go-away" {
                    check("the replacement resumed from the provider's handle", second.configuration.resumptionHandle == "sim-handle-1")
                } else {
                    check("without a handle the replacement carries the recent transcript",
                          second.configuration.resumptionHandle == nil && second.configuration.instructions.count
                            > first.configuration.instructions.count)
                }
                check("the turn in progress was answered on the old session and the next on the new one",
                      first.session.sentAudioBytes > 0 && second.session.sentAudioBytes > 0 && finishedReplies.count >= 3)
                let notes = second.session.sent.compactMap { if case .text(let text, false) = $0 { text } else { nil } }
                check("the replacement was told the exchange that finished on the old session after it opened",
                      notes.contains { $0.contains("User:") && $0.contains("You:") })
            }
        case "voice-change":
            check("the session was restarted once", opened.count == 2)
            if opened.count >= 2, let changed = voiceChangedAt {
                check("the new session speaks with Puck", opened[1].configuration.voice == "Puck")
                check(String(format: "it restarted at the next pause, %.2f s after the change (not mid-turn)", opened[1].openedAt - changed),
                      opened[1].openedAt - changed > 1)
                check("the recent transcript went with it", opened[1].configuration.instructions.count > opened[0].configuration.instructions.count)
            }
        case "muted":
            check("the Unmute notice showed once", notices.count == 1 && notices.first?.kind == .outputMuted)
            check("the reply was copied to the clipboard: \(guardian?.lastCopied ?? "nothing")", guardian?.lastCopied?.isEmpty == false)
            check("the output's mute and volume were left alone", volume.log.isEmpty)
        case "drawing":
            let session = opened.first?.session
            let images = session?.sent.filter { if case .image = $0 { true } else { false } }.count ?? 0
            let result = session?.toolResults.first { $0.name == RealtimeToolName.captureScreen }
            let message = result?.output.objectValue?["message"]?.stringValue ?? "-"
            check("capture_screen answered in words: \(message)", result != nil)
            check("no picture was attached while the drawing played (\(images) images sent)", images == 0)
        default:
            break
        }
        print("")
        print("Scenario \(name): \(sessions.all.count) session(s)")
        for (text, passed) in checks { print("\(passed ? "PASS" : "FAIL")  \(text)") }
        if checks.contains(where: { !$0.1 }) { fail("Scenario \(name) failed.") }
    }
}

/// The scenarios never reach the push-to-talk brain; any turn that did would say so.
final class ScenarioBrain: BrainTurnRunning, @unchecked Sendable {
    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(spoken: "Not in this scenario.", detail: "occtl realtime --scenario"))
            continuation.finish()
        }
    }
    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
}
