import Foundation
import Testing
@testable import OpenClickyKit

// The 2D drawing engine (Resources/js/draw-engine.js + draw-pieces.js) running in JavaScriptCore under DrawingEngineHost.

private func makeHost(_ clock: VirtualClock = VirtualClock(), luminance: DrawingEngineHost.Luminance? = nil,
                      directory: URL? = nil) throws -> DrawingEngineHost {
    try DrawingEngineHost(clock: { clock.now }, luminance: luminance, scriptDirectory: directory)
}

private func beginNow(_ host: DrawingEngineHost, width: Double = 1280, height: Double = 832, skippingErrors: Bool = false) -> [DrawingEvent] {
    var options = DrawingBeginOptions(width: width, height: height, pace: .now)
    // A failing statement normally ends the program; the sandbox tests try one refused route per statement.
    options.continuesAfterErrors = skippingErrors
    return host.perform(.begin(options))
}

private func marks(_ events: [DrawingEvent]) -> [DrawingMark] {
    events.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
}

private func errors(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .error(let message, _) = $0 { message } else { nil } }
}

private func warnings(_ events: [DrawingEvent]) -> [String] {
    events.compactMap { if case .warning(let message) = $0 { message } else { nil } }
}

/// Feed a whole program, chunk by chunk, then end it. With a clock, time then runs on so timed edits and `done` arrive.
private func run(_ host: DrawingEngineHost, chunk: Int = .max, clock: VirtualClock? = nil, _ program: String) -> [DrawingEvent] {
    var events: [DrawingEvent] = []
    var index = program.startIndex
    while index < program.endIndex {
        let end = program.index(index, offsetBy: chunk, limitedBy: program.endIndex) ?? program.endIndex
        events += host.perform(.append(String(program[index..<end])))
        index = end
    }
    events += host.perform(.end)
    events += host.perform(.drain)
    if let clock {
        for _ in 0..<60 {
            clock.now += 0.5
            events += host.perform(.drain)
        }
    }
    return events
}

// A program full of things that make statement boundaries hard to find.
private let trickyProgram = """
```js
let n = 0
const pts = [
  [10, 10],
  [200, 40]
]
function bump() { n++; return n }
if (n === 0) {
  bump()
}
else {
  bump(); bump(); bump()
}
const label = `count ${ {a: 1}.a } }`   // a brace inside a template substitution
const re = /;}/g
step(1); say("First; the line.")   // a comment with ; and }
line(pts, { tone: "red" })
;[1, 2].forEach(i => bump())
text(20, 300, "n=" + n
  + "!" + label.length)
const p = pts
  .map(q => [q[0] + 5, q[1]])
for (let i = 0; i < 3; i++) {
  dot(40 + i * 20, 400)
}
/* a block comment; with } braces { */
step(2)
say('Second line')
box(100, 100, 200, 120, { label: "Server" })
```
"""

@Test func streamingOneCharacterAtATimeRunsEachStatementOnce() throws {
    let whole = try makeHost()
    _ = beginNow(whole)
    let wholeEvents = run(whole, trickyProgram)
    #expect(errors(wholeEvents).isEmpty, "\(errors(wholeEvents))")

    let streamed = try makeHost()
    _ = beginNow(streamed)
    let streamedEvents = run(streamed, chunk: 1, trickyProgram)
    #expect(errors(streamedEvents).isEmpty, "\(errors(streamedEvents))")

    let a = marks(wholeEvents), b = marks(streamedEvents)
    #expect(a.map(\.kind) == ["line", "text", "dot", "dot", "dot", "box", "text"])
    #expect(a.map(\.json) == b.map(\.json))
    // The if-branch ran once (1) and the forEach twice (2): every statement ran exactly once.
    let words = a.first { $0.kind == "text" }?.json["text"]?.stringValue
    #expect(words == "n=3!9")
}

