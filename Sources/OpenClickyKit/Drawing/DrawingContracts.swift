import CoreGraphics
import Foundation
import QuartzCore

/// One thing to draw, as emitted by the drawing engine. See docs/drawing-contract.md.
public struct DrawingMark: Sendable, Hashable {
    public var json: JSONValue

    public init(_ json: JSONValue) { self.json = json }

    public var id: String { json["id"]?.stringValue ?? "" }
    /// The mark kind (`do` field): "line", "text", "figure", "part3d", …
    public var kind: String { json["do"]?.stringValue ?? "" }
    public var step: Int { json["step"]?.intValue ?? 0 }
    /// Seconds after the step's line starts when this mark begins drawing.
    public var start: Double { json["start"]?.doubleValue ?? 0 }
    /// Seconds the mark takes to draw (pen reveal); 0 = appear at once.
    public var duration: Double { json["duration"]?.doubleValue ?? 0 }

    /// 3D marks go to the FigureSink; the 2D painter never interprets them.
    public var isFigureMark: Bool { kind.hasPrefix("figure") || kind.hasSuffix("3d") }
}

/// Events the engine hands to the host (`__engine.drain()`).
public enum DrawingEvent: Sendable, Hashable {
    case marks([DrawingMark])
    case remove([String])
    case step(Int)
    case warning(String)
    case error(message: String, statement: String?)
    /// A drawn button was clicked; its text becomes a typed follow-up turn.
    case ask(String)
    /// A plugin needs data from the host for mark `mark` (a photo, a place, a quote; docs/dsl-media.md). `json` is the
    /// whole event. Answer with `DrawingEngineHost.Command.patch(ref:fields:)`; unanswered requests are harmless.
    case request(ref: String, mark: String, json: JSONValue)
    /// Something the host does when its line is heard, or when a drawn button or link is clicked: type words, copy
    /// them, open a web page, hand a task to an agent, play a sound (docs/dsl.md, "Actions").
    case action(DrawingAction)
    /// What the program noted for the host: `seen` (what the user is doing), `noted` (a fact about the user),
    /// `lesson` (a title for a saved lesson). Draws nothing.
    case note(kind: String, text: String)
    /// What a mark sounds like as it is drawn, at host-clock time `at` (a sound recipe; `DrawingSoundRecipe`).
    case sound(DrawingSoundRecipe)
    case done

    public init?(json: JSONValue) {
        switch json["type"]?.stringValue {
        case "marks": self = .marks((json["marks"]?.arrayValue ?? []).map(DrawingMark.init))
        case "remove": self = .remove((json["ids"]?.arrayValue ?? []).compactMap(\.stringValue))
        case "step": self = .step(json["step"]?.intValue ?? 0)
        case "warning": self = .warning(json["message"]?.stringValue ?? "")
        case "error": self = .error(message: json["message"]?.stringValue ?? "", statement: json["statement"]?.stringValue)
        case "ask": self = .ask(json["text"]?.stringValue ?? "")
        case "request":
            guard let ref = json["ref"]?.stringValue, let mark = json["mark"]?.stringValue else { return nil }
            self = .request(ref: ref, mark: mark, json: json)
        case "done": self = .done
        case "action":
            guard let action = DrawingAction(json: json) else { return nil }
            self = .action(action)
        case "note":
            guard let kind = json["kind"]?.stringValue, let text = json["text"]?.stringValue else { return nil }
            self = .note(kind: kind, text: text)
        case "sound":
            guard let recipe = DrawingSoundRecipe(json: json) else { return nil }
            self = .sound(recipe)
        default: return nil
        }
    }
}

/// An action in a drawing (`typeText`, `copyText`, `openPage`, `handOff`, `sfx`, or a button or link that was clicked).
public struct DrawingAction: Sendable, Hashable {
    public enum Role: String, Sendable {
        /// Type `text` where the caret is (at `point` if given). Never presses Return.
        case type
        /// Put `text` on the clipboard.
        case copy
        /// Open `url` (http or https only).
        case open
        /// Hand `task` to a background agent.
        case handoff
        /// Play the named sound accent (`text`).
        case sfx
    }

