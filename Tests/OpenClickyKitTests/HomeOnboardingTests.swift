import Foundation
import Testing
@testable import OpenClickyKit

private let allGranted: [OnboardingPermission: Bool] = [.microphone: true, .screenRecording: true, .accessibility: true, .speechRecognition: false]

@Test func onboardingWalksEveryStepToDone() {
    let clock = HomeClock()
    var machine = OnboardingMachine(now: clock.function)
    #expect(machine.step == .welcome)
    #expect(machine.canContinue)

    #expect(machine.send(.next) == [.watchPermissions, .saveProgress])
    #expect(machine.step == .permissions)
    #expect(machine.blocker == "Waiting for Microphone, Screen Recording, Accessibility.")
    #expect(machine.send(.next).isEmpty, "can't continue while permissions are missing")
    machine.send(.permissionsChanged([.microphone: true]))
    #expect(machine.blocker == "Waiting for Screen Recording, Accessibility.")
    machine.send(.permissionsChanged(allGranted))
    #expect(machine.canContinue, "speech recognition is optional")

    #expect(machine.send(.next) == [.stopWatchingPermissions, .checkProviders, .saveProgress])
    #expect(machine.step == .providers)
    #expect(machine.blocker == "Checking your models and keys…")
    machine.send(.providersChecked(blocking: ["Brain: No credential named \"anthropic\"."], warnings: []))
    #expect(machine.blocker == "Brain: No credential named \"anthropic\".")
    machine.send(.providersChecked(blocking: [], warnings: ["Background agent: No model chosen for this slot."]))
    #expect(machine.canContinue)
    #expect(machine.state.providerWarnings.count == 1)

    machine.send(.next)
    #expect(machine.step == .voiceTest)
    #expect(machine.blocker == "Play the test line first, or skip it.")
    #expect(machine.send(.startVoiceTest) == [.speakTestLine(OnboardingMachine.testLine)])
    #expect(machine.send(.startVoiceTest).isEmpty, "one test line at a time")
    #expect(machine.blocker == "Speaking the test line…")
    machine.send(.voiceTestFinished(seconds: 3.2))
    #expect(machine.state.voiceTest == .succeeded(seconds: 3.2))

    machine.send(.next)
    #expect(machine.step == .talkKeys)
    machine.send(.talkKeyPracticed)
    #expect(machine.state.practicedTalkKey)

    #expect(machine.send(.next) == [.openInterview(attempt: 1), .saveProgress])
    #expect(machine.step == .interview)
    #expect(machine.state.interview.phase == .preparing)
    #expect(machine.canContinue, "the welcome chat never blocks")
    #expect(machine.send(.skipInterview) == [.closeInterview, .loadSkillPicks, .saveProgress], "nothing answered, nothing saved")
    #expect(machine.step == .skills)
    machine.send(.skillPicksLoaded(["research"]))
    #expect(machine.send(.next) == [.activateSkills(["research"]), .saveProgress])
    #expect(machine.step == .firstQuestion)
    #expect(machine.send(.askFirstQuestion("   ")).isEmpty)
    clock.advance(42)
    #expect(machine.send(.askFirstQuestion(" What can you do? ")) == [.saveProgress, .sendFirstQuestion("What can you do?")])
    #expect(machine.step == .done)
    #expect(machine.isComplete)
    #expect(machine.state.completedAt == clock.now)
    #expect(machine.send(.back).isEmpty, "done is final")
}

/// The welcome chat step walked through the shared performer with a fake realtime client (more cases in
/// HomeOnboardingInterviewTests.swift): the session opens, a spoken answer counts, and Continue closes it and saves.
@MainActor @Test func onboardingWalksTheWelcomeChatWithAFakeRealtimeClient() async throws {
    let client = InterviewFakeClient()
    let rig = InterviewRig(client: client, storage: .init(transcriptURL: nil, memory: nil))
    rig.send(.next)
    #expect(rig.machine.step == .interview)
    #expect(await waitUntil { rig.interview.phase == .live })
    rig.modelSays("Hi! What are you working on these days?", id: "r0")
    rig.userSays("A website for my bakery", item: "u1")
    #expect(await waitUntil { rig.interview.answers == ["A website for my bakery"] })
    rig.send(.next)
    #expect(rig.machine.step == .skills)
    let session = try #require(client.sessions.last)
    #expect(await waitUntil { session.sent.contains(.close) }, "leaving the step closes the session")
    #expect(rig.performer.savedRecords.last?.answers == ["A website for my bakery"])
}

