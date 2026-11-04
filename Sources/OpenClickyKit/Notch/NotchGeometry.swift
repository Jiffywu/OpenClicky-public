import CoreGraphics
import Foundation

/// Where the notch is on one display, in AppKit global points (bottom-left origin).
public struct NotchGeometry: Sendable, Hashable {
    /// The size of the panel every display gets: wide and tall enough for the open notch. Only the visible part takes
    /// clicks; the rest lets them through.
    public static let envelope = CGSize(width: 680, height: 480)

    public var screenFrame: CGRect
    /// The camera housing, or nil on displays without one.
    public var notchRect: CGRect?

    public init(screenFrame: CGRect, notchRect: CGRect?) {
        self.screenFrame = screenFrame
        self.notchRect = notchRect
    }

    /// From `NSScreen`: the safe-area top inset and the menu-bar areas either side of the housing
    /// (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`). Only their widths are used, so it doesn't matter which
    /// coordinate space they come in.
    public init(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) {
        self.screenFrame = screenFrame
        if safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight, right.minX > left.maxX {
            let width = right.minX - left.maxX
            notchRect = CGRect(x: screenFrame.minX + left.width, y: screenFrame.maxY - safeAreaTop, width: width, height: safeAreaTop)
        } else {
            notchRect = nil
        }
    }

    public var hasNotch: Bool { notchRect != nil }
    public var notchWidth: CGFloat { notchRect?.width ?? 0 }
    public var notchHeight: CGFloat { notchRect?.height ?? 0 }

    /// Where resting the pointer opens the notch: the housing and a little either side of it, or without one a strip
    /// along the top edge in the middle.
    public var hotZone: CGRect {
        if let notchRect {
            return CGRect(x: notchRect.minX - 10, y: notchRect.minY, width: notchRect.width + 20, height: notchRect.height + 1)
        }
        return CGRect(x: screenFrame.midX - 110, y: screenFrame.maxY - 6, width: 220, height: 7)
    }

    /// The panel's frame: top centre.
    public var panelFrame: CGRect {
        let size = Self.envelope
        return CGRect(x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// A rect in the panel's content (top-left origin, as SwiftUI lays it out) in AppKit global points.
    public func globalRect(fromPanel rect: CGRect) -> CGRect {
        let panel = panelFrame
        return CGRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The size of what a surface draws, hanging from the top centre of the panel. The app's views use these exact
    /// sizes, so hit-testing here and in `occtl notch simulate` matches what is on screen.
    public func contentSize(for surface: NotchSurface) -> CGSize {
        let top = hasNotch ? notchHeight : 0
        switch surface {
        case .hidden: return .zero
        case .tucked: return hasNotch ? CGSize(width: notchWidth, height: notchHeight) : CGSize(width: 200, height: 6)
        case .activity: return CGSize(width: 440, height: top + 62)
        case .liveEvent(let event): return CGSize(width: 460, height: top + (event.hasButtons ? 96 : 80))
        case .onboarding: return CGSize(width: 460, height: top + 112)
        case .open: return CGSize(width: Self.envelope.width - 40, height: Self.envelope.height - 40)
        }
    }

    /// The visible content of a surface in AppKit global points (the part of the panel that takes clicks).
    public func contentRect(for surface: NotchSurface) -> CGRect {
        let size = contentSize(for: surface)
        guard size.width > 0, size.height > 0 else { return .null }
        let local = CGRect(x: (Self.envelope.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        return globalRect(fromPanel: local)
    }

    /// A point in AppKit global points in the panel's content coordinates (top-left origin).
    public func panelPoint(fromGlobal point: CGPoint) -> CGPoint {
        let panel = panelFrame
        return CGPoint(x: point.x - panel.minX, y: panel.maxY - point.y)
    }
}
