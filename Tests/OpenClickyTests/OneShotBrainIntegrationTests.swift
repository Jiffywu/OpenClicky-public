import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

@Suite @MainActor struct OneShotBrainIntegrationTests {
    @Test func interruptionKeepsTheInstalledBrainUntilCleanupAndOutcomeAreSaved() async throws {
        let fixture = try EvidenceSnapshots.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.config.slots[.brain] = nil
        let relay = BrainRelay()
        let loop = VoiceLoopController(model: fixture.model, home: fixture.services, brain: relay, settingsURL: nil)
        // Build the real app services without a provider, then install a controlled runtime before the turn starts.
        loop.ask("Hold this answer")
        loop.orchestrator.services.screen = OneShotEmptyScreen()
        loop.orchestrator.services.narrator = nil
        loop.orchestrator.services.drawings = nil
        let first = OneShotCleanupBrain()
        defer { first.finishCleanup() }
        relay.brain = first
        guard await eventually({ first.started }) else {
            Issue.record("The app's one-shot turn did not reach its installed shared brain.")
            loop.stopTurn()
            return
        }
        loop.stopTurn()
        #expect(!loop.orchestrator.isBusy)
        let replacement = OneShotCleanupBrain()
        #expect(!relay.replaceIfIdle { replacement })
        #expect(await eventually { first.cleaning })
        #expect(await eventually { first.notes.contains { $0.contains("The user pressed Escape") } })
        #expect(!relay.replaceIfIdle { replacement })
        first.finishCleanup()
        #expect(await eventually { !relay.isRunning })
        #expect(relay.replaceIfIdle { replacement })
        #expect(first.notes.contains { $0.contains("The user pressed Escape") })
    }

    private func eventually(_ check: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return check()
    }
}

private final class OneShotCleanupBrain: BrainTurnRunning, BrainTurnSettling, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var saved: [String] = []
    private var cleanup: CheckedContinuation<Void, Never>?
    private var released = false
    var started: Bool { lock.withLock { began } }
    var cleaning: Bool { lock.withLock { cleanup != nil } }
    var notes: [String] { lock.withLock { saved } }
    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        lock.withLock { began = true }
        return AsyncThrowingStream { _ in }
    }
    func prewarm() async {}
    func recordOutcome(_ note: String) async { lock.withLock { saved.append(note) } }
    func endSession() async {}
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released { continuation.resume() } else { cleanup = continuation }
            }
        }
    }
    func finishCleanup() {
        let waiting = lock.withLock {
            released = true
            let waiting = cleanup
            cleanup = nil
            return waiting
        }
        waiting?.resume()
    }
}

@MainActor private final class OneShotEmptyScreen: TurnScreenLooking {
    func prefetch() {}
    func cancelPrefetch() {}
    func look() async -> TurnScreenLook { TurnScreenLook() }
}
