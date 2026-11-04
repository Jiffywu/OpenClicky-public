import CoreGraphics
import Foundation
import QuartzCore

// What the user can touch on a painted drawing: drawn buttons, figures, and marks moved while their card is dragged.
// Points are in the painter's layer (y down), the overlay's coordinates for its display.

extension DrawingPainter {
    /// A drawn button the user can click now, in this layer's points.
    public struct VisibleButton: Sendable, Hashable {
        public var id: String
        public var frame: CGRect
        public var text: String

        public init(id: String, frame: CGRect, text: String) {
            self.id = id
            self.frame = frame
            self.text = text
        }
    }

    /// Buttons that have started to appear by `time` (now by default), where they are drawn (moves included). A button
    /// painted ahead of its moment in the voice isn't listed yet: a click on that spot still belongs to the app below.
    public func visibleButtons(at time: CFTimeInterval? = nil) -> [VisibleButton] {
        let now = time ?? self.now()
        var out: [VisibleButton] = []
        for (id, entry) in entries where beginTime(entry.mark.json) <= now {
            let linked = entry.mark.kind == "text" && entry.mark.json["link"] != nil
            guard entry.mark.kind == "button" || linked else { continue }
            let affine = CATransform3DGetAffineTransform(entry.container.transform)
            let frame = (linked ? rect(entry.mark.json).insetBy(dx: -4, dy: -4) : rect(entry.mark.json)).applying(affine)
            guard frame.width > 0, frame.height > 0 else { continue }
            out.append(VisibleButton(id: id, frame: frame, text: entry.mark.json["text"]?.stringValue ?? ""))
        }
        return out.sorted { $0.id < $1.id }
    }

    /// The figures on the canvas and where their layers sit.
    public var figureFrames: [String: CGRect] { figureLayers.mapValues(\.frame) }

    /// Shows marks `offset` points away from where the engine put them, while the user drags their card (the move is
    /// committed to the engine when the drag ends). A zero offset puts them back.
    public func previewOffset(_ ids: [String], by offset: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shift = CATransform3DMakeTranslation(offset.width, offset.height, 0)
        for id in ids {
            guard let entry = entries[id] else { continue }
            entry.container.removeAnimation(forKey: "move")
            entry.container.transform = CATransform3DConcat(transform(entry.mark.json), shift)
        }
        CATransaction.commit()
    }
}
