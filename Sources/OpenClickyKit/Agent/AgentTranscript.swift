import Foundation

/// A job's conversation rebuilt from its files: one turn per run, with what was asked, what the agent said and
/// thought along the way, the steps it took, the files it touched, how it ended and what it suggested next.
///
/// Built only from `job.json` and `events.jsonl`, so it reads the same after a relaunch as while the job ran. Home →
/// Agents shows it, and the brain's `read_job` (detail conversation) reads the same turns.
public struct AgentTranscript: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case message, thinking, tool, file, approval, error, note }
        public var kind: Kind
        public var text: String
        public var at: Date

        public init(kind: Kind, text: String, at: Date) {
            self.kind = kind
            self.text = text
            self.at = at
        }
    }

    public struct Turn: Sendable, Hashable, Identifiable {
        /// 1-based run number.
        public var number: Int
        public var ask: String
        public var startedAt: Date
        public var finishedAt: Date?
        public var outcome: AgentTurnOutcome?
        /// What the run said along the way, in order: messages, reasoning headings, tool steps, files, approvals, errors.
        public var steps: [Step]
        /// The latest plan of the run.
        public var plan: [AgentPlanStep]
        /// Files touched, in the order first touched (absolute paths), with their last change.
        public var files: [AgentTranscriptFile]
        /// The final report's body, spoken line and next steps.
        public var report: AgentFinalReport?
        public var error: String?
        /// The routine that started the run, if any.
        public var routineID: String?

        public var id: Int { number }
        public var messages: [String] { steps.filter { $0.kind == .message }.map(\.text) }
        public var reasoning: [String] { steps.filter { $0.kind == .thinking }.map(\.text) }
        public var toolSteps: [String] { steps.filter { $0.kind == .tool }.map(\.text) }
        public var suggestedNext: [String] { report?.nextSteps ?? [] }
    }

    public var jobID: String
    public var turns: [Turn]

    public init(jobID: String, turns: [Turn]) {
        self.jobID = jobID
        self.turns = turns
    }

    /// The most steps one turn keeps (the newest); older ones are counted in a note.
    public static let maxStepsPerTurn = 400

    /// Folds a job's log into turns. Runs come from the record (ask, times, outcome); events go to the run whose marker
    /// (written when a run starts) came last, and a finished turn moves on to the next run, so logs from before the
    /// markers existed split the same way. A harness restarted after a crash writes its run's marker again. A run
    /// without events (its log was cleaned up) keeps its ask and spoken result.
    public static func build(record: AgentJobRecord, entries: [AgentLogEntry]) -> AgentTranscript {
        // Whole seconds, as job.json and events.jsonl store them, so a record read back after a relaunch gives the same turns
        // as the one in memory.
        func second(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        var turns: [Turn] = record.runs.enumerated().map { index, run in
            Turn(number: index + 1, ask: run.ask, startedAt: second(run.startedAt), finishedAt: run.finishedAt.map(second), outcome: run.outcome, steps: [],
                 plan: [], files: [], report: nil, error: nil, routineID: run.routineID)
        }
        var current = 0
        var dropped: [Int: Int] = [:]
        func ensure(_ index: Int, at time: Date) {
            while turns.count <= index {
                turns.append(Turn(number: turns.count + 1, ask: "", startedAt: time, finishedAt: nil, outcome: nil, steps: [], plan: [],
                                  files: [], report: nil, error: nil, routineID: nil))
            }
        }
        func add(_ kind: Step.Kind, _ text: String, at time: Date) {
            ensure(current, at: time)
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Streaming harnesses repeat a line; keep it once.
            if let last = turns[current].steps.last, last.kind == kind, last.text == text { return }
            turns[current].steps.append(Step(kind: kind, text: text, at: time))
            if turns[current].steps.count > maxStepsPerTurn {
                turns[current].steps.removeFirst()
                dropped[current, default: 0] += 1
            }
        }
        for entry in entries {
            if entry.kind == runKind {
                current = max(0, (entry.id.flatMap(Int.init) ?? (current + 1)) - 1)
                ensure(current, at: entry.t)
                if turns[current].ask.isEmpty, let ask = entry.text { turns[current].ask = ask }
                continue
            }
            switch entry.kind {
            case "commentary": add(.message, AgentText.stripCitations(entry.text ?? ""), at: entry.t)
            case "thinking": add(.thinking, entry.text ?? "", at: entry.t)
            case "progress": add(.tool, entry.text ?? "", at: entry.t)
            case "plan":
                ensure(current, at: entry.t)
                turns[current].plan = entry.plan ?? []
            case "file":
                guard let path = entry.path else { continue }
                ensure(current, at: entry.t)
                let change = entry.change ?? "changed"
                if let index = turns[current].files.firstIndex(where: { $0.path == path }) {
                    turns[current].files[index].change = change
                } else {
                    turns[current].files.append(AgentTranscriptFile(path: path, change: change))
                }
                add(.file, "\(change.capitalized) \(URL(fileURLWithPath: path).lastPathComponent)", at: entry.t)
            case "approval_requested":
                if let request = entry.request { add(.approval, "Asked: \(request.summary)", at: entry.t) }
            case "error":
                if entry.fatal ?? true, let text = entry.text { add(.error, text, at: entry.t) }
            case "compacted":
                add(.note, "Compacted its conversation to keep going", at: entry.t)
            case "turn_finished":
                ensure(current, at: entry.t)
                if let text = entry.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns[current].report = AgentFinalReport.parse(text, now: entry.t)
                }
                if let error = entry.change {
                    turns[current].error = error
                    add(.error, error, at: entry.t)
                }
                if turns[current].finishedAt == nil { turns[current].finishedAt = entry.t }
                if turns[current].outcome == nil { turns[current].outcome = entry.outcome }
                // What follows belongs to the next run (its marker, when there is one, says which).
                current += 1
            default:
                continue
            }
        }
        for (index, count) in dropped where index < turns.count {
            turns[index].steps.insert(Step(kind: .note, text: "\(count) earlier steps left out", at: turns[index].startedAt), at: 0)
        }
        // The latest run's report lives in the record too (and survives a cleaned-up log).
        if let last = turns.indices.last, turns[last].report == nil, let report = record.report, record.runs.last?.finishedAt != nil {
            turns[last].report = report
        }
        for index in turns.indices where turns[index].report == nil {
            if index < record.runs.count, let spoken = record.runs[index].spoken, !spoken.isEmpty {
                turns[index].report = AgentFinalReport(markdown: "", spoken: spoken)
            }
        }
        if let last = turns.indices.last, turns[last].error == nil, record.status == .failed { turns[last].error = record.error }
        return AgentTranscript(jobID: record.id, turns: turns)
    }

    static let runKind = "run"

    /// The text for a job list row: the latest run's spoken result, else its latest message, else what was asked.
    public var preview: String? {
        guard let turn = turns.last else { return nil }
        if let spoken = turn.report?.spoken, !spoken.isEmpty { return AgentText.shorten(spoken, limit: 160) }
        if let message = turn.messages.last { return AgentText.firstLine(message, limit: 160) }
        return turn.ask.isEmpty ? nil : AgentText.firstLine(turn.ask, limit: 160)
    }

    /// The conversation as JSON lines for the brain (`read_job` detail conversation): the asks, what the agent said
    /// and did, and each run's report, newest last, within `limit` entries.
    public func brainLines(limit: Int = 80) -> [JSONValue] {
        var lines: [JSONValue] = []
        for turn in turns {
            lines.append(.string("ask (run \(turn.number)): \(AgentText.shorten(turn.ask, limit: 400))"))
            for step in turn.steps {
                switch step.kind {
                case .message: lines.append(.string("commentary: \(AgentText.shorten(step.text, limit: 300))"))
                case .thinking: lines.append(.string("thinking: \(AgentText.shorten(step.text, limit: 200))"))
                case .tool: lines.append(.string("progress: \(AgentText.shorten(step.text, limit: 200))"))
                case .file: lines.append(.string("file: \(step.text)"))
                case .approval: lines.append(.string(step.text))
                case .error: lines.append(.string("error: \(AgentText.shorten(step.text, limit: 300))"))
                case .note: continue
                }
            }
            if let report = turn.report {
                let body = report.markdown.isEmpty ? report.spoken : report.markdown
                var line = "final: \(AgentText.shorten(body, limit: 1_500))"
                if !report.nextSteps.isEmpty { line += "\nsuggested next: \(report.nextSteps.joined(separator: " | "))" }
                lines.append(.string(line))
            } else if let error = turn.error {
                lines.append(.string("ended: \(AgentText.shorten(error, limit: 300))"))
            }
        }
        return Array(lines.suffix(limit))
    }
}

/// A file a turn touched and its last change ("created", "changed", "deleted").
public struct AgentTranscriptFile: Sendable, Hashable {
    public var path: String
    public var change: String

    public init(path: String, change: String) {
        self.path = path
        self.change = change
    }
}

extension AgentLogEntry {
    /// The marker written when a run starts: its number and what was asked.
    public init(runStarted number: Int, ask: String, at time: Date) {
        t = time
        kind = AgentTranscript.runKind
        text = ask
        id = String(number)
    }
}

extension AgentJobStore {
    /// Logs that run `number` started with `ask`, so the transcript can tell runs apart.
    public func appendRun(number: Int, ask: String, to record: AgentJobRecord, at time: Date = Date()) {
        appendEntry(AgentLogEntry(runStarted: number, ask: ask, at: time), to: record)
    }

    /// Every log entry of a job (the whole log; `events(of:limit:)` keeps only the tail).
    public func allEvents(of record: AgentJobRecord) -> [AgentLogEntry] {
        events(of: record, limit: Int.max)
    }

    /// The job's transcript as its files have it now.
    public func transcript(of record: AgentJobRecord) -> AgentTranscript {
        AgentTranscript.build(record: record, entries: allEvents(of: record))
    }
}
