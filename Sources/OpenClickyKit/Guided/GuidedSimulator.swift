import CoreGraphics
import Foundation

/// A scripted walkthrough for running the guided loop with no screen, mouse or permissions (`occtl guided simulate`,
/// tests). Coordinates are screenshot pixels, top-left origin, on one display the size of `screen`.
///
///     {"screen": {"width": 1280, "height": 800},
///      "elements": [{"id": "e1", "role": "AXMenuBarItem", "label": "File", "box": [60, 0, 40, 24]}],
///      "events": [{"at": 0, "answer": "task(\"Export\")\nsay(\"Open File.\")\ntarget(58, 2, 44, 20, \"File\")"},
///                 {"at": 1.5, "click": [80, 12]}]}
///
/// `answer` runs a drawing program through the real engine and guided pieces (its markers arm targets; an answer
/// with none finishes the walkthrough). Other events: `click`, `move` ([x, y]), `key`, `scroll`, `app` (bundle id),
/// `escape`, `userTurn`.
public struct GuidedScript: Codable, Sendable {
    public struct Screen: Codable, Sendable {
        public var width: Double
        public var height: Double
    }

    public struct Element: Codable, Sendable {
        public var id: String
        public var role: String
        public var label: String?
        public var box: [Double]
        public var enabled: Bool?
    }

    public struct Event: Codable, Sendable {
        public var at: Double
        public var answer: String?
        public var click: [Double]?
        public var move: [Double]?
        public var key: Bool?
        public var scroll: Bool?
        public var app: String?
        public var escape: Bool?
        public var userTurn: Bool?
    }

    public var screen: Screen
    public var elements: [Element]
    public var events: [Event]

    public var geometry: CaptureGeometry {
        CaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: screen.width, height: screen.height),
                        pixelWidth: Int(screen.width.rounded()), pixelHeight: Int(screen.height.rounded()))
    }

    /// The elements as an Accessibility snapshot would give them (AppKit global frames).
    public var snapshots: [ElementSnapshot] {
        let g = geometry
        return elements.compactMap { e in
            guard e.box.count == 4 else { return nil }
            return ElementSnapshot(id: e.id, role: e.role, title: e.label,
                                   frame: g.appKitRect(fromPixelRect: CGRect(x: e.box[0], y: e.box[1], width: e.box[2], height: e.box[3])),
                                   isEnabled: e.enabled ?? true)
        }
    }
}

@MainActor
public enum GuidedSimulator {
    public struct Result {
        /// What happened, one line per event or effect, with times.
        public var log: [String]
        public var requests: [GuidedTurnRequest]
        /// Each target when it was armed.
        public var targets: [(target: GuidedTarget, at: TimeInterval)]
        public var finalStatus: GuidedStatus
        public var phase: GuidedWalkthrough.Phase
        /// Every call the buddy pointer got, with times (flights to targets and pointed-at controls).
        public var buddy: [(call: RecordingBuddyPointer.Call, at: TimeInterval)]
    }

