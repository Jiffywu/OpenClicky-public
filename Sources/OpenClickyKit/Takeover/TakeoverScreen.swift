import CoreGraphics
import Foundation

/// Where a drive's screenshots come from. `LiveTakeoverScreen` captures the display under the pointer with
/// ScreenCaptureKit; `StillTakeoverScreen` stands a screenshot file in for the screen (tests, `occtl takeover plan` and
/// `simulate`).
public protocol TakeoverScreenSource: Sendable {
    /// The screen now, sized for the model.
    func observe() async throws -> DriveObservation
    /// A closer look at `pixelRegion` (pixels of `observation`'s image), at most `longEdge` pixels on its long edge.
    func zoom(pixelRegion: CGRect, of observation: DriveObservation, longEdge: Int) async throws -> DriveImage
}

extension TakeoverScreenSource {
    /// Crops the observation's own image (no extra detail, but a bigger view of the region).
    public func zoom(pixelRegion: CGRect, of observation: DriveObservation, longEdge: Int) async throws -> DriveImage {
        try DriveImageTools.crop(observation.imageData, region: pixelRegion, regionSpace: CGSize(width: observation.pixelWidth,
                                                                                                 height: observation.pixelHeight),
                                 longEdge: longEdge)
    }
}

/// Image helpers for drives. Core Graphics and ImageIO only, so they work in tests and occtl.
public enum DriveImageTools {
    /// Crops `region` (given in a `regionSpace`-sized coordinate system laid over the image) out of encoded image
    /// data and scales it up or down so its long edge is about `longEdge` (never past 3× the crop). JPEG out.
    public static func crop(_ data: Data, region: CGRect, regionSpace: CGSize, longEdge: Int) throws -> DriveImage {
        let image = try ImageCoding.decode(data)
        let sx = CGFloat(image.width) / max(regionSpace.width, 1)
        let sy = CGFloat(image.height) / max(regionSpace.height, 1)
        let rect = CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
            throw DriveActionParseError("The zoom region is outside the screenshot.")
        }
        let long = max(cropped.width, cropped.height)
        let target = min(longEdge, long * 3)
        let factor = Double(target) / Double(long)
        let width = max(1, Int((Double(cropped.width) * factor).rounded()))
        let height = max(1, Int((Double(cropped.height) * factor).rounded()))
        let output = try ImageCoding.resized(cropped, width: width, height: height)
        return DriveImage(data: try ImageCoding.jpegData(output), pixelWidth: width, pixelHeight: height)
    }

    /// Re-encodes an image file as a JPEG whose long edge is at most `longEdge`.
    public static func fitted(_ data: Data, longEdge: Int) throws -> DriveImage {
        let image = try ImageCoding.downscaled(ImageCoding.decode(data), longEdge: longEdge)
        return DriveImage(data: try ImageCoding.jpegData(image), pixelWidth: image.width, pixelHeight: image.height)
    }

    /// A plain light-gray screen with a faint grid: stands in for a screenshot in simulations.
    public static func placeholder(width: Int = 1280, height: Int = 800) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageCoding.Failure.resizeFailed }
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 80) { context.stroke(CGRect(x: x, y: 0, width: 0, height: height)) }
        for y in stride(from: 0, through: height, by: 80) { context.stroke(CGRect(x: 0, y: y, width: width, height: 0)) }
        guard let image = context.makeImage() else { throw ImageCoding.Failure.resizeFailed }
        return try ImageCoding.jpegData(image)
    }
}

/// A screenshot file standing in for the screen. The file is resized for the model; zooms crop the original at
/// full resolution. The display it shows defaults to a 1-point-per-pixel display at the origin, unless a display
/// is given (occtl passes the real primary display when the aspect ratios match).
public struct StillTakeoverScreen: TakeoverScreenSource {
    public let original: Data
    public let observation: DriveObservation

