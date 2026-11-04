import Foundation
import Testing
@testable import OpenClickyKit

// Echo cancellation for the voice loop: the planner, the deaf check, the per-topology verdict cache, the router that
// moves the mic and the voice onto one voice-processing engine, always-on on speakers, and the tuned echo-gate
// presets (docs/audio-robustness.md). No microphone is opened: hosts are offline and probes are scripted.

private let laptop = AudioTopology(inputUID: "BuiltInMic", inputTransport: "built-in", outputUID: "BuiltInSpeakers", outputTransport: "built-in")
private let usb = AudioTopology(inputUID: "USBMic", outputUID: "BuiltInSpeakers")

private func tempFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-echo-\(UUID().uuidString)").appendingPathComponent(name)
}

@Suite struct EchoPlannerTests {
    @Test func headphonesNeedNothingAndTheSettingCanTurnItOff() {
        let planner = EchoCancellationPlanner()
        #expect(planner.plan(route: .headphones, mode: .automatic, cached: nil) == .notNeeded)
        #expect(planner.plan(route: .speakers, mode: .off, cached: nil) == .disabled)
        #expect(planner.plan(route: .unknown, mode: .automatic, cached: nil) == .probe)
    }

    @Test func cachedVerdictsDecideAndProbesHaveABudget() {
        var planner = EchoCancellationPlanner(probeBudget: 2)
        #expect(planner.plan(route: .speakers, mode: .automatic, cached: .promoted(at: Date())) == .useCached)
        #expect(planner.plan(route: .speakers, mode: .automatic, cached: .zombie(reason: "deaf: no audio", at: Date()))
                == .cachedZombie("deaf: no audio"))
        planner.noteProbe()
        planner.noteProbe()
        #expect(planner.plan(route: .speakers, mode: .automatic, cached: nil) == .budgetExhausted)
    }

    @Test func theDeafCheckTellsNoAudioFromZerosFromWorking() {
        #expect(EchoProbeResult.check(chunks: 0, audibleChunks: 0) == .deaf(.noAudio))
        #expect(EchoProbeResult.check(chunks: 20, audibleChunks: 0) == .deaf(.allZeros))
        #expect(EchoProbeResult.check(chunks: 20, audibleChunks: 4) == .working(chunks: 20, audible: 4))
        #expect(EchoProbeResult.deaf(.allZeros).verdict(at: Date()).isPromoted == false)
        #expect(EchoProbeResult.working(chunks: 1, audible: 1).verdict(at: Date()).isPromoted)
    }
}

@Suite struct EchoVerdictCacheTests {
    @Test func verdictsArePerTopologyAndSurviveARelaunch() throws {
        let url = tempFile("echo-cancellation.json")
        var cache = EchoVerdictCache(url: url)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        cache.record(.promoted(at: when), for: laptop)
        cache.record(.zombie(reason: "deaf: no audio", at: when), for: usb)
        let loaded = EchoVerdictCache.load(from: url)
        #expect(loaded.verdict(for: laptop, now: when) == .promoted(at: when))
        #expect(loaded.verdict(for: usb, now: when) == .zombie(reason: "deaf: no audio", at: when))
        #expect(laptop.key == "in=BuiltInMic|out=BuiltInSpeakers")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func aZombieIsProbedAgainAfterAWhile() {
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = EchoVerdictCache(verdicts: [usb.key: .zombie(reason: "deaf", at: then)], zombieRetry: 3600)
        #expect(cache.verdict(for: usb, now: then.addingTimeInterval(60)) != nil)
        #expect(cache.verdict(for: usb, now: then.addingTimeInterval(7200)) == nil)
    }

    @Test func aMissingOrBrokenFileIsAnEmptyCache() throws {
        let url = tempFile("broken.json")
        #expect(EchoVerdictCache.load(from: url).verdicts.isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(EchoVerdictCache.load(from: url).verdicts.isEmpty)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private func router(_ probe: ScriptedEchoProbe, topology: AudioTopology = laptop, cache: EchoVerdictCache = EchoVerdictCache(),
                    clock: ManualSeconds = ManualSeconds()) -> DuplexAudioRouter {
    // Offline hosts: nothing touches hardware.
    DuplexAudioRouter(cache: cache, prober: probe, topology: { _ in topology },
                      makeHost: { AudioEngineHost(offlineSampleRate: 24_000) }, now: clock.function)
}

@Suite struct DuplexAudioRouterTests {
    @Test func aWorkingProbePromotesAndTheNextSessionUsesTheCache() async throws {
        let probe = ScriptedEchoProbe([.working(chunks: 20, audible: 18)])
        let router = router(probe)
        #expect(router.captureHost == nil && router.player == nil)
        let first = await router.prepare(route: .speakers, setting: .automatic)
        #expect(first.mode == .echoCancelled && first.plan == .probe)
        #expect(router.captureHost != nil && router.player != nil)
        #expect(router.verdicts.verdict(for: laptop)?.isPromoted == true)
        let host = try #require(router.captureHost)
        router.release()
        #expect(router.currentMode == .plain && router.captureHost == nil)
        let second = await router.prepare(route: .speakers, setting: .automatic)
        #expect(second.plan == .useCached && second.mode == .echoCancelled)
        // The same shared engine (and player) comes back.
        #expect(router.captureHost === host)
        #expect(probe.probes == 1)
    }