@Test func splitterFindsTheSameStatementsAtAnyChunkSize() throws {
    let host = try makeHost()
    let source = trickyProgram.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "$", with: "\\$")
    let script = """
    (function () {
      var src = `\(source)`;
      function split(chunk) {
        var s = new __engine._internals.Splitter(), out = [];
        for (var i = 0; i < src.length; i += chunk) {
          s.push(src.slice(i, i + chunk));
          out = out.concat(s.take().map(function (r) { return s.slice(r.s, r.e).trim(); }));
        }
        s.finish();
        out = out.concat(s.take().map(function (r) { return s.slice(r.s, r.e).trim(); }));
        return out.filter(function (t) { return t.length; });
      }
      return JSON.stringify([1, 2, 5, 13, 100000].map(split));
    })()
    """
    let json = try #require(host.evaluate(script))
    let results = try #require(try JSONValue.parse(json).arrayValue).map { $0.arrayValue?.compactMap(\.stringValue) ?? [] }
    for result in results { #expect(result == results[results.count - 1]) }
    let statements = results[0]
    #expect(statements.contains("let n = 0"))
    #expect(statements.contains { $0.hasPrefix("if (n === 0) {") && $0.hasSuffix("bump(); bump(); bump()\n}") })
    #expect(statements.contains("step(1);"))
    #expect(statements.contains { $0.hasPrefix("text(20, 300,") && $0.hasSuffix("label.length)") })
    #expect(statements.contains { $0.hasPrefix("const p = pts") && $0.contains(".map(") })
    #expect(!statements.contains { $0.contains("```") })
}

@Test func sayLinesAndStepsAreNumberedLikeSayLineExtractor() throws {
    let program = """
    ```js
    step(1)
    say("Hello there.")
    // say("not spoken: a comment")
    const note = "say(\\"not spoken: a string\\")"
    obj = { say: function () {} }; obj.say("not spoken: a member call")
    function intro() { say('From a helper.') }
    box(100, 100, 200, 100)
    step(2)
    say(`A template line.`)
    circle(500, 300, 40)
    intro()
    arrow([300, 150], [460, 290])
    step(3)
    say("Read [the docs](https://example.com/docs) now.")
    for (const k of [0, 1]) { say("Again and again.") ; dot(700 + k * 30, 500) }
    say(`Not ahead of time: ${1 + 1}`)
    text(40, 600, "done")
    ```
    """
    var extractor = SayLineExtractor()
    var extracted: [SayLineExtractor.Line] = []
    let clock = VirtualClock()
    let host = try makeHost(clock)
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech)))
    for character in program {
        extracted += extractor.feed(String(character))
        events += host.perform(.append(String(character)))
    }
    events += host.perform(.end)
    #expect(errors(events).isEmpty, "\(errors(events))")
    #expect(host.spokenLines() == extracted.map(\.raw))
    #expect(extracted.count == 5)
    // Nothing is drawn before the voice starts the first line.
    #expect(marks(events).isEmpty)
    // A say() whose words are only known at run time can't be spoken ahead, so the engine says so.
    #expect(warnings(events).contains { $0.hasPrefix("say() is spoken only when its words are a plain string") })

    var lineOfMark: [String: Int] = [:]
    var stepEvents: [Int] = []
    var all: [DrawingEvent] = []
    for index in extracted.indices {
        clock.now += 0.5
        events = host.perform(.lineStarted(index, 2.0))
        clock.now += 2.0
        events += host.perform(.drain)
        events += host.perform(.lineFinished(index))
        all += events
        for event in events {
            if case .step(let step) = event { stepEvents.append(step) }
            if case .marks(let ms) = event {
                for mark in ms {
                    lineOfMark[mark.id] = mark.json["line"]?.intValue
                    #expect(mark.start >= 0 && mark.start <= 2.0, "\(mark.kind) starts at \(mark.start)")
                }
            }
        }
    }
    clock.now += 1
    all += host.perform(.drain)
    #expect(all.filter { $0 == .done }.count == 1)
    #expect(stepEvents == [1, 2, 3])

    // Numbering follows the text, as SayLineExtractor reads it: 0 Hello, 1 From a helper (spoken where the helper is
    // defined), 2 A template line, 3 Read the docs, 4 Again and again. The box draws during line 0, the circle during
    // line 2, the arrow during line 1 (intro() runs the helper's say just before it), and the dots and the last words
    // during line 4 (the loop's second say repeats words already spoken).
    #expect(extracted.map(\.text) == ["Hello there.", "From a helper.", "A template line.", "Read the docs now.", "Again and again."])
    #expect(lineOfMark.values.sorted() == [0, 1, 2, 4, 4, 4])
    #expect(warnings(all).isEmpty)
}

