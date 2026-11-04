import Foundation
import Testing
@testable import OpenClickyKit

// The onboarding welcome chat and skills picker steps (HomeOnboardingTests' new steps), walked with a fake realtime
// client: answers counted into progress notes, the retry, the typed fallback, the skip tool, and the memory that the
// next brain turn sees.

/// A machine already on the talk-keys step, so `.next` opens the welcome chat.
func interviewMachineAtTalkKeys(now: @escaping @Sendable () -> Date = Date.init) -> OnboardingMachine {
    var state = OnboardingState()
    state.step = .talkKeys
    state.furthest = .talkKeys
    return OnboardingMachine(state: state, now: now)
}

/// A realtime client whose first `failures` connections throw; later ones return fake sessions the test drives.
final class InterviewFakeClient: @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private var made: [FakeRealtimeVoiceSession] = []
    private var configurations: [RealtimeSessionConfiguration] = []

    init(failures: Int = 0) { failuresLeft = failures }

    func connect(_ configuration: RealtimeSessionConfiguration) throws -> any RealtimeVoiceSession {
        try lock.withLock {
            configurations.append(configuration)
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw ProviderError(provider: "fake-realtime", message: "realtime preparation unavailable")
            }
            let session = FakeRealtimeVoiceSession()
            made.append(session)
            return session
        }
    }

    var sessions: [FakeRealtimeVoiceSession] { lock.withLock { made } }
    var attempts: Int { lock.withLock { configurations.count } }
    var lastConfiguration: RealtimeSessionConfiguration? { lock.withLock { configurations.last } }
}

/// Owns the machine like the onboarding window does and routes the chat's effects to the shared performer.
@MainActor
final class InterviewRig {
    private(set) var machine: OnboardingMachine
    let performer: OnboardingInterviewPerformer
    let client: InterviewFakeClient
    private(set) var effects: [OnboardingEffect] = []

    init(client: InterviewFakeClient, storage: OnboardingInterviewPerformer.Storage, machine: OnboardingMachine = interviewMachineAtTalkKeys(),
         captionGrace: Duration = .seconds(2)) {
        self.client = client
        self.machine = machine
        performer = OnboardingInterviewPerformer(storage: storage, connectableApps: { ["Gmail", "Notion"] },
                                                 captionGrace: captionGrace) { toolbox, instructions in
            let environment = AlwaysOnVoiceController.Environment(
                connect: { try client.connect($0) },
                configuration: { _ in RealtimeSessionConfiguration(instructions: instructions(), tools: toolbox.specs) },
                toolbox: toolbox, makeOutput: { RecordingRealtimeOutput(realTime: false) }, microphone: ManualMicrophone(),
                outputRoute: { .headphones }, maxReconnects: 0)
            return AlwaysOnVoiceController(environment: environment)
        }
        performer.deliver = { [weak self] event in self?.send(event) }
        performer.acceptsSkip = { [weak self] in self?.machine.acceptsInterviewSkip ?? false }
    }

    func send(_ event: OnboardingEvent) {
        let made = machine.send(event)
        effects += made
        for effect in made { performer.perform(effect) }
    }

    var interview: OnboardingInterviewState { machine.state.interview }

    /// Texts the app sent into the latest session.
    var sentTexts: [(String, Bool)] {
        (client.sessions.last?.sent ?? []).compactMap { if case .text(let text, let respond) = $0 { (text, respond) } else { nil } }
    }

    /// The fake server: the user said `text` (a final caption), then the model replied `reply`.
    func userSays(_ text: String, item: String) {
        client.sessions.last?.emit(.userTurnCommitted(itemID: item))
        client.sessions.last?.emit(.userTranscript(text: text, isFinal: true, itemID: item))
    }

    func modelSays(_ text: String, id: String) {
        client.sessions.last?.emit(.responseStarted(responseID: id))
        client.sessions.last?.emit(.responseFinished(RealtimeResponseSummary(responseID: id, status: .completed, transcript: text)))
    }
}

