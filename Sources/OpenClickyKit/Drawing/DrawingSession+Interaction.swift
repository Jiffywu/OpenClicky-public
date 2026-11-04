import CoreGraphics
import Foundation
import JavaScriptCore

// What the user and the screen do to a drawing once it is up: cards dragged or closed, the screen changing under it,
// and the text a follow-up turn reads about it. See docs/overlay-interaction.md.

extension DrawingSession {
    /// A card on the drawing (a paper, a photo or other media card, or a 3D figure) and the marks riding on it.
    public struct Card: Sendable, Hashable {
        public var id: String
        /// The card mark's kind: "paper", "photo", "figure", …
        public var kind: String
        /// Where it is, in canvas units.
        public var box: CGRect
        /// The card's own mark and every mark riding on it.
        public var marks: [String]
        public var title: String
        /// A 3D figure sits on it (dragging the card would leave the figure behind, so it can't be dragged).
        public var hasFigure: Bool

        public init(id: String, kind: String, box: CGRect, marks: [String], title: String = "", hasFigure: Bool = false) {
            self.id = id
            self.kind = kind
            self.box = box
            self.marks = marks
            self.title = title
            self.hasFigure = hasFigure
        }

        init?(json: JSONValue) {
            guard let id = json["id"]?.stringValue, let box = json["box"]?.arrayValue?.compactMap(\.doubleValue), box.count == 4 else { return nil }
            self.init(id: id, kind: json["kind"]?.stringValue ?? "", box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
                      marks: (json["marks"]?.arrayValue ?? []).compactMap(\.stringValue), title: json["title"]?.stringValue ?? "",
                      hasFigure: json["has3D"]?.boolValue ?? false)
        }

        /// Figures turn when dragged; a card carrying one stays where it is.
        public var isDraggable: Bool { kind != "figure" && !hasFigure }
    }

    /// The cards on screen now, after every command sent before.
    public func cards() async -> [Card] {
        let result = await interact(.cards)
        return (result?.arrayValue ?? []).compactMap(Card.init(json:))
    }

    /// The user dragged `card` by `delta` canvas units: its marks move there at once (kept on the canvas). Returns the
    /// move made, or nil when nothing moved.
    @discardableResult
    public func moveCard(_ card: Card, by delta: CGSize) async -> CGSize? {
        guard card.isDraggable else { return nil }
        let result = await interact(.moveCard(marks: card.marks, dx: Double(delta.width), dy: Double(delta.height)))
        guard let moved = result?.arrayValue?.compactMap(\.doubleValue), moved.count == 2 else { return nil }
        return CGSize(width: moved[0], height: moved[1])
    }

    /// The user closed `card`: it and everything on it leave the screen. Returns how many marks went.
    @discardableResult
    public func closeCard(_ card: Card) async -> Int {
        let result = await interact(.closeCard(marks: card.marks))
        return result?.doubleValue.map { Int($0) } ?? 0
    }

    /// What lies under the drawing changed (its window moved or was covered, the user scrolled or switched apps):
    /// marks that point at things on the screen go, including those still waiting for their line; cards stay.
    @discardableResult
    public func dropScreenMarks() async -> (kept: Int, dropped: Int) {
        let result = await interact(.dropScreenMarks)
        return (result?["kept"]?.intValue ?? 0, result?["dropped"]?.intValue ?? 0)
    }

    /// What the drawing on screen shows, for the brain's next turn: the card's parts as drawn (ids, kinds, words and
    /// boxes) and each 3D figure's parts. Nil when nothing is drawn. At most `maxCharacters` long; the oldest 2D parts
    /// are folded into one line first.
    public func describeOnScreen(maxCharacters: Int = 12_000) -> String? {
        let figures = painter.figureFrames.keys.sorted().map { id in
            host.withContext { FigureTickBridge(context: $0).describe(figure: id) }
        }.filter { !$0.isEmpty }
        let figureText = figures.joined(separator: "\n")
        let room = max(1_000, maxCharacters - figureText.count - 1)
        let card = host.describe(drawnOnly: true, maxCharacters: room)
        let text = [card, figureText].filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return text.count > maxCharacters ? String(text.prefix(maxCharacters - 1)) + "…" : text
    }

    /// The program variable or name of a figure part (`__figure3d.nameOf`), for naming a clicked part.
    public func figurePartName(_ partID: String) -> String? {
        host.withContext { FigureTickBridge(context: $0).nameOf(part: partID) }
    }

    private func interact(_ interaction: DrawingEngineHost.Interaction) async -> JSONValue? {
        await withCheckedContinuation { (continuation: CheckedContinuation<JSONValue?, Never>) in
            host.interact(interaction) { [weak self] result, events, number in
                self?.deliver(events, program: number)
                continuation.resume(returning: result)
            }
        }
    }
}

extension FigureTickBridge {
    /// What a part is called: its `name`, else the program variable holding it (`const rotor = f.cylinder(…)`), else nil.
    public func nameOf(part partID: String) -> String? {
        guard let registry = context.objectForKeyedSubscript("__figure3d"), registry.isObject,
              let value = registry.invokeMethod("nameOf", withArguments: [partID]), value.isString else { return nil }
        let name = value.toString() ?? ""
        return name.isEmpty ? nil : name
    }
}