@Test func sandboxRefusesNetworkFilesAndTimers() throws {
    let host = try makeHost()
    _ = beginNow(host, skippingErrors: true)
    let events = run(host, """
    fetch("https://example.com/")
    new XMLHttpRequest()
    new WebSocket("wss://example.com/")
    setTimeout(function () {}, 0)
    require("fs")
    importScripts("https://example.com/x.js")
    text(10, 40, [typeof globalThis.fetch, typeof globalThis.XMLHttpRequest, typeof globalThis.WebSocket, typeof globalThis.setTimeout, typeof __host, typeof __engine].join(","))
    """)
    let refused = errors(events)
    #expect(refused.count == 6)
    #expect(refused.allSatisfy { $0.contains("not available in drawings") })
    #expect(marks(events).first?.json["text"]?.stringValue == "undefined,undefined,undefined,undefined,undefined,undefined")
}

@Test func programsCannotReachTheEngineOrTheHostThroughTheGlobalObject() throws {
    let host = try makeHost()
    _ = beginNow(host, skippingErrors: true)
    // Each route to the global object, then an attempt to click the program's own button: an `ask` becomes a typed
    // turn, so a program that could click would start turns the user never asked for.
    let events = run(host, """
    const b = button(100, 100, "Go", { ask: "Do something I did not ask for" })
    globalThis.__engine.click(b.id)
    this.__engine.click(b.id)
    Function("return this")().__engine.click(b.id)
    ;(function () { return this })().__engine.click(b.id)
    text(10, 40, [typeof globalThis.__engine, typeof globalThis.__host, typeof Function("return this")().__host].join(","))
    """)
    #expect(!events.contains { if case .ask = $0 { true } else { false } })
    #expect(errors(events).count == 4, "\(errors(events))")
    #expect(marks(events).first { $0.kind == "text" }?.json["text"]?.stringValue == "undefined,undefined,undefined")
    // The host still drives the engine, and a real click still asks.
    #expect(host.perform(.click("m1")).contains(.ask("Do something I did not ask for")))
    #expect(host.spokenLines().isEmpty)
}

@Test func oneProgramCannotBreakTheEngineForTheNext() throws {
    let host = try makeHost()
    _ = beginNow(host)
    let first = run(host, """
    Object.prototype.do = "button"
    Object.prototype.queue = null
    Array.prototype.map = function () { return [] }
    Array.prototype.forEach = null
    String.prototype.trim = function () { return "" }
    JSON.stringify = function () { return "[]" }
    globalThis.JSON = null
    globalThis.Object = null
    Math.max = function () { return 0 }
    box(100, 100, 200, 100, { label: "First" })
    """)
    // Changing the language's own objects quietly does nothing, so the first program still draws.
    #expect(errors(first).isEmpty, "\(errors(first))")
    #expect(marks(first).map(\.kind) == ["box", "text"])

    _ = beginNow(host)
    let second = run(host, """
    say("Second.")
    box(100, 100, 200, 100, { label: "Server" })
    arrow([320, 150], [500, 150], { label: "calls" })
    text(40, 400, "  still here  ")
    """)
    #expect(errors(second).isEmpty, "\(errors(second))")
    #expect(marks(second).map(\.kind) == ["box", "text", "arrow", "text", "text"])
    #expect(marks(second).last?.json["text"]?.stringValue == "  still here  ")
    #expect(host.spokenLines() == ["Second."])
}

@Test func aBrokenEngineIsReportedInsteadOfRetriedForever() throws {
    let host = try makeHost()
    _ = beginNow(host)
    // Stand-in for an engine bug: every statement and every recovery throws.
    _ = host.evaluate("""
    (function (e) {
      e.calls = 0;
      e.runNext = function () { e.calls++; throw new Error('engine bug'); };
      e.recover = function () { throw new Error('still broken'); };
    })(__engine)
    """)
    let started = Date()
    let events = host.perform(.append("dot(10, 10)\ndot(20, 20)\n"))
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(host.evaluate("__engine.calls") == "1")
    #expect(marks(events).isEmpty)
}

