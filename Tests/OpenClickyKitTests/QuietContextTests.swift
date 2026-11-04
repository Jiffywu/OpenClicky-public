import Foundation
import Testing
@testable import OpenClickyKit

// Quiet contexts: Focus from the Focus database and the menu bar, calls from who records from the mic, the monitor,
// and the gate that holds job reports, routine notices, meeting countdowns and onboarding prompts (docs/audio-robustness.md).

private func focusDirectory(assertions: String?, configurations: String?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-focus-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let assertions { try Data(assertions.utf8).write(to: directory.appendingPathComponent("Assertions.json")) }
    if let configurations { try Data(configurations.utf8).write(to: directory.appendingPathComponent("ModeConfigurations.json")) }
    return directory
}

private let noAssertions = #"{"data":[{"storeAssertionRecords":[]}]}"#
private let workSchedule = #"""
{"data":[{"modeConfigurations":{
  "com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb","modeIdentifier":"com.apple.donotdisturb.mode.default"},"triggers":{"triggers":[]}},
  "com.apple.focus.work":{"mode":{"name":"Work","modeIdentifier":"com.apple.focus.work"},"triggers":{"triggers":[
    {"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":2,"timePeriodStartTimeHour":9,"timePeriodStartTimeMinute":0,
     "timePeriodEndTimeHour":17,"timePeriodEndTimeMinute":30,"timePeriodWeekdays":62}]}},
  "com.apple.sleep.sleep-mode":{"mode":{"name":"Sleep","modeIdentifier":"com.apple.sleep.sleep-mode"},"triggers":{"triggers":[
    {"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":2,"timePeriodStartTimeHour":23,"timePeriodStartTimeMinute":0,
     "timePeriodEndTimeHour":7,"timePeriodEndTimeMinute":0,"timePeriodWeekdays":127},
    {"class":"DNDModeConfigurationScheduleTrigger","enabledSetting":1,"timePeriodStartTimeHour":12,"timePeriodStartTimeMinute":0,
     "timePeriodEndTimeHour":13,"timePeriodEndTimeMinute":0,"timePeriodWeekdays":127}]}}
}}]}
"""#

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 2026-11-02 is a Monday.
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Suite struct FocusDetectionTests {
    @Test func aFocusTurnedOnByHandIsManual() throws {
        let assertions = #"""
        {"data":[{"storeAssertionRecords":[
          {"assertionStartDateTimestamp":100,"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}},
          {"assertionStartDateTimestamp":200,"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}]}
        """#
        let directory = try focusDirectory(assertions: assertions, configurations: workSchedule)
        let reading = FocusDatabaseReader(directory: directory, calendar: utc).read(now: at(2, 20))
        #expect(reading.reason == .manuallyEnabled(mode: "Do Not Disturb"))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func schedulesFollowTheClockTheWeekdaysAndMidnight() throws {
        let directory = try focusDirectory(assertions: noAssertions, configurations: workSchedule)
        let reader = FocusDatabaseReader(directory: directory, calendar: utc)
        // A configured schedule can be overridden or skipped. Only live assertions establish active Focus.
        #expect(reader.read(now: at(2, 10)).reason == nil)
        let modes = FocusDatabaseReader.modes(from: Data(workSchedule.utf8))
        let work = try #require(modes["com.apple.focus.work"]?.schedules.first)
        #expect(work.covers(at(2, 10), calendar: utc))
        #expect(!work.covers(at(2, 17, 30), calendar: utc))
        #expect(!work.covers(at(1, 10), calendar: utc))
        let sleep = try #require(modes["com.apple.sleep.sleep-mode"]?.schedules.first)
        #expect(sleep.covers(at(2, 23, 30), calendar: utc))
        #expect(sleep.covers(at(3, 6, 59), calendar: utc))
        #expect(!sleep.covers(at(7, 12, 30), calendar: utc))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func anUnreadableDatabaseSaysWhyAndFindsNothing() {
        let reading = FocusDatabaseReader(directory: URL(fileURLWithPath: "/nonexistent/openclicky/DB")).read(now: Date())
        #expect(reading.reason == nil)
        #expect(reading.notes.first?.contains("not readable") == true)
    }

    @Test func theMenuBarIndicatorAndTheCombinedReading() {
        #expect(ControlCenterFocusIndicator(read: { true }).read(now: Date()).reason == nil)
        #expect(ControlCenterFocusIndicator(read: { false }).read(now: Date()).reason == nil)
        #expect(ControlCenterFocusIndicator(read: { nil }).read(now: Date()).reason == nil)
        let combined = SystemFocusStatus(sources: [FixedFocusStatus(nil), ControlCenterFocusIndicator(read: { true })]).read(now: Date())
        #expect(combined.reason == nil)
        #expect(combined.notes.count == 2)
    }

    @Test func theRealSourcesReadWithoutPermissionPrompts() {
        // Whatever this Mac's state, reading must not throw or prompt; an unreadable database is a note.
        let reading = SystemFocusStatus().read(now: Date())
        #expect(!reading.notes.isEmpty)
    }
}

@Suite struct CallPresenceTests {
    private func detector(_ users: [AudioInputUser]) -> CallPresenceDetector {
        CallPresenceDetector(usage: FixedInputUsage(users), ownBundleIDs: ["app.openclicky"], ownPIDs: [42])
    }

    @Test func callAppsAndBrowsersRecordingAreCalls() {
        #expect(detector([AudioInputUser(bundleID: "us.zoom.xos", name: "zoom.us")]).detect() == .onCall(app: "Zoom"))
        #expect(detector([AudioInputUser(bundleID: "com.microsoft.teams2")]).detect() == .onCall(app: "Microsoft Teams"))
        #expect(detector([AudioInputUser(bundleID: "com.google.Chrome.helper", isRegularApp: false)]).detect() == .onCall(app: "Chrome"))
        #expect(detector([AudioInputUser(bundleID: "com.apple.FaceTime")]).detect() == .onCall(app: "FaceTime"))
    }

    @Test func otherAppsRecordingMakeTheMicBusy() {
        #expect(detector([AudioInputUser(bundleID: "com.apple.VoiceMemos", name: "Voice Memos")]).detect() == .microphoneBusy(app: "Voice Memos"))
        #expect(detector([AudioInputUser(bundleID: nil, isRegularApp: false)]).detect() == .microphoneBusy(app: nil))
    }

    @Test func ourOwnCaptureAndSystemListenersDontCount() {
        #expect(detector([]).detect() == nil)
        #expect(detector([AudioInputUser(pid: 42, bundleID: "something.else")]).detect() == nil)
        #expect(detector([AudioInputUser(bundleID: "app.openclicky")]).detect() == nil)
        #expect(detector([AudioInputUser(bundleID: "com.apple.corespeechd", isRegularApp: false)]).detect() == nil)
        #expect(detector([AudioInputUser(bundleID: "com.example.helperd", isRegularApp: false)]).detect() == nil)
    }

    @Test func theRealProcessListReadsWithoutPermission() {
        _ = CoreAudioInputUsage().inputUsers()
    }
}

@MainActor
@Suite struct QuietMonitorTests {
    @Test func alwaysOnStillDetectsExternalCallsStartingChangingAndEnding() {
        let own = AudioInputUser(pid: 42, bundleID: "app.openclicky")
        let usage = FixedInputUsage([own])
        let monitor = QuietContextMonitor(sources: .init(focus: FixedFocusStatus(),
            calls: CallPresenceDetector(usage: usage, ownBundleIDs: ["app.openclicky"], ownPIDs: [42]),
            ownCaptureActive: { true }))
        #expect(monitor.refresh() == .none)
        usage.set([own, AudioInputUser(pid: 43, bundleID: "us.zoom.xos")])
        #expect(monitor.refresh().reasons == [.onCall(app: "Zoom")])
        var gate = QuietGate()
        _ = gate.update(monitor.context, now: Date())
        let report = ProactiveItem(id: "job", kind: .jobReport, title: "Finished", createdAt: Date())
        #expect(gate.offer(report, now: Date()) == .hold)
        usage.set([own, AudioInputUser(pid: 44, bundleID: "com.google.Chrome.helper", isRegularApp: false)])
        #expect(monitor.refresh().reasons == [.onCall(app: "Chrome")])
        _ = gate.update(monitor.context, now: Date())
        usage.set([own])
        #expect(monitor.refresh() == .none)
        #expect(gate.update(monitor.context, now: Date()).release.map(\.id) == ["job"])
    }

    @Test func changesAreReportedAndUnattributedOwnCaptureKeepsTheLastCallAnswer() {
        let usage = FixedInputUsage()
        let focus = FixedFocusStatus()
        let ownCapture = LockedBox(false)
        let monitor = QuietContextMonitor(sources: .init(focus: focus, calls: CallPresenceDetector(usage: usage, ownBundleIDs: [], ownPIDs: []),
                                                         ownCaptureActive: { ownCapture.value }))
        var changes: [QuietContext] = []
        monitor.onChange = { changes.append($0) }
        #expect(monitor.refresh() == .none)
        usage.set([AudioInputUser(bundleID: "us.zoom.xos")])
        #expect(monitor.refresh().reasons == [.onCall(app: "Zoom")])
        focus.set(.manuallyEnabled(mode: "Work"))
        #expect(monitor.refresh().reasons == [.onCall(app: "Zoom"), .focus(.manuallyEnabled(mode: "Work"))])
        // Unattributed input may be our own mic, so it keeps the last call reading.
        ownCapture.mutate { $0 = true }
        usage.set([AudioInputUser(bundleID: nil, isRegularApp: false)])
        #expect(monitor.refresh().onCall)
        ownCapture.mutate { $0 = false }
        usage.set([])
        focus.set(nil)
        #expect(monitor.refresh() == .none)
        #expect(changes.count == 3)
        #expect(changes.last?.summary == "not quiet")
    }

    /// Review fix: with holding turned off in Settings, a call or Focus no longer makes OpenClicky quiet (the job
    /// notifications keep their sound), though the context is still read.
    @Test func turningHoldingOffMeansNotQuietEvenDuringACall() {
        let usage = FixedInputUsage([AudioInputUser(bundleID: "us.zoom.xos")])
        let monitor = QuietContextMonitor(sources: .init(focus: FixedFocusStatus(), calls: CallPresenceDetector(usage: usage, ownBundleIDs: [], ownPIDs: [])))
        let hold = QuietHold(monitor: monitor)
        hold.start()
        defer { hold.stop() }
        #expect(hold.context.onCall)
        #expect(hold.isQuiet)
        hold.policy.enabled = false
        #expect(hold.context.onCall)
        #expect(!hold.isQuiet)
        hold.policy.enabled = true
        usage.set([])
        hold.refresh()
        #expect(!hold.isQuiet)
    }
}

/// The gate behind a reference, so its mutating calls can sit inside `#expect`.
final class GateRef {
    var gate: QuietGate
    init(_ gate: QuietGate = QuietGate()) { self.gate = gate }
    func offer(_ item: ProactiveItem, now: Date) -> QuietGate.Decision { gate.offer(item, now: now) }
    @discardableResult
    func update(_ context: QuietContext, now: Date) -> (release: [ProactiveItem], dropped: [ProactiveItem]) { gate.update(context, now: now) }
    var held: [ProactiveItem] { gate.held }
    var heldSummary: String? { gate.heldSummary }
}

@Suite struct QuietGateTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let onCall = QuietContext(reasons: [.onCall(app: "Zoom")])
    private let inFocus = QuietContext(reasons: [.focus(.manuallyEnabled(mode: "Work"))])

    private func item(_ kind: ProactiveKind, _ title: String, at offset: TimeInterval = 0, expires: TimeInterval? = nil) -> ProactiveItem {
        ProactiveItem(id: title, kind: kind, title: title, payload: "note:\(title)", createdAt: t0.addingTimeInterval(offset),
                      expiresAt: expires.map { t0.addingTimeInterval($0) })
    }

    @Test func notQuietDeliversEverything() {
        let gate = GateRef()
        for kind in ProactiveKind.allCases { #expect(gate.offer(item(kind, kind.rawValue), now: t0) == .deliver) }
        #expect(gate.held.isEmpty)
    }

    @Test func aCallHoldsReportsAndPromptsDropsCountdownsAndReleasesInOrderWhenItEnds() {
        let gate = GateRef()
        _ = gate.update(onCall, now: t0)
        #expect(gate.offer(item(.jobReport, "export"), now: t0) == .hold)
        #expect(gate.offer(item(.routineNotice, "inbox digest", at: 5), now: t0) == .hold)
        #expect(gate.offer(item(.onboardingPrompt, "finish setup", at: 6), now: t0) == .hold)
        #expect(gate.offer(item(.meetingCountdown, "standup", expires: 600), now: t0) == .drop("dropped during a call"))
        #expect(gate.heldSummary == "3 things are waiting until your call ends.")
        let (release, dropped) = gate.update(.none, now: t0.addingTimeInterval(900))
        #expect(release.map(\.title) == ["export", "inbox digest", "finish setup"])
        #expect(dropped.isEmpty)
        #expect(gate.held.isEmpty && gate.heldSummary == nil)
    }

    @Test func aFocusHoldsCountdownsUntilTheyExpire() {
        let gate = GateRef()
        _ = gate.update(inFocus, now: t0)
        #expect(gate.offer(item(.meetingCountdown, "standup", expires: 300), now: t0) == .hold)
        #expect(gate.offer(item(.meetingCountdown, "review", expires: 3600), now: t0) == .hold)
        #expect(gate.offer(item(.jobReport, "already stale", expires: -1), now: t0) == .drop("expired"))
        let (release, dropped) = gate.update(.none, now: t0.addingTimeInterval(600))
        #expect(release.map(\.title) == ["review"])
        #expect(dropped.map(\.title) == ["standup"])
    }

    @Test func aCallEndingInsideAFocusKeepsWhatTheFocusStillHolds() {
        let gate = GateRef(QuietGate(policy: .init(holdDuringFocus: [.jobReport])))
        _ = gate.update(QuietContext(reasons: onCall.reasons + inFocus.reasons), now: t0)
        #expect(gate.offer(item(.jobReport, "report"), now: t0) == .hold)
        #expect(gate.offer(item(.onboardingPrompt, "setup"), now: t0) == .hold)
        let (release, _) = gate.update(inFocus, now: t0.addingTimeInterval(60))
        #expect(release.map(\.title) == ["setup"])
        #expect(gate.held.map(\.title) == ["report"])
        #expect(gate.heldSummary == "1 thing is waiting until your Focus ends.")
    }

    @Test func itemsHeldTooLongAreDroppedAndTheSwitchTurnsHoldingOff() {
        let gate = GateRef(QuietGate(policy: .init(maxHold: 3600)))
        _ = gate.update(onCall, now: t0)
        _ = gate.offer(item(.jobReport, "old"), now: t0)
        _ = gate.offer(item(.jobReport, "new", at: 5000), now: t0.addingTimeInterval(5000))
        let (release, dropped) = gate.update(.none, now: t0.addingTimeInterval(6000))
        #expect(release.map(\.title) == ["new"])
        #expect(dropped.map(\.title) == ["old"])

        let off = GateRef(QuietGate(policy: .init(enabled: false)))
        _ = off.update(onCall, now: t0)
        #expect(off.offer(item(.jobReport, "x"), now: t0) == .deliver)
    }

    @Test func reHoldingTheSameItemReplacesIt() {
        let gate = GateRef()
        _ = gate.update(onCall, now: t0)
        _ = gate.offer(item(.jobReport, "same"), now: t0)
        _ = gate.offer(item(.jobReport, "same", at: 10), now: t0)
        #expect(gate.held.count == 1)
    }
}