@Suite struct OnboardingInterviewMachineTests {
    @Test func answersAreCountedIntoProgressNotesAndTheWrapUpSavesTheChat() {
        var machine = interviewMachineAtTalkKeys()
        machine.send(.next)
        #expect(machine.send(.interviewReady) == [.sendInterviewText(OnboardingInterviewScript.openerNote, respond: true)])
        #expect(machine.state.interview.phase == .live)
        machine.send(.interviewSaid(OnboardingInterviewScript.opener.joined(separator: " ")))

        let first = machine.send(.interviewAnswered("I run a small bakery", typed: false))
        guard case .sendInterviewText(let note, false) = first.first else { Issue.record("no progress note"); return }
        #expect(note.contains("Replies so far: 1 of 4") && note.contains("3 replies remain"))
        #expect(note.contains("What are you working on these days?"), "the note lists the questions used")
        machine.send(.interviewSaid("Lovely. What does a busy morning look like?"))
        machine.send(.interviewAnswered("Baking from five, then emails", typed: false))
        machine.send(.interviewSaid("Which part would you hand off?"))
        let third = machine.send(.interviewAnswered("Supplier emails", typed: false))
        #expect(third == [.sendInterviewText(RealtimeInstructions.interviewProgress(asked: machine.state.interview.questions.map(OnboardingInterviewArchive.lastSentence), answered: 3, total: 4),
                                             respond: false)])
        #expect(RealtimeInstructions.interviewProgress(asked: [], answered: 3, total: 4).contains("closing question about AI agents"))
        machine.send(.interviewSaid("Have you tried any AI agents?"))
        #expect(machine.send(.interviewAnswered("   ", typed: false)).isEmpty, "empty captions aren't answers")
        machine.send(.interviewAnswered("Only ChatGPT", typed: false))
        #expect(machine.state.interview.answers.count == 4)
        #expect(machine.send(.interviewAnswered("one more", typed: false)).isEmpty, "the budget is four answers")

        let wrap = machine.send(.interviewSaid("Thanks so much. Supplier emails sound like the place to start."))
        #expect(machine.state.interview.phase == .finished)
        #expect(wrap.first == .closeInterview)
        guard case .saveInterview(let saved) = wrap[1] else { Issue.record("not saved"); return }
        #expect(saved.answers == ["I run a small bakery", "Baking from five, then emails", "Supplier emails", "Only ChatGPT"])
        #expect(machine.step == .interview, "the step waits for Continue after the wrap-up")
        #expect(machine.send(.next) == [.loadSkillPicks, .saveProgress], "already saved, nothing to close")
    }

    @Test func preparationIsRetriedOnceThenTheChatIsTyped() {
        var machine = interviewMachineAtTalkKeys()
        #expect(machine.send(.next).first == .openInterview(attempt: 1))
        #expect(machine.send(.interviewPreparationFailed("socket closed")) == [.openInterview(attempt: 2)])
        #expect(machine.state.interview.phase == .preparing)
        machine.send(.interviewPreparationFailed("socket closed again"))
        #expect(machine.state.interview.phase == .scripted)
        #expect(machine.state.interview.typing)
        #expect(machine.state.interview.failure == "socket closed again")
        #expect(machine.state.interview.questions == OnboardingInterviewScript.opener, "the opener is shown as two bubbles")

        machine.send(.interviewAnswered("Planning a wedding", typed: true))
        #expect(machine.state.interview.questions.last == OnboardingInterviewScript.typedQuestions[0])
        machine.send(.interviewAnswered("Spreadsheets all day", typed: true))
        #expect(machine.state.interview.questions.last == OnboardingInterviewScript.typedQuestions[1])
        machine.send(.interviewAnswered("Vendor emails", typed: true))
        #expect(machine.state.interview.questions.last?.contains("AI agents") == true, "the last question is always about agents")
        let effects = machine.send(.interviewAnswered("Never tried one", typed: true))
        #expect(machine.state.interview.phase == .finished)
        #expect(machine.state.interview.questions.last == OnboardingInterviewScript.typedWrapUp)
        #expect(effects.contains { if case .saveInterview = $0 { true } else { false } })
        #expect(machine.state.interview.lines.filter { $0.role == .user }.allSatisfy { $0.typed == true })
    }

    @Test func leavingOrDroppingTheChatKeepsTheAnswers() {
        var machine = interviewMachineAtTalkKeys()
        machine.send(.next)
        machine.send(.interviewReady)
        machine.send(.interviewAnswered("Writing a novel", typed: false))
        // The session dropped: the rest is typed, starting with the question already asked.
        #expect(machine.send(.interviewEnded("provider closed the socket")) == [.closeInterview, .saveProgress])
        #expect(machine.state.interview.phase == .scripted)
        machine.send(.interviewAnswered("Mostly mornings", typed: true))
        #expect(machine.state.interview.questions.last == OnboardingInterviewScript.typedQuestions[1])
        // Continue mid-chat counts as a skip and saves the two answers.
        let effects = machine.send(.next)
        #expect(machine.state.interview.phase == .skipped)
        #expect(effects.contains { if case .saveInterview(let state) = $0 { state.answers.count == 2 } else { false } })
        #expect(machine.step == .skills)
        // Back, then Start Over, opens a fresh chat.
        machine.send(.back)
        #expect(machine.send(.startInterview) == [.openInterview(attempt: 1), .saveProgress])
        #expect(machine.state.interview.answers.isEmpty)
        #expect(machine.acceptsInterviewSkip)
        // Closing the window mid-chat closes the session and starts over on resume.
        #expect(machine.send(.dismiss) == [.closeInterview, .saveProgress, .close])
        #expect(machine.state.interview.phase == .notStarted)
    }

    @Test func aSavedFlowFromBeforeTheNewStepsStillLoads() throws {
        let folder = HomeTemporaryFolder("onboarding-old")
        let url = folder.path("onboarding.json")
        try #"{"step":"done","furthest":"done","permissions":[],"continuedWithoutPermissions":false,"providerProblems":[],"providerWarnings":[],"providersChecked":true,"voiceTest":{"succeeded":{"seconds":5.06}},"practicedTalkKey":true,"completedAt":"2026-10-30T10:00:00Z"}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let state = try #require(OnboardingProgress.load(from: url))
        #expect(state.completedAt != nil)
        #expect(!OnboardingProgress.needsOnboarding(at: url), "a finished onboarding isn't shown again")
        #expect(state.interview.phase == .notStarted)
        #expect(state.skillPicks == nil)

        // A chat that was open when the app quit is saved as not started.
        var running = OnboardingState()
        running.step = .interview
        running.interview.phase = .live
        running.interview.lines = [OnboardingInterviewLine(role: .user, text: "hi")]
        try OnboardingProgress.save(running, to: url)
        #expect(OnboardingProgress.load(from: url)?.interview.phase == .notStarted)
    }
}

