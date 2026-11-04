import Foundation

/// Which harness and model a job runs with, and how it signs in.
public struct AgentLaunchSettings: Sendable {
    public var harness: HarnessKind
    /// nil = the harness's default model.
    public var model: String?
    public var reasoningEffort: String?
    /// The agent-slot provider id, or "harness-login".
    public var providerID: String
    public var auth: HarnessAuth
    public var approvalMode: AgentApprovalMode
    public var executable: URL?
    public var extraArguments: [String]
    public var mcpServers: [AgentMCPServer]
    /// The environment the harness starts from (before OpenClicky strips and adds variables); nil = this process's.
    public var baseEnvironment: [String: String]?
    /// Appended to the job's developer instructions (the active skills, for example); nil or empty adds nothing.
    public var extraInstructions: String?
    /// Plain variables for the job's commands (never secrets).
    public var environment: [String: String]
    /// Steps, time, compaction and cleanup limits (the config's `agentLimits`).
    public var limits: AgentLimits

    public init(harness: HarnessKind, model: String?, reasoningEffort: String? = nil, providerID: String, auth: HarnessAuth,
                approvalMode: AgentApprovalMode = .ask, executable: URL? = nil, extraArguments: [String] = [], mcpServers: [AgentMCPServer] = [],
                baseEnvironment: [String: String]? = nil, extraInstructions: String? = nil, environment: [String: String] = [:],
                limits: AgentLimits = AgentLimits()) {
        self.environment = environment
        self.limits = limits
        self.harness = harness
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.providerID = providerID
        self.auth = auth
        self.approvalMode = approvalMode
        self.executable = executable
        self.extraArguments = extraArguments
        self.mcpServers = mcpServers
        self.baseEnvironment = baseEnvironment
        self.extraInstructions = extraInstructions
    }

    public static let loginProviderID = ProviderDialect.harnessLogin.rawValue

    /// Settings from the config's agent slot. The key is read from the credential store here, at launch, and only
    /// ever handed to the harness through its environment.
    ///
    /// - Parameters:
    ///   - harness: run with this harness instead of the slot's.
    ///   - forceLogin: use the harness's own sign-in even if the slot names a keyed provider.
    ///   - model: run with this model instead of the slot's.
    public static func fromConfig(_ config: OpenClickyConfig, credentials: any CredentialStore, harness: HarnessKind? = nil,
                                  forceLogin: Bool = false, model: String? = nil, approvalMode: AgentApprovalMode = .ask,
                                  mcpServers: [AgentMCPServer] = []) throws -> AgentLaunchSettings {
        guard let selection = config.slots[.agent] else { throw AgentManagerError.configuration("The config has no agent slot.") }
        guard let provider = config.provider(selection.provider) else {
            throw AgentManagerError.configuration("The agent slot's provider \"\(selection.provider)\" is not configured.")
        }
        let kind = harness ?? selection.harness ?? .codex
        let slotIsLogin = provider.dialect == .harnessLogin
        let overrides = config.harnesses?[kind]
        func normalized(_ id: String?) -> String? {
            guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id != "default" else { return nil }
            return id
        }
        var settings = AgentLaunchSettings(
            harness: kind, model: nil, reasoningEffort: normalized(selection.reasoningEffort), providerID: provider.id,
            auth: .harnessLogin, approvalMode: approvalMode,
            executable: overrides?.executable.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            extraArguments: overrides?.extraArguments ?? [], mcpServers: mcpServers, limits: config.agentLimits ?? AgentLimits())
        if forceLogin || slotIsLogin {
            settings.providerID = loginProviderID
            // A keyed provider's model name may not exist behind the harness's login; let the harness choose.
            settings.model = normalized(model) ?? (slotIsLogin && (selection.harness ?? kind) == kind ? normalized(selection.model) : nil)
            return settings
        }
        guard kind.supportedDialects.contains(provider.dialect) else {
            throw AgentManagerError.configuration(
                "The \(kind.rawValue) harness can't use the \(provider.dialect.rawValue) provider \"\(provider.id)\". Pick a matching provider or use the harness's own login.")
        }
        var key: String?
        if let name = provider.credential {
            key = try credentials.secret(named: name)
            if key == nil { throw AgentManagerError.configuration(CredentialError.missing(name).description) }
        }
        settings.auth = .provider(provider, apiKey: key)
        settings.model = normalized(model) ?? normalized(selection.model)
        return settings
    }
}

/// How a job should be launched: a harness override and whether to use its own login.
public struct AgentLaunchPreference: Sendable, Hashable {
    public var harness: HarnessKind?
    public var login: Bool

    public init(harness: HarnessKind? = nil, login: Bool = false) {
        self.harness = harness
        self.login = login
    }
}

public enum AgentManagerError: Error, CustomStringConvertible, Equatable {
    case configuration(String)
    case unknownJob(String)
    case emptyTask
    case nothingToAnswer(String)
    case busy(String)
    /// Archiving and other kept-agent actions on a one-off job.
    case notKept(String)

    public var description: String {
        switch self {
        case .configuration(let message): message
        case .unknownJob(let reference): "There is no job or kept agent called \"\(reference)\"."
        case .emptyTask: "The task is empty."
        case .nothingToAnswer(let id): "\(id) isn't waiting for an answer."
        case .busy(let id): "\(id) is still working on its previous run."
        case .notKept(let id): "\(id) is a one-off job, not a kept agent."
        }
    }
}

/// A request to start background work.
public struct AgentSpawnRequest: Sendable {
    public var task: String
    public var title: String?
    /// Run in this kept agent (slug or name).
    public var agent: String?
    public var agentRole: String?
    /// Create the kept agent if it doesn't exist.
    public var keep: Bool
    public var preference: AgentLaunchPreference
    /// Image files for the agent to look at (copied into the run's task assets first).
    public var images: [URL]
    /// Files the user attached: listed in the brief by path, as inputs only.
    public var attachments: [URL]
    /// JPEG screenshots of the user's screen from the turn that asked (saved as the run's task assets and attached).
    public var screenshots: [Data]
    public var routine: AgentRoutine?
    public var runNumber: Int

    public init(task: String, title: String? = nil, agent: String? = nil, agentRole: String? = nil, keep: Bool = false,
                preference: AgentLaunchPreference = .init(), images: [URL] = [], attachments: [URL] = [], screenshots: [Data] = [],
                routine: AgentRoutine? = nil, runNumber: Int = 1) {
        self.screenshots = screenshots
        self.task = task
        self.title = title
        self.agent = agent
        self.agentRole = agentRole
        self.keep = keep
        self.preference = preference
        self.images = images
        self.attachments = attachments
        self.routine = routine
        self.runNumber = runNumber
    }
}

public struct AgentSpawnResult: Sendable {
    public var record: AgentJobRecord
    /// The same task was started moments ago; nothing new was started.
    public var alreadyStarted: Bool
    /// Set when the task went to a busy kept agent as a follow-up.
    public var sentAs: AgentSendDisposition?
    /// The task went to an archived kept agent, which is back in the list now (the brain should say so).
    public var revived = false
}

/// What the manager publishes to the HUD, the voice brain and notifications.
public enum AgentManagerUpdate: Sendable {
    /// A job's record changed.
    case job(AgentJobRecord)
    case event(jobID: String, AgentEvent)
    /// A run finished; hand it to the brain for a report turn.
    case report(AgentJobReport)
    /// New work started from a request (a launch sound, a start line). Sent once per spawned job or kept-agent task,
    /// not for follow-ups or routine runs.
    case launched(AgentJobRecord)
}

