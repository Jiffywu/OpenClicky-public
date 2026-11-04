import Foundation
import os

/// The app's side of a take-over: the consent card, the overlay and input blocker, and the report. The app's
/// implementation is `TakeoverPresenter` (Sources/OpenClicky/Takeover); occtl and tests use their own.
public protocol TakeoverPresenting: Sendable {
    func showConsent(_ offer: TakeoverOffer) async
    func hideConsent() async
    /// Called just before the first screenshot: put up the overlay and start watching for user input (which must
    /// trip `stop`). Throwing refuses the drive (for example when the input monitor cannot be installed, since a
    /// drive the user cannot interrupt must not run).
    func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws
    func driveEvent(_ event: TakeoverEvent) async
    func driveDidEnd(_ report: TakeoverReport) async
}

/// Shows nothing; for tests and headless runs that only need the flow.
public struct NullTakeoverPresenter: TakeoverPresenting {
    public init() {}
    public func showConsent(_ offer: TakeoverOffer) async {}
    public func hideConsent() async {}
    public func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws {}
    public func driveEvent(_ event: TakeoverEvent) async {}
    public func driveDidEnd(_ report: TakeoverReport) async {}
}

/// Everything one drive is made of. Built fresh for each approved drive, so settings changes apply to the next one.
public struct TakeoverDriveSetup: Sendable {
    public var planner: any TakeoverPlanner
    public var screen: any TakeoverScreenSource
    public var actuator: any DriveActuating
    public var safety: TakeoverSafetyGuard
    public var limits: TakeoverLimits
    public var rateLimits: DriveRateLimits
    public var timing: any DriveTiming

    public init(planner: any TakeoverPlanner, screen: any TakeoverScreenSource, actuator: any DriveActuating, safety: TakeoverSafetyGuard,
                limits: TakeoverLimits = TakeoverLimits(), rateLimits: DriveRateLimits = DriveRateLimits(),
                timing: any DriveTiming = ContinuousTiming()) {
        self.planner = planner
        self.screen = screen
        self.actuator = actuator
        self.safety = safety
        self.limits = limits
        self.rateLimits = rateLimits
        self.timing = timing
    }
}

