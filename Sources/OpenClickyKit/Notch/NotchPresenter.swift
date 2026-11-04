import Foundation

/// The notch's tabs when it is open.
public enum NotchTab: String, Sendable, Hashable, Codable, CaseIterable {
    case home, chat, settings

    public var title: String {
        switch self {
        case .home: "Home"
        case .chat: "Chat"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left.and.text.bubble.right"
        case .settings: "gearshape"
        }
    }
}

/// What the notch presents, in HeyClicky's terms (docs/re/03 §8): nothing in particular, the onboarding card pinned
/// open, the chat composer, a typed answer, or a live event.
public enum NotchPresentation: Sendable, Hashable {
    case idle
    case onboardingPinned
    case textInput
    case textResponse
    case liveEvent(NotchLiveEvent)

    public var name: String {
        switch self {
        case .idle: "idle"
        case .onboardingPinned: "onboardingPinned"
        case .textInput: "textInput"
        case .textResponse: "textResponse"
        case .liveEvent(let event): "liveEvent(\(event.id))"
        }
    }
}

public enum NotchHideReason: Sendable, Hashable {
    /// System UI is up (Spotlight, Control Center, the screenshot UI, a picker, Mission Control).
    case yielding(NotchYieldReason)
    /// The front app is full screen on this display.
    case fullscreen
}

/// What one display's notch panel shows.
public enum NotchSurface: Sendable, Hashable {
    case hidden(NotchHideReason)
    /// Only the hardware notch (or a thin sliver without one): click or hover to open.
    case tucked
    /// A voice turn or always-on voice, as the pill hanging from the notch.
    case activity
    case liveEvent(NotchLiveEvent)
    /// The onboarding card, pinned open until setup is done.
    case onboarding
    /// The open panel on a tab.
    case open(NotchTab)

    public var name: String {
        switch self {
        case .hidden(.yielding(let reason)): "hidden(\(reason.rawValue))"
        case .hidden(.fullscreen): "hidden(fullscreen)"
        case .tucked: "tucked"
        case .activity: "activity"
        case .liveEvent(let event): "liveEvent(\(event.id))"
        case .onboarding: "onboarding"
        case .open(let tab): "open(\(tab.rawValue))"
        }
    }

    public var isHidden: Bool { if case .hidden = self { true } else { false } }
}

public enum NotchOpenTrigger: String, Sendable, Hashable {
    /// The pointer rested on the notch.
    case hover
    /// A click on the notch, a tab or something inside.
    case click
    /// The text key or the menu asked for the composer.
    case textKey
}

public struct NotchTiming: Sendable, Hashable {
    /// How long the pointer rests on the notch before it opens.
    public var hoverDwell: TimeInterval
    /// After a hover-open, how long the pointer may be away before the notch folds again.
    public var hoverCollapseGrace: TimeInterval
    /// Whether resting on the notch opens it at all.
    public var hoverOpens: Bool

    public init(hoverDwell: TimeInterval = 0.45, hoverCollapseGrace: TimeInterval = 0.6, hoverOpens: Bool = true) {
        self.hoverDwell = hoverDwell
        self.hoverCollapseGrace = hoverCollapseGrace
        self.hoverOpens = hoverOpens
    }
}

public enum NotchInput: Sendable, Hashable {
    /// Where the pointer is, every tick: the display under it, whether it is on the notch's hot zone, and whether it
    /// is over the panel's visible content.
    case pointer(display: UInt32, inHotZone: Bool, inPanel: Bool)
    /// A click on the notch itself or the pill hanging from it.
    case clickNotch(display: UInt32)
    /// A click anywhere outside the panel.
    case clickOutside
    case escape
    case selectTab(NotchTab)
    /// Open the composer (the text key or the menu).
    case openChat(display: UInt32?)
    case submitText(String)
    case post(NotchLiveEvent)
    /// The source took an event back (the meeting moved, the job's question was answered elsewhere).
    case withdraw(String)
    /// A button on an event.
    case perform(eventID: String, actionID: String)
    /// A click on an event's body.
    case clickEvent(String)
    /// The event's close button.
    case dismiss(String)
    /// A voice turn or always-on voice is showing (or stopped showing) in the pill.
    case activity(Bool)
    /// What the pill's Stop would stop now (nil: nothing, and the pill has no Stop).
    case stoppable(NotchStopTarget?)
    /// The pill's Stop was clicked.
    case stop
    case onboarding(pinned: Bool)
    /// The system UI the notch steps aside for right now (after the hard limits).
    case yield(Set<NotchYieldReason>)
    /// Displays whose front app is full screen.
    case fullscreen(Set<UInt32>)
    /// Time passed.
    case tick
}

