import Foundation
import Testing
@testable import OpenClickyKit

// The notch's live events for features that already exist (routines, spending limits, provider failures, the browser
// extension, take-over drives, always-on voice) and the Stop pill.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func report(_ outcome: AgentJobReport.Outcome, routine: String? = "r1", error: String? = nil, run: Int = 3) -> AgentJobReport {
    var report = AgentJobReport(jobID: "j7", run: run, title: "Morning brief", outcome: outcome, spoken: "Three meetings and one deadline.",
                                files: ["/tmp/j7/brief.md"], startedAt: t0, finishedAt: t0)
    report.routineID = routine
    report.error = error
    return report
}

private func diagnosis(_ verdict: ProviderVerdict = .networkBlocked, provider: String = "openrouter") -> ProviderUnavailableError {
    ProviderUnavailableError(diagnosis: ProviderDiagnosis(providerID: provider, providerName: "OpenRouter", host: "openrouter.ai",
                                                          purpose: .brain, verdict: verdict, probe: "timed out", failure: "connect"),
                             underlying: "URLError(-1001)")
}

private func peer(_ bundleID: String) -> BrowserPeer {
    BrowserPeer(id: UUID().uuidString, session: "s", profileId: "p", origin: "chrome-extension://abc", browser: bundleID, extensionVersion: "1.0",
                connectedAt: t0, lastSeen: t0)
}

/// Every new kind, as the sources make them.
private func samples() throws -> [String: NotchLiveEvent] {
    var mapper = AgentLiveEvents()
    let doneEvents = mapper.apply(.report(report(.done)), now: t0)
    let failedEvents = mapper.apply(.report(report(.failed, error: "The harness exited.", run: 4)), now: t0)
    let routineDone = try #require(doneEvents.first)
    let routineFailed = try #require(failedEvents.first)
    let warned = UsageLiveEvents.event(for: UsageLimitAlert(id: "usage:day:2027-01-15:warned", kind: .warned,
                                                            status: UsageLimitStatus(level: .warning, period: .day, spentUSD: 0.85, limitUSD: 1, stops: true)),
                                       now: t0)
    let stopped = UsageLiveEvents.event(for: UsageLimitAlert(id: "usage:day:2027-01-15:stopped", kind: .stopped,
                                                             status: UsageLimitStatus(level: .reached, period: .day, spentUSD: 1.02, limitUSD: 1, stops: true)),
                                        now: t0)
    var providers = ProviderLiveEvents()
    let providerEvent = providers.event(for: diagnosis(), now: t0)
    let provider = try #require(providerEvent)
    var browsers = BrowserLiveEvents()
    let connectedEvents = browsers.changes(peers: [peer("com.google.Chrome")], now: t0)
    let disconnectedEvents = browsers.changes(peers: [], now: at(1))
    let connected = try #require(connectedEvents.first)
    let disconnected = try #require(disconnectedEvents.first)
    let offer = TakeoverOffer(id: "o1", brief: TakeoverBrief(task: "Rename the three screenshots on the Desktop"), offeredAt: t0)
    let driving = try #require(TakeoverLiveEvents.event(for: .driving(offer), detail: "Click Rename", dryRun: false, now: t0))
    var display = AlwaysOnDisplay(state: .on)
    display.voice = .listening
    let listening = try #require(AlwaysOnLiveEvents.event(for: display, hint: "Triple-tap Control ends it", now: t0))
    return ["routineDone": routineDone, "routineFailed": routineFailed, "usageWarned": warned, "usageStopped": stopped,
            "provider": provider, "browserConnected": connected, "browserDisconnected": disconnected, "takeover": driving,
            "alwaysOn": listening]
}

