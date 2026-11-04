import Foundation

// The conversation history OpenClicky keeps on the Mac: sessions, and the turns in them with the user's words, the
// spoken lines, the drawing program and timings. The on-disk format is documented in docs/history.md.

/// How a turn started.
public enum HistoryTurnSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// The user held the talk keys and spoke.
    case voice
    /// The user typed into the Home chat or the text box.
    case text
    /// OpenClicky started the turn itself (a job came back, a tour step, a click on a drawn target).
    case app
}

/// How a turn ended.
public enum HistoryTurnOutcome: String, Codable, Sendable, Hashable {
    case completed
    case failed
    /// A newer turn or the user stopped it before the brain finished.
    case cancelled
}

/// Milliseconds from the moment the turn was handed to the brain. Missing values never happened.
public struct HistoryTimings: Codable, Sendable, Hashable {
    /// First status, program text or line, whichever came first.
    public var firstEventMs: Int?
    /// First drawing-program text.
    public var firstProgramMs: Int?
    /// First complete spoken line.
    public var firstLineMs: Int?
    /// The model's own first token, as the brain reported it.
    public var modelFirstTokenMs: Int?
    /// Until `finished` or `failed`.
    public var totalMs: Int?

    public init(firstEventMs: Int? = nil, firstProgramMs: Int? = nil, firstLineMs: Int? = nil, modelFirstTokenMs: Int? = nil,
                totalMs: Int? = nil) {
        self.firstEventMs = firstEventMs
        self.firstProgramMs = firstProgramMs
        self.firstLineMs = firstLineMs
        self.modelFirstTokenMs = modelFirstTokenMs
        self.totalMs = totalMs
    }
}

/// Token counts for a turn, when the provider reported them.
public struct HistoryUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var cached: Int
    public var output: Int

    public init(input: Int = 0, cached: Int = 0, output: Int = 0) {
        self.input = input
        self.cached = cached
        self.output = output
    }

    public init(_ usage: TokenUsage) {
        self.init(input: usage.inputTokens, cached: usage.cachedInputTokens, output: usage.outputTokens)
    }
}

