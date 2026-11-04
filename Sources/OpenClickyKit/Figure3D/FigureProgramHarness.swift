import CoreGraphics
import Foundation
import JavaScriptCore

/// Drives `globalThis.__figure3d` (installed by figure-api.js) in any JavaScriptCore context: runs a figure's
/// started ticks and collects tick-made readouts. The 2D engine host uses it with its own context on its own
/// thread; the harness below uses it with the stand-in engine.
public struct FigureTickBridge {
    public let context: JSContext

    public init(context: JSContext) { self.context = context }

    /// Run the figure's ticks (`[(tickID, secondsSinceItsLineStarted)]`) and return the packed poses
    /// (12 floats per posed part, docs/dsl-3d.md §10).
    public func runTicks(figure: String, ticks: [(String, Double)], dt: Double) -> [Float] {
        guard !ticks.isEmpty, let registry = context.objectForKeyedSubscript("__figure3d"), registry.isObject else { return [] }
        let list = ticks.map { [$0.0, $0.1] as [Any] }
        guard let result = registry.invokeMethod("runTicks", withArguments: [figure, list, dt]) else { return [] }
        return FigureKernel.floats(result, in: context)
    }

    /// Readouts changed by ticks since the last call: figure id -> key -> text.
    public func takeReadouts() -> [String: [String: String]] {
        guard let registry = context.objectForKeyedSubscript("__figure3d"), registry.isObject,
              let text = registry.invokeMethod("takeReadouts", withArguments: [])?.toString(), text != "null", text != "undefined",
              let json = try? JSONValue.parse(text), let figures = json.objectValue else { return [:] }
        return figures.mapValues { ($0.objectValue ?? [:]).compactMapValues(\.stringValue) }
    }

    /// One line per part of a figure, for follow-up turns (docs/dsl-3d.md §10).
    public func describe(figure: String) -> String {
        context.objectForKeyedSubscript("__figure3d")?.invokeMethod("describe", withArguments: [figure])?.toString() ?? ""
    }
}

/// Runs a figure program without the 2D drawing engine: a minimal stand-in implements only the plugin side of the
/// drawing contract (`__engine.registerModule`, `ctx.push` and friends, `say`/`step` as no-ops), loads
/// figure-api.js, runs the whole program at once and collects the marks. Used by `occtl figure` and tests; the real
/// app runs figure-api.js inside the 2D engine instead.
public final class FigureProgramHarness {
    public let context: JSContext
    public private(set) var marks: [DrawingMark] = []
    public private(set) var warnings: [String] = []
    public private(set) var errors: [String] = []
    public var tickBridge: FigureTickBridge { FigureTickBridge(context: context) }

    private var lastException: String?