@Suite("Notch service events")
struct NotchServiceEventTests {
    @Test func eachNewKindHasItsWordsPriorityExpiryAndButtons() throws {
        let events = try samples()
        func check(_ name: String, priority: Int, expiry: NotchEventExpiry, tone: NotchTone, buttons: [String],
                   title: String, subtitle: String?, quiet: ProactiveKind?) throws {
            let event = try #require(events[name], "\(name)")
            #expect(event.priority == priority, "\(name) priority")
            #expect(event.expiry == expiry, "\(name) expiry")
            #expect(event.tone == tone, "\(name) tone")
            #expect(event.actions.map(\.id) == buttons, "\(name) buttons")
            #expect(event.title == title, "\(name) title")
            #expect(event.subtitle(now: t0) == subtitle, "\(name) subtitle")
            #expect(event.proactiveKind == quiet, "\(name) quiet kind")
        }
        try check("routineDone", priority: 1, expiry: .visibleFor(8), tone: .success, buttons: ["file", "show"],
                  title: "Routine done: Morning brief", subtitle: "Three meetings and one deadline.", quiet: .routineNotice)
        try check("routineFailed", priority: 1, expiry: .visibleFor(10), tone: .warning, buttons: ["show"],
                  title: "Routine didn't finish: Morning brief", subtitle: "The harness exited.", quiet: .routineNotice)
        try check("usageWarned", priority: 2, expiry: .visibleFor(8), tone: .attention, buttons: ["usage"],
                  title: "Nearing your spending limit", subtitle: "You've used $0.85 of your $1.00 limit today.", quiet: nil)
        try check("usageStopped", priority: 4, expiry: .visibleFor(12), tone: .warning, buttons: ["usage"],
                  title: "Spending limit reached",
                  subtitle: "You've reached your $1.00 limit today, so OpenClicky has stopped calling paid models. Raise it in Settings → Usage.",
                  quiet: nil)
        try check("provider", priority: 3, expiry: .visibleFor(10), tone: .warning, buttons: ["providers"],
                  title: "OpenRouter isn't answering", subtitle: NotchLiveEvent.clip(diagnosis().diagnosis.explanation, 140), quiet: nil)
        let chrome = peer("com.google.Chrome").browserName
        try check("browserConnected", priority: 0, expiry: .visibleFor(4), tone: .success, buttons: [],
                  title: "\(chrome) is connected", subtitle: "Background jobs can use your browser", quiet: nil)
        try check("browserDisconnected", priority: 0, expiry: .visibleFor(4), tone: .info, buttons: [],
                  title: "\(chrome) disconnected", subtitle: "Jobs can't use the browser until it reconnects", quiet: nil)
        try check("takeover", priority: 5, expiry: .untilDismissed, tone: .attention, buttons: ["stop"],
                  title: "OpenClicky is driving", subtitle: "Click Rename", quiet: nil)
        try check("alwaysOn", priority: 0, expiry: .untilDismissed, tone: .info, buttons: ["stop"],
                  title: "Always-on is listening", subtitle: "Just talk · Triple-tap Control ends it", quiet: nil)
        // Routine cards open the job like job cards do.
        #expect(events["routineDone"]?.bodyAction?.kind == .openJob("j7"))
        #expect(events["usageStopped"]?.symbol == "dollarsign.circle.fill")
    }

    @Test func routineCardsReplaceJobCardsOnlyForRoutineRuns() {
        var mapper = AgentLiveEvents()
        let job = mapper.apply(.report(report(.done, routine: nil)), now: t0)
        let routine = mapper.apply(.report(report(.done)), now: t0)
        let question = mapper.apply(.report(report(.needsYou)), now: t0)
        let stopped = mapper.apply(.report(report(.stopped)), now: t0)
        #expect(job.first?.title == "Morning brief is done")
        #expect(routine.first?.title == "Routine done: Morning brief")
        // A routine run that needs the user is still a question; a stopped one says nothing.
        #expect(question.first?.title == "Morning brief needs you")
        #expect(stopped.isEmpty)
    }

    @Test func routineCardsWaitOutACallWhileLimitsDriveAndTheBrowserDoNot() throws {
        let events = try samples()
        var gate = QuietGate()
        _ = gate.update(QuietContext(reasons: [.onCall(app: "Zoom")]), now: t0)
        for (name, event) in events {
            guard let kind = event.proactiveKind else { continue }
            let decision = gate.offer(ProactiveItem(id: "notch:" + event.id, kind: kind, title: event.title, createdAt: t0), now: t0)
            #expect(decision == .hold, "\(name) waits for the call to end")
        }
        #expect(gate.held.map(\.kind) == [.routineNotice, .routineNotice])
        // Everything else is about what's happening now and never waits.
        let immediate = events.filter { $0.value.proactiveKind == nil }.keys.sorted()
        #expect(immediate == ["alwaysOn", "browserConnected", "browserDisconnected", "provider", "takeover", "usageStopped", "usageWarned"])
        // The call ends: the routine notes come back to be shown.
        let released = gate.update(QuietContext(), now: at(600)).release
        #expect(released.count == 2)
    }

