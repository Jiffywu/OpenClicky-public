import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OpenClickyKit
import UniformTypeIdentifiers

/// `occtl takeover …`: plan or simulate a take-over drive. Nothing here ever posts a mouse or keyboard event: every
/// subcommand uses the dry-run actuator.
enum TakeoverCommands {
    static let usage = """
    Usage:
      occtl takeover plan --config c.json --image shot.jpg [options] <task>
          One live model step on the brain slot against a screenshot file: prints the actions the model would take,
          where each lands on the screen, and whether the safety check would allow it. Nothing is performed.
            --elements e.json      element list for the screenshot (see mock-screen); password fields in it are refused
            --display x,y,w,h      the display the screenshot shows, in AppKit points (default: one point per pixel)
            --planner auto|computer-tool|functions   (default auto: Anthropic's computer tool on Anthropic, else functions)
            --effort e             reasoning effort for the model call
            --slot brain|brain-fast  which model slot plans (default brain, as in the app)
            --out dir              write plan.json and plan.png (the screenshot with numbered action markers)
            --json                 print the report as JSON
      occtl takeover simulate [--image shot.png --elements e.json] [--script steps.json | --config c.json [--live-steps n]]
                              [--reply "words" | --decline] [--esc-after-step n | --move-mouse-after-step n] [--json] [task]
          The whole flow headlessly: offer_screen_takeover → consent (card, or the user's reply) → drive loop →
          report, with a dry-run actuator, a still screen and a simulated user. Without --script or --config it plays
          a built-in demo script against the mock screen.
      occtl takeover mock-screen --out dir
          Writes mock-screen.png (a 1440×900 fake note window with a title field, a password field and buttons) and
          mock-elements.json, for plan and simulate.
    """

    static let command = OcctlCommand(name: "takeover", usage: "takeover <plan|simulate|mock-screen>  plan or simulate a take-over drive (dry run only)") { args in
        guard let sub = args.first else { fail(usage) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "plan": try await plan(rest)
        case "simulate": try await simulate(rest)
        case "mock-screen": try mockScreen(rest)
        default: fail(usage)
        }
    }

    // MARK: - Options

    struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var words: [String] = []

        init(_ args: [String], valued: Set<String>, flags known: Set<String>) {
            var index = 0
            while index < args.count {
                let arg = args[index]
                if valued.contains(arg) {
                    index += 1
                    guard index < args.count else { fail("\(arg) needs a value") }
                    values[arg] = args[index]
                } else if known.contains(arg) {
                    flags.insert(arg)
                } else if arg.hasPrefix("--") {
                    fail("Unknown option \(arg)\n\n\(usage)")
                } else {
                    words.append(arg)
                }
                index += 1
            }
        }

        subscript(_ key: String) -> String? { values[key] }
        var task: String { words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - plan

    static func plan(_ args: [String]) async throws {
        let options = Options(args, valued: ["--config", "--image", "--elements", "--display", "--planner", "--effort", "--out", "--slot"],
                              flags: ["--json"])
        guard let imagePath = options["--image"], !options.task.isEmpty else { fail(usage) }
        let config = try EngineCommands.loadConfig(options["--config"], fallback: nil)
        let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
        let choice = try plannerChoice(options["--planner"])
        let slot = SlotID(rawValue: options["--slot"] ?? "brain") ?? .brain
        guard [.brain, .brainFast].contains(slot) else { fail("--slot must be brain or brain-fast") }
        let resolution = try factory.resolve(slot)
        let inner = try choice.makePlanner(factory: factory, slot: slot, effort: options["--effort"])
        let planner = OneStepPlanner(inner)

        let screen = try stillScreen(imagePath: imagePath, elementsPath: options["--elements"], display: options["--display"])
        let observation = screen.observation
        let probe = StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: observation),
                                        cursor: observation.layout.quartzPoint(fromAppKit: CGPoint(x: observation.display.frame.midX,
                                                                                                   y: observation.display.frame.midY)))
        let brief = TakeoverBrief(task: options.task)
        let actuator = DryRunActuator()
        let driver = TakeoverDriver(brief: brief, planner: planner, screen: screen, actuator: actuator, safety: TakeoverSafetyGuard(probe: probe),
                                    limits: TakeoverLimits(maximumSteps: 1, settleSeconds: 0), timing: VirtualTiming())

