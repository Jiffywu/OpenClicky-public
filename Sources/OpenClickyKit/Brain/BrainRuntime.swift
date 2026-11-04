import Foundation

/// Settings for the brain runtime.
public struct BrainRuntimeConfiguration: Sendable {
    /// The brain slot's model id.
    public var model: String
    /// The brain slot's provider dialect: decides whether prompt-cache prewarming is possible.
    public var dialect: ProviderDialect?
    public var reasoningEffort: String?
    /// Thinking before the answer, where the provider switches it apart from the effort (Anthropic); nil keeps the
    /// adapter's default. The prewarm sends the same value, so the cache it writes is the one turns read.
    public var thinking: ThinkingMode?
    /// Output cap per model round. Programs with a 3D figure run to a few thousand tokens.
    public var maxOutputTokens: Int
    /// Model rounds per turn (the first answer plus rounds that read tool results).
    public var maxRounds: Int
    /// Tool calls per turn; later calls are answered "tool_limit_reached" without running.
    public var maxToolCallsPerTurn: Int
    public var pruning: BrainPruningPolicy
    /// A session with no turn for this long ends (memory notes are written) and the next turn starts a fresh one.
    public var idleTimeout: TimeInterval
    /// Compaction is considered once a request's input reaches this many tokens…
    public var compactionThreshold: Int
    /// …and, when there is too little to fold yet, again after this many more.
    public var compactionStep: Int
    /// User turns kept verbatim when the rest is folded into a note.
    public var compactionKeepTurns: Int
    /// Ask the provider to cache the stable prefix and the conversation (Anthropic needs this; others ignore it).
    public var promptCaching: Bool
    /// Prewarm only when the last request is at least this old (a provider cache entry lives about five minutes).
    public var prewarmAfterIdle: TimeInterval
    /// 3D figures can be drawn on this Mac.
    public var figuresAvailable: Bool

    public init(model: String, dialect: ProviderDialect? = nil, reasoningEffort: String? = nil, maxOutputTokens: Int = 8_000,
                maxRounds: Int = 4, maxToolCallsPerTurn: Int = 8, pruning: BrainPruningPolicy = BrainPruningPolicy(),
                idleTimeout: TimeInterval = 30 * 60, compactionThreshold: Int = 60_000, compactionStep: Int = 15_000,
                compactionKeepTurns: Int = 3, promptCaching: Bool = true, prewarmAfterIdle: TimeInterval = 4 * 60,
                figuresAvailable: Bool = true, thinking: ThinkingMode? = nil) {
        self.model = model
        self.dialect = dialect
        self.reasoningEffort = reasoningEffort
        self.thinking = thinking
        self.maxOutputTokens = maxOutputTokens
        self.maxRounds = max(1, maxRounds)
        self.maxToolCallsPerTurn = maxToolCallsPerTurn
        self.pruning = pruning
        self.idleTimeout = idleTimeout
        self.compactionThreshold = compactionThreshold
        self.compactionStep = max(1_000, compactionStep)
        self.compactionKeepTurns = max(1, compactionKeepTurns)
        self.promptCaching = promptCaching
        self.prewarmAfterIdle = prewarmAfterIdle
        self.figuresAvailable = figuresAvailable
    }

    /// Whether a cheap request can warm the provider's prompt cache: only providers that cache on request
    /// (Anthropic) gain from it. OpenAI caches by itself on the first real request.
    public var canPrewarm: Bool { promptCaching && dialect == .anthropicMessages }
}

/// The user's memory, as the brain uses it.
public struct BrainMemory: Sendable {
    public var store: MemoryStore
    /// Writes the session note and profile changes when a session ends (brain-fast slot). Nil skips that.
    public var writer: MemoryWriter?
    public var promptBuilder: MemoryPromptBuilder

    public init(store: MemoryStore, writer: MemoryWriter? = nil, promptBuilder: MemoryPromptBuilder = MemoryPromptBuilder()) {
        self.store = store
        self.writer = writer
        self.promptBuilder = promptBuilder
    }
}

/// What the app keeps current for the brain beyond each turn's own input: the active skills, notes such as the
/// `[Your jobs]` list, and whether 3D figures can be shown. Every source is read fresh, so a change in Settings or a job
/// finishing reaches the next turn without rebuilding the runtime.
///
/// The system prompt is fixed for a session (so the provider's prompt cache keeps matching): skills and figures are
/// read into it when a session starts. If either changes mid-session, the next turn carries a note instead
/// (`[Skill update]` with the new block, or an `[App]` note that figures stopped working).
public struct BrainContextSources: Sendable {
    /// The `<active_skills>` block (`ActiveSkillsProviding.skillsPromptSection()`), "" with none on.
    public var skills: (@Sendable () -> String)?
    /// Silent notes for the next turn, each starting with its tag ("[Your jobs] …", from
    /// `AgentCoordinator.brainContext()`). A note goes to the brain again only when its text changed since it was last
    /// sent in this session.
    public var turnNotes: (@Sendable () async -> [String])?
    /// Whether 3D figures can be drawn right now (`FigureAvailability.isAvailable`).
    public var figuresAvailable: (@Sendable () -> Bool)?