    @Test func aDeafProbeIsCachedAsAZombieAndNotProbedAgain() async {
        let probe = ScriptedEchoProbe([.deaf(.allZeros)])
        let router = router(probe)
        let decision = await router.prepare(route: .speakers, setting: .automatic)
        #expect(decision.mode == .plain && decision.probe == .deaf(.allZeros))
        #expect(router.captureHost == nil)
        let again = await router.prepare(route: .speakers, setting: .automatic)
        guard case .cachedZombie(let reason) = again.plan else { Issue.record("expected a cached zombie, got \(again.plan)"); return }
        #expect(reason.contains("digital silence"))
        #expect(probe.probes == 1)
    }

    @Test func aProbeThatCouldNotRunCachesNothing() async {
        let probe = ScriptedEchoProbe([.unavailable("microphone access isn't granted"), .working(chunks: 4, audible: 4)])
        let router = router(probe)
        #expect(await router.prepare(route: .speakers, setting: .automatic).mode == .plain)
        #expect(router.verdicts.verdict(for: laptop) == nil)
        // Once access is granted the next session probes again.
        #expect(await router.prepare(route: .speakers, setting: .automatic).mode == .echoCancelled)
        #expect(probe.probes == 2)
    }

    @Test func headphonesAndTheOffSettingStayPlain() async {
        let probe = ScriptedEchoProbe([.working(chunks: 1, audible: 1)])
        let router = router(probe)
        #expect(await router.prepare(route: .headphones, setting: .automatic).mode == .plain)
        #expect(await router.prepare(route: .speakers, setting: .off).mode == .plain)
        #expect(probe.probes == 0)
    }

    @Test func aMicRebuildingRightAfterPromotionIsDeafAndDemotes() async {
        let clock = ManualSeconds()
        let router = router(ScriptedEchoProbe([.working(chunks: 5, audible: 5)]), clock: clock)
        _ = await router.prepare(route: .speakers, setting: .automatic)
        #expect(router.captureEvent(.running(device: "mic")) == false)
        clock.advance(1)
        #expect(router.captureEvent(.rebuilding(.noAudio)))
        #expect(router.currentMode == .plain)
        guard case .zombie(let reason, _)? = router.verdicts.verdict(for: laptop) else { Issue.record("expected a zombie"); return }
        #expect(reason == "deaf at start: no audio")
    }

    @Test func aLateRebuildIsLeftToTheHealthLadderButADeadMicDemotes() async {
        let clock = ManualSeconds()
        let router = router(ScriptedEchoProbe([.working(chunks: 5, audible: 5)]), clock: clock)
        _ = await router.prepare(route: .speakers, setting: .automatic)
        clock.advance(30)
        #expect(router.captureEvent(.rebuilding(.allZeros)) == false)
        #expect(router.currentMode == .echoCancelled)
        #expect(router.captureEvent(.irrecoverable(.allZeros)))
        #expect(router.currentMode == .plain)
        // Events after demotion change nothing.
        #expect(router.captureEvent(.failed("gone")) == false)
    }

    @Test func forgettingAVerdictProbesAgain() async {
        let probe = ScriptedEchoProbe([.deaf(.noAudio), .working(chunks: 3, audible: 3)])
        let router = router(probe)
        _ = await router.prepare(route: .speakers, setting: .automatic)
        router.forgetVerdict()
        #expect(await router.prepare(route: .speakers, setting: .automatic).mode == .echoCancelled)
        #expect(probe.probes == 2)
    }
}

@Suite struct AlwaysOnEchoCancellationTests {
    typealias Harness = AlwaysOnVoiceTests.Harness

    private func environment(_ harness: Harness, plan: AlwaysOnRoutePlan, requireHeadphones: Bool = true,
                             prepared: LockedBox<Int> = LockedBox(0)) -> AlwaysOnVoiceController.Environment {
        var environment = harness.environment(requireHeadphones: requireHeadphones)
        environment.prepareRoute = { _ in
            prepared.mutate { $0 += 1 }
            return plan
        }
        environment.echoSettings = { route, cancelled in .tuned(for: route, echoCancelled: cancelled) }
        return environment
    }