@Suite(.serialized) struct OnboardingInterviewSessionTests {
    @MainActor @Test func theStepRunsAgainstAFakeRealtimeClientWithRetrySkipAndMemory() async throws {
        let folder = HomeTemporaryFolder("interview")
        let memoryFolder = TemporaryMemoryFolder()
        let memory = memoryFolder.store()
        let client = InterviewFakeClient(failures: 1)
        let rig = InterviewRig(client: client, storage: .init(transcriptURL: folder.path("onboarding-interview.json"), memory: memory))

        rig.send(.next)
        // The first preparation fails; the flow retries once by itself.
        #expect(await waitUntil { rig.interview.phase == .live })
        #expect(client.attempts == 2)
        #expect(rig.effects.contains(.openInterview(attempt: 2)))
        let configuration = try #require(client.lastConfiguration)
        #expect(configuration.instructions.contains("exactly 4 answers"))
        #expect(configuration.instructions.contains("Gmail, Notion"))
        #expect(configuration.tools.map(\.name) == [RealtimeToolName.skipInterview])
        #expect(await waitUntil { rig.sentTexts.contains { $0.0 == OnboardingInterviewScript.openerNote && $0.1 } }, "the opener is asked for")

        rig.modelSays(OnboardingInterviewScript.opener.joined(separator: " "), id: "r0")
        rig.userSays("I'm launching a podcast about city cycling", item: "u1")
        #expect(await waitUntil { rig.interview.answers.count == 1 })
        #expect(await waitUntil { rig.sentTexts.contains { $0.0.contains("Replies so far: 1 of 4") && !$0.1 } }, "spoken answers get a note")
        rig.modelSays("A cycling podcast! How do you plan an episode: research first, or record and edit?", id: "r1")
        #expect(await waitUntil { rig.interview.questions.count == 2 })

        // Typing instead: the answer goes to the session after its note, and asks for a reply.
        rig.send(.interviewTyping(true))
        rig.send(.interviewAnswered("Research first, in Notion", typed: true))
        #expect(await waitUntil { rig.sentTexts.last.map { $0.0 == "Research first, in Notion" && $0.1 } ?? false })
        let notes = rig.sentTexts.filter { $0.0.contains("Replies so far: 2 of 4") }
        #expect(notes.count == 1 && notes[0].1 == false)
        rig.modelSays("Notion, nice. What eats most of your week?", id: "r2")

        // The model hears "let's stop" and calls the skip tool: the flow moves on, keeping both answers.
        let session = try #require(client.sessions.last)
        session.emit(.responseStarted(responseID: "r3"))
        session.emit(.toolCall(RealtimeToolCall(callID: "skip-1", name: RealtimeToolName.skipInterview, arguments: "{}")))
        #expect(await waitUntil { rig.machine.step == .skills })
        #expect(rig.interview.phase == .skipped)
        #expect(await waitUntil { session.sent.contains(.close) }, "the session is closed")
        // The skip closes the session, which cancels calls still running, so the result may never be sent; when it
        // is, it says accepted.
        #expect(session.toolResults.allSatisfy { $0.output["status"] == "accepted" })

        // A late skip (nothing running) is refused.
        #expect(!rig.machine.acceptsInterviewSkip)

        // The transcript and the [About the user] memory were written.
        let record = try #require(OnboardingInterviewArchive.load(from: folder.path("onboarding-interview.json")))
        #expect(record.outcome == .skipped)
        #expect(record.answers == ["I'm launching a podcast about city cycling", "Research first, in Notion"])
        let profile = try memory.profileText()
        #expect(profile.contains("## \(OnboardingInterviewScript.memorySection)"))
        #expect(profile.contains("What are you working on these days?\u{201D}: I'm launching a podcast about city cycling"))
        #expect(profile.contains("research first, or record and edit?\u{201D}: Research first, in Notion"))

        // The next brain turn sees it in its context.
        let model = BrainScriptModel([[.text("Got it."), .finish(.stop)]])
        let runtime = BrainFixtures.runtime(model, memory: BrainMemory(store: memory))
        _ = try await BrainFixtures.events(runtime, BrainFixtures.input("what should I do first?"))
        let system = try #require(model.requests.first?.messages.first?.text)
        #expect(system.contains("\(OnboardingInterviewScript.memorySection):"))
        #expect(system.contains("I'm launching a podcast about city cycling"))
    }