public enum NotchEffect: Sendable, Hashable {
    case openURL(URL)
    case openJob(String)
    case revealFile(String)
    case suppress(NotchSuppression)
    case submit(String)
    case focusComposer
    case openHome
    case openSettings
    case openOnboarding
    /// Open a Settings page by its id ("usage", "developer").
    case openSettingsPage(String)
    /// Stop what is running, through its usual interrupt path.
    case stop(NotchStopTarget)
    /// An event appeared on screen for the first time.
    case shown(String)
    /// The user closed an event or used one of its buttons; its source shouldn't post it again.
    case dismissed(String)
}

/// The notch's state machine. Pure: feed it inputs with the time, apply the effects it returns, and draw `surface`.
/// The app, `occtl notch simulate` and the tests run the same code.
///
/// Live events queue: one shows at a time, short ones before long-lived ones (a meeting countdown steps back for a
/// "job done" and returns), then by priority. A short event's clock runs only while it is actually on screen, so an
/// event posted during a voice turn, with the notch open, or while hidden still gets its full time.
public struct NotchPresenter: Sendable {
    public struct Shown: Sendable, Hashable {
        public var event: NotchLiveEvent
        /// Seconds of visibility left for `.visibleFor` events.
        public var remaining: TimeInterval?
        public var wasShown = false
    }

    public var timing: NotchTiming
    public private(set) var isExpanded = false
    public private(set) var tab: NotchTab = .home
    public private(set) var openedBy: NotchOpenTrigger?
    /// The chat tab shows an answer (after a question was sent) rather than an empty composer.
    public private(set) var chatHasResponse = false
    public private(set) var onboardingPinned = false
    public private(set) var activityBusy = false
    /// What Stop stops now; the pill shows a Stop button while it is set.
    public private(set) var stopTarget: NotchStopTarget?
    public private(set) var yielding: Set<NotchYieldReason> = []
    public private(set) var fullscreenDisplays: Set<UInt32> = []
    /// The display the notch is presenting on: the pointer's while folded, fixed while open.
    public private(set) var activeDisplay: UInt32?
    public private(set) var current: Shown?
    public private(set) var queue: [Shown] = []
    public private(set) var dwellStartedAt: Date?
    private var pointerLeftAt: Date?
    /// After the notch folds, resting on it opens it again only once the pointer has left the housing (folding with
    /// the pointer still on it must not bounce it open).
    private var dwellNeedsFreshEntry = false
    private var lastNow: Date?

    public init(timing: NotchTiming = NotchTiming()) {
        self.timing = timing
    }

    // MARK: Derived

    public var presentation: NotchPresentation {
        if onboardingPinned { return .onboardingPinned }
        if isExpanded, tab == .chat { return chatHasResponse ? .textResponse : .textInput }
        if !isExpanded, let current { return .liveEvent(current.event) }
        return .idle
    }

    /// The surface on the active display.
    public var surface: NotchSurface {
        if let reason = yielding.min() { return .hidden(.yielding(reason)) }
        if let display = activeDisplay, fullscreenDisplays.contains(display) {
            // Over a full-screen app the notch keeps only a voice turn's pill: it is the only sign the keys were heard
            // (the overlay leaves the pill to the notch). Nothing opens there, and events wait.
            return activityBusy ? .activity : .hidden(.fullscreen)
        }
        if isExpanded { return .open(tab) }
        if activityBusy { return .activity }
        if onboardingPinned { return .onboarding }
        if let current { return .liveEvent(current.event) }
        return .tucked
    }

    /// The surface on any display: the active one presents, the others only keep their notch.
    public func surface(on display: UInt32) -> NotchSurface {
        if let reason = yielding.min() { return .hidden(.yielding(reason)) }
        let isActive = activeDisplay == nil || activeDisplay == display
        if fullscreenDisplays.contains(display) { return isActive && activityBusy ? .activity : .hidden(.fullscreen) }
        if !isActive { return .tucked }
        return surface
    }

    /// 0…1 while the pointer rests on the notch, for the ring that fills before it opens.
    public func dwellProgress(now: Date) -> Double? {
        guard let dwellStartedAt, timing.hoverDwell > 0 else { return nil }
        return min(1, max(0, now.timeIntervalSince(dwellStartedAt) / timing.hoverDwell))
    }