        log("→ \(slot.rawValue): \(resolution.selection.provider) / \(resolution.selection.model) via \(planner.label)")
        log("→ screenshot \(observation.pixelWidth)×\(observation.pixelHeight) px (model size) of display \(rect(observation.display.frame)) pt; "
            + "\(observation.elements.count) elements")
        let started = Date()
        let report = await driver.run()
        let seconds = Date().timeIntervalSince(started)
        let plan = planner.firstPlan

        var json = report.json.objectValue ?? [:]
        json["mode"] = "plan (one model step, dry run)"
        json["wall_ms"] = .number((seconds * 1000).rounded())
        json["screenshot"] = ["model_width": .number(Double(observation.pixelWidth)), "model_height": .number(Double(observation.pixelHeight)),
                              "display_frame": observation.display.frame.jsonValue]
        if let plan {
            json["planned"] = .array(plan.actions.map { planned in
                var item: [String: JSONValue] = ["call_id": .string(planned.callID), "name": .string(planned.name),
                                                 "summary": .string(planned.action?.summary ?? planned.problem ?? "")]
                if let action = planned.action {
                    let points = action.targets.compactMap { try? observation.mapper.quartzPoint(for: $0) }
                    item["quartz_points"] = .array(points.map(\.jsonValue))
                }
                return .object(item)
            })
        }

