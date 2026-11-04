import Foundation

/// Plans a drive with Anthropic's computer tool (`AnthropicComputerToolVersion`), through the brain slot's
/// `AnthropicMessagesClient`. Keeps the Messages conversation itself: assistant turns go back exactly as received
/// (thinking blocks included), and each tool_use gets one tool_result, in order, echoing `toolset_name` for the
/// toolset.
///
/// The conversation is append-only. Claude's thinking blocks are bound to everything sent before them ("preserved
/// thinking", enforced with a 400 for accounts created on or after 2026-08-31), and an untouched prefix also keeps
/// the prompt cache warm. Once the conversation holds more than `maxScreenshots` images, all but the newest
/// `keepScreenshots` become a short note, and since that edits earlier turns, every thinking block is dropped from
/// the history on that request (the documented recovery for an edited history).
public actor AnthropicComputerUsePlanner: TakeoverPlanner {
    public nonisolated let label: String
    public let client: AnthropicMessagesClient
    /// The metered brain client `client` came out of, when there is one: steps then go through it, so they count
    /// toward the ledger and stop at a stopping spending limit.
    public let metered: MeteredLanguageModelClient?
    public let model: String
    public let version: AnthropicComputerToolVersion
    public let maxTokens: Int
    public let effort: String?
    public let zoom: Bool
    /// Images kept when old screenshots are dropped.
    public let keepScreenshots: Int
    /// Images the conversation may hold before old screenshots are dropped.
    public let maxScreenshots: Int

    private var messages: [JSONValue] = []
    private var pendingCallIDs: [String] = []
    private var displaySize = (width: 1280, height: 800)

    public init(client: AnthropicMessagesClient, model: String, version: AnthropicComputerToolVersion? = nil, maxTokens: Int = 4096,
                effort: String? = nil, zoom: Bool = true, keepScreenshots: Int = 3, maxScreenshots: Int = 12,
                metered: MeteredLanguageModelClient? = nil) {
        let version = version ?? AnthropicComputerToolVersion.preferred(forModel: model)
        self.client = client
        self.metered = metered
        self.model = model
        self.version = version
        self.maxTokens = maxTokens
        self.effort = effort
        self.zoom = zoom
        self.keepScreenshots = max(1, keepScreenshots)
        self.maxScreenshots = max(self.keepScreenshots, maxScreenshots)
        label = "Anthropic \(version.rawValue) on \(model)"
    }

    public func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
        displaySize = (observation.pixelWidth, observation.pixelHeight)
        messages = [[
            "role": "user",
            "content": [
                ["type": "text", "text": .string(TakeoverPrompts.taskText(brief: brief, observation: observation))],
                Self.imageBlock(DriveImage(observation)),
            ],
        ]]
        pendingCallIDs = []
        return try await step()
    }

    public func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
        // The API rejects a turn that leaves any tool_use unanswered, so every pending call gets exactly one result.
        let byID = Dictionary(results.map { ($0.callID, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [JSONValue] = pendingCallIDs.map { id in
            let result = byID[id] ?? DriveActionResult(callID: id, status: .notExecuted, text: DriveActionResult.notExecutedText)
            return AnthropicMessagesClient.computerToolResult(callID: id, version: version, text: result.text, image: result.image,
                                                              isError: result.isError)
        }
        if blocks.isEmpty {
            blocks = [["type": "text", "text": .string(TakeoverPrompts.screenText(observation))], Self.imageBlock(DriveImage(observation))]
        }
        messages.append(["role": "user", "content": .array(blocks)])
        if imageCount > maxScreenshots {
            pruneScreenshots()
            dropThinking()
        }
        return try await step()
    }

    /// The request the next step would send (for tests and `occtl takeover plan --show-request`).
    public func pendingRequest() -> AnthropicComputerUseRequest { request() }

    private func request() -> AnthropicComputerUseRequest {
        AnthropicComputerUseRequest(model: model, system: TakeoverPrompts.computerToolSystem(), messages: messages, version: version,
                                    displayWidth: displaySize.width, displayHeight: displaySize.height, zoom: zoom, maxTokens: maxTokens,
                                    effort: effort)
    }

    private func step() async throws -> DrivePlan {
        let reply: AnthropicComputerUseReply
        if let metered {
            reply = try await metered.computerUseStep(request(), on: client)
        } else {
            reply = try await client.computerUseStep(request())
        }
        if reply.stopReason == "refusal" {
            // A safety classifier stopped the reply; that is not the model finishing the task.
            throw ProviderError(provider: client.context.provider.id, status: 200,
                                message: "The model declined to continue this drive (stop_reason refusal).")
        }
        if !reply.content.isEmpty { messages.append(["role": "assistant", "content": .array(reply.content)]) }
        pendingCallIDs = reply.toolUses.map(\.id)
        return DrivePlan(narration: reply.text.trimmingCharacters(in: .whitespacesAndNewlines), actions: reply.plannedActions(version),
                         usage: reply.usage, stopReason: reply.stopReason)
    }

    static func imageBlock(_ image: DriveImage) -> JSONValue {
        ["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]]
    }

    /// Replaces every image but the newest `keepScreenshots` with a short note.
    private func pruneScreenshots() {
        var kept = 0
        let note: JSONValue = ["type": "text", "text": "[An earlier screenshot was removed to save space.]"]
        func prune(_ blocks: [JSONValue]) -> [JSONValue] {
            var out = blocks
            for index in out.indices.reversed() {
                if out[index]["type"]?.stringValue == "image" {
                    kept += 1
                    if kept > keepScreenshots { out[index] = note }
                } else if out[index]["type"]?.stringValue == "tool_result", case .object(var result) = out[index],
                          let inner = result["content"]?.arrayValue {
                    result["content"] = .array(prune(inner))
                    out[index] = .object(result)
                }
            }
            return out
        }
        for index in messages.indices.reversed() where messages[index]["role"]?.stringValue == "user" {
            guard case .object(var message) = messages[index], let content = message["content"]?.arrayValue else { continue }
            message["content"] = .array(prune(content))
            messages[index] = .object(message)
        }
    }

    /// Removes `thinking` and `redacted_thinking` blocks from every assistant turn: after an edit to earlier turns
    /// they no longer match the conversation, and replaying them would be refused.
    private func dropThinking() {
        for index in messages.indices where messages[index]["role"]?.stringValue == "assistant" {
            guard case .object(var message) = messages[index], let content = message["content"]?.arrayValue else { continue }
            var kept = content.filter { !["thinking", "redacted_thinking"].contains($0["type"]?.stringValue) }
            guard kept.count != content.count else { continue }
            if kept.isEmpty { kept = [["type": "text", "text": "(no reply text)"]] }
            message["content"] = .array(kept)
            messages[index] = .object(message)
        }
    }

    /// Images currently in the conversation.
    public var imageCount: Int {
        func count(_ value: JSONValue) -> Int {
            if value["type"]?.stringValue == "image" { return 1 }
            if let array = value.arrayValue { return array.map(count).reduce(0, +) }
            if let object = value.objectValue { return object.values.map(count).reduce(0, +) }
            return 0
        }
        return messages.map(count).reduce(0, +)
    }
}

/// Plans a drive with any tool-calling language model: a `computer_actions` function taking a short list of actions
/// (same names and fields as Anthropic's computer tool, plus `element` ids for Accessibility grounding) and a
/// `finish_takeover` function for the report. Each step's result carries a fresh screenshot and the front window's
/// element list.
public actor FunctionCallingDrivePlanner: TakeoverPlanner {
    public nonisolated let label: String
    public let client: any LanguageModelClient
    public let model: String
    public let effort: String?
    public let maxOutputTokens: Int?
    public let keepScreenshots: Int

    private var messages: [ChatMessage] = []
    private var pendingCalls: [ToolCall] = []

    public init(client: any LanguageModelClient, model: String, providerLabel: String = "function calling", effort: String? = nil,
                maxOutputTokens: Int? = 4096, keepScreenshots: Int = 3) {
        self.client = client
        self.model = model
        self.effort = effort
        self.maxOutputTokens = maxOutputTokens
        self.keepScreenshots = max(1, keepScreenshots)
        label = "\(providerLabel) (computer_actions) on \(model)"
    }

    public static let actionsToolName = "computer_actions"
    public static let finishToolName = "finish_takeover"

    public static var tools: [ToolSpec] { [actionsTool, finishTool] }

    static let point: JSONValue = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                                   "description": "[x, y] in pixels of the latest screenshot."]

    public static let actionsTool = ToolSpec(
        name: actionsToolName,
        description: """
        Operate the Mac: run these actions in order, then get a fresh screenshot. Target a control by its element id \
        when it is in the list, else by coordinate. Use super for the Command key.
        """,
        parameters: [
            "type": "object",
            "properties": [
                "actions": [
                    "type": "array", "minItems": 1, "maxItems": 10,
                    "items": [
                        "type": "object",
                        "properties": [
                            "action": ["type": "string", "enum": .array(DriveActionParser.actionNames.map { .string($0) })],
                            "element": ["type": "string", "description": "Element id from the list (e.g. e12), instead of coordinate."],
                            "coordinate": point,
                            "start_element": ["type": "string", "description": "left_click_drag: element to drag from."],
                            "start_coordinate": point,
                            "text": ["type": "string", "description": """
                                type: the text to enter. key, hold_key: a key or combination such as Return, Tab, \
                                super+s. Clicks and scroll: modifier keys to hold, such as shift.
                                """],
                            "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                            "scroll_amount": ["type": "integer", "minimum": 1, "maximum": 30],
                            "repeat": ["type": "integer", "minimum": 1, "maximum": 50],
                            "duration": ["type": "number", "minimum": 0, "maximum": 10, "description": "wait, hold_key: seconds."],
                            "region": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                                       "description": "zoom: [x0, y0, x1, y1] in screenshot pixels."],
                        ],
                        "required": ["action"],
                    ],
                ],
                "note": ["type": "string", "description": "A few words on what these actions are for."],
            ],
            "required": ["actions"],
        ])

    public static let finishTool = ToolSpec(
        name: finishToolName,
        description: "End the drive. report is one or two short, plain sentences for the user: what you did and anything left for them.",
        parameters: [
            "type": "object",
            "properties": [
                "report": ["type": "string"],
                "succeeded": ["type": "boolean", "description": "Whether the task is done."],
            ],
            "required": ["report"],
        ])

    public func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
        messages = [
            .system(TakeoverPrompts.functionCallingSystem()),
            .user(.text(TakeoverPrompts.taskText(brief: brief, observation: observation) + "\n" + TakeoverPrompts.elementsText(observation)),
                  observation.contentPart),
        ]
        pendingCalls = []
        return try await step()
    }

    public func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
        for call in pendingCalls {
            if call.name == Self.actionsToolName {
                let mine = results.filter { $0.callID.hasPrefix(call.id + "#") }
                var lines = mine.enumerated().map { "\($0.offset + 1). \($0.element.status.rawValue): \($0.element.text)" }
                if lines.isEmpty { lines = [DriveActionResult.notExecutedText] }
                lines.append(TakeoverPrompts.screenText(observation))
                lines.append(TakeoverPrompts.elementsText(observation))
                var content: [ContentPart] = [.text(lines.joined(separator: "\n"))]
                // Images from zooms first, then the latest screenshot.
                for result in mine { if let image = result.image, image.data != observation.imageData { content.append(image.contentPart) } }
                content.append(observation.contentPart)
                let failed = !mine.isEmpty && mine.allSatisfy(\.isError)
                messages.append(ChatMessage(role: .tool, content: content, toolCallID: call.id, isError: failed))
            } else {
                messages.append(.tool(callID: call.id, result: "{\"status\":\"not_implemented\",\"message\":\"There is no tool named \(call.name).\"}",
                                      isError: true))
            }
        }
        if pendingCalls.isEmpty {
            messages.append(.user(.text(TakeoverPrompts.screenText(observation) + "\n" + TakeoverPrompts.elementsText(observation)),
                                  observation.contentPart))
        }
        pruneScreenshots()
        return try await step()
    }

    private func step() async throws -> DrivePlan {
        let request = ChatRequest(model: model, messages: messages, tools: Self.tools, reasoningEffort: effort, maxOutputTokens: maxOutputTokens)
        let reply = try await client.completeReply(request)
        messages.append(reply.message)
        pendingCalls = reply.toolCalls
        return Self.plan(from: reply)
    }

    /// Reads a reply into a plan. `finish_takeover` wins over any actions in the same reply.
    static func plan(from reply: ChatReply) -> DrivePlan {
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let finish = reply.toolCalls.first(where: { $0.name == finishToolName }) {
            let arguments = try? JSONValue.parse(finish.arguments)
            let report = arguments?["report"]?.stringValue ?? text
            return DrivePlan(narration: report, actions: [], isFinal: true, succeeded: arguments?["succeeded"]?.boolValue, usage: reply.usage,
                             stopReason: reply.finishReason?.rawValue)
        }
        var actions: [PlannedAction] = []
        for call in reply.toolCalls {
            guard call.name == actionsToolName else {
                actions.append(PlannedAction(callID: call.id + "#0", name: call.name, action: nil, problem: "There is no tool named \(call.name)."))
                continue
            }
            guard let arguments = try? JSONValue.parse(call.arguments), let items = arguments["actions"]?.arrayValue, !items.isEmpty else {
                actions.append(PlannedAction(callID: call.id + "#0", name: actionsToolName, action: nil,
                                             problem: "computer_actions needs an actions array with at least one action."))
                continue
            }
            for (index, item) in items.enumerated() {
                actions.append(PlannedAction.parsing(callID: "\(call.id)#\(index)", name: item["action"]?.stringValue ?? "", input: item))
            }
        }
        return DrivePlan(narration: text, actions: actions, usage: reply.usage, stopReason: reply.finishReason?.rawValue)
    }

    private func pruneScreenshots() {
        var kept = 0
        for index in messages.indices.reversed() {
            var message = messages[index]
            var changed = false
            for part in message.content.indices.reversed() {
                guard case .image = message.content[part] else { continue }
                kept += 1
                if kept > keepScreenshots {
                    message.content[part] = .text("[An earlier screenshot was removed to save space.]")
                    changed = true
                }
            }
            if changed { messages[index] = message }
        }
    }

    /// Images currently in the conversation (for tests).
    public var imageCount: Int {
        messages.flatMap(\.content).filter { if case .image = $0 { true } else { false } }.count
    }
}

