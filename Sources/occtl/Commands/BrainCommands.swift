import CoreGraphics
import Foundation
import ImageIO
import OpenClickyKit

/// `occtl brain ask|show|end`: run real brain turns headlessly (no microphone, screen capture or voice), print the
/// turn events as they arrive and save each turn's drawing program, so `occtl draw` / `occtl figure` can render it.
enum BrainCommands {
    static let help = """
    Usage:
      occtl brain ask [options] <words…>   run one turn and print its events
      occtl brain show [--state dir]       the current session: turns, thread size, compactions
      occtl brain end [--config c] [--state dir]   end the session (writes memory notes on brain-fast)
      occtl brain render <program.js> <out.png> [--size WxH] [--bg image|#RRGGBB] [--look studio|illustrated]
          [--time s]                       draw a whole answer: 2D marks plus its 3D figures composited in place

    Options for ask:
      --config c.json        the slots to use (default: your config)
      --image f.jpg|png      the screenshot of the screen under the pointer (the canvas); repeat for more screens
      --elements f.json      elements to point at: [{"id","role","label","frame":[x,y,w,h]}] in screenshot pixels
      --app name             front app; --window title; --url address; --doc file.txt (document text)
      --selected text        selected text; --note "…" an [App] note; --typed (the words were typed)
      --state dir            where sessions are kept (default ~/Library/Application Support/OpenClicky/Brain)
      --new                  start a fresh session instead of continuing the current one
      --out program.js       where to save the program (default: in the session folder, turn-N.js)
      --effort e             reasoning effort for the brain model (default: low when the model lists it)
      --tools none|lookups|memory|apps|skills|all   what to give the brain, comma-separated (default lookups,memory;
                             memory lives in the state folder and recall also searches the history; apps reads the
                             connected apps and Obsidian vault in connectors.json; skills adds the active skills; all
                             is all four)
      --connectors f.json    connected apps to use with --tools apps (default: your connectors.json)
      --show-prompt          print the system prompt first (skills, connected apps, memory)
      --services f.json      lookup services to use (default: your services.json)
      --hosted-search        with web search "brain-hosted": pass the provider's own search through (experimental)
      --prewarm              warm the provider's prompt cache first, as key-down would
      --no-figures           tell the brain 3D figures are unavailable
      --show-program         also print the program text as it streams
    """

    static let brain = OcctlCommand(name: "brain", usage: "brain ask|show|end [options] <words>  run brain turns headlessly (--help)") { args in
        guard let sub = args.first, sub != "--help", sub != "-h" else { print(help); return }
        if sub == "render" { try await render(Array(args.dropFirst())); return }
        var options = Options()
        options.parse(Array(args.dropFirst()))
        switch sub {
        case "ask": try await ask(options)
        case "show": try show(options)
        case "end": try await end(options)
        default: fail(help)
        }
    }

    struct Options {
        var config: String?
        var images: [String] = []
        var elements: String?
        var app: String?
        var window: String?
        var url: String?
        var document: String?
        var selected: String?
        var notes: [String] = []
        var typed = false
        var state: String?
        var fresh = false
        var out: String?
        var effort: String?
        var tools = "lookups,memory"
        var services: String?
        var hostedSearch = false
        var prewarm = false
        var figures = true
        var showProgram = false
        var showPrompt = false
        var connectors: String?
        var words: [String] = []

