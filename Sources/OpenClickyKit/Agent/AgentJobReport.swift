import Foundation

/// A finished run, compact enough to hand to the brain for a report turn ("tell the user it came back").
public struct AgentJobReport: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case done
        /// Finished, but the agent asked the user something.
        case needsYou = "needs-you"
        case failed, stopped
    }

    public var id: String { "\(jobID)#\(run)" }
    public var jobID: String
    /// 1-based run number within the job.
    public var run: Int
    public var title: String
    public var agentName: String?
    public var outcome: Outcome
    /// One or two sentences the voice can say as is.
    public var spoken: String
    /// The full report for the result card.
    public var markdown: String
    /// Deliverables (absolute paths or URLs), most important first.
    public var files: [String]
    public var nextSteps: [String]
    public var question: String?
    public var error: String?
    public var routineID: String?
    public var startedAt: Date
    public var finishedAt: Date
    /// What the run mainly produced (the card's icon).
    public var kind: AgentDeliverableKind?
    /// The structured answer for the card (`<answer>`).
    public var answer: AgentAnswer?
    /// A step the user has to do before the job goes on (`<wait_for>`).
    public var userStep: AgentUserStep?
    /// Routines the job proposed, waiting for the user's yes (`<routine>`).
    public var routineProposals: [AgentRoutineRequest]?
    /// The request id that answers `routineProposals` (`AgentManager.answer`); an answer without it goes to the step.
    public var routineRequestID: String?
    /// How-tos the job reported learning (`<learned>`).
    public var learned: [AgentLearnedHowTo]?

    public init(jobID: String, run: Int, title: String, agentName: String? = nil, outcome: Outcome, spoken: String, markdown: String = "",
                files: [String] = [], nextSteps: [String] = [], question: String? = nil, error: String? = nil, routineID: String? = nil,
                startedAt: Date, finishedAt: Date) {
        self.jobID = jobID
        self.run = run
        self.title = title
        self.agentName = agentName
        self.outcome = outcome
        self.spoken = spoken
        self.markdown = markdown
        self.files = files
        self.nextSteps = nextSteps
        self.question = question
        self.error = error
        self.routineID = routineID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var durationSeconds: Int { Int(finishedAt.timeIntervalSince(startedAt).rounded()) }

    /// Builds the report for the latest run of a job.
    public static func make(record: AgentJobRecord, outputs: [String], finishedAt: Date = Date()) -> AgentJobReport {
        let run = record.runs.last
        let report = record.report
        let outcome: Outcome = switch record.status {
        case .stopped: .stopped
        case .failed: .failed
        case .needsYou: .needsYou
        default: .done
        }
        var files = report?.resolvedFiles(in: record.folder).map { $0.isFileURL ? $0.path : $0.absoluteString } ?? []
        if files.isEmpty {
            files = outputs.prefix(8).map { record.folder.appendingPathComponent($0).path }
        }
        let spoken: String = {
            switch outcome {
            case .stopped:
                // OpenClicky stopped it at a limit: say why rather than "I stopped it".
                if let reason = record.error { return "\(record.title) stopped early: \(AgentText.firstSentence(reason, limit: 160))" }
                return report?.spoken.nilIfEmpty ?? "I stopped \(record.title) before it finished."
            case .failed: return "\(record.title) didn't work out: \(AgentText.firstSentence(record.error ?? "the agent stopped with an error", limit: 160))"
            default: return report?.spoken.nilIfEmpty ?? "\(record.title) is done."
            }
        }()
        var made = AgentJobReport(
            jobID: record.id, run: max(1, record.runs.count), title: report?.title ?? record.title,
            agentName: record.agentName, outcome: outcome, spoken: spoken, markdown: report?.markdown ?? "",
            files: files, nextSteps: report?.nextSteps ?? [], question: report?.question, error: record.error,
            routineID: run?.routineID, startedAt: run?.startedAt ?? record.createdAt, finishedAt: run?.finishedAt ?? finishedAt)
        made.kind = outcome == .done || outcome == .needsYou ? record.deliverableKind : nil
        if outcome == .done || outcome == .needsYou {
            made.answer = report?.answer
            made.userStep = record.waitingStep
            made.routineProposals = record.pendingRoutines
            made.routineRequestID = AgentManager.isRoutineConfirmation(record.pendingRequest?.id) ? record.pendingRequest?.id : nil
            made.learned = report?.learned
        }
        return made
    }

    /// The compact JSON object the brain receives (tool results and report-turn notes).
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "job_id": .string(jobID), "title": .string(title), "outcome": .string(outcome.rawValue),
            "say": .string(spoken), "seconds": .number(Double(durationSeconds)),
        ]
        if let agentName { object["agent"] = .string(agentName) }
        if !files.isEmpty { object["files"] = .array(files.map { .string($0) }) }
        if !nextSteps.isEmpty { object["next"] = .array(nextSteps.map { .string($0) }) }
        if let question { object["question"] = .string(question) }
        if let error, outcome == .failed { object["error"] = .string(AgentText.shorten(error, limit: 300)) }
        if let routineID { object["routine_id"] = .string(routineID) }
        if let kind { object["kind"] = .string(kind.rawValue) }
        if let step = userStep {
            var value: [String: JSONValue] = ["step": .string(step.step)]
            if let page = step.page { value["page"] = .string(page) }
            object["user_step"] = .object(value)
        }
        if let proposals = routineProposals, !proposals.isEmpty {
            object["routine_proposal"] = .string(proposals.map(\.summary).joined(separator: "; "))
        }
        if let outcome = answer?.outcome { object["answer"] = .string(outcome) }
        return .object(object)
    }
}