    @MainActor @Test func aReplyThatFinishesBeforeItsAnswerIsTranscribedWaitsForIt() async throws {
        let client = InterviewFakeClient()
        let rig = InterviewRig(client: client, storage: .init(transcriptURL: nil, memory: nil), captionGrace: .milliseconds(200))
        rig.send(.next)
        #expect(await waitUntil { rig.interview.phase == .live })
        rig.modelSays("Hi. What are you working on?", id: "r0")
        #expect(await waitUntil { rig.interview.questions.count == 1 })
        let session = try #require(client.sessions.last)
        // Gemini's order: words so far, the whole reply, then the settled caption, then trailing words.
        session.emit(.userTranscript(text: "A garden", isFinal: false, itemID: "g1"))
        rig.modelSays("A garden! What grows there?", id: "r1")
        session.emit(.userTranscript(text: "A garden planner", isFinal: true, itemID: "g1"))
        #expect(await waitUntil { rig.interview.lines.count == 3 })
        #expect(rig.interview.lines.map(\.role) == [.assistant, .user, .assistant], "the answer comes before the reply to it")
        #expect(rig.interview.answers == ["A garden planner"])
        session.emit(.userTranscript(text: "A garden planner app", isFinal: true, itemID: "g1"))
        #expect(await waitUntil { rig.interview.answers == ["A garden planner app"] }, "a longer transcript revises the answer")
        #expect(rig.interview.answers.count == 1)
        session.emit(.userTranscript(text: "A garden planner app", isFinal: true, itemID: "g1"))

        // No final caption at all: after the grace period the partial words count.
        session.emit(.userTranscript(text: "Tomatoes mostly", isFinal: false, itemID: "g2"))
        rig.modelSays("Tomatoes are great. Which part takes longest?", id: "r2")
        #expect(await waitUntil { rig.interview.answers.count == 2 })
        #expect(rig.interview.answers.last == "Tomatoes mostly")
        #expect(rig.interview.lines.last?.role == .assistant)

        // The same words in a new turn are a new answer.
        session.emit(.userSpeechStarted)
        session.emit(.userSpeechStopped)
        rig.userSays("Tomatoes mostly", item: "g3")
        #expect(await waitUntil { rig.interview.answers.count == 3 })
    }

