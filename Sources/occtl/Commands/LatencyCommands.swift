import Foundation
import OpenClickyKit

/// `occtl latency`: where a voice turn's wait goes. `latency brain` sends the brain's real first request (the system
/// prompt, tools and a turn message with a screenshot) in a few thinking and effort variants and times each step;
/// `--sizes` counts the prompt's tokens per part. See docs/latency.md.
enum LatencyCommands {
    static let help = """
    Usage:
      occtl latency brain [options] [--words "what does the say hello button do"]

    Sends the brain's first request for one turn, the way `occtl turn` builds it, and times the response head, the
    first event, thinking, the first answer text, the first program text and the first complete say() line.
    Each variant first sends one request that warms the prompt cache (shown as "warm"), then --runs timed ones.

    Options:
      --config c.json      the slots to use (default: your config)
      --image f.png|jpg    the screenshot (default: a blank 1280×800 canvas)
      --app name / --window title   the front app and window in the turn notes
      --words "…"          what the user said (default: what does the say hello button do)
      --runs n             timed requests per variant (default 3)
      --variant v          repeatable; default: configured
                           configured          the brain as the app runs it
                           adaptive-summarized effort low, adaptive thinking, summary streamed (the old default)
                           adaptive-omitted    effort low, adaptive thinking, nothing streamed
                           off                 effort low, thinking off
                           off-default-effort  thinking off, the model's default effort
      --tools none|lookups|memory|all   (default lookups,memory, as occtl turn)
      --no-figures         the prompt without the 3D section
      --sizes              count the prompt's tokens per part (Anthropic's free counting endpoint)
      --out f.json         write every timing and the sizes as JSON
    """

    static let latency = OcctlCommand(name: "latency", usage: "latency brain [--config c] [--image f] [--variant v]… [--sizes]  time the brain's first request (--help)") { args in
        guard args.first == "brain", !args.contains("--help") else { print(help); return }
        try await brain(Array(args.dropFirst()))
    }

