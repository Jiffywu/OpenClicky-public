import CoreGraphics
import Foundation
import os
import Testing
@testable import OpenClickyKit

@Suite("Take-over consent")
struct TakeoverConsentTests {
    static let brief = TakeoverBrief(task: "Rename the file to Q3 plan", steps: ["Select the file", "Press Return", "Type the name"])
    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func happyPathOfferApproveDriveFinish() throws {
        var machine = TakeoverConsentMachine()
        let offer = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        #expect(machine.phase == .offered(offer))
        _ = try machine.approve(source: .card, now: Self.t0.addingTimeInterval(5))
        #expect(machine.phase.name == "approved")
        #expect(try machine.beginDrive(now: Self.t0.addingTimeInterval(6)) == offer)
        #expect(machine.phase == .driving(offer))
        let stopped = machine.requestStop(.userPressedEscape)
        #expect(stopped)
        #expect(machine.phase == .stopping(offer, .userPressedEscape))
        machine.finish(.stoppedByUser)
        #expect(machine.phase == .idle)
        #expect(machine.lastOutcome == .stoppedByUser)
    }

    @Test func cannotDriveWithoutTheUsersYes() throws {
        var machine = TakeoverConsentMachine()
        #expect(throws: TakeoverConsentError.noOffer) { try machine.beginDrive(now: Self.t0) }
        _ = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        #expect(throws: TakeoverConsentError.notApproved) { try machine.beginDrive(now: Self.t0) }
        // A hedged or negative reply is not consent.
        for reply in ["no", "not now", "wait, what will you do?", "yes but don't save it", "hmm maybe", "I don't think so", ""] {
            #expect(throws: TakeoverConsentError.notAffirmative, "\(reply)") {
                try machine.approve(source: .userReply(reply), now: Self.t0)
            }
        }
        #expect(machine.phase.name == "offered")
        _ = try machine.approve(source: .userReply("Yes, go ahead."), now: Self.t0)
        #expect(machine.phase.name == "approved")
    }

    @Test func oneApprovalIsGoodForOneDrive() throws {
        var machine = TakeoverConsentMachine()
        _ = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        _ = try machine.approve(source: .card, now: Self.t0)
        _ = try machine.beginDrive(now: Self.t0)
        #expect(throws: TakeoverConsentError.alreadyDriving) { try machine.beginDrive(now: Self.t0) }
        #expect(throws: TakeoverConsentError.alreadyDriving) { try machine.offer(Self.brief, id: "o2", now: Self.t0) }
        machine.finish(.finished)
        #expect(throws: TakeoverConsentError.noOffer) { try machine.beginDrive(now: Self.t0) }
    }

    @Test func offersAndApprovalsExpire() throws {
        var machine = TakeoverConsentMachine(offerLifetime: 60, approvalLifetime: 20)
        _ = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        #expect(throws: TakeoverConsentError.offerExpired) { try machine.approve(source: .card, now: Self.t0.addingTimeInterval(61)) }
        #expect(machine.phase == .idle)

        _ = try machine.offer(Self.brief, id: "o2", now: Self.t0)
        _ = try machine.approve(source: .card, now: Self.t0.addingTimeInterval(10))
        #expect(throws: TakeoverConsentError.approvalExpired) { try machine.beginDrive(now: Self.t0.addingTimeInterval(31)) }
        #expect(machine.phase == .idle)
    }

    @Test func aNewOfferReplacesTheOldAndStaleAnswersAreRefused() throws {
        var machine = TakeoverConsentMachine()
        _ = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        let second = try machine.offer(TakeoverBrief(task: "Something else"), id: "o2", now: Self.t0)
        #expect(throws: TakeoverConsentError.staleOffer) { try machine.approve(offerID: "o1", source: .card, now: Self.t0) }
        let wrong = machine.decline(offerID: "o1")
        #expect(wrong == nil)
        let right = machine.decline(offerID: "o2")
        #expect(right == second)
        #expect(machine.phase == .idle)
        #expect(throws: TakeoverConsentError.emptyTask) { try machine.offer(TakeoverBrief(task: "  "), id: "o3", now: Self.t0) }
    }

    @Test func stopIsOnlyForARunningDrive() throws {
        var machine = TakeoverConsentMachine()
        let idleStop = machine.requestStop(.userTookOver)
        #expect(!idleStop)
        _ = try machine.offer(Self.brief, id: "o1", now: Self.t0)
        let offeredStop = machine.requestStop(.userTookOver)
        #expect(!offeredStop)
        machine.finish(.finished) // nothing to finish
        #expect(machine.phase.name == "offered")
    }

    @Test func replyReading() {
        for yes in ["yes", "Yeah sure", "OK", "go ahead", "Sure, do it.", "yep, take over", "please do", "alright"] {
            #expect(TakeoverReplyConsent.isClearYes(yes), "\(yes)")
        }
        for unclear in ["no", "nope", "don't", "yes? what will it do", "wait", "not yet", "can you explain first",
                        "yes no", "maybe later", "ok but do not send it",
                        "yes yes yes yes yes yes yes yes yes yes yes yes yes"] {
            #expect(!TakeoverReplyConsent.isClearYes(unclear), "\(unclear)")
        }
        #expect(TakeoverReplyConsent.isClearNo("No thanks"))
        #expect(TakeoverReplyConsent.isClearNo("not now"))
        #expect(!TakeoverReplyConsent.isClearNo("sure"))
    }

    /// A reply that merely contains a yes word ("do it", "you can", "fine", "ok") inside some other sentence is not
    /// consent; only a reply made of consent words is.
    @Test func yesWordsInsideOtherSentencesAreNotConsent() {
        for unclear in ["I'll do it myself", "I can do it", "let me do it", "you can see the button on the left",
                        "I'm fine", "ok so where is the save button", "how do I drive this", "sure thing, after lunch",
                        "go ahead and delete everything", "yes, the second one", "fine, whatever you think is best",
                        "okay I see the title field"] {
            #expect(!TakeoverReplyConsent.isClearYes(unclear), "\(unclear)")
        }
        for yes in ["Yes please", "yeah go for it", "sure thing", "Okay, sounds good to me.", "fine by me", "of course",
                    "let's do it", "yes you can", "go ahead and do it", "absolutely, take over", "yes, that would be great",
                    "um yeah sure", "Ok thanks"] {
            #expect(TakeoverReplyConsent.isClearYes(yes), "\(yes)")
        }
    }
}