@Test func timeLimitStopsAnInfiniteLoopAndTheProgramGoesOn() throws {
    let host = try makeHost()
    var limited = DrawingBeginOptions(width: 1280, height: 832, pace: .now, timeLimit: 0.2)
    limited.continuesAfterErrors = true
    _ = host.perform(.begin(limited))
    let started = Date()
    let events = run(host, """
    dot(10, 10)
    while (true) {}
    for (;;) { let x = 1 }
    const spin = () => { spin2() }; function spin2() { for (let i = 0; ; i++) {} }
    spin()
    dot(20, 20)
    """)
    let elapsed = Date().timeIntervalSince(started)
    let stopped = errors(events)
    #expect(stopped.count == 3, "\(stopped)")
    #expect(stopped.allSatisfy { $0.contains("ran longer than") || $0.contains("time limit") })
    #expect(marks(events).map(\.kind) == ["dot", "dot"])
    #expect(elapsed < 3)
}

@Test func hardTimeLimitStopsCodeTheLoopGuardCannotSee() throws {
    let host = try makeHost()
    try #require(host.hasHardTimeLimit, "JavaScriptCore's execution watchdog is not available here")
    var limited = DrawingBeginOptions(width: 1280, height: 832, pace: .now, timeLimit: 0.2)
    limited.continuesAfterErrors = true
    _ = host.perform(.begin(limited))
    let started = Date()
    // Code built at run time is not rewritten with loop guards; JavaScriptCore's watchdog stops it instead.
    let events = run(host, """
    Function("while (true) {}")()
    dot(20, 20)
    """)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(errors(events).count == 1)
    #expect(marks(events).map(\.kind) == ["dot"])
}

@Test func pluginsRegisterThroughRegisterModuleAndLoadAfterTheEngine() throws {
    let source = try #require(KitResources.url("draw-engine", "js", in: "js")).deletingLastPathComponent()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("draw-plugin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["draw-engine.js", "draw-pieces.js"] {
        try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: directory.appendingPathComponent(name))
    }
    try """
    __engine.registerModule(function (api, ctx) {
      api.gadget = function (x, y, o) {
        var id = ctx.nextId('gadget');
        var m = ctx.push({ do: 'figure', id: id, at: [x, y], w: 200, h: 150, ink: ctx.ink,
                           info: [ctx.currentStep(), ctx.canvas.width, ctx.canvas.height, ctx.canvas.scale].join(',') });
        return { id: m.id, spin: function () { m.spin = true; ctx.push(m); },
                 part: function () { return ctx.push({ do: 'part3d', id: id + '.p1', figure: id }); } };
      };
      api.grumble = function () { ctx.warn('a plugin warning'); };
    });
    """.write(to: directory.appendingPathComponent("gadget-api.js"), atomically: true, encoding: .utf8)

    let host = try makeHost(directory: directory)
    #expect(host.loadedScripts == ["draw-engine.js", "draw-pieces.js", "gadget-api.js"])
    _ = host.perform(.begin(DrawingBeginOptions(width: 1000, height: 700, scale: 2, ink: "#26C281", pace: .now)))
    let events = run(host, """
    step(4)
    const g = gadget(100, 120)
    g.part()
    g.spin()
    grumble()
    """)
    #expect(errors(events).isEmpty, "\(errors(events))")
    #expect(warnings(events).contains("a plugin warning"))
    let ms = marks(events)
    #expect(ms.map(\.kind) == ["figure", "part3d", "figure"])
    #expect(ms.allSatisfy { $0.isFigureMark })
    #expect(ms[0].id == "gadget1" && ms[2].id == "gadget1")
    #expect(ms[1].id == "gadget1.p1")
    #expect(ms[0].step == 4)
    #expect(ms[0].json["info"]?.stringValue == "4,1000,700,2")
    #expect(ms[0].json["ink"]?.stringValue == "#26C281")
    #expect(ms[2].json["spin"]?.boolValue == true)
}

