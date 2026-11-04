import AppKit
import Observation
import OpenClickyKit

/// The notch as SwiftUI sees it: the presenter's state, published only when something visible changes (the presenter
/// itself advances on every pointer tick). Inputs go through `send`, and the presenter's effects come out of
/// `onEffect`.
@MainActor
@Observable
final class NotchModel {
    private(set) var surfaces: [UInt32: NotchSurface] = [:]
    private(set) var presentation: NotchPresentation = .idle
    private(set) var tab: NotchTab = .home
    /// 0…1 while the pointer rests on the notch.
    private(set) var dwell: Double?
    /// The share of its time the event on screen has left (short events only), for its ring.
    private(set) var eventProgress: Double?
    /// The current time to the second, for countdowns.
    private(set) var clock = Date()
    /// The meeting countdown waiting or on screen (the Home tab shows it too).
    private(set) var meeting: NotchLiveEvent?
    private(set) var geometries: [UInt32: NotchGeometry] = [:]
    private(set) var settings: NotchSettings
    /// The chat composer's text, kept while the notch folds.
    var draft = ""
    /// Bumped to put the cursor in the composer.
    private(set) var composerFocusToken = 0

    /// What the pill's Stop stops now (nil: no Stop).
    private(set) var stopTarget: NotchStopTarget?
    @ObservationIgnored private(set) var presenter: NotchPresenter
    @ObservationIgnored var onEffect: ((NotchEffect) -> Void)?
    /// Called when whether the notch wants Escape changes (the voice loop's Escape gate follows it).
    @ObservationIgnored var onEscapeInterestChange: (() -> Void)?
    @ObservationIgnored private let settingsURL: URL?

    init(settings: NotchSettings = NotchSettings(), settingsURL: URL? = nil) {
        self.settings = settings
        self.settingsURL = settingsURL
        presenter = NotchPresenter(timing: NotchTiming(hoverOpens: settings.hoverOpens))
    }

    func send(_ input: NotchInput, now: Date = Date()) {
        let wanted = presenter.wantsEscape
        let effects = presenter.handle(input, now: now)
        publish(now: now)
        if presenter.wantsEscape != wanted { onEscapeInterestChange?() }
        for effect in effects {
            if case .focusComposer = effect { composerFocusToken += 1 }
            onEffect?(effect)
        }
    }

    /// The presenter's surface for a display, read without observing (the window manager polls it).
    func currentSurface(on display: UInt32) -> NotchSurface { presenter.surface(on: display) }

    var wantsEscape: Bool { presenter.wantsEscape }
    var isExpanded: Bool { presenter.isExpanded }
    var chatHasResponse: Bool { presenter.chatHasResponse }

    func setGeometries(_ next: [UInt32: NotchGeometry]) {
        if next != geometries { geometries = next }
        publish(now: Date())
    }

    func update(_ newSettings: NotchSettings) {
        settings = newSettings
        presenter.timing.hoverOpens = newSettings.hoverOpens
        if let settingsURL { try? newSettings.save(to: settingsURL) }
    }

    func surface(on display: UInt32) -> NotchSurface { surfaces[display] ?? .tucked }

    private func publish(now: Date) {
        var next: [UInt32: NotchSurface] = [:]
        for id in geometries.keys { next[id] = presenter.surface(on: id) }
        if next != surfaces { surfaces = next }
        let presentation = presenter.presentation
        if presentation != self.presentation { self.presentation = presentation }
        if presenter.tab != tab { tab = presenter.tab }
        if presenter.stopTarget != stopTarget { stopTarget = presenter.stopTarget }
        let dwell = presenter.dwellProgress(now: now).map { ($0 * 50).rounded() / 50 }
        if dwell != self.dwell { self.dwell = dwell }
        var progress: Double?
        if let shown = presenter.current, let remaining = shown.remaining, case .visibleFor(let full) = shown.event.expiry, full > 0 {
            progress = (max(0, min(1, remaining / full)) * 50).rounded() / 50
        }
        if progress != eventProgress { eventProgress = progress }
        let second = now.timeIntervalSince1970.rounded(.down)
        if second != clock.timeIntervalSince1970.rounded(.down) { clock = now }
        let meeting = presenter.pendingEvents.first { if case .meetingCountdown = $0.kind { true } else { false } }
        if meeting != self.meeting { self.meeting = meeting }
    }
}
