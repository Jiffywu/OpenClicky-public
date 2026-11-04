import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct AgentResultRetryTests {
    @Test func failedChipCanRetryAndPendingTapCannotDoubleSubmit() async throws {
        let report = AgentJobReport(jobID: "fixture", run: 1, title: "Fixture", outcome: .done,
                                    spoken: "Done.", nextSteps: ["Try again"], startedAt: Date().addingTimeInterval(-1), finishedAt: Date())
        let model = AgentResultCardModel(card: AgentResultCard(report: report))
        var calls = 0
        var finish: CheckedContinuation<Void, any Error>?
        model.sendFollowUp = { _, _ in
            calls += 1
            try await withCheckedThrowingContinuation { finish = $0 }
        }
        model.tap("Try again")
        model.tap("Try again")
        for _ in 0..<200 where finish == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 1)
        finish?.resume(throwing: CocoaError(.fileWriteNoPermission))
        finish = nil
        for _ in 0..<200 where model.status?.hasPrefix("Couldn't") != true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.sent.contains("Try again"))
        model.tap("Try again")
        for _ in 0..<200 where finish == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 2)
        finish?.resume()
        for _ in 0..<200 where !model.sent.contains("Try again") { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.sent.contains("Try again"))
        model.tap("Try again")
        #expect(calls == 2)
    }

    @Test func aHoveredCardKeepsTheTypedReplyAndSentChipsWhenItLooksAgain() async throws {
        let report = AgentJobReport(jobID: "fixture", run: 1, title: "Fixture", outcome: .needsYou, spoken: "Ready.",
                                    nextSteps: ["Draft the email"], startedAt: Date().addingTimeInterval(-1), finishedAt: Date())
        let model = AgentResultCardModel()
        model.show(report)
        model.sendFollowUp = { _, _ in }
        let panel = AgentResultCardPanel(model: model)
        panel.lingers = 0.02
        var looks = 0
        panel.isHovered = { looks += 1; return true }
        model.tap("Draft the email")
        for _ in 0..<200 where !model.sent.contains("Draft the email") { try await Task.sleep(for: .milliseconds(5)) }
        model.reply = "Send it to Sa"
        panel.armHideTimer()
        for _ in 0..<200 where looks < 4 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(looks >= 4)
        #expect(model.reply == "Send it to Sa")
        #expect(model.sent.contains("Draft the email"))
        #expect(model.status?.hasPrefix("Sent to") == true)
        panel.hide()
    }

    @Test func theStepAndTheRoutinesAreEachAnsweredOnTheirOwn() async throws {
        var report = AgentJobReport(jobID: "fixture", run: 1, title: "Expenses", outcome: .needsYou, spoken: "Sign in.",
                                    startedAt: Date().addingTimeInterval(-1), finishedAt: Date())
        report.userStep = AgentUserStep(step: "Sign in to the portal", askedAt: Date())
        report.routineProposals = [AgentRoutineRequest(action: .create, title: "Expense check", task: "Check", schedule: .every(minutes: 60))]
        report.routineRequestID = "openclicky-routine-abc123"
        let model = AgentResultCardModel()
        model.show(report)
        var calls: [(String?, AgentApprovalDecision)] = []
        model.answerJob = { _, requestID, decision in calls.append((requestID, decision)) }

        model.respond(.approve(always: false), to: .step, done: "Thanks. It's carrying on.")
        for _ in 0..<200 where !model.responded.contains(.step) { try await Task.sleep(for: .milliseconds(5)) }
        // "I'm done" carries no request id (the step), and leaves the routine buttons live.
        #expect(calls.count == 1 && calls[0].0 == nil)
        #expect(!model.responded.contains(.routines))

        model.respond(.approve(always: false), to: .routines, done: "Done.")
        for _ in 0..<200 where !model.responded.contains(.routines) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(calls.count == 2 && calls[1].0 == "openclicky-routine-abc123")
        model.respond(.decline, to: .routines, done: "No.")
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls.count == 2)
    }
}
