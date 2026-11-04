import CoreGraphics
import Foundation
import JavaScriptCore
import QuartzCore

/// How a drawing starts (`__engine.begin(options)` in docs/drawing-contract.md).
public struct DrawingBeginOptions: Sendable, Equatable {
    public enum Pace: String, Sendable {
        /// Hold each line's marks until the voice starts that line, then spread them over it.
        case speech
        /// Draw as soon as each statement has run.
        case now
    }

    /// Canvas size in canvas units (the screenshot the brain saw), x to the right and y down.
    public var width: Double
    public var height: Double
    /// Screen points per canvas unit.
    public var scale: Double
    /// Clicky's ink (the cursor colour), `#RRGGBB`.
    public var ink: String
    /// On-screen windows the program may use for placement, in canvas units: `{x, y, w, h, title?, app?}`.
    public var windows: [JSONValue]
    public var screenshotSize: CGSize?
    public var pace: Pace
    /// Keep what is already on the canvas and continue it (a follow-up turn that edits by part id).
    public var keep: Bool
    /// Wall-clock limit for one top-level statement, in seconds.
    public var timeLimit: TimeInterval
    /// Which of the turn's screenshots (1-based, as the brain saw them numbered) this drawing is on; `onScreen(n)` in
    /// the program is checked against it. Nil: not told.
    public var screen: Int?
    /// False (the default) ends the program at a statement that fails, keeping its longest runnable prefix; true
    /// reports the failing statement and carries on with the next.
    public var continuesAfterErrors = false

    public init(width: Double, height: Double, scale: Double = 1, ink: String = "#3380FF", windows: [JSONValue] = [],
                screenshotSize: CGSize? = nil, pace: Pace = .speech, keep: Bool = false, timeLimit: TimeInterval = 0.4,
                screen: Int? = nil) {
        self.screen = screen
        self.width = width
        self.height = height
        self.scale = scale
        self.ink = ink
        self.windows = windows
        self.screenshotSize = screenshotSize
        self.pace = pace
        self.keep = keep
        self.timeLimit = timeLimit
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "canvas": ["width": .number(width), "height": .number(height), "scale": .number(scale)],
            "ink": .string(ink),
            "windows": .array(windows),
            "pace": .string(pace.rawValue),
            "keep": .bool(keep),
            "timeLimit": .number(timeLimit),
            "afterError": .string(continuesAfterErrors ? "skip" : "cut"),
        ]
        if let screen { object["screen"] = .number(Double(screen)) }
        if let screenshotSize {
            object["screenshotSize"] = [.number(Double(screenshotSize.width)), .number(Double(screenshotSize.height))]
        }
        return .object(object)
    }
}

/// Runs OpenClicky's drawing engine (`Resources/js/draw-engine.js`) on a private JavaScriptCore virtual machine, driven
/// from one serial queue. It installs the host functions the engine may call (`__host.now/log/textWidth/lum/busy/shape3d`), loads the
/// engine, then `draw-*.js` pieces, then every `*-api.js` plugin, feeds program text, and drains events.
///
/// The JavaScript has no network, files or timers. Each top-level statement runs in its own call into the context
/// with a hard time limit (JavaScriptCore's execution watchdog when available, plus the engine's own loop guard).
public final class DrawingEngineHost: @unchecked Sendable {
    public enum Command: Sendable, Equatable {
        case begin(DrawingBeginOptions)
        case append(String)
        case end
        case lineStarted(Int, TimeInterval?)
        case lineFinished(Int)
        case finishNow
        case cancel
        case drain
        /// The user clicked the button mark with this id; the engine answers with an `ask` event.
        case click(String)
        /// The host's answer to a `request` event: merge `fields` into the requested mark and repaint it if shown.
        case patch(ref: String, fields: JSONValue)
        /// Hold the pen (program text keeps arriving); `resume` carries on as if no time had passed.
        case pause
        case resume
        /// The voice has spoken this many words of the answer so far (continuous narration instead of line events).
        case spoken(Int)
    }

    public enum LoadError: Error, CustomStringConvertible {
        case missingEngine
        case script(file: String, message: String)

        public var description: String {
            switch self {
            case .missingEngine: "draw-engine.js is missing from OpenClickyKit's resources"
            case .script(let file, let message): "\(file) failed to load: \(message)"
            }
        }
    }

