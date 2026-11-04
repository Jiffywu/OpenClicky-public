import Foundation
import Testing
import OpenClickyKit
@testable import OpenClicky

/// Settings → Developer reads the shared brain the app installs behind `BrainRelay` (#53).
@Suite @MainActor struct DeveloperBrainControlsTests {
    @Test func statsFreshSessionAndDiagnosticsReachTheRuntimeBehindTheRelay() async throws {
        let fixture = try EvidenceSnapshots.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.config.slots[.brain] = nil
        let relay = BrainRelay()
        let loop = VoiceLoopController(model: fixture.model, home: fixture.services, brain: relay, settingsURL: nil)
        fixture.model.voiceLoop = loop
        // A typed question builds the app's real services (the relay is their brain); a scripted runtime answers it.
        loop.ask("Say done")
        loop.orchestrator.services.screen = DeveloperEmptyScreen()
        loop.orchestrator.services.narrator = nil
        loop.orchestrator.services.drawings = nil
        let runtime = BrainRuntime(client: DeveloperScriptedModel(), configuration: BrainRuntimeConfiguration(model: "test-brain", dialect: .anthropicMessages),
                                   assembler: BrainPromptAssembler(drawing2D: "", drawing3D: ""))
        relay.brain = runtime
        #expect(loop.orchestrator.services.brain as? BrainRelay === relay)
        #expect(await eventually { await runtime.stats.turns == 1 })
        #expect(await eventually { !relay.isRunning })
        let firstSession = await runtime.stats.sessionID

        let infra = fixture.services.infra
        #expect(infra.hasBrain)
        infra.loadBrainStats()
        #expect(await eventually { infra.brainStats != nil })
        #expect(infra.brainStats?.sessionID == firstSession)
        #expect(infra.brainStats?.turns == 1)

        infra.startFreshSession()
        #expect(await eventually { infra.message == "Started a fresh brain session." })
        let freshSession = await runtime.stats.sessionID
        #expect(freshSession != firstSession)
        #expect(infra.brainStats?.sessionID == freshSession)
        #expect(infra.brainStats?.turns == 0)
        #expect(!infra.busy)

        let inputs = await infra.diagnosticsInputs(note: "Testing")
        #expect(inputs.brainStats?.sessionID == freshSession)
        #expect(inputs.brainStats?.turns == 0)
    }

    @Test func anUnavailableOrUnbuiltBrainLeavesFreshSessionAndStatsAlone() async throws {
        let fixture = try EvidenceSnapshots.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.config.slots[.brain] = nil
        let relay = BrainRelay()
        let loop = VoiceLoopController(model: fixture.model, home: fixture.services, brain: relay, settingsURL: nil)
        fixture.model.voiceLoop = loop
        let infra = fixture.services.infra

        // Nothing built yet. Fresh Session must not build the engines just to end an empty session.
        let preparations = DeveloperCounter()
        relay.setPrepare { preparations.add() }
        #expect(!infra.hasBrain)
        infra.startFreshSession()
        #expect(infra.message == "The brain isn't running yet; the first turn starts a fresh session anyway.")
        #expect(await infra.diagnosticsInputs(note: "").brainStats == nil)
        #expect(preparations.count == 0)
        relay.setPrepare(nil)

        // Built without a brain model: the relay holds the app's unavailable brain.
        loop.ask("Anyone there?")
        loop.orchestrator.services.screen = DeveloperEmptyScreen()
        loop.orchestrator.services.narrator = nil
        loop.orchestrator.services.drawings = nil
        #expect(await eventually { relay.brain is UnavailableBrain && !loop.orchestrator.isBusy })
        #expect(!infra.hasBrain)
        infra.loadBrainStats()
        infra.startFreshSession()
        #expect(infra.message == "The brain isn't running yet; the first turn starts a fresh session anyway.")
        #expect(infra.brainStats == nil)
        #expect(await infra.diagnosticsInputs(note: "").brainStats == nil)
    }

    private func eventually(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await check()
    }
}

/// Answers every turn with one spoken line.
private final class DeveloperScriptedModel: LanguageModelClient {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("```js\nsay(\"Done.\")\n```"))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }
}

private final class DeveloperCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func add() { lock.withLock { calls += 1 } }
}

@MainActor private final class DeveloperEmptyScreen: TurnScreenLooking {
    func prefetch() {}
    func cancelPrefetch() {}
    func look() async -> TurnScreenLook { TurnScreenLook() }
}
