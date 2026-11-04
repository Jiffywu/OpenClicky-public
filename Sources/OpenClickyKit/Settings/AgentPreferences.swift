import Foundation

/// Settings → Agents: how background jobs run and how they report back. `agent-settings.json` in the agent support
/// folder (so `OPENCLICKY_SUPPORT_DIR` moves it with the jobs). The agent model and its reasoning effort live in the
/// config's agent slot, next to the rest of the model choices.
public struct AgentPreferences: Codable, Sendable, Equatable {
    /// `ask`: work in the job folder, ask before anything beyond it. `fullAccess`: never ask (HeyClicky's behaviour).
    public var approvalMode: AgentApprovalMode
    /// A folder the user chose for job and kept-agent folders; nil keeps them in Application Support.
    public var customFolder: String?
    /// Speak a short report when jobs finish (a report turn in the voice loop).
    public var voiceAnnouncements: Bool
    /// Show a notification when jobs finish. Jobs that need the user always notify.
    public var textAnnouncements: Bool
    /// Let OpenClicky suggest a background job when one would help.
    public var suggestTasks: Bool
    /// Developer preview: keep before-and-after copies of the text files jobs change and show their diffs.
    public var developerFileDiffs: Bool

    public init(approvalMode: AgentApprovalMode = .ask, customFolder: String? = nil, voiceAnnouncements: Bool = true,
                textAnnouncements: Bool = true, suggestTasks: Bool = true, developerFileDiffs: Bool = false) {
        self.approvalMode = approvalMode
        self.customFolder = customFolder
        self.voiceAnnouncements = voiceAnnouncements
        self.textAnnouncements = textAnnouncements
        self.suggestTasks = suggestTasks
        self.developerFileDiffs = developerFileDiffs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentPreferences()
        approvalMode = (try? c.decodeIfPresent(AgentApprovalMode.self, forKey: .approvalMode)) ?? d.approvalMode
        customFolder = try c.decodeIfPresent(String.self, forKey: .customFolder)
        voiceAnnouncements = try c.decodeIfPresent(Bool.self, forKey: .voiceAnnouncements) ?? d.voiceAnnouncements
        textAnnouncements = try c.decodeIfPresent(Bool.self, forKey: .textAnnouncements) ?? d.textAnnouncements
        suggestTasks = try c.decodeIfPresent(Bool.self, forKey: .suggestTasks) ?? d.suggestTasks
        developerFileDiffs = try c.decodeIfPresent(Bool.self, forKey: .developerFileDiffs) ?? d.developerFileDiffs
    }

    public static func url(in paths: AgentPaths = .default) -> URL { paths.root.appendingPathComponent("agent-settings.json") }

    public static func load(from url: URL = AgentPreferences.url()) -> AgentPreferences {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AgentPreferences.self, from: $0) } ?? AgentPreferences()
    }

    public func save(to url: URL = AgentPreferences.url()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The agent folders with the custom folder applied (when it is set and usable).
    public func paths(base: AgentPaths = .default) -> AgentPaths {
        var paths = base
        if let folder = customFolder, case .success(let url) = Self.validateFolder(folder) { paths.customProjects = url }
        return paths
    }

    /// Checks a folder chosen for agent work: an absolute path to a folder (or one that can be made), not inside an
    /// app bundle or a system location.
    public static func validateFolder(_ path: String, fileManager: FileManager = .default) -> Result<URL, AgentFolderProblem> {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute) }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let components = url.pathComponents
        if components.contains(where: { $0.hasSuffix(".app") }) { return .failure(.insideApp) }
        let system = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/Applications", "/Volumes"]
        if url.path == "/" || system.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) && !url.path.hasPrefix("/Volumes/") {
            return .failure(.systemLocation)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { return .failure(.notAFolder) }
        return .success(url)
    }

    /// The `[Agent settings]` line for the voice brain when suggestions are off; nil when it has nothing to add.
    public var brainNote: String? {
        suggestTasks ? nil : "[Agent settings] The user turned off job suggestions: start a background job only when they ask for one."
    }
}

public enum AgentFolderProblem: Error, Sendable, Equatable, CustomStringConvertible {
    case notAbsolute, insideApp, systemLocation, notAFolder

    public var description: String {
        switch self {
        case .notAbsolute: "Choose a full folder path."
        case .insideApp: "Agent work can't go inside an app."
        case .systemLocation: "Choose a folder in your home folder or on an external drive, not a system location."
        case .notAFolder: "That's a file, not a folder."
        }
    }
}

