import CoreGraphics
import Foundation

/// An on-screen control the model may target by id instead of by pixel (grounding through Accessibility).
public struct DriveElement: Sendable, Hashable {
    public var id: String
    public var role: String
    public var subrole: String?
    public var label: String?
    /// AppKit global points.
    public var frame: CGRect
    public var isEnabled: Bool

    public init(id: String, role: String, subrole: String? = nil, label: String? = nil, frame: CGRect, isEnabled: Bool = true) {
        self.id = id
        self.role = role
        self.subrole = subrole
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
    }

    public init(_ snapshot: ElementSnapshot) {
        self.init(id: snapshot.id, role: snapshot.role, subrole: snapshot.subrole, label: snapshot.label, frame: snapshot.frame,
                  isEnabled: snapshot.isEnabled)
    }

    /// A password field: never clicked or typed into during a drive.
    public var isSecureField: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }

    public var kindName: String { ElementRoles.friendlyName(role: role, subrole: subrole) }
}

/// What the drive sees at one moment: the screenshot the model gets (already sized for it), the display it shows,
/// and the front window's elements.
public struct DriveObservation: Sendable {
    public var imageData: Data
    public var mimeType: String
    /// The size of the image the model sees. Coordinates the model answers with are in these pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The display the image shows.
    public var display: DisplayGeometry
    /// Every display, for converting to the Quartz coordinates `CGEvent` uses.
    public var layout: DesktopLayout
    public var elements: [DriveElement]
    public var frontApp: FrontAppInfo?
    public var windowTitle: String?
    public var capturedAt: Date

    public init(imageData: Data, mimeType: String = "image/jpeg", pixelWidth: Int, pixelHeight: Int, display: DisplayGeometry,
                layout: DesktopLayout, elements: [DriveElement] = [], frontApp: FrontAppInfo? = nil, windowTitle: String? = nil,
                capturedAt: Date = Date()) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.display = display
        self.layout = layout
        self.elements = elements
        self.frontApp = frontApp
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
    }

    public var geometry: CaptureGeometry {
        CaptureGeometry(displayFrame: display.frame, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public var mapper: DriveCoordinateMapper {
        DriveCoordinateMapper(geometry: geometry, layout: layout, elements: elements)
    }

    public var contentPart: ContentPart { .image(data: imageData, mimeType: mimeType) }

    /// Compact element lines for the prompt, boxes in this image's pixels: `e12 button "Save" [x,y,w,h]`. Only
    /// labeled, actionable elements on this display; password fields are marked so the model leaves them alone.
    public func elementLines(limit: Int = 150) -> [String] {
        let geometry = geometry
        var lines: [String] = []
        for element in elements where ElementRoles.actionable.contains(element.role) || element.isSecureField || element.role == "AXHeading" {
            guard let label = element.label ?? (element.isSecureField ? "password" : nil),
                  let box = geometry.visiblePixelRect(geometry.pixelRect(fromAppKitRect: element.frame)) else { continue }
            let numbers = [box.minX, box.minY, box.width, box.height].map { String(Int($0.rounded())) }.joined(separator: ",")
            let shown = label.count > 80 ? String(label.prefix(79)) + "…" : label
            var line = "\(element.id) \(element.kindName) \"\(shown.replacingOccurrences(of: "\"", with: "'"))\" [\(numbers)]"
            if !element.isEnabled { line += " disabled" }
            if element.isSecureField { line += " (password: off limits)" }
            lines.append(line)
            if lines.count >= limit { break }
        }
        return lines
    }
}

/// Why a model's coordinate or element could not be placed on the screen.
public enum DriveMappingError: Error, Sendable, Hashable, CustomStringConvertible {
    case outsideScreenshot(x: Double, y: Double, width: Int, height: Int)
    case unknownElement(String)
    case elementOffScreen(String)

    public var description: String {
        switch self {
        case .outsideScreenshot(let x, let y, let width, let height):
            "(\(Int(x.rounded())), \(Int(y.rounded()))) is outside the \(width)×\(height) screenshot."
        case .unknownElement(let id): "There is no element \(id) in the latest screenshot's list."
        case .elementOffScreen(let id): "Element \(id) is not on the screen being driven."
        }
    }
}

/// Maps the model's answers, in pixels of the image it was shown or element ids, to the Quartz global points
/// `CGEvent` posts at (origin top-left of the primary display, y down), and back for the overlay.
///
/// The chain is: model pixel → display-local points (`CaptureGeometry`, which scales by the image-to-display ratio)
/// → AppKit global → Quartz global (`DesktopLayout`). Retina scale never enters: the image was resized from the
/// panel's pixels, and events are posted in points.
public struct DriveCoordinateMapper: Sendable, Hashable {
    public var geometry: CaptureGeometry
    public var layout: DesktopLayout
    public var elements: [String: DriveElement]
    /// How far past the image's edge (in its pixels) an answer may land and still be pulled onto the edge. Models
    /// sometimes answer a pixel or two outside; anything further is refused rather than guessed.
    public var edgeTolerance: Double

    public init(geometry: CaptureGeometry, layout: DesktopLayout, elements: [DriveElement] = [], edgeTolerance: Double = 2) {
        self.geometry = geometry
        self.layout = layout
        self.elements = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.edgeTolerance = edgeTolerance
    }