    public init(imageData: Data, display: DisplayGeometry? = nil, layout: DesktopLayout? = nil, elements: [DriveElement] = [],
                frontApp: FrontAppInfo? = nil, windowTitle: String? = nil, longEdge: Int = CaptureSizing.modelLongEdge) throws {
        original = imageData
        guard let size = ImageCoding.pixelSize(of: imageData) else { throw ImageCoding.Failure.decodeFailed }
        let fitted = try DriveImageTools.fitted(imageData, longEdge: longEdge)
        let display = display ?? DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: size.width, height: size.height), scale: 1,
                                                 isPrimary: true, name: "screenshot file")
        let layout = layout ?? DesktopLayout(displays: [display])
        observation = DriveObservation(imageData: fitted.data, mimeType: fitted.mimeType, pixelWidth: fitted.pixelWidth,
                                       pixelHeight: fitted.pixelHeight, display: display, layout: layout, elements: elements,
                                       frontApp: frontApp, windowTitle: windowTitle)
    }

    /// The display a screenshot of `pixelSize` most likely shows: the layout's primary display when its aspect
    /// ratio matches within 2 %, else nil.
    public static func matchingDisplay(pixelSize: (width: Int, height: Int), in layout: DesktopLayout) -> DisplayGeometry? {
        guard let primary = layout.primary, primary.frame.height > 0, pixelSize.height > 0 else { return nil }
        let displayAspect = primary.frame.width / primary.frame.height
        let imageAspect = CGFloat(pixelSize.width) / CGFloat(pixelSize.height)
        return abs(displayAspect - imageAspect) / displayAspect <= 0.02 ? primary : nil
    }

    public func observe() async throws -> DriveObservation {
        var fresh = observation
        fresh.capturedAt = Date()
        return fresh
    }

    public func zoom(pixelRegion: CGRect, of observation: DriveObservation, longEdge: Int) async throws -> DriveImage {
        try DriveImageTools.crop(original, region: pixelRegion,
                                 regionSpace: CGSize(width: observation.pixelWidth, height: observation.pixelHeight), longEdge: longEdge)
    }
}

/// The real screen: the display under the pointer through ScreenCaptureKit (Screen Recording permission), the
/// front window's elements through Accessibility (when trusted), and full-resolution zooms.
public struct LiveTakeoverScreen: TakeoverScreenSource {
    public var capturer: ScreenCaptureKitCapturer
    /// OpenClicky's own windows (overlay, consent card) to leave out of every screenshot.
    public var exclusion: @Sendable () -> CaptureExclusion
    /// The app being driven (OpenClicky itself skipped).
    public var frontApp: @Sendable () -> FrontAppInfo?
    public var readsElements: Bool
    public var longEdge: Int

    public init(capturer: ScreenCaptureKitCapturer = ScreenCaptureKitCapturer(), exclusion: @escaping @Sendable () -> CaptureExclusion = { .none },
                frontApp: @escaping @Sendable () -> FrontAppInfo?, readsElements: Bool = true, longEdge: Int = CaptureSizing.modelLongEdge) {
        self.capturer = capturer
        self.exclusion = exclusion
        self.frontApp = frontApp
        self.readsElements = readsElements
        self.longEdge = longEdge
    }

    public func observe() async throws -> DriveObservation {
        let options = ScreenCaptureOptions(displays: .cursorOnly, longEdge: longEdge, showsCursor: true, exclusion: exclusion(),
                                           settle: .quick)
        guard let capture = try await capturer.capture(options).cursorCapture else { throw ScreenCaptureError.noDisplays }
        let layout = capturer.layout()
        let app = frontApp()
        var elements: [DriveElement] = []
        var windowTitle: String?
        if readsElements, let app, let snapshot = AccessibilityElementReader().snapshot(of: app, layout: layout) {
            elements = snapshot.elements.map(DriveElement.init)
            windowTitle = snapshot.windowTitle
        }
        return DriveObservation(imageData: capture.imageData, mimeType: capture.mimeType, pixelWidth: capture.pixelWidth,
                                pixelHeight: capture.pixelHeight, display: capture.display, layout: layout, elements: elements,
                                frontApp: app, windowTitle: windowTitle, capturedAt: capture.capturedAt)
    }

    public func zoom(pixelRegion: CGRect, of observation: DriveObservation, longEdge: Int) async throws -> DriveImage {
        let rect = observation.mapper.appKitRect(fromPixelRect: pixelRegion)
        let region = try await capturer.captureRegion(rect, exclusion: exclusion())
        return try DriveImageTools.fitted(region.png, longEdge: longEdge)
    }
}