    public init(skills: (@Sendable () -> String)? = nil, turnNotes: (@Sendable () async -> [String])? = nil,
                figuresAvailable: (@Sendable () -> Bool)? = nil) {
        self.skills = skills
        self.turnNotes = turnNotes
        self.figuresAvailable = figuresAvailable
    }

    /// Skills from a library.
    public static func skills(_ provider: any ActiveSkillsProviding) -> @Sendable () -> String {
        { provider.skillsPromptSection() }
    }

    /// The note that replaces the active skills mid-session.
    public static func skillUpdateNote(_ skills: String) -> String {
        let block = skills.trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty
            ? "[Skill update] No skills are active now; set aside the # Skills section of your instructions."
            : "[Skill update] The active skills changed. Use these in place of the # Skills section of your instructions:\n" + block
    }

    static let figuresStoppedNote = "[App] 3D figures stopped working on this Mac. Don't call figure() for now; use 2D drawings."
    static let figuresBackNote = "[App] 3D figures work again on this Mac: figure() is available."
}

/// Session figures for a stats HUD and `occtl brain`.
public struct BrainSessionStats: Sendable, Hashable {
    public var sessionID: String
    public var startedAt: Date
    public var lastTurnAt: Date?
    public var turns: Int
    public var threadItems: Int
    public var screenshotsInThread: Int
    public var lastInputTokens: Int
    public var nextCompactionCheck: Int
    public var compactions: Int
}