    /// The AppKit global point a target names.
    public func appKitPoint(for target: DriveTarget) throws(DriveMappingError) -> CGPoint {
        switch target {
        case .pixel(let x, let y):
            let width = Double(geometry.pixelWidth), height = Double(geometry.pixelHeight)
            guard x >= -edgeTolerance, y >= -edgeTolerance, x <= width + edgeTolerance, y <= height + edgeTolerance else {
                throw .outsideScreenshot(x: x, y: y, width: geometry.pixelWidth, height: geometry.pixelHeight)
            }
            return geometry.appKitPoint(fromPixel: CGPoint(x: x, y: y))
        case .element(let id):
            guard let element = elements[id] else { throw .unknownElement(id) }
            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            let frame = geometry.displayFrame
            guard center.x >= frame.minX, center.x <= frame.maxX, center.y >= frame.minY, center.y <= frame.maxY else {
                throw .elementOffScreen(id)
            }
            return center
        }
    }

    /// The Quartz global point (what `CGEvent` uses) a target names.
    public func quartzPoint(for target: DriveTarget) throws(DriveMappingError) -> CGPoint {
        layout.quartzPoint(fromAppKit: try appKitPoint(for: target))
    }

    /// A Quartz global point back in the screenshot's pixels, or nil when it is not on the driven display.
    public func modelPixel(fromQuartz point: CGPoint) -> CGPoint? {
        geometry.pixel(fromQuartz: point, layout: layout)
    }

    /// A rectangle in the screenshot's pixels, as AppKit global points (for zoom captures).
    public func appKitRect(fromPixelRect rect: CGRect) -> CGRect { geometry.appKitRect(fromPixelRect: rect) }

    /// Places an input action on the screen. A click, scroll or button change without a target happens where the
    /// drive cursor is (`cursor`, Quartz global). Observations (screenshot, zoom, wait…) have nothing to place and
    /// return nil.
    public func resolve(_ action: DriveAction, cursor: CGPoint) throws(DriveMappingError) -> ResolvedDriveAction? {
        func point(_ target: DriveTarget?) throws(DriveMappingError) -> CGPoint {
            guard let target else { return cursor }
            return try quartzPoint(for: target)
        }
        switch action {
        case .screenshot, .zoom, .cursorPosition, .wait: return nil
        case .moveMouse(let target): return .move(to: try point(target))
        case .click(let target, let button, let count, let modifiers):
            return .click(at: try point(target), button: button, count: count, modifiers: modifiers)
        case .mouseDown(let target): return .mouseDown(at: try point(target))
        case .mouseUp(let target): return .mouseUp(at: try point(target))
        case .drag(let from, let to, let modifiers): return .drag(from: try point(from), to: try point(to), modifiers: modifiers)
        case .scroll(let target, let direction, let amount, let modifiers):
            return .scroll(at: try point(target), direction: direction, amount: amount, modifiers: modifiers)
        case .type(let text): return .type(text)
        case .key(let combo, let count): return .key(combo, repeatCount: count)
        case .holdKey(let combo, let seconds): return .holdKey(combo, seconds: seconds)
        }
    }
}

/// An input action placed on the screen, in Quartz global points, ready for the safety check and the actuator.
public enum ResolvedDriveAction: Sendable, Hashable {
    case move(to: CGPoint)
    case click(at: CGPoint, button: DriveMouseButton, count: Int, modifiers: DriveModifiers)
    case mouseDown(at: CGPoint)
    case mouseUp(at: CGPoint)
    case drag(from: CGPoint, to: CGPoint, modifiers: DriveModifiers)
    case scroll(at: CGPoint, direction: DriveScrollDirection, amount: Int, modifiers: DriveModifiers)
    case type(String)
    case key(KeyCombo, repeatCount: Int)
    case holdKey(KeyCombo, seconds: Double)

    /// Every point the pointer visits, in order.
    public var points: [CGPoint] {
        switch self {
        case .move(let p), .click(let p, _, _, _), .mouseDown(let p), .mouseUp(let p), .scroll(let p, _, _, _): [p]
        case .drag(let from, let to, _): [from, to]
        case .type, .key, .holdKey: []
        }
    }

    /// Where the pointer ends up, if the action moves it.
    public var finalPoint: CGPoint? { points.last }

    /// Keystrokes go to whatever has keyboard focus.
    public var usesKeyboard: Bool {
        switch self {
        case .type, .key, .holdKey: true
        default: false
        }
    }

    public var summary: String {
        func at(_ p: CGPoint) -> String { "(\(Int(p.x.rounded())), \(Int(p.y.rounded())))" }
        func with(_ modifiers: DriveModifiers) -> String { modifiers.isEmpty ? "" : " with \(modifiers.summary)" }
        switch self {
        case .move(let p): return "move to \(at(p))"
        case .click(let p, let button, let count, let modifiers):
            let kind = count == 3 ? "triple click" : count == 2 ? "double click" : button == .left ? "click" : "\(button.rawValue) click"
            return "\(kind) at \(at(p))\(with(modifiers))"
        case .mouseDown(let p): return "mouse down at \(at(p))"
        case .mouseUp(let p): return "mouse up at \(at(p))"
        case .drag(let from, let to, let modifiers): return "drag \(at(from)) → \(at(to))\(with(modifiers))"
        case .scroll(let p, let direction, let amount, let modifiers): return "scroll \(direction.rawValue) \(amount) at \(at(p))\(with(modifiers))"
        case .type(let text): return "type \(text.count) characters"
        case .key(let combo, let count): return "key \(combo.summary)\(count > 1 ? " ×\(count)" : "")"
        case .holdKey(let combo, let seconds): return "hold \(combo.summary) \(DriveAction.format(seconds)) s"
        }
    }
}