    public typealias Clock = @Sendable () -> TimeInterval
    /// Mean relative luminance (0…1) of the screen under a canvas rectangle, or nil when unknown.
    public typealias Luminance = @Sendable (CGRect) -> Double?
    /// How busy (0…1: text, controls) the screen is under a canvas rectangle, or nil when unknown.
    public typealias Busyness = @Sendable (CGRect) -> Double?

    private let queue = DispatchQueue(label: "app.openclicky.drawing-engine", qos: .userInteractive)
    private let context: JSContext
    private let engine: JSValue
    private let exceptions: ExceptionBox
    private let watchdogSlack: TimeInterval = 0.15
    private static let loadTimeLimit: TimeInterval = 5
    private var timeLimit: TimeInterval = 0.4
    /// How many programs have begun (confined to `queue`): each `begin` that runs makes the next one current.
    private var program = 0

    /// Names of the scripts loaded, in order.
    public let loadedScripts: [String]
    /// True when JavaScriptCore's execution watchdog backs the per-statement time limit.
    public let hasHardTimeLimit: Bool

    /// Called with a 3D part's kind and canonical recipe as soon as a program's `figure()` part parses, before its line
    /// is heard (`FigureKernel.prewarm`).
    public typealias ShapePrewarm = @Sendable (_ kind: String, _ recipe: String) -> Void

    /// The default prewarm: start building the mesh in the shared kernel the stage reads from.
    public static let sharedKernelPrewarm: ShapePrewarm = { kind, recipe in FigureKernel.shared.prewarm(kind: kind, recipe: recipe) }

    public init(clock: @escaping Clock = { CACurrentMediaTime() }, luminance: Luminance? = nil, busyness: Busyness? = nil,
                log: (@Sendable (String) -> Void)? = nil, scriptDirectory: URL? = nil,
                prewarmShape: ShapePrewarm? = DrawingEngineHost.sharedKernelPrewarm) throws {
        guard let directory = scriptDirectory ?? KitResources.url("draw-engine", "js", in: "js")?.deletingLastPathComponent() else {
            throw LoadError.missingEngine
        }
        let engineURL = directory.appendingPathComponent("draw-engine.js")
        guard FileManager.default.fileExists(atPath: engineURL.path) else { throw LoadError.missingEngine }

        let machine = JSVirtualMachine()!
        let context = JSContext(virtualMachine: machine)!
        context.name = "OpenClicky drawing"
        // JavaScriptCore only guarantees the time limit for code run after it is set, so arm it before any script
        // loads (generously while loading; begin() sets the per-statement limit).
        Self.setExecutionTimeLimit?(JSContextGetGroup(context.jsGlobalContextRef), Self.loadTimeLimit, { _, _ in true }, nil)
        let box = ExceptionBox()
        context.exceptionHandler = { _, value in box.value = value?.toString() ?? "unknown JavaScript error" }

        let host = JSValue(newObjectIn: context)!
        let now: @convention(block) () -> Double = { clock() }
        let logBlock: @convention(block) (String) -> Void = { message in log?(message) }
        let measure: @convention(block) (String, Double, String) -> Double = { text, size, style in
            DrawingFonts.width(of: text, size: size, style: DrawingTextStyle(name: style))
        }
        let lum: @convention(block) (Double, Double, Double, Double) -> Double = { x, y, w, h in
            luminance?(CGRect(x: x, y: y, width: w, height: h)) ?? -1
        }
        let busy: @convention(block) (Double, Double, Double, Double) -> Double = { x, y, w, h in
            busyness?(CGRect(x: x, y: y, width: w, height: h)) ?? -1
        }
        host.setObject(now, forKeyedSubscript: "now" as NSString)
        host.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        host.setObject(measure, forKeyedSubscript: "textWidth" as NSString)
        host.setObject(lum, forKeyedSubscript: "lum" as NSString)
        host.setObject(busy, forKeyedSubscript: "busy" as NSString)
        if let prewarmShape {
            let shape: @convention(block) (String, String) -> Void = { kind, recipe in prewarmShape(kind, recipe) }
            host.setObject(shape, forKeyedSubscript: "shape3d" as NSString)
        }
        context.setObject(host, forKeyedSubscript: "__host" as NSString)

        var scripts = [engineURL]
        let others = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = others.map(\.lastPathComponent)
        scripts += names.filter { $0.hasPrefix("draw-") && $0.hasSuffix(".js") && $0 != "draw-engine.js" }.sorted().map { directory.appendingPathComponent($0) }
        scripts += names.filter { $0.hasSuffix("-api.js") }.sorted().map { directory.appendingPathComponent($0) }
        for url in scripts {
            let source = try String(contentsOf: url, encoding: .utf8)
            box.value = nil
            context.evaluateScript(source, withSourceURL: url)
            if let message = box.value { throw LoadError.script(file: url.lastPathComponent, message: message) }
        }
        guard let engine = context.objectForKeyedSubscript("__engine"), engine.isObject else { throw LoadError.missingEngine }
        engine.setValue(true, forProperty: "stepwise")
        // Takes __engine and __host off the global object and freezes the language's own objects: from here on the
        // host reaches the engine only through this reference, and program code can't reach either.
        box.value = nil
        engine.invokeMethod("sealGlobals", withArguments: [])
        if let message = box.value { throw LoadError.script(file: "draw-engine.js", message: message) }

        self.context = context
        self.engine = engine
        self.exceptions = box
        self.loadedScripts = scripts.map(\.lastPathComponent)
        self.hasHardTimeLimit = Self.setExecutionTimeLimit != nil
        applyTimeLimit(0.4)
    }