/// The brain runtime: OpenClicky's prompt, the conversation thread, tools and the brain-slot model, behind the turn
/// contract (docs/turn-contract.md, docs/brain.md).
///
/// One turn: the turn's notes, screenshots and words become a user message; the brain's reply streams in, fences
/// stripped, as `programDelta`, and each finished `say("…")` line goes out as `sayLine` while the rest still streams.
/// Tool calls start as soon as the model has written them; reads send their results back for another round, actions
/// report a status, screen-changing actions become `deferredAction`, background calls just start. The turn ends with
/// `finished` (program, lines, rounds, usage, timings) or `failed` with a sentence the voice can say. Cancelling the
/// consumer stops the model call and running tools, and the thread still gets a result for every call.
public actor BrainRuntime: BrainTurnRunning {
    public nonisolated let configuration: BrainRuntimeConfiguration
    private let client: any LanguageModelClient
    private let assembler: BrainPromptAssembler
    private let store: BrainSessionStore?
    private let memory: BrainMemory?
    private let compactor: BrainCompactor?
    private let sources: BrainContextSources
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var tools: ToolRegistry
    private var promptOptions: BrainPromptOptions
    private var session: BrainSessionState
    /// The system prompt, fixed for the session so the provider's cache keeps matching.
    private var systemPrompt: String?
    /// A saved session that went quiet while the app was closed; its memory is written before the next turn.
    private var staleSession: BrainSessionState?
    private var memoryErasuresAtStart: Int?
    private var currentTurn: Task<Void, Never>?
    private var turnRunning = false
    /// The session and turn that called read_connected_apps: that turn's deferred actions (open a link…) are held
    /// back, so a quick read never turns into an action the user didn't ask for (`ConnectedAppsReadGuard`).
    private var connectedAppsRead: (session: String, turn: Int)?
    private var lastRequestAt: Date?
    private var idleTask: Task<Void, Never>?
    private var compactionTask: Task<Void, Never>?
    /// A compaction note that came back while a turn was running: applied when that turn ends, so the thread never
    /// changes between the rounds of one turn (that would break the provider cache and replayed thinking mid-turn).
    private var heldCompaction: (note: String, sessionID: String, keepFrom: Int)?
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    /// What the current session's system prompt (or a later note) told the brain about skills and figures, and the
    /// turn notes it last sent, by tag. Reset with every new session.
    private var told = ToldContext()

    struct ToldContext {
        var sessionID: String?
        var skills: String?
        var figures: Bool?
        var notes: [String: String] = [:]
    }

    /// - Parameters:
    ///   - client: The brain slot's model.
    ///   - store: Where sessions are kept; nil keeps them in memory only (tests, `occtl` dry runs).
    ///   - resume: Pick up the newest saved session when it is still fresh.
    ///   - sleep: How the idle timer waits (tests pass a controllable one).
    public init(client: any LanguageModelClient, configuration: BrainRuntimeConfiguration, tools: ToolRegistry = ToolRegistry(),
                assembler: BrainPromptAssembler, promptOptions: BrainPromptOptions = BrainPromptOptions(),
                store: BrainSessionStore? = nil, memory: BrainMemory? = nil, compactor: BrainCompactor? = nil,
                sources: BrainContextSources = BrainContextSources(), resume: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.client = client
        self.configuration = configuration
        self.tools = tools
        self.assembler = assembler
        var options = promptOptions
        options.figuresAvailable = options.figuresAvailable && configuration.figuresAvailable
        options.toolGroups.formUnion(tools.groups)
        self.promptOptions = options
        self.store = store
        self.memory = memory
        self.compactor = compactor
        self.sources = sources
        self.now = now
        self.sleep = sleep
        let fresh = BrainSessionState(startedAt: now(), compactionThreshold: configuration.compactionThreshold)
        var current = fresh
        var stale: BrainSessionState?
        if resume, let saved = store?.latest(), !saved.ended {
            let last = saved.lastTurnAt ?? saved.startedAt
            if now().timeIntervalSince(last) < configuration.idleTimeout { current = saved } else { stale = saved }
        }
        self.session = current
        self.staleSession = stale
        self.memoryErasuresAtStart = memory?.store.erasures
    }

    // MARK: - BrainTurnRunning

    public nonisolated func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let outer = Task { await self.runTurn(input, continuation: continuation) }
            continuation.onTermination = { _ in outer.cancel() }
        }
    }

    public func prewarm() async {
        guard configuration.canPrewarm, !turnRunning else { return }
        let at = now()
        if let last = lastRequestAt, at.timeIntervalSince(last) < configuration.prewarmAfterIdle { return }
        endSessionIfIdle(at: at)
        lastRequestAt = at
        let system = currentSystemPrompt()
        var messages: [ChatMessage] = [.system(system)] + session.messages
        // Cache through the thread's last message; the placeholder after it is never kept.
        let through = session.items.isEmpty ? nil : messages.count - 1
        messages.append(.user(.text("(OpenClicky is warming up while the user talks. Reply with one word.)")))
        let request = ChatRequest(model: configuration.model, messages: messages, tools: tools.specs,
                                  reasoningEffort: configuration.reasoningEffort, maxOutputTokens: 1,
                                  promptCache: PromptCacheHint(system: true, throughMessage: through, automatic: false),
                                  hostedTools: tools.hostedTools, thinking: configuration.thinking)
        var usage: TokenUsage?
        var problem: String?
        do {
            for try await event in client.stream(request) { if case .usage(let value) = event { usage = value } }
        } catch {
            problem = String(describing: error)
        }
        var entry: [String: JSONValue] = ["kind": "prewarm", "at": .number(at.timeIntervalSince1970), "session": .string(session.id),
                                          "items": .number(Double(session.items.count)),
                                          "ms": .number((now().timeIntervalSince(at) * 1000).rounded())]
        if let usage { entry["usage"] = Self.json(usage) }
        if let problem { entry["error"] = .string(problem) }
        log(.object(entry))
    }

    public func recordOutcome(_ note: String) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.pendingAppNotes.append(BrainTurnNotes.isTagged(trimmed) ? trimmed : "[App] " + trimmed)
        save()
    }

    public func endSession() async {
        // A turn still running would keep writing into the session being ended.
        await stopRunningTurns()
        await endCurrentSession()?.value
    }

    /// Cancels the running turn and waits for it, again if another started meanwhile.
    private func stopRunningTurns() async {
        while let turn = currentTurn {
            turn.cancel()
            await turn.value
            if currentTurn == turn { currentTurn = nil }
        }
    }

    /// Ends the session without waiting for the current turn (the turn itself calls this when the session went idle).
    /// Returns the memory-notes work, which runs in the background; only an explicit `endSession()` waits for it.
    @discardableResult
    private func endCurrentSession() -> Task<Void, Never>? {
        idleTask?.cancel()
        idleTask = nil
        compactionTask?.cancel()
        compactionTask = nil
        heldCompaction = nil
        let ending = session
        let erasures = memoryErasuresAtStart
        session = BrainSessionState(startedAt: now(), compactionThreshold: configuration.compactionThreshold)
        systemPrompt = nil
        memoryErasuresAtStart = memory?.store.erasures
        return finish(ending, erasuresAtStart: erasures)
    }

    // MARK: - Other entry points

    /// Runs an action the turn deferred (`TurnEvent.deferredAction`) once the narration has been spoken. A failure
    /// becomes an `[App]` note for the next turn.
    @discardableResult
    public func performDeferred(_ action: DeferredAction) async -> JSONValue {
        if let read = connectedAppsRead, read.session == session.id, read.turn == session.turnCount,
           ConnectedAppsReadGuard.refuses(action.name) {
            let result = ConnectedAppsReadGuard.refusal(for: action.name)
            noteFailure(name: action.name, result: result)
            log(["kind": "deferred", "at": .number(now().timeIntervalSince1970), "session": .string(session.id),
                 "tool": .string(action.name), "result": result])
            return result
        }
        let result = await tools.runDeferred(action, sessionID: session.id, turn: session.turnCount)
        if !BrainToolResults.succeeded(result) { noteFailure(name: action.name, result: result) }
        log(["kind": "deferred", "at": .number(now().timeIntervalSince1970), "session": .string(session.id),
             "tool": .string(action.name), "result": result])
        return result
    }

    /// Replaces the tools (and the prompt's tool rules). Changes the cached prefix, so do it rarely.
    public func update(tools newTools: ToolRegistry, promptOptions newOptions: BrainPromptOptions? = nil) {
        tools = newTools
        var options = newOptions ?? promptOptions
        options.figuresAvailable = options.figuresAvailable && configuration.figuresAvailable
        options.toolGroups.formUnion(newTools.groups)
        promptOptions = options
        systemPrompt = nil
    }

    public var stats: BrainSessionStats {
        BrainSessionStats(sessionID: session.id, startedAt: session.startedAt, lastTurnAt: session.lastTurnAt, turns: session.turnCount,
                          threadItems: session.items.count, screenshotsInThread: session.imageCount,
                          lastInputTokens: session.lastInputTokens, nextCompactionCheck: session.nextCompactionCheck,
                          compactions: session.compactions)
    }

    /// The current session (for tests, `occtl brain` and debugging views).
    public var currentSession: BrainSessionState { session }

    /// The request the next turn's first round would send for `input`: the system prompt, the thread so far and this
    /// turn's message, with the turn's tools and settings. Changes nothing (for `occtl latency` and debugging).
    public func previewRequest(for input: TurnInput) -> ChatRequest {
        let message = assembler.turnMessage(for: input, appNotes: session.pendingAppNotes, relevantMemories: relevantMemories(for: input))
        return ChatRequest(model: configuration.model, messages: [.system(currentSystemPrompt())] + session.messages + [message],
                           tools: tools.specs, reasoningEffort: configuration.reasoningEffort,
                           maxOutputTokens: configuration.maxOutputTokens,
                           promptCache: configuration.promptCaching ? .conversation : nil, hostedTools: tools.hostedTools,
                           thinking: configuration.thinking)
    }

    /// The sections of the system prompt the next request sends, named (for size reports).
    public func systemPromptSections() -> [(name: String, text: String)] {
        var options = promptOptions
        if let memory, options.memory.isEmpty, let snapshot = try? memory.store.snapshot() {
            options.memory = memory.promptBuilder.build(from: snapshot, query: "").stableText
        }
        return assembler.systemSections(options)
    }

    /// The system prompt the next request sends.
    public func currentSystemPrompt() -> String {
        if let systemPrompt { return systemPrompt }
        var options = promptOptions
        if let memory, options.memory.isEmpty, let snapshot = try? memory.store.snapshot() {
            options.memory = memory.promptBuilder.build(from: snapshot, query: "").stableText
        }
        if let skills = sources.skills, options.skills.isEmpty { options.skills = skills() }
        if let figures = sources.figuresAvailable { options.figuresAvailable = options.figuresAvailable && figures() }
        let prompt = assembler.systemPrompt(options)
        systemPrompt = prompt
        told = ToldContext(sessionID: session.id, skills: options.skills.trimmingCharacters(in: .whitespacesAndNewlines),
                           figures: options.figuresAvailable)
        return prompt
    }

    /// Notes for this turn from `sources`: a skills or figures change since the prompt was built, and turn notes
    /// whose text changed since they were last sent in this session.
    private func contextNotes() async -> [String] {
        if told.sessionID != session.id { told = ToldContext(sessionID: session.id) }
        var notes: [String] = []
        if let skills = sources.skills {
            let current = skills().trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = told.skills, previous != current { notes.append(BrainContextSources.skillUpdateNote(current)) }
            told.skills = current
        }
        if let figures = sources.figuresAvailable, promptOptions.figuresAvailable {
            let current = figures()
            if let previous = told.figures, previous != current {
                notes.append(current ? BrainContextSources.figuresBackNote : BrainContextSources.figuresStoppedNote)
            }
            told.figures = current
        }
        if let turnNotes = sources.turnNotes {
            for note in await turnNotes() {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let key = BrainTurnNotes.isTagged(text) ? String(text[...text.firstIndex(of: "]")!]) : text
                if told.notes[key] == text { continue }
                told.notes[key] = text
                notes.append(text)
            }
        }
        return notes
    }

    /// Waits for background work started by earlier turns (compaction, background tool calls). For tests and
    /// shutdown.
    public func waitForBackgroundWork() async {
        while true {
            let pending = Array(backgroundTasks.values) + [compactionTask].compactMap { $0 }
            if pending.isEmpty { return }
            for task in pending { await task.value }
            if compactionTask.map({ task in pending.contains { $0 == task } }) ?? false { compactionTask = nil }
            backgroundTasks = backgroundTasks.filter { entry in !pending.contains { $0 == entry.value } }
        }
    }

    // MARK: - The turn

    private func runTurn(_ input: TurnInput, continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation) async {
        let previous = currentTurn
        let turn = Task {
            if let previous {
                previous.cancel()
                await previous.value
            }
            let screenshots = input.screenshots.filter(\.isCursorScreen) + input.screenshots.filter { !$0.isCursorScreen }
            await AgentTurnAssets.$forBrainTurn.withValue(AgentTurnAssets(screenshots: screenshots.map(\.jpeg))) {
                await self.performTurn(input, out: continuation)
            }
        }
        currentTurn = turn
        await withTaskCancellationHandler {
            await turn.value
        } onCancel: {
            turn.cancel()
        }
        if currentTurn == turn { currentTurn = nil }
    }

    private func performTurn(_ input: TurnInput, out: AsyncThrowingStream<TurnEvent, Error>.Continuation) async {
        defer { out.finish() }
        let started = now()
        finishStaleSession()
        endSessionIfIdle(at: started)
        guard !Task.isCancelled else { return }
        idleTask?.cancel()
        idleTask = nil
        turnRunning = true
        defer { turnRunning = false }

        let system = currentSystemPrompt()
        let liveNotes = await contextNotes()
        guard !Task.isCancelled else {
            // contextNotes() already counts these as told: keep them for the turn that replaces this one.
            session.pendingAppNotes += liveNotes
            return
        }
        session.turnCount += 1
        let turnNumber = session.turnCount
        let notes = session.pendingAppNotes + liveNotes
        session.pendingAppNotes = []
        let userMessage = assembler.turnMessage(for: input, appNotes: notes, relevantMemories: relevantMemories(for: input))
        session.append(userMessage, at: started, words: input.words, whereLine: BrainTurnNotes.whereLine(for: input))
        configuration.pruning.prune(&session.items)
        session.lastTurnAt = started

        var program = ""
        var spoken: [String] = []
        var extractor = SayLineExtractor()
        var totalUsage: TokenUsage?
        var firstToken: Double?
        var rounds = 0
        var failure: (spoken: String, detail: String)?
        var cancelled = false
        var firstRequestBytes: Int?
        let runner = BrainToolRunner(cap: configuration.maxToolCallsPerTurn)
        var askedForProgram = false
        let context = { (callID: String) in BrainToolContext(sessionID: self.session.id, turn: turnNumber, callID: callID) }
        let sessionID = session.id

        for round in 0..<configuration.maxRounds {
            if Task.isCancelled { cancelled = true; break }
            rounds = round + 1
            let request = ChatRequest(model: configuration.model, messages: [.system(system)] + session.messages, tools: tools.specs,
                                      reasoningEffort: configuration.reasoningEffort, maxOutputTokens: configuration.maxOutputTokens,
                                      promptCache: configuration.promptCaching ? .conversation : nil, hostedTools: tools.hostedTools,
                                      thinking: configuration.thinking)
            if firstRequestBytes == nil { firstRequestBytes = request.approximateBodyBytes }
            let roundStarted = now()
            lastRequestAt = roundStarted
            var reply = ChatReply()
            var fence = ProgramFenceStripper()
            var lines = ProgramLineFilter()
            var roundProgram = ""
            var roundFirstToken: Double?
            let firstCall = runner.count
            let lastRound = round == configuration.maxRounds - 1

            func emit(_ code: String) {
                guard !code.isEmpty else { return }
                var text = code
                if roundProgram.isEmpty, !program.isEmpty, !program.hasSuffix("\n") { text = "\n" + text }
                if firstToken == nil { firstToken = now().timeIntervalSince(started) }
                if roundFirstToken == nil { roundFirstToken = now().timeIntervalSince(roundStarted) }
                program += text
                roundProgram += text
                out.yield(.programDelta(text))
                for line in extractor.feed(text) {
                    spoken.append(line.text)
                    out.yield(.sayLine(index: line.index, text: line.text))
                }
            }

            do {
                for try await event in client.stream(request) {
                    reply.apply(event)
                    switch event {
                    case .textDelta(let delta):
                        emit(lines.feed(fence.feed(delta)))
                    case .toolCall(let call):
                        if call.name == ReadConnectedApps.toolName { connectedAppsRead = (sessionID, turnNumber) }
                        var background: [(tool: any BrainTool, arguments: JSONValue, context: BrainToolContext)] = []
                        let events = runner.start(call, registry: tools, context: context(call.id), lastRound: lastRound) { _, tool, arguments, context in
                            background.append((tool, arguments, context))
                        }
                        // Registered before anything else runs, so waitForBackgroundWork() always sees it.
                        for item in background { startBackground(tool: item.tool, arguments: item.arguments, context: item.context) }
                        for event in events { out.yield(event) }
                    default:
                        break
                    }
                }
                if Task.isCancelled { cancelled = true }
            } catch {
                if Task.isCancelled || error is CancellationError { cancelled = true } else { failure = Self.failure(for: error) }
            }
            emit(lines.feed(fence.finish()) + lines.finish())
            if let usage = reply.usage {
                session.lastInputTokens = usage.inputTokens
                totalUsage = TokenUsage(inputTokens: (totalUsage?.inputTokens ?? 0) + usage.inputTokens,
                                        cachedInputTokens: (totalUsage?.cachedInputTokens ?? 0) + usage.cachedInputTokens,
                                        outputTokens: (totalUsage?.outputTokens ?? 0) + usage.outputTokens,
                                        cacheWriteTokens: (totalUsage?.cacheWriteTokens ?? 0) + usage.cacheWriteTokens)
            }

            // The reply goes into the thread as produced (fences and all), and every call it made gets a result.
            let assistant = reply.message
            if !assistant.content.isEmpty || !assistant.toolCalls.isEmpty { session.append(assistant, at: now()) }
            if cancelled || failure != nil { runner.abandon() }
            let outcomes = await runner.collect(from: firstCall)
            for outcome in outcomes {
                session.append(.tool(callID: outcome.call.id, result: outcome.result.jsonString(), isError: !outcome.succeeded), at: now())
                if outcome.announced, !cancelled {
                    out.yield(.toolFinished(name: outcome.call.name, callID: outcome.call.id, succeeded: outcome.succeeded))
                }
            }
            logRound(sessionID: sessionID, turn: turnNumber, round: round, words: input.words, text: roundProgram, reply: reply,
                     outcomes: outcomes, firstToken: roundFirstToken, seconds: now().timeIntervalSince(roundStarted))
            if cancelled || failure != nil { break }
            out.yield(.roundFinished(round))
            if runner.needsRound(from: firstCall), reply.finishReason != .length { continue }
            // Plain sentences were held out of the program (they can't be spoken): ask once for the rest as code.
            let prose = lines.dropped
            guard !prose.isEmpty, !askedForProgram, round < configuration.maxRounds - 1, reply.finishReason != .length else { break }
            askedForProgram = true
            session.append(.user(.text(Self.proseNote)), at: now())
            log(["kind": "prose_rescue", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
                 "turn": .number(Double(turnNumber)), "lines": .array(prose.prefix(5).map { .string($0) })])
        }

        let total = now().timeIntervalSince(started)
        turnRunning = false
        applyHeldCompaction()
        if cancelled {
            log(["kind": "interrupted", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
                 "turn": .number(Double(turnNumber)), "words": .string(input.words), "program": .string(program)])
            save()
            return
        }
        if let failure {
            out.yield(.failed(spoken: failure.spoken, detail: failure.detail))
            log(["kind": "failed", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
                 "turn": .number(Double(turnNumber)), "error": .string(failure.detail)])
        } else if program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && runner.isEmpty {
            out.yield(.failed(spoken: "Sorry, I lost my train of thought. Could you ask that again?",
                              detail: "The model answered with no program and no tool calls."))
        } else {
            out.yield(.finished(TurnSummary(program: program, spokenLines: spoken, rounds: rounds, usage: totalUsage,
                                            model: configuration.model, firstTokenSeconds: firstToken, totalSeconds: total,
                                            requestBytes: firstRequestBytes)))
        }
        save()
        scheduleCompactionIfNeeded()
        scheduleIdleEnd()
    }

    // MARK: - Background tools

    private func startBackground(tool: any BrainTool, arguments: JSONValue, context: BrainToolContext) {
        let key = UUID()
        let task = Task {
            let result = await tool.run(arguments, context: context)
            self.backgroundFinished(key: key, name: tool.spec.name, result: result)
        }
        backgroundTasks[key] = task
    }

    private func backgroundFinished(key: UUID, name: String, result: JSONValue) {
        backgroundTasks[key] = nil
        if !BrainToolResults.succeeded(result) { noteFailure(name: name, result: result) }
        log(["kind": "background", "at": .number(now().timeIntervalSince1970), "session": .string(session.id),
             "tool": .string(name), "result": result])
    }

    private func noteFailure(name: String, result: JSONValue) {
        let status = result["status"]?.stringValue ?? "error"
        let message = result["message"]?.stringValue.map { " \($0)" } ?? ""
        session.pendingAppNotes.append("[App] \(name) did not work (\(status)).\(message)")
        save()
    }

    // MARK: - Memory and sessions

    private func relevantMemories(for input: TurnInput) -> String {
        guard let memory, let snapshot = try? memory.store.snapshot() else { return "" }
        return memory.promptBuilder.build(from: snapshot, for: input).turnText
    }

    private func endSessionIfIdle(at date: Date) {
        guard !session.items.isEmpty, let last = session.lastTurnAt, date.timeIntervalSince(last) >= configuration.idleTimeout else { return }
        endCurrentSession()
    }

    private func finishStaleSession() {
        guard let stale = staleSession else { return }
        staleSession = nil
        finish(stale, erasuresAtStart: nil)
    }

    /// Marks a session ended and saves it, then writes its memory notes in the background (a model call on
    /// brain-fast that can take several seconds, so a turn never waits for it). Returns that work, if any; it is
    /// also tracked by `waitForBackgroundWork()`.
    @discardableResult
    private func finish(_ session: BrainSessionState, erasuresAtStart: Int?) -> Task<Void, Never>? {
        guard !session.items.isEmpty else { return nil }
        var ending = session
        ending.ended = true
        try? store?.save(ending)
        let entry: [String: JSONValue] = ["kind": "session_end", "at": .number(now().timeIntervalSince1970),
                                          "session": .string(ending.id), "turns": .number(Double(ending.turnCount))]
        guard let memory, let writer = memory.writer, ending.userSpoke else {
            store?.appendLog(.object(entry), sessionID: ending.id)
            return nil
        }
        let store = self.store
        let thread = ending.conversationForMemory, id = ending.id
        let key = UUID()
        let task = Task {
            var logged = entry
            do {
                let report = try await writer.endSession(thread: thread, store: memory.store, sessionID: id,
                                                         erasuresAtStart: erasuresAtStart)
                logged["memory"] = .string(String(describing: report))
            } catch {
                logged["memory_error"] = .string(String(describing: error))
            }
            store?.appendLog(.object(logged), sessionID: id)
            self.backgroundTasks[key] = nil
        }
        backgroundTasks[key] = task
        return task
    }

    private func scheduleIdleEnd() {
        idleTask?.cancel()
        let timeout = configuration.idleTimeout
        let sleep = self.sleep
        idleTask = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.endSessionIfIdle(at: self.now())
        }
    }

    // MARK: - Compaction

    private func scheduleCompactionIfNeeded() {
        guard let compactor, compactionTask == nil, session.lastInputTokens >= session.nextCompactionCheck else { return }
        guard let boundary = BrainCompactor.foldBoundary(session.items, keepTurns: configuration.compactionKeepTurns) else {
            session.nextCompactionCheck = session.lastInputTokens + configuration.compactionStep
            log(["kind": "compaction_skipped", "at": .number(now().timeIntervalSince1970), "session": .string(session.id),
                 "input_tokens": .number(Double(session.lastInputTokens)), "next_check": .number(Double(session.nextCompactionCheck))])
            save()
            return
        }
        let folded = Array(session.items[..<boundary])
        let keepFrom = session.items[boundary].seq
        let sessionID = session.id
        compactionTask = Task {
            do {
                let note = try await compactor.summarize(folded)
                self.applyCompaction(note: note, sessionID: sessionID, keepFrom: keepFrom)
            } catch {
                self.compactionFailed(sessionID: sessionID, error: error)
            }
        }
    }

    private func applyCompaction(note: String, sessionID: String, keepFrom: Int) {
        compactionTask = nil
        guard !turnRunning else {
            heldCompaction = (note, sessionID, keepFrom)
            return
        }
        // A compaction that finishes after the session ended or the folded messages changed is dropped.
        guard session.id == sessionID, let index = session.items.firstIndex(where: { $0.seq == keepFrom }) else { return }
        let before = session.items.count
        let summary = BrainThreadItem(seq: keepFrom - 1, turn: 0, at: now(),
                                      message: .user(.text(BrainCompactor.noteHeader + "\n" + note)), isSummary: true)
        session.items.replaceSubrange(0..<index, with: [summary])
        session.compactions += 1
        // The notes that were folded away go out again when next due.
        told.notes = [:]
        session.nextCompactionCheck = configuration.compactionThreshold
        log(["kind": "compacted", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
             "items_before": .number(Double(before)), "items_after": .number(Double(session.items.count)),
             "input_tokens": .number(Double(session.lastInputTokens))])
        save()
    }

    private func applyHeldCompaction() {
        guard let held = heldCompaction else { return }
        heldCompaction = nil
        applyCompaction(note: held.note, sessionID: held.sessionID, keepFrom: held.keepFrom)
    }

    private func compactionFailed(sessionID: String, error: Error) {
        compactionTask = nil
        guard session.id == sessionID else { return }
        session.nextCompactionCheck = session.lastInputTokens + configuration.compactionStep
        log(["kind": "compaction_failed", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
             "error": .string(String(describing: error))])
        save()
    }

    // MARK: - Persistence and logs

    private func save() {
        guard let store, !session.items.isEmpty || !session.pendingAppNotes.isEmpty else { return }
        try? store.save(session)
    }

    private func log(_ entry: JSONValue) {
        store?.appendLog(entry, sessionID: session.id)
    }

    private func logRound(sessionID: String, turn: Int, round: Int, words: String, text: String, reply: ChatReply,
                          outcomes: [BrainToolRunner.Outcome], firstToken: Double?, seconds: Double) {
        var entry: [String: JSONValue] = [
            "kind": "round", "at": .number(now().timeIntervalSince1970), "session": .string(sessionID),
            "turn": .number(Double(turn)), "round": .number(Double(round)), "model": .string(configuration.model),
            "program": .string(text), "ms": .number((seconds * 1000).rounded()),
            "tool_calls": .array(outcomes.map { ["name": .string($0.call.name), "status": $0.result["status"] ?? "ok"] }),
        ]
        if round == 0 { entry["words"] = .string(words) }
        if let firstToken { entry["first_token_ms"] = .number((firstToken * 1000).rounded()) }
        if let usage = reply.usage { entry["usage"] = Self.json(usage) }
        if let reason = reply.finishReason { entry["finish"] = .string(reason.rawValue) }
        store?.appendLog(.object(entry), sessionID: sessionID)
    }

    /// Sent when a reply wrote plain sentences instead of code.
    static let proseNote = """
    [App] Part of your last reply was plain sentences, which are never spoken or drawn. Continue the same program now \
    in a ```js block: the next step number, say() lines with what you meant to tell the user, and marks if they help. \
    Don't repeat lines already said.
    """

    static func json(_ usage: TokenUsage) -> JSONValue {
        ["input": .number(Double(usage.inputTokens)), "cached": .number(Double(usage.cachedInputTokens)),
         "cache_write": .number(Double(usage.cacheWriteTokens)), "output": .number(Double(usage.outputTokens))]
    }

    // MARK: - Failures

    /// A short sentence the voice can say about a failed turn, and the detail for logs.
    static func failure(for error: Error) -> (spoken: String, detail: String) {
        let detail = String(describing: error)
        // A usage limit or a diagnosed provider failure already says what happened, plainly.
        if let spoken = error as? any SpokenError { return (spoken.spokenExplanation, detail) }
        if let provider = error as? ProviderError, let status = provider.status {
            switch status {
            case 401, 403: return ("I can't reach my brain: the API key was turned down. Check it in Settings.", detail)
            case 402: return ("My brain's account is out of credit. Check it in Settings.", detail)
            case 429: return ("My brain is getting too many requests. Wait a little, then ask me again.", detail)
            case 400, 404, 413, 422: return ("My brain couldn't take that request. Try asking another way.", detail)
            case 500...599: return ("My brain is having trouble right now. Try again in a moment.", detail)
            default: break
            }
        }
        if error is URLError { return ("I lost my connection. Try again in a moment.", detail) }
        return ("Something went wrong on my end. Try asking again.", detail)
    }
}