/// Records what the presenter was asked to show.
final class TakeoverRecordingPresenter: TakeoverPresenting {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    let refuseDrive: Bool

    init(refuseDrive: Bool = false) { self.refuseDrive = refuseDrive }

    var calls: [String] { state.withLock { $0 } }
    private func note(_ text: String) { state.withLock { $0.append(text) } }

    func showConsent(_ offer: TakeoverOffer) async { note("card: \(offer.brief.task)") }
    func hideConsent() async { note("hide card") }
    func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws {
        note("overlay on (dry run \(dryRun))")
        if refuseDrive { throw ScreenCaptureError.permissionDenied }
    }
    func driveEvent(_ event: TakeoverEvent) async {
        if case .finished(let outcome) = event { note("event finished \(outcome.rawValue)") }
    }
    func driveDidEnd(_ report: TakeoverReport) async { note("overlay off: \(report.outcome.rawValue)") }
}

@Suite("Take-over controller and brain tools")
struct TakeoverControllerTests {
    static func controller(_ plans: [DrivePlan], presenter: TakeoverRecordingPresenter = TakeoverRecordingPresenter(),
                           reports: TakeoverReportBox = TakeoverReportBox(), beforeStep: (@Sendable (Int) async -> Void)? = nil) -> TakeoverController {
        TakeoverController(presenter: presenter, makeID: { "offer-1" }, onReport: { await reports.add($0) }) { _ in
            let screen = TakeoverCountingScreen()
            return TakeoverDriveSetup(planner: ScriptedTakeoverPlanner(plans, beforeStep: beforeStep), screen: screen,
                                      actuator: DryRunActuator(),
                                      safety: TakeoverSafetyGuard(probe: StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: screen.observation))),
                                      timing: VirtualTiming())
        }
    }

    static let plans: [DrivePlan] = [
        .acting([("left_click", ["element": "e2"]), ("type", ["text": "Q3 plan"])]),
        DrivePlan(narration: "Renamed it to Q3 plan.", actions: []),
    ]

    @Test func cardApprovalStartsTheDriveAndReportsBack() async throws {
        let presenter = TakeoverRecordingPresenter()
        let reports = TakeoverReportBox()
        let controller = Self.controller(Self.plans, presenter: presenter, reports: reports)
        let tools = TakeoverTools(controller: controller)

        let offered = await tools.run(ToolCall(id: "1", name: TakeoverTools.offerName,
                                               arguments: #"{"task":"Rename the file to Q3 plan","steps":["Click the name","Type"]}"#))
        #expect(offered.status == .needsConfirmation)
        #expect(offered.details["offer_id"] == "offer-1")
        #expect(controller.phase.name == "offered")

        try await controller.approve(source: .card)
        let report = try #require(await controller.waitForDrive())
        #expect(report.outcome == .finished)
        #expect(report.summary == "Renamed it to Q3 plan.")
        #expect(controller.phase == .idle)
        #expect(await reports.all.count == 1)
        #expect(report.appNote.contains("ended: finished"))
        #expect(report.appNote.contains("2 actions performed"))
        #expect(presenter.calls == ["card: Rename the file to Q3 plan", "hide card", "overlay on (dry run true)",
                                    "event finished finished", "overlay off: finished"])
    }

    @Test func startIsRefusedUntilTheUserSaysYes() async throws {
        let controller = Self.controller(Self.plans)
        let tools = TakeoverTools(controller: controller)
        let early = await tools.run(ToolCall(id: "1", name: TakeoverTools.startName, arguments: "{}"))
        #expect(early.status == .refused)
        _ = await tools.run(ToolCall(id: "2", name: TakeoverTools.offerName, arguments: #"{"task":"Rename the file"}"#))
        let unanswered = await tools.run(ToolCall(id: "3", name: TakeoverTools.startName, arguments: "{}"))
        #expect(unanswered.status == .refused)
        #expect(controller.phase.name == "offered")

        // A spoken yes approves; the brain then starts the drive.
        #expect(await controller.userReplied("yes please, go ahead").name == "approved")
        let started = await tools.run(ToolCall(id: "4", name: TakeoverTools.startName, arguments: "{}"))
        #expect(started.status == .ok)
        #expect(started.details["takeover"] == "driving")
        #expect(await controller.waitForDrive()?.outcome == .finished)
    }

    @Test func aSpokenNoDeclinesAndHidesTheCard() async throws {
        let presenter = TakeoverRecordingPresenter()
        let controller = Self.controller(Self.plans, presenter: presenter)
        try await controller.offer(TakeoverBrief(task: "Rename"))
        #expect(await controller.userReplied("hmm, what would you do?").name == "offered")
        #expect(await controller.userReplied("no thanks") == .idle)
        #expect(presenter.calls.last == "hide card")
    }

    @Test func endToolStopsARunningDrive() async throws {
        let gate = TakeoverGate()
        let controller = Self.controller([
            .acting([("left_click", ["coordinate": [100, 100]])]),
            .acting([("left_click", ["coordinate": [200, 200]])]),
            DrivePlan(narration: "done", actions: []),
        ], beforeStep: { step in if step == 1 { await gate.wait() } })
        let tools = TakeoverTools(controller: controller)
        try await controller.offer(TakeoverBrief(task: "Click twice"))
        try await controller.approve(source: .card)
        #expect(controller.phase.name == "driving")
        let ended = await tools.run(ToolCall(id: "9", name: TakeoverTools.endName, arguments: #"{"reason":"user asked"}"#))
        #expect(ended.status == .ok)
        await gate.open()
        let report = try #require(await controller.waitForDrive())
        #expect(report.outcome == .endedByBrain)
        #expect(controller.phase == .idle)
        let nothing = await tools.run(ToolCall(id: "10", name: TakeoverTools.endName, arguments: "{}"))
        #expect(nothing.status == .notFound)
    }

    @Test func emergencyStopTripsTheSwitchAtOnce() async throws {
        let gate = TakeoverGate()
        let controller = Self.controller([.acting([("left_click", ["coordinate": [100, 100]])]), DrivePlan(narration: "x", actions: [])],
                                         beforeStep: { step in if step == 1 { await gate.wait() } })
        try await controller.offer(TakeoverBrief(task: "Click"))
        try await controller.approve(source: .card)
        controller.emergencyStop(.userPressedEscape)
        #expect(controller.stopSwitch.reason == .userPressedEscape)
        await gate.open()
        #expect(await controller.waitForDrive()?.outcome == .stoppedByUser)
    }

    /// A stop that lands while the drive is still starting (the card is being hidden, the setup is being built) must
    /// not be wiped out by the start: the drive ends at once and posts nothing.
    @Test func aStopWhileTheDriveIsStartingIsNotLost() async throws {
        let entered = TakeoverGate()
        let release = TakeoverGate()
        let presenter = TakeoverHoldingPresenter(entered: entered, release: release)
        let actuator = DryRunActuator()
        let controller = TakeoverController(presenter: presenter, makeID: { "offer-1" }) { _ in
            let screen = TakeoverCountingScreen()
            return TakeoverDriveSetup(planner: ScriptedTakeoverPlanner(Self.plans), screen: screen, actuator: actuator,
                                      safety: TakeoverSafetyGuard(probe: StaticTakeoverProbe()), timing: VirtualTiming())
        }
        try await controller.offer(TakeoverBrief(task: "Rename the file"))
        #expect(await controller.userReplied("yes").name == "approved")
        let starting = Task { try await controller.start() }
        await entered.wait()
        #expect(await controller.stop(.userPressedEscape))
        await release.open()
        _ = try await starting.value
        let report = try #require(await controller.waitForDrive())
        #expect(report.outcome == .stoppedByUser)
        #expect(actuator.performed.isEmpty)
        #expect(controller.phase == .idle)
    }

    @Test func aDriveTheUserCannotInterruptNeverStarts() async throws {
        let presenter = TakeoverRecordingPresenter(refuseDrive: true)
        let reports = TakeoverReportBox()
        let controller = Self.controller(Self.plans, presenter: presenter, reports: reports)
        try await controller.offer(TakeoverBrief(task: "Rename"))
        await #expect(throws: ScreenCaptureError.self) { try await controller.approve(source: .card) }
        #expect(controller.phase == .idle)
        #expect(await reports.all.first?.outcome == .failed)
    }

    @Test func offerArgumentsAreValidated() async {
        let tools = TakeoverTools(controller: Self.controller([]))
        let missing = await tools.run(ToolCall(id: "1", name: TakeoverTools.offerName, arguments: "{}"))
        #expect(missing.status == .invalidRequest)
        let badSteps = await tools.run(ToolCall(id: "2", name: TakeoverTools.offerName, arguments: #"{"task":"x","steps":"one"}"#))
        #expect(badSteps.status == .invalidRequest)
        let tooMany = await tools.run(ToolCall(id: "3", name: TakeoverTools.offerName,
                                               arguments: #"{"task":"x","steps":["1","2","3","4","5","6","7","8","9"]}"#))
        #expect(tooMany.status == .invalidRequest)
        #expect(TakeoverTools.specs.map(\.name) == ["offer_screen_takeover", "start_screen_takeover", "end_screen_takeover"])
        #expect(tools.appTools.allSatisfy { !$0.defersUntilNarrationEnds && !$0.needsFollowUpRound })
    }
}

/// Holds `hideConsent` (the controller's first wait when a drive starts) until released.
final class TakeoverHoldingPresenter: TakeoverPresenting {
    let entered: TakeoverGate
    let release: TakeoverGate

    init(entered: TakeoverGate, release: TakeoverGate) {
        self.entered = entered
        self.release = release
    }

    func showConsent(_ offer: TakeoverOffer) async {}
    func hideConsent() async {
        await entered.open()
        await release.wait()
    }
    func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws {}
    func driveEvent(_ event: TakeoverEvent) async {}
    func driveDidEnd(_ report: TakeoverReport) async {}
}

actor TakeoverReportBox {
    private(set) var all: [TakeoverReport] = []
    func add(_ report: TakeoverReport) { all.append(report) }
}

/// Holds a planner step until opened.
actor TakeoverGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
