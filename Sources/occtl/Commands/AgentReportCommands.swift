import Foundation
import OpenClickyKit

/// `occtl agent-report`: tells a finished job's result the way the app does, headlessly. The job's report becomes a
/// report turn (`AgentReportTurn.note`) for the configured brain with the agent tools; the voice is written to a WAV
/// file; a `show_result` call prints the result card the app would show (with its next-step chips).
enum AgentReportCommands {
    static let help = """
    Usage: occtl agent-report <job-id|agent> --out-dir <dir> [--config c.json] [--no-voice]
      Runs the report turn for the job's latest run: the brain says what came back (voice in <dir>/voice.wav) and may
      show its result card (printed, and saved as <dir>/card.txt). Writes <dir>/report-turn.txt with every step.
    """

    static let command = OcctlCommand(name: "agent-report", usage: "agent-report <job-id> --out-dir d [--config c]  tell a finished job's result as a report turn") { args in
        if args.isEmpty || args.contains("--help") || args.contains("-h") { print(help); return }
        var positional: [String] = []
        var config: String?
        var outDir: String?
        var voice = true
        var index = 0
        while index < args.count {
            let arg = args[index]
            func value() -> String {
                index += 1
                guard index < args.count else { fail("\(arg) needs a value.") }
                return args[index]
            }
            switch arg {
            case "--config": config = value()
            case "--out-dir": outDir = value()
            case "--no-voice": voice = false
            default:
                if arg.hasPrefix("--") { fail("Unknown option \(arg)\n\(help)") }
                positional.append(arg)
            }
            index += 1
        }
        guard let reference = positional.first, let outDir else { fail(help) }
        try await run(reference: reference, config: config, out: URL(fileURLWithPath: outDir, isDirectory: true), voice: voice)
    }

    @MainActor
    static func run(reference: String, config path: String?, out: URL, voice: Bool) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = AgentJobStore()
        // Tools only read and show here; nothing is launched.
        let manager = AgentManager(store: store) { _ in throw AgentManagerError.configuration("occtl agent-report doesn't start jobs.") }
        guard let record = await manager.job(reference) else { fail(AgentManagerError.unknownJob(reference).description) }
        guard !record.status.isActive || record.status == .needsYou else { fail("\(record.id) is still working.") }
        let report = AgentJobReport.make(record: record, outputs: store.outputs(of: record))

        let config = try EngineCommands.loadConfig(path, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let runtime = try TurnCommands.makeBrain(factory: factory, stateRoot: out.appendingPathComponent("brain", isDirectory: true), tools: "none",
                                                 figures: false, fresh: true)
        var transcript: [String] = []
        let started = Date()
        func note(_ text: String) {
            let line = String(format: "%7.3fs  ", Date().timeIntervalSince(started)) + text
            transcript.append(line)
            print(line)
        }
        let cards = CardBox()
        let tools = AgentTools(manager: manager, presentResult: { report in cards.add(AgentResultCard(report: report)) })
        var registry = ToolRegistry()
        registry.register(contentsOf: ToolRegistry.agentTools(tools))
        await runtime.update(tools: registry)

        let wavURL = out.appendingPathComponent("voice.wav")
        let speakers = try OfflineSpeakers(url: wavURL)
        var narrator: LineNarrator?
        if voice {
            let fallback = AppleSpeechSynthesisClient(context: ProviderContext(provider: ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis), apiKey: nil))
            narrator = LineNarrator(voice: (try? factory.speechOutput()) ?? fallback, fallback: fallback, player: speakers.player)
        }
        let jobs = await manager.jobs()
        let screen = AgentContextScreen(base: StillImageScreen(imageData: StillImageScreen.blankCanvas()), assets: nil,
                                        context: { AgentBrainContext.note(jobs: jobs, running: []) })
        let services = TurnOrchestrator.Services(microphone: nil, speechToText: { throw EngineFactoryError.slotEmpty(.stt) }, screen: screen,
                                                 brain: runtime, narrator: narrator, drawings: nil)
        let orchestrator = TurnOrchestrator(services: services)
        var records: [TurnRecord] = []
        var undelivered = false
        orchestrator.onTurnFinished = { records.append($0) }
        orchestrator.onReportUndelivered = { _ in undelivered = true }
        orchestrator.onLog = { note($0) }
        var lastLines = 0
        orchestrator.onDisplayChange = { display in
            for line in display.lines.dropFirst(lastLines) { note("brain line: \(line)") }
            lastLines = display.lines.count
            if let notice = display.notice { note("notice: \(notice.title)") }
        }

        let resolution = try factory.resolve(.brain)
        note("job \(record.id) · \(report.outcome.rawValue) · say: \(report.spoken)")
        note("brain: \(resolution.selection.provider) / \(resolution.selection.model)")
        speakers.start()
        let reportNote = AgentReportTurn.note(for: [report])
        orchestrator.runReportTurn(note: reportNote)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if !orchestrator.isBusy, !records.isEmpty, undelivered || records.last?.history?.spokenLines.isEmpty == false { break }
            if !orchestrator.isBusy, records.count > TurnOrchestrator.reportRetries { break }
        }
        try await Task.sleep(for: .milliseconds(500))
        let seconds = speakers.seconds
        try speakers.finish()
        for (index, record) in records.enumerated() {
            note("turn \(index + 1): \(record.outcome.label), lines: \(record.history?.spokenLines ?? [])")
            for action in record.deferred { note("deferred \(action.action.name): \(action.succeeded.map { $0 ? "done" : "failed" } ?? "dropped")") }
            if let seconds = record.timings.originToFirstLineHeardMs { note("first line heard after \(seconds) ms") }
        }
        if undelivered { note("the report didn't land after a retry; the app would show the jobs panel") }
        var cardText = ""
        for card in cards.all {
            cardText += """
            [\(card.symbol)] \(card.title)
            \(card.subtitle)
            \(card.summary)

            \(card.body)

            files: \(card.files.map(\.name).joined(separator: ", "))
            chips: \(card.chips.map { "[\($0)]" }.joined(separator: " "))
            \(card.question.map { "question: \($0)" } ?? "")

            """
        }
        if !cardText.isEmpty {
            print("\n— result card —\n" + cardText)
            try cardText.write(to: out.appendingPathComponent("card.txt"), atomically: true, encoding: .utf8)
        }
        note(String(format: "voice: %.2f s written to %@", seconds, wavURL.path))
        let text = (["note sent to the brain:", reportNote, ""] + transcript).joined(separator: "\n") + "\n"
        try text.write(to: out.appendingPathComponent("report-turn.txt"), atomically: true, encoding: .utf8)
    }

    final class CardBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cards: [AgentResultCard] = []
        var all: [AgentResultCard] { lock.withLock { cards } }
        func add(_ card: AgentResultCard) { lock.withLock { cards.append(card) } }
    }
}