    @MainActor @Test func twoFailedPreparationsFallBackToTypingWithoutASession() async throws {
        let client = InterviewFakeClient(failures: 5)
        let memoryFolder = TemporaryMemoryFolder()
        let memory = memoryFolder.store()
        let rig = InterviewRig(client: client, storage: .init(transcriptURL: nil, memory: memory))
        rig.send(.next)
        #expect(await waitUntil { rig.interview.phase == .scripted })
        #expect(client.attempts == 2, "one retry, not more")
        #expect(rig.interview.failure?.contains("realtime preparation unavailable") == true)
        for answer in ["Teaching", "Grading at night", "Lesson plans", "Never"] { rig.send(.interviewAnswered(answer, typed: true)) }
        #expect(rig.interview.phase == .finished)
        #expect(rig.performer.savedRecords.count == 1)
        #expect(try memory.profileText().contains("Grading at night"))
    }

    @MainActor @Test func aSecondChatReplacesTheFirstInMemory() throws {
        let memoryFolder = TemporaryMemoryFolder()
        let memory = memoryFolder.store()
        _ = try memory.addToProfile("Lives in Porto", section: "Basics")
        var first = OnboardingInterviewState()
        first.lines = [OnboardingInterviewLine(role: .assistant, text: "Hi. What are you up to?"), OnboardingInterviewLine(role: .user, text: "Old answer")]
        try OnboardingInterviewArchive.writeMemory(OnboardingInterviewRecord(state: first), to: memory)
        var second = first
        second.lines[1].text = "New answer"
        try OnboardingInterviewArchive.writeMemory(OnboardingInterviewRecord(state: second), to: memory)
        let text = try memory.profileText()
        #expect(!text.contains("Old answer") && text.contains("New answer"))
        #expect(text.components(separatedBy: "## \(OnboardingInterviewScript.memorySection)").count == 2, "one section")
        #expect(text.contains("Lives in Porto"))
        #expect(OnboardingInterviewArchive.lastSentence("Great. What's next? Tell me.") == "What's next?")
    }
}

@Suite struct OnboardingSkillPickerTests {
    func picker(_ folder: HomeTemporaryFolder) -> SkillPicker { SkillPicker(stateURL: folder.path("skill-picks.json")) }