    /// Escape folds the open notch (and only then is it the notch's).
    public var wantsEscape: Bool { isExpanded }

    /// Every event waiting or on screen.
    public var pendingEvents: [NotchLiveEvent] { (current.map { [$0.event] } ?? []) + queue.map(\.event) }

    // MARK: Input

    @discardableResult
    public mutating func handle(_ input: NotchInput, now: Date) -> [NotchEffect] {
        advanceClock(to: now)
        var effects: [NotchEffect] = []
        switch input {
        case .pointer(let display, let inHotZone, let inPanel):
            if !isExpanded { activeDisplay = display }
            if isExpanded {
                if inPanel || inHotZone { pointerLeftAt = nil } else if pointerLeftAt == nil { pointerLeftAt = now }
            }
            if !inHotZone { dwellNeedsFreshEntry = false }
            if canDwell, inHotZone, !dwellNeedsFreshEntry {
                if dwellStartedAt == nil { dwellStartedAt = now }
            } else {
                dwellStartedAt = nil
            }
        case .clickNotch(let display):
            if onboardingPinned { break }
            if isExpanded { collapse() } else { expand(.click, display: display) }
        case .clickOutside:
            if isExpanded { collapse() }
        case .escape:
            if isExpanded { collapse() }
        case .selectTab(let tab):
            guard isExpanded else { break }
            openedBy = .click
            pointerLeftAt = nil
            self.tab = tab
            if tab == .chat { effects.append(.focusComposer) }
        case .openChat(let display):
            guard !onboardingPinned, !isHidden(display ?? activeDisplay) else { break }
            if !isExpanded { expand(.textKey, display: display) }
            openedBy = openedBy == .hover ? .click : openedBy
            tab = .chat
            chatHasResponse = false
            effects.append(.focusComposer)
        case .submitText(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { break }
            if !isExpanded { expand(.click, display: activeDisplay) }
            openedBy = .click
            tab = .chat
            chatHasResponse = true
            effects.append(.submit(trimmed))
        case .post(let event):
            post(event, now: now)
        case .withdraw(let id):
            remove(id)
        case .perform(let eventID, let actionID):
            guard let event = event(eventID), let action = event.actions.first(where: { $0.id == actionID }) else { break }
            effects += perform(action, on: event)
        case .clickEvent(let id):
            guard let event = event(id) else { break }
            if let action = event.bodyAction {
                effects += perform(action, on: event)
            } else if !isExpanded {
                expand(.click, display: activeDisplay)
            }
        case .dismiss(let id):
            guard event(id) != nil else { break }
            remove(id)
            effects.append(.dismissed(id))
        case .activity(let busy):
            activityBusy = busy
        case .stoppable(let target):
            stopTarget = target
        case .stop:
            if let target = stopTarget { effects.append(.stop(target)) }
        case .onboarding(let pinned):
            onboardingPinned = pinned
            if pinned, isExpanded { collapse() }
            if pinned { dwellStartedAt = nil }
        case .yield(let reasons):
            yielding = reasons
            if !reasons.isEmpty {
                if isExpanded { collapse() }
                dwellStartedAt = nil
            }
        case .fullscreen(let displays):
            fullscreenDisplays = displays
            if let active = activeDisplay, displays.contains(active) {
                if isExpanded { collapse() }
                dwellStartedAt = nil
            }
        case .tick:
            break
        }
        effects += settle(now: now)
        return effects
    }

    // MARK: Internals

    /// Resting on the notch opens it, except while it is open, pinned, hidden or showing a voice turn (a pointer
    /// parked at the top during a turn shouldn't cover the answer; a click still opens it).
    private var canDwell: Bool {
        timing.hoverOpens && !isExpanded && !onboardingPinned && !activityBusy && !isHidden(activeDisplay)
    }

    private func isHidden(_ display: UInt32?) -> Bool {
        if !yielding.isEmpty { return true }
        if let display, fullscreenDisplays.contains(display) { return true }
        return false
    }

    private mutating func expand(_ trigger: NotchOpenTrigger, display: UInt32?) {
        guard !onboardingPinned, !isHidden(display ?? activeDisplay) else { return }
        isExpanded = true
        openedBy = trigger
        if let display { activeDisplay = display }
        dwellStartedAt = nil
        pointerLeftAt = nil
    }

    private mutating func collapse() {
        isExpanded = false
        openedBy = nil
        pointerLeftAt = nil
        dwellStartedAt = nil
        dwellNeedsFreshEntry = true
    }

    private func event(_ id: String) -> NotchLiveEvent? {
        if current?.event.id == id { return current?.event }
        return queue.first { $0.event.id == id }?.event
    }

    private mutating func remove(_ id: String) {
        if current?.event.id == id { current = nil }
        queue.removeAll { $0.event.id == id }
    }

    private mutating func perform(_ action: NotchAction, on event: NotchLiveEvent) -> [NotchEffect] {
        remove(event.id)
        switch action.kind {
        case .openURL(let url): return [.openURL(url), .dismissed(event.id)]
        case .openJob(let id): return [.openJob(id), .dismissed(event.id)]
        case .revealFile(let file): return [.revealFile(file), .dismissed(event.id)]
        case .suppress(let kind): return [.suppress(kind), .dismissed(event.id)]
        case .stop(let target): return [.stop(target), .dismissed(event.id)]
        case .openSettings(let page): return [.openSettingsPage(page), .dismissed(event.id)]
        case .dismiss: return [.dismissed(event.id)]
        }
    }

    private static func isShort(_ event: NotchLiveEvent) -> Bool {
        if case .visibleFor = event.expiry { return true }
        return false
    }

    private static func fullTime(_ event: NotchLiveEvent) -> TimeInterval? {
        if case .visibleFor(let seconds) = event.expiry { return seconds }
        return nil
    }

    private mutating func post(_ event: NotchLiveEvent, now: Date) {
        if current?.event.id == event.id {
            current?.event = event
            if let full = Self.fullTime(event) { current?.remaining = full }
            return
        }
        if let index = queue.firstIndex(where: { $0.event.id == event.id }) {
            queue[index].event = event
            queue[index].remaining = Self.fullTime(event)
            return
        }
        queue.append(Shown(event: event, remaining: Self.fullTime(event)))
        // An event that would come first steps in front of the one on screen, which goes back to wait with the time it
        // has left: a meeting countdown makes way for a short note, a "job done" for a question.
        if let shown = current, Self.precedes(event, shown.event) {
            queue.append(shown)
            current = nil
        }
    }

    /// The order events wait in: short ones before long-lived ones, then by priority, then first posted.
    private static func precedes(_ x: NotchLiveEvent, _ y: NotchLiveEvent) -> Bool {
        let xs = isShort(x), ys = isShort(y)
        if xs != ys { return xs }
        return x.priority > y.priority
    }

    /// Charges the time since the last input to the event on screen.
    private mutating func advanceClock(to now: Date) {
        defer { lastNow = now }
        guard let lastNow, now > lastNow, var shown = current, case .liveEvent = surface else { return }
        if let remaining = shown.remaining {
            shown.remaining = remaining - now.timeIntervalSince(lastNow)
            current = shown
        }
    }

    private mutating func settle(now: Date) -> [NotchEffect] {
        var effects: [NotchEffect] = []
        if let dwellStartedAt, now.timeIntervalSince(dwellStartedAt) >= timing.hoverDwell, canDwell {
            expand(.hover, display: activeDisplay)
        }
        if isExpanded, openedBy == .hover, let pointerLeftAt, now.timeIntervalSince(pointerLeftAt) >= timing.hoverCollapseGrace {
            collapse()
        }
        if let shown = current, Self.isExpired(shown, now: now) { current = nil }
        queue.removeAll { Self.isExpired($0, now: now) }
        if current == nil, let next = nextQueued() {
            current = queue.remove(at: next)
        }
        if let shown = current, !shown.wasShown, case .liveEvent = surface {
            current?.wasShown = true
            effects.append(.shown(shown.event.id))
        }
        return effects
    }

    private static func isExpired(_ shown: Shown, now: Date) -> Bool {
        switch shown.event.expiry {
        case .visibleFor: return (shown.remaining ?? 0) <= 0
        case .at(let date): return now >= date
        case .untilDismissed: return false
        }
    }

    private func nextQueued() -> Int? {
        guard !queue.isEmpty else { return nil }
        return queue.indices.min { a, b in
            let x = queue[a].event, y = queue[b].event
            if Self.precedes(x, y) { return true }
            if Self.precedes(y, x) { return false }
            return x.postedAt < y.postedAt
        }
    }
}