/// Which planner a drive uses, and why.
public enum TakeoverPlannerChoice: String, Sendable, Hashable, CaseIterable {
    /// Anthropic's computer tool when the brain slot is on Anthropic's own API, function calling otherwise.
    case automatic = "auto"
    case computerTool = "computer-tool"
    case functionCalling = "functions"
}

extension TakeoverPlannerChoice {
    /// Builds the planner for the brain slot. `.computerTool` requires an `anthropic-messages` provider.
    public func makePlanner(factory: EngineFactory, slot: SlotID = .brain, effort: String? = nil,
                            toolVersion: AnthropicComputerToolVersion? = nil) throws -> any TakeoverPlanner {
        let resolution = try factory.resolve(slot)
        let client = try factory.languageModel(for: slot)
        let model = resolution.selection.model
        let anthropic = EngineFactory.unwrapped(client) as? AnthropicMessagesClient
        let metered = client as? MeteredLanguageModelClient
        switch self {
        case .computerTool:
            guard let anthropic else {
                throw EngineFactoryError.wrongSlot(slot, expected: "an Anthropic Messages model for the computer tool")
            }
            return AnthropicComputerUsePlanner(client: anthropic, model: model, version: toolVersion, effort: effort, metered: metered)
        case .automatic:
            if let anthropic, AnthropicMessagesClient.isAnthropicHost(anthropic.context.provider.baseURL) {
                return AnthropicComputerUsePlanner(client: anthropic, model: model, version: toolVersion, effort: effort, metered: metered)
            }
            return FunctionCallingDrivePlanner(client: client, model: model, providerLabel: resolution.selection.provider, effort: effort)
        case .functionCalling:
            return FunctionCallingDrivePlanner(client: client, model: model, providerLabel: resolution.selection.provider, effort: effort)
        }
    }
}