/// Runs the take-over flow: offers, the user's consent, one drive at a time, stops and reports.
///
/// Consent comes only from the user (`approve(source:)` with the card or the user's own reply); the brain tools can
/// offer, start an approved drive, and stop. The stop switch is shared with the app's input monitor, which trips
/// it straight from its event tap; `stop(_:)` also cancels the drive task so a model call in flight ends at once.
public actor TakeoverController {
    public typealias SetupFactory = @Sendable (TakeoverBrief) async throws -> TakeoverDriveSetup

    public nonisolated let stopSwitch: TakeoverStopSwitch
    private let presenter: any TakeoverPresenting
    private let makeSetup: SetupFactory
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    /// A yes on the card starts the drive at once. A spoken yes waits for the brain's start_screen_takeover, so the
    /// brain can say "okay, driving now" first.
    public let startsOnCardApproval: Bool
    private let onReport: @Sendable (TakeoverReport) async -> Void

    private var consent: TakeoverConsentMachine
    private var driveTask: Task<TakeoverReport, Never>?
    public private(set) var lastReport: TakeoverReport?
    /// The phase, readable without awaiting (the brain tools' argument checks, the menu).
    private nonisolated let mirror = OSAllocatedUnfairLock<TakeoverPhase>(initialState: .idle)

    public init(presenter: any TakeoverPresenting = NullTakeoverPresenter(), consent: TakeoverConsentMachine = TakeoverConsentMachine(),
                stopSwitch: TakeoverStopSwitch = TakeoverStopSwitch(), startsOnCardApproval: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() }, makeID: @escaping @Sendable () -> String = { UUID().uuidString },
                onReport: @escaping @Sendable (TakeoverReport) async -> Void = { _ in }, makeSetup: @escaping SetupFactory) {
        self.presenter = presenter
        self.consent = consent
        self.stopSwitch = stopSwitch
        self.startsOnCardApproval = startsOnCardApproval
        self.now = now
        self.makeID = makeID
        self.onReport = onReport
        self.makeSetup = makeSetup
    }

    public nonisolated var phase: TakeoverPhase { mirror.withLock { $0 } }

    private func sync() {
        let current = consent.phase
        mirror.withLock { $0 = current }
    }

    // MARK: Offer and consent

    /// Shows the consent card for `brief`. Replaces an offer that has not started; refused while driving.
    @discardableResult
    public func offer(_ brief: TakeoverBrief) async throws -> TakeoverOffer {
        let offer = try consent.offer(brief, id: makeID(), now: now())
        sync()
        await presenter.showConsent(offer)
        return offer
    }

    /// The user said yes. From the card the drive starts right away (when `startsOnCardApproval`); a reply waits for
    /// the brain's start_screen_takeover.
    @discardableResult
    public func approve(source: TakeoverConsentSource, offerID: String? = nil) async throws -> TakeoverOffer {
        let offer = try consent.approve(offerID: offerID, source: source, now: now())
        sync()
        if source == .card, startsOnCardApproval { try await start() }
        return offer
    }

    /// The user's reply while the card is up: approves on a clear yes, declines on a clear no, otherwise leaves the
    /// card up. Returns the phase afterwards.
    @discardableResult
    public func userReplied(_ words: String) async -> TakeoverPhase {
        guard case .offered = consent.phase else { return consent.phase }
        if TakeoverReplyConsent.isClearYes(words) {
            _ = try? consent.approve(source: .userReply(words), now: now())
        } else if TakeoverReplyConsent.isClearNo(words) {
            consent.decline()
            await presenter.hideConsent()
        }
        sync()
        return consent.phase
    }

    /// The user said no or closed the card.
    public func decline(offerID: String? = nil) async {
        guard consent.decline(offerID: offerID) != nil else { return }
        sync()
        await presenter.hideConsent()
    }

    // MARK: Drive

    /// Starts the approved drive in the background and returns its offer. The report arrives through `onReport`
    /// (and `waitForDrive()`).
    @discardableResult
    public func start() async throws -> TakeoverOffer {
        let offer = try consent.beginDrive(now: now())
        // Cleared before the first suspension point: a stop that arrives while the card hides or the setup is built
        // (`stop(_:)` runs in between, since the actor is reentrant) must stay tripped so the drive ends at once.
        stopSwitch.reset()
        sync()
        await presenter.hideConsent()
        let setup: TakeoverDriveSetup
        do {
            setup = try await makeSetup(offer.brief)
            try await presenter.driveWillStart(offer, stop: stopSwitch, dryRun: setup.actuator.isDryRun)
        } catch {
            let report = TakeoverReport(brief: offer.brief, outcome: .failed, summary: "The drive could not start.", steps: [], dryRun: true,
                                        planner: "none", error: String(describing: error), startedAt: now(), durationSeconds: 0)
            await ended(report)
            throw error
        }
        let presenter = presenter
        let (events, sink) = AsyncStream<TakeoverEvent>.makeStream()
        // One consumer keeps the presenter's events in order.
        let forwarding = Task { for await event in events { await presenter.driveEvent(event) } }
        let driver = TakeoverDriver(brief: offer.brief, planner: setup.planner, screen: setup.screen, actuator: setup.actuator,
                                    safety: setup.safety, limits: setup.limits, rateLimits: setup.rateLimits, timing: setup.timing,
                                    stop: stopSwitch, onEvent: { sink.yield($0) })
        driveTask = Task {
            let report = await driver.run()
            sink.finish()
            await forwarding.value
            await self.ended(report)
            return report
        }
        return offer
    }

    private func ended(_ report: TakeoverReport) async {
        consent.finish(report.outcome)
        sync()
        lastReport = report
        driveTask = nil
        await presenter.driveDidEnd(report)
        await onReport(report)
    }

    /// Stops a running drive, or withdraws an offer that has not started. True when there was something to stop.
    @discardableResult
    public func stop(_ reason: TakeoverStopReason) async -> Bool {
        switch consent.phase {
        case .driving:
            consent.requestStop(reason)
            sync()
            stopSwitch.trip(reason)
            driveTask?.cancel()
            return true
        case .stopping:
            stopSwitch.trip(reason)
            driveTask?.cancel()
            return true
        case .offered, .approved:
            await decline()
            return true
        case .idle:
            return false
        }
    }

    /// Trips the stop switch from any thread, then lets the controller cancel the drive. For the event tap and
    /// the overlay's Stop button.
    public nonisolated func emergencyStop(_ reason: TakeoverStopReason) {
        stopSwitch.trip(reason)
        Task { await self.stop(reason) }
    }

    /// Waits for the running drive's report (nil when none is running).
    public func waitForDrive() async -> TakeoverReport? {
        guard let driveTask else { return nil }
        return await driveTask.value
    }

    /// Drops an offer or approval that has expired; call from a timer.
    public func expireStaleOffers() async {
        if consent.expireIfNeeded(now: now()) {
            sync()
            await presenter.hideConsent()
        }
    }
}

extension TakeoverReplyConsent {
    /// A reply that clearly declines ("no", "don't", "not now", "stop").
    public static func isClearNo(_ reply: String) -> Bool {
        let words = reply.lowercased().replacingOccurrences(of: "’", with: "'").split { !($0.isLetter || $0 == "'") }.map(String.init)
        guard !words.isEmpty, words.count <= 12 else { return false }
        let declines: Set<String> = ["no", "nope", "nah", "don't", "dont", "stop", "cancel", "never"]
        return words.contains(where: declines.contains) || words.joined(separator: " ").contains("not now")
    }
}