extension BrainRuntime: ConversationSeeding {
    /// Replaces the thread with earlier turns from the history (oldest first), so a conversation picked up in the
    /// Home window continues where it was. Completed turns with words and a reply count; each becomes the user's
    /// words and the brain's program (or its spoken lines as `say()` statements). Screenshots are not kept in the
    /// history, so none come back.
    public func seedConversation(_ turns: [HistoryTurn]) async {
        await seedConversation(turns, sessionID: UUID().uuidString)
    }

    /// The same, with the thread taking the history conversation's id, so voice turns that follow (which name their
    /// history session after the brain's, `BrainSessionNaming`) land in the conversation the user picked.
    public func seedConversation(_ turns: [HistoryTurn], sessionID: String) async {
        var seeded = BrainSessionState(id: sessionID, startedAt: now(), compactionThreshold: configuration.compactionThreshold)
        for turn in turns where turn.outcome == .completed && !turn.words.isEmpty && !turn.spokenLines.isEmpty {
            seeded.turnCount += 1
            let said = (turn.source == .text ? "The user typed: " : "The user said: ") + turn.words
            seeded.append(.user(.text(said)), at: turn.startedAt, words: turn.words,
                          whereLine: [BrainTurnNotes.shortTime(turn.startedAt, zone: .current), turn.frontApp].compactMap { $0 }
                              .joined(separator: " · "))
            let program = turn.program.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? turn.spokenLines.map { "say(\(JSONValue.string($0).jsonString()))" }.joined(separator: "\n")
            seeded.append(.assistant("```js\n" + program + "\n```"), at: turn.startedAt)
        }
        // The conversation is being picked up now: it isn't idle, and its old turns were noted when they happened.
        if !seeded.items.isEmpty { seeded.lastTurnAt = now() }
        await stopRunningTurns()
        // The conversation being replaced ends properly, so its memory notes are still written.
        endCurrentSession()
        session = seeded
        save()
    }
}

