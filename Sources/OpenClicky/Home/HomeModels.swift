import AppKit
import OpenClickyKit
import SwiftUI

enum HomeSection: String, CaseIterable, Identifiable, Hashable {
    case chat, agents, drawings, skills
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .agents: "Agents"
        case .drawings: "Drawings"
        case .skills: "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .agents: "sparkles.rectangle.stack"
        case .drawings: "scribble.variable"
        case .skills: "sparkles"
        }
    }
}

/// One row of a conversation: a turn, or a job starting or coming back.
enum HomeChatEntry: Identifiable, Hashable {
    case turn(HistoryTurn)
    case handOff(HistoryHandOff)

    var id: String {
        switch self {
        case .turn(let turn): turn.id
        case .handOff(let handOff): "handoff-" + handOff.id
        }
    }

    var at: Date {
        switch self {
        case .turn(let turn): turn.startedAt
        case .handOff(let handOff): handOff.at
        }
    }
}

/// Home's chat: the conversations in the history, the selected one's turns, and typed questions sent through the brain.
@MainActor
@Observable
final class HomeChatModel {
    struct Pending: Equatable {
        var question: String
        var lines: [String] = []
        var status: String?
    }

    var section: HomeSection = .chat
    private(set) var sessions: [HistorySession] = []
    private(set) var selectedSessionID: String?
    private(set) var turns: [HistoryTurn] = [] {
        didSet { refreshEntries() }
    }
    /// The turns and the jobs that started or came back in the selected conversation, oldest first.
    private(set) var entries: [HomeChatEntry] = []
    var draft = ""
    private(set) var pending: Pending?
    var lastError: String?

    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let injectedBrain: (any BrainTurnRunning)?
    @ObservationIgnored private let extraSections: @Sendable () -> [String]
    @ObservationIgnored private var controller: TypedChatController?
    @ObservationIgnored private var controllerKey: String?
    @ObservationIgnored private var follower: Task<Void, Never>?
    /// Show the newest conversation as voice, always-on and typed turns add to it, until the user picks another one.
    @ObservationIgnored private var followsLatest = true
    /// A conversation the user picked (or started) that the next question must go into.
    @ObservationIgnored private var picked: String?


    init(history: HistoryStore, model: AppModel, brain: (any BrainTurnRunning)?, extraSections: @escaping @Sendable () -> [String]) {
        self.history = history
        self.model = model
        injectedBrain = brain
        self.extraSections = extraSections
        reload()
    }