/// The reasoning efforts Settings → Agents offers for the agent slot's harness and model.
public enum AgentEffortOptions {
    /// What each harness accepts on its command line or in its config.
    public static func harnessEfforts(_ harness: HarnessKind) -> [String] {
        switch harness {
        case .claudeCode: ["low", "medium", "high", "xhigh", "max"]
        case .codex: ["minimal", "low", "medium", "high", "xhigh"]
        }
    }

    /// The model's catalog efforts the harness can pass on; the harness's whole list when the catalog doesn't say.
    public static func choices(harness: HarnessKind, model: ModelDescriptor?) -> [String] {
        let supported = harnessEfforts(harness)
        guard let listed = model?.reasoningEfforts, !listed.isEmpty else { return supported }
        let both = listed.filter(supported.contains)
        return both.isEmpty ? supported : both
    }

    /// The choices for a config's agent slot.
    public static func choices(config: OpenClickyConfig, catalog: ModelCatalog) -> [String] {
        guard let selection = config.slots[.agent] else { return [] }
        let harness = selection.harness ?? .codex
        let dialect = config.provider(selection.provider)?.dialect
        let descriptor = dialect.flatMap { catalog.merging(config.models).model(selection.model, servedBy: $0) }
        return choices(harness: harness, model: descriptor)
    }
}

// MARK: - Routines page

/// One run of a routine, as the Routines page and `occtl routines show` list it.
public struct RoutineRunEntry: Sendable, Hashable, Identifiable {
    public var jobID: String
    public var runIndex: Int
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: AgentTurnOutcome?
    public var spoken: String?

    public var id: String { "\(jobID)#\(runIndex)" }

    public var statusText: String {
        switch outcome {
        case .completed: "done"
        case .failed: "failed"
        case .interrupted: "stopped"
        case nil: finishedAt == nil ? "running" : "finished"
        }
    }
}

/// A routine with its run list and the line the page shows under it.
public struct RoutineSummary: Sendable, Hashable, Identifiable {
    public var routine: AgentRoutine
    /// Newest first.
    public var runs: [RoutineRunEntry]
    /// The last failed run's error, if the latest outcome was a failure.
    public var lastFailure: String?

    public var id: String { routine.id }

    /// Runs of every routine, from the job records (each run remembers which routine started it), newest first.
    public static func make(routines: [AgentRoutine], jobs: [AgentJobRecord], runLimit: Int = 20) -> [RoutineSummary] {
        var byRoutine: [String: [RoutineRunEntry]] = [:]
        var failureText: [String: (Date, String)] = [:]
        for job in jobs {
            for (index, run) in job.runs.enumerated() {
                guard let routineID = run.routineID else { continue }
                byRoutine[routineID, default: []].append(RoutineRunEntry(jobID: job.id, runIndex: index, startedAt: run.startedAt,
                                                                         finishedAt: run.finishedAt, outcome: run.outcome, spoken: run.spoken))
                if run.outcome == .failed {
                    let text = job.error ?? run.spoken ?? "The run failed."
                    if failureText[routineID].map({ $0.0 < run.startedAt }) ?? true { failureText[routineID] = (run.startedAt, text) }
                }
            }
        }
        return routines.map { routine in
            let runs = (byRoutine[routine.id] ?? []).sorted { $0.startedAt > $1.startedAt }
            let failure = routine.lastOutcome == .failed ? (failureText[routine.id]?.1 ?? "The last run failed before it started.") : nil
            return RoutineSummary(routine: routine, runs: Array(runs.prefix(runLimit)), lastFailure: failure)
        }
    }

    /// "Paused", "Paused after 3 failed runs", "Next run Tue 09:00", "Retrying at 10:20 after a failed run".
    public func statusLine(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(routine.dueAt ?? now, inSameDayAs: now) ? "HH:mm" : "EEE d MMM HH:mm")
        if routine.isPaused {
            return routine.consecutiveFailures > 0
                ? "Paused after \(routine.consecutiveFailures) failed run\(routine.consecutiveFailures == 1 ? "" : "s")"
                : "Paused"
        }
        if let retry = routine.retryAt, routine.dueAt == retry {
            return "Retrying at \(formatter.string(from: retry)) after a failed run"
        }
        guard let next = routine.nextRunAt else { return "Not scheduled" }
        return "Next run \(formatter.string(from: next))"
    }

    /// "Ran 4 times, last 2 h ago: done".
    public func lastRunLine(now: Date = Date()) -> String {
        guard let last = routine.lastRunAt else { return "Hasn't run yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let ago = formatter.localizedString(for: min(last, now), relativeTo: now)
        let times = routine.runCount == 1 ? "once" : "\(routine.runCount) times"
        let outcome = runs.first?.statusText ?? routine.lastOutcome.map { $0 == .completed ? "done" : $0.rawValue } ?? "started"
        return "Ran \(times), last \(ago): \(outcome)"
    }
}