@Test func labelledBoxesThatHalfCoverEachOtherAreNudgedApart() throws {
    let host = try makeHost()
    _ = beginNow(host)
    let events = run(host, """
    box(200, 200, 240, 140, { label: "Client" })
    box(300, 260, 240, 140, { label: "Server" })
    box(220, 220, 80, 50, { label: "Cache" })
    """)
    let boxes = marks(events).filter { $0.kind == "box" }
    #expect(boxes.count == 3)
    func rect(_ m: DrawingMark) -> CGRect {
        let at = m.json["at"]?.arrayValue ?? []
        return CGRect(x: at[0].doubleValue ?? 0, y: at[1].doubleValue ?? 0, width: m.json["w"]?.doubleValue ?? 0, height: m.json["h"]?.doubleValue ?? 0)
    }
    let client = rect(boxes[0]), server = rect(boxes[1]), cache = rect(boxes[2])
    #expect(!client.intersects(server) || client.intersection(server).width * client.intersection(server).height < 0.08 * client.width * client.height)
    #expect(server.origin != CGPoint(x: 300, y: 260))
    // Nesting is intended, so the small box inside the first one stays put.
    #expect(cache.origin == CGPoint(x: 220, y: 220))
    #expect(warnings(events).contains { $0.hasPrefix("moved the box \"Server\"") })
}

@Test func inkStaysReadableOnLightAndDarkScreens() throws {
    func tone(over luminance: Double, ink: String) throws -> String? {
        let host = try makeHost(luminance: { _ in luminance })
        _ = host.perform(.begin(DrawingBeginOptions(width: 800, height: 600, ink: ink, pace: .now)))
        return marks(run(host, "text(100, 100, \"Readable words\")")).first?.json["tone"]?.stringValue
    }
    // A pale ink on a white page darkens but keeps its hue; on a dark page a dark ink lightens.
    let onLight = try #require(try tone(over: 0.95, ink: "#FFD84D"))
    let onDark = try #require(try tone(over: 0.01, ink: "#1F5FCC"))
    let light = try #require(DrawingColor(hex: onLight)), dark = try #require(DrawingColor(hex: onDark))
    func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
    #expect(ratio(light.luminance, 0.95) >= 4)
    #expect(ratio(dark.luminance, 0.01) >= 4)
    #expect(light.red > light.blue) // still a yellow-brown, not grey
    #expect(try tone(over: 0.95, ink: "#1F5FCC") == "#1F5FCC") // already readable: unchanged
}

@Test func editsEraseMoveHighlightAndUndoByPartID() throws {
    let clock = VirtualClock()
    let host = try makeHost(clock)
    _ = beginNow(host)
    var events = run(host, clock: clock, """
    box(100, 100, 200, 100, { label: "Server" })
    circle(600, 300, 50)
    erase("p2")
    move("p1", 40, 0)
    highlight("p1")
    undo()
    undo()
    """)
    #expect(events.contains(.done))
    #expect(errors(events).isEmpty, "\(errors(events))")
    let removed = events.flatMap { event -> [String] in if case .remove(let ids) = event { ids } else { [] } }
    let circle = try #require(marks(events).first { $0.kind == "circle" })
    #expect(removed.contains(circle.id))
    let moved = marks(events).filter { $0.json["edit"]?.stringValue == "move" }
    #expect(moved.contains { $0.json["xf"]?.arrayValue?.compactMap(\.doubleValue) == [1, 40, 0] })
    let highlight = try #require(marks(events).first { $0.kind == "highlight" })
    #expect(removed.contains(highlight.id)) // the first undo takes the highlight away again
    // The second undo glides the box back where it was.
    let last = try #require(marks(events).last { $0.kind == "box" })
    #expect(last.json["edit"]?.stringValue == "move")
    #expect(last.json["xf"] == nil)

    let description = host.describe()
    #expect(description.contains("p1"))
    #expect(description.contains("Server"))
    _ = beginNow(host)
    events = run(host, "box(10, 10, 50, 50)\nerase(\"p99\")")
    #expect(warnings(events).contains { $0.contains("p99") })
}

