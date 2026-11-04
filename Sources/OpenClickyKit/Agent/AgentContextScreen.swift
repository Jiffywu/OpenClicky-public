import Foundation

/// The voice loop's screen, with background jobs folded in: every turn's look carries the `[Your jobs]` note (what is
/// running, what each job last did and said, what waits on the user, what came back) as silent context for the
/// brain, and its screenshots are recorded as the turn's assets for `sessions_spawn` to hand to a new job.
@MainActor
public final class AgentContextScreen: TurnScreenLooking {
    public let base: any TurnScreenLooking
    private let assets: AgentTurnAssetsBox?
    private let context: (@Sendable () async -> String?)?
    private let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - assets: where the turn's screenshots go (nil keeps none).
    ///   - context: the jobs note for the brain (`AgentCoordinator.brainContext()`); nil adds none.
    public init(base: any TurnScreenLooking, assets: AgentTurnAssetsBox?, context: (@Sendable () async -> String?)?,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.base = base
        self.assets = assets
        self.context = context
        self.clock = clock
    }

    public func prefetch() { base.prefetch() }
    public func cancelPrefetch() { base.cancelPrefetch() }
    public func look() async -> TurnScreenLook { await decorate(base.look()) }
    public func lookAfterAction() async -> TurnScreenLook { await decorate(base.lookAfterAction()) }

    private func decorate(_ look: TurnScreenLook) async -> TurnScreenLook {
        var look = look
        // The pointer's screen first. A turn without a screenshot clears the last one, so a job never gets a stale view.
        let ordered = look.cursorScreenshot.map { cursor in [cursor] + look.screenshots.filter { $0 != cursor } } ?? []
        assets?.record(AgentTurnAssets(screenshots: ordered.map(\.jpeg), capturedAt: clock()))
        if let note = await context?(), !note.isEmpty { look.appNotes.append(note) }
        return look
    }
}
