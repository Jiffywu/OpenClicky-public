import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import OpenClickyKit

/// `occtl overlay`: what the user does to a drawing on the overlay, headlessly. A drawing (a program, or the brain's
/// answer) is drawn on an offscreen canvas exactly as the overlay's `DrawingDisplayCanvas` draws it; pointer actions go
/// in as synthesized mouse events on the handle panels (`DrawingHandles`, never shown), through the same routing the app
/// uses; follow-up turns run through the real `TurnOrchestrator` and continue the drawing; the stale watch runs on a
/// synthetic window list. A frame is written after every step, with the handle panels outlined.
enum OverlayCommands {
    static let help = """
    Usage:
      occtl overlay --out-dir <dir> (--program p.js | --ask "words") [options] [actions…]

    Draws a drawing (at once, as a typed answer is drawn) and then does what the user would, in order. Writes to <dir>:
      frame-N.png   the drawing after step N over the screenshot, handle panels outlined (orange: card, blue: button,
                    green: figure), the pointer and its cursor marked
      state-N.txt   what a follow-up turn would read about the drawing (TurnContext.drawingOnScreen)
      turn-N.txt    each brain turn: the words, the drawing it was shown and the program it wrote
      events.txt    every step with its time

    Options:
      --program p.js     draw this program first
      --ask "words"      or ask the brain (needs --config) and draw its answer
      --config c.json    the brain for --ask, --then, and the questions clicks ask (without it they are only printed)
      --image f.png|jpg  the screenshot under the drawing (default: a blank 1280×832 canvas)
      --speak            read answers aloud (written to <dir>/voice.wav, never played): drawings are paced by the voice
      --tools none|lookups|memory|all   the brain's tools (default none)

    Actions (canvas points: screenshot pixels, origin top-left):
      --hover x,y              move the pointer there
      --click x,y              click there
      --drag x1,y1:x2,y2       press, move and let go
      --click-button "words"   click the drawn button whose words contain these ("*": the first button)
      --click-part name        click the 3D figure part with this name, program variable or id ("*": the part that
                               shows the most)
      --turn-figure dx,dy      drag the first figure from its middle
      --drag-card n:dx,dy      drag card n (1 = the first) by dx, dy
      --close-card n           hover card n and click its close box
      --then "words"           a typed follow-up turn (needs --config): it sees the drawing and continues it
      --stale KIND             the screen changes under the drawing: nudge (a 3-point shift, ignored), move, cover,
                               scroll, app or space
      --wait seconds           let time pass
    """

    static let overlay = OcctlCommand(name: "overlay", usage: "overlay --out-dir d (--program p.js | --ask words) [actions…]  click, drag and follow up on a drawing headlessly (--help)") { args in
        if args.isEmpty || args.contains("--help") || args.contains("-h") { print(help); return }
        var options = Options()
        options.parse(args)
        try await run(options)
    }

    enum Action {
        case hover(CGPoint)
        case click(CGPoint)
        case drag(CGPoint, CGPoint)
        case clickButton(String)
        case clickPart(String)
        case turnFigure(CGSize)
        case dragCard(Int, CGSize)
        case closeCard(Int)
        case then(String)
        case stale(String)
        case wait(Double)

        var label: String {
            switch self {
            case .hover(let p): "hover \(Int(p.x)),\(Int(p.y))"
            case .click(let p): "click \(Int(p.x)),\(Int(p.y))"
            case .drag(let a, let b): "drag \(Int(a.x)),\(Int(a.y)) → \(Int(b.x)),\(Int(b.y))"
            case .clickButton(let words): "click the button \"\(words)\""
            case .clickPart(let name): "click the figure part \"\(name)\""
            case .turnFigure(let by): "turn the figure by \(Int(by.width)),\(Int(by.height))"
            case .dragCard(let n, let by): "drag card \(n) by \(Int(by.width)),\(Int(by.height))"
            case .closeCard(let n): "close card \(n)"
            case .then(let words): "follow-up: \(words)"
            case .stale(let kind): "the screen changes: \(kind)"
            case .wait(let seconds): "wait \(seconds) s"
            }
        }
    }