/// Runs background jobs: creates their folders, launches the harness, follows its events, keeps the records and
/// logs, and publishes progress and finished-run reports. One actor for the whole app.
public actor AgentManager {
    public typealias SettingsProvider = @Sendable (AgentLaunchPreference) async throws -> AgentLaunchSettings

    public nonisolated let store: AgentJobStore
    private let harnesses: [HarnessKind: any AgentHarness]
    private let settingsProvider: SettingsProvider
    private let now: @Sendable () -> Date

    private struct Live {
        var token: UUID
        var session: any AgentHarnessSession
    }

    private var live: [String: Live] = [:]
    private var records: [String: AgentJobRecord] = [:]
    private var starting: Set<String> = []
    /// Follow-ups that arrived while the harness was starting.
    private var pendingWhileStarting: [String: [String]] = [:]
    /// Follow-ups the harness queued behind the running turn; each becomes its own run.
    private var queuedRuns: [String: [String]] = [:]
    /// Follow-ups on their way to a live session. A turn that finishes meanwhile leaves the session open for them.
    private var sendsInFlight: [String: Int] = [:]
    private var interruptWhenStarted: Set<String> = []
    private var recentSpawns: [(key: String, at: Date, jobID: String)] = []
    /// One token per approval request as it arrives, so a timer never expires a later request that reuses its id
    /// (a relaunched harness numbers its requests from zero again).
    private var approvalTokens: [String: UUID] = [:]
    /// Approval requests that arrived while another one of the same job was waiting on the user.
    private var waitingRequests: [String: [AgentApprovalRequest]] = [:]
    /// The skills to install for each launch (`setSkillSources`); nil leaves the harness skill folders alone.
    var skillSources: (@Sendable () async -> [AgentSkillSource])?
    /// Set by `shutdown()`: a harness that finishes starting afterwards is closed at once.
    private var isShutDown = false
    private var subscribers: [UUID: AsyncStream<AgentManagerUpdate>.Continuation] = [:]
    /// Adds connected apps (and anything else) to every launch; asked at each launch, so tokens are fresh.
    private var extrasProvider: (@Sendable (AgentJobRecord) async -> AgentLaunchExtras)?
    /// Writes a title and a start line for new jobs (the brain-fast slot); nil keeps the first-words title.
    private var labeler: (any AgentLaunchLabeling)?
    /// Whether to keep before-and-after diffs of the files jobs change (Settings → Agents, developer preview); read
    /// at every file event. Nil keeps none.
    private var fileDiffsEnabled: (@Sendable () -> Bool)?
    /// The "before" of every file the current run of each job is changing.
    private var diffRecorders: [String: AgentFileDiffRecorder] = [:]
    /// Writes each job's token deltas to the usage ledger; nil records nothing.
    private var usageRecorder: AgentUsageRecorder?

    /// What the limits watch for the run in progress.
    private struct RunWatch {
        var token = UUID()
        var steps = 0
        var startedAt: Date
        var stopReason: String?
    }

    private var watches: [String: RunWatch] = [:]
    /// The limits each job was last launched with.
    private var jobLimits: [String: AgentLimits] = [:]
    /// One pending "assume and say so" timer per job whose report question is unanswered.
    private var assumeTokens: [String: UUID] = [:]
    /// Jobs asking the user to connect Chrome (`requestChromeSetup`), and jobs waiting for it to connect.
    private var chromeSetup: [String: AgentApprovalRequest] = [:]
    private var awaitingChrome: Set<String> = []
    /// Whether a browser is connected now (`setBrowserConnectedCheck`); nil = unknown, wait for the connect event.
    private var browserIsConnected: (@Sendable () -> Bool)?
    /// The preference each job was last launched with, to restart its harness after a crash.
    private var launchPreferences: [String: AgentLaunchPreference] = [:]
    /// Jobs whose current run already restarted once after the harness died mid-turn.
    private var crashResumed: Set<String> = []
    /// OpenClicky's own confirmations (a job's tool asking to add a routine) waiting on the user, by request id, with
    /// the job that asked.
    private var localWaiters: [String: (job: String, request: AgentApprovalRequest, continuation: CheckedContinuation<AgentApprovalDecision?, Never>)] = [:]
    /// Applies a routine a job proposed, once the user said yes; returns what it did. nil: proposals can't be applied.
    private var routineApplier: (@Sendable (AgentRoutineRequest, AgentJobRecord) async throws -> String)?
    /// The `[Your routines]` note for every launch's instructions, given the launching job's id.
    private var routinesNote: (@Sendable (String) async -> String?)?

    /// Request ids OpenClicky raises itself (not the harness's): routine proposals and tool confirmations.
    static let localRequestPrefix = "openclicky-"
    /// The confirmation for routines a report proposed (`routineConfirmation`).
    static let routineRequestPrefix = localRequestPrefix + "routine-"

    static func isRoutineConfirmation(_ requestID: String?) -> Bool { requestID?.hasPrefix(routineRequestPrefix) == true }

    /// How long a job waits for an answer to an approval or question before it gets a "no" (and, for a question,
    /// is told to assume and say so), so an unanswered request never holds a harness open for good.
    public let approvalTimeout: TimeInterval
    /// The most a job's own tool waits for the user's confirmation: under the 900 s tool timeout the harnesses get for
    /// OpenClicky's MCP servers, so the tool call is answered (with a no) before the harness gives up on it and the
    /// agent retries a call the user could still say yes to.
    static let localConfirmTimeout: TimeInterval = 14 * 60

    public init(store: AgentJobStore = AgentJobStore(), harnesses: [any AgentHarness] = [CodexHarness(), ClaudeCodeHarness()],
                now: @escaping @Sendable () -> Date = { Date() }, approvalTimeout: TimeInterval = 30 * 60, settings: @escaping SettingsProvider) {
        self.store = store
        self.harnesses = Dictionary(harnesses.map { ($0.kind, $0) }, uniquingKeysWith: { $1 })
        self.settingsProvider = settings
        self.now = now
        self.approvalTimeout = approvalTimeout
    }

    // MARK: Observing

    public func subscribe() -> AsyncStream<AgentManagerUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentManagerUpdate.self, bufferingPolicy: .bufferingNewest(1000))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func publish(_ update: AgentManagerUpdate) {
        for continuation in subscribers.values { continuation.yield(update) }
    }

    // MARK: Configuring

    /// What every launch adds (connected apps, their instructions and `OBSIDIAN_VAULT_PATH`).
    public func setLaunchExtras(_ provider: (@Sendable (AgentJobRecord) async -> AgentLaunchExtras)?) { extrasProvider = provider }

    /// The labeler that names new jobs and writes their start line.
    public func setLabeler(_ labeler: (any AgentLaunchLabeling)?) { self.labeler = labeler }

    /// What applies a routine a job proposed (`<routine>` block or the routines tool) after the user's yes.
    public func setRoutineApplier(_ applier: (@Sendable (AgentRoutineRequest, AgentJobRecord) async throws -> String)?) {
        routineApplier = applier
    }

    /// The current-routines note added to every launch's instructions; it gets the job's id to mark the routines that
    /// run in that job's folder.
    public func setRoutinesNote(_ note: (@Sendable (String) async -> String?)?) { routinesNote = note }

    /// Turns before-and-after file diffs on or off (read at every file event).
    public func setFileDiffs(_ enabled: (@Sendable () -> Bool)?) { fileDiffsEnabled = enabled }

    /// Files whose "before" the job's current run has kept (tests).
    func fileSnapshotCount(_ id: String) -> Int { diffRecorders[id]?.order.count ?? 0 }

    /// Where job token usage is written (the app's usage ledger); nil stops recording.
    public func setUsageRecorder(_ recorder: AgentUsageRecorder?) { usageRecorder = recorder }

    // MARK: Reading

    public func jobs() -> [AgentJobRecord] {
        store.all().map { records[$0.id] ?? $0 }
    }

    public func job(_ reference: String) -> AgentJobRecord? { resolve(reference) }

    public func isRunning(_ id: String) -> Bool { live[id] != nil || starting.contains(id) }

    /// A job id, a kept agent's slug, or a kept agent's name.
    public func resolve(_ reference: String) -> AgentJobRecord? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = records[reference] { return cached }
        if let record = store.load(id: reference) { return record }
        let slug = AgentJobStore.slug(reference)
        if let cached = records[slug] { return cached }
        if let record = store.load(id: slug) { return record }
        return store.all().first { $0.isKept && $0.agentName?.caseInsensitiveCompare(reference) == .orderedSame }
    }

    public func find(_ query: String, limit: Int = 8) -> [AgentJobRecord] {
        store.find(query, limit: limit).map { records[$0.id] ?? $0 }
    }

    // MARK: Kept agents

    /// Kept agents, most recently updated first; archived ones too (`isArchived`).
    public func keptAgents() -> [AgentJobRecord] { jobs().filter(\.isKept) }

    /// Archives a kept agent: it leaves the `[Your Clickys]` note until work is routed to it again. Its folder, memory,
    /// files and routines stay. A kept agent that is working can't be archived.
    @discardableResult
    public func archive(_ reference: String) throws -> AgentJobRecord {
        guard let record = resolve(reference) else { throw AgentManagerError.unknownJob(reference) }
        guard record.isKept else { throw AgentManagerError.notKept(record.id) }
        guard !isRunning(record.id), !record.status.isActive else { throw AgentManagerError.busy(record.id) }
        guard !record.isArchived else { return record }
        update(record.id, touch: false) { $0.archivedAt = self.now() }
        append(.log("Archived."), to: record.id)
        try? store.writeIndex()
        return records[record.id] ?? record
    }

    /// Brings an archived kept agent back (also done by routing work to it).
    @discardableResult
    public func unarchive(_ reference: String) throws -> AgentJobRecord {
        guard let record = resolve(reference) else { throw AgentManagerError.unknownJob(reference) }
        guard record.isKept else { throw AgentManagerError.notKept(record.id) }
        guard record.isArchived else { return record }
        update(record.id, touch: false) { $0.archivedAt = nil }
        append(.log("Back from the archive."), to: record.id)
        try? store.writeIndex()
        return records[record.id] ?? record
    }

    /// Saves a record changed outside a run (the organizer filing jobs under a kept agent). Running jobs are left alone.
    func replaceRecord(_ record: AgentJobRecord) {
        guard !isRunning(record.id) else { return }
        records[record.id] = record
        try? store.save(record)
        publish(.job(record))
    }

    // MARK: Starting work

    /// Starts a job (or a kept agent's next task). Returns once the job exists; with `waitForStart` it also waits
    /// until the harness has started, so launch errors are thrown instead of only being recorded.
    public func spawn(_ request: AgentSpawnRequest, waitForStart: Bool = false) async throws -> AgentSpawnResult {
        let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw AgentManagerError.emptyTask }
        let current = now()
        recentSpawns.removeAll { current.timeIntervalSince($0.at) > 30 }
        let key = "\(request.agent.map(AgentJobStore.slug) ?? "")|\(task.lowercased())"
        // The same task asked twice in a row (a repeated tool call) starts once. Checked again after every
        // suspension below, because two identical calls can both get past this first check before either records
        // its job.
        func duplicate() -> AgentSpawnResult? {
            guard request.routine == nil, let recent = recentSpawns.first(where: { $0.key == key }),
                  let record = resolve(recent.jobID) else { return nil }
            return AgentSpawnResult(record: record, alreadyStarted: true, sentAs: nil)
        }
        if let duplicate = duplicate() { return duplicate }

        var record: AgentJobRecord
        var preference = request.preference
        var revived = false
        if let agent = request.agent {
            var existing = resolve(agent).flatMap { $0.isKept ? $0 : nil }
            var created: AgentJobRecord?
            if existing == nil {
                guard request.keep else { throw AgentManagerError.unknownJob(agent) }
                let settings = try await settingsProvider(preference)
                if let duplicate = duplicate() { return duplicate }
                // A parallel call (another tool call in the same reply) may have created and started it meanwhile.
                existing = resolve(agent).flatMap { $0.isKept ? $0 : nil }
                if existing == nil {
                    created = try store.keptAgent(named: agent, role: request.agentRole, harness: settings.harness, model: settings.model,
                                                  provider: settings.providerID, now: current)
                }
            }
            if let created {
                record = created
            } else if var existing {
                // Work the user routes to an archived kept agent brings it back. Its scheduled routines keep running
                // while it is archived (as archiving says) without bringing it back.
                if existing.isArchived, request.routine == nil {
                    existing = try unarchive(existing.id)
                    revived = true
                }
                if isRunning(existing.id) {
                    if request.routine == nil { recentSpawns.append((key, current, existing.id)) }
                    let (updated, disposition) = try await send(to: existing.id, message: task)
                    return AgentSpawnResult(record: updated, alreadyStarted: false, sentAs: disposition, revived: revived)
                }
                record = existing
                if preference.harness == nil { preference.harness = existing.harness }
                if !preference.login, existing.provider == AgentLaunchSettings.loginProviderID { preference.login = true }
            } else {
                throw AgentManagerError.unknownJob(agent)
            }
        } else {
            let settings = try await settingsProvider(preference)
            if let duplicate = duplicate() { return duplicate }
            record = try store.createJob(task: task, title: request.title, harness: settings.harness, model: settings.model,
                                         provider: settings.providerID, now: current)
        }
        // No suspension between the last duplicate check and here, so a concurrent identical call sees this entry.
        recentSpawns.append((key, current, record.id))
        let interrupted = record.runs.last?.outcome == .interrupted
        // The turn's screenshots and images become this run's task assets; the agent gets the saved copies.
        let images: [URL]
        do {
            images = try AgentTaskAssets.save(screenshots: request.screenshots, images: request.images, paths: store.paths,
                                              jobID: record.id, run: record.runs.count + 1)
        } catch {
            store.append(.log("Couldn't save the task's screenshots (\(error)); starting without them."), to: record, at: current)
            images = request.images
        }
        let brief = AgentInstructions.brief(task: task, record: record, routine: request.routine, runNumber: request.runNumber,
                                            attachments: request.attachments, interruptedBefore: interrupted && record.isKept,
                                            images: images)
        record = try await startRun(record, ask: task, message: brief, images: images, preference: preference,
                                    routineID: request.routine?.id, wait: waitForStart)
        if request.routine == nil {
            publish(.launched(record))
            if !record.isKept, let labeler {
                let id = record.id
                let keepTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                Task { [weak self] in
                    guard let labels = await labeler.labels(for: task) else { return }
                    await self?.apply(labels, to: id, keepTitle: keepTitle)
                }
            }
        }
        return AgentSpawnResult(record: records[record.id] ?? record, alreadyStarted: false, sentAs: nil, revived: revived)
    }

    /// The labeler's title (unless the brain named the job) and start line, once they arrive.
    private func apply(_ labels: AgentLaunchLabels, to id: String, keepTitle: Bool) {
        guard let before = records[id] else { return }
        update(id) { record in
            if !keepTitle { record.title = labels.title }
            record.startCue = labels.startCue
            if record.status.isActive, ["Starting", "Working on it"].contains(record.lastProgress ?? "Starting") {
                record.lastProgress = labels.startCue
            }
        }
        if before.status.isActive { publish(.event(jobID: id, .progress(labels.startCue))) }
        append(.log("Labeled: \(keepTitle ? before.title : labels.title) · \(labels.startCue)"), to: id)
        try? store.writeIndex()
    }

    /// A follow-up for a job or kept agent: steers or queues it if the harness is running, else starts a new run
    /// that resumes the harness conversation.
    @discardableResult
    public func send(to reference: String, message: String, waitForStart: Bool = false) async throws -> (AgentJobRecord, AgentSendDisposition) {
        try await deliver(to: reference, message: message, waitForStart: waitForStart, fromUser: true)
    }

    /// `send`, also for OpenClicky's own follow-ups (`fromUser` false: not recorded as the user's words).
    private func deliver(to reference: String, message: String, waitForStart: Bool, fromUser: Bool) async throws -> (AgentJobRecord, AgentSendDisposition) {
        guard var record = resolve(reference) else { throw AgentManagerError.unknownJob(reference) }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentManagerError.emptyTask }
        // A kept agent comes back from the archive here (and says so); a one-off job when its new run starts.
        if record.isArchived, record.isKept { record = try unarchive(record.id) }
        let id = record.id
        // Anything the user sends answers a waiting question; no assumption is needed any more.
        assumeTokens[id] = nil
        if fromUser {
            noteAnswer("Follow-up: \(text)", for: id)
            record = records[id] ?? record
        }
        while true {
            if starting.contains(id) {
                pendingWhileStarting[id, default: []].append(text)
                return (records[id] ?? record, .queued)
            }
            guard let entry = live[id] else { break }
            let sent = await sendFollowUp(text, to: entry, jobID: id)
            // The session ended while the follow-up was on its way: deliver it again (below, as a new run).
            guard live[id]?.token == entry.token else { continue }
            defer { closeIfIdle(id) }
            let disposition = try sent.get()
            return (records[id] ?? record, disposition)
        }
        record = records[id] ?? record
        let preference = AgentLaunchPreference(harness: record.harness, login: record.provider == AgentLaunchSettings.loginProviderID)
        let message: String
        if record.threadID != nil {
            message = AgentInstructions.followUp(text)
        } else {
            // Nothing to resume: give the new session the history it needs.
            var context = "Earlier task in this folder:\n\(record.runs.first?.ask ?? record.task)"
            if let previous = record.report?.spoken, !previous.isEmpty { context += "\n\nYour last report said: \(previous)" }
            message = AgentInstructions.brief(task: "\(context)\n\nNow: \(text)", record: record,
                                              interruptedBefore: record.runs.last?.outcome == .interrupted)
        }
        record = try await startRun(record, ask: text, message: message, images: [], preference: preference, routineID: nil, wait: waitForStart)
        return (record, .startedTurn)
    }

    /// Runs one routine: in its job folder if it has one, else as a new job (or in its kept agent).
    public func runRoutine(_ routine: AgentRoutine, runNumber: Int) async throws -> String {
        if let jobID = routine.jobID, let record = resolve(jobID) {
            if isRunning(record.id) { throw AgentManagerError.busy(record.id) }
            let brief = AgentInstructions.brief(task: routine.task, record: record, routine: routine, runNumber: runNumber)
            let preference = AgentLaunchPreference(harness: routine.harness ?? record.harness, login: record.provider == AgentLaunchSettings.loginProviderID)
            return try await startRun(record, ask: routine.task, message: brief, images: [], preference: preference, routineID: routine.id, wait: false).id
        }
        let result = try await spawn(AgentSpawnRequest(
            task: routine.task, title: routine.title, agent: routine.agent, keep: routine.agent != nil,
            preference: AgentLaunchPreference(harness: routine.harness), routine: routine, runNumber: runNumber))
        return result.record.id
    }

    private func startRun(_ record: AgentJobRecord, ask: String, message: String, images: [URL], preference: AgentLaunchPreference,
                          routineID: String?, wait: Bool) async throws -> AgentJobRecord {
        let id = record.id
        // A second harness for the same job would orphan the first session; callers send follow-ups instead.
        guard !isRunning(id) else { throw AgentManagerError.busy(id) }
        records[id] = record
        update(id) { record in
            record.runs.append(AgentRun(ask: ask, startedAt: self.now(), routineID: routineID))
            record.status = .queued
            record.lastProgress = "Starting"
            record.error = nil
            record.pendingRequest = nil
            record.waitingStep = nil
            // Routines the last report proposed keep waiting for the user's answer; `finishRun` asks again.
            // New work brings an archived job back into the list; a kept agent's routine runs leave it archived.
            if !(record.isKept && routineID != nil) { record.archivedAt = nil }
            // New scratch, log and screenshots: clean them up again once this run has been idle long enough.
            record.cleanedAt = nil
        }
        crashResumed.remove(id)
        markRunStarted(id)
        starting.insert(id)
        // File diffs for this run start here: a file already modified since now when its "before" is read was changed
        // first (wall clock, as file times are).
        diffRecorders[id] = AgentFileDiffRecorder(since: Date())
        try? store.writeIndex()
        if wait {
            try await launch(id, message: message, images: images, preference: preference)
        } else {
            Task { try? await self.launch(id, message: message, images: images, preference: preference) }
        }
        return records[id] ?? record
    }

    private func launch(_ id: String, message: String, images: [URL], preference: AgentLaunchPreference) async throws {
        starting.insert(id)
        defer { starting.remove(id) }
        launchPreferences[id] = preference
        do {
            let settings = try await settingsProvider(preference)
            guard let harness = harnesses[settings.harness] else {
                throw AgentManagerError.configuration("This build has no \(settings.harness.rawValue) harness.")
            }
            var extras = AgentLaunchExtras(mcpServers: settings.mcpServers, instructions: [settings.extraInstructions].compactMap { $0 },
                                           environment: settings.environment)
            if let extrasProvider, let current = records[id] ?? resolve(id) {
                extras = extras.merged(with: await extrasProvider(current))
            }
            if let routinesNote, let note = await routinesNote(id) { extras.instructions.append(note) }
            extras.mcpServers = Self.identifyingJob(id, in: extras.mcpServers)
            let extraInstructions = extras.instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            // A paid job doesn't start once the user's spending limit stops paid calls.
            if settings.providerID != AgentLaunchSettings.loginProviderID, let status = blockingLimit() {
                throw UsageLimitError(status: status)
            }
            guard var record = records[id] ?? resolve(id) else { throw AgentManagerError.unknownJob(id) }
            if record.harness != settings.harness || record.provider != settings.providerID {
                // A different harness or account can't resume the old conversation.
                record.threadID = nil
            }
            // A new conversation's running total starts from zero (only Codex keeps a running total).
            if record.threadID == nil { record.usageCursor = settings.harness.reportsCumulativeUsage ? AgentTokenUsage() : nil }
            record.harness = settings.harness
            record.model = settings.model
            record.provider = settings.providerID
            records[id] = record
            jobLimits[id] = settings.limits
            var launch = HarnessLaunch(
                folder: record.folder,
                instructions: AgentInstructions.developer(for: record, now: now(), extra: extraInstructions.joined(separator: "\n\n"),
                                                          limits: settings.limits),
                model: settings.model,
                reasoningEffort: settings.reasoningEffort, auth: settings.auth, mcpServers: extras.mcpServers,
                approvalMode: settings.approvalMode, resumeThreadID: record.threadID, executable: settings.executable,
                extraArguments: settings.extraArguments, paths: store.paths,
                baseEnvironment: settings.baseEnvironment ?? ProcessInfo.processInfo.environment, environment: extras.environment,
                limits: settings.limits)
            if !extras.mcpServers.isEmpty {
                append(.log("MCP servers: \(extras.mcpServers.map(\.name).joined(separator: ", "))"), to: id)
            }
            let session: any AgentHarnessSession
            if let skillSources {
                let skills = await skillSources()
                launch.skills = skills
                launch.instructions = AgentSkillNotes.appending(to: launch.instructions, skills: skills, harness: settings.harness)
            }
            do {
                session = try await harness.start(launch, message: message, images: images)
            } catch where launch.resumeThreadID != nil {
                // The harness lost the conversation (deleted history, different home): start fresh with context.
                append(.log("Couldn't resume the previous conversation (\(error)); starting a new one."), to: id)
                update(id) { record in
                    record.threadID = nil
                    record.usageCursor = settings.harness.reportsCumulativeUsage ? AgentTokenUsage() : nil
                }
                launch.resumeThreadID = nil
                let context = "You worked in this folder before; your notes are in AGENTS.md and earlier results in report.md and output/.\n\n"
                session = try await harness.start(launch, message: context + message, images: images)
            }
            if isShutDown {
                await session.close()
                finishRun(id, outcome: .interrupted, finalText: nil, error: nil)
                return
            }
            attach(session, to: id)
            // A harness restarted after a crash keeps the run's step count and clock.
            if watches[id] == nil { resetWatch(id) }
            update(id) { record in
                if record.status == .queued { record.status = .running }
                if record.lastProgress == nil || record.lastProgress == "Starting" {
                    record.lastProgress = (record.runs.count <= 1 ? record.startCue : nil) ?? "Working on it"
                }
            }
            for text in pendingWhileStarting.removeValue(forKey: id) ?? [] {
                guard let entry = live[id] else { break }
                _ = await sendFollowUp(text, to: entry, jobID: id)
            }
            closeIfIdle(id)
            if interruptWhenStarted.remove(id) != nil { await session.interrupt() }
        } catch {
            pendingWhileStarting[id] = nil
            interruptWhenStarted.remove(id)
            finishRun(id, outcome: .failed, finalText: nil, error: "\(error)")
            throw error
        }
    }

    /// Sends a follow-up to a live session and records what the harness did with it. Counted in `sendsInFlight`
    /// while it is on its way, so a turn that finishes meanwhile doesn't close the session under it.
    private func sendFollowUp(_ text: String, to entry: Live, jobID id: String) async -> Result<AgentSendDisposition, any Error> {
        sendsInFlight[id, default: 0] += 1
        let sent: Result<AgentSendDisposition, any Error>
        do {
            sent = .success(try await entry.session.send(AgentInstructions.followUp(text)))
        } catch {
            sent = .failure(error)
        }
        sendsInFlight[id, default: 1] -= 1
        if sendsInFlight[id] == 0 { sendsInFlight[id] = nil }
        guard live[id]?.token == entry.token, case .success(var disposition) = sent else { return sent }
        // The turn it was queued behind finished while it was on its way: the harness takes it as the next turn now.
        if disposition == .queued, records[id]?.runs.last?.finishedAt != nil { disposition = .startedTurn }
        switch disposition {
        case .steered:
            update(id) { $0.runs[$0.runs.count - 1].ask += "\n\nFollow-up: \(text)" }
        case .queued:
            queuedRuns[id, default: []].append(text)
        case .startedTurn:
            update(id) { record in
                record.runs.append(AgentRun(ask: text, startedAt: self.now()))
                record.status = .running
                Self.setRoutineConfirmationAside(&record)
            }
            markRunStarted(id)
            resetWatch(id)
        }
        return .success(disposition)
    }

    /// Closes a live session whose turn finished while a follow-up was on its way, once no follow-up is left in flight
    /// or queued and no new turn started.
    private func closeIfIdle(_ id: String) {
        guard sendsInFlight[id] == nil, let entry = live[id], queuedRuns[id]?.isEmpty ?? true,
              records[id]?.runs.last?.finishedAt != nil else { return }
        live[id] = nil
        Task { await entry.session.close() }
    }

    private func attach(_ session: any AgentHarnessSession, to id: String) {
        let token = UUID()
        live[id] = Live(token: token, session: session)
        Task { [weak self] in
            for await event in session.events { await self?.handle(event, jobID: id) }
            await self?.sessionEnded(id, token: token)
        }
    }

    // MARK: Controlling

    /// Stops the job's current turn. Returns false if nothing was running.
    @discardableResult
    public func interrupt(_ reference: String) async -> Bool {
        guard let record = resolve(reference) else { return false }
        queuedRuns[record.id] = nil
        // A stopped job no longer asks for Chrome, and doesn't start again when it connects.
        let waitedForChrome = chromeSetup.removeValue(forKey: record.id) != nil || awaitingChrome.remove(record.id) != nil
        if starting.contains(record.id), live[record.id] == nil {
            interruptWhenStarted.insert(record.id)
            return true
        }
        guard let session = live[record.id]?.session else {
            guard waitedForChrome else { return false }
            update(record.id) { record in
                if record.pendingRequest?.kind == .chromeSetup { record.pendingRequest = nil }
                record.status = .stopped
                record.lastProgress = "Stopped"
            }
            append(.log("Stopped while waiting for Chrome."), to: record.id)
            return true
        }
        update(record.id) { $0.lastProgress = "Stopping…" }
        await session.interrupt()
        return true
    }

    public enum AnswerResult: String, Sendable { case answered, sentAsFollowUp = "sent_as_follow_up" }

    // MARK: Browser

    /// A job called the browser while none is connected: ask the user (a `chrome_setup` request) once. Returns
    /// whether the job is now asking (also true when it already was).
    @discardableResult
    public func requestChromeSetup(jobID: String) -> Bool {
        guard let record = resolve(jobID) else { return false }
        if chromeSetup[record.id] != nil || awaitingChrome.contains(record.id) { return true }
        let request = AgentApprovalRequest(id: "chrome-setup-\(UUID().uuidString.prefix(8).lowercased())", kind: .chromeSetup,
                                           summary: "Connect Chrome so this job can work in sites you're signed in to",
                                           options: ["Connect Chrome", "Not now"])
        chromeSetup[record.id] = request
        append(.log("Asked the user to connect Chrome: the job called the browser and none is connected."), to: record.id)
        if record.pendingRequest == nil {
            update(record.id) { record in
                record.pendingRequest = request
                record.status = .needsYou
                record.lastProgress = "Needs your Chrome connected"
            }
        }
        return true
    }

    /// The pending `chrome_setup` request of a job, if it is asking.
    public func chromeSetupRequest(_ reference: String) -> AgentApprovalRequest? { resolve(reference).flatMap { chromeSetup[$0.id] } }

    /// The `chrome_setup` request that `answer(reference, requestID:)` would answer: the one named, or with no id the
    /// one facing the user (a harness approval raised meanwhile comes first).
    public func chromeSetupRequest(_ reference: String, answering requestID: String?) -> AgentApprovalRequest? {
        guard let record = resolve(reference), let setup = chromeSetup[record.id] else { return nil }
        if let requestID { return requestID == setup.id ? setup : nil }
        return record.pendingRequest == nil || record.pendingRequest?.id == setup.id ? setup : nil
    }

    /// Tells the manager how to check whether a browser is connected, so approving `chrome_setup` while one already
    /// is carries the job on at once instead of waiting for a connection that already happened.
    public func setBrowserConnectedCheck(_ check: (@Sendable () -> Bool)?) { browserIsConnected = check }

    /// Whether a `chrome_setup` answer says yes.
    public static func approvesChromeSetup(_ decision: AgentApprovalDecision) -> Bool {
        switch decision {
        case .approve: true
        case .decline: false
        case .answer(let text): !["no", "not now", "decline", "skip"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        }
    }

    /// A browser connected: jobs that waited for it hear they can carry on.
    public func browserConnected() async {
        let waiting = awaitingChrome.sorted()
        awaitingChrome.removeAll()
        for id in waiting {
            // A job stopped meanwhile stays stopped.
            if let status = (records[id] ?? resolve(id))?.status, status == .stopped || status == .failed { continue }
            append(.log("Chrome connected; told the job to carry on."), to: id)
            _ = try? await deliver(to: id, message: Self.chromeConnectedMessage, waitForStart: false, fromUser: false)
        }
    }

    static let chromeConnectedMessage = "The user's browser is connected now. Carry on with the website steps you left waiting, using the browser tool."
    static let chromeDeclinedMessage = "The user would rather not connect their browser now. Finish without it: use web search or a plain fetch for public pages, and for anything that needs their account, give them short numbered steps to do themselves."

    /// Keeps what a turn did in the browser on the run it belongs to (the latest run started before its first call).
    public func recordBrowserUsage(jobID: String, _ usage: BrowserTurnUsage) {
        guard records[jobID] != nil || resolve(jobID) != nil else { return }
        if records[jobID] == nil { records[jobID] = resolve(jobID) }
        update(jobID, touch: false) { record in
            guard let index = record.runs.lastIndex(where: { $0.startedAt <= usage.firstCallAt }) ?? record.runs.indices.last else { return }
            record.runs[index].browser = usage
        }
        append(.log(usage.summary), to: jobID)
        try? store.writeIndex()
    }

    /// Answers a `chrome_setup` request: approve waits for Chrome to connect (the caller opens Settings → Browser),
    /// decline tells the job to go on without it.
    private func answerChromeSetup(_ record: AgentJobRecord, _ request: AgentApprovalRequest, decision: AgentApprovalDecision) async throws -> AnswerResult {
        let id = record.id
        chromeSetup[id] = nil
        let approved = Self.approvesChromeSetup(decision)
        update(id) { record in
            if record.pendingRequest?.id == request.id {
                record.pendingRequest = nil
                if record.status == .needsYou { record.status = self.isRunning(id) ? .running : .done }
                record.lastProgress = approved ? "Waiting for Chrome to connect" : "Continuing without Chrome"
            }
        }
        if approved {
            if browserIsConnected?() == true {
                // Connected before the answer came: no connect event will follow, so carry on now.
                append(.log("The user approved and Chrome is already connected; told the job to carry on."), to: id)
                _ = try await deliver(to: id, message: Self.chromeConnectedMessage, waitForStart: false, fromUser: false)
                return .sentAsFollowUp
            }
            awaitingChrome.insert(id)
            append(.log("The user is connecting Chrome."), to: id)
            return .answered
        }
        append(.log("The user declined to connect Chrome."), to: id)
        _ = try await deliver(to: id, message: Self.chromeDeclinedMessage, waitForStart: false, fromUser: false)
        return .sentAsFollowUp
    }

    /// Answers the job's pending approval or question. A question the agent asked in its report is answered by
    /// sending the answer as a follow-up.
    /// Only a direct user-control callback may set `fromUser`; model-facing tools must leave it false.
    @discardableResult
    public func answer(_ reference: String, requestID: String? = nil, decision: AgentApprovalDecision, fromUser: Bool = false) async throws -> AnswerResult {
        guard let record = resolve(reference) else { throw AgentManagerError.unknownJob(reference) }
        if let setup = chromeSetupRequest(record.id, answering: requestID) {
            return try await answerChromeSetup(record, setup, decision: decision)
        }
        // OpenClicky's own requests: a tool waiting on a confirmation, routines proposed in a report, a user step.
        let localID = requestID ?? record.pendingRequest?.id
        if let localID, let waiter = localWaiters[localID] {
            guard waiter.request.kind != .browserAction || fromUser else {
                throw AgentManagerError.configuration("Browser changes must be confirmed in OpenClicky's user controls. A model cannot answer this request.")
            }
            noteDecision(decision, on: record.pendingRequest ?? AgentApprovalRequest(id: localID, kind: .tool, summary: "a confirmation"), for: record.id)
            resolveLocal(localID, jobID: record.id, decision: decision)
            return .answered
        }
        // Routines proposed in a report: answered by their confirmation's id (also while a later turn runs), or with
        // no id when no step waits too. With a step waiting, an answer with no id is about the step ("I'm done").
        if let proposals = record.pendingRoutines, !proposals.isEmpty,
           requestID.map(Self.isRoutineConfirmation) ?? (live[record.id] == nil && record.waitingStep == nil) {
            await resolveRoutineProposals(record, proposals, decision: decision)
            return .answered
        }
        // A confirmation for routines already answered: never hand OpenClicky's own id to the harness.
        if Self.isRoutineConfirmation(requestID) { throw AgentManagerError.nothingToAnswer(record.id) }
        if let step = record.waitingStep, live[record.id] == nil, requestID == nil || requestID == record.pendingRequest?.id {
            switch decision {
            case .decline:
                noteAnswer("Won't do the step \"\(AgentText.shorten(step.step, limit: 120))\"", for: record.id)
                update(record.id) { record in
                    record.waitingStep = nil
                    // Routines the same report proposed still wait for their own answer.
                    record.status = record.pendingRoutines?.isEmpty == false ? .needsYou : .done
                    record.lastProgress = "Ended: you skipped the step"
                }
                try? store.writeIndex()
                return .answered
            case .approve:
                _ = try await continueAfterUserStep(record.id)
            case .answer(let text):
                _ = try await continueAfterUserStep(record.id, note: text)
            }
            return .sentAsFollowUp
        }
        if let session = live[record.id]?.session, let requestID = requestID ?? record.pendingRequest?.id {
            let request = [record.pendingRequest].compactMap { $0 }.first { $0.id == requestID }
                ?? waitingRequests[record.id]?.first { $0.id == requestID }
            try await session.respond(to: requestID, with: decision)
            if let request { noteDecision(decision, on: request, for: record.id) }
            return .answered
        }
        if record.status == .needsYou, let question = record.report?.question {
            let text: String = switch decision {
            case .answer(let text): text
            case .approve: "Yes, go ahead."
            case .decline: "No, don't do that. Wrap up with what you have."
            }
            noteAnswer("Answered \"\(AgentText.shorten(question, limit: 120))\": \(text)", for: record.id)
            _ = try await deliver(to: record.id, message: text, waitForStart: false, fromUser: false)
            return .sentAsFollowUp
        }
        throw AgentManagerError.nothingToAnswer(record.id)
    }

    /// Marks jobs that were running when OpenClicky last quit as stopped, so they don't look busy forever. A job
    /// waiting on a question from its finished report had nothing running; it stays waiting for `maintain` and
    /// `answer`.
    public func recoverInterruptedJobs() {
        for var record in store.all() where record.status.isActive && live[record.id] == nil && !starting.contains(record.id) {
            let lastRunFinished = record.runs.last.map({ $0.finishedAt != nil }) ?? true
            if record.status == .needsYou, record.pendingRequest == nil, record.report?.question != nil, lastRunFinished { continue }
            // A step the user still has to do, or routines waiting on their yes, outlive the app too.
            if record.status == .needsYou, lastRunFinished, record.waitingStep != nil || record.pendingRoutines?.isEmpty == false { continue }
            record.status = .stopped
            record.pendingRequest = nil
            record.lastProgress = "Stopped before it finished (OpenClicky quit)"
            if !record.runs.isEmpty, record.runs[record.runs.count - 1].finishedAt == nil {
                record.runs[record.runs.count - 1].finishedAt = now()
                record.runs[record.runs.count - 1].outcome = .interrupted
            }
            record.updatedAt = now()
            try? store.save(record)
            records[record.id] = record
            publish(.job(record))
        }
        try? store.writeIndex()
    }

    /// Stops every running harness (app quit).
    public func shutdown() async {
        isShutDown = true
        for (id, entry) in live {
            await entry.session.interrupt()
            await entry.session.close()
            finishRun(id, outcome: .interrupted, finalText: nil, error: nil)
        }
        live.removeAll()
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, jobID id: String) async {
        append(event, to: id)
        publish(.event(jobID: id, event))
        await watch(event, jobID: id)
        switch event {
        case .log:
            return
        case .compacted:
            await compacted(id)
        case .commentary(let text):
            update(id) { record in
                record.lastSaid = AgentText.firstLine(AgentText.stripCitations(text), limit: 200)
                if let line = event.progressLine { record.lastProgress = line }
            }
        case .fileWillChange(let path):
            if fileDiffsEnabled?() == true { diffRecorders[id, default: AgentFileDiffRecorder()].willChange(path) }
        case .fileChanged(let path, let change):
            if fileDiffsEnabled?() == true { diffRecorders[id, default: AgentFileDiffRecorder()].changed(path, change: change) }
            updateLedger(id) { $0.touch(path, change: change) }
            if let line = event.progressLine { update(id) { $0.lastProgress = line } }
        case .sessionStarted(let threadID):
            update(id) { $0.threadID = threadID }
        case .turnStarted:
            update(id) { if $0.status == .queued { $0.status = .running } }
        case .approvalRequested(let request):
            // One request at a time faces the user; parallel ones wait their turn. The harness's own request goes
            // before a chrome_setup one (which has no timer and is shown again once nothing else waits).
            if let current = records[id]?.pendingRequest, current.id != request.id, current.kind != .chromeSetup {
                waitingRequests[id, default: []].append(request)
            } else {
                present(request, jobID: id)
            }
        case .approvalResolved(let requestID):
            waitingRequests[id]?.removeAll { $0.id == requestID }
            guard records[id]?.pendingRequest?.id == requestID else { break }
            approvalTokens[id] = nil
            if let next = waitingRequests[id]?.first {
                waitingRequests[id]?.removeFirst()
                present(next, jobID: id)
            } else if let setup = chromeSetup[id] {
                update(id) { record in
                    record.pendingRequest = setup
                    record.status = .needsYou
                    record.lastProgress = "Needs your Chrome connected"
                }
            } else {
                update(id) { record in
                    record.pendingRequest = nil
                    record.status = .running
                    record.lastProgress = "Continuing"
                }
            }
        case .usage(let reported):
            await noteUsage(reported, jobID: id)
        case .error(let message, let fatal):
            update(id) { record in
                if fatal { record.error = message }
                record.lastProgress = event.progressLine
            }
        case .turnFinished(let outcome, let finalText, let error):
            if outcome == .failed, finalText == nil, let error, AgentHarnessExit.isExit(error) {
                if await resumeAfterCrash(id, exit: error) { return }
                let exits = records[id]?.runs.last?.harnessExits ?? []
                finishRun(id, outcome: .failed, finalText: nil,
                          error: exits.count > 1 ? "The agent stopped twice mid-task: " + exits.joined(separator: "; then ") : error)
            } else {
                finishRun(id, outcome: outcome, finalText: finalText, error: error)
            }
            if let next = queuedRuns[id]?.first {
                queuedRuns[id]?.removeFirst()
                update(id) { record in
                    record.runs.append(AgentRun(ask: next, startedAt: self.now()))
                    record.status = .running
                    record.lastProgress = "Working on your follow-up"
                    Self.setRoutineConfirmationAside(&record)
                }
                markRunStarted(id)
                resetWatch(id)
            } else if let entry = live[id], sendsInFlight[id] == nil {
                // Done for now. A later follow-up relaunches the harness and resumes the conversation. (With a
                // follow-up on its way, `closeIfIdle` closes it after the send if it didn't start a new turn.)
                live[id] = nil
                await entry.session.close()
            }
        default:
            if let line = event.progressLine { update(id) { $0.lastProgress = line } }
        }
    }

    /// Adds what a usage report hasn't counted yet to the job's total and the ledger. Codex repeats its running total
    /// after every model call, so only the growth since the last report counts.
    private func noteUsage(_ reported: AgentTokenUsage, jobID id: String) async {
        guard let record = records[id] ?? store.load(id: id) else { return }
        let cumulative = record.harness.reportsCumulativeUsage
        let cursor = AgentUsageMeter.cursor(for: record)
        let delta = AgentUsageMeter.delta(reported: reported, cursor: cursor, cumulative: cumulative)
        update(id) { record in
            record.usage = record.usage + delta
            if cumulative { record.usageCursor = reported }
        }
        guard !delta.isZero, let usageRecorder, let updated = records[id] else { return }
        usageRecorder.record(job: updated, delta: delta,
                             oneCall: AgentUsageMeter.coversOneCall(reported: reported, cursor: cursor, cumulative: cumulative), at: now())
        await stopPaidJobsAtLimit()
    }

    /// The usage limit, when it is reached and set to stop paid calls; nil otherwise or with no ledger.
    private func blockingLimit() -> UsageLimitStatus? {
        guard let status = usageRecorder?.recorder.limitStatus(), status.blocksCalls else { return nil }
        return status
    }

    /// Stops the running jobs billed per token once the user's spending limit stops paid calls. Jobs on the harness's
    /// own sign-in aren't billed per token and keep going.
    private func stopPaidJobsAtLimit() async {
        guard let status = blockingLimit() else { return }
        let reason = UsageLimitError(status: status).description
        for id in Array(live.keys) where records[id]?.provider != AgentLaunchSettings.loginProviderID {
            guard live[id] != nil, watches[id]?.stopReason == nil else { continue }
            await stopForLimit(id, reason: reason)
        }
    }

    private func present(_ request: AgentApprovalRequest, jobID id: String) {
        update(id) { record in
            record.pendingRequest = request
            record.status = .needsYou
            record.lastProgress = AgentEvent.approvalRequested(request).progressLine
        }
        let wait = timeout(for: request)
        let token = UUID()
        approvalTokens[id] = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await self?.expire(request, jobID: id, token: token)
        }
    }

    private func timeout(for request: AgentApprovalRequest) -> TimeInterval {
        localWaiters[request.id] != nil ? min(approvalTimeout, Self.localConfirmTimeout) : approvalTimeout
    }

    /// The user never answered: decline (or answer the question with "assume"), and say so in the log.
    private func expire(_ request: AgentApprovalRequest, jobID id: String, token: UUID) async {
        guard approvalTokens[id] == token, records[id]?.pendingRequest?.id == request.id else { return }
        if localWaiters[request.id] != nil {
            approvalTokens[id] = nil
            append(.log("No answer to \"\(request.summary)\" after \(Int(timeout(for: request) / 60)) min; declined."), to: id)
            resolveLocal(request.id, jobID: id, decision: nil)
            return
        }
        guard let session = live[id]?.session else { return }
        approvalTokens[id] = nil
        let decision: AgentApprovalDecision = request.kind == .question
            ? .answer("The user didn't answer. Make the most reasonable assumption, carry on, and say what you assumed in your report.")
            : .decline
        append(.log("No answer to \"\(request.summary)\" after \(Int(approvalTimeout / 60)) min; \(request.kind == .question ? "told the agent to assume" : "declined")."), to: id)
        try? await session.respond(to: request.id, with: decision)
    }

    private func sessionEnded(_ id: String, token: UUID) {
        guard live[id]?.token == token else { return }
        live[id] = nil
        queuedRuns[id] = nil
        if let record = records[id], record.status.isActive {
            finishRun(id, outcome: .failed, finalText: nil, error: "The agent stopped unexpectedly.")
        }
    }

    private func finishRun(_ id: String, outcome: AgentTurnOutcome, finalText: String?, error: String?) {
        endLocalConfirmations(of: id)
        waitingRequests[id] = nil
        approvalTokens[id] = nil
        if outcome != .completed {
            // A stopped or failed job no longer waits for Chrome.
            chromeSetup[id] = nil
            awaitingChrome.remove(id)
        }
        let stopReason = watches.removeValue(forKey: id)?.stopReason
        crashResumed.remove(id)
        let report = finalText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : AgentFinalReport.parse($0, now: now()) }
        let outputs = records[id].map { store.outputs(of: $0) } ?? []
        let proposals = outcome == .completed ? (report?.routineRequests ?? []) : []
        var diffs: [AgentFileDiffItem] = []
        if let recorder = diffRecorders.removeValue(forKey: id), !recorder.isEmpty, let current = records[id] ?? resolve(id) {
            diffs = recorder.finish(run: max(1, current.runs.count), folder: current.folder, at: now())
        }
        update(id) { record in
            if !diffs.isEmpty { record.fileDiffs = AgentFileDiffs.merged(record.fileDiffs, diffs, folder: record.folder) }
            record.pendingRequest = nil
            // A new result: unseen, and back in the panel if it was closed there.
            record.isSeen = false
            record.isDismissed = nil
            switch outcome {
            case .completed:
                record.report = report ?? AgentFinalReport(markdown: "", spoken: "")
                record.waitingStep = report?.waitFor
                // Proposals from an earlier report the user hasn't answered yet are asked again with the new ones.
                let carried = record.pendingRoutines ?? []
                let routines = carried + proposals.filter { !carried.contains($0) }
                record.pendingRoutines = routines.isEmpty ? nil : routines
                if !routines.isEmpty { record.pendingRequest = Self.routineConfirmation(routines) }
                record.status = report?.question != nil || report?.waitFor != nil || !routines.isEmpty ? .needsYou : .done
                record.error = nil
                record.lastProgress = report?.waitFor.map { "Waiting for you: \($0.step)" } ?? "Finished"
            case .interrupted:
                if let report { record.report = report }
                record.status = .stopped
                record.lastProgress = stopReason ?? "Stopped"
                // A limit stop is told as the reason, not as the user stopping it.
                record.error = stopReason
            case .failed:
                if let report { record.report = report }
                record.status = .failed
                record.error = stopReason ?? error ?? "The agent stopped with an error."
                record.lastProgress = "Failed"
            }
            if let report, outcome != .failed {
                record.deliverableKind = AgentDeliverableKind.classify(files: report.files.isEmpty ? outputs : report.files,
                                                                      reportLength: report.markdown.count)
            }
            if let setup = self.chromeSetup[id], outcome == .completed {
                // The job ended its turn waiting for Chrome: it still asks.
                record.pendingRequest = setup
                record.status = .needsYou
                record.lastProgress = "Needs your Chrome connected"
            }
            if !record.runs.isEmpty {
                let index = record.runs.count - 1
                record.runs[index].finishedAt = self.now()
                record.runs[index].outcome = outcome
                record.runs[index].spoken = report?.spoken
                record.runs[index].stopReason = stopReason
            }
        }
        guard let record = records[id] else { return }
        try? store.writeReport(for: record)
        try? store.writeIndex()
        if record.status == .needsYou, record.pendingRequest == nil, record.report?.question != nil,
           record.runs.last?.trigger != AgentRun.assumeTrigger {
            scheduleAssume(id, after: (jobLimits[id] ?? AgentLimits()).assumeAfterSeconds)
        }
        publish(.report(AgentJobReport.make(record: record, outputs: store.outputs(of: record), finishedAt: now())))
    }

    // MARK: Limits

    /// Counts the run's steps and stops it at the step cap; records side effects in the ledger.
    private func watch(_ event: AgentEvent, jobID id: String) async {
        if let effect = AgentJobLedger.sideEffect(of: event) { updateLedger(id) { $0.addSideEffect(effect, at: self.now()) } }
        guard Self.isStep(event), var watch = watches[id] else { return }
        watch.steps += 1
        watches[id] = watch
        let cap = (jobLimits[id] ?? AgentLimits()).maxStepsPerRun
        if cap > 0, watch.steps > cap, watch.stopReason == nil {
            await stopForLimit(id, reason: "It reached the limit of \(cap) steps for one task, so OpenClicky stopped it.")
        }
    }

    /// A tool starting: a command, a file edit, an app or web call. Outcome lines (a failure, a skipped command) and
    /// OpenClicky's own notices don't count.
    static func isStep(_ event: AgentEvent) -> Bool {
        guard case .progress(let line) = event else { return false }
        let notSteps = ["Skipped:", "Command failed", "Got your follow-up", "Retrying", "Tidying up"]
        return !notSteps.contains { line.hasPrefix($0) } && !line.hasSuffix("didn't work") && !line.contains(" failed: ")
    }

    /// A fresh watch for the run that just started (step count zero, its own wall clock).
    private func resetWatch(_ id: String) {
        let watch = RunWatch(startedAt: now())
        watches[id] = watch
        let limit = (jobLimits[id] ?? AgentLimits()).maxRunSeconds
        guard limit > 0 else { return }
        let token = watch.token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            await self?.wallClockExpired(id, token: token, limit: limit)
        }
    }

    private func wallClockExpired(_ id: String, token: UUID, limit: TimeInterval) async {
        guard watches[id]?.token == token, watches[id]?.stopReason == nil, live[id] != nil else { return }
        await stopForLimit(id, reason: "It ran for \(AgentLimits.phrase(limit)), the limit for one task, so OpenClicky stopped it.")
    }

    private func stopForLimit(_ id: String, reason: String) async {
        watches[id]?.stopReason = reason
        append(.log(reason), to: id)
        queuedRuns[id] = nil
        update(id) { $0.lastProgress = "Stopping: limit reached" }
        if let session = live[id]?.session { await session.interrupt() }
    }

    /// After a compaction: count it, rewrite state.md, and hand the ledger to a harness that can take it mid-turn.
    private func compacted(_ id: String) async {
        updateLedger(id) { $0.compactions += 1 }
        guard let record = records[id], let ledger = record.ledger, !ledger.isEmpty,
              record.harness == .codex, let session = live[id]?.session else { return }
        // Claude Code would only read a message after the turn, as a new one; it reads state.md as its instructions say.
        guard let disposition = try? await session.send(ledger.compactionNote(folder: record.folder)) else { return }
        append(.log("Gave the agent its state after compaction (\(disposition.rawValue))."), to: id)
        switch disposition {
        case .steered: break
        case .queued: queuedRuns[id, default: []].append("Continue after compaction")
        case .startedTurn:
            update(id) { record in
                record.runs.append(AgentRun(ask: "Continue after compaction", startedAt: self.now()))
                record.status = .running
                Self.setRoutineConfirmationAside(&record)
            }
            markRunStarted(id)
            resetWatch(id)
        }
    }

    /// Waits `after` seconds, then tells a job whose report question is still unanswered to assume and say so.
    private func scheduleAssume(_ id: String, after: TimeInterval) {
        guard after > 0 else { return }
        let token = UUID()
        assumeTokens[id] = token
        let runs = records[id]?.runs.count ?? 0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            await self?.assumeIfStillWaiting(id, token: token, runs: runs, after: after)
        }
    }

    private func assumeIfStillWaiting(_ id: String, token: UUID, runs: Int, after: TimeInterval) async {
        guard assumeTokens[id] == token else { return }
        assumeTokens[id] = nil
        await assume(id, expectedRuns: runs, after: after)
    }

    @discardableResult
    private func assume(_ id: String, expectedRuns: Int?, after: TimeInterval) async -> Bool {
        guard let record = records[id] ?? resolve(id), record.status == .needsYou, record.pendingRequest == nil,
              let question = record.report?.question, !isRunning(id), record.runs.last?.trigger != AgentRun.assumeTrigger,
              expectedRuns == nil || record.runs.count == expectedRuns else { return false }
        append(.log("No answer to \"\(AgentText.shorten(question, limit: 100))\" after \(AgentLimits.phrase(after)); told the agent to assume and say so."), to: id)
        guard (try? await deliver(to: id, message: AgentInstructions.assumeFollowUp(question: question), waitForStart: false, fromUser: false)) != nil
        else { return false }
        update(id) { record in
            guard !record.runs.isEmpty else { return }
            record.runs[record.runs.count - 1].trigger = AgentRun.assumeTrigger
            record.runs[record.runs.count - 1].ask = "(No answer yet: carry on with a reasonable assumption)"
        }
        return true
    }

    /// What `maintain` did.
    public struct MaintenanceResult: Sendable, Equatable {
        /// Jobs told to assume an answer (their question went unanswered while OpenClicky was closed).
        public var assumed: [String] = []
        /// Jobs no longer waiting on the user after `idleEndSeconds`.
        public var ended: [String] = []
        /// Jobs whose scratch, log and task screenshots were removed.
        public var cleaned: [String] = []
    }

    /// The periodic sweep (at start and then hourly): the assume fallback for questions that went unanswered while
    /// OpenClicky was closed, the idle end for jobs left waiting on the user, the cleanup of jobs idle for
    /// `cleanupAfterDays`, and of kept agents' task screenshots older than that. Sweeping doesn't reorder the job list: records it changes keep their `updatedAt`.
    @discardableResult
    public func maintain(limits: AgentLimits) async -> MaintenanceResult {
        var result = MaintenanceResult()
        let current = now()
        for stored in store.all() {
            let id = stored.id
            guard let record = records[id] ?? Optional(stored), !isRunning(id), !starting.contains(id) else { continue }
            let quiet = current.timeIntervalSince(record.updatedAt)
            if record.status == .needsYou, record.pendingRequest == nil, record.report?.question != nil,
               limits.assumeAfterSeconds > 0, assumeTokens[id] == nil, quiet >= limits.assumeAfterSeconds,
               limits.idleEndSeconds <= 0 || quiet < limits.idleEndSeconds {
                jobLimits[id] = jobLimits[id] ?? limits
                if await assume(id, expectedRuns: nil, after: quiet) { result.assumed.append(id) }
                continue
            }
            if record.status == .needsYou, limits.idleEndSeconds > 0, quiet >= limits.idleEndSeconds {
                assumeTokens[id] = nil
                update(id, touch: false) { record in
                    record.status = .done
                    record.pendingRequest = nil
                    record.lastProgress = "Ended: no answer after \(AgentLimits.phrase(limits.idleEndSeconds))"
                }
                append(.log("Ended after \(AgentLimits.phrase(limits.idleEndSeconds)) waiting on the user."), to: id)
                result.ended.append(id)
                continue
            }
            guard !record.status.isActive, limits.cleanupAfterDays > 0 else { continue }
            let age = TimeInterval(limits.cleanupAfterDays) * 86_400
            if record.isKept {
                // A kept agent in regular use is never idle that long: its old runs' screenshots go on every sweep.
                if !store.cleanUp(record, olderThan: current.addingTimeInterval(-age)).isEmpty { result.cleaned.append(id) }
            } else if record.cleanedAt == nil, quiet >= age {
                store.cleanUp(record, olderThan: current.addingTimeInterval(-age))
                update(id, touch: false) { $0.cleanedAt = current }
                result.cleaned.append(id)
            }
        }
        if !result.ended.isEmpty { try? store.writeIndex() }
        return result
    }

    /// Servers with a job header get this job's id in it (as a secret header, out of the agent's shell's reach).
    static func identifyingJob(_ id: String, in servers: [AgentMCPServer]) -> [AgentMCPServer] {
        servers.map { $0.identifyingJob(id) }
    }

    // MARK: Crashes

    /// The harness died mid-turn: restart it once and resume its conversation with a note to pick up from state.md.
    /// Returns false when the run should fail instead (a second exit, a stop OpenClicky asked for, shutting down).
    private func resumeAfterCrash(_ id: String, exit: String) async -> Bool {
        let line = AgentText.firstLine(exit, limit: 240)
        update(id) { record in
            guard !record.runs.isEmpty else { return }
            record.runs[record.runs.count - 1].harnessExits = (record.runs[record.runs.count - 1].harnessExits ?? []) + [line]
        }
        guard !isShutDown, watches[id]?.stopReason == nil, !crashResumed.contains(id), let preference = launchPreferences[id],
              let record = records[id] else { return false }
        crashResumed.insert(id)
        append(.log("The agent stopped mid-turn (\(line)); restarting it once to resume."), to: id)
        if let entry = live.removeValue(forKey: id) { Task { await entry.session.close() } }
        // Follow-ups the dead harness had queued are sent again once it is back.
        let queued = queuedRuns.removeValue(forKey: id) ?? []
        if !queued.isEmpty { pendingWhileStarting[id, default: []].append(contentsOf: queued) }
        endLocalConfirmations(of: id)
        waitingRequests[id] = nil
        approvalTokens[id] = nil
        update(id) { record in
            record.pendingRequest = nil
            record.status = .running
            record.lastProgress = "Restarting after the agent stopped"
        }
        let message = AgentInstructions.resumeAfterCrash(ask: record.runs.last?.ask ?? record.task, resumingConversation: record.threadID != nil)
        // The same run goes on: its marker again, so the transcript keeps the resumed events in it.
        markRunStarted(id)
        starting.insert(id)
        Task { try? await self.launch(id, message: message, images: [], preference: preference) }
        return true
    }

    // MARK: OpenClicky's own requests

    static func routineConfirmation(_ proposals: [AgentRoutineRequest]) -> AgentApprovalRequest {
        let summary = proposals.count == 1 ? proposals[0].summary : "\(proposals.count) routine changes: " + proposals.map(\.summary).joined(separator: "; ")
        return AgentApprovalRequest(id: routineRequestPrefix + AgentJobStore.randomHex(6), kind: .tool,
                                    summary: AgentText.shorten(summary, limit: 300),
                                    reason: proposals.first?.task.map { "Each run: \(AgentText.shorten($0, limit: 200))" })
    }

    /// A new turn starts while routines from the last report wait for the user: they keep waiting (`pendingRoutines`,
    /// answered by the confirmation's id), but the confirmation stops facing the user so the harness's own approvals
    /// in this turn reach them. `finishRun` asks again.
    static func setRoutineConfirmationAside(_ record: inout AgentJobRecord) {
        if isRoutineConfirmation(record.pendingRequest?.id) { record.pendingRequest = nil }
    }

    private func resolveRoutineProposals(_ record: AgentJobRecord, _ proposals: [AgentRoutineRequest], decision: AgentApprovalDecision) async {
        let id = record.id
        let approved: Bool = switch decision {
        case .approve: true
        case .decline: false
        case .answer(let text): ["yes", "ok", "okay", "sure", "go ahead", "do it", "y"].contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
        }
        var done: [String] = []
        var failed: [String] = []
        if approved {
            for proposal in proposals {
                guard let routineApplier else { failed.append("\(proposal.summary): routines aren't available"); continue }
                do { done.append(try await routineApplier(proposal, records[id] ?? record)) } catch { failed.append("\(proposal.summary): \(error)") }
            }
        }
        noteAnswer(approved ? "Said yes to: \(proposals.map(\.summary).joined(separator: "; "))" : "Said no to: \(proposals.map(\.summary).joined(separator: "; "))", for: id)
        for line in done { append(.log("Routine: \(line)"), to: id) }
        for line in failed { append(.log("Routine not applied: \(line)"), to: id) }
        update(id) { record in
            record.pendingRoutines = nil
            // Only the routine confirmation: a later turn may be waiting on the harness's own request.
            if Self.isRoutineConfirmation(record.pendingRequest?.id) { record.pendingRequest = nil }
            if record.status == .needsYou, record.pendingRequest == nil {
                record.status = record.waitingStep != nil || record.report?.question != nil ? .needsYou : .done
            }
            record.lastProgress = !approved ? "Routine not set up"
                : failed.isEmpty ? (done.first ?? "Routine set up") : "Routine not set up: \(failed[0])"
        }
        try? store.writeIndex()
    }

    /// Asks the user to confirm something a running job's tool wants, through the same needs-you
    /// flow as a harness approval. Returns their decision, or nil when it timed out or the job isn't known.
    public func confirm(_ reference: String, summary: String, reason: String? = nil,
                        kind: AgentApprovalRequest.Kind = .tool) async -> AgentApprovalDecision? {
        guard let record = resolve(reference) else { return nil }
        let id = record.id
        if records[id] == nil { records[id] = record }
        let request = AgentApprovalRequest(id: Self.localRequestPrefix + AgentJobStore.randomHex(8), kind: kind,
                                           summary: AgentText.shorten(summary, limit: 300), reason: reason)
        append(.approvalRequested(request), to: id)
        publish(.event(jobID: id, .approvalRequested(request)))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                localWaiters[request.id] = (id, request, continuation)
                if let current = records[id]?.pendingRequest, current.id != request.id {
                    waitingRequests[id, default: []].append(request)
                } else {
                    present(request, jobID: id)
                }
            }
        } onCancel: {
            Task { await self.resolveLocal(request.id, jobID: id, decision: nil) }
        }
    }

    /// Hands a local request's decision to its waiter and moves on to the next request (or back to work).
    private func resolveLocal(_ requestID: String, jobID id: String, decision: AgentApprovalDecision?) {
        guard localWaiters[requestID] != nil else { return }
        localWaiters.removeValue(forKey: requestID)?.continuation.resume(returning: decision)
        append(.approvalResolved(id: requestID), to: id)
        publish(.event(jobID: id, .approvalResolved(id: requestID)))
        waitingRequests[id]?.removeAll { $0.id == requestID }
        guard records[id]?.pendingRequest?.id == requestID else { return }
        approvalTokens[id] = nil
        if let next = waitingRequests[id]?.first {
            waitingRequests[id]?.removeFirst()
            present(next, jobID: id)
        } else {
            update(id) { record in
                record.pendingRequest = nil
                if record.status == .needsYou { record.status = .running }
                record.lastProgress = "Continuing"
            }
        }
    }

    /// The run ended (finished, stopped, or its harness died) while its own tool still waited on a confirmation: that
    /// tool call is gone, so the confirmation ends unanswered and its waiter gets nil.
    private func endLocalConfirmations(of id: String) {
        for (requestID, waiter) in localWaiters where waiter.job == id {
            localWaiters[requestID] = nil
            waiter.continuation.resume(returning: nil)
            append(.approvalResolved(id: requestID), to: id)
            publish(.event(jobID: id, .approvalResolved(id: requestID)))
        }
    }

    /// The user did the step the job was waiting for ("I'm done"): a follow-up run checks it and carries on.
    @discardableResult
    public func continueAfterUserStep(_ reference: String, note: String? = nil) async throws -> AgentJobRecord {
        guard let record = resolve(reference) else { throw AgentManagerError.unknownJob(reference) }
        guard let step = record.waitingStep else { throw AgentManagerError.nothingToAnswer(record.id) }
        noteAnswer("Did the step \"\(AgentText.shorten(step.step, limit: 120))\"\(note.map { ": \($0)" } ?? "")", for: record.id)
        update(record.id) { $0.waitingStep = nil }
        let (updated, _) = try await deliver(to: record.id, message: AgentInstructions.userStepDone(step, note: note), waitForStart: false, fromUser: false)
        return updated
    }

    // MARK: List state

    /// The user opened the job's result.
    public func markSeen(_ reference: String, _ seen: Bool = true) {
        guard let record = resolve(reference), record.isSeen != seen else { return }
        update(record.id, touch: false) { $0.isSeen = seen }
    }

    /// Closes the job in the jobs panel (it stays in Home → Agents).
    public func setDismissed(_ reference: String, _ dismissed: Bool = true) {
        guard let record = resolve(reference) else { return }
        update(record.id, touch: false) { $0.isDismissed = dismissed ? true : nil }
    }

    /// Moves the job out of the job list (or back). An archived job is seen and closed too.
    public func setArchived(_ reference: String, _ archived: Bool = true) {
        guard let record = resolve(reference) else { return }
        update(record.id, touch: false) { record in
            record.archivedAt = archived ? (record.archivedAt ?? self.now()) : nil
            if archived {
                record.isSeen = true
                record.isDismissed = true
            }
        }
    }

    /// A step a job took through one of OpenClicky's own tools (a web search): a progress line, like the harness's.
    public func noteToolUse(_ reference: String, line: String) {
        guard let record = resolve(reference) else { return }
        let id = record.id
        if records[id] == nil { records[id] = record }
        append(.progress(line), to: id)
        publish(.event(jobID: id, .progress(line)))
        update(id) { $0.lastProgress = line }
    }

    /// Progress a running job reported through OpenClicky's `openclicky_progress` tool: a line and/or plan steps,
    /// published like the harness's own (the HUD and the brain's context follow them). Not counted as steps.
    public func noteProgress(_ reference: String, line: String?, plan: [AgentPlanStep]?) {
        guard let record = resolve(reference) else { return }
        let id = record.id
        if records[id] == nil { records[id] = record }
        if let plan, !plan.isEmpty {
            append(.plan(plan), to: id)
            publish(.event(jobID: id, .plan(plan)))
        }
        if let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            let short = AgentText.shorten(AgentText.oneLine(line, limit: 400), limit: 200)
            append(.commentary(short), to: id)
            publish(.event(jobID: id, .commentary(short)))
            update(id) { record in
                record.lastSaid = short
                record.lastProgress = short
            }
        } else if let line = AgentEvent.plan(plan ?? []).progressLine {
            update(id) { $0.lastProgress = line }
        }
    }

    // MARK: Ledger

    private func updateLedger(_ id: String, _ change: (inout AgentJobLedger) -> Void) {
        guard records[id] != nil || store.load(id: id) != nil else { return }
        update(id) { record in
            var ledger = record.ledger ?? AgentJobLedger()
            change(&ledger)
            record.ledger = ledger
        }
        if let record = records[id] { try? store.writeState(for: record) }
    }

    private func noteAnswer(_ text: String, for id: String) {
        updateLedger(id) { $0.addAnswer(text, at: self.now()) }
    }

    private func noteDecision(_ decision: AgentApprovalDecision, on request: AgentApprovalRequest, for id: String) {
        let time = now()
        updateLedger(id) { ledger in
            switch decision {
            case .approve(let always):
                ledger.addAnswer("Approved\(always ? " (and the same again)" : ""): \(request.summary)", at: time)
                if AgentJobLedger.approvalIsSideEffect(request) { ledger.addSideEffect("With the user's yes: \(request.summary)", at: time) }
            case .decline:
                ledger.addAnswer("Declined: \(request.summary)", at: time)
            case .answer(let text):
                ledger.addAnswer("Answered \"\(AgentText.shorten(request.summary, limit: 120))\": \(text)", at: time)
            }
        }
    }

    // MARK: Records

    /// - Parameter touch: bump `updatedAt` (moves the job up the lists); sweeps leave it.
    private func update(_ id: String, touch: Bool = true, _ change: (inout AgentJobRecord) -> Void) {
        guard var record = records[id] ?? store.load(id: id) else { return }
        change(&record)
        if touch { record.updatedAt = now() }
        records[id] = record
        try? store.save(record)
        publish(.job(record))
    }

    /// Logs the run marker for the job's latest run (the transcript splits runs at these).
    private func markRunStarted(_ id: String) {
        guard let record = records[id], let run = record.runs.last else { return }
        store.appendRun(number: record.runs.count, ask: run.ask, to: record, at: now())
    }

    private func append(_ event: AgentEvent, to id: String) {
        guard let record = records[id] ?? store.load(id: id) else { return }
        store.append(event, to: record, at: now())
    }
}
