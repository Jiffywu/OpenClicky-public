import CoreGraphics
import Foundation

/// Maps between one screenshot's pixels, its display's points and global screen coordinates.
///
/// Screenshot pixels have their origin at the image's top-left corner with y growing downward; that is how models
/// read images and how they answer with coordinates. A screenshot is usually smaller than the display in points
/// (1280 px across a 1512 pt panel), so one pixel is `pointsPerPixel` points. Retina scale does not enter the
/// mapping: the screenshot was resized from whatever the panel's native pixels were.
public struct CaptureGeometry: Sendable, Hashable {
    /// The captured display's frame in AppKit global points (bottom-left origin).
    public var displayFrame: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(displayFrame: CGRect, pixelWidth: Int, pixelHeight: Int) {
        self.displayFrame = displayFrame
        self.pixelWidth = max(pixelWidth, 1)
        self.pixelHeight = max(pixelHeight, 1)
    }

    public var pointsPerPixelX: CGFloat { displayFrame.width / CGFloat(pixelWidth) }
    public var pointsPerPixelY: CGFloat { displayFrame.height / CGFloat(pixelHeight) }

    // MARK: Points

    /// Pulls a pixel coordinate inside the image (models sometimes answer a few pixels past the edge).
    public func clampedPixel(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: min(max(pixel.x, 0), CGFloat(pixelWidth)), y: min(max(pixel.y, 0), CGFloat(pixelHeight)))
    }

    public func containsPixel(_ pixel: CGPoint) -> Bool {
        pixel.x >= 0 && pixel.y >= 0 && pixel.x <= CGFloat(pixelWidth) && pixel.y <= CGFloat(pixelHeight)
    }

    /// Screenshot pixel → display-local points (top-left origin). Clamps to the image.
    public func localPoint(fromPixel pixel: CGPoint) -> CGPoint {
        let p = clampedPixel(pixel)
        return CGPoint(x: p.x * pointsPerPixelX, y: p.y * pointsPerPixelY)
    }

    /// Display-local points → screenshot pixels (not clamped).
    public func pixel(fromLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / pointsPerPixelX, y: point.y / pointsPerPixelY)
    }

    /// Screenshot pixel → AppKit global points. Clamps to the image.
    public func appKitPoint(fromPixel pixel: CGPoint) -> CGPoint {
        let local = localPoint(fromPixel: pixel)
        return CGPoint(x: displayFrame.minX + local.x, y: displayFrame.maxY - local.y)
    }

    /// AppKit global points → screenshot pixels, or nil when the point is not on this display.
    public func pixel(fromAppKit point: CGPoint) -> CGPoint? {
        guard Self.closedContains(displayFrame, point) else { return nil }
        return pixel(fromLocal: CGPoint(x: point.x - displayFrame.minX, y: displayFrame.maxY - point.y))
    }

    /// Screenshot pixel → Quartz global points (top-left origin of the primary display), for Accessibility hit tests.
    public func quartzPoint(fromPixel pixel: CGPoint, layout: DesktopLayout) -> CGPoint {
        layout.quartzPoint(fromAppKit: appKitPoint(fromPixel: pixel))
    }

    public func pixel(fromQuartz point: CGPoint, layout: DesktopLayout) -> CGPoint? {
        pixel(fromAppKit: layout.appKitPoint(fromQuartz: point))
    }

    // MARK: Rects

    /// A rectangle in screenshot pixels (top-left origin) → AppKit global points. Clamps to the image.
    public func appKitRect(fromPixelRect rect: CGRect) -> CGRect {
        let a = appKitPoint(fromPixel: CGPoint(x: rect.minX, y: rect.minY))
        let b = appKitPoint(fromPixel: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// AppKit global rectangle → screenshot pixels (top-left origin). Not clamped; parts may lie outside the image.
    public func pixelRect(fromAppKitRect rect: CGRect) -> CGRect {
        let topLeft = pixel(fromLocal: CGPoint(x: rect.minX - displayFrame.minX, y: displayFrame.maxY - rect.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y, width: rect.width / pointsPerPixelX, height: rect.height / pointsPerPixelY)
    }

    /// Quartz global rectangle (as Accessibility reports frames) → screenshot pixels.
    public func pixelRect(fromQuartzRect rect: CGRect, layout: DesktopLayout) -> CGRect {
        pixelRect(fromAppKitRect: layout.appKitRect(fromQuartz: rect))
    }

    /// The part of the image a pixel rectangle covers, or nil when it misses the image entirely.
    public func visiblePixelRect(_ rect: CGRect) -> CGRect? {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return clipped.isNull || clipped.isEmpty ? nil : clipped
    }

    /// Like `CGRect.contains`, but the max edges count too, so the bottom-right pixel of an image maps back.
    private static func closedContains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
