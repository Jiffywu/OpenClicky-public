import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// A brain that replays scripted events and records what it was asked.
final class ReplayBrain: BrainTurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputs: [TurnInput] = []
    let events: [TurnEvent]
    let delay: Duration

    init(_ events: [TurnEvent], delay: Duration = .zero) {
        self.events = events
        self.delay = delay
    }

    var inputs: [TurnInput] { lock.withLock { recordedInputs } }

    func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
        lock.withLock { recordedInputs.append(input) }
        let events = events, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prewarm() async {}
    func recordOutcome(_ note: String) async {}
    func endSession() async {}
}

struct FailingScreen: RealtimeScreenSource {
    var error: Error
    func captureCursorScreen() async throws -> TurnScreenshot { throw error }
}

@Suite struct RealtimeToolDispatcherTests {
    static let shot = TurnScreenshot(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0]), label: "main display", isCursorScreen: true,
                                     pixelSize: CGSize(width: 1280, height: 800), displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))

    static func spec(_ name: String) -> ToolSpec { ToolSpec(name: name, description: name, parameters: ["type": "object"]) }

    static func tool(_ name: String, cancels: Bool = true, timeout: Duration = .seconds(5),
                     run: @escaping @Sendable (RealtimeToolInvocation) async -> RealtimeToolOutcome) -> RealtimeTool {
        RealtimeTool(spec: spec(name), statusLabel: "Running \(name)…", cancelsWhenSuperseded: cancels, timeout: timeout, run: run)
    }

    static func call(_ id: String, _ name: String, _ arguments: String = "{}") -> RealtimeToolCall {
        RealtimeToolCall(callID: id, name: name, arguments: arguments)
    }

    // MARK: - Dispatch rules

    @Test func aToolRunsAndItsAnswerAndPicturesGoBack() async throws {
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [Self.tool("echo") { call in
            var outcome = RealtimeToolOutcome.status("ok", details: ["got": .string(call.string("word") ?? ""),
                                                                     "heard": .string(call.userWords)], succeeded: true)
            outcome.images = [RealtimeImage(data: Data([1, 2]), caption: "pic")]
            return outcome
        }])
        #expect(dispatcher.specs.map(\.name) == ["echo"])
        #expect(dispatcher.statusLabel(for: "echo") == "Running echo…")
        await dispatcher.handle(Self.call("c1", "echo", #"{"word":"hi"}"#), session: session, userWords: "say hi")
        await dispatcher.waitUntilIdle()
        #expect(session.sent == [
            .image(bytes: 2, mimeType: "image/jpeg", caption: "pic"),
            .toolResult(RealtimeToolResult(callID: "c1", name: "echo", output: ["status": "ok", "got": "hi", "heard": "say hi"])),
        ])
    }

    @Test func unknownToolsAndBadArgumentsAreAnsweredAtOnce() async throws {
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [Self.tool("echo") { _ in .status("ok", succeeded: true) }])
        await dispatcher.handle(Self.call("c1", "teleport"), session: session)
        await dispatcher.handle(Self.call("c2", "echo", "[1, 2]"), session: session)
        await dispatcher.handle(Self.call("c3", "echo", "not json"), session: session)
        await dispatcher.handle(Self.call("c4", "echo", ""), session: session)
        await dispatcher.waitUntilIdle()
        let results = session.toolResults
        #expect(results.map { $0.output["status"]?.stringValue } == ["not_implemented", "invalid_request", "invalid_request", "ok"])
        #expect(results.allSatisfy { $0.respond })
    }

    @Test func thePerTurnCapAnswersTheRestWithToolLimitReached() async throws {
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [Self.tool("echo") { _ in .status("ok", succeeded: true) }], maxCallsPerTurn: 2)
        for index in 1...3 { await dispatcher.handle(Self.call("c\(index)", "echo"), session: session) }
        await dispatcher.waitUntilIdle()
        #expect(session.toolResults.first { $0.callID == "c3" }?.output["status"] == "tool_limit_reached")
        #expect(session.toolResults.filter { $0.output["status"] == "ok" }.count == 2)
        // A new user turn starts the count over.
        await dispatcher.userTurnStarted()
        await dispatcher.handle(Self.call("c4", "echo"), session: session)
        await dispatcher.waitUntilIdle()
        #expect(session.toolResults.last == RealtimeToolResult(callID: "c4", name: "echo", output: ["status": "ok"]))
    }

    @Test func aResultThatArrivesAfterANewerTurnIsSupersededAndSilent() async throws {
        let session = FakeRealtimeVoiceSession()
        let ranToEnd = LockedFlag()
        let dispatcher = RealtimeToolDispatcher(tools: [
            Self.tool("lookup") { _ in
                // Cancellable: a newer turn stops it.
                do { try await Task.sleep(for: .seconds(30)) } catch { return .status("cancelled", succeeded: false) }
                return .status("ok", succeeded: true)
            },
            Self.tool("save", cancels: false) { _ in
                try? await Task.sleep(for: .milliseconds(50))
                ranToEnd.set()
                return .status("saved", succeeded: true)
            },
        ])
        await dispatcher.handle(Self.call("c1", "lookup"), session: session)
        await dispatcher.handle(Self.call("c2", "save"), session: session)
        #expect(await dispatcher.runningCount == 2)
        await dispatcher.userTurnStarted()
        await dispatcher.waitUntilIdle()
        #expect(ranToEnd.isSet)
        let results = session.toolResults
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.output["status"] == "superseded" && !$0.respond })
    }

    @Test func withdrawnCallsGetNoAnswer() async throws {
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [Self.tool("slow") { _ in
            try? await Task.sleep(for: .seconds(30))
            return .status("ok", succeeded: true)
        }])
        let activity = Task { () -> [RealtimeToolActivity] in
            var seen: [RealtimeToolActivity] = []
            for await item in dispatcher.activity {
                seen.append(item)
                if case .withdrawn = item { break }
            }
            return seen
        }
        await dispatcher.handle(Self.call("c1", "slow"), session: session)
        await dispatcher.withdraw(["c1"])
        await dispatcher.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.toolResults.isEmpty)
        #expect(await activity.value == [.started(name: "slow", callID: "c1", label: "Running slow…"), .withdrawn(name: "slow", callID: "c1")])
    }

    @Test func aToolThatTakesTooLongTimesOut() async throws {
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [Self.tool("slow", timeout: .milliseconds(30)) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .status("ok", succeeded: true)
        }])
        await dispatcher.handle(Self.call("c1", "slow"), session: session)
        await dispatcher.waitUntilIdle()
        #expect(session.toolResults.first?.output["status"] == "timed_out")
    }

    // MARK: - The tools

    @Test func captureScreenAttachesThePointersScreen() async throws {
        let tool = RealtimeTools.captureScreen(StaticRealtimeScreenSource(screenshot: Self.shot))
        #expect(tool.name == "capture_screen" && tool.statusLabel == "Looking at your screen…")
        let outcome = await tool.run(RealtimeToolInvocation(callID: "c1", name: "capture_screen", arguments: [:]))
        #expect(outcome.succeeded)
        #expect(outcome.images == [RealtimeImage(data: Self.shot.jpeg, mimeType: "image/jpeg")])
        #expect(outcome.output["status"] == "ok" && outcome.output["screen"] == "main display")
        #expect(outcome.output["width"] == 1280 && outcome.output["height"] == 800)

        let denied = await RealtimeTools.captureScreen(FailingScreen(error: ScreenCaptureError.permissionDenied))
            .run(RealtimeToolInvocation(callID: "c2", name: "capture_screen", arguments: [:]))
        #expect(denied.output["status"] == "unavailable" && denied.images.isEmpty)
        let broken = await RealtimeTools.captureScreen(FailingScreen(error: ScreenCaptureError.noDisplays))
            .run(RealtimeToolInvocation(callID: "c3", name: "capture_screen", arguments: [:]))
        #expect(broken.output["status"] == "failed")
    }

    @Test func aStaticScreenFromAFileIsScaledToTheModelSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rtv-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        try ImageCoding.pngData(context.makeImage()!).write(to: url)
        let source = try StaticRealtimeScreenSource(imageFile: url)
        #expect(source.screenshot.pixelSize == CGSize(width: 1280, height: 800))
        #expect(ImageCoding.pixelSize(of: source.screenshot.jpeg)?.width == 1280)
    }

    @Test func sendToHigherModelRunsABrainTurnWithTheScreenAndReturnsTheLines() async throws {
        let brain = ReplayBrain([
            .status("Thinking…"),
            .programDelta("circle(10, 10, 40);\nsay(\"The reminder is in the middle.\");"),
            .sayLine(index: 0, text: "The reminder is in the middle."),
            .sayLine(index: 1, text: "It says Thursday at four fifteen."),
            .finished(TurnSummary(program: "", spokenLines: [], rounds: 1, usage: nil, model: "m", firstTokenSeconds: nil, totalSeconds: 1)),
        ])
        let observed = ObservedEvents()
        let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: StaticRealtimeScreenSource(screenshot: Self.shot)) {
            observed.add($0)
        }
        #expect(tool.statusLabel == "Thinking deeper…")
        let outcome = await tool.run(RealtimeToolInvocation(callID: "c1", name: "send_to_higher_model",
                                                            arguments: ["question": "Circle the reminder"], userWords: "circle it"))
        #expect(outcome.succeeded)
        #expect(outcome.output["status"] == "answer")
        #expect(outcome.output["answer"] == "The reminder is in the middle. It says Thursday at four fifteen.")
        #expect(outcome.output["drew_on_screen"] == true)
        let input = try #require(brain.inputs.first)
        #expect(input.words == "Circle the reminder")
        #expect(input.screenshots == [Self.shot])
        #expect(input.context.trigger == "realtime_voice")
        #expect(observed.count == 5)

        // Without include_screen there's no picture; without a question the user's words are used.
        _ = await tool.run(RealtimeToolInvocation(callID: "c2", name: "send_to_higher_model",
                                                  arguments: ["include_screen": false], userWords: "what is this"))
        #expect(brain.inputs.last?.screenshots.isEmpty == true)
        #expect(brain.inputs.last?.words == "what is this")
    }

    @Test func sendToHigherModelReportsFailures() async throws {
        let failing = RealtimeTools.sendToHigherModel(brain: ReplayBrain([.failed(spoken: "The brain is offline.", detail: "500")]), screen: nil)
        let failed = await failing.run(RealtimeToolInvocation(callID: "c1", name: "send_to_higher_model", arguments: ["question": "q"]))
        #expect(failed.output["status"] == "failed" && !failed.succeeded)
        #expect(failed.output["message"]?.stringValue?.contains("The brain is offline.") == true)

        let silent = RealtimeTools.sendToHigherModel(brain: ReplayBrain([]), screen: nil)
        #expect(await silent.run(RealtimeToolInvocation(callID: "c2", name: "send_to_higher_model", arguments: ["question": "q"]))
            .output["status"] == "failed")
        let noQuestion = await silent.run(RealtimeToolInvocation(callID: "c3", name: "send_to_higher_model", arguments: [:]))
        #expect(noQuestion.output["status"] == "invalid_request")

        // A newer turn cancels the brain: the dispatcher answers superseded and the brain stops.
        let slowBrain = ReplayBrain([.sayLine(index: 0, text: "late")], delay: .seconds(30))
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: [RealtimeTools.sendToHigherModel(brain: slowBrain, screen: nil)])
        await dispatcher.handle(Self.call("c4", "send_to_higher_model", #"{"question":"q"}"#), session: session)
        await dispatcher.userTurnStarted()
        await dispatcher.waitUntilIdle()
        #expect(session.toolResults.first?.output["status"] == "superseded")
    }

    @Test func drawingProgramsAreToldApartFromSpeech() {
        #expect(!RealtimeTools.programDraws(#"say("Hello there.");"#))
        #expect(!RealtimeTools.programDraws(""))
        #expect(RealtimeTools.programDraws("arrow(1, 2, 3, 4);\nsay(\"Look here\");"))
        #expect(RealtimeTools.programDraws(#"say("a (b)"); label("x")"#))
    }

    @Test func memoryToolsSaveAndRecall() async throws {
        let folder = TemporaryMemoryFolder()
        let tools = RealtimeTools.memory(MemoryTools(store: folder.store()))
        #expect(Set(tools.map(\.name)) == [MemoryTools.save, MemoryTools.recall, MemoryTools.forget])
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: tools)
        await dispatcher.handle(Self.call("c1", MemoryTools.save, #"{"text":"Prefers green tea"}"#), session: session)
        await dispatcher.waitUntilIdle()
        await dispatcher.handle(Self.call("c2", MemoryTools.recall, #"{"query":"tea"}"#), session: session)
        await dispatcher.waitUntilIdle()
        let results = session.toolResults
        #expect(results.count == 2)
        #expect(results[0].output.objectValue != nil)
        #expect(results[1].output.jsonString().contains("green tea"))
    }

    @Test func appActionsWaitUntilTheReplyHasBeenSpoken() async throws {
        let workspace = RecordingWorkspace()
        let toolbox = AppToolbox.standard(AppToolEnvironment(workspace: workspace, pasteboard: RecordingPasteboard(),
                                                             appleScript: ScriptedAppleScriptRunner(), calendar: InMemoryCalendarStore(),
                                                             homeDirectory: URL(fileURLWithPath: "/Users/tester"), sleep: { _ in }))
        let session = FakeRealtimeVoiceSession()
        let dispatcher = RealtimeToolDispatcher(tools: RealtimeTools.appTools(toolbox))
        await dispatcher.handle(Self.call("c1", AppToolName.openURL, #"{"url":"https://example.com"}"#), session: session)
        await dispatcher.handle(Self.call("c2", AppToolName.openURL, #"{"url":"javascript:alert(1)"}"#), session: session)
        await dispatcher.waitUntilIdle()
        #expect(workspace.events.isEmpty)  // nothing opened yet
        #expect(session.toolResults.first { $0.callID == "c1" }?.output["deferred"] == true)
        #expect(session.toolResults.first { $0.callID == "c2" }?.output["status"] == "refused")
        let work = await dispatcher.takeDeferredWork()
        #expect(work.map(\.name) == [AppToolName.openURL])
        #expect(await work[0].run() == nil)
        #expect(workspace.events == [.openInBrowser(URL(string: "https://example.com")!)])
        #expect(await dispatcher.takeDeferredWork().isEmpty)

        // A newer turn drops actions that haven't run.
        await dispatcher.handle(Self.call("c3", AppToolName.openURL, #"{"url":"https://example.org"}"#), session: session)
        await dispatcher.waitUntilIdle()
        await dispatcher.userTurnStarted()
        #expect(await dispatcher.takeDeferredWork().isEmpty)
    }

    @Test func theStandardToolboxLeavesOutWhatIsMissing() {
        #expect(RealtimeToolbox.standard(screen: nil, brain: nil).specs.isEmpty)
        let both = RealtimeToolbox.standard(screen: StaticRealtimeScreenSource(screenshot: Self.shot), brain: ReplayBrain([]))
        #expect(both.specs.map(\.name) == ["capture_screen", "send_to_higher_model"])
        let skip = RealtimeTools.skipInterview { true }
        #expect(skip.name == "skip_onboarding_interview")
    }

    @Test func skippingTheInterview() async {
        let inInterview = RealtimeTools.skipInterview { true }
        #expect(await inInterview.run(RealtimeToolInvocation(callID: "c", name: "skip_onboarding_interview", arguments: [:]))
            .output["status"] == "accepted")
        let notInInterview = RealtimeTools.skipInterview { false }
        #expect(await notInInterview.run(RealtimeToolInvocation(callID: "c", name: "skip_onboarding_interview", arguments: [:]))
            .output["status"] == "not_in_interview")
    }
}

final class ObservedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TurnEvent] = []
    func add(_ event: TurnEvent) { lock.withLock { events.append(event) } }
    var count: Int { lock.withLock { events.count } }
}
