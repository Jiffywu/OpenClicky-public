import Foundation

/// The connected apps the brain can read: the reader `read_connected_apps` runs, and the apps as the tool and the
/// prompt name them.
public struct ConnectedAppsWiring: Sendable {
    public var reader: ReadConnectedApps
    public var apps: [ConnectedAppSummary]

    public init(reader: ReadConnectedApps, apps: [ConnectedAppSummary]) {
        self.reader = reader
        self.apps = apps
    }

    /// The user's connectors (`connectors.json`), the Obsidian vault and Composio, read through one hub. The chooser that
    /// picks which connector tools to call is the brain-fast model when `factory` can build one, else word matching.
    public static func make(registry: ConnectorRegistry, credentials: any CredentialStore, factory: EngineFactory? = nil) -> ConnectedAppsWiring {
        // The shared session cache: Settings resetting Composio (sign-in, connect, disconnect) reaches the brain's hub too.
        let hub = ConnectedAppsHub(registry: registry, environment: ConnectorEnvironment(credentials: credentials, composioSessions: .shared))
        var chooser: any ConnectedAppsToolChooser = KeywordToolChooser()
        if let factory, let fast = try? factory.resolve(.brainFast), let client = try? factory.languageModel(for: .brainFast) {
            chooser = ModelToolChooser(client: client, model: fast.selection.model)
        }
        return ConnectedAppsWiring(reader: ReadConnectedApps(hub: hub, chooser: chooser),
                                   apps: ConnectedAppsHub.summaries(of: registry, credentials: credentials))
    }

    /// Apps that can be read now.
    public var ready: [ConnectedAppSummary] { apps.filter { $0.status == .ready } }

    /// A fingerprint of the connectors that only changes when they do (the app rebuilds the brain then). Keys are
    /// sorted: each read of `connectors.json` makes new dictionaries, and Swift iterates two equal dictionaries in
    /// different orders, so plain encoding would differ on every read.
    public static func fingerprint(_ registry: ConnectorRegistry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(registry)).map { $0.base64EncodedString() } ?? ""
    }

    /// How the prompt lists each ready app: its name (with the account) and what it holds.
    public var promptLines: [String] {
        ready.map { app in
            let capability = app.capability?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return capability.isEmpty ? app.labelledName : "\(app.labelledName): \(capability)"
        }
    }
}

/// What the voice brain is built from besides its model: tools, prompt options and the context it reads every turn.
/// The app's voice loop and `occtl brain` build their runtime through this, so a headless run gets what the app's
/// brain gets: memory (with earlier chats in `recall_memory`), app tools, lookups, background jobs, connected apps and
/// the Obsidian vault, take-over, the active skills, the `[Your jobs]` note and whether 3D figures work.
public struct BrainWiring: Sendable {
    public var memory: MemoryStore?
    /// Earlier chats `recall_memory` also searches.
    public var history: HistoryStore?
    public var appTools: AppToolbox?
    public var lookups: LookupTools?
    /// The provider-hosted web search entry (`ToolRegistry.hostedWebSearch`), if any.
    public var hostedSearch: JSONValue?
    public var agents: AgentTools?
    public var connectedApps: ConnectedAppsWiring?
    /// More tools registered last (take-over in the app).
    public var extraTools: [any BrainTool]
    public var skills: (any ActiveSkillsProviding)?
    /// Notes for every turn (`AgentCoordinator.brainContext()`).
    public var turnNotes: (@Sendable () async -> [String])?
    public var figures: FigureAvailability?
    /// The `brain.reads-connected-apps` flag: off leaves `read_connected_apps` and the connected-app prompt lines out.
    public var readsConnectedApps = true
    /// The `brain.keeps-screens` flag: keep up to `keptScreens` screenshots in the thread instead of the newest few.
    public var keepsScreens = false
    /// How many screenshots `keepsScreens` keeps (compaction still trims a long thread).
    public static let keptScreens = 24

