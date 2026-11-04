import CoreGraphics
import Foundation
import Testing
@testable import OpenClickyKit

/// `send_to_higher_model` outcomes (#29): the flags the voice model reads, run through the real dispatcher on a fake
/// session; the last `capture_screen` picture reaching the brain; and `insert_text` typing through dictation's inserter.
@Suite(.timeLimit(.minutes(1)))
struct HigherModelOutcomeTests {
    static let shot = BrainFixtures.screenshot(width: 320, height: 200)

    /// A brain script: an optional drawing program, held actions and tools it ran, then the answer.
    static func script(_ answer: String, program: String = "", held: [String] = [], tools: [(String, Bool)] = []) -> [ScriptedBrain.Step] {
        var steps: [ScriptedBrain.Step] = []
        steps.append(.init(delay: 0, event: .programDelta("say(\"\(answer)\")\n" + program)))
        steps.append(.init(delay: 0, event: .sayLine(index: 0, text: answer)))
        for (name, ok) in tools {
            steps.append(.init(delay: 0, event: .toolStarted(name: name, callID: "t-\(name)")))
            steps.append(.init(delay: 0, event: .toolFinished(name: name, callID: "t-\(name)", succeeded: ok)))
        }
        for name in held {
            steps.append(.init(delay: 0, event: .deferredAction(DeferredAction(callID: "h-\(name)", name: name, arguments: ["text": "hello"]))))
        }
        steps.append(.init(delay: 0, event: .finished(TurnSummary(program: "", spokenLines: [answer], rounds: 1, usage: nil, model: "m",
                                                                  firstTokenSeconds: 0, totalSeconds: 0))))
        return steps
    }