/// The size of the canvas a drawing program was written for, so it can be replayed at the same proportions.
public struct HistoryCanvas: Codable, Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// One user turn and everything that came back.
public struct HistoryTurn: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String
    public var startedAt: Date
    public var source: HistoryTurnSource
    /// What the user said or typed. Empty for app-started turns.
    public var words: String
    /// Why an app-started turn began ("job_report", "tour", …).
    public var trigger: String?
    /// "[App] …" notes the brain saw before the words.
    public var appNotes: [String]
    /// The front app when the user asked, for context in the list.
    public var frontApp: String?
    /// say() lines in order, as the voice spoke them.
    public var spokenLines: [String]
    /// The whole drawing program (fences stripped); nil when the reply drew nothing.
    public var program: String?
    public var canvas: HistoryCanvas?
    /// Status words shown while tools ran ("Searching the web").
    public var statuses: [String]
    /// Tool names in the order they started.
    public var tools: [String]
    /// Names of actions held until the narration finished.
    public var deferredActions: [String]
    public var outcome: HistoryTurnOutcome
    /// For failed turns: the sentence said aloud, and the detail for the log.
    public var errorSpoken: String?
    public var errorDetail: String?
    /// What happened to the narration afterwards ("cut off by the user after line 2"), from `recordOutcome`.
    public var narration: String?
    public var model: String?
    public var rounds: Int
    public var usage: HistoryUsage?
    public var timings: HistoryTimings

    public init(id: String = UUID().uuidString, sessionID: String, startedAt: Date, source: HistoryTurnSource, words: String,
                trigger: String? = nil, appNotes: [String] = [], frontApp: String? = nil, spokenLines: [String] = [],
                program: String? = nil, canvas: HistoryCanvas? = nil, statuses: [String] = [], tools: [String] = [],
                deferredActions: [String] = [], outcome: HistoryTurnOutcome = .completed, errorSpoken: String? = nil,
                errorDetail: String? = nil, narration: String? = nil, model: String? = nil, rounds: Int = 0,
                usage: HistoryUsage? = nil, timings: HistoryTimings = HistoryTimings()) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.source = source
        self.words = words
        self.trigger = trigger
        self.appNotes = appNotes
        self.frontApp = frontApp
        self.spokenLines = spokenLines
        self.program = program
        self.canvas = canvas
        self.statuses = statuses
        self.tools = tools
        self.deferredActions = deferredActions
        self.outcome = outcome
        self.errorSpoken = errorSpoken
        self.errorDetail = errorDetail
        self.narration = narration
        self.model = model
        self.rounds = rounds
        self.usage = usage
        self.timings = timings
    }

    /// The reply as one paragraph: the spoken lines, or the error sentence for a failed turn.
    public var replyText: String {
        if !spokenLines.isEmpty { return spokenLines.joined(separator: " ") }
        return errorSpoken ?? ""
    }

    /// Whether the reply drew something worth replaying: its program does more than speak (a typed answer in Home is
    /// often only `step()` and `say()` lines, which would make an empty thumbnail).
    public var hasDrawing: Bool {
        guard let program else { return false }
        return Self.programDraws(program)
    }

    /// Whether a drawing program makes marks: any call other than `say("…")`, `step(n)` and comments.
    public static func programDraws(_ program: String) -> Bool {
        // Spoken lines go first, so a "//" inside one (a link) isn't taken for a comment.
        var rest = program.replacingOccurrences(of: #"say\(\s*"(?:[^"\\]|\\.)*"\s*\)\s*;?"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"say\(\s*'(?:[^'\\]|\\.)*'\s*\)\s*;?"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"//[^\n]*"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"\bstep\(\s*[0-9]*\s*\)\s*;?"#, with: "", options: .regularExpression)
        return rest.range(of: #"[A-Za-z_][A-Za-z0-9_\.]*\s*\("#, options: .regularExpression) != nil
    }

    // Older or newer files may lack fields; every optional collection defaults to empty.
    private enum CodingKeys: String, CodingKey {
        case id, sessionID = "session", startedAt = "at", source, words, trigger, appNotes, frontApp, spokenLines = "lines",
             program, canvas, statuses, tools, deferredActions, outcome, errorSpoken, errorDetail, narration, model, rounds,
             usage, timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        source = (try? c.decode(HistoryTurnSource.self, forKey: .source)) ?? .voice
        words = try c.decodeIfPresent(String.self, forKey: .words) ?? ""
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        appNotes = try c.decodeIfPresent([String].self, forKey: .appNotes) ?? []
        frontApp = try c.decodeIfPresent(String.self, forKey: .frontApp)
        spokenLines = try c.decodeIfPresent([String].self, forKey: .spokenLines) ?? []
        program = try c.decodeIfPresent(String.self, forKey: .program)
        canvas = try c.decodeIfPresent(HistoryCanvas.self, forKey: .canvas)
        statuses = try c.decodeIfPresent([String].self, forKey: .statuses) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        deferredActions = try c.decodeIfPresent([String].self, forKey: .deferredActions) ?? []
        outcome = (try? c.decode(HistoryTurnOutcome.self, forKey: .outcome)) ?? .completed
        errorSpoken = try c.decodeIfPresent(String.self, forKey: .errorSpoken)
        errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
        narration = try c.decodeIfPresent(String.self, forKey: .narration)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds) ?? 0
        usage = try c.decodeIfPresent(HistoryUsage.self, forKey: .usage)
        timings = try c.decodeIfPresent(HistoryTimings.self, forKey: .timings) ?? HistoryTimings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(source, forKey: .source)
        try c.encode(words, forKey: .words)
        try c.encodeIfPresent(trigger, forKey: .trigger)
        if !appNotes.isEmpty { try c.encode(appNotes, forKey: .appNotes) }
        try c.encodeIfPresent(frontApp, forKey: .frontApp)
        try c.encode(spokenLines, forKey: .spokenLines)
        try c.encodeIfPresent(program, forKey: .program)
        try c.encodeIfPresent(canvas, forKey: .canvas)
        if !statuses.isEmpty { try c.encode(statuses, forKey: .statuses) }
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        if !deferredActions.isEmpty { try c.encode(deferredActions, forKey: .deferredActions) }
        try c.encode(outcome, forKey: .outcome)
        try c.encodeIfPresent(errorSpoken, forKey: .errorSpoken)
        try c.encodeIfPresent(errorDetail, forKey: .errorDetail)
        try c.encodeIfPresent(narration, forKey: .narration)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(rounds, forKey: .rounds)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encode(timings, forKey: .timings)
    }
}

