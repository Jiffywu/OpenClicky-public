import Foundation
import Testing
@testable import OpenClickyKit

@Suite struct BrainRelayReservationTests {
    @Test func aSelectedRuntimeCannotBeReplacedUntilItsTurnEnds() async throws {
        let first = RelayHoldingBrain(), second = RelayHoldingBrain()
        let relay = BrainRelay(first)
        let turn = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "hold"))) }
        #expect(await waitUntil { first.started })
        relay.brain = second
        #expect(relay.brain === first)
        #expect(relay.isRunning)
        turn.cancel()
        _ = await turn.value
        #expect(await waitUntil { !relay.isRunning })
        relay.brain = second
        #expect(relay.brain === second)
    }

    @Test func cancellationKeepsTheReservationUntilRuntimeCleanupFinishes() async throws {
        let brain = RelayCleanupBrain()
        let relay = BrainRelay(brain)
        let turn = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "cancel"))) }
        #expect(await waitUntil { brain.started })
        turn.cancel()
        _ = await turn.value
        #expect(await waitUntil { brain.cleaning })
        #expect(relay.isRunning)
        #expect(!relay.replaceIfIdle { RelayHoldingBrain() })
        brain.finishCleanup()
        #expect(await waitUntil { !relay.isRunning })
        #expect(relay.replaceIfIdle { RelayHoldingBrain() })
    }

    @Test func firstPreparationIsSharedAndCancellingOneWaiterDoesNotCancelAnother() async throws {
        let relay = BrainRelay()
        let brain = RelayHoldingBrain()
        let preparation = RelayPreparationGate()
        relay.setPrepare {
            await preparation.wait()
            // This is the same idle check the app uses before it builds its first runtime.
            if !relay.isRunning { relay.brain = brain }
        }
        let cancelled = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "cancel"))) }
        let survivor = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "survive"))) }
        #expect(await waitUntil { preparation.calls > 0 })
        cancelled.cancel()
        await preparation.release()
        _ = await cancelled.value
        #expect(await waitUntil { brain.started })
        #expect(preparation.calls == 1)
        #expect(brain.inputs == ["survive"])
        survivor.cancel()
        _ = await survivor.value
        #expect(await waitUntil { !relay.isRunning })
    }

    @Test func onlyTurnsAndPrewarmRunPreparationOnceARuntimeExists() async throws {
        let relay = BrainRelay()
        let brain = RelayHoldingBrain()
        let preparations = RelayCounter()
        relay.setPrepare {
            preparations.increment()
            if !relay.isRunning, relay.brain == nil { relay.brain = brain }
        }
        // The first bookkeeping call has no runtime yet, so it builds one.
        await relay.recordOutcome("first")
        #expect(preparations.value == 1)
        #expect(relay.brain === brain)
        await relay.recordOutcome("again")
        _ = await relay.currentSessionID()
        await relay.seedConversation([])
        await relay.endSession()
        #expect(preparations.value == 1)
        await relay.prewarm()
        #expect(preparations.value == 2)
        let turn = Task { try? await BrainFixtures.collect(relay.run(TurnInput(words: "go"))) }
        #expect(await waitUntil { brain.started })
        #expect(preparations.value == 3)
        turn.cancel()
        _ = await turn.value
    }
}

private final class RelayCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class RelayHoldingBrain: BrainTurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var words: [String] = []
    var started: Bool { lock.withLock { !words.isEmpty } }
    var inputs: [String] { lock.withLock { words } }
    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        lock.withLock { words.append(input.words) }
        return AsyncThrowingStream { _ in }
    }
    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
}

private final class RelayPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                if opened { continuation.resume() } else { continuations.append(continuation) }
            }
        }
    }
    func release() async {
        lock.withLock {
            opened = true
            continuations.forEach { $0.resume() }
            continuations = []
        }
    }
}

private final class RelayCleanupBrain: BrainTurnRunning, BrainTurnSettling, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var cleanup: CheckedContinuation<Void, Never>?
    var started: Bool { lock.withLock { began } }
    var cleaning: Bool { lock.withLock { cleanup != nil } }
    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        lock.withLock { began = true }
        return AsyncThrowingStream { _ in }
    }
    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in lock.withLock { cleanup = continuation } }
    }
    func finishCleanup() { lock.withLock { cleanup?.resume(); cleanup = nil } }
}
