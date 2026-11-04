import CoreGraphics
import Foundation
import QuartzCore
@testable import OpenClickyKit

/// One ordered log shared by every fake, so tests can check what happened across parts and in which order.
final class VoiceTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    func index(of entry: String) -> Int? { all.firstIndex(of: entry) }
    func filtered(_ prefix: String) -> [String] { all.filter { $0.hasPrefix(prefix) } }
}

/// A brain that plays a script of events per turn, each after a delay.
final class ScriptedBrain: BrainTurnRunning, DeferredActionPerforming, BrainSessionNaming, @unchecked Sendable {
    struct Step {
        var delay: TimeInterval
        var event: TurnEvent
    }

    private let lock = NSLock()
    private var scripts: [[Step]]
    private var _inputs: [TurnInput] = []
    private var _notes: [String] = []
    private var _prewarms = 0
    private var _cancelled = 0
    let trace: VoiceTrace
    var deferredResult: JSONValue = ["status": "opened"]

    init(trace: VoiceTrace, scripts: [[Step]]) {
        self.trace = trace
        self.scripts = scripts
    }

    var inputs: [TurnInput] { lock.withLock { _inputs } }
    var notes: [String] { lock.withLock { _notes } }
    var prewarms: Int { lock.withLock { _prewarms } }
    var cancelledRuns: Int { lock.withLock { _cancelled } }

    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        let script: [Step] = lock.withLock {
            _inputs.append(input)
            return scripts.count > 1 ? scripts.removeFirst() : (scripts.first ?? [])
        }
        trace.add("brain.run:\(input.words)")
        let (stream, continuation) = AsyncThrowingStream<TurnEvent, Error>.makeStream()
        let task = Task {
            for step in script {
                try? await Task.sleep(for: .seconds(step.delay))
                if Task.isCancelled { return }
                continuation.yield(step.event)
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] termination in
            task.cancel()
            if case .cancelled = termination { self?.lock.withLock { self?._cancelled += 1 } }
        }
        return stream
    }

    func prewarm() async { lock.withLock { _prewarms += 1 } }

    func recordOutcome(_ note: String) async {
        lock.withLock { _notes.append(note) }
        trace.add("brain.note")
    }

    func endSession() async {}

    func performDeferred(_ action: DeferredAction) async -> JSONValue {
        trace.add("deferred:\(action.name)")
        return deferredResult
    }

    func currentSessionID() async -> String { "test-session" }

    // Script building

    static func program(_ lines: [String], deferred: [String] = [], gap: TimeInterval = 0.02) -> [Step] {
        var steps: [Step] = []
        for (index, line) in lines.enumerated() {
            steps.append(Step(delay: gap, event: .programDelta("say(\"\(line)\")\n")))
            steps.append(Step(delay: 0, event: .sayLine(index: index, text: line)))
            steps.append(Step(delay: 0, event: .programDelta("line([10, \(10 + index * 20)], [200, \(10 + index * 20)])\n")))
        }
        for name in deferred {
            steps.append(Step(delay: 0.005, event: .deferredAction(DeferredAction(callID: "c-\(name)", name: name, arguments: ["url": "https://example.com"]))))
        }
        let summary = TurnSummary(program: "", spokenLines: lines, rounds: 1, usage: nil, model: "scripted", firstTokenSeconds: 0.02,
                                  totalSeconds: 0.1)
        steps.append(Step(delay: 0.01, event: .finished(summary)))
        return steps
    }
}

/// A voice that answers each line with `seconds` of audio, or misbehaves as told for its next calls.
final class FakeVoiceClient: SpeechOutputClient, @unchecked Sendable {
    enum Behavior {
        case speak(seconds: TimeInterval)
        /// Opens the stream and never sends audio.
        case silent
        case fail(String)
    }

    let name: String
    let trace: VoiceTrace
    private let lock = NSLock()
    private var queue: [Behavior] = []
    private var standard: Behavior
    private var _spoken: [String] = []
    private var _voices: [String?] = []
    private var _stopAlls = 0
    private var _warmUps = 0