    private func applyTimeLimit(_ seconds: TimeInterval) {
        timeLimit = max(0.02, seconds)
        Self.setExecutionTimeLimit?(JSContextGetGroup(context.jsGlobalContextRef), timeLimit + watchdogSlack, { _, _ in true }, nil)
    }

    // MARK: Commands

    /// Run a command and return the events it produced. Safe from any thread except this host's own queue.
    @discardableResult
    public func perform(_ command: Command) -> [DrawingEvent] {
        performRaw(command).compactMap(DrawingEvent.init(json:))
    }

    /// Like `perform`, but returns the events as JSON (marks keep every field the engine wrote).
    public func performRaw(_ command: Command) -> [JSONValue] {
        queue.sync { run(command) }
    }

    /// Run a command on the engine's queue and hand its events (possibly none) to `deliver` on the main queue, in
    /// command order.
    public func send(_ command: Command, deliver: (@MainActor @Sendable ([DrawingEvent]) -> Void)? = nil) {
        queue.async { [self] in
            let events = run(command).compactMap(DrawingEvent.init(json:))
            guard let deliver else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(events) } }
        }
    }

    /// Like `send(_:deliver:)`, and also hands over the number of the program the events came from (1 after the
    /// first `begin` has run, 2 after the next, …). Events reach the main queue after the caller may already have
    /// begun another program, so this tells a late `done` of an earlier program from the current program's.
    public func send(_ command: Command, deliverWithProgram deliver: @escaping @MainActor @Sendable ([DrawingEvent], Int) -> Void) {
        queue.async { [self] in
            let events = run(command).compactMap(DrawingEvent.init(json:))
            let number = program
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(events, number) } }
        }
    }

    /// The card as text for a follow-up turn: each part's id, kind, words and box.
    public func describe() -> String {
        queue.sync { engine.invokeMethod("describe", withArguments: [])?.toString() ?? "" }
    }

    /// The card as the brain should read it on a follow-up turn: only marks already drawn (empty when nothing is), at
    /// most `maxCharacters` long (the oldest parts are folded into one line).
    public func describe(drawnOnly: Bool, maxCharacters: Int) -> String {
        let options: JSONValue = ["drawnOnly": .bool(drawnOnly), "maxChars": .number(Double(max(200, maxCharacters)))]
        return queue.sync { engine.invokeMethod("describe", withArguments: [options.jsonString()])?.toString() ?? "" }
    }

    /// The end-of-drawing report: marks running off the canvas and words overlapping other words, as the engine found
    /// them when the drawing was done (empty before then). Follow-up turns see it in `describe`.
    public func report() -> [String] {
        let text = queue.sync { engine.invokeMethod("reportJSON", withArguments: [])?.toString() ?? "[]" }
        guard let data = text.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// The engine's host-only entry points for what the user does to a drawing (docs/overlay-interaction.md).
    public enum Interaction: Sendable, Equatable {
        /// The cards on screen (`cardsJSON`).
        case cards
        /// Move a card's marks by dx, dy canvas units.
        case moveCard(marks: [String], dx: Double, dy: Double)
        /// Take a card's marks off the screen.
        case closeCard(marks: [String])
        /// What lies under the drawing changed: drop the marks that point at it, keep cards.
        case dropScreenMarks
    }

    /// Run an interaction on the engine's queue; `deliver` gets its JSON result and the events it produced (with the
    /// program number, like `send(_:deliverWithProgram:)`) on the main queue, in order with every other command.
    public func interact(_ interaction: Interaction,
                         deliver: @escaping @MainActor @Sendable (JSONValue?, [DrawingEvent], Int) -> Void) {
        queue.async { [self] in
            let (result, raw) = runInteraction(interaction)
            let events = raw.compactMap(DrawingEvent.init(json:))
            let number = program
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(result, events, number) } }
        }
    }

    /// The same, waiting for the result (tests and tools). Safe from any thread except this host's own queue.
    public func interactNow(_ interaction: Interaction) -> (result: JSONValue?, events: [DrawingEvent]) {
        let (result, raw) = queue.sync { runInteraction(interaction) }
        return (result, raw.compactMap(DrawingEvent.init(json:)))
    }

    private func runInteraction(_ interaction: Interaction) -> (JSONValue?, [JSONValue]) {
        exceptions.value = nil
        let value: JSONValue?
        switch interaction {
        case .cards:
            value = engine.invokeMethod("cardsJSON", withArguments: [])?.toString().flatMap { try? JSONValue.parse($0) }
        case .moveCard(let marks, let dx, let dy):
            let ids = JSONValue.array(marks.map { .string($0) }).jsonString()
            value = engine.invokeMethod("moveCard", withArguments: [ids, dx, dy])?.toString().flatMap { try? JSONValue.parse($0) }
        case .closeCard(let marks):
            let ids = JSONValue.array(marks.map { .string($0) }).jsonString()
            value = engine.invokeMethod("closeCard", withArguments: [ids]).map { .number($0.toDouble()) }
        case .dropScreenMarks:
            value = engine.invokeMethod("dropScreenMarks", withArguments: [])?.toString().flatMap { try? JSONValue.parse($0) }
        }
        let failed = exceptions.value
        var events = drain()
        if let failed { events.append(["type": "warning", "message": .string("drawing engine: \(failed)")]) }
        return (failed == nil ? value : nil, events)
    }

    /// Run `body` on the engine's queue with its JavaScriptCore context, for a plugin's native side: the 3D milestone's
    /// `FigureTickBridge(context:)` runs a figure's ticks this way once per frame. Don't keep the context, and don't call
    /// back into this host from `body` (it would deadlock).
    public func withContext<T>(_ body: (JSContext) throws -> T) rethrows -> T {
        try queue.sync { try body(context) }
    }

    /// Keep the card for a follow-up turn: what was never drawn is dropped, and the card's code so far is returned
    /// (`code` replays the whole card, with `__turn` markers). Begin the next program with `keep: true`.
    public func continueTurn() -> JSONValue? {
        queue.sync {
            guard let text = engine.invokeMethod("continueTurn", withArguments: [])?.toString() else { return nil }
            return try? JSONValue.parse(text)
        }
    }

    /// What the program noted for the host: `{lessonTitle, notes: [{kind, text}], actions}`.
    public func summary() -> JSONValue {
        queue.sync {
            (engine.invokeMethod("summary", withArguments: [])?.toString()).flatMap { try? JSONValue.parse($0) } ?? .null
        }
    }

    /// The beat being heard, for debug captions: `{line, of, text, elapsed, length, chips: [{label, state, late}]}`, or
    /// nil when no line has started.
    public func beats() -> DrawingBeats? {
        queue.sync {
            guard let text = engine.invokeMethod("beats", withArguments: [])?.toString(), let json = try? JSONValue.parse(text) else { return nil }
            return DrawingBeats(json: json)
        }
    }

    /// Spoken lines the engine has seen so far, numbered like `SayLineExtractor`.
    public func spokenLines() -> [String] {
        queue.sync {
            (engine.invokeMethod("lines", withArguments: [])?.toArray() ?? []).compactMap { $0 as? String }
        }
    }

    /// Evaluate JavaScript in the engine's context and return the result as a string (tests and diagnostics).
    /// `__engine` is put back on the global object for the duration of the call.
    func evaluate(_ script: String) -> String? {
        queue.sync {
            exceptions.value = nil
            context.setObject(engine, forKeyedSubscript: "__engine" as NSString)
            defer { context.globalObject.deleteProperty("__engine") }
            let value = context.evaluateScript(script)
            if let error = exceptions.value { return "error: \(error)" }
            return value?.toString()
        }
    }

    // MARK: Running on the queue

    private func run(_ command: Command) -> [JSONValue] {
        exceptions.value = nil
        switch command {
        case .begin(let options):
            program += 1
            applyTimeLimit(options.timeLimit)
            engine.invokeMethod("begin", withArguments: [options.json.jsonString()])
        case .append(let text):
            engine.invokeMethod("append", withArguments: [text])
            runStatements()
        case .end:
            engine.invokeMethod("end", withArguments: [])
            runStatements()
        case .lineStarted(let index, let seconds):
            engine.invokeMethod("lineStarted", withArguments: [index, seconds.map { NSNumber(value: $0) } ?? NSNull()])
        case .lineFinished(let index):
            engine.invokeMethod("lineFinished", withArguments: [index])
        case .finishNow:
            engine.invokeMethod("finishNow", withArguments: [])
        case .cancel:
            engine.invokeMethod("cancel", withArguments: [])
        case .drain:
            break
        case .click(let id):
            engine.invokeMethod("click", withArguments: [id])
        case .patch(let ref, let fields):
            engine.invokeMethod("patch", withArguments: [ref, fields.jsonString()])
        case .pause:
            engine.invokeMethod("pause", withArguments: [])
        case .resume:
            engine.invokeMethod("resume", withArguments: [])
        case .spoken(let words):
            engine.invokeMethod("spoken", withArguments: [words])
        }
        return drain()
    }

    /// One statement per call into JavaScript, so the watchdog limits each statement on its own.
    private func runStatements() {
        var guardCount = 0
        while guardCount < 100_000 {
            guardCount += 1
            exceptions.value = nil
            let more = engine.invokeMethod("runNext", withArguments: [])
            if exceptions.value != nil {
                // The watchdog stopped a statement (or the engine itself failed): report it and carry on.
                exceptions.value = nil
                engine.invokeMethod("recover", withArguments: [])
                // If recovering fails too, the engine itself is broken; retrying would only spin on this queue.
                if exceptions.value != nil { break }
                continue
            }
            if more?.toBool() != true { break }
        }
    }

    private func drain() -> [JSONValue] {
        exceptions.value = nil
        guard let text = engine.invokeMethod("drainJSON", withArguments: [])?.toString(), exceptions.value == nil,
              let value = try? JSONValue.parse(text), let events = value.arrayValue else {
            let message = exceptions.value ?? "the drawing engine returned unreadable events"
            return [["type": "error", "message": .string("drawing engine: \(message)")]]
        }
        return events
    }

    // MARK: JavaScriptCore's execution watchdog

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    /// `JSContextGroupSetExecutionTimeLimit` is exported by JavaScriptCore but declared only in its private headers,
    /// so it is looked up at runtime. Without it the engine's loop guard still stops loops and runaway functions.
    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()
}