    public static func run(_ script: GuidedScript, settings: GuidedWalkthrough.Settings = .init(), tick: TimeInterval = 0.05) throws -> Result {
        var now: TimeInterval = 0
        let controller = GuidedWalkthroughController(settings: settings, clock: { now })
        let geometry = script.geometry
        controller.screen = GuidedScreen(geometry: geometry, elements: script.snapshots)
        let engine = try DrawingEngineHost(prewarmShape: nil)
        let pointer = RecordingBuddyPointer()
        let buddy = BuddyGuidance(pointer: pointer)
        var buddyCalls: [(RecordingBuddyPointer.Call, TimeInterval)] = []
        pointer.onCall = { buddyCalls.append(($0, now)) }
        var log: [String] = []
        var requests: [GuidedTurnRequest] = []
        var targets: [(GuidedTarget, TimeInterval)] = []
        func stamp(_ line: String) { log.append(String(format: "%6.2f s  ", now) + line) }
        func px(_ p: CGPoint?) -> String {
            guard let p, let pixel = geometry.pixel(fromAppKit: p) else { return "?" }
            return "(\(Int(pixel.x.rounded())), \(Int(pixel.y.rounded())))"
        }
        buddy.onLog = { line in
            let flight = pointer.calls.last.flatMap { call -> String? in
                guard case .fly(let destination, _, let hold) = call, line.contains("flies to") else { return nil }
                let frame = destination.resolved.frame.map { geometry.pixelRect(fromAppKitRect: $0) }
                let box = frame.map { "pixels [\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width)), \(Int($0.height))]" } ?? px(destination.resolved.point)
                return " → \(box)" + (hold.map { String(format: ", back after %.1f s", $0) } ?? ", parked")
            }
            stamp(line + (flight ?? ""))
        }
        controller.onEffect = { effect in
            // The buddy decides on the effect first, as the app's pointing guide does.
            buddy.handle(effect)
            switch effect {
            case .showTarget(let t):
                targets.append((t, now))
                let box = geometry.pixelRect(fromAppKitRect: t.frame)
                let how = t.element.map { "snapped to \($0.id) \($0.kindName) \"\($0.label ?? "")\" (\(t.snap.rawValue))" } ?? "no control near; ring at the brain's box"
                stamp("show \(t.isHover ? "hover" : "click") target \"\(t.name ?? "?")\" at pixels [\(Int(box.minX)), \(Int(box.minY)), \(Int(box.width)), \(Int(box.height))], \(how)")
            case .clearTarget: stamp("clear target")
            case .startTurn(let request):
                requests.append(request)
                stamp("START TURN trigger=\(request.trigger.rawValue) step=\(request.step) remaining=\(request.remainingRounds)")
                for note in request.notes { stamp("    note: " + note.replacingOccurrences(of: "\n", with: "\n             ")) }
            case .refreshCapture: stamp("re-capture the screen (the user kept going)")
            case .ended(let reason): stamp("walkthrough ended: \(reason.rawValue)")
            }
        }
        let events = script.events.sorted { $0.at < $1.at }
        for event in events {
            // Let time pass up to the event: hover rests complete, manual steps settle, targets expire.
            while now + tick <= event.at {
                now += tick
                controller.tick()
            }
            now = event.at
            controller.tick()
            if let answer = event.answer {
                stamp("brain answers: " + answer.split(whereSeparator: \.isNewline).joined(separator: " ⏎ "))
                var drained = engine.perform(.begin(DrawingBeginOptions(width: script.screen.width, height: script.screen.height, pace: .now)))
                drained += engine.perform(.append(answer))
                drained += engine.perform(.end)
                drained += engine.perform(.drain)
                for event in drained {
                    if case .warning(let message) = event { stamp("drawing warning: \(message)") }
                    if case .error(let message, _) = event { stamp("drawing error: \(message)") }
                }
                let marks = drained.flatMap { event -> [DrawingMark] in if case .marks(let ms) = event { ms } else { [] } }
                for marker in marks.compactMap(GuidedMarker.init(mark:)) {
                    if case .task(let name) = marker { stamp("task: \(name)") }
                    if case .wait(let note) = marker { stamp("manual step: \(note ?? "(no note)")") }
                    if case .target(let request) = marker, case .element(let id) = request.place,
                       !script.snapshots.contains(where: { $0.id == id }) {
                        stamp("target names \(id), which isn't on screen: nothing armed")
                    }
                    controller.apply(marker)
                }
                buddy.marksReleased(marks, screen: controller.screen)
                _ = engine.perform(.cancel)
                // The narration is over: an answer that armed nothing ends the walkthrough.
                controller.answerFinished()
            }
            if let p = event.click, p.count == 2 {
                let point = geometry.appKitPoint(fromPixel: CGPoint(x: p[0], y: p[1]))
                stamp("user clicks at \(px(point))")
                controller.handle(.mouseDown(point))
            }
            if let p = event.move, p.count == 2 {
                let point = geometry.appKitPoint(fromPixel: CGPoint(x: p[0], y: p[1]))
                stamp("pointer moves to \(px(point))")
                controller.handle(.mouseMoved(point))
            }
            if event.key == true { stamp("user types"); controller.handle(.keyDown) }
            if event.scroll == true { stamp("user scrolls"); controller.handle(.scroll) }
            if let app = event.app { stamp("front app becomes \(app)"); controller.handle(.appChanged(app)) }
            if event.escape == true { stamp("user presses Escape"); controller.handle(.escape) }
            if event.userTurn == true {
                stamp("user presses the talk key")
                buddy.userTurnStarted()
                controller.userTurnStarted()
            }
            let status = controller.status
            if status.isActive { stamp("HUD: step \(status.step) of at most \(status.maxRounds) · \(status.caption)") }
        }
        // Let any pending quiet period or hover finish.
        for _ in 0..<Int(3 / tick) {
            now += tick
            controller.tick()
        }
        return Result(log: log, requests: requests, targets: targets, finalStatus: controller.status, phase: controller.walkthrough.phase,
                      buddy: buddyCalls)
    }
}