        mutating func parse(_ args: [String]) {
            var index = 0
            func value(_ flag: String) -> String {
                index += 1
                guard index < args.count else { fail("\(flag) needs a value") }
                return args[index]
            }
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--config": config = value(arg)
                case "--image": images.append(value(arg))
                case "--elements": elements = value(arg)
                case "--app": app = value(arg)
                case "--window": window = value(arg)
                case "--url": url = value(arg)
                case "--doc": document = value(arg)
                case "--selected": selected = value(arg)
                case "--note": notes.append(value(arg))
                case "--typed": typed = true
                case "--state": state = value(arg)
                case "--new": fresh = true
                case "--out": out = value(arg)
                case "--effort": effort = value(arg)
                case "--tools": tools = value(arg)
                case "--services": services = value(arg)
                case "--hosted-search": hostedSearch = true
                case "--prewarm": prewarm = true
                case "--no-figures": figures = false
                case "--show-program": showProgram = true
                case "--show-prompt": showPrompt = true
                case "--connectors": connectors = value(arg)
                default:
                    if arg.hasPrefix("--") { fail("Unknown option \(arg)\n\(help)") }
                    words.append(arg)
                }
                index += 1
            }
        }

        var store: BrainSessionStore {
            BrainSessionStore(root: state.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? BrainSessionStore.defaultRoot)
        }
    }

    // MARK: ask

    static func ask(_ options: Options) async throws {
        let words = options.words.joined(separator: " ")
        let config = try EngineCommands.loadConfig(options.config, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let store = options.store
        let resolution = try factory.resolve(.brain)
        let wiring = Self.wiring(tools: options.tools, factory: factory, dialect: resolution.provider?.dialect,
                                 memoryDirectory: store.root.appendingPathComponent("memory", isDirectory: true),
                                 services: options.services, hostedSearch: options.hostedSearch, connectors: options.connectors)
        let registry = wiring.tools()
        let effort = options.effort ?? BrainRuntime.defaultEffort(factory: factory, resolution: resolution)
        let runtime = try runtime(factory: factory, wiring: wiring, store: store, resume: !options.fresh, figures: options.figures,
                                  effort: effort)
        if options.showPrompt { print(await runtime.currentSystemPrompt()); print("---") }

        let input = try makeInput(words: words, options: options)
        let session = await runtime.currentSession
        let turnNumber = session.turnCount + 1
        err("→ brain: \(resolution.selection.provider) / \(resolution.selection.model) via \(resolution.adapter ?? "?"), effort \(effort ?? "default"); session \(session.id) turn \(turnNumber)")
        let hosted = registry.hostedTools.compactMap { $0["type"]?.stringValue }.map { "\($0) (hosted)" }
        err("  tools: \(registry.names.isEmpty && hosted.isEmpty ? "none" : (registry.names + hosted).joined(separator: ", "))")
        if options.prewarm {
            let warmStart = Date()
            await runtime.prewarm()
            err(String(format: "  prewarm sent in %.2f s", Date().timeIntervalSince(warmStart)))
        }

        let started = Date()
        func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(started)) }
        var summary: TurnSummary?
        for try await event in runtime.run(input) {
            switch event {
            case .programDelta(let text):
                if options.showProgram { FileHandle.standardOutput.write(Data(text.utf8)) }
            case .sayLine(let index, let text):
                print("\(stamp())  say \(index): \(text)")
            case .status(let text):
                print("\(stamp())  status: \(text)")
            case .toolStarted(let name, let id):
                print("\(stamp())  tool started: \(name) [\(id)]")
            case .toolFinished(let name, let id, let ok):
                print("\(stamp())  tool finished: \(name) [\(id)] \(ok ? "ok" : "failed")")
            case .deferredAction(let action):
                print("\(stamp())  deferred until narration ends (not run by occtl): \(action.name) \(action.arguments.jsonString())")
            case .roundFinished(let round):
                print("\(stamp())  round \(round) finished")
            case .finished(let value):
                summary = value
                var line = "\(stamp())  finished: \(value.spokenLines.count) line(s), \(value.rounds) round(s)"
                if let first = value.firstTokenSeconds { line += String(format: ", first program text %.2f s", first) }
                line += String(format: ", total %.2f s", value.totalSeconds)
                if let usage = value.usage {
                    line += ", tokens in \(usage.inputTokens) (cached \(usage.cachedInputTokens)) out \(usage.outputTokens)"
                }
                print(line)
            case .failed(let spoken, let detail):
                print("\(stamp())  failed: \"\(spoken)\" (\(detail))")
            }
        }
        await runtime.waitForBackgroundWork()
        guard let summary else { exit(1) }
        let destination = options.out.map { URL(fileURLWithPath: $0) }
            ?? store.directory(for: session.id).appendingPathComponent("turn-\(turnNumber).js")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try summary.program.write(to: destination, atomically: true, encoding: .utf8)
        print("program saved to \(destination.path)")
        if let canvas = input.screenshots.first(where: \.isCursorScreen) {
            print("render it: occtl draw \(destination.path) out.png --size \(Int(canvas.pixelSize.width))x\(Int(canvas.pixelSize.height))"
                  + (options.images.first.map { " --bg \($0)" } ?? ""))
        }
    }

    /// The brain runtime occtl runs: the brain slot with `wiring`, compaction and memory notes on brain-fast, sessions
    /// under `store`, and a six-hour idle limit so separate commands continue one session.
    static func runtime(factory: EngineFactory, wiring: BrainWiring, store: BrainSessionStore, resume: Bool = true,
                        figures: Bool = true, effort: String? = nil, thinking: ThinkingMode? = nil) throws -> BrainRuntime {
        let resolution = try factory.resolve(.brain)
        let client = try factory.languageModel(for: .brain)
        var configuration = BrainRuntimeConfiguration(model: resolution.selection.model, dialect: resolution.provider?.dialect,
                                                      reasoningEffort: effort ?? BrainRuntime.defaultEffort(factory: factory, resolution: resolution),
                                                      figuresAvailable: figures, thinking: thinking ?? BrainRuntime.defaultThinking(resolution: resolution))
        configuration.idleTimeout = 6 * 3600
        configuration.pruning = wiring.pruning(configuration.pruning)
        var compactor: BrainCompactor?
        var writer: MemoryWriter?
        if let fast = try? factory.resolve(.brainFast), let fastClient = try? factory.languageModel(for: .brainFast) {
            compactor = BrainCompactor(client: fastClient, model: fast.selection.model)
            writer = try? MemoryWriter(factory: factory)
        }
        return BrainRuntime(client: client, configuration: configuration, tools: wiring.tools(), assembler: try BrainPromptAssembler(),
                            promptOptions: wiring.promptOptions(), store: store,
                            memory: wiring.memory.map { BrainMemory(store: $0, writer: writer) },
                            compactor: compactor, sources: wiring.sources(), resume: resume)
    }

    /// What the brain gets for `--tools`: the same `BrainWiring` the app uses, with memory in `memoryDirectory`
    /// (recall also searches the history occtl uses), lookups, the connected apps in `connectors` and the active skills.
    static func wiring(tools: String, factory: EngineFactory, dialect: ProviderDialect?, memoryDirectory: URL, services: String?,
                       hostedSearch: Bool, connectors: String?) -> BrainWiring {
        let wanted = Set(tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let all = wanted.contains("all")
        var wiring = BrainWiring()
        wiring.apply(FeatureFlagStore())
        if all || wanted.contains("memory") {
            wiring.memory = MemoryStore(directory: memoryDirectory)
            wiring.history = HistoryStore(directory: HistoryCommands.directory)
        }
        if all || wanted.contains("lookups") {
            let servicesURL = services.map { URL(fileURLWithPath: $0) } ?? ServicesConfig.defaultURL
            let lookupServices = LookupServices.make(config: (try? ServicesConfig.load(from: servicesURL)) ?? .defaults,
                                                     credentials: CoreCommands.store)
            let lookups = LookupTools(services: lookupServices)
            wiring.lookups = lookups
            wiring.hostedSearch = ToolRegistry.hostedWebSearch(lookups, dialect: dialect,
                                                               enabled: HostedWebSearch.brainPassesHostedTools || hostedSearch)
        }
        if all || wanted.contains("apps") {
            let url = connectors.map { URL(fileURLWithPath: $0) } ?? ConnectorRegistry.defaultURL
            let registry = (try? ConnectorRegistry.load(from: url)) ?? ConnectorRegistry()
            wiring.connectedApps = ConnectedAppsWiring.make(registry: registry, credentials: CoreCommands.store, factory: factory)
        }
        if all || wanted.contains("skills") { wiring.skills = SkillsCommands.library() }
        return wiring
    }

    static func makeInput(words: String, options: Options) throws -> TurnInput {
        var screenshots: [TurnScreenshot] = []
        var x: CGFloat = 0
        for (index, path) in options.images.enumerated() {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                fail("\(path) is not a readable image")
            }
            // One screenshot pixel per point, displays side by side.
            let frame = CGRect(x: x, y: 0, width: CGFloat(width), height: CGFloat(height))
            x += CGFloat(width)
            screenshots.append(TurnScreenshot(jpeg: data, label: index == 0 ? "main display" : "display \(index + 1) (right)",
                                              isCursorScreen: index == 0, pixelSize: CGSize(width: width, height: height), displayFrame: frame))
        }
        var context = TurnContext(frontApp: options.app, windowTitle: options.window)
        if let url = options.url { context.documentURL = url; context.documentTitle = options.window }
        if let path = options.document { context.documentText = try String(contentsOfFile: path, encoding: .utf8) }
        context.selectedText = options.selected
        if let path = options.elements {
            let json = try JSONValue.parse(String(contentsOfFile: path, encoding: .utf8))
            context.elements = (json.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue, let frame = item["frame"]?.arrayValue?.compactMap(\.doubleValue), frame.count == 4 else { return nil }
                return TurnElement(id: id, role: item["role"]?.stringValue ?? "element", label: item["label"]?.stringValue ?? "",
                                   frame: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]))
            }
        }
        return TurnInput(words: words, isTyped: options.typed, screenshots: screenshots, context: context, appNotes: options.notes)
    }

    // MARK: show / end

    static func show(_ options: Options) throws {
        guard let session = options.store.latest() else { print("No saved sessions in \(options.store.root.path)"); return }
        print("session \(session.id)\(session.ended ? " (ended)" : "")")
        print("  started \(session.startedAt), last turn \(session.lastTurnAt.map { "\($0)" } ?? "never"), \(session.turnCount) turn(s)")
        print("  \(session.items.count) thread item(s), last request \(session.lastInputTokens) input tokens, "
              + "compaction at \(session.nextCompactionCheck), \(session.compactions) compaction(s)")
        for item in session.items {
            let role = item.isSummary ? "summary" : item.message.role.rawValue
            var text = item.words ?? item.message.text
            if !item.message.toolCalls.isEmpty { text += " → " + item.message.toolCalls.map(\.name).joined(separator: ", ") }
            print("  [\(item.seq)] \(role): \(text.replacingOccurrences(of: "\n", with: " ").prefix(140))")
        }
    }

    static func end(_ options: Options) async throws {
        let config = try EngineCommands.loadConfig(options.config, fallback: .heyClickyLike)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let store = options.store
        let memory = MemoryStore(directory: store.root.appendingPathComponent("memory", isDirectory: true))
        let runtime = try BrainRuntime.make(factory: factory, store: store, memoryStore: memory) { $0.idleTimeout = 6 * 3600 }
        let id = await runtime.currentSession.id
        await runtime.endSession()
        print("ended session \(id); memory notes (if any) are in \(memory.directory.path)")
    }

    // MARK: render

    static func render(_ args: [String]) async throws {
        var positional: [String] = []
        var size = (width: 1280.0, height: 832.0)
        var background = "light"
        var look: FigureLook?
        var time = 1.0
        var index = 0
        func value(_ flag: String) -> String {
            index += 1
            guard index < args.count else { fail("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--size":
                guard let parsed = DrawCommands.parseSize(value(arg)) else { fail("--size wants WxH") }
                size = parsed
            case "--bg": background = value(arg)
            case "--look":
                guard let parsed = FigureLook(rawValue: value(arg)) else { fail("--look must be studio or illustrated") }
                look = parsed
            case "--time":
                guard let parsed = Double(value(arg)), parsed >= 0 else { fail("--time wants seconds") }
                time = parsed
            default:
                if arg.hasPrefix("--") { fail("Unknown option \(arg)\n\(help)") }
                positional.append(arg)
            }
            index += 1
        }
        guard positional.count == 2 else { fail(help) }
        let program = try String(contentsOf: URL(fileURLWithPath: positional[0]), encoding: .utf8)
        let output = URL(fileURLWithPath: positional[1])
        let chosenSize = size, chosenBackground = background, chosenLook = look, chosenTime = time
        let report = try await MainActor.run { () throws -> String in
            var options = DrawingRehearsal.Options()
            options.width = chosenSize.width
            options.height = chosenSize.height
            options.backdrop = try DrawCommands.backdrop(chosenBackground)
            let result = try DrawingRehearsal.run(program: program, options: options)
            var lines = ["2D: \(result.lines.count) spoken line(s), \(result.markCount) mark(s)"]
            for warning in result.warnings { lines.append("  warning: \(warning)") }
            for error in result.errors { lines.append("  error: \(error)") }
            // 3D: the 2D rehearsal has no tick bridge yet, so figures run in the figure harness (with stand-ins for
            // the 2D calls) whose ticks pose the parts, then go on top of the 2D image at their rectangles.
            var figures: [(CGImage, CGRect)] = []
            if program.contains("figure(") {
                let harness = try FigureProgramHarness(canvas: CGSize(width: chosenSize.width, height: chosenSize.height))
                harness.context.evaluateScript(twoDStandIns(width: chosenSize.width, height: chosenSize.height))
                let figureMarks = harness.run(program)
                for message in harness.errors { lines.append("  3D error: \(message)") }
                let bridge = harness.tickBridge
                for figure in figureMarks where figure.kind == "figure" {
                    let rect = figure.json["rect"]?.arrayValue?.compactMap(\.doubleValue) ?? []
                    guard rect.count == 4 else { continue }
                    var figureOptions = FigureSnapshot.Options()
                    figureOptions.figureID = figure.id
                    figureOptions.size = CGSize(width: rect[2], height: rect[3])
                    figureOptions.background = nil
                    figureOptions.look = chosenLook
                    figureOptions.time = chosenTime
                    do {
                        let rendered = try FigureSnapshot.render(
                            marks: figureMarks, options: figureOptions,
                            tick: { id, ticks, dt in bridge.runTicks(figure: id, ticks: ticks, dt: dt) },
                            readouts: { bridge.takeReadouts() })
                        let parts = rendered.scene.nodes.filter { !$0.isGroup }.count
                        lines.append("3D: \(figure.id) \(parts) part(s), \(rendered.frame.look.rawValue) look at [\(rect.map { String(Int($0)) }.joined(separator: ", "))], t=\(chosenTime) s")
                        for (part, reason) in rendered.failures.sorted(by: { $0.key < $1.key }) { lines.append("  part \(part) failed: \(reason)") }
                        figures.append((rendered.image, CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])))
                    } catch {
                        lines.append("3D: \(figure.id) failed: \(error)")
                    }
                }
            }
            let base = result.image
            guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("could not composite") }
            context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let sx = Double(base.width) / chosenSize.width, sy = Double(base.height) / chosenSize.height
            for (image, rect) in figures {
                context.draw(image, in: CGRect(x: rect.minX * sx, y: Double(base.height) - rect.maxY * sy,
                                               width: rect.width * sx, height: rect.height * sy))
            }
            guard let composite = context.makeImage() else { fail("could not composite") }
            try DrawingSnapshot.writePNG(composite, to: output)
            lines.insert("Wrote \(positional[1]) (\(composite.width)x\(composite.height))", at: 0)
            return lines.joined(separator: "\n")
        }
        print(report)
    }

    /// Do-nothing versions of the 2D language for the figure harness, so a mixed program's figure statements run.
    static func twoDStandIns(width: Double, height: Double) -> String {
        let names = ["point", "callout", "region", "underline", "check", "cross", "pill", "label", "badge", "highlight", "line",
                     "curve", "arrow", "box", "circle", "ellipse", "dot", "text", "write", "paper", "graph", "timeline", "button",
                     "erase", "move", "moveTo", "recolor", "undo", "clear", "rect", "poly", "path", "image", "photo", "noted", "seen",
                     "plan", "task", "waitForUser", "onScreen", "lessonTitle"]
        let list = names.map { "'\($0)'" }.joined(separator: ",")
        return """
        (function () {
          var g = globalThis;
          function handle() {
            var h = { id: '', part: '', x: 0, y: 0, w: 0, h: 0, cx: 0, cy: 0, left: 0, right: 0, top: 0, bottom: 0 };
            h.plot = h.point = h.line = function () { return h; };
            h.at = function () { return [0, 0]; };
            return h;
          }
          [\(list)].forEach(function (n) { if (typeof g[n] !== 'function') g[n] = function () { return handle(); }; });
          if (typeof g.mid !== 'function') g.mid = function (p, q) { return [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2]; };
          if (typeof g.dist !== 'function') g.dist = function (p, q) { return Math.hypot(p[0] - q[0], p[1] - q[1]); };
          if (typeof g.lerp !== 'function') g.lerp = function (a, b, t) { return a + (b - a) * t; };
          if (typeof g.polar !== 'function') g.polar = function (cx, cy, r, d) { var a = d * Math.PI / 180; return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; };
          if (typeof g.range !== 'function') g.range = function (n) { var a = []; for (var i = 0; i < n; i++) a.push(i); return a; };
          if (typeof g.measure !== 'function') g.measure = function () { return { w: 0, h: 0 }; };
          if (g.W === undefined) g.W = \(Int(width));
          if (g.H === undefined) g.H = \(Int(height));
        })();
        """
    }

    static func err(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
