import Foundation
import OpenClickyKit

/// `occtl history …`: the conversation history Home shows, and typed turns recorded into it.
enum HistoryCommands {
    static let usageText = """
        Usage:
          occtl history list [n]                 recent conversations
          occtl history show <session-id|latest> the turns of one conversation
          occtl history drawings [n]             recent replies that drew something
          occtl history search <words>           turns whose question or answer contain the words
          occtl history thumbnail <turn-id> <out.png>   re-render a turn's drawing with the drawing engine
          occtl history replay <turn-id|lesson-folder> <out-dir> [--every seconds]
                                                 replay a saved drawing offscreen at its lines' pace: a PNG frame
                                                 every 0.5 s (with the caption heard then) and the final frame
          occtl history chat [--config c.json] [--new] [--runtime [--state dir] [--tools list]] <question>
                                                 ask a typed question and record the turn. With --runtime it goes
                                                 through the brain runtime, as Home's chat does in the app (tools,
                                                 drawing, lookups; --tools as in occtl brain ask, default all;
                                                 sessions in --state); without, the stand-in text brain (active
                                                 skills included)
        History lives in \(HistoryStore.defaultDirectory.path)
        (set OPENCLICKY_HISTORY_DIR to use another folder).
        """

    /// `occtl history replay`: frames of a saved drawing played again, as Home's Drawings page shows it.
    static func replay(store: HistoryStore, args: [String]) async throws {
        var rest = args
        var every = 0.5
        if let at = rest.firstIndex(of: "--every"), rest.indices.contains(at + 1), let value = Double(rest[at + 1]), value > 0.05 {
            every = value
            rest.removeSubrange(at...(at + 1))
        }
        guard rest.count == 2 else { fail("Usage: occtl history replay <turn-id|lesson-folder> <out-dir> [--every seconds]") }
        let lessons = DrawingLessonStore(historyDirectory: store.directory)
        var folder = URL(fileURLWithPath: rest[0])
        if lessons.load(folder: folder) == nil { folder = lessons.folder(for: rest[0]) }
        guard let lesson = lessons.load(folder: folder) else { fail("No saved lesson for \(rest[0]) (turn \"Save drawings as lessons\" on).") }
        let screenshot = lessons.screenshot(folder: folder)
        let out = URL(fileURLWithPath: rest[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let report = try await MainActor.run { () throws -> String in
            let replay = try DrawingLessonReplay(lesson: lesson, screenshot: screenshot)
            var lines = ["lesson \(lesson.turnID): \(lesson.lines.count) line(s), canvas \(Int(lesson.canvas.width))×\(Int(lesson.canvas.height)), "
                         + (screenshot == nil ? "no screenshot" : "over its screenshot")]
            for (index, slot) in replay.schedule.enumerated() {
                lines.append(String(format: "  line %d at %.2f–%.2f s: %@", index, slot.start, slot.end, lesson.lines[index].text))
            }
            var t = 0.0, n = 0
            while t <= replay.duration + 0.01 {
                replay.advance(to: t)
                let name = String(format: "replay-%03d.png", n)
                try DrawingSnapshot.writePNG(try replay.frame(maxWidth: 960), to: out.appendingPathComponent(name))
                lines.append(String(format: "%@  t=%.2f s  %d mark(s)  caption: %@", name, t, replay.marks.count, replay.caption()?.text ?? "—"))
                t += every
                n += 1
            }
            replay.runToEnd()
            try DrawingSnapshot.writePNG(try replay.frame(), to: out.appendingPathComponent("replay-final.png"))
            lines.append(String(format: "replay-final.png  t=%.2f s  %d mark(s), done at %.2f s", replay.time, replay.marks.count, replay.finishedAt ?? -1))
            return lines.joined(separator: "\n")
        }
        try (report + "\n").write(to: out.appendingPathComponent("replay.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    static let history = OcctlCommand(name: "history", usage: "history <list|show|drawings|search|thumbnail|replay|chat>  conversations Home shows") { args in
        let store = HistoryStore(directory: directory)
        guard let verb = args.first else { fail(usageText) }
        let rest = Array(args.dropFirst())
        switch verb {
        case "list", "ls":
            let sessions = store.sessions(limit: Int(rest.first ?? "") ?? 20)
            if sessions.isEmpty { print("No conversations yet.") }
            for session in sessions {
                print("\(stamp(session.updatedAt))  \(session.id)  \(session.turnCount) turn\(session.turnCount == 1 ? "" : "s")"
                      + (session.drawingCount > 0 ? ", \(session.drawingCount) drawing\(session.drawingCount == 1 ? "" : "s")" : ""))
                print("    \(session.title.isEmpty ? "(no words)" : session.title)")
                if !session.preview.isEmpty { print("    → \(session.preview)") }
            }
        case "show":
            guard let reference = rest.first else { fail("Usage: occtl history show <session-id|latest>") }
            let id = reference == "latest" ? (store.sessions(limit: 1).first?.id ?? "") : reference
            let turns = try store.turns(in: id)
            if turns.isEmpty { fail("No conversation \(reference).") }
            for turn in turns { printTurn(turn) }
            let damaged = store.damagedLineCount(in: id)
            if damaged > 0 { print("(\(damaged) unreadable line\(damaged == 1 ? "" : "s") skipped)") }
        case "drawings":
            let drawings = store.recentDrawings(limit: Int(rest.first ?? "") ?? 12)
            if drawings.isEmpty { print("No drawings yet.") }
            for drawing in drawings {
                print("\(stamp(drawing.createdAt))  turn \(drawing.turnID)  \(drawing.title)  (\(drawing.program.count) chars of program)")
                if let folder = drawing.lessonFolder { print("    lesson: \(folder.path)") }
            }
        case "search":
            let hits = store.search(rest.joined(separator: " "))
            if hits.isEmpty { print("Nothing matches.") }
            for turn in hits { printTurn(turn) }
        case "thumbnail":
            guard rest.count == 2 else { fail("Usage: occtl history thumbnail <turn-id> <out.png>") }
            guard let turn = store.recentTurns(limit: 10_000).first(where: { $0.id == rest[0] }), let program = turn.program else {
                fail("No turn \(rest[0]) with a drawing.")
            }
            let output = URL(fileURLWithPath: rest[1])
            let summary = try await MainActor.run { () throws -> String in
                let thumbnailer = DrawingThumbnailer(cacheDirectory: nil, pixelWidth: 640)
                let image = try thumbnailer.thumbnail(for: program, canvas: turn.canvas)
                try DrawingSnapshot.writePNG(image, to: output)
                return "Wrote \(output.path) (\(image.width)x\(image.height))."
            }
            print(summary)
        case "replay":
            try await replay(store: store, args: rest)
        case "chat":
            try await chat(store: store, args: rest)
        default:
            fail(usageText)
        }
    }

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["OPENCLICKY_HISTORY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return HistoryStore.defaultDirectory
    }

    static func chat(store: HistoryStore, args: [String]) async throws {
        var configPath: String?
        var fresh = false
        var useRuntime = false
        var statePath: String?
        var tools = "all"
        var words: [String] = []
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--config": configPath = value("--config")
            case "--new": fresh = true
            case "--runtime": useRuntime = true
            case "--state": statePath = value("--state")
            case "--tools": tools = value("--tools")
            default: words.append(args[index])
            }
            index += 1
        }
        let question = words.joined(separator: " ")
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("Usage: occtl history chat [--config c.json] [--new] [--runtime [--state dir] [--tools list]] <question>")
        }
        let config = try EngineCommands.loadConfig(configPath)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let brain: any BrainTurnRunning
        var notes: [String] = []
        var runtime: BrainRuntime?
        if useRuntime {
            let state = BrainSessionStore(root: statePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? BrainSessionStore.defaultRoot)
            let wiring = BrainCommands.wiring(tools: tools, factory: factory, dialect: try factory.resolve(.brain).provider?.dialect,
                                              memoryDirectory: state.root.appendingPathComponent("memory", isDirectory: true),
                                              services: nil, hostedSearch: false, connectors: nil)
            let made = try BrainCommands.runtime(factory: factory, wiring: wiring, store: state)
            runtime = made
            brain = made
            notes = [TypedChatController.homeWindowNote]
            print("brain runtime, session \(await made.currentSessionID()); tools: \(wiring.tools().names.joined(separator: ", "))")
        } else {
            let skills = SkillsCommands.library()
            brain = try StandInTextBrain.forBrainSlot(factory) { [skills.skillsPromptSection()] }
        }
        let chat = TypedChatController(brain: brain, history: store)
        if fresh { await chat.startNewConversation() }
        let turn = await chat.send(question, appNotes: notes) { event in
            switch event {
            case .sayLine(let index, let text): print("  say \(index): \(text)")
            case .toolStarted(let name, _): print("  tool: \(name)")
            case .deferredAction(let action): print("  after the answer: \(action.name)")
            case .failed(let spoken, let detail): print("  failed: \(spoken) (\(detail))")
            default: break
            }
        }
        await runtime?.waitForBackgroundWork()
        let timing = [turn.timings.modelFirstTokenMs.map { "first token \($0) ms" }, turn.timings.firstLineMs.map { "first line \($0) ms" },
                      turn.timings.totalMs.map { "total \($0) ms" }].compactMap { $0 }.joined(separator: ", ")
        print("Recorded turn \(turn.id) in session \(turn.sessionID) (\(turn.outcome.rawValue); \(turn.model ?? "?"); \(timing)).")
    }

    static func printTurn(_ turn: HistoryTurn) {
        let source = turn.source == .text ? "typed" : turn.source.rawValue
        print("\(stamp(turn.startedAt))  [\(source)] \(turn.words.isEmpty ? "(\(turn.trigger ?? "no words"))" : turn.words)")
        for (index, line) in turn.spokenLines.enumerated() { print("    say \(index): \(line)") }
        if turn.outcome != .completed { print("    \(turn.outcome.rawValue)\(turn.errorDetail.map { ": \($0)" } ?? "")") }
        if let program = turn.program { print("    drew \(program.split(separator: "\n").count) line(s) of program") }
        if !turn.tools.isEmpty { print("    tools: \(turn.tools.joined(separator: ", "))") }
        if let narration = turn.narration { print("    narration: \(narration)") }
        var timing: [String] = []
        if let ms = turn.timings.firstLineMs { timing.append("first line \(ms) ms") }
        if let ms = turn.timings.totalMs { timing.append("total \(ms) ms") }
        if !timing.isEmpty { print("    \(timing.joined(separator: ", "))\(turn.model.map { ", \($0)" } ?? "")  id \(turn.id)") }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
