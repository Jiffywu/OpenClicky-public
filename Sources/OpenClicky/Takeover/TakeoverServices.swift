import AppKit
import OpenClickyKit
import os

/// The app's take-over subsystem in one place: the controller, its presenter (consent card, overlay, input
/// blocker) and the brain tools. The voice pipeline registers `tools.appTools` with the brain, forwards the user's
/// replies while a card is up (`controller.userReplied`), and turns `onReport` into the next turn's `[App]` note.
///
/// Real input is posted only when `dryRun()` is false, only for a drive the user approved, and only while the input
/// blocker is installed (so Escape and any user input stop it).
@MainActor
final class TakeoverServices {
    let presenter: TakeoverPresenter
    let controller: TakeoverController
    let tools: TakeoverTools
    /// Called with every finished drive's report.
    var onReport: ((TakeoverReport) -> Void)?

    /// - Parameters:
    ///   - config: read for each drive, so model changes apply to the next one.
    ///   - dryRun: when true, drives show what they would do and post nothing.
    init(config: @escaping @Sendable () -> OpenClickyConfig, credentials: any CredentialStore, frontApp: FrontAppTracker,
         dryRun: @escaping @Sendable () -> Bool = { false }, limits: TakeoverLimits = TakeoverLimits()) {
        let presenter = TakeoverPresenter()
        let ownWindows = presenter.ownWindows
        let relay = ReportRelay()
        self.presenter = presenter
        controller = TakeoverController(presenter: presenter, onReport: { report in await relay.deliver(report) }) { _ in
            let current = config()
            let factory = EngineFactory(config: current, catalog: ((try? ModelCatalog.builtIn()) ?? ModelCatalog(models: [])).merging(current.models),
                                        credentials: credentials)
            let planner = try TakeoverPlannerChoice.automatic.makePlanner(factory: factory)
            let screen = LiveTakeoverScreen(exclusion: { CaptureExclusion(windowNumbers: ownWindows.numbers) },
                                            frontApp: { frontApp.current })
            let probe = MacTakeoverProbe(ignoredWindows: { ownWindows.numbers })
            let policy = TakeoverSafetyPolicy.standard(ownProcessID: ProcessInfo.processInfo.processIdentifier,
                                                       ownBundleID: Bundle.main.bundleIdentifier)
            let actuator: any DriveActuating = dryRun() ? DryRunActuator() : CGEventActuator(poster: HIDEventPoster())
            return TakeoverDriveSetup(planner: planner, screen: screen, actuator: actuator,
                                      safety: TakeoverSafetyGuard(policy: policy, probe: probe), limits: limits)
        }
        tools = TakeoverTools(controller: controller)
        presenter.controller = controller
        relay.owner = self
    }

    /// Ends any drive (app quit).
    func shutdown() async {
        await controller.stop(.cancelled)
        presenter.blocker.stop()
    }

    @MainActor
    private final class ReportRelay: Sendable {
        weak var owner: TakeoverServices?
        func deliver(_ report: TakeoverReport) { owner?.onReport?(report) }
    }
}

/// OpenClicky's own take-over windows, readable off the main thread (screenshots and the probe skip them).
final class TakeoverOwnWindows: Sendable {
    private let state = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
    var numbers: Set<Int> { state.withLock { $0 } }
    func set(_ numbers: Set<Int>) { state.withLock { $0 = numbers } }
}

/// Shows the take-over on screen: the consent card, the drive overlay, and the input blocker that lets the user stop it.
@MainActor
final class TakeoverPresenter: TakeoverPresenting {
    let card = TakeoverConsentPanelController()
    let overlay = TakeoverOverlayController()
    let blocker = TakeoverInputBlocker()
    let ownWindows = TakeoverOwnWindows()
    weak var controller: TakeoverController?
    private var dryRun = false
    /// The drive as the notch shows it: driving (with the step under way) or over (`.idle`).
    var onDriveChange: ((TakeoverPhase, String?, Bool) -> Void)?
    private var drivingOffer: TakeoverOffer?

    func showConsent(_ offer: TakeoverOffer) async {
        let content = TakeoverConsentCardContent(task: offer.brief.task, steps: offer.brief.steps, app: offer.brief.app)
        card.show(content, onApprove: { [weak self] in
            guard let controller = self?.controller else { return }
            Task { try? await controller.approve(source: .card, offerID: offer.id) }
        }, onDecline: { [weak self] in
            guard let controller = self?.controller else { return }
            Task { await controller.decline(offerID: offer.id) }
        })
        refreshOwnWindows()
    }

    func hideConsent() async {
        card.hide()
        refreshOwnWindows()
    }

    func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws {
        self.dryRun = dryRun
        drivingOffer = offer
        onDriveChange?(.driving(offer), nil, dryRun)
        overlay.show(dryRun: dryRun)
        refreshOwnWindows()
        let controller = controller
        do {
            try blocker.start(stop: stop) { reason in controller?.emergencyStop(reason) }
        } catch {
            // A real drive the user cannot interrupt must not run. A dry run posts nothing, so it may go on.
            if !dryRun {
                overlay.hide()
                refreshOwnWindows()
                drivingOffer = nil
                onDriveChange?(.idle, nil, dryRun)
                throw error
            }
        }
    }

    func driveEvent(_ event: TakeoverEvent) async {
        switch event {
        case .acting(_, let summary, let point):
            overlay.model.content.detail = summary.prefix(1).uppercased() + summary.dropFirst()
            overlay.model.content.cursorLabel = summary
            if let point {
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                overlay.model.cursorGlobal = CGPoint(x: point.x, y: primaryHeight - point.y)
            }
        case .planning:
            overlay.model.content.detail = "Looking at the screen…"
        case .narration(_, let text):
            overlay.model.content.detail = text
        case .refused(_, let summary, _):
            overlay.model.content.detail = "Skipped: \(summary)"
        case .finished(let outcome):
            overlay.model.content.isStopping = true
            overlay.model.content.title = outcome == .finished ? "Done" : "Stopped"
        default:
            break
        }
        if let offer = drivingOffer {
            let stopping = if case .finished = event { true } else { false }
            onDriveChange?(stopping ? .stopping(offer, .cancelled) : .driving(offer), overlay.model.content.detail, dryRun)
        }
    }

    func driveDidEnd(_ report: TakeoverReport) async {
        drivingOffer = nil
        onDriveChange?(.idle, nil, dryRun)
        blocker.stop()
        overlay.hide()
        refreshOwnWindows()
    }

    private func refreshOwnWindows() {
        var numbers = Set(overlay.windowNumbers)
        if let card = card.windowNumber { numbers.insert(card) }
        ownWindows.set(numbers)
    }
}