    init(name: String = "voice", trace: VoiceTrace, seconds: TimeInterval = 0.25) {
        self.name = name
        self.trace = trace
        standard = .speak(seconds: seconds)
    }

    /// The next calls behave like this, in order; then back to normal.
    func then(_ behaviors: Behavior...) { lock.withLock { queue += behaviors } }
    func always(_ behavior: Behavior) { lock.withLock { standard = behavior } }

    var spoken: [String] { lock.withLock { _spoken } }
    /// The voice name each line asked for.
    var voices: [String?] { lock.withLock { _voices } }
    var stopAlls: Int { lock.withLock { _stopAlls } }
    var warmUps: Int { lock.withLock { _warmUps } }

    func speak(_ text: String, voice: String?, instructions: String?) -> AsyncThrowingStream<SpeechEvent, Error> {
        let behavior: Behavior = lock.withLock {
            _spoken.append(text)
            _voices.append(voice)
            return queue.isEmpty ? standard : queue.removeFirst()
        }
        trace.add("\(name).speak:\(text)")
        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let task = Task {
            switch behavior {
            case .speak(let seconds):
                try? await Task.sleep(for: .milliseconds(10))
                let frames = Int(seconds * 24_000)
                let half = frames / 2
                continuation.yield(.audio(Data(count: half * 2), .speech24k))
                continuation.yield(.audio(Data(count: (frames - half) * 2), .speech24k))
                continuation.yield(.lineFinished)
                continuation.finish()
            case .silent:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                continuation.finish()
            case .fail(let message):
                try? await Task.sleep(for: .milliseconds(5))
                continuation.finish(throwing: ProviderError(provider: name, status: 503, message: message))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func warmUp() async { lock.withLock { _warmUps += 1 } }
    func stopAll() async { lock.withLock { _stopAlls += 1 } }
}

/// Moves a fake output's clock in real time (times `speed`) and polls the player, like a sound card would.
final class PlaybackClockDriver: @unchecked Sendable {
    let backend: FakeSpeechPlaybackBackend
    let player: SpeechPlayer
    private var task: Task<Void, Never>?

    init(speed: Double = 1) {
        backend = FakeSpeechPlaybackBackend(sampleRate: 24_000)
        player = SpeechPlayer(backend: backend, pollInterval: nil, idleTimeout: 3600)
        let backend = self.backend, player = self.player
        task = Task.detached {
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(4))
                let now = Date()
                backend.advance(seconds: now.timeIntervalSince(last) * speed)
                last = now
                player.poll()
            }
        }
    }

    deinit { task?.cancel() }
    func stop() { task?.cancel() }
}

/// Records every call the orchestrator makes on a drawing.
@MainActor
final class RecordingDrawing: TurnDrawing {
    let trace: VoiceTrace
    private(set) var options: DrawingBeginOptions?
    private(set) var program = ""
    var isDrawing = false
    var onMarks: (([DrawingMark]) -> Void)?

    init(trace: VoiceTrace) { self.trace = trace }

    func begin(_ options: DrawingBeginOptions) {
        self.options = options
        isDrawing = true
        trace.add("draw.begin:\(options.pace.rawValue)")
    }
    func append(_ text: String) {
        program += text
        trace.add("draw.append")
    }
    func end() { trace.add("draw.end") }
    func finishNow() { trace.add("draw.finishNow") }
    func cancel() {
        isDrawing = false
        trace.add("draw.cancel")
    }
    func clear() {
        isDrawing = false
        trace.add("draw.clear")
    }
    nonisolated func lineStarted(_ index: Int, expectedDuration: TimeInterval?) { trace.add("draw.lineStarted:\(index)") }
    nonisolated func lineFinished(_ index: Int) { trace.add("draw.lineFinished:\(index)") }
}

@MainActor
final class RecordingSurfaces: TurnDrawingSurfaces {
    let trace: VoiceTrace
    private(set) var drawings: [RecordingDrawing] = []
    private(set) var cleared = 0
    var visible = false