    private func refreshEntries() {
        let handOffs = selectedSessionID.flatMap { try? history.handOffs(in: $0) } ?? []
        entries = (turns.map(HomeChatEntry.turn) + handOffs.map(HomeChatEntry.handOff)).enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// Keeps the list current when voice turns (or occtl) add to the history.
    func startFollowingHistory() {
        guard follower == nil else { return }
        let changes = history.changes()
        follower = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.reload()
            }
        }
    }

    func reload() {
        sessions = history.sessions(limit: 200)
        if followsLatest, pending == nil, let latest = sessions.first, latest.id != selectedSessionID {
            selectedSessionID = latest.id
            turns = (try? history.turns(in: latest.id)) ?? []
            return
        }
        if let id = selectedSessionID, sessions.contains(where: { $0.id == id }) {
            turns = (try? history.turns(in: id)) ?? []
        } else if selectedSessionID == nil, pending == nil, let latest = sessions.first {
            selectedSessionID = latest.id
            turns = (try? history.turns(in: latest.id)) ?? []
        } else if let id = selectedSessionID, !sessions.contains(where: { $0.id == id }) {
            // A brand-new conversation that has no turns yet, or one deleted elsewhere.
            turns = []
        }
    }

    func select(_ id: String) {
        selectedSessionID = id
        turns = (try? history.turns(in: id)) ?? []
        followsLatest = id == sessions.first?.id
        picked = id
        controller?.resume(sessionID: id)
    }

    /// Starts an empty conversation; the brain forgets the thread.
    func newConversation() {
        let id = UUID().uuidString
        selectedSessionID = id
        turns = []
        followsLatest = false
        picked = id
        if let controller {
            Task { await controller.startNewConversation(id: id) }
        }
    }

    func delete(_ id: String) {
        try? history.deleteSession(id)
        if selectedSessionID == id { selectedSessionID = nil }
        reload()
    }

    var canSend: Bool { pending == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let chat: TypedChatController
        do {
            chat = try chatController()
        } catch {
            lastError = "Typed chat needs a working brain slot: \(error)"
            return
        }
        // The shared brain keeps its own conversation (voice and always-on go there too) unless the user picked one
        // here; the stand-in brain is always pointed at the selected conversation.
        if injectedBrain == nil, let selectedSessionID {
            chat.resume(sessionID: selectedSessionID)
        } else if let picked {
            chat.resume(sessionID: picked)
            self.picked = nil
        }
        let notes = injectedBrain == nil ? [] : [TypedChatController.homeWindowNote]
        draft = ""
        lastError = nil
        pending = Pending(question: question)
        let relay: @Sendable (TurnEvent) -> Void = { [weak self] event in
            guard let model = self else { return }
            Task { @MainActor in model.absorb(event) }
        }
        Task { [weak self] in
            let turn = await chat.send(question, appNotes: notes, onEvent: relay)
            guard let self else { return }
            self.pending = nil
            self.selectedSessionID = turn.sessionID
            self.followsLatest = true
            if turn.outcome == .failed { self.lastError = turn.errorDetail }
            self.reload()
        }
    }

    private func absorb(_ event: TurnEvent) {
        guard pending != nil else { return }
        switch event {
        case .sayLine(_, let text): pending?.lines.append(text)
        case .status(let text): pending?.status = text
        default: break
        }
    }

    /// The typed-chat controller for the current brain; rebuilt when the brain slot changes.
    private func chatController() throws -> TypedChatController {
        if let injectedBrain {
            if let controller { return controller }
            let made = TypedChatController(brain: injectedBrain, history: history)
            controller = made
            return made
        }
        let selection = model.config.slots[.brain]
        let key = "\(selection?.provider ?? "")|\(selection?.model ?? "")|\(model.config.provider(selection?.provider ?? "")?.baseURL?.absoluteString ?? "")"
        if let controller, controllerKey == key { return controller }
        let factory = EngineFactory(config: model.config, catalog: model.mergedCatalog, credentials: model.credentials)
        let brain = try StandInTextBrain.forBrainSlot(factory, extraSystemSections: extraSections)
        let made = TypedChatController(brain: brain, history: history)
        controller = made
        controllerKey = key
        return made
    }
}

/// Recent drawings with thumbnails re-rendered by the drawing engine.
@MainActor
@Observable
final class HomeDrawingsModel {
    private(set) var drawings: [HistoryDrawing] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var failures: [String: String] = [:]
    var selectedID: String?

    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored let thumbnailer: DrawingThumbnailer
    @ObservationIgnored private var rendering: Task<Void, Never>?

    init(history: HistoryStore, cacheDirectory: URL?) {
        self.history = history
        thumbnailer = DrawingThumbnailer(cacheDirectory: cacheDirectory, pixelWidth: 480)
    }

    var selected: HistoryDrawing? { drawings.first { $0.id == selectedID } }

    func reload(limit: Int = 24) {
        drawings = history.recentDrawings(limit: limit)
        renderMissing()
    }

    /// Renders thumbnails one at a time, yielding between them so the window stays responsive.
    func renderMissing() {
        rendering?.cancel()
        let pending = drawings.filter { thumbnails[$0.id] == nil && failures[$0.id] == nil }
        guard !pending.isEmpty else { return }
        rendering = Task { [weak self] in
            for drawing in pending {
                guard let self, !Task.isCancelled else { return }
                self.renderNow(drawing)
                await Task.yield()
            }
        }
    }

    /// Renders one thumbnail synchronously (evidence renders use this directly).
    func renderNow(_ drawing: HistoryDrawing) {
        do {
            let image = try thumbnailer.thumbnail(for: drawing)
            thumbnails[drawing.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            failures[drawing.id] = "\(error)"
        }
    }
}