/// A conversation: the turns between two "start fresh" points (the brain runtime's session).
public struct HistorySession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var updatedAt: Date
    /// A short name: the first thing the user asked, trimmed.
    public var title: String
    public var turnCount: Int
    /// The latest reply, trimmed, for the list.
    public var preview: String
    public var drawingCount: Int

    public init(id: String, startedAt: Date, updatedAt: Date, title: String = "", turnCount: Int = 0, preview: String = "",
                drawingCount: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.title = title
        self.turnCount = turnCount
        self.preview = preview
        self.drawingCount = drawingCount
    }

    /// The summary a list shows, from the turns themselves.
    static func summarize(id: String, startedAt: Date, turns: [HistoryTurn]) -> HistorySession {
        var session = HistorySession(id: id, startedAt: startedAt, updatedAt: startedAt)
        for turn in turns { session.absorb(turn) }
        return session
    }

    mutating func absorb(_ turn: HistoryTurn) {
        turnCount += 1
        updatedAt = max(updatedAt, turn.startedAt)
        if title.isEmpty, !turn.words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = Self.clip(turn.words, to: 60)
        }
        let reply = turn.replyText
        if !reply.isEmpty { preview = Self.clip(reply, to: 120) }
        if turn.hasDrawing { drawingCount += 1 }
    }

    static func clip(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A drawing worth showing in Home: a turn whose reply drew something.
public struct HistoryDrawing: Sendable, Hashable, Identifiable {
    public var id: String { turnID }
    public var turnID: String
    public var sessionID: String
    public var createdAt: Date
    /// What the user asked.
    public var question: String
    public var program: String
    public var canvas: HistoryCanvas?
    public var spokenLines: [String]
    /// The saved lesson (`DrawingLessonStore`): screenshot, poster and lesson.json, when one was kept.
    public var lessonFolder: URL?

    public init(turn: HistoryTurn) {
        turnID = turn.id
        sessionID = turn.sessionID
        createdAt = turn.startedAt
        question = turn.words
        program = turn.program ?? ""
        canvas = turn.canvas
        spokenLines = turn.spokenLines
    }

    /// A title for the card: the question, or the first spoken line.
    public var title: String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return HistorySession.clip(question.isEmpty ? (spokenLines.first ?? "Drawing") : question, to: 48)
    }
}

