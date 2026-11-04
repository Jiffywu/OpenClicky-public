import Foundation
import Testing
import UserNotifications
import OpenClickyKit
@testable import OpenClicky

// AgentNotifier over a fake notification center: what it posts for finished and waiting jobs, quiet mode, asking for
// permission once, clearing a job's notifications, and routing a clicked one back to its job.
@Suite @MainActor struct AgentNotifierTests {
    @MainActor final class FakeCenter: AgentNotificationCentering {
        var grants = true
        var authorizationRequests = 0
        var added: [UNNotificationRequest] = []
        var deliveredList: [(id: String, thread: String)] = []
        var removed: [[String]] = []

        func requestAuthorization() async -> Bool {
            authorizationRequests += 1
            return grants
        }
        func add(_ request: UNNotificationRequest) async throws {
            added.append(request)
            deliveredList.append((request.identifier, request.content.threadIdentifier))
        }
        func delivered() async -> [(id: String, thread: String)] { deliveredList }
        func removeDelivered(_ ids: [String]) {
            removed.append(ids)
            deliveredList.removeAll { ids.contains($0.id) }
        }
    }

    private func notice(_ id: String, job: String, needsYou: Bool) -> AgentNotice {
        AgentNotice(id: id, jobID: job, title: needsYou ? "Research needs you" : "Research is done", body: "Body \(id)", needsAttention: needsYou)
    }

    @Test func postsFinishedAndWaitingJobsWithTheirJobAndSound() async throws {
        let center = FakeCenter()
        let notifier = AgentNotifier(center: center)
        #expect(notifier.isAvailable)
        await notifier.post(notice("run-1", job: "job-a", needsYou: false))
        await notifier.post(notice("run-2", job: "job-a", needsYou: true))
        #expect(center.authorizationRequests == 1, "permission is asked once")
        #expect(center.added.map(\.identifier) == ["run-1", "run-2"])
        let done = try #require(center.added.first?.content)
        #expect(done.title == "Research is done" && done.body == "Body run-1")
        #expect(done.threadIdentifier == "job-a")
        #expect(done.categoryIdentifier == AgentNotifier.categoryFinished)
        #expect(done.userInfo[AgentNotifier.jobIDKey] as? String == "job-a")
        #expect(done.sound == nil, "a finished job arrives without a sound")
        let waiting = try #require(center.added.last?.content)
        #expect(waiting.categoryIdentifier == AgentNotifier.categoryNeedsYou)
        #expect(waiting.sound != nil)
        #expect(waiting.interruptionLevel == .active)
    }

    @Test func quietTimesPostPassivelyWithoutSound() async throws {
        let center = FakeCenter()
        let notifier = AgentNotifier(center: center)
        notifier.isQuiet = { true }
        await notifier.post(notice("run-1", job: "job-a", needsYou: true))
        let content = try #require(center.added.first?.content)
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
    }

    @Test func refusedPermissionPostsNothingAndIsNotAskedAgain() async {
        let center = FakeCenter()
        center.grants = false
        let notifier = AgentNotifier(center: center)
        await notifier.post(notice("run-1", job: "job-a", needsYou: true))
        await notifier.post(notice("run-2", job: "job-a", needsYou: true))
        #expect(center.added.isEmpty)
        #expect(center.authorizationRequests == 1)
    }

    @Test func clearingAJobRemovesOnlyItsNotifications() async {
        let center = FakeCenter()
        let notifier = AgentNotifier(center: center)
        await notifier.post(notice("run-1", job: "job-a", needsYou: false))
        await notifier.post(notice("run-2", job: "job-b", needsYou: false))
        await notifier.post(notice("run-3", job: "job-a", needsYou: true))
        await notifier.clear(jobID: "job-a")
        #expect(center.removed == [["run-1", "run-3"]])
        #expect(center.deliveredList.map(\.id) == ["run-2"])
        await notifier.clear(jobID: "job-z")
        #expect(center.removed.count == 1, "nothing to remove, no call")
    }

    @Test func aClickedNotificationOpensItsJob() {
        let notifier = AgentNotifier(center: FakeCenter())
        var opened: [String] = []
        notifier.onOpen = { opened.append($0) }
        notifier.opened(userInfo: [AgentNotifier.jobIDKey: "job-a"])
        notifier.opened(userInfo: ["other": "x"])
        #expect(opened == ["job-a"])
    }

    @Test func withoutACenterNothingHappens() async {
        let notifier = AgentNotifier(center: nil)
        #expect(!notifier.isAvailable)
        #expect(await notifier.requestAuthorization() == false)
        await notifier.post(notice("run-1", job: "job-a", needsYou: true))
        await notifier.clear(jobID: "job-a")
    }
}