    init(trace: VoiceTrace) { self.trace = trace }

    func drawing(for screenshot: TurnScreenshot, image: CGImage?) -> (any TurnDrawing)? {
        let drawing = RecordingDrawing(trace: trace)
        drawings.append(drawing)
        visible = true
        return drawing
    }

    var hasVisibleDrawing: Bool { visible }

    func clearAll() {
        cleared += 1
        visible = false
        trace.add("surfaces.clear")
    }
}

/// A complete loop of fakes around a real `TurnOrchestrator`, `LineNarrator` and `SpeechPlayer`.
@MainActor
final class VoiceLoopRig {
    let trace = VoiceTrace()
    let brain: ScriptedBrain
    let voice: FakeVoiceClient
    let fallback: FakeVoiceClient
    let clock: PlaybackClockDriver
    let narrator: LineNarrator
    let microphone = SilentMicrophone(chunkDuration: 0.01)
    let screen: StillImageScreen
    let surfaces: RecordingSurfaces
    let orchestrator: TurnOrchestrator
    var stt: SimulatedSpeechToText
    private(set) var records: [TurnRecord] = []
    private(set) var displays: [TurnDisplay] = []
    private(set) var voiceEvents: [LineNarrator.Event] = []

    init(heard: String = "what does this button do", scripts: [[ScriptedBrain.Step]], voiceSeconds: TimeInterval = 0.25,
         policy: LineNarrator.Policy = LineNarrator.Policy(firstAudioTimeout: 2)) {
        brain = ScriptedBrain(trace: trace, scripts: scripts)
        voice = FakeVoiceClient(name: "voice", trace: trace, seconds: voiceSeconds)
        fallback = FakeVoiceClient(name: "apple", trace: trace, seconds: voiceSeconds)
        clock = PlaybackClockDriver()
        narrator = LineNarrator(voice: voice, fallback: fallback, player: clock.player, policy: policy)
        screen = StillImageScreen(imageData: StillImageScreen.blankCanvas(width: 320, height: 200), context: TurnContext(frontApp: "Safari"))
        surfaces = RecordingSurfaces(trace: trace)
        stt = SimulatedSpeechToText(text: heard, chunksPerWord: 1)
        var settings = TurnOrchestrator.Settings()
        // Generous: the whole suite runs in parallel and shares the main actor.
        settings.transcriptTimeout = 3
        let services = TurnOrchestrator.Services(microphone: microphone, speechToText: { SimulatedSpeechToText(text: "") },
                                                 screen: screen, brain: brain, narrator: narrator, drawings: surfaces)
        orchestrator = TurnOrchestrator(services: services, settings: settings)
        orchestrator.services.speechToText = { [unowned self] in self.stt }
        orchestrator.onTurnFinished = { [unowned self] record in self.records.append(record) }
        orchestrator.onDisplayChange = { [unowned self] display in self.displays.append(display) }
        orchestrator.onVoiceEvent = { [unowned self] event, _ in self.voiceEvents.append(event) }
    }

    /// Press, hold for `seconds`, let go.
    func ask(holding seconds: TimeInterval = 0.12) async {
        orchestrator.pressBegan()
        try? await Task.sleep(for: .seconds(seconds))
        orchestrator.pressEnded()
    }

    /// Waits (on the main actor, letting it run) until `condition` holds; false on timeout.
    @discardableResult
    func wait(_ timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func waitForRecords(_ count: Int, timeout: TimeInterval = 10) async -> Bool {
        await wait(timeout) { records.count >= count && !orchestrator.isBusy }
    }

    func started(_ index: Int) -> Bool {
        voiceEvents.contains { if case .lineStarted(index, _) = $0 { true } else { false } }
    }

    deinit { clock.stop() }
}