    @Test func entriesCoverTheStarterCatalogByCategoryAndBundleSkills() {
        let folder = HomeTemporaryFolder("picker")
        let picker = picker(folder)
        let entries = picker.entries()
        let catalogIDs = Set(SkillCatalog().entries().map(\.id))
        #expect(catalogIDs.count == 8)
        #expect(Set(entries.flatMap(\.skillIDs)) == catalogIDs, "every starter skill can be picked, and nothing else")
        #expect(entries.contains { $0.skillIDs.count > 1 }, "an entry can bundle several skills")
        let categories = picker.categories()
        #expect(categories.map(\.category.name) == SkillCategory.all.map(\.name).filter { name in categories.contains { $0.category.name == name } })
        #expect(categories.first { $0.category.name == "Productivity" }?.entries.first?.skillIDs == ["meeting-notes", "writing-coach"])
        #expect(picker.skillIDs(for: ["meetings", "presentations", "nope"]) == ["meeting-notes", "writing-coach", "slide-decks"])
    }

    @Test func defaultsApplyOnFirstLaunchOnlyAndPicksPersist() throws {
        let folder = HomeTemporaryFolder("picker")
        let picker = picker(folder)
        #expect(picker.loadPicks() == SkillPicker.firstLaunchDefaults)
        #expect(picker.load().firstLaunchDefaultsApplied)
        var selection = picker.load()
        selection.picks = []
        try picker.save(selection)
        #expect(picker.loadPicks().isEmpty, "an emptied selection stays empty")
        let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
        picker.activate(["code-review", "trips"], library: library)
        #expect(SkillPicker(stateURL: folder.path("skill-picks.json")).loadPicks() == ["code-review", "trips"])
    }

    @Test func activationCopiesAndSwitchesOnOnlyWhatThePickerOwns() throws {
        let folder = HomeTemporaryFolder("picker")
        let picker = picker(folder)
        let library = SkillsLibrary(directory: folder.path("Skills"), stateURL: folder.path("skills.json"))
        // The user already has research-brief, switched off, and their own writing-coach switched on.
        try SkillCatalog().add("research-brief", to: library)
        try SkillCatalog().add("writing-coach", to: library, enable: true)

        let first = picker.activate(["learning", "writing"], library: library)
        #expect(first.added == ["study-buddy"])
        #expect(first.enabled == ["research-brief"])
        #expect(Set(library.activeSkills().map(\.id)) == ["study-buddy", "research-brief", "writing-coach"])
        #expect(library.skillsPromptSection().contains("Study buddy"), "the brain sees them, and agents get them from the same library")
        #expect(first.summary == "Switched on 2 skills.")

        // Unpicking switches off what the picker turned on, never the user's own writing-coach.
        let second = picker.activate(["writing"], library: library)
        #expect(Set(second.disabled) == ["study-buddy", "research-brief"])
        #expect(library.activeSkills().map(\.id) == ["writing-coach"])
    }

    @Test func theMachineLoadsTogglesAndActivatesOnLeaving() {
        var state = OnboardingState()
        state.step = .interview
        state.furthest = .interview
        state.interview.phase = .finished
        var machine = OnboardingMachine(state: state)
        #expect(machine.send(.next) == [.loadSkillPicks, .saveProgress])
        machine.send(.skillPicksLoaded(["research", "writing"]))
        machine.send(.skillPicksLoaded(["ignored"]))
        #expect(machine.state.skillPicks == ["research", "writing"], "loaded once")
        machine.send(.toggleSkillPick("writing"))
        machine.send(.toggleSkillPick("money"))
        #expect(machine.state.skillPicks == ["research", "money"])
        #expect(machine.send(.next) == [.activateSkills(["research", "money"]), .saveProgress])
        machine.send(.skillsActivated("Switched on 2 skills."))
        #expect(machine.state.skillsNote == "Switched on 2 skills.")
        machine.send(.back)
        #expect(machine.send(.next) == [.saveProgress], "no change, no second activation")
    }
}
