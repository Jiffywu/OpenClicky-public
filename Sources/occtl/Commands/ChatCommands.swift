import Foundation
import OpenClickyKit

/// `occtl chat`: stream one reply from a language-model slot, to check a provider end to end.
enum ChatCommands {
    static let chat = OcctlCommand(
        name: "chat",
        usage: "chat [--config c.json] [--slot brain|brain-fast|agent] [--image f.jpg|png] [--effort e] <text>  stream one reply"
    ) { args in
        var configPath: String?
        var slot = SlotID.brain
        var images: [URL] = []
        var effort: String?
        var toolTest = false
        var words: [String] = []
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            switch args[index] {
            case "--config": configPath = value("--config")
            case "--slot":
                let raw = value("--slot")
                guard let parsed = SlotID(rawValue: raw), [.brain, .brainFast, .agent].contains(parsed) else {
                    fail("--slot must be brain, brain-fast or agent")
                }
                slot = parsed
            case "--image": images.append(URL(fileURLWithPath: value("--image")))
            case "--effort": effort = value("--effort")
            case "--tool-test": toolTest = true
            default: words.append(args[index])
            }
            index += 1
        }
        let text = words.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("Usage: occtl chat [--config c.json] [--slot brain|brain-fast|agent] [--image f] [--effort e] <text>") }

        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models),
                                    credentials: CoreCommands.store)
        let resolution = try factory.resolve(slot)
        let client = try factory.languageModel(for: slot)

        var parts: [ContentPart] = []
        for url in images {
            let data = try Data(contentsOf: url)
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            parts.append(.image(data: data, mimeType: mime))
        }
        parts.append(.text(text))
        // --tool-test offers one tool, so a provider's tool-call path can be checked end to end.
        let tools: [ToolSpec] = toolTest ? [ToolSpec(
            name: "point_at",
            description: "Point the user's cursor at an on-screen element.",
            parameters: ["type": "object",
                         "properties": ["label": ["type": "string", "description": "Visible label of the element"],
                                        "x": ["type": "number"], "y": ["type": "number"]],
                         "required": ["label"]])] : []
        let request = ChatRequest(model: resolution.selection.model, messages: [.init(role: .user, content: parts)],
                                  tools: tools, reasoningEffort: effort)

        let started = Date()
        var firstToken: TimeInterval?
        var usage: TokenUsage?
        var finish: FinishReason?
        var reasoningChars = 0
        FileHandle.standardError.write(Data("→ \(slot.rawValue): \(resolution.selection.provider) / \(resolution.selection.model) via \(resolution.adapter ?? "?")\n".utf8))
        for try await event in client.stream(request) {
            switch event {
            case .textDelta(let delta):
                if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                FileHandle.standardOutput.write(Data(delta.utf8))
            case .reasoningDelta(let delta):
                reasoningChars += delta.count
            case .toolCall(let call):
                print("\n[tool call \(call.name) \(call.arguments)]")
            case .usage(let u):
                usage = u
            case .finished(let reason):
                finish = reason
            default:
                break
            }
        }
        let total = Date().timeIntervalSince(started)
        var summary = "\n← \(String(format: "%.2f", total)) s total"
        if let firstToken { summary += ", first text \(String(format: "%.2f", firstToken)) s" }
        if let usage { summary += ", tokens in \(usage.inputTokens) (cached \(usage.cachedInputTokens)) out \(usage.outputTokens)" }
        if reasoningChars > 0 { summary += ", reasoning \(reasoningChars) chars" }
        if let finish { summary += ", finish \(finish.rawValue)" }
        FileHandle.standardError.write(Data((summary + "\n").utf8))
    }
}