@Test func undoingAnEraseInTheSameLineBringsTheMarksBack() throws {
    let clock = VirtualClock()
    let host = try makeHost(clock)
    _ = beginNow(host)
    // The erase is timed to its moment in the line; the undo right after it must win, and a later erase still counts.
    let events = run(host, clock: clock, "box(100, 100, 200, 100)\ncircle(600, 300, 50)\nerase(\"p1,p2\")\nundo()\nerase(\"p2\")\n")
    var shown: Set<String> = []
    for event in events {
        if case .marks(let ms) = event { ms.forEach { shown.insert($0.id) } }
        if case .remove(let ids) = event { shown.subtract(ids) }
    }
    #expect(shown == ["m1"])
    #expect(events.contains(.done))
    #expect(host.describe().contains("p1: box"))
    #expect(!host.describe().contains("p2:"))
}

@Test func strangeNumbersNeitherHangTheEngineNorStallTheDrawing() throws {
    let clock = VirtualClock()
    let host = try makeHost(clock)
    _ = beginNow(host)
    let started = Date()
    // Coordinates that aren't numbers, sizes far past the screen, a range over ids that don't exist, then an edit
    // whose timing came after them: the program still finishes, nothing huge is released, and the erase happens.
    let events = run(host, clock: clock, """
    box(20, 20, 60, 40)
    callout(NaN, Infinity, "where?")
    cross(NaN, NaN)
    text(NaN, 10, "lost")
    line([0, 0], [1e300, 1e300], { size: 1e300 })
    paper(0, 0, 1e300, 1e300, { board: "dots" })
    text(10, 700, "x".repeat(9000), { size: 1e300 })
    erase("m1-m99999999")
    """)
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(errors(events).isEmpty, "\(errors(events))")
    #expect(events.contains(.done))
    let all = marks(events)
    #expect(!all.contains { $0.kind == "pill" || $0.json["pts"]?.arrayValue?.isEmpty == false && $0.kind == "arrow" })
    func numbers(_ value: JSONValue) -> [Double] {
        if let d = value.doubleValue { return [d] }
        if let a = value.arrayValue { return a.flatMap(numbers) }
        if case .object(let o) = value { return o.filter { $0.key != "base" }.values.flatMap(numbers) }
        return []
    }
    #expect(all.allSatisfy { numbers($0.json).allSatisfy { abs($0) <= 100_000 } })
    let paper = try #require(all.first { $0.kind == "paper" })
    #expect((paper.json["w"]?.doubleValue ?? 0) <= 1280 && (paper.json["h"]?.doubleValue ?? 0) <= 832)
    let words = try #require(all.first { $0.kind == "text" })
    #expect((words.json["text"]?.stringValue?.count ?? 0) <= 4000)
    let removed = Set(events.flatMap { event -> [String] in if case .remove(let ids) = event { ids } else { [] } })
    #expect(removed == Set(all.map(\.id)))
}

@Test func clickingADrawnButtonAsksAFollowUp() throws {
    let host = try makeHost()
    _ = beginNow(host)
    let events = run(host, "button(100, 600, \"Show me an example\", { ask: \"Can you show me an example of a cache miss?\" })")
    let button = try #require(marks(events).first { $0.kind == "button" })
    let asked = host.perform(.click(button.id)).filter { if case .ask = $0 { true } else { false } }
    #expect(asked == [.ask("Can you show me an example of a cache miss?")])
    #expect(!host.perform(.click("nope")).contains { if case .ask = $0 { true } else { false } })
}

@Test func finishNowDrawsEverythingStillWaitingForTheVoice() throws {
    let clock = VirtualClock()
    let host = try makeHost(clock)
    _ = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .speech)))
    var events = run(host, """
    step(1); say("One."); box(100, 100, 100, 100)
    step(2); say("Two."); circle(400, 300, 40)
    """)
    #expect(marks(events).isEmpty)
    events = host.perform(.finishNow)
    clock.now += 5
    events += host.perform(.drain)
    #expect(marks(events).map(\.kind) == ["box", "circle"])
    #expect(events.contains(.done))
    #expect(marks(events).allSatisfy { $0.duration < 1 })
}