        if options.flags.contains("--json") {
            print(pretty(.object(json)))
        } else {
            printPlan(report: report, plan: plan, seconds: seconds)
        }
        if let out = options["--out"] {
            let directory = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(pretty(.object(json)).utf8).write(to: directory.appendingPathComponent("plan.json"))
            if let plan {
                let png = try annotate(observation: observation, plan: plan, report: report)
                try png.write(to: directory.appendingPathComponent("plan.png"))
            }
            log("wrote \(directory.path)/plan.json and plan.png")
        }
        if report.outcome == .failed || report.outcome == .couldNotSee { exit(1) }
    }

    static func printPlan(report: TakeoverReport, plan: DrivePlan?, seconds: Double) {
        print("Task: \(report.brief.task)")
        if let step = report.steps.first {
            if !step.narration.isEmpty { print("Model says: \(step.narration)") }
            if step.actions.isEmpty { print("The model asked for no actions (it would finish here).") }
            let observations: Set<String> = ["screenshot", "zoom", "cursor_position", "wait"]
            for (index, action) in step.actions.enumerated() {
                var line = "\(index + 1). \(action.summary)"
                if let placed = action.placed, placed.contains("(") { line += "  →  \(placed) in Quartz points" }
                switch action.status {
                case .done where observations.contains(action.name): line += "  [looks only; no input]"
                case .done: line += "  [would perform; dry run]"
                case .refused: line += "  [REFUSED: \(action.detail ?? "")]"
                case .notExecuted: line += "  [skipped: an earlier action in this step failed]"
                case .failed: line += "  [FAILED: \(action.detail ?? "")]"
                case .stopped: line += "  [stopped]"
                }
                print(line)
            }
        } else if let error = report.error {
            print("No plan: \(error)")
        }
        let usage = report.usage
        print(String(format: "Model step: %.2f s, tokens in %d out %d. Nothing was performed.", seconds, usage.inputTokens, usage.outputTokens))
        _ = plan
    }

    /// Wraps a planner so a drive stops after its first model step and never makes a second call.
    final class OneStepPlanner: TakeoverPlanner, @unchecked Sendable {
        private let inner: any TakeoverPlanner
        private let lock = NSLock()
        private var stored: DrivePlan?

        init(_ inner: any TakeoverPlanner) { self.inner = inner }

        var label: String { inner.label }
        var firstPlan: DrivePlan? { lock.withLock { stored } }

        func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
            let plan = try await inner.start(brief: brief, observation: observation)
            lock.withLock { stored = plan }
            return plan
        }

        func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
            DrivePlan(narration: "(plan mode: no second model step)", actions: [])
        }
    }

    // MARK: - simulate

    static func simulate(_ args: [String]) async throws {
        let options = Options(args, valued: ["--image", "--elements", "--display", "--script", "--config", "--live-steps", "--reply",
                                             "--esc-after-step", "--move-mouse-after-step", "--planner"],
                              flags: ["--decline", "--json"])
        let screen: StillTakeoverScreen
        if let image = options["--image"] {
            screen = try stillScreen(imagePath: image, elementsPath: options["--elements"], display: options["--display"])
        } else {
            let mock = try MockScreen.make()
            screen = try StillTakeoverScreen(imageData: mock.png, display: MockScreen.display, layout: DesktopLayout(displays: [MockScreen.display]),
                                          elements: MockScreen.elements(display: MockScreen.display))
        }
        let observation = screen.observation
        let probe = StaticTakeoverProbe(regions: StaticTakeoverProbe.regions(for: observation),
                                        focused: DriveTargetInfo(ownerBundleID: "dev.openclicky.mock", ownerName: "Notes Lite", role: "AXTextField"),
                                        cursor: CGPoint(x: 700, y: 450))
        let task = options.task.isEmpty ? "Title the note \"Quarterly plan\" and save it" : options.task
        let escAfter = options["--esc-after-step"].flatMap(Int.init)
        let moveAfter = options["--move-mouse-after-step"].flatMap(Int.init)
        let liveSteps = options["--live-steps"].flatMap(Int.init) ?? 3

        let started = Date()
        let printer = ConsolePresenter(started: started, quiet: options.flags.contains("--json"))
        let controllerBox = ControllerBox()
        // A simulated user: at the chosen step, press Escape or move the mouse, through the same policy the app's
        // event tap uses.
        let beforeStep: @Sendable (Int) async -> Void = { step in
            var policy = UserInputPolicy()
            if step == escAfter {
                printer.say("user presses Escape")
                if let reason = policy.decide(.keyDown(keyCode: 53), synthetic: false).stop { controllerBox.controller?.emergencyStop(reason) }
            }
            if step == moveAfter {
                printer.say("user moves the mouse 40 pt")
                for _ in 0..<4 {
                    if let reason = policy.decide(.pointerMoved(distance: 10), synthetic: false).stop { controllerBox.controller?.emergencyStop(reason) }
                }
            }
        }

        var plannerLabel = "scripted"
        let makePlanner: @Sendable () throws -> any TakeoverPlanner
        if let configPath = options["--config"] {
            let config = try EngineCommands.loadConfig(configPath, fallback: nil)
            let factory = EngineFactory(config: config, catalog: try ModelCatalog.builtIn().merging(config.models), credentials: CoreCommands.store)
            let choice = try plannerChoice(options["--planner"])
            let live = try choice.makePlanner(factory: factory)
            plannerLabel = live.label
            makePlanner = { SteppedPlanner(live, beforeStep: beforeStep) }
        } else {
            let plans: [DrivePlan]
            if let script = options["--script"] {
                plans = try ScriptedTakeoverPlanner.plans(fromJSON: String(contentsOfFile: script, encoding: .utf8))
            } else {
                plans = try ScriptedTakeoverPlanner.plans(fromJSON: MockScreen.demoScript)
            }
            makePlanner = { ScriptedTakeoverPlanner(plans, beforeStep: beforeStep) }
        }
        let limits = TakeoverLimits(maximumSteps: options["--config"] != nil ? max(1, liveSteps) : 25, settleSeconds: 0)
        let controller = TakeoverController(presenter: printer, startsOnCardApproval: true) { _ in
            TakeoverDriveSetup(planner: try makePlanner(), screen: screen, actuator: DryRunActuator(), safety: TakeoverSafetyGuard(probe: probe),
                               limits: limits, timing: VirtualTiming())
        }
        controllerBox.controller = controller
        let tools = TakeoverTools(controller: controller)
        printer.say("planner: \(plannerLabel); screen \(observation.pixelWidth)×\(observation.pixelHeight) px, \(observation.elements.count) elements")

        // 1. The brain offers.
        let offerArguments: JSONValue = ["task": .string(task), "steps": ["Click the Title field", "Type the title", "Save with Command-S"],
                                         "app": "Notes Lite"]
        let offered = await tools.run(ToolCall(id: "call_offer", name: TakeoverTools.offerName, arguments: offerArguments.jsonString()))
        printer.say("brain → offer_screen_takeover: \(offered.status.rawValue) — \(offered.message ?? "")")
        // The brain trying to start before the user answers is refused.
        let early = await tools.run(ToolCall(id: "call_early", name: TakeoverTools.startName, arguments: "{}"))
        printer.say("brain → start_screen_takeover (before any answer): \(early.status.rawValue) — \(early.message ?? "")")

        // 2. The user answers.
        if options.flags.contains("--decline") {
            printer.say("user clicks Not now")
            await controller.decline()
            printer.say("phase: \(controller.phase.name); nothing was driven")
            return
        }
        if let reply = options["--reply"] {
            printer.say("user says: \"\(reply)\"")
            let phase = await controller.userReplied(reply)
            printer.say("phase: \(phase.name)")
            guard phase.name == "approved" else {
                let refused = await tools.run(ToolCall(id: "call_start", name: TakeoverTools.startName, arguments: "{}"))
                printer.say("brain → start_screen_takeover: \(refused.status.rawValue) — \(refused.message ?? "")")
                return
            }
            let startResult = await tools.run(ToolCall(id: "call_start", name: TakeoverTools.startName, arguments: "{}"))
            printer.say("brain → start_screen_takeover: \(startResult.status.rawValue) — \(startResult.message ?? "")")
        } else {
            printer.say("user clicks Let OpenClicky drive")
            try await controller.approve(source: .card)
        }

        // 3. The drive runs; 4. the report.
        guard let report = await controller.waitForDrive() else { fail("The drive did not start.") }
        if options.flags.contains("--json") {
            print(pretty(report.json))
        } else {
            printer.say("report: \(report.outcome.rawValue) — \(report.summary)")
            printer.say("brain's next [App] note: \(report.appNote)")
            print(pretty(report.json))
        }
    }

    final class ControllerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TakeoverController?
        var controller: TakeoverController? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Runs a hook before each step of another planner (for simulated user input during live runs).
    final class SteppedPlanner: TakeoverPlanner, @unchecked Sendable {
        private let inner: any TakeoverPlanner
        private let beforeStep: @Sendable (Int) async -> Void
        private let lock = NSLock()
        private var step = 0

        init(_ inner: any TakeoverPlanner, beforeStep: @escaping @Sendable (Int) async -> Void) {
            self.inner = inner
            self.beforeStep = beforeStep
        }

        var label: String { inner.label }

        private func tick() async throws {
            let current = lock.withLock { () -> Int in
                defer { step += 1 }
                return step
            }
            await beforeStep(current)
            try Task.checkCancellation()
        }

        func start(brief: TakeoverBrief, observation: DriveObservation) async throws -> DrivePlan {
            try await tick()
            return try await inner.start(brief: brief, observation: observation)
        }

        func next(results: [DriveActionResult], observation: DriveObservation) async throws -> DrivePlan {
            try await tick()
            return try await inner.next(results: results, observation: observation)
        }
    }

    /// Prints what the app would show: the card, overlay updates and the end of the drive.
    final class ConsolePresenter: TakeoverPresenting {
        let started: Date
        let quiet: Bool
        init(started: Date, quiet: Bool) {
            self.started = started
            self.quiet = quiet
        }

        func say(_ text: String) {
            let line = String(format: "[%6.2fs] ", Date().timeIntervalSince(started)) + text
            if quiet { FileHandle.standardError.write(Data((line + "\n").utf8)) } else { print(line) }
        }

        func showConsent(_ offer: TakeoverOffer) async {
            var card = "card: \"Let OpenClicky use your Mac?\" — \(offer.brief.task)"
            if !offer.brief.steps.isEmpty { card += " | plan: " + offer.brief.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ") }
            card += " | Esc stops; any mouse or key input stops and hands back | [Not now] [Let OpenClicky drive]"
            say(card)
        }
        func hideConsent() async { say("card hidden") }
        func driveWillStart(_ offer: TakeoverOffer, stop: TakeoverStopSwitch, dryRun: Bool) async throws {
            say("overlay on: red frame + drive cursor\(dryRun ? " (dry run: nothing reaches the Mac)" : ""); input monitor armed")
        }
        func driveEvent(_ event: TakeoverEvent) async { say("drive: \(event.logLine)") }
        func driveDidEnd(_ report: TakeoverReport) async { say("overlay off, input monitor removed") }
    }

    // MARK: - mock-screen

    static func mockScreen(_ args: [String]) throws {
        let options = Options(args, valued: ["--out"], flags: [])
        guard let out = options["--out"] else { fail(usage) }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mock = try MockScreen.make()
        try mock.png.write(to: directory.appendingPathComponent("mock-screen.png"))
        try Data(pretty(MockScreen.elementsJSON).utf8).write(to: directory.appendingPathComponent("mock-elements.json"))
        print("wrote \(directory.path)/mock-screen.png (1440×900) and mock-elements.json (\(MockScreen.elements.count) elements)")
    }

    // MARK: - Helpers

    static func plannerChoice(_ raw: String?) throws -> TakeoverPlannerChoice {
        guard let raw else { return .automatic }
        guard let choice = TakeoverPlannerChoice(rawValue: raw) else { fail("--planner must be auto, computer-tool or functions") }
        return choice
    }

    /// A screenshot file and, optionally, its element list (boxes in the file's pixels) as a still screen.
    static func stillScreen(imagePath: String, elementsPath: String?, display: String?) throws -> StillTakeoverScreen {
        let data = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        guard let size = ImageCoding.pixelSize(of: data) else { fail("Can't read the image \(imagePath).") }
        var geometry = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: size.width, height: size.height), scale: 1, isPrimary: true,
                                       name: "screenshot file")
        if let display {
            let numbers = display.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { fail("--display is x,y,w,h in AppKit points") }
            geometry.frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        var elements: [DriveElement] = []
        if let elementsPath {
            let json = try JSONValue.parse(String(contentsOfFile: elementsPath, encoding: .utf8))
            elements = try MockScreen.elements(from: json, imageSize: size, display: geometry)
        }
        return try StillTakeoverScreen(imageData: data, display: geometry, layout: DesktopLayout(displays: [geometry]), elements: elements)
    }

    /// The model-sized screenshot with a numbered marker at each action's target: green for allowed, red for
    /// refused, gray for skipped.
    static func annotate(observation: DriveObservation, plan: DrivePlan, report: TakeoverReport) throws -> Data {
        let image = try ImageCoding.decode(observation.imageData)
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageCoding.Failure.resizeFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let statuses = Dictionary((report.steps.first?.actions ?? []).map { ($0.callID, $0.status) }, uniquingKeysWith: { a, _ in a })
        for (index, planned) in plan.actions.enumerated() {
            guard let action = planned.action else { continue }
            let points = action.targets.compactMap { target -> CGPoint? in
                guard let quartz = try? observation.mapper.quartzPoint(for: target) else { return nil }
                return observation.mapper.modelPixel(fromQuartz: quartz)
            }
            let color: CGColor
            switch statuses[planned.callID] {
            case .done: color = CGColor(red: 0.1, green: 0.65, blue: 0.3, alpha: 1)
            case .refused, .failed: color = CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
            default: color = CGColor(gray: 0.45, alpha: 1)
            }
            for (pointIndex, pixel) in points.enumerated() {
                let center = CGPoint(x: pixel.x, y: CGFloat(height) - pixel.y)
                context.setStrokeColor(color)
                context.setLineWidth(3)
                context.strokeEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                let label = points.count > 1 ? "\(index + 1)\(pointIndex == 0 ? "a" : "b")" : "\(index + 1)"
                drawText(label, at: CGPoint(x: center.x + 16, y: center.y + 8), color: color, size: 18, in: context)
            }
        }
        guard let output = context.makeImage() else { throw ImageCoding.Failure.resizeFailed }
        return try ImageCoding.pngData(output)
    }

    static func drawText(_ text: String, at point: CGPoint, color: CGColor, size: CGFloat, in context: CGContext, bold: Bool = true) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func pretty(_ value: JSONValue) -> String {
        guard let data = try? value.jsonData(), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let printed = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return value.jsonString() }
        return String(decoding: printed, as: UTF8.self)
    }

    static func rect(_ r: CGRect) -> String { "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))" }

    static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}

