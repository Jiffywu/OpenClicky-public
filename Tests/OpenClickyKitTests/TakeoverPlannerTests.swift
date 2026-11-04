import Foundation
import Testing
@testable import OpenClickyKit

@Suite("Anthropic computer use")
struct AnthropicComputerUseTests {
    static func client(_ transport: FakeHTTPTransport, headers: [String: String]? = nil) -> AnthropicMessagesClient {
        AnthropicMessagesClient(context: ProviderContext(
            provider: ProviderConfig(id: "anthropic", dialect: .anthropicMessages, baseURL: URL(string: "https://api.anthropic.com"),
                                     credential: "anthropic", headers: headers),
            apiKey: "sk-test-not-real", http: transport))
    }

    /// A toolset reply: some text, then two member calls.
    static let toolsetReply = #"""
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","stop_reason":"tool_use",
     "content":[
      {"type":"thinking","thinking":"","signature":"sig-abc"},
      {"type":"text","text":"I'll click the Title field and type."},
      {"type":"tool_use","id":"toolu_1","name":"left_click","toolset_name":"computer","input":{"coordinate":[410,140]}},
      {"type":"tool_use","id":"toolu_2","name":"type","toolset_name":"computer","input":{"text":"Quarterly plan"}}
     ],
     "usage":{"input_tokens":5200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":120}}
    """#

    static let finalReply = #"""
    {"id":"msg_2","type":"message","role":"assistant","stop_reason":"end_turn",
     "content":[{"type":"text","text":"I typed the title. Press Save when you're ready."}],
     "usage":{"input_tokens":6000,"output_tokens":30}}
    """#

    @Test func picksTheToolVersionForEachModel() {
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-haiku-5-5") == .toolset)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-opus-5-5") == .toolset)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-opus-4-8") == .toolset)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-sonnet-4-6") == .beta20251124)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-opus-4-5-20251101") == .beta20251124)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "claude-haiku-4-5-20251001") == .beta20250124)
        #expect(AnthropicComputerToolVersion.preferred(forModel: "some-future-model") == .toolset)
        #expect(AnthropicComputerToolVersion.toolset.betaHeader == nil)
        #expect(AnthropicComputerToolVersion.beta20251124.betaHeader == "computer-use-2025-11-24")
    }

    @Test func toolsetRequestHasNoBetaHeaderNameOrDisplaySize() throws {
        let fake = FakeHTTPTransport([.body(Self.toolsetReply)])
        let client = Self.client(fake)
        let request = AnthropicComputerUseRequest(model: "claude-haiku-5-5", system: "sys", messages: [["role": "user", "content": "hi"]],
                                                  version: .toolset, displayWidth: 1280, displayHeight: 831, zoom: false)
        let urlRequest = client.computerUseURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-test-not-real")
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        let body = client.computerUseBody(request)
        #expect(body["stream"] == nil)
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool == ["type": "computer_toolset_20260801", "configs": ["zoom": ["enabled": false]]])
        #expect(tool["name"] == nil && tool["display_width_px"] == nil)
        #expect(AnthropicComputerToolVersion.toolset.toolEntry(displayWidth: 1, displayHeight: 1, zoom: true) == ["type": "computer_toolset_20260801"])
    }

    @Test func betaVersionsCarryTheirHeaderAndDisplaySize() {
        let client = Self.client(FakeHTTPTransport([]), headers: ["anthropic-beta": "prompt-caching-x"])
        let request = AnthropicComputerUseRequest(model: "claude-sonnet-4-6", system: "s", messages: [], version: .beta20251124,
                                                  displayWidth: 1280, displayHeight: 800, zoom: true)
        let urlRequest = client.computerUseURLRequest(request)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "prompt-caching-x,computer-use-2025-11-24")
        let tool = client.computerUseBody(request)["tools"]?.arrayValue?.first
        #expect(tool == ["type": "computer_20251124", "name": "computer", "display_width_px": 1280, "display_height_px": 800,
                         "enable_zoom": true])
    }

    @Test func readsToolsetMembersAndBetaActions() {
        let reply = AnthropicComputerUseReply(response: try! JSONValue.parse(Self.toolsetReply))
        #expect(reply.text == "I'll click the Title field and type.")
        #expect(reply.usage?.inputTokens == 5200)
        let actions = reply.plannedActions(.toolset)
        #expect(actions.map(\.callID) == ["toolu_1", "toolu_2"])
        #expect(actions[0].action == .click(at: .pixel(x: 410, y: 140), button: .left, count: 1, modifiers: []))
        #expect(actions[1].action == .type(text: "Quarterly plan"))

        let beta = AnthropicComputerUseReply(content: [
            ["type": "tool_use", "id": "t1", "name": "computer", "input": ["action": "key", "text": "super+s"]],
            ["type": "tool_use", "id": "t2", "name": "bash", "input": ["command": "ls"]],
        ], stopReason: "tool_use", usage: nil)
        let betaActions = beta.plannedActions(.beta20251124)
        #expect(betaActions[0].action == .key(KeyCombo.parse("super+s")!, repeatCount: 1))
        #expect(betaActions[1].action == nil)
        #expect(betaActions[1].problem?.contains("bash") == true)
        // Under the toolset, a block without toolset_name is not a computer action even if its name matches.
        let impostor = AnthropicComputerUseReply(content: [["type": "tool_use", "id": "t", "name": "left_click", "input": [:]]],
                                                 stopReason: nil, usage: nil)
        #expect(impostor.plannedActions(.toolset)[0].action == nil)
    }

    @Test func toolResultsEchoToolsetNameAndCarryImages() {
        let image = DriveImage(data: Data([1, 2, 3]), pixelWidth: 2, pixelHeight: 2)
        let result = AnthropicMessagesClient.computerToolResult(callID: "toolu_1", version: .toolset, text: "Done.", image: image, isError: false)
        #expect(result["toolset_name"] == "computer")
        #expect(result["is_error"] == nil)
        #expect(result["content"]?.arrayValue?.count == 2)
        #expect(result["content"]?.arrayValue?[1]["source"]?["data"] == "AQID")
        let beta = AnthropicMessagesClient.computerToolResult(callID: "t", version: .beta20250124, text: "Refused", image: nil, isError: true)
        #expect(beta["toolset_name"] == nil)
        #expect(beta["is_error"] == true)
    }

    @Test func apiErrorsBecomeProviderErrors() async {
        let fake = FakeHTTPTransport([.body(#"{"type":"error","error":{"type":"invalid_request_error","message":"tools.0: bad"}}"#, status: 400)])
        let request = AnthropicComputerUseRequest(model: "m", system: "s", messages: [], version: .toolset, displayWidth: 1, displayHeight: 1)
        await #expect(throws: ProviderError.self) { try await Self.client(fake).computerUseStep(request) }
        do {
            _ = try await Self.client(FakeHTTPTransport([.body(#"{"type":"error","error":{"type":"invalid_request_error","message":"tools.0: bad"}}"#, status: 400)])).computerUseStep(request)
        } catch let error as ProviderError {
            #expect(error.status == 400)
            #expect(error.message.contains("tools.0: bad"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func plannerKeepsTheConversationAndAnswersEveryCallInOrder() async throws {
        let fake = FakeHTTPTransport([.body(Self.toolsetReply), .body(Self.finalReply)])
        let planner = AnthropicComputerUsePlanner(client: Self.client(fake), model: "claude-haiku-5-5")
        #expect(planner.label == "Anthropic computer_toolset_20260801 on claude-haiku-5-5")
        let observation = TakeoverFixtures.observation()
        let first = try await planner.start(brief: TakeoverBrief(task: "Title it"), observation: observation)
        #expect(first.actions.count == 2 && !first.isFinal)

        let body0 = try fake.jsonBody(0)
        let opening = try #require(body0["messages"]?.arrayValue?.first?["content"]?.arrayValue)
        #expect(opening[0]["text"]?.stringValue?.contains("Task the user approved: Title it") == true)
        #expect(opening[1]["type"] == "image")
        #expect(body0["system"]?.stringValue?.contains("computer tool") == true)

        // Results arrive out of order and one is missing: the planner answers both calls, in the reply's order.
        let results = [DriveActionResult(callID: "toolu_1", status: .refused, text: "Refused: nope")]
        let second = try await planner.next(results: results, observation: observation)
        #expect(second.isFinal)
        #expect(second.narration == "I typed the title. Press Save when you're ready.")

        let messages = try #require(try fake.jsonBody(1)["messages"]?.arrayValue)
        #expect(messages.count == 3)
        // The assistant turn goes back exactly as received, thinking block and all.
        #expect(messages[1]["content"]?.arrayValue?.first?["signature"] == "sig-abc")
        let answers = try #require(messages[2]["content"]?.arrayValue)
        #expect(answers.map { $0["tool_use_id"] } == ["toolu_1", "toolu_2"])
        #expect(answers.allSatisfy { $0["toolset_name"] == "computer" })
        #expect(answers[0]["is_error"] == true)
        #expect(answers[1]["content"]?.arrayValue?.first?["text"]?.stringValue == DriveActionResult.notExecutedText)
    }

    @Test func plannerKeepsOnlyTheNewestScreenshots() async throws {
        let replies = (0..<5).map { index in
            FakeHTTPTransport.Scripted.body(#"{"content":[{"type":"tool_use","id":"t\#(index)","name":"screenshot","toolset_name":"computer","input":{}}],"stop_reason":"tool_use"}"#)
        }
        let planner = AnthropicComputerUsePlanner(client: Self.client(FakeHTTPTransport(replies)), model: "claude-haiku-5-5", keepScreenshots: 2,
                                                  maxScreenshots: 4)
        let observation = TakeoverFixtures.observation()
        var plan = try await planner.start(brief: TakeoverBrief(task: "Look"), observation: observation)
        for _ in 0..<4 {
            let results = plan.actions.map { DriveActionResult(callID: $0.callID, status: .done, text: "Screenshot taken.", image: DriveImage(observation)) }
            plan = try await planner.next(results: results, observation: observation)
        }
        #expect(await planner.imageCount == 2)
    }

    /// A safety refusal is not the model finishing the task: the drive reports it as a failure with the reason.
    @Test func aRefusalEndsTheDriveAsAFailureNotAFinish() async {
        let fake = FakeHTTPTransport([.body(#"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#)])
        let screen = TakeoverCountingScreen()
        let driver = TakeoverDriver(brief: TakeoverBrief(task: "Do it"),
                                    planner: AnthropicComputerUsePlanner(client: Self.client(fake), model: "claude-haiku-5-5"),
                                    screen: screen, actuator: DryRunActuator(), safety: TakeoverSafetyGuard(probe: StaticTakeoverProbe()),
                                    timing: VirtualTiming())
        let report = await driver.run()
        #expect(report.outcome == .failed)
        #expect(report.error?.contains("declined") == true)
        // The brain hears why, so it can tell the user.
        #expect(report.appNote.contains("declined to continue"))
    }

    /// Preserved thinking: a thinking block stays valid only while the system prompt, the tools and every message
    /// before it are unchanged, and enforced accounts get a 400 for replaying one after an edit. So the planner keeps
    /// the conversation append-only, and on the rare request where it does drop old screenshots it sends no
    /// thinking blocks at all.
    @Test func historyIsAppendOnlyAndNeverReplaysThinkingAfterAnEdit() async throws {
        let replies = (0..<12).map { index in
            FakeHTTPTransport.Scripted.body(#"""
            {"content":[{"type":"thinking","thinking":"","signature":"sig-\#(index)"},
             {"type":"tool_use","id":"t\#(index)","name":"screenshot","toolset_name":"computer","input":{}}],"stop_reason":"tool_use"}
            """#)
        }
        let fake = FakeHTTPTransport(replies)
        let planner = AnthropicComputerUsePlanner(client: Self.client(fake), model: "claude-haiku-5-5", keepScreenshots: 2, maxScreenshots: 5)
        let observation = TakeoverFixtures.observation()
        var plan = try await planner.start(brief: TakeoverBrief(task: "Look"), observation: observation)
        for _ in 0..<10 {
            let results = plan.actions.map { DriveActionResult(callID: $0.callID, status: .done, text: "Screenshot taken.", image: DriveImage(observation)) }
            plan = try await planner.next(results: results, observation: observation)
        }

        func thinkingBlocks(_ messages: [JSONValue]) -> Int {
            messages.flatMap { $0["content"]?.arrayValue ?? [] }.filter { ["thinking", "redacted_thinking"].contains($0["type"]?.stringValue) }.count
        }
        func images(_ value: JSONValue) -> Int {
            if value["type"]?.stringValue == "image" { return 1 }
            if let array = value.arrayValue { return array.map(images).reduce(0, +) }
            if let object = value.objectValue { return object.values.map(images).reduce(0, +) }
            return 0
        }
        var edits = 0
        for index in 1..<11 {
            let before = try fake.jsonBody(index - 1), after = try fake.jsonBody(index)
            #expect(before["system"] == after["system"] && before["tools"] == after["tools"])
            let old = try #require(before["messages"]?.arrayValue), new = try #require(after["messages"]?.arrayValue)
            #expect(images(.array(new)) <= 5, "request \(index)")
            if new.count >= old.count, Array(new.prefix(old.count)) == old { continue }
            edits += 1
            #expect(thinkingBlocks(new) == 0, "request \(index) edits earlier turns and replays thinking")
        }
        // Old screenshots were dropped (so the limit holds), but only now and then, not on every step.
        #expect(edits >= 1 && edits <= 3)
        // Between edits, thinking blocks go back unchanged.
        #expect(thinkingBlocks(try #require(try fake.jsonBody(10)["messages"]?.arrayValue)) > 0)
    }
}

@Suite("Function-calling drive planner")
struct FunctionCallingPlannerTests {
    static func call(_ id: String, _ name: String, _ arguments: String) -> [ChatEvent] {
        [.toolCall(ToolCall(id: id, name: name, arguments: arguments)), .finished(.toolCalls)]
    }

    @Test func actionsUseElementIdsAndResultsComeBackWithAScreenshot() async throws {
        let model = TakeoverScriptedModel([
            Self.call("call_1", "computer_actions",
                      #"{"actions":[{"action":"left_click","element":"e2"},{"action":"type","text":"Quarterly plan"},{"action":"key","text":"super+s"}],"note":"title and save"}"#),
            Self.call("call_2", "finish_takeover", #"{"report":"Titled and saved.","succeeded":true}"#),
        ])
        let planner = FunctionCallingDrivePlanner(client: model, model: "openai/gpt-5-nano", providerLabel: "openrouter")
        let observation = TakeoverFixtures.observation()
        let first = try await planner.start(brief: TakeoverBrief(task: "Title and save"), observation: observation)
        #expect(first.actions.map(\.callID) == ["call_1#0", "call_1#1", "call_1#2"])
        #expect(first.actions[0].action == .click(at: .element("e2"), button: .left, count: 1, modifiers: []))

        // The first request lists the elements with their pixel boxes and offers both tools.
        let opening = model.requests[0]
        #expect(opening.tools.map(\.name) == ["computer_actions", "finish_takeover"])
        #expect(opening.messages[1].text.contains("e2 text field \"Title\""))

        let results = first.actions.map { DriveActionResult(callID: $0.callID, status: .done, text: "Done.") }
        let second = try await planner.next(results: results, observation: observation)
        #expect(second.isFinal)
        #expect(second.succeeded == true)
        #expect(second.narration == "Titled and saved.")

        let toolMessage = try #require(model.requests[1].messages.last)
        #expect(toolMessage.role == .tool && toolMessage.toolCallID == "call_1")
        #expect(toolMessage.text.contains("1. done: Done."))
        #expect(toolMessage.content.contains { if case .image = $0 { true } else { false } })
    }

    @Test func badArgumentsBecomeUnreadableActions() {
        var reply = ChatReply()
        reply.apply(.toolCall(ToolCall(id: "c", name: "computer_actions", arguments: #"{"actions":[]}"#)))
        reply.apply(.toolCall(ToolCall(id: "d", name: "open_url", arguments: "{}")))
        let plan = FunctionCallingDrivePlanner.plan(from: reply)
        #expect(plan.actions.count == 2)
        #expect(plan.actions.allSatisfy { $0.action == nil && $0.problem != nil })
        #expect(!plan.isFinal)
    }

    @Test func plainTextReplyEndsTheDrive() async throws {
        let model = TakeoverScriptedModel([[.textDelta("I can't see a Save button."), .finished(.stop)]])
        let planner = FunctionCallingDrivePlanner(client: model, model: "m")
        let plan = try await planner.start(brief: TakeoverBrief(task: "Save"), observation: TakeoverFixtures.observation())
        #expect(plan.isFinal)
        #expect(plan.narration == "I can't see a Save button.")
    }

    @Test func driverRunsTheFunctionCallingPlannerEndToEnd() async {
        let model = TakeoverScriptedModel([
            Self.call("call_1", "computer_actions", #"{"actions":[{"action":"left_click","element":"e3"}]}"#),
            Self.call("call_2", "finish_takeover", #"{"report":"That's a password field, so I left it for you.","succeeded":false}"#),
        ])
        let screen = TakeoverCountingScreen()
        let driver = TakeoverDriver(brief: TakeoverBrief(task: "Log in"), planner: FunctionCallingDrivePlanner(client: model, model: "m"),
                                    screen: screen, actuator: DryRunActuator(),
                                    safety: TakeoverSafetyGuard(probe: StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: screen.observation))),
                                    timing: VirtualTiming())
        let report = await driver.run()
        #expect(report.outcome == .finished)
        #expect(report.succeeded == false)
        #expect(report.refusals == 1)
        let toolMessage = model.requests[1].messages.last
        #expect(toolMessage?.isError == true)
        #expect(toolMessage?.text.contains("password field") == true)
    }
}