extension GuidedScript {
    /// A plain picture of the scripted screen: a window, and each element as a labelled control where its box is.
    /// Flat shapes and system type only, so evidence renders have something to point at.
    public func mockScreen() -> CGImage? {
        let width = Int(screen.width.rounded()), height = Int(screen.height.rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func fill(_ hex: String, _ rect: CGRect, radius: CGFloat = 0) {
            context.setFillColor(DrawingColor(hex: hex)!.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        fill("#C9D3E0", CGRect(x: 0, y: 0, width: width, height: height))
        fill("#FFFFFF", CGRect(x: 30, y: 40, width: CGFloat(width) - 60, height: CGFloat(height) - 70), radius: 12)
        fill("#F1F3F6", CGRect(x: 0, y: 0, width: width, height: 26))
        for element in elements where element.box.count == 4 {
            let r = CGRect(x: element.box[0], y: element.box[1], width: element.box[2], height: element.box[3])
            switch element.role {
            case "AXButton", "AXPopUpButton", "AXMenuButton":
                fill(element.enabled == false ? "#E3E5E8" : "#E8EEF9", r, radius: 6)
            case "AXMenuItem":
                fill("#F7F8FA", r, radius: 3)
            case "AXTextField", "AXSearchField":
                fill("#FFFFFF", r, radius: 5)
                context.setStrokeColor(DrawingColor(hex: "#B8BEC8")!.cgColor)
                context.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            default:
                break
            }
            guard let label = element.label, !label.isEmpty else { continue }
            let size = min(14, max(9, r.height * 0.5))
            let path = DrawingFonts.glyphPath(label, style: .ui, size: size, origin: .zero)
            let textWidth = CGFloat(DrawingFonts.width(of: label, size: Double(size), style: .ui))
            let x = element.role == "AXMenuItem" || element.role == "AXTextField" ? r.minX + 8 : r.midX - textWidth / 2
            let baseline = r.midY + (DrawingFonts.ascent(.ui, size: size) - DrawingFonts.descent(.ui, size: size)) / 2
            var place = CGAffineTransform(translationX: x, y: baseline)
            if let moved = path.path.copy(using: &place) {
                context.setFillColor(DrawingColor(hex: element.enabled == false ? "#A0A5AD" : "#1F2328")!.cgColor)
                context.addPath(moved)
                context.fillPath()
            }
        }
        return context.makeImage()
    }
}

/// A buddy pointer that only records what it was asked (tests, `occtl guided simulate`).
@MainActor
public final class RecordingBuddyPointer: BuddyPointing {
    public enum Call: Sendable, Hashable {
        case fly(PointingDestination, label: String?, hold: TimeInterval?)
        case release
        case cancel
    }

    public private(set) var calls: [Call] = []
    public var onCall: ((Call) -> Void)?

    public init() {}

    public func fly(to destination: PointingDestination, label: String?, hold: TimeInterval?) { record(.fly(destination, label: label, hold: hold)) }
    public func release() { record(.release) }
    public func cancel() { record(.cancel) }

    private func record(_ call: Call) {
        calls.append(call)
        onCall?(call)
    }

    /// The flights only.
    public var flights: [(destination: PointingDestination, label: String?, hold: TimeInterval?)] {
        calls.compactMap { if case .fly(let d, let l, let h) = $0 { (d, l, h) } else { nil } }
    }
}