/// Holds the welcome chat's controller back until the test lets it go.
final class InterviewGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false

    var isWaiting: Bool { lock.withLock { waiter != nil } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiter = lock.withLock {
            opened = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

/// Leaving the step (or closing the window) while the chat is still being prepared must not leave a microphone
/// session running once the preparation finishes.
@Test func onboardingClosingTheChatWhileItIsPreparedOpensNoSession() async throws {
    let client = InterviewFakeClient()
    let gate = InterviewGate()
    let session = OnboardingInterviewSession(skip: { false }) { toolbox, instructions in
        await gate.wait()
        let environment = AlwaysOnVoiceController.Environment(
            connect: { try client.connect($0) },
            configuration: { _ in RealtimeSessionConfiguration(instructions: instructions(), tools: toolbox.specs) },
            toolbox: toolbox, makeOutput: { RecordingRealtimeOutput(realTime: false) }, microphone: ManualMicrophone(),
            outputRoute: { .headphones }, maxReconnects: 0)
        return AlwaysOnVoiceController(environment: environment)
    }
    let opening = Task { await session.open() }
    #expect(await waitUntil { gate.isWaiting })
    await session.close()
    gate.open()
    await opening.value
    #expect(client.attempts == 0, "the closed chat never connects")
    var events: [OnboardingEvent] = []
    for await event in session.events { events.append(event) }
    #expect(!events.contains(.interviewReady))
}

@Test func onboardingCanGoOnWithoutPermissionsAndSkipTheVoice() {
    var machine = OnboardingMachine()
    machine.send(.next)
    #expect(machine.send(.requestPermission(.microphone)) == [.requestPermission(.microphone)])
    #expect(machine.send(.continueWithoutPermissions) == [.stopWatchingPermissions, .checkProviders, .saveProgress])
    #expect(machine.state.continuedWithoutPermissions)
    machine.send(.providersChecked(blocking: [], warnings: []))
    machine.send(.next)
    machine.send(.startVoiceTest)
    machine.send(.voiceTestFailed("ElevenLabs HTTP 401: invalid key"))
    #expect(machine.state.voiceTest == .failed("ElevenLabs HTTP 401: invalid key"))
    #expect(!machine.canContinue)
    machine.send(.skipVoiceTest)
    #expect(machine.step == .talkKeys)
    // Going back to permissions re-checks them; the user already chose to go on without.
    machine.send(.goTo(.permissions))
    #expect(machine.step == .permissions)
    #expect(machine.canContinue)
    #expect(machine.send(.goTo(.firstQuestion)).isEmpty, "can't jump past the furthest step reached")
    machine.send(.goTo(.talkKeys))
    #expect(machine.step == .talkKeys)
}

@Test func onboardingProviderStepRechecksEachTimeItOpens() {
    var machine = OnboardingMachine()
    machine.send(.next)
    machine.send(.permissionsChanged(allGranted))
    machine.send(.next)
    machine.send(.providersChecked(blocking: [], warnings: []))
    machine.send(.next)
    #expect(machine.send(.back) == [.checkProviders, .saveProgress])
    #expect(!machine.canContinue, "a fresh check is pending")
}

@Test func onboardingDismissRestartAndResume() throws {
    let folder = HomeTemporaryFolder("onboarding")
    let url = folder.path("onboarding.json")
    #expect(OnboardingProgress.needsOnboarding(at: url))

    var machine = OnboardingMachine()
    machine.send(.next)
    machine.send(.permissionsChanged(allGranted))
    #expect(machine.send(.dismiss) == [.stopWatchingPermissions, .saveProgress, .close])
    try OnboardingProgress.save(machine.state, to: url)
    #expect(OnboardingProgress.needsOnboarding(at: url))

    // Permissions are never trusted from disk: the resumed flow waits for live status again.
    let resumed = OnboardingMachine(state: try #require(OnboardingProgress.load(from: url)))
    #expect(resumed.step == .permissions)
    #expect(!resumed.canContinue)

    var finished = OnboardingMachine(state: resumed.state)
    finished.send(.permissionsChanged(allGranted))
    finished.send(.next)
    finished.send(.providersChecked(blocking: [], warnings: []))
    finished.send(.next)
    finished.send(.skipVoiceTest)
    finished.send(.next)
    finished.send(.skipInterview)
    finished.send(.next)
    finished.send(.askFirstQuestion("Hi"))
    try OnboardingProgress.save(finished.state, to: url)
    #expect(!OnboardingProgress.needsOnboarding(at: url))

    finished.send(.restart)
    #expect(finished.step == .welcome)
    #expect(finished.state.completedAt == nil)
    #expect(finished.state.permissions == allGranted, "a replay keeps the live permission status")
}

@Test func onboardingOnlyBlocksOnTheSlotsItNeeds() {
    let config = OpenClickyConfig(
        providers: [ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"), credential: "anthropic"),
                    ProviderConfig(id: "openai", dialect: .openAIResponses, baseURL: URL(string: "https://api.openai.com/v1"), credential: "openai"),
                    ProviderConfig(id: "apple-speech", dialect: .appleSpeech),
                    ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis)],
        slots: [.stt: SlotSelection(provider: "apple-speech", model: "on-device"),
                .voice: SlotSelection(provider: "apple-voices", model: "system"),
                .brain: SlotSelection(provider: "anthropic", model: "claude-haiku-5-5"),
                .agent: SlotSelection(provider: "openai", model: "gpt-6-luna", harness: .codex)])
    let issues = ConfigValidator(catalog: (try? ModelCatalog.builtIn()) ?? ModelCatalog(models: []), credentials: InMemoryCredentialStore()).validate(config)
    let split = OnboardingProviderCheck.split(issues, config: config)
    #expect(split.blocking.contains { $0.contains("\"anthropic\"") }, "the brain's key is missing")
    #expect(!split.blocking.contains { $0.contains("\"openai\"") }, "only the agent uses openai, so that's a warning")
    #expect(split.warnings.contains { $0.contains("\"openai\"") })

    let keyed = ConfigValidator(catalog: (try? ModelCatalog.builtIn()) ?? ModelCatalog(models: []),
                                credentials: InMemoryCredentialStore(["anthropic": "k"])).validate(config)
    #expect(OnboardingProviderCheck.split(keyed, config: config).blocking.isEmpty)
}

@Test func onboardingSetupPlansFillTheSlotsAndNameTheKeys() throws {
    let start = OpenClickyConfig(providers: [ProviderConfig(id: "apple-speech", dialect: .appleSpeech)],
                                 slots: [.stt: SlotSelection(provider: "apple-speech", model: "on-device")])
    let plan = try #require(OnboardingSetupPlan.all.first { $0.id == "claude-elevenlabs" })
    #expect(!plan.isApplied(in: start))
    let config = plan.apply(to: start)
    #expect(plan.isApplied(in: config))
    #expect(config.providers.map(\.id) == ["apple-speech", "anthropic", "elevenlabs"], "existing providers are kept, missing ones added once")
    #expect(config.slots[.voice]?.voice == "EXAVITQu4vr4xnSDxMaL")
    #expect(Set(OnboardingSetupPlan.neededKeys(for: config).map(\.name)) == ["anthropic", "elevenlabs"])
    #expect(OnboardingSetupPlan.neededKeys(for: config).first?.preset?.keyHelpURL != nil)

    // Every plan validates once its keys exist.
    let catalog = try ModelCatalog.builtIn()
    for plan in OnboardingSetupPlan.all {
        let planned = plan.apply(to: start)
        let keys = Dictionary(uniqueKeysWithValues: OnboardingSetupPlan.neededKeys(for: planned).map { ($0.name, "k") })
        let issues = ConfigValidator(catalog: catalog, credentials: InMemoryCredentialStore(keys)).validate(planned)
        #expect(OnboardingProviderCheck.split(issues, config: planned).blocking.isEmpty, "\(plan.id): \(issues)")
    }
}