    public init(memory: MemoryStore? = nil, history: HistoryStore? = nil, appTools: AppToolbox? = nil, lookups: LookupTools? = nil,
                hostedSearch: JSONValue? = nil, agents: AgentTools? = nil, connectedApps: ConnectedAppsWiring? = nil,
                extraTools: [any BrainTool] = [], skills: (any ActiveSkillsProviding)? = nil,
                turnNotes: (@Sendable () async -> [String])? = nil, figures: FigureAvailability? = nil) {
        self.memory = memory
        self.history = history
        self.appTools = appTools
        self.lookups = lookups
        self.hostedSearch = hostedSearch
        self.agents = agents
        self.connectedApps = connectedApps
        self.extraTools = extraTools
        self.skills = skills
        self.turnNotes = turnNotes
        self.figures = figures
    }

    /// The `[Your jobs]`, `[Your Clickys]` and `[Your routines]` notes from a job coordinator, for `turnNotes`.
    public static func jobNotes(_ coordinator: AgentCoordinator) -> @Sendable () async -> [String] {
        { [weak coordinator] in
            guard let coordinator else { return [] }
            return await coordinator.brainNotes() + [await coordinator.routinesContext()]
        }
    }

    /// The memory tools for this wiring (recall also searches the history).
    public var memoryTools: MemoryTools? { memory.map { MemoryTools(store: $0, history: history) } }

    public func tools() -> ToolRegistry {
        var registry = ToolRegistry()
        if let memoryTools { registry.register(contentsOf: ToolRegistry.memoryTools(memoryTools)) }
        if let appTools { registry.register(contentsOf: ToolRegistry.appTools(appTools)) }
        if let lookups { registry.register(contentsOf: ToolRegistry.lookupTools(lookups)) }
        if let hostedSearch { registry.registerHosted(hostedSearch, group: .hostedSearch) }
        if let connectedApps, readsConnectedApps, !connectedApps.ready.isEmpty {
            registry.register(ToolRegistry.connectedAppsTool(connectedApps.reader, apps: connectedApps.apps))
        }
        if let agents { registry.register(contentsOf: ToolRegistry.agentTools(agents)) }
        registry.register(contentsOf: extraTools)
        return registry
    }

    public func promptOptions(_ base: BrainPromptOptions = BrainPromptOptions()) -> BrainPromptOptions {
        var options = base
        if let connectedApps, readsConnectedApps { options.connectedApps = connectedApps.promptLines }
        return options
    }

    public func sources() -> BrainContextSources {
        var sources = BrainContextSources(turnNotes: turnNotes)
        if let skills { sources.skills = BrainContextSources.skills(skills) }
        if let figures { sources.figuresAvailable = { figures.isAvailable } }
        return sources
    }

    /// Reads the flags this wiring honours (`brain.reads-connected-apps`, `brain.keeps-screens`).
    public mutating func apply(_ flags: FeatureFlagStore) {
        readsConnectedApps = flags.isOn(.brainReadsConnectedApps)
        keepsScreens = flags.isOn(.brainKeepsScreens)
    }

    /// The pruning policy `keepsScreens` asks for, applied over `base`.
    public func pruning(_ base: BrainPruningPolicy) -> BrainPruningPolicy {
        guard keepsScreens else { return base }
        var policy = base
        policy.keepImages = max(base.keepImages, Self.keptScreens)
        return policy
    }

    /// The brain runtime on the user's slots with this wiring (`BrainRuntime.make`).
    public func makeRuntime(factory: EngineFactory, store: BrainSessionStore? = BrainSessionStore(),
                            configure: (inout BrainRuntimeConfiguration) -> Void = { _ in }) throws -> BrainRuntime {
        let wiring = self
        return try BrainRuntime.make(factory: factory, tools: tools(), promptOptions: promptOptions(), store: store, memoryStore: memory,
                                     sources: sources()) { configuration in
            configuration.pruning = wiring.pruning(configuration.pruning)
            configure(&configuration)
        }
    }
}