extension BrainRuntime {
    /// A runtime built from the user's settings: the brain slot's model, compaction and memory notes on brain-fast
    /// (falling back to the brain), sessions under `store`.
    public static func make(factory: EngineFactory, tools: ToolRegistry = ToolRegistry(), promptOptions: BrainPromptOptions = BrainPromptOptions(),
                            store: BrainSessionStore? = BrainSessionStore(), memoryStore: MemoryStore? = nil,
                            sources: BrainContextSources = BrainContextSources(),
                            configure: (inout BrainRuntimeConfiguration) -> Void = { _ in }) throws -> BrainRuntime {
        let resolution = try factory.resolve(.brain)
        let client = try factory.languageModel(for: .brain)
        var configuration = BrainRuntimeConfiguration(model: resolution.selection.model, dialect: resolution.provider?.dialect,
                                                      reasoningEffort: defaultEffort(factory: factory, resolution: resolution),
                                                      thinking: defaultThinking(resolution: resolution))
        configure(&configuration)
        var compactor: BrainCompactor?
        var writer: MemoryWriter?
        if let fast = try? factory.resolve(.brainFast), let fastClient = try? factory.languageModel(for: .brainFast) {
            compactor = BrainCompactor(client: fastClient, model: fast.selection.model)
            writer = try? MemoryWriter(factory: factory)
        }
        let memory = memoryStore.map { BrainMemory(store: $0, writer: writer) }
        return BrainRuntime(client: client, configuration: configuration, tools: tools, assembler: try BrainPromptAssembler(),
                            promptOptions: promptOptions, store: store, memory: memory, compactor: compactor, sources: sources)
    }