    @Test func withEchoCancellationAlwaysOnRunsOnSpeakersWithTheCancelledGate() async throws {
        let harness = Harness()
        harness.route = .speakers
        let prepared = LockedBox(0)
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .echoCancelled, prepared: prepared))
        #expect(await controller.start() == .on)
        #expect(prepared.value == 1)
        #expect(await controller.echoCancelled)
        let conversation = try #require(await controller.currentConversation)
        #expect(await conversation.echoSettings == .speakersEchoCancelled)
        #expect(await conversation.outputRoute == .speakers)
        await controller.stop()
    }

    @Test func withoutItSpeakersAreStillRefusedAndHeadphonesNeverAsk() async {
        let harness = Harness()
        harness.route = .speakers
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .plain))
        guard case .refused(let why) = await controller.start() else { Issue.record("expected a refusal"); return }
        #expect(why.contains("headphones"))

        let refusing = AlwaysOnVoiceController(environment: environment(harness, plan: .refuse("Echo cancellation is still starting.")))
        #expect(await refusing.start() == .refused("Echo cancellation is still starting."))

        harness.route = .headphones
        let prepared = LockedBox(0)
        let quiet = AlwaysOnVoiceController(environment: environment(harness, plan: .echoCancelled, prepared: prepared))
        #expect(await quiet.start() == .on)
        #expect(prepared.value == 0)
        #expect(await quiet.echoCancelled == false)
        await quiet.stop()
    }

    @Test func speakersAllowedWithoutCancellationGetTheStricterGate() async throws {
        let harness = Harness()
        harness.route = .speakers
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .plain, requireHeadphones: false))
        #expect(await controller.start() == .on)
        let conversation = try #require(await controller.currentConversation)
        #expect(await conversation.echoSettings == .speakersRaw)
        await controller.stop()
    }

    @Test func turningItOffWhileEchoCancellationIsBeingSetUpGivesTheEnginesBack() async {
        let harness = Harness()
        harness.route = .speakers
        let gate = LockedBox(false)
        let released = LockedBox(0)
        var environment = harness.environment()
        environment.prepareRoute = { _ in
            while !gate.value { try? await Task.sleep(for: .milliseconds(5)) }
            return .echoCancelled
        }
        environment.releaseRoute = { released.mutate { $0 += 1 } }
        let controller = AlwaysOnVoiceController(environment: environment)
        let starting = Task { await controller.start() }
        #expect(await realtimeEventually { await controller.state == .starting })
        await controller.stop()
        gate.mutate { $0 = true }
        #expect(await starting.value == .off)
        #expect(released.value == 1)
        #expect(harness.all.isEmpty)
    }

    @Test func losingEchoCancellationOnSpeakersStopsAlwaysOn() async {
        let harness = Harness()
        harness.route = .speakers
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .echoCancelled))
        #expect(await controller.start() == .on)
        await controller.echoCancellationLost("deaf at start: no audio")
        guard case .refused(let why) = await controller.state else { Issue.record("expected a refusal"); return }
        #expect(why.contains("Echo cancellation stopped working"))
        #expect(harness.all.first?.sent.last == .close)
    }

    /// Review fix: a session that started echo-cancelled on speakers and then moved to headphones still has its mic on
    /// the shared engine; when that engine dies the session must reopen on the plain engines, not stay deaf.
    @Test func losingEchoCancellationAfterMovingToHeadphonesReopensOnThePlainEngines() async throws {
        let harness = Harness()
        harness.route = .speakers
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .echoCancelled))
        #expect(await controller.start() == .on)
        harness.route = .headphones
        await controller.outputRouteChanged()
        #expect(await controller.state == .on)
        #expect(harness.all.count == 1)
        await controller.echoCancellationLost("died: no audio")
        #expect(await controller.state == .on)
        #expect(await controller.echoCancelled == false)
        #expect(harness.all.count == 2)
        #expect(harness.all.first?.sent.last == .close)
        let conversation = try #require(await controller.currentConversation)
        #expect(await conversation.echoSettings == RealtimeEchoGate.Settings())
        await controller.stop()
    }

    @Test func movingToSpeakersMidSessionReopensOnTheCancelledEngine() async throws {
        let harness = Harness()
        harness.route = .headphones
        let prepared = LockedBox(0)
        let controller = AlwaysOnVoiceController(environment: environment(harness, plan: .echoCancelled, prepared: prepared))
        #expect(await controller.start() == .on)
        harness.route = .speakers
        await controller.outputRouteChanged()
        #expect(await controller.state == .on)
        #expect(prepared.value == 1)
        #expect(harness.all.count == 2)
        let conversation = try #require(await controller.currentConversation)
        #expect(await conversation.echoSettings == .speakersEchoCancelled)
        await controller.stop()
    }
}

// MARK: - Echo gate tuning