    @MainActor
    static func brain(_ args: [String]) async throws {
        var configPath: String?, imagePath: String?, app: String?, window: String?, out: String?
        var words = "what does the say hello button do"
        var runs = 3
        var variants: [String] = []
        var tools = "lookups,memory"
        var figures = true
        var sizes = false
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--config": configPath = value(arg)
            case "--image": imagePath = value(arg)
            case "--app": app = value(arg)
            case "--window": window = value(arg)
            case "--words": words = value(arg)
            case "--runs":
                guard let parsed = Int(value(arg)), parsed > 0 else { fail("--runs wants a count") }
                runs = parsed
            case "--variant": variants.append(value(arg))
            case "--tools": tools = value(arg)
            case "--no-figures": figures = false
            case "--sizes": sizes = true
            case "--out": out = value(arg)
            default: fail("Unknown option \(arg)\n\(help)")
            }
            index += 1
        }
        if variants.isEmpty { variants = ["configured"] }

        let config = try EngineCommands.loadConfig(configPath, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("occtl-latency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let runtime = try TurnCommands.makeBrain(factory: factory, stateRoot: state, tools: tools, figures: figures, fresh: true)
        let client = try factory.languageModel(for: .brain)

        let imageData = try imagePath.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? StillImageScreen.blankCanvas()
        let screen = StillImageScreen(imageData: imageData, context: TurnContext(frontApp: app, windowTitle: window))
        let look = await screen.look()
        let input = TurnInput(words: words, screenshots: look.screenshots, context: look.context, appNotes: look.appNotes)
        let base = await runtime.previewRequest(for: input)
        let configuration = runtime.configuration
        print("→ brain: \(configuration.model) (effort \(configuration.reasoningEffort ?? "default"), thinking \(configuration.thinking?.rawValue ?? "default"))")
        print("→ \(base.tools.count) tools; system prompt \(base.messages.first?.text.count ?? 0) characters")

        var report: [String: JSONValue] = ["model": .string(configuration.model), "words": .string(words)]
        if sizes {
            guard let anthropic = EngineFactory.unwrapped(client) as? AnthropicMessagesClient else { fail("--sizes needs an Anthropic brain (it uses Anthropic's token counter)") }
            let (parts, total) = try await BrainLatencyProbe.promptParts(of: base, sections: await runtime.systemPromptSections(), on: anthropic)
            print("\nprompt: \(total) input tokens")
            for part in parts {
                print("  " + part.name.padding(toLength: 44, withPad: " ", startingAt: 0)
                      + String(format: "%6d tokens  %7d chars", part.tokens, part.characters))
            }
            report["prompt_tokens"] = .number(Double(total))
            report["parts"] = .array(parts.map { ["name": .string($0.name), "tokens": .number(Double($0.tokens)), "chars": .number(Double($0.characters))] })
        }

        var all: [JSONValue] = []
        for name in variants {
            guard let (variantClient, request) = variant(name, base: base, client: client) else { fail("Unknown variant \(name)\n\(help)") }
            print("\nvariant \(name): effort \(request.reasoningEffort ?? "default"), thinking \(request.thinking?.rawValue ?? "default")")
            print("  run    head  event  think→   ←think  text   code  line   done   in/cached/write/out")
            var timings: [BrainLatencyProbe.Timing] = []
            for run in 0...runs {
                let label = run == 0 ? "warm" : "\(run)"
                let timing = await BrainLatencyProbe.time(request, on: variantClient, label: label)
                print("  " + row(timing))
                if let error = timing.error { print("    error: \(error)") }
                if run > 0 { timings.append(timing) }
                all.append(.object(["variant": .string(name), "timing": timing.json]))
            }
            let lines = timings.compactMap(\.firstLineMs).sorted()
            if !lines.isEmpty {
                print("  first say() line: median \(lines[lines.count / 2]) ms (min \(lines.first!), max \(lines.last!))")
                if let program = timings.last?.program { print("  last program:\n" + program.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")) }
            }
        }
        report["runs"] = .array(all)
        if let out {
            try (JSONValue.object(report).jsonString() + "\n").write(toFile: out, atomically: true, encoding: .utf8)
            print("\nwrote \(out)")
        }
    }

    /// A variant's client and request.
    static func variant(_ name: String, base: ChatRequest, client: any LanguageModelClient) -> (any LanguageModelClient, ChatRequest)? {
        var request = base
        switch name {
        case "configured":
            return (client, request)
        case "adaptive-summarized":
            request.reasoningEffort = "low"
            request.thinking = .summarized
            return (client, request)
        case "adaptive-omitted":
            request.reasoningEffort = "low"
            request.thinking = .hidden
            return (client, request)
        case "off":
            request.reasoningEffort = "low"
            request.thinking = .off
            return (client, request)
        case "off-default-effort":
            request.reasoningEffort = nil
            request.thinking = .off
            return (client, request)
        default:
            return nil
        }
    }

    static func row(_ t: BrainLatencyProbe.Timing) -> String {
        func cell(_ value: Int?) -> String { (value.map(String.init) ?? "-").padding(toLength: 7, withPad: " ", startingAt: 0) }
        let usage = t.usage.map { "\($0.inputTokens)/\($0.cachedInputTokens)/\($0.cacheWriteTokens)/\($0.outputTokens)" } ?? "-"
        return t.label.padding(toLength: 6, withPad: " ", startingAt: 0) + cell(t.headersMs) + cell(t.firstEventMs) + cell(t.thinkingStartMs)
            + cell(t.thinkingEndMs) + cell(t.firstTextMs) + cell(t.firstCodeMs) + cell(t.firstLineMs) + cell(t.finishedMs) + usage
            + (t.thinkingCharacters > 0 ? "  (\(t.thinkingCharacters) chars of thinking)" : "")
    }
}