@Test func everyMarkCarriesAnIDStepAndTiming() throws {
    let host = try makeHost()
    _ = beginNow(host)
    let events = run(host, """
    step(1)
    line(100, 100, 300, 140)
    arrow([320, 160], [500, 300], { label: "flows" })
    box(520, 300, 160, 90, { label: "Queue", dash: true })
    circle(800, 200, 60, { fill: "sky" })
    dot(900, 400)
    step(2)
    text(100, 500, "Plain words")
    write(100, 560, "Handwritten words")
    highlight(100, 495, 200, 30)
    pill(400, 500, "Inbox")
    badge(380, 480, 2)
    callout(1100, 600, "This button", { side: "left" })
    region(60, 640, 300, 120, "Sidebar")
    paper(700, 450, 420, 300, { title: "Notes", board: "dots" })
    button(720, 700, "Tell me more")
    const g = graph(100, 100, 300, 200, { x: [0, 10], y: [0, 100], grid: true })
    g.plot(x => x * x)
    timeline(100, 780, 1000, [[1990, "Web"], [2007, "Phones"], [2022, "Chat"]])
    check(1000, 100); cross(1050, 100); underline(100, 530, 120)
    point(1200, 50, "Here")
    """)
    #expect(errors(events).isEmpty, "\(errors(events))")
    let all = marks(events)
    let kinds = Set(all.map(\.kind))
    for kind in ["line", "arrow", "box", "circle", "dot", "text", "highlight", "pill", "badge", "region", "paper", "button", "graph"] {
        #expect(kinds.contains(kind), "missing \(kind)")
    }
    // Edits send a mark again under its id (here the notes card grows to hold the button hung from it).
    let drawn = all.filter { $0.json["edit"] == nil }
    #expect(Set(drawn.map(\.id)).count == drawn.count)
    for mark in all {
        #expect(!mark.id.isEmpty)
        #expect(mark.step == 1 || mark.step == 2)
        #expect(mark.start >= 0)
        #expect(mark.duration >= 0)
        #expect(mark.json["part"]?.stringValue?.hasPrefix("p") == true)
    }
}

/// docs/dsl-3d.md's engine hook: figure ticks are program code the host runs once per frame, between statements.
/// They used to freeze after 255 frames, when the disarmed runaway-loop guard tripped; `ctx.guarded` arms it per call.
@Test func figureTicksKeepRunningFrameAfterFrameInTheRealEngine() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/Drawing/3d/piston-engine.js")
    let host = try makeHost()
    var events = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now)))
    events += host.perform(.append(try String(contentsOf: url, encoding: .utf8)))
    events += host.perform(.end)
    #expect(errors(events).isEmpty, "\(errors(events))")
    let figure = try #require(marks(events).first { $0.kind == "figure" }?.id)
    let tick = try #require(marks(events).first { $0.kind == "tick3d" }?.id)
    var previous: [Float] = [], changes = 0
    for frame in 0..<900 {
        let pose = host.withContext { FigureTickBridge(context: $0).runTicks(figure: figure, ticks: [(tick, Double(frame) / 60)], dt: 1.0 / 60) }
        if pose != previous { changes += 1 }
        previous = pose
    }
    #expect(changes == 900)
    let readouts = host.withContext { FigureTickBridge(context: $0).takeReadouts() }
    #expect(readouts[figure]?["stroke"] != nil)
    // A follow-up turn adds a runaway tick: each frame stops it at the guard's limit and comes back promptly.
    var more = host.perform(.begin(DrawingBeginOptions(width: 1280, height: 832, pace: .now, keep: true)))
    more += host.perform(.append("f.tick(() => { while (true) {} })\n"))
    more += host.perform(.end)
    #expect(errors(more).isEmpty, "\(errors(more))")
    let runaway = try #require(marks(more).first { $0.kind == "tick3d" }?.id)
    #expect(runaway != tick)
    let started = Date()
    for _ in 0..<3 {
        _ = host.withContext { FigureTickBridge(context: $0).runTicks(figure: figure, ticks: [(tick, 2), (runaway, 2)], dt: 1.0 / 60) }
    }
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(warnings(host.perform(.drain)).contains { $0.contains(runaway) && $0.contains("stopped") })
}