/// Work handed to a background job, and the job coming back, in the conversation where it happened. Home shows these
/// between the turns; the history keeps them so a later look back ("what did that job find?") can see them.
public struct HistoryHandOff: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A job (or a new run of one) started.
        case started
        /// A run finished: done, failed, stopped, or waiting on the user.
        case cameBack = "came_back"
    }

    public var id: String
    public var sessionID: String
    public var kind: Kind
    public var at: Date
    public var jobID: String
    /// Which run of the job, from 1.
    public var run: Int
    public var title: String
    /// The kept agent's name, when the job belongs to one.
    public var agentName: String?
    /// For `cameBack`: `done`, `needs-you`, `failed` or `stopped`.
    public var outcome: String?
    /// For `cameBack`: the sentence the voice can say.
    public var spoken: String?
    /// For `cameBack`: deliverables, most important first.
    public var files: [String]
    /// For `cameBack`: what the job asked the user, if anything.
    public var question: String?
    /// For `started`: what was asked of the job, shortened.
    public var task: String?

    public init(id: String = UUID().uuidString, sessionID: String, kind: Kind, at: Date, jobID: String, run: Int, title: String,
                agentName: String? = nil, outcome: String? = nil, spoken: String? = nil, files: [String] = [], question: String? = nil,
                task: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
        self.jobID = jobID
        self.run = run
        self.title = title
        self.agentName = agentName
        self.outcome = outcome
        self.spoken = spoken
        self.files = files
        self.question = question
        self.task = task
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID = "session", kind, at, jobID = "job", run, title, agentName = "agent", outcome, spoken, files, question, task
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        kind = try c.decode(Kind.self, forKey: .kind)
        at = try c.decode(Date.self, forKey: .at)
        jobID = try c.decode(String.self, forKey: .jobID)
        run = try c.decodeIfPresent(Int.self, forKey: .run) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        spoken = try c.decodeIfPresent(String.self, forKey: .spoken)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        question = try c.decodeIfPresent(String.self, forKey: .question)
        task = try c.decodeIfPresent(String.self, forKey: .task)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(kind, forKey: .kind)
        try c.encode(at, forKey: .at)
        try c.encode(jobID, forKey: .jobID)
        try c.encode(run, forKey: .run)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(agentName, forKey: .agentName)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(spoken, forKey: .spoken)
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        try c.encodeIfPresent(question, forKey: .question)
        try c.encodeIfPresent(task, forKey: .task)
    }

    /// One line for a list: "Started: Find flights" / "Came back (done): Find flights: Found three options."
    public var summary: String {
        switch kind {
        case .started: return "Started: \(title)"
        case .cameBack:
            let head = "Came back" + (outcome.map { " (\($0))" } ?? "") + ": \(title)"
            return spoken.map { head + ": " + $0 } ?? head
        }
    }
}

/// Turns the job manager's updates into hand-off records: `started` the first time a run of a job is seen running,
/// `cameBack` for each finished run's report. The session id is filled in by whoever stores them.
public struct HistoryHandOffTracker: Sendable {
    private var seenRuns: [String: Int] = [:]
    private var reported: Set<String> = []

    public init() {}

    public mutating func observe(_ update: AgentManagerUpdate) -> HistoryHandOff? {
        switch update {
        case .job(let record):
            let run = record.runs.count
            guard run > 0, record.status.isActive, (seenRuns[record.id] ?? 0) < run else { return nil }
            seenRuns[record.id] = run
            let started = record.runs.last?.startedAt ?? record.updatedAt
            let task = (record.runs.last?.ask ?? record.task).trimmingCharacters(in: .whitespacesAndNewlines)
            return HistoryHandOff(id: "\(record.id)#\(run)-started", sessionID: "", kind: .started, at: started, jobID: record.id,
                                  run: run, title: record.title, agentName: record.agentName,
                                  task: task.isEmpty ? nil : HistorySession.clip(task, to: 280))
        case .report(let report):
            guard reported.insert(report.id).inserted else { return nil }
            seenRuns[report.jobID] = max(seenRuns[report.jobID] ?? 0, report.run)
            return HistoryHandOff(id: "\(report.id)-back", sessionID: "", kind: .cameBack, at: report.finishedAt, jobID: report.jobID,
                                  run: report.run, title: report.title, agentName: report.agentName, outcome: report.outcome.rawValue,
                                  spoken: report.spoken, files: report.files, question: report.question)
        case .event, .launched:
            return nil
        }
    }
}