private final class ExceptionBox: @unchecked Sendable {
    var value: String?
}


/// The beat being heard and how far its drawing has got (`DrawingEngineHost.beats()`), for the debug captions.
public struct DrawingBeats: Sendable, Hashable {
    public struct Chip: Sendable, Hashable {
        public enum State: String, Sendable { case waiting, drawing, done }
        /// The statement in a few words: what it calls and its first quoted words.
        public var label: String
        public var state: State
        /// Its marks run past the end of the line.
        public var late: Bool
    }

    public var line: Int
    public var lineCount: Int
    public var text: String
    public var elapsed: Double
    public var length: Double?
    public var chips: [Chip]

    public init?(json: JSONValue) {
        guard let line = json["line"]?.intValue else { return nil }
        self.line = line
        lineCount = json["of"]?.intValue ?? 0
        text = json["text"]?.stringValue ?? ""
        elapsed = json["elapsed"]?.doubleValue ?? 0
        length = json["length"]?.doubleValue
        chips = (json["chips"]?.arrayValue ?? []).compactMap { chip in
            guard let label = chip["label"]?.stringValue else { return nil }
            return Chip(label: label, state: Chip.State(rawValue: chip["state"]?.stringValue ?? "") ?? .waiting, late: chip["late"]?.boolValue == true)
        }
    }

    /// "beat 2 of 5 · 1.4 s / 3.2 s"
    public var header: String {
        let length = length.map { String(format: " / %.1f s", $0) } ?? ""
        return "beat \(line + 1) of \(max(lineCount, line + 1)) · " + String(format: "%.1f s", elapsed) + length
    }
}
