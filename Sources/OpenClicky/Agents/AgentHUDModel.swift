import AppKit
import Observation
import OpenClickyKit

/// The agent HUD's state on the main actor: the activity feed folded from the manager's updates, plus the actions
/// the HUD's buttons call (stop, approve, decline, answer, open files).
@MainActor
@Observable
final class AgentHUDModel {
    private(set) var feed: AgentActivityFeed
    /// Ticks once a second while something runs, so elapsed times stay current.
    private(set) var now = Date()
    var lastError: String?
    /// Home → Agents: the job whose transcript is shown, and whether archived jobs are listed.
    var selectedJobID: String?
    var showArchived = false

    @ObservationIgnored private let manager: AgentManager?
    /// Where transcripts are read from (the manager's store, or a fixture's).
    @ObservationIgnored private let store: AgentJobStore?
    @ObservationIgnored private var transcripts: [String: (stamp: Date, runs: Int, transcript: AgentTranscript)] = [:]
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?

    init(manager: AgentManager) {
        self.manager = manager
        store = manager.store
        feed = AgentActivityFeed()
    }

    /// A HUD over fixed records, for snapshots and demos; its buttons do nothing. `store` supplies transcripts.
    init(records: [AgentJobRecord], updates: [AgentManagerUpdate] = [], now: Date, store: AgentJobStore? = nil) {
        manager = nil
        self.store = store
        var feed = AgentActivityFeed(records: records)
        for update in updates { feed.apply(update) }
        self.feed = feed
        self.now = now
    }

    var items: [AgentActivityFeed.Item] { feed.items }
    /// The jobs panel: archived jobs and finished ones closed there stay out.
    var panelItems: [AgentActivityFeed.Item] {
        feed.items.filter { $0.record.isListed && ($0.record.status.isActive || $0.record.isDismissed != true) }
    }
    /// Home → Agents' list: archived jobs only when asked for.
    var listItems: [AgentActivityFeed.Item] { feed.items.filter { showArchived ? $0.record.isArchived == true : $0.record.isListed } }
    var archivedCount: Int { feed.items.filter { $0.record.isArchived == true }.count }
    var unseenCount: Int { feed.items.filter { $0.record.isUnseen && $0.record.isListed }.count }

    /// The job's transcript, rebuilt from its files (cached until the record changes).
    func transcript(_ id: String) -> AgentTranscript? {
        guard let store, let record = feed.item(id)?.record else { return nil }
        if let cached = transcripts[id], cached.stamp == record.updatedAt, cached.runs == record.runs.count { return cached.transcript }
        let transcript = store.transcript(of: record)
        transcripts[id] = (record.updatedAt, record.runs.count, transcript)
        return transcript
    }

    /// The row's preview: the latest result, message or ask from the transcript, else the live headline.
    func preview(_ item: AgentActivityFeed.Item) -> String {
        if item.record.status.isActive { return item.headline }
        return transcript(item.id)?.preview ?? item.headline
    }

    func select(_ id: String?) {
        selectedJobID = id
        if let id, feed.item(id)?.record.isUnseen == true { markSeen(id) }
    }
    var hasActiveJobs: Bool { !feed.active.isEmpty }

    func start() {
        guard listener == nil, let manager else { return }
        listener = Task { [weak self] in
            // Subscribe before reading the list, so nothing that happens in between is missed.
            let updates = await manager.subscribe()
            let records = await manager.jobs()
            self?.feed = AgentActivityFeed(records: records)
            for await update in updates {
                guard let self else { return }
                self.feed.apply(update)
            }
        }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.hasActiveJobs { self.now = Date() }
            }
        }
    }

    func stop() {
        listener?.cancel()
        clock?.cancel()
        listener = nil
        clock = nil
    }

    // MARK: Actions

    func interrupt(_ id: String) {
        guard let manager else { return }
        Task { await manager.interrupt(id) }
    }

    func approve(_ id: String, always: Bool = false) { answer(id, .approve(always: always)) }
    func decline(_ id: String) { answer(id, .decline) }
    func reply(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(id, .answer(text))
    }

    private func answer(_ id: String, _ decision: AgentApprovalDecision) {
        guard let manager else { return }
        let requestID = feed.item(id)?.record.pendingRequest?.id
        Task { [weak self] in
            do { try await manager.answer(id, requestID: requestID, decision: decision, fromUser: true) }
            catch { self?.lastError = "\(error)" }
        }
    }

    func markSeen(_ id: String, _ seen: Bool = true) {
        guard let manager else { return }
        Task { await manager.markSeen(id, seen) }
    }

    func setArchived(_ id: String, _ archived: Bool) {
        guard let manager else { return }
        if archived, selectedJobID == id { selectedJobID = nil }
        Task { await manager.setArchived(id, archived) }
    }

    func dismiss(_ id: String) {
        guard let manager else { return }
        Task { await manager.setDismissed(id) }
    }

    /// "I'm done" for a job waiting on a step only the user can do.
    func continueStep(_ id: String) {
        guard let manager else { return }
        Task { [weak self] in
            do { try await manager.continueAfterUserStep(id) } catch { self?.lastError = "\(error)" }
        }
    }

    /// Sends a follow-up from the transcript view.
    func followUp(_ id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let manager, !text.isEmpty else { return }
        Task { [weak self] in
            do { _ = try await manager.send(to: id, message: text) } catch { self?.lastError = "\(error)" }
        }
    }

    func openFolder(_ id: String) {
        guard let item = feed.item(id) else { return }
        NSWorkspace.shared.open(item.record.folder)
    }

    func open(_ file: String) {
        if file.hasPrefix("http://") || file.hasPrefix("https://"), let url = URL(string: file) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        }
    }

    // MARK: Formatting

    func elapsed(_ item: AgentActivityFeed.Item) -> String {
        guard let seconds = item.record.lastRunDuration(now: now) else { return "" }
        let total = Int(seconds)
        return total < 60 ? "\(total)s" : total < 3600 ? "\(total / 60)m \(total % 60)s" : "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