    @Test func thePresenterOrdersTheNewKindsAndHoldsThemWhileTheNotchIsBusy() throws {
        let events = try samples()
        var presenter = NotchPresenter()
        // A voice turn has the notch: nothing shows and no clock runs.
        presenter.handle(.activity(true), now: t0)
        for name in ["browserConnected", "routineDone", "usageWarned", "provider"] {
            presenter.handle(.post(try #require(events[name])), now: t0)
        }
        presenter.handle(.tick, now: at(30))
        #expect(presenter.surface == .activity)
        #expect(presenter.pendingEvents.count == 4)
        presenter.handle(.activity(false), now: at(30))
        // Highest priority first: the provider (3), the warning (2), the routine (1), the browser (0).
        var order: [String] = []
        var time = 30.0
        while let current = presenter.current?.event, time < 200 {
            if order.last != current.title { order.append(current.title) }
            time += 0.5
            presenter.handle(.tick, now: at(time))
        }
        #expect(order == ["OpenRouter isn't answering", "Nearing your spending limit", "Routine done: Morning brief",
                          "\(peer("com.google.Chrome").browserName) is connected"])
        // 30 s busy + 10 + 8 + 8 + 4 s on screen: every card got its full time after the turn.
        #expect(time >= 60 && time <= 61)

        // A drive (long-lived) steps behind a short card and comes back; a stopped limit outranks a warning.
        presenter.handle(.post(try #require(events["takeover"])), now: at(300))
        presenter.handle(.post(try #require(events["usageStopped"])), now: at(300.1))
        #expect(presenter.current?.event.title == "Spending limit reached")
        presenter.handle(.tick, now: at(313))
        #expect(presenter.current?.event.id == TakeoverLiveEvents.eventID)
        presenter.handle(.tick, now: at(3_600))
        #expect(presenter.current?.event.id == TakeoverLiveEvents.eventID, "a drive stays up until its source takes it down")
        presenter.handle(.withdraw(TakeoverLiveEvents.eventID), now: at(3_601))
        #expect(presenter.surface == .tucked)
    }

    @Test func repeatedFailuresAndBrowserListsDontFloodTheNotch() throws {
        var providers = ProviderLiveEvents(repeatAfter: 300)
        let first = providers.event(for: diagnosis(), now: t0)
        let repeated = providers.event(for: diagnosis(), now: at(60))
        let otherVerdict = providers.event(for: diagnosis(.keyRejected), now: at(60))
        let otherProvider = providers.event(for: diagnosis(provider: "anthropic"), now: at(60))
        let later = providers.event(for: diagnosis(), now: at(301))
        #expect(first != nil)
        #expect(repeated == nil, "the same failure within five minutes")
        #expect(otherVerdict != nil, "a different verdict is new")
        #expect(otherProvider != nil, "another provider is new")
        #expect(later != nil)

        var browsers = BrowserLiveEvents()
        let one = browsers.changes(peers: [peer("com.google.Chrome")], now: t0)
        let sameBrowser = browsers.changes(peers: [peer("com.google.Chrome"), peer("com.google.Chrome")], now: at(1))
        #expect(one.count == 1)
        #expect(sameBrowser.isEmpty, "a second profile of the same browser")
        let both = browsers.changes(peers: [peer("company.thebrowser.Browser")], now: at(2))
        #expect(both.count == 2)
        #expect(both.map(\.title).contains { $0.hasSuffix(" disconnected") })
    }

    @Test func takeoverAndAlwaysOnCardsFollowTheirState() {
        let offer = TakeoverOffer(id: "o1", brief: TakeoverBrief(task: "Archive the newsletters"), offeredAt: t0)
        #expect(TakeoverLiveEvents.event(for: .idle, detail: nil, dryRun: false, now: t0) == nil)
        #expect(TakeoverLiveEvents.event(for: .offered(offer), detail: nil, dryRun: false, now: t0) == nil, "the consent card asks first")
        let practice = TakeoverLiveEvents.event(for: .driving(offer), detail: nil, dryRun: true, now: t0)
        #expect(practice?.title == "Practising the steps" && practice?.subtitle(now: t0) == "Archive the newsletters")
        let stopping = TakeoverLiveEvents.event(for: .stopping(offer, .userPressedEscape), detail: "x", dryRun: false, now: t0)
        #expect(stopping?.subtitle(now: t0) == "Stopping…" && stopping?.id == TakeoverLiveEvents.eventID)

        var display = AlwaysOnDisplay(state: .starting)
        #expect(AlwaysOnLiveEvents.event(for: display, hint: nil, now: t0) == nil, "starting shows in the pill")
        display.state = .on
        #expect(AlwaysOnLiveEvents.event(for: display, hint: nil, now: t0)?.subtitle(now: t0) == "Just talk")
        for voice: RealtimeVoiceState in [.userSpeaking, .thinking, .speaking] {
            display.voice = voice
            #expect(AlwaysOnLiveEvents.event(for: display, hint: nil, now: t0) == nil, "\(voice) shows in the pill")
        }
        display.voice = .listening
        display.status = "Looking at your screen…"
        #expect(AlwaysOnLiveEvents.event(for: display, hint: nil, now: t0) == nil)
        display.status = nil
        display.reconnecting = true
        #expect(AlwaysOnLiveEvents.event(for: display, hint: nil, now: t0) == nil)
    }

    @Test func theStopPillStopsWhatIsRunning() throws {
        #expect(NotchStopTarget.current(takeoverDriving: true, answering: true, drawing: true, alwaysOn: true) == .takeover)
        #expect(NotchStopTarget.current(takeoverDriving: false, answering: true, drawing: true, alwaysOn: true) == .voice)
        #expect(NotchStopTarget.current(takeoverDriving: false, answering: false, drawing: true, alwaysOn: true) == .drawing)
        #expect(NotchStopTarget.current(takeoverDriving: false, answering: false, drawing: false, alwaysOn: true) == .alwaysOn)
        #expect(NotchStopTarget.current(takeoverDriving: false, answering: false, drawing: false, alwaysOn: false) == nil)

        var presenter = NotchPresenter()
        let nothing = presenter.handle(.stop, now: t0)
        #expect(nothing.isEmpty, "nothing to stop")
        presenter.handle(.activity(true), now: t0)
        presenter.handle(.stoppable(.voice), now: t0)
        #expect(presenter.stopTarget == .voice)
        let stopped = presenter.handle(.stop, now: at(1))
        #expect(stopped == [.stop(.voice)])
        presenter.handle(.stoppable(nil), now: at(2))
        let none = presenter.handle(.stop, now: at(2))
        #expect(none.isEmpty)

        // The cards' Stop buttons go through the same effect, and the card goes away.
        presenter.handle(.activity(false), now: at(3))
        let events = try samples()
        let driving = try #require(events["takeover"])
        presenter.handle(.post(driving), now: at(3))
        let effects = presenter.handle(.perform(eventID: driving.id, actionID: "stop"), now: at(4))
        #expect(effects == [.stop(.takeover), .dismissed(driving.id)])
        let listening = try #require(events["alwaysOn"])
        presenter.handle(.post(listening), now: at(5))
        let alwaysOnStop = presenter.handle(.perform(eventID: listening.id, actionID: "stop"), now: at(6))
        #expect(alwaysOnStop == [.stop(.alwaysOn), .dismissed(listening.id)])
        // The usage card opens Settings → Usage.
        let warned = try #require(events["usageWarned"])
        presenter.handle(.post(warned), now: at(7))
        let usage = presenter.handle(.perform(eventID: warned.id, actionID: "usage"), now: at(8))
        #expect(usage == [.openSettingsPage("usage"), .dismissed(warned.id)])
        #expect(NotchSimulator.describe(.stop(.alwaysOn)) == "stop always-on")
    }

    @Test func explainedProviderFailuresReachTheFeed() async throws {
        let box = FeedBox()
        let token = ProviderUnavailableFeed.subscribe { box.add($0) }
        defer { ProviderUnavailableFeed.unsubscribe(token) }
        ProviderUnavailableFeed.publish(diagnosis())
        #expect(box.count == 1)
        ProviderUnavailableFeed.unsubscribe(token)
        ProviderUnavailableFeed.publish(diagnosis())
        #expect(box.count == 1)
    }
}

extension NotchSimulatorTests {
    @Test func theServicesScriptRunsTheNewSourcesAndStops() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/examples/notch-script-services.json")
        let result = await NotchSimulator.run(try JSONDecoder().decode(NotchScript.self, from: Data(contentsOf: url)))
        func shown(_ prefix: String) -> Bool { result.effects.contains { if case .shown(let id) = $0 { id.hasPrefix(prefix) } else { false } } }
        #expect(shown("browser:") && shown(AlwaysOnLiveEvents.eventID) && shown("job:j7:report:3"))
        #expect(result.effects.contains(.stop(.alwaysOn)))
        #expect(result.effects.contains(.stop(.voice)), "the pill's Stop")
        #expect(shown("usage:day:") && shown("provider:openrouter:network-blocked") && shown(TakeoverLiveEvents.eventID))
        #expect(result.effects.filter { if case .shown(let id) = $0 { id.hasPrefix("provider:") } else { false } }.count == 1,
                "the second failure within five minutes isn't shown again")
        #expect(result.effects.contains(.stop(.takeover)))
        #expect(shown("job:j8:report:1"))
        #expect(result.presenter.pendingEvents.isEmpty, "everything showed and went")
    }
}

private final class FeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [ProviderUnavailableError] = []
    func add(_ error: ProviderUnavailableError) { lock.withLock { errors.append(error) } }
    var count: Int { lock.withLock { errors.count } }
}
