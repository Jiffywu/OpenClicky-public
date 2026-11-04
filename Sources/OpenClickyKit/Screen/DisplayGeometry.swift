import CoreGraphics
import Foundation

/// One connected display, in the coordinate spaces OpenClicky uses.
///
/// Coordinate spaces (all in points unless a name says pixels):
/// - **AppKit global**: origin at the bottom-left corner of the primary display, y grows upward. `NSEvent.mouseLocation`,
///   `NSScreen.frame` and `NSWindow.frame` use it. `frame` below is in this space.
/// - **Quartz global**: origin at the top-left corner of the primary display, y grows downward. Core Graphics display
///   bounds, `CGEvent.location`, the window list and every Accessibility position and size use it.
/// - **Display-local**: origin at the top-left corner of one display, y grows downward. Overlay views (SwiftUI inside the
///   per-display panel) draw in it.
/// - **Screenshot pixels**: origin at the top-left corner of a capture image; see `CaptureGeometry`.
public struct DisplayGeometry: Sendable, Hashable {
    /// The Core Graphics display ID (`CGDirectDisplayID`, also `NSScreenNumber`).
    public var id: UInt32
    /// The display's rectangle in AppKit global points.
    public var frame: CGRect
    /// Backing pixels per point (2 on Retina panels, 1 on most external monitors).
    public var scale: Double
    /// The display that holds the menu bar and anchors both global spaces.
    public var isPrimary: Bool
    public var name: String?

    public init(id: UInt32, frame: CGRect, scale: Double, isPrimary: Bool, name: String? = nil) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.isPrimary = isPrimary
        self.name = name
    }

    /// The panel's native resolution in pixels.
    public var nativePixelSize: CGSize { CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded()) }
}

/// Every connected display and the conversions between global spaces.
public struct DesktopLayout: Sendable, Hashable {
    public var displays: [DisplayGeometry]

    public init(displays: [DisplayGeometry]) {
        self.displays = displays
    }

    /// The primary display, or the first one when none is flagged.
    public var primary: DisplayGeometry? { displays.first(where: \.isPrimary) ?? displays.first }

    /// Height of the primary display: the axis both global spaces flip around.
    public var primaryHeight: CGFloat { primary?.frame.height ?? 0 }

    /// The union of every display frame (AppKit global).
    public var bounds: CGRect { displays.map(\.frame).reduce(CGRect.null) { $0.union($1) } }

    // MARK: AppKit ⇄ Quartz

    public func quartzPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public func appKitPoint(fromQuartz point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public func quartzRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public func appKitRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Lookup

    /// The display containing an AppKit global point. Points on a shared edge belong to the display whose frame
    /// contains them under `CGRect.contains` (min edges inclusive, max edges exclusive).
    public func display(containing point: CGPoint) -> DisplayGeometry? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display containing the point, else the one whose frame is closest to it (for points in the gaps of an
    /// uneven arrangement or just past an edge).
    public func display(nearest point: CGPoint) -> DisplayGeometry? {
        if let hit = display(containing: point) { return hit }
        return displays.min { Self.distance(from: point, to: $0.frame) < Self.distance(from: point, to: $1.frame) }
    }

    public func display(id: UInt32) -> DisplayGeometry? { displays.first { $0.id == id } }

    /// AppKit global → display-local (top-left origin, y down).
    public func localPoint(fromAppKit point: CGPoint, in display: DisplayGeometry) -> CGPoint {
        CGPoint(x: point.x - display.frame.minX, y: display.frame.maxY - point.y)
    }

    /// Display-local → AppKit global.
    public func appKitPoint(fromLocal point: CGPoint, in display: DisplayGeometry) -> CGPoint {
        CGPoint(x: display.frame.minX + point.x, y: display.frame.maxY - point.y)
    }

    public func localRect(fromAppKit rect: CGRect, in display: DisplayGeometry) -> CGRect {
        CGRect(x: rect.minX - display.frame.minX, y: display.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Displays sorted the way people number them: left to right, then top to bottom.
    public var readingOrder: [DisplayGeometry] {
        displays.sorted { a, b in
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.frame.maxY > b.frame.maxY
        }
    }

    static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Live layout

extension DesktopLayout {
    /// The current arrangement, read from Core Graphics. Needs no permission and works in command-line tools.
    /// Uses the active displays, or the online ones while the displays sleep.
    public static func current() -> DesktopLayout {
        var ids = activeDisplayIDs()
        if ids.isEmpty { ids = onlineDisplayIDs() }
        let main = CGMainDisplayID()
        let primaryBounds = CGDisplayBounds(main)
        let primaryHeight = primaryBounds.height
        let displays = ids.map { id -> DisplayGeometry in
            let bounds = CGDisplayBounds(id) // Quartz global points
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            var scale = 1.0
            if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                scale = Double(mode.pixelWidth) / Double(mode.width)
            }
            return DisplayGeometry(id: id, frame: frame, scale: scale, isPrimary: id == main)
        }
        return DesktopLayout(displays: displays)
    }

    /// The pointer location in AppKit global points.
    public static func currentCursorLocation(in layout: DesktopLayout) -> CGPoint {
        let quartz = CGEvent(source: nil)?.location ?? .zero
        return layout.appKitPoint(fromQuartz: quartz)
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }
}

// MARK: - JSON

extension CGRect {
    /// `{x, y, width, height}`, rounded to 0.1 pt.
    public var jsonValue: JSONValue {
        func r(_ v: CGFloat) -> JSONValue { .number((Double(v) * 10).rounded() / 10) }
        return ["x": r(minX), "y": r(minY), "width": r(width), "height": r(height)]
    }
}

extension CGPoint {
    public var jsonValue: JSONValue {
        func r(_ v: CGFloat) -> JSONValue { .number((Double(v) * 10).rounded() / 10) }
        return ["x": r(x), "y": r(y)]
    }
}

extension DisplayGeometry {
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .number(Double(id)),
            "frame": frame.jsonValue,
            "scale": .number(scale),
            "isPrimary": .bool(isPrimary),
        ]
        if let name { object["name"] = .string(name) }
        return .object(object)
    }
}