    /// The reasoning effort a voice turn wants: "low" when the model lists it (a spoken answer can't wait for long
    /// thinking: on Claude Haiku 5.5 a 3D answer took 20 s to its first line at the default effort and 2 to 6 s at low),
    /// else the provider's default.
    public static func defaultEffort(factory: EngineFactory, resolution: EngineResolution) -> String? {
        guard let dialect = resolution.provider?.dialect else { return nil }
        let listed = factory.catalog.merging(factory.config.models).model(resolution.selection.model, servedBy: dialect)?.reasoningEfforts ?? []
        return listed.contains("low") ? "low" : nil
    }

    /// How a voice turn's brain thinks: `.hidden` on Anthropic, where a streamed thinking summary holds the answer text
    /// back until it is written (on Claude Haiku 5.5 the first line came about 1.4 s later with it; thinking itself, and
    /// so the drawings, are the same either way; docs/latency.md). Nil for other dialects, which keep their default.
    public static func defaultThinking(resolution: EngineResolution) -> ThinkingMode? {
        resolution.provider?.dialect == .anthropicMessages ? .hidden : nil
    }
}


extension BrainRuntime: BrainTurnSettling {
    public func waitUntilIdle() async {
        while let turn = currentTurn {
            await turn.value
            if currentTurn == turn { currentTurn = nil }
        }
    }
}