    struct Options {
        var outDir: String?
        var program: String?
        var ask: String?
        var config: String?
        var image: String?
        var speak = false
        var tools = "none"
        var actions: [Action] = []

        mutating func parse(_ args: [String]) {
            var index = 0
            func value(_ flag: String) -> String {
                index += 1
                guard index < args.count else { fail("\(flag) needs a value") }
                return args[index]
            }
            func point(_ text: String, _ flag: String) -> CGPoint {
                let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2 else { fail("\(flag) wants x,y") }
                return CGPoint(x: parts[0], y: parts[1])
            }
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--out-dir": outDir = value(arg)
                case "--program": program = value(arg)
                case "--ask": ask = value(arg)
                case "--config": config = value(arg)
                case "--image": image = value(arg)
                case "--speak": speak = true
                case "--tools": tools = value(arg)
                case "--hover": actions.append(.hover(point(value(arg), arg)))
                case "--click": actions.append(.click(point(value(arg), arg)))
                case "--drag":
                    let ends = value(arg).split(separator: ":").map(String.init)
                    guard ends.count == 2 else { fail("--drag wants x1,y1:x2,y2") }
                    actions.append(.drag(point(ends[0], arg), point(ends[1], arg)))
                case "--click-button": actions.append(.clickButton(value(arg)))
                case "--click-part": actions.append(.clickPart(value(arg)))
                case "--turn-figure":
                    let p = point(value(arg), arg)
                    actions.append(.turnFigure(CGSize(width: p.x, height: p.y)))
                case "--drag-card":
                    let parts = value(arg).split(separator: ":").map(String.init)
                    guard parts.count == 2, let n = Int(parts[0]), n >= 1 else { fail("--drag-card wants n:dx,dy") }
                    let p = point(parts[1], arg)
                    actions.append(.dragCard(n, CGSize(width: p.x, height: p.y)))
                case "--close-card":
                    guard let n = Int(value(arg)), n >= 1 else { fail("--close-card wants a card number (1 = the first)") }
                    actions.append(.closeCard(n))
                case "--then": actions.append(.then(value(arg)))
                case "--stale":
                    let kind = value(arg)
                    guard ["nudge", "move", "cover", "scroll", "app", "space"].contains(kind) else { fail("--stale is nudge, move, cover, scroll, app or space") }
                    actions.append(.stale(kind))
                case "--wait":
                    guard let seconds = Double(value(arg)), seconds >= 0 else { fail("--wait wants seconds") }
                    actions.append(.wait(seconds))
                default:
                    fail("Unknown option \(arg)\n\(help)")
                }
                index += 1
            }
        }
    }

    /// Passes turns to the brain and keeps what each one was given.
    final class RecordingBrain: BrainTurnRunning, @unchecked Sendable {
        let inner: any BrainTurnRunning
        private let lock = NSLock()
        private var _inputs: [TurnInput] = []

        init(_ inner: any BrainTurnRunning) { self.inner = inner }

        var inputs: [TurnInput] { lock.withLock { _inputs } }

        func run(_ input: TurnInput) -> AsyncThrowingStream<TurnEvent, Error> {
            lock.withLock { _inputs.append(input) }
            return inner.run(input)
        }

        func prewarm() async { await inner.prewarm() }
        func recordOutcome(_ note: String) async { await inner.recordOutcome(note) }
        func endSession() async { await inner.endSession() }
    }

    @MainActor
    static func run(_ options: Options) async throws {
        guard let outPath = options.outDir else { fail(help) }
        guard options.program != nil || options.ask != nil else { fail("Give --program or --ask\n\(help)") }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let started = Date()
        var events: [String] = []
        func note(_ text: String) {
            let line = String(format: "%7.3fs  ", Date().timeIntervalSince(started)) + text
            events.append(line)
            print(line)
        }

        // The screen and the canvas, as the overlay's canvas for one display draws it.
        let imageData = try options.image.map { try Data(contentsOf: URL(fileURLWithPath: $0)) } ?? StillImageScreen.blankCanvas(width: 1280, height: 832)
        let screen = StillImageScreen(imageData: imageData, context: TurnContext(frontApp: "TextEdit"))
        guard let shot = screen.screenshot else { fail("\(options.image ?? "the canvas") is not a readable image") }
        let size = shot.pixelSize
        let stage = FigureStage(drivesItself: false)
        let surfaces = CanvasDrawingSurfaces(canvas: DrawingDisplayCanvas(stage: stage))
        let canvas = surfaces.canvas
        canvas.onEvent = { event in
            switch event {
            case .warning(let message): note("drawing warning: \(message)")
            case .error(let message, _): note("drawing error: \(message)")
            case .ask(let text): note("drawing asks: \(text)")
            default: break
            }
        }
        // One display at the origin, the size of the screenshot (AppKit and canvas coordinates differ only in y).
        let displayFrame = CGRect(origin: .zero, size: size)
        let handles = DrawingHandles(showsPanels: false) {
            [DrawingHandles.Display(id: 1, frame: displayFrame, router: canvas.router)]
        }
        handles.onOutcome = { _, outcome in note("outcome: \(describe(outcome))") }

        // The brain, when there is one: typed turns through the real turn loop.
        var orchestrator: TurnOrchestrator?
        var brain: RecordingBrain?
        var runtime: BrainRuntime?
        var speakers: OfflineSpeakers?
        var records: [TurnRecord] = []
        var brainLabel = "none"
        if let config = options.config {
            let loaded = try EngineCommands.loadConfig(config, fallback: .heyClickyLike)
            let factory = EngineFactory(config: loaded, catalog: try ModelCatalog.builtIn().merging(loaded.models), credentials: CoreCommands.store)
            let made = try TurnCommands.makeBrain(factory: factory, stateRoot: out.appendingPathComponent("brain", isDirectory: true),
                                                  tools: options.tools, figures: stage.rendererError == nil, fresh: true)
            runtime = made
            let recording = RecordingBrain(made)
            brain = recording
            let resolution = try factory.resolve(.brain)
            brainLabel = "\(resolution.selection.provider) / \(resolution.selection.model)"
            var narrator: LineNarrator?
            if options.speak {
                let offline = try OfflineSpeakers(url: out.appendingPathComponent("voice.wav"))
                speakers = offline
                let apple = AppleSpeechSynthesisClient(context: ProviderContext(provider: ProviderConfig(id: "apple-voices", dialect: .appleSpeechSynthesis), apiKey: nil))
                narrator = LineNarrator(voice: (try? factory.speechOutput()) ?? apple, fallback: apple, player: offline.player)
                offline.start()
            }
            let services = TurnOrchestrator.Services(microphone: nil, speechToText: { SimulatedSpeechToText(text: "") }, screen: screen,
                                                     brain: recording, narrator: narrator, drawings: surfaces, deferred: made, sessions: made)
            let loop = TurnOrchestrator(services: services, settings: TurnOrchestrator.Settings(speaksTypedAnswers: options.speak))
            loop.onLog = { note("turn: \($0)") }
            loop.onTurnFinished = { records.append($0) }
            orchestrator = loop
        }
        canvas.onAsk = { question in
            if let orchestrator {
                note("typed turn from the click: \(question)")
                orchestrator.submitTyped(question)
            } else {
                note("would ask (no --config): \(question)")
            }
        }
        print("→ brain: \(brainLabel); canvas \(Int(size.width))×\(Int(size.height)); figures \(stage.rendererError == nil ? "on" : "off (\(stage.rendererError.map { "\($0)" } ?? ""))")")

        // MARK: Steps

        var step = 0
        var pointer: (at: CGPoint, cursor: DrawingPointerRouter.Cursor)?
        var turnsWritten = 0

        func settle() async throws {
            // A click's question comes back from the engine as an event: let it arrive (and start its turn) first.
            await canvas.session?.settle()
            try await Task.sleep(for: .milliseconds(100))
            let deadline = Date().addingTimeInterval(240)
            while let orchestrator, orchestrator.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            let drawDeadline = Date().addingTimeInterval(20)
            while canvas.session?.isDrawing == true, Date() < drawDeadline { try await Task.sleep(for: .milliseconds(30)) }
            await canvas.session?.settle()
            await stage.settle()
            try await Task.sleep(for: .milliseconds(900))
            await canvas.session?.settle()
            stage.renderFrame()
            await canvas.router?.refresh()
            handles.sync()
            while turnsWritten < records.count, let brain {
                let record = records[turnsWritten]
                let input = brain.inputs.count > turnsWritten ? brain.inputs[turnsWritten] : nil
                turnsWritten += 1
                var text = "words: \(record.words)\noutcome: \(record.outcome.label)\n"
                text += "\n[the drawing on screen, as the brain was shown it]\n" + (input?.context.drawingOnScreen ?? "(none)") + "\n"
                text += "\n[the program it wrote]\n" + (record.history?.program ?? "") + "\n"
                if !(record.history?.spokenLines ?? []).isEmpty { text += "\n[said]\n" + (record.history?.spokenLines ?? []).joined(separator: "\n") + "\n" }
                try text.write(to: out.appendingPathComponent("turn-\(turnsWritten).txt"), atomically: true, encoding: .utf8)
                note("turn \(turnsWritten) (\(record.words)): \(record.outcome.label); it was shown \(input?.context.drawingOnScreen == nil ? "no drawing" : "the drawing on screen")")
            }
        }

        func frame(_ label: String) throws {
            let name = "frame-\(step).png"
            let state = surfaces.describeOnScreen() ?? "(nothing drawn)"
            try (state + "\n").write(to: out.appendingPathComponent("state-\(step).txt"), atomically: true, encoding: .utf8)
            if let image = try compose(surfaces: surfaces, stage: stage, handles: handles, display: displayFrame, pointer: pointer) {
                try DrawingSnapshot.writePNG(image, to: out.appendingPathComponent(name))
            }
            let regions = canvas.router?.regions() ?? []
            note("frame \(name) after \(label): \(regions.count) handle region(s) " +
                 regions.map { "\($0.target) [\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))]" }.joined(separator: ", "))
            step += 1
        }

        /// A pointer gesture as mouse events on the handle panel under its first point.
        func gesture(_ points: [CGPoint]) async throws {
            guard let first = points.first else { return }
            handles.sync()
            let global = { (p: CGPoint) in CGPoint(x: displayFrame.minX + p.x, y: displayFrame.maxY - p.y) }
            let candidates = handles.panels.values.filter { $0.frame.contains(global(first)) }
            guard let panel = candidates.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                note("no handle at \(Int(first.x)),\(Int(first.y)): the click goes to the app underneath")
                pointer = (first, .arrow)
                return
            }
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                let g = global(p)
                return NSEvent.mouseEvent(with: type, location: CGPoint(x: g.x - panel.frame.minX, y: g.y - panel.frame.minY), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let view = panel.handleView
            if points.count == 1 {
                view.mouseMoved(with: event(.mouseMoved, first))
                pointer = (first, view.cursorShown)
                return
            }
            view.mouseMoved(with: event(.mouseMoved, first))
            view.mouseDown(with: event(.leftMouseDown, first))
            let last = points[points.count - 1]
            for p in points.dropFirst().dropLast() {
                view.mouseDragged(with: event(.leftMouseDragged, p))
                try await Task.sleep(for: .milliseconds(12))
            }
            if points.count > 2 { pointer = (last, view.cursorShown) }
            view.mouseUp(with: event(.leftMouseUp, last))
            pointer = (last, view.cursorShown)
            await canvas.router?.settle()
        }

        func path(_ a: CGPoint, _ b: CGPoint, steps: Int = 12) -> [CGPoint] {
            [a] + (1...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }

        // MARK: The first drawing

        if let path = options.program {
            let program = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            note("drawing \(path)")
            guard let (drawing, _) = surfaces.continuingDrawing(for: shot, image: TurnImages.image(from: shot.jpeg)) else { fail("the drawing engine didn't load") }
            drawing.begin(TurnImages.beginOptions(for: shot, ink: "#3380FF", pace: .now))
            drawing.append(program)
            drawing.end()
        } else if let ask = options.ask {
            guard let orchestrator else { fail("--ask needs --config") }
            note("typed turn: \(ask)")
            orchestrator.submitTyped(ask)
        }
        try await settle()
        try frame("the first drawing")

        // MARK: Actions

        var stale: DrawingStaleMonitor?
        var windows: [ScreenWindow] = []
        var frontApp: (pid: Int32, name: String)? = (4242, "TextEdit")
        for action in options.actions {
            note("→ \(action.label)")
            switch action {
            case .hover(let p):
                try await gesture([p])
            case .click(let p):
                try await gesture([p, p])
            case .drag(let a, let b):
                try await gesture(path(a, b))
            case .clickButton(let words):
                let buttons = canvas.session?.painter.visibleButtons().sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) } ?? []
                guard let button = words == "*" ? buttons.first : buttons.first(where: { $0.text.localizedCaseInsensitiveContains(words) }) else {
                    note("no drawn button says \"\(words)\"")
                    continue
                }
                let middle = CGPoint(x: button.frame.midX, y: button.frame.midY)
                try await gesture([middle])
                try await gesture([middle, middle])
            case .clickPart(let name):
                guard let (figure, point) = findPart(name, stage: stage, session: canvas.session) else {
                    note("no figure part called \"\(name)\" is visible")
                    continue
                }
                note("part \"\(name)\" of \(figure) is under \(Int(point.x)),\(Int(point.y))")
                try await gesture([point])
                try await gesture([point, point])
            case .turnFigure(let by):
                guard let (_, frame) = canvas.session?.painter.figureFrames.sorted(by: { $0.key < $1.key }).first else {
                    note("there is no figure to turn")
                    continue
                }
                let middle = CGPoint(x: frame.midX, y: frame.midY)
                try await gesture(path(middle, CGPoint(x: middle.x + by.width, y: middle.y + by.height)))
                stage.renderFrame()
            case .dragCard(let n, let by):
                guard let router = canvas.router, n <= router.cards.count else {
                    note("there is no card \(n)")
                    continue
                }
                let card = router.cards[n - 1]
                let frame = router.frame(of: card)
                let grabs = [CGPoint(x: frame.midX, y: frame.minY + 14), CGPoint(x: frame.minX + 16, y: frame.maxY - 12),
                             CGPoint(x: frame.midX, y: frame.maxY - 10), CGPoint(x: frame.minX + 12, y: frame.midY)]
                let grab = grabs.first { router.target(at: $0) == .card(card.id) } ?? grabs[0]
                try await gesture([grab])
                try await gesture(path(grab, CGPoint(x: grab.x + by.width, y: grab.y + by.height)))
            case .closeCard(let n):
                guard let router = canvas.router, n <= router.cards.count else {
                    note("there is no card \(n)")
                    continue
                }
                let card = router.cards[n - 1]
                let cardFrame = router.frame(of: card)
                try await gesture([CGPoint(x: cardFrame.midX, y: cardFrame.minY + 10)])
                handles.sync()
                try frame("hovering card \(n) (its close box shows)")
                let box = router.closeBox(of: card)
                try await gesture([CGPoint(x: box.midX, y: box.midY)])
                try await gesture([CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.midX, y: box.midY)])
            case .then(let words):
                guard let orchestrator else {
                    note("--then needs --config")
                    continue
                }
                orchestrator.submitTyped(words)
            case .stale(let kind):
                if stale == nil {
                    windows = [ScreenWindow(number: 10, ownerPID: 4242, ownerName: "TextEdit", bounds: CGRect(x: 60, y: 40, width: size.width - 120, height: size.height - 80))]
                }
                let monitor = stale ?? DrawingStaleMonitor(sources: .init(windows: { windows }, frontApp: { frontApp }),
                                                           ignoring: [ProcessInfo.processInfo.processIdentifier], observesSystem: false)
                if stale == nil || !monitor.isArmed {
                    monitor.arm(area: CGRect(origin: .zero, size: size))
                    note("stale watch armed over TextEdit's window [60,40,\(Int(size.width - 120)),\(Int(size.height - 80))]")
                }
                stale = monitor
                var reason: DrawingStaleReason?
                monitor.onStale = { reason = $0 }
                switch kind {
                case "nudge": windows[0].bounds.origin.x += 3; monitor.poll()
                case "move": windows[0].bounds.origin.x += 60; monitor.poll()
                case "cover": windows.insert(ScreenWindow(number: 11, ownerPID: 5151, ownerName: "Notes", bounds: CGRect(x: 200, y: 150, width: 700, height: 500)), at: 0); monitor.poll()
                case "scroll": for _ in 0..<6 { monitor.scrolled(dx: 0, dy: -20, at: CGPoint(x: size.width / 2, y: size.height / 2)) }
                case "app": frontApp = (5151, "Notes"); monitor.poll()
                default: monitor.spaceChanged()
                }
                if let reason {
                    let drawing = canvas.session?.isDrawing == true
                    let kept = await canvas.screenChanged()
                    note("stale (\(reason)): " + (drawing ? "loose marks removed, the answer goes on" : kept > 0 ? "loose marks removed, \(kept) card(s) kept" : "drawing cleared"))
                    // The next change is a new screen to watch.
                    windows = [ScreenWindow(number: 10, ownerPID: 4242, ownerName: "TextEdit", bounds: CGRect(x: 60, y: 40, width: size.width - 120, height: size.height - 80))]
                    frontApp = (4242, "TextEdit")
                } else {
                    note("stale watch: the drawing still matches the screen")
                }
            case .wait(let seconds):
                try await Task.sleep(for: .seconds(seconds))
            }
            try await settle()
            try frame(action.label)
        }

        if let speakers { try speakers.finish() }
        await runtime?.waitForBackgroundWork()
        try (events.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("events.txt"), atomically: true, encoding: .utf8)
        handles.stop()
        print("wrote \(step) frame(s), state and turn texts and events.txt to \(out.path)")
    }

    static func describe(_ outcome: DrawingPointerRouter.Outcome) -> String {
        switch outcome {
        case .none: "nothing"
        case .asked(let button): "button \(button) asked its question"
        case .figureClicked(let click): "clicked \(click.name) (part \(click.partID)) → \"\(click.question)\""
        case .figureTurned(let figure): "turned \(figure)"
        case .cardMoved(let card, let by): "moved \(card) by \(Int(by.width)),\(Int(by.height)) points"
        case .cardClosed(let card): "closed \(card)"
        }
    }

    /// A point over a visible figure part (by name, program variable or id): the middle of where picking finds it.
    @MainActor
    static func findPart(_ wanted: String, stage: FigureStage, session: DrawingSession?) -> (String, CGPoint)? {
        guard let session else { return nil }
        for (figure, frame) in session.painter.figureFrames.sorted(by: { $0.key < $1.key }) {
            guard let scene = stage.scene(figure) else { continue }
            let ids = scene.nodes.filter { node in
                wanted == "*" || node.id == wanted || node.name == wanted || session.figurePartName(node.id) == wanted
            }.map(\.id)
            guard !ids.isEmpty else { continue }
            var hits: [CGPoint] = []
            var y: CGFloat = 3
            while y < frame.height {
                var x: CGFloat = 3
                while x < frame.width {
                    if let id = stage.hitTest(figure: figure, at: CGPoint(x: x, y: y)), ids.contains(id) { hits.append(CGPoint(x: x, y: y)) }
                    x += 6
                }
                y += 6
            }
            guard !hits.isEmpty else { continue }
            if wanted == "*" {
                // The part that shows the most.
                var counts: [String: Int] = [:]
                for hit in hits { if let id = stage.hitTest(figure: figure, at: hit) { counts[id, default: 0] += 1 } }
                if let top = counts.max(by: { $0.value < $1.value })?.key {
                    hits = hits.filter { stage.hitTest(figure: figure, at: $0) == top }
                }
            }
            let mean = CGPoint(x: hits.map(\.x).reduce(0, +) / CGFloat(hits.count), y: hits.map(\.y).reduce(0, +) / CGFloat(hits.count))
            // The hit nearest the middle (a ring's middle may be empty).
            let best = hits.min { hypot($0.x - mean.x, $0.y - mean.y) < hypot($1.x - mean.x, $1.y - mean.y) } ?? mean
            return (figure, CGPoint(x: frame.minX + best.x, y: frame.minY + best.y))
        }
        return nil
    }

    /// The drawing over the screenshot, its figures, the handle panels outlined and the pointer marked.
    @MainActor
    static func compose(surfaces: CanvasDrawingSurfaces, stage: FigureStage, handles: DrawingHandles, display: CGRect,
                        pointer: (at: CGPoint, cursor: DrawingPointerRouter.Cursor)?) throws -> CGImage? {
        let size = display.size
        let base = try surfaces.snapshot(at: CACurrentMediaTime() + 3)
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        if let base { context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height)) } else if let backdrop = surfaces.backdrop {
            context.draw(backdrop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // y down from here on.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if let session = surfaces.session {
            for (id, frame) in session.painter.figureFrames {
                guard let image = try? stage.image(figure: id) else { continue }
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: frame.size))
                context.restoreGState()
            }
        }
        for (key, panel) in handles.panels {
            let rect = CGRect(x: panel.frame.minX - display.minX, y: display.maxY - panel.frame.maxY, width: panel.frame.width, height: panel.frame.height)
            let colour: CGColor = key.contains("|card ") ? CGColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 0.9)
                : key.contains("|button ") ? CGColor(srgbRed: 0.1, green: 0.45, blue: 1, alpha: 0.9)
                : CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 0.9)
            context.setStrokeColor(colour)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
            if let box = panel.handleView.closeBox {
                DrawingHandleArt.drawCloseBox(in: context, rect: box.offsetBy(dx: rect.minX, dy: rect.minY))
            }
        }
        context.setLineDash(phase: 0, lengths: [])
        if let pointer {
            let p = pointer.at
            context.setFillColor(CGColor(gray: 0, alpha: 0.85))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(1.5)
            let arrow = CGMutablePath()
            arrow.move(to: p)
            arrow.addLine(to: CGPoint(x: p.x, y: p.y + 18))
            arrow.addLine(to: CGPoint(x: p.x + 5, y: p.y + 14))
            arrow.addLine(to: CGPoint(x: p.x + 12, y: p.y + 13))
            arrow.closeSubpath()
            context.addPath(arrow)
            context.drawPath(using: .fillStroke)
            let text = NSAttributedString(string: pointer.cursor.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            let box = CGRect(x: p.x + 14, y: p.y + 18, width: text.size().width + 10, height: text.size().height + 4)
            context.setFillColor(CGColor(gray: 0, alpha: 0.75))
            context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }
}