/// The note that starts a report turn: background jobs came back, and the brain should tell the user.
public enum AgentReportTurn {
    /// App-note text for one or more finished jobs. The brain answers with one short spoken line per job and a
    /// `show_result` call for the ones worth a card.
    public static func note(for reports: [AgentJobReport]) -> String {
        let lines = reports.map { $0.json.jsonString() }.joined(separator: "\n")
        let count = reports.count == 1 ? "A background job" : "\(reports.count) background jobs"
        return """
        [Jobs came back] \(count) finished while the user was busy. For each one, say one short line built from its \
        "say" text (in your own voice, no file paths or links). Call show_result with its job_id when it produced \
        files or a report worth seeing. If one has a "question", ask it. If one has a "user_step", tell the user what to \
        do and that they can say when it's done (answer it with sessions_answer_request). If one has a \
        "routine_proposal", ask whether to set it up. If one failed, say so plainly.
        \(lines)
        """
    }

    /// What the jobs in report notes said, joined for a notice: used when the brain couldn't tell them.
    public static func fallbackText(notes: [String]) -> String? {
        var said: [String] = []
        for note in notes {
            for line in note.split(separator: "\n") where line.hasPrefix("{") {
                guard let json = try? JSONValue.parse(String(line)), let say = json["say"]?.stringValue, !say.isEmpty else { continue }
                said.append(say)
            }
        }
        guard !said.isEmpty else { return nil }
        return AgentText.shorten(said.joined(separator: " "), limit: 280)
    }
}

/// Collects finished runs that arrive close together so the brain hears about them in one report turn.
public actor AgentReportBatcher {
    private let delay: TimeInterval
    private var waiting: [AgentJobReport] = []
    private var flushTask: Task<Void, Never>?
    private let deliver: @Sendable ([AgentJobReport]) async -> Void

    /// `deliver` gets each batch, at least `delay` seconds after the first report of the batch arrived.
    public init(delay: TimeInterval = 1.5, deliver: @escaping @Sendable ([AgentJobReport]) async -> Void) {
        self.delay = delay
        self.deliver = deliver
    }

    public func add(_ report: AgentJobReport) {
        waiting.removeAll { $0.jobID == report.jobID }
        waiting.append(report)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, delay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.flush()
        }
    }

    public func flush() async {
        flushTask = nil
        let batch = waiting
        waiting.removeAll()
        if !batch.isEmpty { await deliver(batch) }
    }
}