    /// Runs one `send_to_higher_model` call through a dispatcher and returns the result object the session got.
    static func dispatch(_ script: [ScriptedBrain.Step], observe: Bool = true, typingRefused: Bool = false,
                         memory: RealtimeCaptureMemory? = nil) async throws -> (output: [String: JSONValue], brain: ScriptedBrain,
                                                                                deferred: [RealtimeDeferredWork]) {
        let brain = ScriptedBrain(trace: VoiceTrace(), scripts: [script])
        var observer: (@Sendable (TurnEvent) -> Void)?
        if observe { observer = { (_: TurnEvent) -> Void in } }
        let refusal = typingRefused
        let refuses: @Sendable () async -> Bool = { () async -> Bool in refusal }
        let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: StaticRealtimeScreenSource(screenshot: shot),
                                                   observe: observer, memory: memory, typingRefused: refuses)
        let dispatcher = RealtimeToolDispatcher(tools: [tool])
        let session = FakeRealtimeVoiceSession()
        await dispatcher.handle(RealtimeToolCall(callID: "c1", name: RealtimeToolName.sendToHigherModel,
                                                 arguments: #"{"question":"help me"}"#), session: session)
        await dispatcher.waitUntilIdle()
        let result = try #require(session.toolResults.first)
        return (result.outputObject, brain, await dispatcher.takeDeferredWork())
    }

    @Test func aPlainAnswerRaisesNoFlags() async throws {
        let (output, _, deferred) = try await Self.dispatch(Self.script("It's the save button."))
        #expect(output["status"] == "answer")
        #expect(output["answer"] == "It's the save button.")
        for flag in ["cursor_animated", "visual_guidance_shown", "text_typed", "copied_to_clipboard", "routed_to_agent", "delivery_refused"] {
            #expect(output[flag] == false, "\(flag)")
        }
        #expect(deferred.isEmpty)
    }

    @Test func aDrawingSetsVisualGuidanceAndAPointAlsoAnimatesTheCursor() async throws {
        let circled = try await Self.dispatch(Self.script("Here.", program: "circle([40, 40], 20)\n")).output
        #expect(circled["visual_guidance_shown"] == true && circled["drew_on_screen"] == true)
        #expect(circled["cursor_animated"] == false)

        let pointed = try await Self.dispatch(Self.script("Click this.", program: "point([120, 80], \"Save\")\n")).output
        #expect(pointed["visual_guidance_shown"] == true)
        #expect(pointed["cursor_animated"] == true)
        #expect(pointed["message"]?.stringValue?.contains("pointing at the spot") == true)

        // Without an overlay to draw on (no observer) nothing is shown, whatever the program says.
        let unseen = try await Self.dispatch(Self.script("Click this.", program: "point([120, 80])\n"), observe: false).output
        #expect(unseen["visual_guidance_shown"] == false && unseen["cursor_animated"] == false)
    }

    @Test func heldTypingAndCopyingAreReportedAndRunAfterTheReply() async throws {
        let (output, brain, deferred) = try await Self.dispatch(Self.script("Done.", held: [InsertTextTool.name, AppToolName.copyToClipboard]))
        #expect(output["text_typed"] == true)
        #expect(output["copied_to_clipboard"] == true)
        #expect(output["delivery_refused"] == false)
        #expect(output["message"]?.stringValue?.contains("typed where their cursor is") == true)
        let work = try #require(deferred.first)
        #expect(work.name == "\(InsertTextTool.name),\(AppToolName.copyToClipboard)")
        #expect(brain.trace.filtered("deferred:").isEmpty)
        _ = await work.run()
        #expect(brain.trace.filtered("deferred:") == ["deferred:insert_text", "deferred:copy_to_clipboard"])
    }

    @Test func typingASecureFieldIsRefusedAndDropped() async throws {
        let (output, brain, deferred) = try await Self.dispatch(Self.script("Typing it.", held: [InsertTextTool.name]), typingRefused: true)
        #expect(output["delivery_refused"] == true)
        #expect(output["text_typed"] == false)
        #expect(output["message"]?.stringValue?.contains("typing was refused") == true)
        #expect(deferred.isEmpty)
        #expect(brain.trace.filtered("deferred:").isEmpty)
    }

    @Test func aJobTheBrainStartedIsReportedAsRoutedToAnAgent() async throws {
        let started = try await Self.dispatch(Self.script("I've started that.", tools: [("sessions_spawn", true)])).output
        #expect(started["routed_to_agent"] == true)
        let failed = try await Self.dispatch(Self.script("That didn't start.", tools: [("sessions_spawn", false)])).output
        #expect(failed["routed_to_agent"] == false)
        let lookup = try await Self.dispatch(Self.script("Found it.", tools: [("web_search", true)])).output
        #expect(lookup["routed_to_agent"] == false)
    }

    // MARK: The last capture reaches the brain

    @Test func theLastCaptureScreenPictureReachesTheBrainRuntime() async throws {
        let memory = RealtimeCaptureMemory()
        let earlier = TurnScreenshot(jpeg: Data([0xFF, 0xD8, 0x01, 0x02, 0x03]), label: "main display", isCursorScreen: true,
                                     pixelSize: CGSize(width: 768, height: 480), displayFrame: CGRect(x: 0, y: 0, width: 768, height: 480))
        let capture = RealtimeTools.captureScreen(StaticRealtimeScreenSource(screenshot: earlier), memory: memory)
        let seen = await capture.run(RealtimeToolInvocation(callID: "cap", name: RealtimeToolName.captureScreen, arguments: [:]))
        #expect(seen.succeeded && seen.images.count == 1)
        #expect(memory.latest?.screenshot.jpeg == earlier.jpeg)

        // The real brain runtime on a scripted model: the request carries the earlier picture as an image part.
        let model = BrainScriptModel([[.text(BrainFixtures.program("say(\"Looks fine.\")")), .finish(.stop)]])
        let runtime = BrainFixtures.runtime(model)
        let tool = RealtimeTools.sendToHigherModel(brain: runtime, screen: nil, memory: memory)
        let outcome = await tool.run(RealtimeToolInvocation(callID: "c2", name: RealtimeToolName.sendToHigherModel,
                                                            arguments: ["question": "is this right?", "include_screen": false]))
        #expect(outcome.succeeded)
        let request = try #require(model.requests.first)
        let user = try #require(request.messages.last)
        let images = user.content.compactMap { if case .image(let data, _) = $0 { data } else { nil } }
        #expect(images.contains(earlier.jpeg))
        #expect(user.text.contains("earlier look the voice took"))
    }

    @Test func aPictureAlreadyInTheFreshLookIsNotSentTwice() async throws {
        let memory = RealtimeCaptureMemory()
        memory.remember(Self.shot)
        let brain = ScriptedBrain(trace: VoiceTrace(), scripts: [Self.script("Same screen.")])
        let tool = RealtimeTools.sendToHigherModel(brain: brain, screen: StaticRealtimeScreenSource(screenshot: Self.shot), memory: memory)
        _ = await tool.run(RealtimeToolInvocation(callID: "c", name: RealtimeToolName.sendToHigherModel, arguments: ["question": "what's this?"]))
        #expect(brain.inputs.first?.screenshots.count == 1)
    }

    // MARK: No picture while a drawing plays

    @Test func captureScreenTakesNoPictureWhileADrawingPlays() async throws {
        let drawing = LockedValue(true)
        let memory = RealtimeCaptureMemory()
        let tool = RealtimeTools.captureScreen(StaticRealtimeScreenSource(screenshot: Self.shot), memory: memory,
                                               isDrawing: { drawing.get() })
        let dispatcher = RealtimeToolDispatcher(tools: [tool])
        let session = FakeRealtimeVoiceSession()
        await dispatcher.handle(RealtimeToolCall(callID: "c1", name: RealtimeToolName.captureScreen, arguments: "{}"), session: session)
        await dispatcher.waitUntilIdle()
        #expect(!session.sent.contains { if case .image = $0 { true } else { false } })
        #expect(session.toolResults.first?.outputObject["status"] == "skipped")
        #expect(session.toolResults.first?.outputObject["message"]?.stringValue?.contains("drawing is playing") == true)
        #expect(memory.latest == nil)

        // Once the drawing is done, the next look attaches the picture again.
        drawing.set(false)
        await dispatcher.handle(RealtimeToolCall(callID: "c2", name: RealtimeToolName.captureScreen, arguments: "{}"), session: session)
        await dispatcher.waitUntilIdle()
        #expect(session.sent.contains { if case .image = $0 { true } else { false } })
        #expect(memory.latest != nil)
    }

    // MARK: insert_text

    @Test func insertTextTypesThroughTheInserterAfterTheNarration() async throws {
        let inserter = TextInserter(system: FakeInsertionSystemForTyping(secure: false))
        let tool = InsertTextTool.make(inserter: inserter)
        #expect(tool.defersUntilNarrationEnds)
        #expect(!tool.isReadOnly)
        let toolbox = AppToolbox([]).adding(tool)
        let call = ToolCall(id: "t1", name: InsertTextTool.name, arguments: #"{"text":"Dear Sam,"}"#)
        guard case .deferUntilNarrationEnds(let action, _) = toolbox.prepare(call) else {
            Issue.record("insert_text should wait for the narration")
            return
        }
        #expect(action.name == InsertTextTool.name)
        let invalid = toolbox.prepare(ToolCall(id: "t2", name: InsertTextTool.name, arguments: #"{"text":"  "}"#))
        if case .finished(let result) = invalid { #expect(result.status == .invalidRequest) } else { Issue.record("blank text is refused") }

        // A refusal or the clipboard fallback reads back plainly.
        let refused = InsertTextTool.result(of: InsertionReport(outcome: .refused(.secureField), attempts: [], insertedText: "x",
                                                                copiedToClipboard: false, target: nil))
        #expect(refused.status == .refused)
        let copied = InsertTextTool.result(of: InsertionReport(outcome: .copiedToClipboard(.noTarget), attempts: [], insertedText: "x",
                                                               copiedToClipboard: true, target: nil))
        #expect(copied.status == .copied && copied.details["typed"] == false)
        #expect(InsertTextTool.wouldRefuse(system: FakeInsertionSystemForTyping(secure: true)))
        #expect(!InsertTextTool.wouldRefuse(system: FakeInsertionSystemForTyping(secure: false)))
    }
}

/// A Mac without a focused field: nothing is trusted to type, Secure Event Input as given.
final class FakeInsertionSystemForTyping: TextInsertionSystem, @unchecked Sendable {
    let secure: Bool
    let pasteboard: any PasteboardAccess = InMemoryPasteboard()
    init(secure: Bool) { self.secure = secure }
    func isAccessibilityTrusted() -> Bool { false }
    func isSecureEventInputEnabled() -> Bool { secure }
    func currentFocus() -> CapturedFocus? { nil }
    func frontmostProcessID() -> Int32? { nil }
    func value(of element: FocusElement) -> String? { nil }
    func setSelectedText(_ text: String, on element: FocusElement) -> Bool { false }
    func setValue(_ value: String, caret: Int, on element: FocusElement) -> Bool { false }
    func postPaste(to processID: Int32) async -> Bool { false }
    func type(_ text: String, to processID: Int32, shiftNewlines: Bool) -> Bool { false }
}