/// A synthetic note-taking window for plan and simulate: drawn with Core Graphics, no real app involved.
enum MockScreen {
    static let size = (width: 1440, height: 900)
    /// One point per pixel, at the origin.
    static let display = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1, isPrimary: true, name: "mock")

    struct Element {
        var id: String
        var role: String
        var subrole: String?
        var label: String
        /// Image pixels, top-left origin.
        var box: CGRect
    }

    static let window = CGRect(x: 220, y: 110, width: 1000, height: 660)
    static let elements: [Element] = [
        Element(id: "e1", role: "AXTextField", label: "Title", box: CGRect(x: 260, y: 214, width: 600, height: 36)),
        Element(id: "e2", role: "AXTextArea", label: "Body", box: CGRect(x: 260, y: 300, width: 920, height: 220)),
        Element(id: "e3", role: "AXTextField", subrole: "AXSecureTextField", label: "Sync password", box: CGRect(x: 260, y: 576, width: 400, height: 36)),
        Element(id: "e4", role: "AXButton", label: "Cancel", box: CGRect(x: 900, y: 704, width: 120, height: 36)),
        Element(id: "e5", role: "AXButton", label: "Save", box: CGRect(x: 1040, y: 704, width: 140, height: 36)),
    ]

    static var elementsJSON: JSONValue {
        .array(elements.map { element in
            var object: [String: JSONValue] = ["id": .string(element.id), "role": .string(element.role), "label": .string(element.label),
                                               "box": [.number(element.box.minX), .number(element.box.minY), .number(element.box.width),
                                                       .number(element.box.height)]]
            if let subrole = element.subrole { object["subrole"] = .string(subrole) }
            return .object(object)
        })
    }

    static func elements(display: DisplayGeometry) -> [DriveElement] {
        (try? elements(from: elementsJSON, imageSize: size, display: display)) ?? []
    }

    /// Reads `[{id, role, subrole?, label?, box: [x, y, w, h]}]` with boxes in image pixels.
    static func elements(from json: JSONValue, imageSize: (width: Int, height: Int), display: DisplayGeometry) throws -> [DriveElement] {
        guard let items = json.arrayValue else { throw DriveActionParseError("The element list is a JSON array.") }
        let geometry = CaptureGeometry(displayFrame: display.frame, pixelWidth: imageSize.width, pixelHeight: imageSize.height)
        return try items.map { item in
            guard let id = item["id"]?.stringValue, let role = item["role"]?.stringValue,
                  let box = item["box"]?.arrayValue?.compactMap(\.doubleValue), box.count == 4 else {
                throw DriveActionParseError("Each element needs id, role and box [x, y, w, h].")
            }
            let frame = geometry.appKitRect(fromPixelRect: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
            return DriveElement(id: id, role: role, subrole: item["subrole"]?.stringValue, label: item["label"]?.stringValue, frame: frame)
        }
    }

    /// Clicks the title field, types, saves, then tries the password field (refused) and finishes.
    static let demoScript = #"""
    [
      {"say": "I'll click the Title field and type the title.",
       "actions": [{"action": "left_click", "coordinate": [500, 207]}, {"action": "type", "text": "Quarterly plan"}]},
      {"say": "Saving with Command-S.", "actions": [{"action": "key", "text": "super+s"}]},
      {"say": "The sync password field is next; trying it.", "actions": [{"action": "left_click", "element": "e3"},
       {"action": "type", "text": "hunter2"}]},
      {"say": "I titled the note Quarterly plan and saved it. The sync password is yours to fill in.", "succeeded": true}
    ]
    """#

    static func make() throws -> (png: Data, elements: [Element]) {
        let width = size.width, height = size.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageCoding.Failure.resizeFailed }
        // Top-left coordinates: flip once.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        func stroke(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0, width: CGFloat = 1) {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
        func text(_ string: String, _ x: CGFloat, _ baseline: CGFloat, size: CGFloat, color: CGColor, bold: Bool = false) {
            context.saveGState()
            // Undo the flip for text, which Core Text draws upright in a y-up space.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            TakeoverCommands.drawText(string, at: CGPoint(x: x, y: CGFloat(height) - baseline), color: color, size: size, in: context, bold: bold)
            context.restoreGState()
        }
        let ink = CGColor(gray: 0.12, alpha: 1), muted = CGColor(gray: 0.55, alpha: 1), border = CGColor(gray: 0.75, alpha: 1)
        // Desktop and menu bar.
        fill(CGRect(x: 0, y: 0, width: width, height: height), CGColor(red: 0.42, green: 0.52, blue: 0.66, alpha: 1))
        fill(CGRect(x: 0, y: 0, width: width, height: 30), CGColor(gray: 0.96, alpha: 0.95))
        text("Notes Lite", 52, 21, size: 15, color: ink, bold: true)
        text("File   Edit   Format   Window   Help", 150, 21, size: 15, color: ink)
        // The window.
        fill(window.offsetBy(dx: 0, dy: 8), CGColor(gray: 0, alpha: 0.18), radius: 12)
        fill(window, CGColor(gray: 1, alpha: 1), radius: 12)
        fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 44), CGColor(gray: 0.93, alpha: 1), radius: 12)
        for (index, color) in [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                               CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            fill(CGRect(x: window.minX + 18 + CGFloat(index) * 22, y: window.minY + 15, width: 14, height: 14), color, radius: 7)
        }
        text("New Note", window.midX - 34, window.minY + 28, size: 15, color: ink, bold: true)
        // Fields.
        let labels = ["e1": "Title", "e2": "Body", "e3": "Sync password"]
        for element in elements {
            if let label = labels[element.id] { text(label, element.box.minX, element.box.minY - 10, size: 15, color: ink, bold: true) }
            switch element.role {
            case "AXButton":
                let primary = element.label == "Save"
                fill(element.box, primary ? CGColor(red: 0.04, green: 0.45, blue: 0.95, alpha: 1) : CGColor(gray: 0.94, alpha: 1), radius: 8)
                if !primary { stroke(element.box, border, radius: 8) }
                text(element.label, element.box.midX - CGFloat(element.label.count) * 4.6, element.box.midY + 6, size: 16,
                     color: primary ? CGColor(gray: 1, alpha: 1) : ink, bold: primary)
            default:
                fill(element.box, CGColor(gray: 1, alpha: 1), radius: 6)
                stroke(element.box, border, radius: 6, width: 1.5)
                let placeholder = element.id == "e1" ? "Untitled" : element.id == "e3" ? "Password" : "Write something…"
                text(placeholder, element.box.minX + 12, element.box.minY + 24, size: 15, color: muted)
            }
        }
        text("Notes sync across your devices when a sync password is set.", 260, 650, size: 13, color: muted)
        guard let image = context.makeImage() else { throw ImageCoding.Failure.resizeFailed }
        return (try ImageCoding.pngData(image), elements)
    }
}