    public var role: Role
    /// The words to type or copy, the sound's name, or the hand-off task.
    public var text: String?
    public var url: URL?
    /// The hand-off's short label, when it has one.
    public var label: String?
    /// Where to type, in canvas units, when the program said.
    public var point: CGPoint?
    /// The mark it came from.
    public var mark: String?
    /// True when a click on a drawn button or link asked for it (not the voice reaching its line).
    public var fromClick: Bool

    public init(role: Role, text: String? = nil, url: URL? = nil, label: String? = nil, point: CGPoint? = nil, mark: String? = nil,
                fromClick: Bool = false) {
        self.role = role
        self.text = text
        self.url = url
        self.label = label
        self.point = point
        self.mark = mark
        self.fromClick = fromClick
    }

    public init?(json: JSONValue) {
        guard let raw = json["role"]?.stringValue, let role = Role(rawValue: raw) else { return nil }
        self.role = role
        mark = json["mark"]?.stringValue
        fromClick = json["click"]?.boolValue == true
        let payload = json["payload"]
        switch role {
        case .type, .copy, .sfx:
            guard let words = payload?.stringValue, !words.isEmpty else { return nil }
            text = words
        case .open:
            guard let string = payload?.stringValue, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            self.url = url
        case .handoff:
            guard let task = payload?["task"]?.stringValue ?? payload?.stringValue, !task.isEmpty else { return nil }
            text = task
            label = payload?["label"]?.stringValue
        }
        if role == .type, let at = json["at"]?.arrayValue, at.count >= 2, let x = at[0].doubleValue, let y = at[1].doubleValue, x != 0 || y != 0 {
            point = CGPoint(x: x, y: y)
        }
    }
}

/// The sound of one mark being drawn (docs/dsl.md, "Sound recipes"): a texture that lasts as long as the pen moves
/// (`felt` on the screen, `pencil` on a card, `writing`, `eraser`) and short accents at offsets into it.
public struct DrawingSoundRecipe: Sendable, Hashable {
    public struct Accent: Sendable, Hashable {
        public var id: String
        /// Seconds after the mark starts.
        public var at: Double

        public init(id: String, at: Double) {
            self.id = id
            self.at = at
        }
    }

    /// Host-clock seconds when the mark starts drawing.
    public var at: Double
    public var duration: Double
    public var texture: String?
    public var accents: [Accent]
    public var mark: String?

    public init(at: Double, duration: Double, texture: String?, accents: [Accent], mark: String? = nil) {
        self.at = at
        self.duration = duration
        self.texture = texture
        self.accents = accents
        self.mark = mark
    }

    public init?(json: JSONValue) {
        guard let at = json["at"]?.doubleValue else { return nil }
        self.at = at
        duration = max(0, json["dur"]?.doubleValue ?? 0)
        texture = json["texture"]?.stringValue
        accents = (json["events"]?.arrayValue ?? []).compactMap { event in
            guard let id = event["id"]?.stringValue else { return nil }
            return Accent(id: id, at: max(0, event["at"]?.doubleValue ?? 0))
        }
        mark = json["mark"]?.stringValue
        if texture == nil && accents.isEmpty { return nil }
    }
}

/// Renders 3D figure marks. Implemented by the 3D milestone; the 2D painter forwards every `isFigureMark` mark here and
/// places the returned layer in its canvas at the figure's rectangle.
@MainActor
public protocol FigureSink: AnyObject {
    /// Apply a 3D mark (create a figure, add or move a part, change the camera…).
    func apply(_ mark: DrawingMark)
    /// The layer showing figure `figureID`, once its `figure` mark has been applied.
    func layer(forFigure figureID: String) -> CALayer?
    /// The part under a point in the figure layer's coordinates (for drag-to-rotate and part picking).
    func hitTest(figure figureID: String, at point: CGPoint) -> String?
    /// Remove a figure and free its GPU resources.
    func removeFigure(_ figureID: String)
}

/// How drawing is paced against the voice: the orchestrator reports when each say() line starts and ends playing.
public protocol SpeechPacing: AnyObject {
    func lineStarted(_ index: Int, expectedDuration: TimeInterval?)
    func lineFinished(_ index: Int)
}