/// Speech-like test audio: bursts of a few harmonics with a syllable envelope and pauses.
private func syntheticSpeech(seconds: Double, rate: Int, seed: Double) -> [Float] {
    let count = Int(seconds * Double(rate))
    return (0..<count).map { index in
        let t = Double(index) / Double(rate)
        let syllable = max(0, sin(2 * .pi * (3.1 + seed * 0.3) * t)) // ~3 syllables per second
        let phrase = fmod(t + seed, 2.4) < 1.9 ? 1.0 : 0.0 // a pause every couple of seconds
        let f0 = 140 + 30 * sin(2 * .pi * 0.7 * t + seed)
        let voice = sin(2 * .pi * f0 * t) + 0.5 * sin(2 * .pi * 2 * f0 * t) + 0.25 * sin(2 * .pi * 3 * f0 * t)
        return Float(0.18 * syllable * phrase * voice)
    }
}

// Small on purpose (8 kHz, short clips): these run in parallel with the timing-sensitive suites, and long synchronous
// work would starve them. `occtl soundcheck gate-tune` runs the full sweep over recorded voices.
@Suite struct EchoGateTuningTests {
    static let rate = 8_000
    static let replies = [syntheticSpeech(seconds: 2.6, rate: rate, seed: 0), syntheticSpeech(seconds: 2.2, rate: rate, seed: 1.3)]
    static let users = [syntheticSpeech(seconds: 1.0, rate: rate, seed: 2.1)]

    @Test func theCancelledPresetNeverOpensOnEchoAndLetsANormalVoiceIn() {
        for room in EchoGateTuner.Room.speakersCancelled {
            for reply in Self.replies {
                let echoOnly = EchoGateTuner.run(.speakersEchoCancelled, reply: reply, user: [], sampleRate: Self.rate,
                                                 scenario: .init(room: room, userLevelDB: nil))
                #expect(!echoOnly.falseBargeIn, "echo opened the gate in \(room.name)")
                let user = EchoGateTuner.run(.speakersEchoCancelled, reply: reply, user: Self.users[0], sampleRate: Self.rate,
                                             scenario: .init(room: room, userLevelDB: -28, userStartsAt: 1.0))
                #expect(!user.falseBargeIn && !user.missed, "\(room.name): \(user)")
                #expect((user.latency ?? 9) < 0.8, "\(room.name): \(user)")
            }
        }
    }

    @Test func theRawPresetHoldsAgainstEchoAtNormalVolumeAndNeedsAClearlyLouderVoice() {
        let normal = EchoGateTuner.Room.speakersRaw[1]
        for reply in Self.replies {
            let echoOnly = EchoGateTuner.run(.speakersRaw, reply: reply, user: [], sampleRate: Self.rate,
                                             scenario: .init(room: normal, userLevelDB: nil))
            #expect(!echoOnly.falseBargeIn, "echo opened the gate in \(normal.name)")
        }
        let loud = EchoGateTuner.run(.speakersRaw, reply: Self.replies[0], user: Self.users[0], sampleRate: Self.rate,
                                     scenario: .init(room: normal, userLevelDB: -14, userStartsAt: 1.0))
        #expect(!loud.falseBargeIn && !loud.missed && (loud.latency ?? 9) < 1.5, "\(loud)")
    }

    @Test func theOldDefaultsLetLoudSpeakerEchoBargeIn() {
        // Why the presets exist: the untuned gate opens on the voice alone with loud laptop speakers.
        let echoOnly = EchoGateTuner.run(RealtimeEchoGate.Settings(), reply: Self.replies[0], user: [], sampleRate: Self.rate,
                                         scenario: .init(room: EchoGateTuner.Room.speakersRaw[0], userLevelDB: nil))
        #expect(echoOnly.falseBargeIn)
    }

    @Test func theSweepRanksSafeSettingsFirst() {
        let rows = EchoGateTuner.sweep(candidates: EchoGateTuner.grid(levels: [-60, -36], speech: [0.24], settle: 0.3),
                                       replies: [Self.replies[0]], users: Self.users, sampleRate: Self.rate,
                                       scenarios: EchoGateTuner.Room.speakersCancelled.map { .init(room: $0, userLevelDB: nil) }
                                           + [.init(room: EchoGateTuner.Room.speakersCancelled[1], userLevelDB: -28)])
        #expect(rows.first?.falseBargeIns == 0)
        #expect(rows.first?.settings.bargeInLevelDB == -36)
        #expect(rows.last.map { $0.falseBargeIns > 0 } == true)
    }

    @Test func presetsFollowTheRoute() {
        #expect(RealtimeEchoGate.Settings.tuned(for: .headphones, echoCancelled: true) == RealtimeEchoGate.Settings())
        #expect(RealtimeEchoGate.Settings.tuned(for: .speakers, echoCancelled: true) == .speakersEchoCancelled)
        #expect(RealtimeEchoGate.Settings.tuned(for: .unknown, echoCancelled: false) == .speakersRaw)
    }
}