    public init(canvas: CGSize = CGSize(width: 1440, height: 900), scale: CGFloat = 2, ink: String = "#30333A") throws {
        guard let context = JSContext() else { throw FigureKernelError.loadFailed("could not create a JavaScript context") }
        self.context = context
        context.name = "OpenClicky figure harness"
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString()
        }
        context.evaluateScript(Self.standInEngine)
        let api = try KitResources.text("figure-api", "js", in: "js")
        context.evaluateScript(api, withSourceURL: URL(string: "openclicky://js/figure-api.js"))
        if let error = lastException { throw FigureKernelError.loadFailed("figure-api.js: \(error)") }
        let options: [String: Any] = ["canvas": ["width": canvas.width, "height": canvas.height, "scale": scale], "ink": ink]
        context.objectForKeyedSubscript("__engine").invokeMethod("begin", withArguments: [options])
        if let error = lastException { throw FigureKernelError.loadFailed("engine begin: \(error)") }
    }

    /// Run a program (code fences allowed) and return every mark it made so far.
    @discardableResult
    public func run(_ program: String) -> [DrawingMark] {
        lastException = nil
        context.evaluateScript(Self.prepare(program), withSourceURL: URL(string: "openclicky://program.js"))
        if let error = lastException {
            errors.append(error)
            lastException = nil
        }
        drain()
        return marks
    }

    /// Ids of the figures the program made, in order.
    public var figureIDs: [String] { marks.filter { $0.kind == "figure" }.map(\.id) }

    private func drain() {
        guard let text = context.objectForKeyedSubscript("__engine").invokeMethod("drain", withArguments: [])?.toString(),
              let json = try? JSONValue.parse(text), let events = json.arrayValue else { return }
        for event in events.compactMap(DrawingEvent.init(json:)) {
            switch event {
            case .marks(let new): marks += new
            case .warning(let message): warnings.append(message)
            case .error(let message, _): errors.append(message)
            default: break
            }
        }
    }

    /// Strip code fences and name parts after the variables they are assigned to
    /// (`const rotor = f.cylinder(...)` -> the part is called "rotor").
    static func prepare(_ program: String) -> String {
        let kinds = "arrow|ball|blob|box|capsule|cone|cyl|cylinder|extrude|gear|group|lathe|pipe|poly|polyhedron|sphere|spring|torus|tube"
        // A declaration at the start of a line or right after a `;`.
        let pattern = try! NSRegularExpression(
            pattern: "(?:^|;)[ \\t]*((?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*[A-Za-z_$][\\w$]*\\.(?:\(kinds))\\s*\\()")
        return program.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return "" }
            // Insert from the end so earlier ranges stay valid.
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let declaration = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { continue }
                text.insert(contentsOf: "__figure3d.nameNext(\"\(text[name])\"); ", at: declaration.lowerBound)
            }
            return text
        }.joined(separator: "\n")
    }

    /// The smallest engine that satisfies the plugin contract in docs/drawing-contract.md. Like the real engine it
    /// calls each module once when it registers, reads the canvas and ink through ctx getters, turns the `__dur` /
    /// `__adv` pacing hints into `start` / `duration`, drops `__` keys and rounds numbers to 2 decimals on the way out.
    static let standInEngine = #"""
    (function () {
      'use strict';
      let events = [];
      let step = 0;
      let canvas = { width: 1440, height: 900, scale: 2 };
      let ink = '#30333A';
      const counters = {};
      const cursor = {};
      const round = (v) => {
        if (typeof v === 'number') return Number.isFinite(v) ? Math.round(v * 100) / 100 + 0 : 0;
        if (Array.isArray(v)) return v.map(round);
        if (v && typeof v === 'object') {
          const o = {};
          for (const k of Object.keys(v)) if (!k.startsWith('__') && typeof v[k] !== 'function' && v[k] !== undefined) o[k] = round(v[k]);
          return o;
        }
        return v;
      };
      const ctx = {
        get canvas() { return canvas; },
        get ink() { return ink; },
        push(mark) {
          mark.step = step;
          const dur = typeof mark.__dur === 'number' ? mark.__dur : (typeof mark.duration === 'number' ? mark.duration : 0);
          const adv = typeof mark.__adv === 'number' ? mark.__adv : dur;
          const at = cursor[step] || 0;
          mark.start = at;
          mark.duration = dur;
          cursor[step] = at + adv;
          const out = round(mark);
          out.start = Math.round(at * 1000) / 1000;
          out.duration = Math.round(dur * 1000) / 1000;
          events.push({ type: 'marks', marks: [out] });
          return mark;
        },
        warn(message) { events.push({ type: 'warning', message: String(message) }); },
        nextId(prefix) { counters[prefix] = (counters[prefix] || 0) + 1; return prefix + counters[prefix]; },
        currentStep() { return step; },
      };
      const api = {
        say() {},
        step(n) { if (typeof n === 'number') step = n; },
      };
      globalThis.__engine = {
        registerModule(fn) { fn(api, ctx); },
        begin(options) {
          options = options || {};
          if (options.canvas) canvas = options.canvas;
          if (typeof options.ink === 'string') ink = options.ink;
          for (const key of Object.keys(api)) globalThis[key] = api[key];
        },
        drain() { const out = JSON.stringify(events); events = []; return out; },
      };
    })();
    """#
}
